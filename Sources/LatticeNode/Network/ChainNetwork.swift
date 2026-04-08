import Lattice
import Foundation
import Ivy
import Acorn
import AcornDiskWorker
import AcornMemoryWorker
import Tally
import cashew
import UInt256

public protocol ChainNetworkDelegate: AnyObject, Sendable {
    func chainNetwork(_ network: ChainNetwork, didReceiveBlock cid: String, data: Data, from peer: PeerID) async
    func chainNetwork(_ network: ChainNetwork, didReceiveBlockAnnouncement cid: String, from peer: PeerID) async
}

public actor ChainNetwork: IvyDelegate {
    public let directory: String
    public let ivy: Ivy
    public let ivyFetcher: IvyFetcher
    public let nodeMempool: NodeMempool
    public let verifiedStore: VerifiedDistanceStore
    public let protectionPolicy: BlockchainProtectionPolicy
    private let localCAS: any AcornCASWorker
    private let resources: NodeResourceConfig
    public weak var delegate: ChainNetworkDelegate?
    private var subscribedChains: Set<String>

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
        let verified = VerifiedDistanceStore(
            inner: disk,
            nodePublicKey: config.publicKey,
            maxEntries: max(diskBytes / 4096, 1000),
            protectionPolicy: policy
        )
        self.verifiedStore = verified

        // Local CAS: memory + disk (no network worker — reads go through IvyFetcher)
        let local = await CompositeCASWorker(
            workers: ["mem": memory, "disk": verified],
            order: ["mem", "disk"]
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
        await verifiedStore.storeVerified(cid: ContentIdentifier(rawValue: cid), data: data)
        await ivy.save(cid: cid, data: data, pin: true)
    }

    /// Store data locally only (no network publish).
    public func storeLocally(cid: String, data: Data) async {
        let contentId = ContentIdentifier(rawValue: cid)
        await localCAS.store(cid: contentId, data: data)
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
    /// This makes state, transactions, and child blocks independently discoverable.
    private func announceVolumeBoundaries(block: Block) async {
        let fee = await ivy.config.relayFee * 3
        let expiry = UInt64(Date().timeIntervalSince1970) + 86400

        // State trees (most important for light client queries)
        let frontierCID = block.frontier.rawCID
        if !frontierCID.isEmpty {
            await ivy.publishPinAnnounce(rootCID: frontierCID, selector: "/", expiry: expiry, signature: Data(), fee: fee)
        }
        let homesteadCID = block.homestead.rawCID
        if !homesteadCID.isEmpty {
            await ivy.publishPinAnnounce(rootCID: homesteadCID, selector: "/", expiry: expiry, signature: Data(), fee: fee)
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

    // MARK: - Gossip

    /// Gossip a block announcement to all direct peers via peerMessage
    public func gossipBlockAnnouncement(cid: String) async {
        if let payload = cid.data(using: .utf8) {
            await ivy.broadcastMessage(topic: "newBlock", payload: payload)
        }
    }

    /// Gossip a transaction CID to all direct peers via peerMessage
    public func gossipTransaction(cid: String) async {
        if let payload = cid.data(using: .utf8) {
            await ivy.broadcastMessage(topic: "mempool", payload: payload)
        }
    }

    // MARK: - IvyDelegate

    nonisolated public func ivy(_ ivy: Ivy, didConnect peer: PeerID) {}
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
        case "mempool":
            if let txCID = String(data: payload, encoding: .utf8) {
                if let txData = try? await ivyFetcher.fetch(rawCid: txCID) {
                    if let tx = Transaction(data: txData) {
                        _ = await nodeMempool.add(transaction: tx)
                    }
                }
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
