import Lattice
import Foundation
import Ivy
import Acorn
import AcornDiskWorker
import Tally
import cashew
import UInt256
import ArrayTrie
import Crypto

public actor LatticeNode: ChainNetworkDelegate, MinerDelegate, LatticeDelegate {
    public let config: LatticeNodeConfig
    public let lattice: Lattice
    public let genesisConfig: GenesisConfig
    public let genesisResult: GenesisResult
    var networks: [String: ChainNetwork]
    var miners: [String: MinerLoop]
    var persisters: [String: ChainStatePersister]
    var blocksSinceLastPersist: [String: UInt64]
    var recentPeerBlocks: [String: ContinuousClock.Instant]
    var peerBlockCounts: [PeerID: (count: Int, windowStart: ContinuousClock.Instant)]
    static let maxBlocksPerPeerPerWindow = 20
    static let peerRateWindow: Duration = .seconds(10)
    var syncTask: Task<Void, Never>?
    var peerRefreshTask: Task<Void, Never>?
    public let feeEstimator: FeeEstimator
    public let subscriptions: SubscriptionManager
    public let anchorPeers: AnchorPeers
    public let metrics: NodeMetrics
    public var stateStores: [String: StateStore]

    // MARK: - Initialization

    public init(config: LatticeNodeConfig, genesisConfig: GenesisConfig) async throws {
        self.config = config
        self.genesisConfig = genesisConfig

        let resourcesWithIdentity = config.resources.withIdentity(publicKey: config.publicKey)
        let chainCount = max(config.subscribedChains.allValues().count, 1)
        let nexusNetwork = try await ChainNetwork(
            directory: genesisConfig.spec.directory,
            config: IvyConfig(
                publicKey: config.publicKey,
                listenPort: config.listenPort,
                bootstrapPeers: config.bootstrapPeers,
                enableLocalDiscovery: config.enableLocalDiscovery
            ),
            storagePath: config.storagePath,
            resources: resourcesWithIdentity,
            chainCount: chainCount
        )

        let persister = ChainStatePersister(
            storagePath: config.storagePath,
            directory: genesisConfig.spec.directory
        )
        let persisted = try? await persister.load()

        let genesis: GenesisResult
        if let persisted = persisted {
            let restoredChain = ChainState.restore(
                from: persisted,
                retentionDepth: config.retentionDepth
            )
            let genesisBlock = try await BlockBuilder.buildGenesis(
                spec: genesisConfig.spec,
                timestamp: genesisConfig.timestamp,
                difficulty: genesisConfig.difficulty,
                fetcher: nexusNetwork.fetcher
            )
            let blockHash = HeaderImpl<Block>(node: genesisBlock).rawCID
            genesis = GenesisResult(block: genesisBlock, blockHash: blockHash, chainState: restoredChain)
        } else {
            genesis = try await GenesisCeremony.create(
                config: genesisConfig,
                fetcher: nexusNetwork.fetcher,
                retentionDepth: config.retentionDepth
            )
        }

        let genesisHeader = HeaderImpl<Block>(node: genesis.block)
        let storer = BufferedStorer()
        do {
            try genesisHeader.storeRecursively(storer: storer)
        } catch {
            let log = NodeLogger("genesis")
            log.error("Failed to store genesis block recursively: \(error)")
        }
        await storer.flush(to: nexusNetwork)

        self.genesisResult = genesis
        let nexusLevel = ChainLevel(chain: genesis.chainState, children: [:])
        let latticeInstance = Lattice(nexus: nexusLevel)
        self.lattice = latticeInstance
        self.networks = [genesisConfig.spec.directory: nexusNetwork]
        self.miners = [:]
        self.persisters = [genesisConfig.spec.directory: persister]
        self.blocksSinceLastPersist = [:]
        self.recentPeerBlocks = [:]
        self.peerBlockCounts = [:]
        self.feeEstimator = FeeEstimator()
        self.subscriptions = SubscriptionManager()
        self.anchorPeers = AnchorPeers(dataDir: config.storagePath)
        self.metrics = NodeMetrics()
        let nexusStore = try? StateStore(storagePath: config.storagePath, chain: genesisConfig.spec.directory)
        if let nexusStore {
            self.stateStores = [genesisConfig.spec.directory: nexusStore]
        } else {
            self.stateStores = [:]
        }
    }

    public func stateStore(for directory: String) -> StateStore? {
        stateStores[directory]
    }

    // MARK: - Lifecycle

    public func start() async throws {
        await lattice.setDelegate(self)
        for (dir, network) in networks {
            await network.setDelegate(self)
            try await network.start()
            await restoreMempool(directory: dir, network: network, fetcher: network.ivyFetcher)
        }
    }

    public func stop() async {
        peerRefreshTask?.cancel()
        peerRefreshTask = nil
        syncTask?.cancel()
        syncTask = nil
        for (_, miner) in miners {
            await miner.stop()
        }
        for (dir, network) in networks {
            await persistChainState(directory: dir)
            await persistMempool(directory: dir, network: network)
        }
        let currentPeers = await connectedPeerEndpoints()
        await anchorPeers.update(peers: currentPeers)
        for (_, network) in networks {
            await network.stop()
        }
    }

    // MARK: - Chain Network Management

    public func network(for directory: String) -> ChainNetwork? {
        networks[directory]
    }

    public func allDirectories() -> [String] {
        Array(networks.keys.sorted())
    }

    public func isMining(directory: String) -> Bool {
        miners[directory] != nil
    }

    public func registerChainNetwork(
        directory: String,
        config: IvyConfig
    ) async throws {
        guard networks[directory] == nil else { return }
        let resourcesWithIdentity = self.config.resources.withIdentity(publicKey: self.config.publicKey)
        let chainCount = max(networks.count + 1, 1)
        let network = try await ChainNetwork(
            directory: directory,
            config: config,
            storagePath: self.config.storagePath,
            resources: resourcesWithIdentity,
            chainCount: chainCount
        )
        await network.setDelegate(self)
        networks[directory] = network
        persisters[directory] = ChainStatePersister(
            storagePath: self.config.storagePath,
            directory: directory
        )
        if stateStores[directory] == nil {
            if let store = try? StateStore(storagePath: self.config.storagePath, chain: directory) {
                stateStores[directory] = store
            }
        }
        try await network.start()
    }

    // MARK: - Mempool Maintenance

    public func pruneExpiredTransactions(olderThan age: Duration = .seconds(600)) async {
        for (_, network) in networks {
            await network.nodeMempool.pruneExpired(olderThan: age)
        }
    }

    // MARK: - Peer Persistence

    public func connectedPeerEndpoints() async -> [PeerEndpoint] {
        let nexusDir = genesisConfig.spec.directory
        guard let network = networks[nexusDir] else { return [] }
        let entries = await network.ivy.router.allPeers()
        return entries.map { $0.endpoint }
    }
}

extension MinerLoop {
    func setDelegate(_ delegate: MinerDelegate) {
        self.delegate = delegate
    }
}

extension ChainNetwork {
    public func setDelegate(_ delegate: ChainNetworkDelegate) {
        self.delegate = delegate
    }
}
