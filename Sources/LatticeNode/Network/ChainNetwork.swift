import Lattice
import Foundation
import Ivy
import VolumeBroker
import Tally
import cashew
import UInt256
import OrderedCollections

public protocol ChainNetworkDelegate: AnyObject, Sendable {
    func chainNetwork(_ network: ChainNetwork, didReceiveBlock cid: String, data: Data, from peer: PeerID) async
    func chainNetwork(_ network: ChainNetwork, didReceiveBlockAnnouncement cid: String, from peer: PeerID) async
    /// Validate + classify + admit a gossip-received transaction. Delegate
    /// owns the full mempool admission decision (valid vs pending vs reject)
    /// so receipt-blocked child-chain withdrawals can sit in pending instead
    /// of being silently dropped. Returns true on any acceptance.
    func chainNetwork(_ network: ChainNetwork, admitTransaction transaction: Transaction, bodyCID: String) async -> Bool
    func chainNetwork(_ network: ChainNetwork, didConnectPeer peer: PeerID) async
}

public actor ChainNetwork: IvyDelegate, IvyDataSource {
    public let directory: String
    public let ivy: Ivy
    public let ivyFetcher: IvyFetcher
    public let nodeMempool: NodeMempool
    /// Per-chain broker cascade: MemoryBroker -> DiskBroker -> IvyBroker (shared)
    public let broker: any VolumeBroker
    /// Direct reference to the per-chain DiskBroker for durable writes.
    public let diskBroker: DiskBroker
    private let resources: NodeResourceConfig
    public weak var delegate: ChainNetworkDelegate?
    private var subscribedChains: Set<String>
    private var recentTxCIDs: OrderedDictionary<String, ContinuousClock.Instant> = [:]
    private static let maxRecentTxCIDs = 8192
    private static let txDeduplicationWindow: Duration = .seconds(60)

    /// Per-peer token bucket for mempool-full gossip admission. A peer that
    /// floods distinct valid txs would otherwise saturate mempool capacity
    /// and validation CPU; cap at ~100 sustained / 200 burst per peer.
    private var mempoolGossipBuckets: [PeerID: TokenBucket] = [:]
    /// Per-peer token bucket for pinRequest admission. Each pinRequest may
    /// trigger a DHT fetch; cap at ~10 sustained / 30 burst per peer.
    private var pinRequestBuckets: [PeerID: TokenBucket] = [:]
    private static let mempoolGossipCapacity: Double = 200
    private static let mempoolGossipRefillPerSec: Double = 100
    private static let pinRequestCapacity: Double = 30
    private static let pinRequestRefillPerSec: Double = 10

    public init(
        directory: String,
        config: IvyConfig,
        resources: NodeResourceConfig = .default,
        chainCount: Int = 1,
        maxPeerConnections: Int = BootstrapPeers.maxPeerConnections,
        sharedDiskBroker: DiskBroker,
        ivyBroker: IvyBroker? = nil,
        sharedTally: Tally? = nil
    ) async throws {
        self.directory = directory
        self.subscribedChains = Set([directory])
        self.resources = resources
        let mempoolSize = resources.mempoolSizePerChain(chainCount: chainCount)
        self.nodeMempool = NodeMempool(maxSize: mempoolSize)

        self.diskBroker = sharedDiskBroker

        let memoryBytes = resources.memoryBytesPerChain(chainCount: chainCount)
        let memoryEntries = max(memoryBytes / 4096, 100)
        let memory = MemoryBroker(capacity: memoryEntries)
        await memory.setNear(sharedDiskBroker)
        if let ivyBroker {
            await sharedDiskBroker.setFar(ivyBroker as any VolumeBroker)
        }
        self.broker = memory

        let tallyWithMaxPeers = TallyConfig(rateLimitBytesPerSecond: .infinity, maxPeers: maxPeerConnections)
        let ivyConfig = IvyConfig(
            publicKey: config.publicKey,
            listenPort: config.listenPort,
            bootstrapPeers: config.bootstrapPeers,
            enableLocalDiscovery: config.enableLocalDiscovery,
            tallyConfig: tallyWithMaxPeers,
            kBucketSize: config.kBucketSize,
            maxConcurrentRequests: config.maxConcurrentRequests,
            requestTimeout: config.requestTimeout,
            relayTimeout: config.relayTimeout,
            serviceType: config.serviceType,
            stunServers: config.stunServers,
            defaultTTL: config.defaultTTL,
            healthConfig: config.healthConfig,
            signingKey: config.signingKey,
            baseThresholdMultiplier: config.baseThresholdMultiplier
        )
        let ivy = Ivy(config: ivyConfig, tally: sharedTally)

        self.ivy = ivy
        self.ivyFetcher = IvyFetcher(ivy: ivy, broker: memory)
    }

    public func start() async throws {
        await ivy.setDelegate(self)
        await ivy.setDataSource(self)
        try await ivy.start()
    }

    public func stop() async {
        await ivy.stop()
    }

    // MARK: - IvyDataSource

    nonisolated public func data(for cid: String) async -> Data? {
        if let payload = await diskBroker.fetchVolumeLocal(root: cid) {
            return payload.entries[cid]
        }
        return nil
    }

    /// Volume responder.
    ///
    /// Volume payloads in the broker hold only the entries for one Volume —
    /// stems plus the root, terminating at the next Volume boundary (its
    /// leaves are themselves Volume roots, fetched separately). So serving
    /// the whole payload returns exactly one Volume's worth, not its
    /// transitive subtree.
    ///
    /// Empty `cids` means "everything you have under this root"; non-empty
    /// `cids` filters to that subset (legacy callers that want a partial
    /// response).
    nonisolated public func volumeData(for rootCID: String, cids: [String]) async -> [(cid: String, data: Data)] {
        guard let payload = await diskBroker.fetchVolumeLocal(root: rootCID) else {
            return []
        }
        if cids.isEmpty {
            return payload.entries.map { (cid: $0.key, data: $0.value) }
        }
        return cids.compactMap { cid in
            payload.entries[cid].map { (cid: cid, data: $0) }
        }
    }

    // MARK: - Fetcher (unified read path)

    /// Volume-aware fetcher for all Cashew resolution: state, blocks, proofs.
    /// Local cache first, then Ivy's fee-based DHT.
    public var fetcher: IvyFetcher { ivyFetcher }

    // MARK: - Store (unified write path)

    /// Store data locally and publish to the network via Ivy.
    public func storeAndPublish(cid: String, data: Data) async {
        let payload = VolumePayload(root: cid, entries: [cid: data])
        do {
            try await diskBroker.storeVolumeLocal(payload)
        } catch {
            NodeLogger("storage").error("\(directory): storeAndPublish/storeVolumeLocal cid=\(String(cid.prefix(16)))… failed: \(error)")
        }
        do {
            try await diskBroker.pin(root: cid, owner: directory)
        } catch {
            NodeLogger("storage").error("\(directory): storeAndPublish/pin root=\(String(cid.prefix(16)))… failed: \(error)")
        }
    }

    /// Store data locally only (no network publish).
    public func storeLocally(cid: String, data: Data) async {
        let payload = VolumePayload(root: cid, entries: [cid: data])
        do {
            try await diskBroker.storeVolumeLocal(payload)
        } catch {
            NodeLogger("storage").error("\(directory): storeLocally cid=\(String(cid.prefix(16)))… failed: \(error)")
        }
    }

    public func storeBatch(_ entries: [(String, Data)]) async {
        guard !entries.isEmpty else { return }
        for (cid, data) in entries {
            let payload = VolumePayload(root: cid, entries: [cid: data])
            do {
                try await diskBroker.storeVolumeLocal(payload)
            } catch {
                NodeLogger("storage").error("\(directory): storeBatch entry cid=\(String(cid.prefix(16)))… failed: \(error)")
            }
        }
    }

    /// Store a batch that comprises a single Volume's merkle subtree.
    public func storeBlockBatch(rootCID: String, entries: [(String, Data)]) async {
        guard !rootCID.isEmpty else { return }
        var dict: [String: Data] = [:]
        dict.reserveCapacity(entries.count)
        for (cid, data) in entries {
            dict[cid] = data
        }
        let payload = VolumePayload(root: rootCID, entries: dict)
        do {
            try await diskBroker.storeVolumeLocal(payload)
        } catch {
            NodeLogger("storage").error("\(directory): storeBlockBatch root=\(String(rootCID.prefix(16)))… (\(entries.count) entries) failed: \(error)")
        }
    }

    /// True iff the disk broker already has bytes for `cid`.
    public func hasCID(_ cid: String) async -> Bool {
        await diskBroker.hasVolume(root: cid)
    }

    // MARK: - Block Operations (backward compat aliases)

    public func publishBlock(cid: String, data: Data) async {
        await storeAndPublish(cid: cid, data: data)

        // Gossip block with inline data via topic so receivers don't need a round-trip fetch.
        var payload = Data()
        let cidBytes = Data(cid.utf8)
        var cidLen = UInt16(cidBytes.count).littleEndian
        payload.append(Data(bytes: &cidLen, count: 2))
        payload.append(cidBytes)
        payload.append(data)
        await ivy.broadcastMessage(topic: "newBlock", payload: payload)

        if let block = Block(data: data) {
            await announceVolumeBoundaries(block: block)
        }
    }

    /// Publish a pin announce via Ivy and record the CID with the disk broker.
    /// Ivy 5.5 removed selector — DHT pin discovery is now whole-root.
    public func announce(cid: String, expiry: UInt64, fee: UInt64) async {
        guard !cid.isEmpty else { return }
        await ivy.publishPinAnnounce(rootCID: cid, expiry: expiry, signature: Data(), fee: fee)
    }

    /// Publish pin announcements for each Volume boundary root in the block.
    /// Ivy 5.5 dropped subtree selectors — pins are now whole-root, so per-
    /// subtree announce calls have collapsed to one announce per distinct CID.
    private func announceVolumeBoundaries(block: Block) async {
        let fee = await ivy.config.relayFee * 3
        let expiry = UInt64(Date().timeIntervalSince1970) + 86400

        let frontierCID = block.frontier.rawCID
        if !frontierCID.isEmpty {
            await announce(cid: frontierCID, expiry: expiry, fee: fee)
        }
        let homesteadCID = block.homestead.rawCID
        if !homesteadCID.isEmpty {
            await announce(cid: homesteadCID, expiry: expiry, fee: fee)
        }

        let txCID = block.transactions.rawCID
        if !txCID.isEmpty {
            await announce(cid: txCID, expiry: expiry, fee: fee)
        }

        let childCID = block.childBlocks.rawCID
        if !childCID.isEmpty {
            await announce(cid: childCID, expiry: expiry, fee: fee)
        }
    }

    public func announceBlock(cid: String) async {
        await ivy.announceBlock(cid: cid)
        await gossipBlockAnnouncement(cid: cid)
    }

    public func storeBlock(cid: String, data: Data) async {
        await storeLocally(cid: cid, data: data)
        // Announce stored block so we can earn from serving it
        await announceStoredBlock(cid: cid, data: data)
    }

    /// Announce a block we received and stored so peers can discover us as a pinner.
    /// Lighter than publishBlock — no storeAndPublish, just pin announcements.
    func announceStoredBlock(cid: String, data: Data) async {
        let fee = await ivy.config.relayFee * 2
        let expiry = UInt64(Date().timeIntervalSince1970) + 86400

        // Announce the block itself
        await announce(cid: cid, expiry: expiry, fee: fee)

        // Announce Volume boundaries so state/tx subtrees are discoverable
        if let block = Block(data: data) {
            let frontierCID = block.frontier.rawCID
            if !frontierCID.isEmpty {
                await announce(cid: frontierCID, expiry: expiry, fee: fee)
            }
            let txCID = block.transactions.rawCID
            if !txCID.isEmpty {
                await announce(cid: txCID, expiry: expiry, fee: fee)
            }
        }
    }

    // MARK: - Chain Tip Management

    /// Register the tip of this chain for pin protection via the disk broker.
    public func setChainTip(tipCID: String, stateRoots: [String]) async {
        let allRoots = stateRoots + [tipCID]
        for root in allRoots where !root.isEmpty {
            do {
                try await diskBroker.pin(root: root, owner: directory)
            } catch {
                NodeLogger("storage").error("\(directory): setChainTip pin root=\(String(root.prefix(16)))… failed: \(error)")
            }
        }
    }

    // MARK: - Chain Subscription

    public func subscribe(to chainDirectory: String) {
        subscribedChains.insert(chainDirectory)
    }

    public func unsubscribe(from chainDirectory: String) {
        subscribedChains.remove(chainDirectory)
    }

    public func isSubscribed(to chainDirectory: String) -> Bool {
        subscribedChains.contains(chainDirectory)
    }

    public func subscribedDirectories() -> Set<String> {
        subscribedChains
    }

    // MARK: - Mempool Operations

    public func submitTransaction(_ transaction: Transaction) async -> Bool {
        await nodeMempool.add(transaction: transaction)
    }

    public func selectTransactionsForBlock(maxCount: Int) async -> [Transaction] {
        await nodeMempool.selectTransactions(maxCount: maxCount)
    }

    public func pruneConfirmedTransactions(txCIDs: Set<String>) async {
        await nodeMempool.removeAll(txCIDs: txCIDs)
    }

    public func allMempoolTransactions() async -> [Transaction] {
        await nodeMempool.allTransactions()
    }

    // MARK: - Chain Announce (Tip Exchange)

    /// Send our chain tip to a specific peer so they can discover they're behind.
    public func sendChainAnnounce(to peer: PeerID, tipCID: String, tipIndex: UInt64, specCID: String) async {
        let announce = ChainAnnounceData(
            chainDirectory: directory,
            tipIndex: tipIndex,
            tipCID: tipCID,
            specCID: specCID
        )
        await ivy.sendMessage(to: peer, topic: "chainAnnounce", payload: announce.serialize())
    }

    /// Broadcast our chain tip to all connected peers.
    public func broadcastChainAnnounce(tipCID: String, tipIndex: UInt64, specCID: String) async {
        let announce = ChainAnnounceData(
            chainDirectory: directory,
            tipIndex: tipIndex,
            tipCID: tipCID,
            specCID: specCID
        )
        await ivy.broadcastMessage(topic: "chainAnnounce", payload: announce.serialize())
    }

    // MARK: - Gossip

    /// Gossip a block announcement to all direct peers via peerMessage
    public func gossipBlockAnnouncement(cid: String) async {
        if let payload = cid.data(using: .utf8) {
            await ivy.broadcastMessage(topic: "newBlock", payload: payload)
        }
    }

    /// Gossip a transaction to all direct peers with body data inline.
    /// `HeaderImpl`'s Codable only emits rawCID, so a gossiped Transaction decodes
    /// with `body.node == nil` — which trips `TransactionValidator.validate`'s
    /// missingBody guard and drops the tx. We include body bytes in the payload
    /// so receivers can reconstruct the Transaction with body.node populated.
    /// Wire format: [cidLen: UInt16 LE][cid][bodyLen: UInt32 LE][body][tx]
    public func gossipTransaction(cid: String, bodyData: Data, transactionData: Data) async {
        var payload = Data()
        let cidBytes = Data(cid.utf8)
        var cidLen = UInt16(cidBytes.count)
        payload.append(Data(bytes: &cidLen, count: 2))
        payload.append(cidBytes)
        var bodyLen = UInt32(bodyData.count)
        payload.append(Data(bytes: &bodyLen, count: 4))
        payload.append(bodyData)
        payload.append(transactionData)
        await ivy.broadcastMessage(topic: "mempool-full", payload: payload)
    }

    // MARK: - IvyDelegate

    nonisolated public func ivy(_ ivy: Ivy, didConnect peer: PeerID) {
        Task { await delegate?.chainNetwork(self, didConnectPeer: peer) }
    }
    nonisolated public func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {}

    nonisolated public func ivy(_ ivy: Ivy, didReceiveBlockAnnouncement cid: String, from peer: PeerID) {
        Task { await delegate?.chainNetwork(self, didReceiveBlockAnnouncement: cid, from: peer) }
    }

    nonisolated public func ivy(_ ivy: Ivy, didReceiveBlock cid: String, data: Data, from peer: PeerID) {
        Task { await delegate?.chainNetwork(self, didReceiveBlock: cid, data: data, from: peer) }
    }

    nonisolated public func ivy(_ ivy: Ivy, didDiscoverPublicAddress address: ObservedAddress) {}

    nonisolated public func ivy(_ ivy: Ivy, didReceiveMessage message: Message, from peer: PeerID) {
        switch message {
        case .peerMessage(let topic, let payload):
            Task { await handlePeerMessage(topic: topic, payload: payload, from: peer) }
        default:
            break
        }
    }

    private func handlePeerMessage(topic: String, payload: Data, from peer: PeerID) async {
        switch topic {
        case "newBlock":
            if payload.count > 2 {
                let cidLen = Int(payload[0]) | (Int(payload[1]) << 8)
                if payload.count >= 2 + cidLen + 1,
                   let cid = String(data: payload[2..<(2 + cidLen)], encoding: .utf8) {
                    let blockData = payload[(2 + cidLen)...]
                    if blockData.isEmpty {
                        await delegate?.chainNetwork(self, didReceiveBlockAnnouncement: cid, from: peer)
                    } else {
                        await delegate?.chainNetwork(self, didReceiveBlock: cid, data: Data(blockData), from: peer)
                    }
                }
            } else if let cid = String(data: payload, encoding: .utf8) {
                await delegate?.chainNetwork(self, didReceiveBlockAnnouncement: cid, from: peer)
            }
        case "mempool-full":
            // Wire format: [cidLen: UInt16 LE][cid][bodyLen: UInt32 LE][body][tx]
            // Body is inline because HeaderImpl's Codable only emits rawCID —
            // without it, the decoded Transaction has body.node == nil and
            // TransactionValidator fails with .missingBody.
            guard payload.count >= 6 else { break }
            var bucket = mempoolGossipBuckets[peer] ?? TokenBucket(
                capacity: Self.mempoolGossipCapacity, refillPerSec: Self.mempoolGossipRefillPerSec
            )
            let admitted = bucket.tryConsume()
            mempoolGossipBuckets[peer] = bucket
            guard admitted else { break }
            let cidLen = Int(payload.withUnsafeBytes { $0.load(as: UInt16.self) })
            guard cidLen > 0, payload.count >= 2 + cidLen + 4 else { break }
            guard let cidStr = String(data: payload[2..<2+cidLen], encoding: .utf8) else { break }
            let bodyLenOffset = 2 + cidLen
            let bodyLen = Int(payload.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: bodyLenOffset, as: UInt32.self)
            })
            let bodyStart = bodyLenOffset + 4
            guard bodyLen > 0, payload.count > bodyStart + bodyLen else { break }
            let bodyData = Data(payload[bodyStart..<bodyStart+bodyLen])
            let txData = Data(payload[(bodyStart+bodyLen)...])
            // Dedup: skip if we've seen this tx CID recently
            let now = ContinuousClock.Instant.now
            if let lastSeen = recentTxCIDs[cidStr], now - lastSeen < Self.txDeduplicationWindow {
                break
            }
            guard let body = TransactionBody(data: bodyData),
                  let wireTx = Transaction(data: txData),
                  wireTx.body.rawCID == cidStr,
                  HeaderImpl<TransactionBody>(node: body).rawCID == cidStr else { break }
            let resolvedTx = Transaction(
                signatures: wireTx.signatures,
                body: HeaderImpl(rawCID: cidStr, node: body, encryptionInfo: nil)
            )
            // Delegate now owns full admission (validate + classify + insert);
            // ChainNetwork no longer calls nodeMempool directly. Pending
            // classification for receipt-blocked withdrawals must happen
            // here too so a peer's gossip doesn't bypass the classifier.
            let accepted: Bool
            if let del = delegate {
                accepted = await del.chainNetwork(self, admitTransaction: resolvedTx, bodyCID: cidStr)
            } else {
                accepted = await nodeMempool.add(transaction: resolvedTx)
            }
            if accepted {
                await storeLocally(cid: cidStr, data: bodyData)
                recentTxCIDs[cidStr] = now
                while recentTxCIDs.count > Self.maxRecentTxCIDs {
                    recentTxCIDs.removeFirst()
                }
                await ivy.broadcastMessage(topic: "mempool-full", payload: payload)
            }
        case "chainAnnounce":
            if let announce = ChainAnnounceData.deserialize(payload) {
                await delegate?.chainNetwork(self, didReceiveBlockAnnouncement: announce.tipCID, from: peer)
            }
        case "pinRequest":
            if let cid = String(data: payload, encoding: .utf8) {
                var bucket = pinRequestBuckets[peer] ?? TokenBucket(
                    capacity: Self.pinRequestCapacity, refillPerSec: Self.pinRequestRefillPerSec
                )
                let admitted = bucket.tryConsume()
                pinRequestBuckets[peer] = bucket
                if admitted {
                    await handlePinRequest(cid: cid, from: peer)
                }
            }
        default:
            break
        }
    }

    /// Accept a remote pin request: fetch the CID, store it, pin it, and announce.
    private func handlePinRequest(cid: String, from peer: PeerID) async {
        if await diskBroker.hasVolume(root: cid) {
            let fee = await ivy.config.relayFee * 2
            let expiry = UInt64(Date().timeIntervalSince1970) + 86400
            await announce(cid: cid, expiry: expiry, fee: fee)
            return
        }

        guard let data = await ivy.get(cid: cid, target: peer) else { return }

        let payload = VolumePayload(root: cid, entries: [cid: data])
        do {
            try await diskBroker.storeVolumeLocal(payload)
        } catch {
            NodeLogger("storage").error("\(directory): handlePinRequest store cid=\(String(cid.prefix(16)))… failed: \(error)")
            return
        }
        do {
            try await diskBroker.pin(root: cid, owner: directory)
        } catch {
            NodeLogger("storage").error("\(directory): handlePinRequest pin root=\(String(cid.prefix(16)))… failed: \(error)")
        }

        let fee = await ivy.config.relayFee * 2
        let expiry = UInt64(Date().timeIntervalSince1970) + 86400
        await announce(cid: cid, expiry: expiry, fee: fee)
    }

}

