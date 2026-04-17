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
    public let verifiedStore: ProfitWeightedStore
    public let protectionPolicy: BlockchainProtectionPolicy
    private let localCAS: any AcornCASWorker
    /// Raw disk worker reference for persisting state on shutdown.
    private let diskStore: DiskCASWorker<DefaultFileSystem>
    /// Separate store for earning pins — LFU eviction keeps profitable data.
    /// Not distance-based; stores whatever peers request us to pin.
    private let pinStore: DiskCASWorker<DefaultFileSystem>
    private let resources: NodeResourceConfig
    public weak var delegate: ChainNetworkDelegate?
    private var subscribedChains: Set<String>
    private var recentTxCIDs: OrderedDictionary<String, ContinuousClock.Instant> = [:]
    private static let maxRecentTxCIDs = 8192
    private static let txDeduplicationWindow: Duration = .seconds(60)

    public init(
        directory: String,
        config: IvyConfig,
        storagePath: URL,
        resources: NodeResourceConfig = .default,
        chainCount: Int = 1,
        maxPeerConnections: Int = BootstrapPeers.maxPeerConnections
    ) async throws {
        self.directory = directory
        self.subscribedChains = Set([directory])
        self.resources = resources
        let mempoolSize = resources.mempoolSizePerChain(chainCount: chainCount)
        self.nodeMempool = NodeMempool(maxSize: mempoolSize)

        let memoryBytes = resources.memoryBytesPerChain(chainCount: chainCount)
        let memoryEntries = max(memoryBytes / 4096, 100)
        let memory = MemoryCASWorker(
            capacity: memoryEntries,
            maxBytes: memoryBytes
        )

        let diskBytes = resources.diskBytesPerChain(chainCount: chainCount)
        let disk = try DiskCASWorker(
            directory: storagePath.appendingPathComponent(directory),
            maxBytes: diskBytes
        )

        let policy = BlockchainProtectionPolicy()
        self.protectionPolicy = policy
        let verified = ProfitWeightedStore(
            inner: disk,
            nodePublicKey: config.publicKey,
            maxEntries: max(diskBytes / 4096, 1000),
            protectionPolicy: policy
        )
        self.verifiedStore = verified
        self.diskStore = disk

        // Earning pin store: LFU eviction keeps frequently-requested (profitable) data.
        // Separate from blockchain data — stores whatever maximizes serving revenue.
        let pinDiskBytes = diskBytes / 4
        let pinDisk = try DiskCASWorker(
            directory: storagePath.appendingPathComponent(directory).appendingPathComponent("pins"),
            maxBytes: pinDiskBytes
        )
        self.pinStore = pinDisk

        // Local CAS: memory + blockchain disk + pin disk
        // Reads check all three; Ivy can serve from any.
        let local = await CompositeCASWorker(
            workers: ["mem": memory, "disk": verified, "pins": pinDisk],
            order: ["mem", "disk", "pins"]
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

    public func persistDiskState() async {
        try? await diskStore.persistState()
        try? await pinStore.persistState()
    }

    // MARK: - Fetcher (unified read path)

    /// Volume-aware fetcher for all Cashew resolution: state, blocks, proofs.
    /// Local cache first, then Ivy's fee-based DHT.
    public var fetcher: IvyFetcher { ivyFetcher }

    // MARK: - Store (unified write path)

    /// Store data locally and publish to the network via Ivy.
    public func storeAndPublish(cid: String, data: Data) async {
        await protectionPolicy.pin(cid)
        await verifiedStore.storeVerified(cid: ContentIdentifier(rawValue: cid), data: data)
        await ivy.save(cid: cid, data: data, pin: true)
    }

    /// Store data locally only (no network publish).
    public func storeLocally(cid: String, data: Data) async {
        let contentId = ContentIdentifier(rawValue: cid)
        await localCAS.store(cid: contentId, data: data)
    }

    public func storeBatch(_ entries: [(String, Data)]) async {
        for (cid, data) in entries {
            let contentId = ContentIdentifier(rawValue: cid)
            await localCAS.store(cid: contentId, data: data)
        }
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

    public func setChainTip(tipCID: String, referencedCIDs: [String]) async {
        await protectionPolicy.setChainTip(chain: directory, tipCID: tipCID, referencedCIDs: referencedCIDs)
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

    /// Available pin storage capacity based on the earning pin store's disk budget.
    public var availableStorageCapacity: Int {
        get async {
            let diskBytes = resources.diskBytesPerChain(chainCount: 1) / 4
            let usedBytes = await pinStore.totalBytes
            return Swift.max(diskBytes - usedBytes, 0)
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

    /// Accept a remote pin request: fetch the CID, store it in the earning pin store, announce it.
    /// The pin store uses LFU eviction — unprofitable data gets replaced by profitable data naturally.
    private func handlePinRequest(cid: String, from peer: PeerID) async {
        // Already have it locally? Just announce.
        let cidObj = ContentIdentifier(rawValue: cid)
        if await localCAS.has(cid: cidObj) {
            let fee = await ivy.config.relayFee * 2
            let expiry = UInt64(Date().timeIntervalSince1970) + 86400
            await ivy.publishPinAnnounce(rootCID: cid, selector: "/", expiry: expiry, signature: Data(), fee: fee)
            return
        }

        // Fetch from the requesting peer (targeted, one hop)
        guard let data = await ivy.get(cid: cid, target: peer) else { return }

        // Store in the earning pin store (LFU eviction, not distance-based)
        await pinStore.storeLocal(cid: cidObj, data: data)

        // Announce so peers discover us
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

    /// Gossip a transaction to all direct peers with full transaction data.
    /// Includes the complete signed transaction so receivers can add it to their mempool.
    public func gossipTransaction(cid: String, transactionData: Data? = nil) async {
        if let txData = transactionData {
            // Send body CID + full transaction: [2-byte cid length][cid bytes][tx bytes]
            var payload = Data()
            let cidBytes = Data(cid.utf8)
            var cidLen = UInt16(cidBytes.count)
            payload.append(Data(bytes: &cidLen, count: 2))
            payload.append(cidBytes)
            payload.append(txData)
            await ivy.broadcastMessage(topic: "mempool-full", payload: payload)
        } else {
            // Fallback: CID-only gossip (receiver must fetch)
            if let payload = cid.data(using: .utf8) {
                await ivy.broadcastMessage(topic: "mempool", payload: payload)
            }
        }
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
            // Full transaction gossip: [2-byte cid length][cid bytes][transaction bytes]
            guard payload.count > 2 else { break }
            let cidLen = Int(payload.withUnsafeBytes { $0.load(as: UInt16.self) })
            guard payload.count >= 2 + cidLen else { break }
            let cidStr = String(data: payload[2..<2+cidLen], encoding: .utf8) ?? ""
            // Dedup: skip if we've seen this tx CID recently
            let now = ContinuousClock.Instant.now
            if let lastSeen = recentTxCIDs[cidStr], now - lastSeen < Self.txDeduplicationWindow {
                break
            }
            recentTxCIDs.removeValue(forKey: cidStr)
            recentTxCIDs[cidStr] = now
            while recentTxCIDs.count > Self.maxRecentTxCIDs {
                recentTxCIDs.removeFirst()
            }
            let txData = Data(payload[(2+cidLen)...])
            if let tx = Transaction(data: txData) {
                if tx.body.rawCID == cidStr {
                    // Validate before mempool admission
                    if let del = delegate, !(await del.chainNetwork(self, shouldAcceptTransaction: tx, bodyCID: cidStr)) {
                        break
                    }
                    if let bodyNode = tx.body.node, let bodyData = bodyNode.toData() {
                        await storeLocally(cid: cidStr, data: bodyData)
                    }
                    let accepted = await nodeMempool.add(transaction: tx)
                    if accepted {
                        await ivy.broadcastMessage(topic: "mempool-full", payload: payload)
                    }
                }
            }
        case "mempool":
            // Legacy CID-only gossip (fallback)
            if let txCID = String(data: payload, encoding: .utf8) {
                let mNow = ContinuousClock.Instant.now
                if let lastSeen = recentTxCIDs[txCID], mNow - lastSeen < Self.txDeduplicationWindow {
                    break
                }
                recentTxCIDs.removeValue(forKey: txCID)
                recentTxCIDs[txCID] = mNow
                if let txData = try? await ivyFetcher.fetch(rawCid: txCID) {
                    if let tx = Transaction(data: txData) {
                        _ = await nodeMempool.add(transaction: tx)
                    }
                }
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
