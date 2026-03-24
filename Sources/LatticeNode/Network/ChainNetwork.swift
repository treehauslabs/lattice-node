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
    public let fetcher: AcornFetcher
    public let nodeMempool: NodeMempool
    private let storage: any AcornCASWorker
    private let memoryWorker: MemoryCASWorker
    public let verifiedStore: VerifiedDistanceStore
    public let protectionPolicy: BlockchainProtectionPolicy
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
        self.memoryWorker = memory

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

        var ivyConfig = config
        let tallyWithMaxPeers = TallyConfig(maxPeers: maxPeerConnections)
        ivyConfig = IvyConfig(
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
            enableRelay: config.enableRelay,
            enableAutoNAT: config.enableAutoNAT,
            enableHolePunch: config.enableHolePunch,
            stunServers: config.stunServers,
            enableTransport: config.enableTransport,
            enableAnnounce: config.enableAnnounce,
            announceInterval: config.announceInterval,
            announceAppName: config.announceAppName,
            udpPort: config.udpPort,
            enableUDP: config.enableUDP,
            signingKey: config.signingKey,
            defaultTTL: config.defaultTTL,
            healthConfig: config.healthConfig
        )
        let ivy = Ivy(config: ivyConfig)
        let network = await ivy.reticulumWorker()

        let composite = await CompositeCASWorker(
            workers: ["mem": memory, "disk": verified, "net": network],
            order: ["mem", "disk", "net"]
        )

        self.ivy = ivy
        self.storage = composite
        self.fetcher = AcornFetcher(worker: composite)
    }

    public func start() async throws {
        await ivy.setDelegate(self)
        try await ivy.start()
    }

    public func stop() async {
        await ivy.stop()
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

    // MARK: - Block Operations

    public func publishBlock(cid: String, data: Data) async {
        await protectionPolicy.pin(cid)
        await verifiedStore.storeVerified(cid: ContentIdentifier(rawValue: cid), data: data)
        await ivy.publishBlock(cid: cid, data: data)
    }

    public func announceBlock(cid: String) async {
        await ivy.announceBlock(cid: cid)
    }

    public func storeBlock(cid: String, data: Data) async {
        await fetcher.store(rawCid: cid, data: data)
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

    // MARK: - IvyDelegate

    nonisolated public func ivy(_ ivy: Ivy, didConnect peer: PeerID) {}
    nonisolated public func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {}

    nonisolated public func ivy(_ ivy: Ivy, didReceiveBlockAnnouncement cid: String, from peer: PeerID) {
        Task { await delegate?.chainNetwork(self, didReceiveBlockAnnouncement: cid, from: peer) }
    }

    nonisolated public func ivy(_ ivy: Ivy, didReceiveBlock cid: String, data: Data, from peer: PeerID) {
        Task { await delegate?.chainNetwork(self, didReceiveBlock: cid, data: data, from: peer) }
    }
}

extension Ivy {
    func setDelegate(_ delegate: IvyDelegate) {
        self.delegate = delegate
    }
}