/// Lazy-refill token bucket. `tryConsume` returns false when starved so the
/// caller can drop the request without further work. State is updated on every
/// call; idle peers retain their full capacity until next message.
struct TokenBucket {
    var tokens: Double
    var lastRefill: ContinuousClock.Instant
    let capacity: Double
    let refillPerSec: Double

    init(capacity: Double, refillPerSec: Double) {
        self.tokens = capacity
        self.lastRefill = .now
        self.capacity = capacity
        self.refillPerSec = refillPerSec
    }

    mutating func tryConsume(_ cost: Double = 1) -> Bool {
        let now = ContinuousClock.Instant.now
        let elapsed = Double((now - lastRefill).components.seconds) +
            Double((now - lastRefill).components.attoseconds) / 1e18
        if elapsed > 0 {
            tokens = min(capacity, tokens + elapsed * refillPerSec)
            lastRefill = now
        }
        guard tokens >= cost else { return false }
        tokens -= cost
        return true
    }
}

extension Ivy {
    func setDelegate(_ delegate: IvyDelegate) {
        self.delegate = delegate
    }

    func setDataSource(_ ds: IvyDataSource) {
        self.dataSource = ds
    }
}

extension MemoryBroker {
    func setNear(_ broker: any VolumeBroker) {
        self.near = broker
    }
}

extension DiskBroker {
    func setFar(_ broker: any VolumeBroker) {
        self.far = broker
    }
}
