import Lattice
import Foundation
import Ivy
import Acorn
import AcornDiskWorker
import AcornMemoryWorker
import Tally
import cashew
import UInt256
import OrderedCollections

public protocol ChainNetworkDelegate: AnyObject, Sendable {
    func chainNetwork(_ network: ChainNetwork, didReceiveBlock cid: String, data: Data, from peer: PeerID) async
    func chainNetwork(_ network: ChainNetwork, didReceiveBlockAnnouncement cid: String, from peer: PeerID) async
    func chainNetwork(_ network: ChainNetwork, shouldAcceptTransaction transaction: Transaction, bodyCID: String) async -> Bool
    func chainNetwork(_ network: ChainNetwork, didConnectPeer peer: PeerID) async
}

public actor ChainNetwork: IvyDelegate {
    public let directory: String
    public let ivy: Ivy
    public let ivyFetcher: IvyFetcher
    public let nodeMempool: NodeMempool
    /// Shared node-level content-addressed store (one LRU across all chains).
    /// Owned by LatticeNode; every ChainNetwork references the same instance.
    public let sharedStore: ProfitWeightedStore
    public let protectionPolicy: BlockchainProtectionPolicy
    let localCAS: any AcornCASWorker
    private let resources: NodeResourceConfig
    public weak var delegate: ChainNetworkDelegate?
    private var subscribedChains: Set<String>
    private var recentTxCIDs: OrderedDictionary<String, ContinuousClock.Instant> = [:]
    private static let maxRecentTxCIDs = 8192
    private static let txDeduplicationWindow: Duration = .seconds(60)

    /// CIDs known to be in CAS from the most recent block stores on this chain.
    /// Used as a skipSet for BufferedStorer so structurally-shared merkle nodes
    /// don't get re-serialized and re-batched on every block. Bounded so it
    /// can't grow without limit across a long mining session.
    private var lastStoredCIDs: Set<String> = []
    private static let maxLastStoredCIDs = 200_000

    public init(
        directory: String,
        config: IvyConfig,
        resources: NodeResourceConfig = .default,
        chainCount: Int = 1,
        maxPeerConnections: Int = BootstrapPeers.maxPeerConnections,
        sharedStore: ProfitWeightedStore,
        protectionPolicy: BlockchainProtectionPolicy
    ) async throws {
        self.directory = directory
        self.subscribedChains = Set([directory])
        self.resources = resources
        self.sharedStore = sharedStore
        self.protectionPolicy = protectionPolicy
        let mempoolSize = resources.mempoolSizePerChain(chainCount: chainCount)
        self.nodeMempool = NodeMempool(maxSize: mempoolSize)

        let memoryBytes = resources.memoryBytesPerChain(chainCount: chainCount)
        let memoryEntries = max(memoryBytes / 4096, 100)
        let memory = MemoryCASWorker(
            capacity: memoryEntries,
            maxBytes: memoryBytes
        )

        // Local CAS: per-chain memory cache in front of the shared node-level store.
        // Reads consult memory first, then the shared LRU-backed disk. Ivy can serve
        // from either — every subscribed chain's protection policy contributes to
        // what stays resident in the shared store.
        let local = await CompositeCASWorker(
            workers: ["mem": memory, "shared": sharedStore],
            order: ["mem", "shared"]
        )
        self.localCAS = local

        let tallyWithMaxPeers = TallyConfig(maxPeers: maxPeerConnections)
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
            signingKey: config.signingKey
        )
        let ivy = Ivy(config: ivyConfig)

        // Connect Ivy's internal worker to the local CAS so it can serve
        // sub-node data (state trie entries, tx bodies, radix nodes) to
        // remote peers via fee-based dhtForward.
        let ivyWorker = await ivy.worker()
        await ivyWorker.setNear(local)

        self.ivy = ivy
        self.ivyFetcher = IvyFetcher(ivy: ivy, localWorker: local)
    }

    public func start() async throws {
        await ivy.setDelegate(self)
        try await ivy.start()
    }

    public func stop() async {
        await ivy.stop()
    }

    // MARK: - Fetcher (unified read path)

    /// Volume-aware fetcher for all Cashew resolution: state, blocks, proofs.
    /// Local cache first, then Ivy's fee-based DHT.
    public var fetcher: IvyFetcher { ivyFetcher }

    // MARK: - Store (unified write path)

    /// Store data locally and publish to the network via Ivy.
    public func storeAndPublish(cid: String, data: Data) async {
        await protectionPolicy.pin(cid)
        await sharedStore.storeVerified(cid: ContentIdentifier(rawValue: cid), data: data)
        await ivy.save(cid: cid, data: data, pin: true)
    }

    /// Store data locally only (no network publish).
    public func storeLocally(cid: String, data: Data) async {
        let contentId = ContentIdentifier(rawValue: cid)
        await localCAS.store(cid: contentId, data: data)
    }

    public func storeBatch(_ entries: [(String, Data)]) async {
        guard !entries.isEmpty else { return }
        let mapped: [(ContentIdentifier, Data)] = entries.map {
            (ContentIdentifier(rawValue: $0.0), $0.1)
        }
        await localCAS.storeLocalBatch(mapped)
    }

    /// Store a batch that comprises a single Volume's merkle subtree and
    /// register its members with the shared store so volume-granularity
    /// eviction can pick the whole group as a unit.
    public func storeBlockBatch(rootCID: String, entries: [(String, Data)]) async {
        await storeBatch(entries)
        guard !rootCID.isEmpty else { return }
        let memberCIDs = entries.map(\.0)
        await sharedStore.registerVolume(rootCID: rootCID, childCIDs: memberCIDs)
    }

    /// Snapshot the set of CIDs known to be resident in CAS from recent stores.
    /// Callers pass this into BufferedStorer so the merkle walk short-circuits
    /// on already-written subtrees instead of re-serializing them.
    public func snapshotLastStoredCIDs() -> Set<String> {
        lastStoredCIDs
    }

    /// Update the last-stored set after a successful block walk + batch store.
    /// Capped so a long-running miner can't grow this set without bound.
    public func updateLastStoredCIDs(_ cids: Set<String>) {
        if cids.count >= Self.maxLastStoredCIDs {
            // The new walk alone exceeds the cap — keep only the new set,
            // trimmed. We don't care which subset we keep since the next block
            // will refill it from its own walk.
            lastStoredCIDs = Set(cids.prefix(Self.maxLastStoredCIDs))
            return
        }
        lastStoredCIDs = cids
    }

    // MARK: - Block Operations (backward compat aliases)

    public func publishBlock(cid: String, data: Data) async {
        await storeAndPublish(cid: cid, data: data)

        // Announce Volume sub-tree roots so peers can discover and fetch sub-trees independently.
        // Light clients query state CIDs, not block CIDs — they need to find pinners for state.
        if let block = Block(data: data) {
            await announceVolumeBoundaries(block: block)
        }
    }

    /// Publish pin announcements for each Volume boundary root in the block.
    /// Each announcement includes a selector describing what subtree the pin covers.
    /// Light clients can discover pinners for specific subtrees (e.g., /accountState).
    private func announceVolumeBoundaries(block: Block) async {
        let fee = await ivy.config.relayFee * 3
        let expiry = UInt64(Date().timeIntervalSince1970) + 86400

        // State trees — full nodes announce "/" (entire state), also specific subtrees
        let frontierCID = block.frontier.rawCID
        if !frontierCID.isEmpty {
            await ivy.publishPinAnnounce(rootCID: frontierCID, selector: "/", expiry: expiry, signature: Data(), fee: fee)
            await ivy.publishPinAnnounce(rootCID: frontierCID, selector: "/accountState", expiry: expiry, signature: Data(), fee: fee)
            await ivy.publishPinAnnounce(rootCID: frontierCID, selector: "/generalState", expiry: expiry, signature: Data(), fee: fee)
        }
        let homesteadCID = block.homestead.rawCID
        if !homesteadCID.isEmpty {
            await ivy.publishPinAnnounce(rootCID: homesteadCID, selector: "/accountState", expiry: expiry, signature: Data(), fee: fee)
        }

        // Transaction tree
        let txCID = block.transactions.rawCID
        if !txCID.isEmpty {
            await ivy.publishPinAnnounce(rootCID: txCID, selector: "/", expiry: expiry, signature: Data(), fee: fee)
        }

        // Child blocks
        let childCID = block.childBlocks.rawCID
        if !childCID.isEmpty {
            await ivy.publishPinAnnounce(rootCID: childCID, selector: "/", expiry: expiry, signature: Data(), fee: fee)
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
        await ivy.publishPinAnnounce(rootCID: cid, selector: "/", expiry: expiry, signature: Data(), fee: fee)

        // Announce Volume boundaries so state/tx subtrees are discoverable
        if let block = Block(data: data) {
            let frontierCID = block.frontier.rawCID
            if !frontierCID.isEmpty {
                await ivy.publishPinAnnounce(rootCID: frontierCID, selector: "/", expiry: expiry, signature: Data(), fee: fee)
            }
            let txCID = block.transactions.rawCID
            if !txCID.isEmpty {
                await ivy.publishPinAnnounce(rootCID: txCID, selector: "/", expiry: expiry, signature: Data(), fee: fee)
            }
        }
    }

    // MARK: - Chain Tip Management

    /// Register the tip of this chain for eviction protection.
    /// `stateRoots` should contain the Volume boundaries that must remain resolvable
    /// to answer queries at this tip (frontier, homestead, tx, childBlocks).
    /// The tip block itself is added to both the state-root set (permanent while
    /// subscribed) and the recent-blocks set (TTL-protected for reorg safety).
    public func setChainTip(tipCID: String, stateRoots: [String]) async {
        await protectionPolicy.setStateRoots(chain: directory, roots: stateRoots + [tipCID])
        await protectionPolicy.addRecentBlock(tipCID)
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

    // MARK: - Storage Advertising

    /// Available storage capacity: unused headroom in the shared node-level disk budget.
    /// Per-chain protection pins occupy space; evictable LRU entries count as free.
    public var availableStorageCapacity: Int {
        get async {
            let total = resources.totalDiskBytes()
            let used = await sharedStore.entryCount * 4096  // ~4KB avg entry size
            return Swift.max(total - used, 0)
        }
    }

    /// Broadcast available storage capacity so peers discover us as a pinner.
    public func advertiseStorage() async {
        let capacity = await availableStorageCapacity
        guard capacity > 0 else { return }
        var payload = Data()
        var cap = UInt32(min(capacity, Int(UInt32.max)))
        payload.append(Data(bytes: &cap, count: 4))
        await ivy.broadcastMessage(topic: "storage", payload: payload)
    }

    /// Accept a remote pin request: fetch the CID, store it in the shared store,
    /// pin it via this chain's protection policy, and announce.
    /// Earning pins ride on the same LRU as blockchain data — they compete on merit;
    /// unpinned / unprofitable entries age out naturally.
    private func handlePinRequest(cid: String, from peer: PeerID) async {
        let cidObj = ContentIdentifier(rawValue: cid)
        if await localCAS.has(cid: cidObj) {
            let fee = await ivy.config.relayFee * 2
            let expiry = UInt64(Date().timeIntervalSince1970) + 86400
            await ivy.publishPinAnnounce(rootCID: cid, selector: "/", expiry: expiry, signature: Data(), fee: fee)
            return
        }

        guard let data = await ivy.get(cid: cid, target: peer) else { return }

        await protectionPolicy.pin(cid)
        await sharedStore.storeVerified(cid: cidObj, data: data)

        let fee = await ivy.config.relayFee * 2
        let expiry = UInt64(Date().timeIntervalSince1970) + 86400
        await ivy.publishPinAnnounce(rootCID: cid, selector: "/", expiry: expiry, signature: Data(), fee: fee)
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
            if let cid = String(data: payload, encoding: .utf8) {
                await delegate?.chainNetwork(self, didReceiveBlockAnnouncement: cid, from: peer)
            }
        case "mempool-full":
            // Wire format: [cidLen: UInt16 LE][cid][bodyLen: UInt32 LE][body][tx]
            // Body is inline because HeaderImpl's Codable only emits rawCID —
            // without it, the decoded Transaction has body.node == nil and
            // TransactionValidator fails with .missingBody.
            guard payload.count >= 6 else { break }
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
            if let del = delegate, !(await del.chainNetwork(self, shouldAcceptTransaction: resolvedTx, bodyCID: cidStr)) {
                break
            }
            await storeLocally(cid: cidStr, data: bodyData)
            let accepted = await nodeMempool.add(transaction: resolvedTx)
            if accepted {
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
                await handlePinRequest(cid: cid, from: peer)
            }
        default:
            break
        }
    }

}

extension Ivy {
    func setDelegate(_ delegate: IvyDelegate) {
        self.delegate = delegate
    }
}
