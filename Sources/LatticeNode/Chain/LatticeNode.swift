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
import OrderedCollections

public actor LatticeNode: ChainNetworkDelegate, MinerDelegate, LatticeDelegate {
    public let config: LatticeNodeConfig
    public let lattice: Lattice
    public let genesisConfig: GenesisConfig
    public let genesisResult: GenesisResult
    var networks: [String: ChainNetwork]
    var miners: [String: MinerLoop]
    var persisters: [String: ChainStatePersister]
    var blocksSinceLastPersist: [String: UInt64]
    var recentPeerBlocks: OrderedDictionary<String, ContinuousClock.Instant>
    var peerBlockCounts: OrderedDictionary<PeerID, (count: Int, windowStart: ContinuousClock.Instant)>
    static let maxBlocksPerPeerPerWindow = 20
    static let peerRateWindow: Duration = .seconds(10)
    var syncTask: Task<Void, Never>?
    var peerRefreshTask: Task<Void, Never>?
    private var mempoolPruneTask: Task<Void, Never>?
    private var gcTask: Task<Void, Never>?
    private var pinReannounceTask: Task<Void, Never>?
    public var feeEstimators: [String: FeeEstimator]
    public let subscriptions: SubscriptionManager
    public let anchorPeers: AnchorPeers
    public let metrics: NodeMetrics
    public var stateStores: [String: StateStore]
    var tipCaches: [String: TipCache]
    var frontierCaches: [String: FrontierCache]
    public let nodeAddress: String

    // MARK: - Initialization

    public typealias GenesisBuilder = (GenesisConfig, Fetcher) async throws -> Block

    public init(
        config: LatticeNodeConfig,
        genesisConfig: GenesisConfig,
        genesisBuilder: GenesisBuilder? = nil
    ) async throws {
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
            chainCount: chainCount,
            maxPeerConnections: config.maxPeerConnections
        )

        let persister = ChainStatePersister(
            storagePath: config.storagePath,
            directory: genesisConfig.spec.directory
        )
        let persisted = try? await persister.load()

        let buildGenesisBlock: (Fetcher) async throws -> Block = { fetcher in
            if let genesisBuilder {
                return try await genesisBuilder(genesisConfig, fetcher)
            }
            return try await BlockBuilder.buildGenesis(
                spec: genesisConfig.spec,
                timestamp: genesisConfig.timestamp,
                difficulty: genesisConfig.difficulty,
                fetcher: fetcher
            )
        }

        let genesis: GenesisResult
        if let persisted = persisted {
            let restoredChain = ChainState.restore(
                from: persisted,
                retentionDepth: config.retentionDepth
            )
            let initLog = NodeLogger("init")
            let restoredHeight = await restoredChain.getHighestBlockIndex()
            let restoredTipHash = await restoredChain.getMainChainTip()
            let tipBlockPresent = await restoredChain.getMainChainBlockHash(atIndex: restoredHeight) != nil
            initLog.info("Restored chain: height=\(restoredHeight) tip=\(String(restoredTipHash.prefix(16)))… tipIndexPresent=\(tipBlockPresent)")
            let genesisBlock = try await buildGenesisBlock(nexusNetwork.fetcher)
            let blockHash = VolumeImpl<Block>(node: genesisBlock).rawCID
            genesis = GenesisResult(block: genesisBlock, blockHash: blockHash, chainState: restoredChain)
        } else {
            let genesisBlock = try await buildGenesisBlock(nexusNetwork.fetcher)
            let blockHash = VolumeImpl<Block>(node: genesisBlock).rawCID
            let chainState = ChainState.fromGenesis(block: genesisBlock, retentionDepth: config.retentionDepth)
            genesis = GenesisResult(block: genesisBlock, blockHash: blockHash, chainState: chainState)
        }

        let genesisHeader = VolumeImpl<Block>(node: genesis.block)
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
        self.feeEstimators = [genesisConfig.spec.directory: FeeEstimator()]
        self.subscriptions = SubscriptionManager()
        self.anchorPeers = AnchorPeers(dataDir: config.storagePath)
        self.metrics = NodeMetrics()
        let nexusStore = try? StateStore(storagePath: config.storagePath, chain: genesisConfig.spec.directory)
        if let nexusStore {
            self.stateStores = [genesisConfig.spec.directory: nexusStore]
        } else {
            self.stateStores = [:]
        }
        let restoredTip = await genesis.chainState.getMainChainTip()
        self.tipCaches = [genesisConfig.spec.directory: TipCache(tip: restoredTip)]
        self.frontierCaches = [genesisConfig.spec.directory: FrontierCache()]
        self.nodeAddress = HeaderImpl<PublicKey>(node: PublicKey(key: config.publicKey)).rawCID
    }

    public func stateStore(for directory: String) -> StateStore? {
        stateStores[directory]
    }

    func feeEstimator(for directory: String) -> FeeEstimator {
        if let existing = feeEstimators[directory] {
            return existing
        }
        let estimator = FeeEstimator()
        feeEstimators[directory] = estimator
        return estimator
    }

    // MARK: - Lifecycle

    public func start() async throws {
        if config.bootstrapPeers.isEmpty && !config.enableLocalDiscovery {
            let log = NodeLogger("startup")
            log.warn("No bootstrap peers configured and local discovery disabled — node may not find peers")
        }
        await lattice.setDelegate(self)
        for (dir, network) in networks {
            await network.setDelegate(self)
            try await network.start()
            if !config.discoveryOnly {
                await recoverFromCAS(directory: dir)
                await backfillBlockIndex(directory: dir)
                await rebuildAccountPins(directory: dir)
                await restoreMempool(directory: dir, network: network, fetcher: network.ivyFetcher)
            }
        }
        if !config.discoveryOnly {
            mempoolPruneTask = startMempoolLoop(node: self)
            gcTask = startGarbageCollectionLoop(node: self, retentionDepth: config.retentionDepth)
            pinReannounceTask = startPinReannounceLoop(node: self)
        }
    }

    public func stop() async {
        mempoolPruneTask?.cancel()
        mempoolPruneTask = nil
        gcTask?.cancel()
        gcTask = nil
        pinReannounceTask?.cancel()
        pinReannounceTask = nil
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
            await network.persistDiskState()
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
        if tipCaches[directory] == nil {
            tipCaches[directory] = TipCache(tip: "")
        }
        if frontierCaches[directory] == nil {
            frontierCaches[directory] = FrontierCache()
        }
        try await network.start()
    }

    // MARK: - Chain Lookup

    func chain(for directory: String) async -> ChainState? {
        if directory == genesisConfig.spec.directory {
            return await lattice.nexus.chain
        } else if let childLevel = await lattice.nexus.children[directory] {
            return await childLevel.chain
        }
        return nil
    }

    // MARK: - Mempool Maintenance

    public func pruneExpiredTransactions(olderThan age: Duration = .seconds(600)) async {
        for (_, network) in networks {
            await network.nodeMempool.pruneExpired(olderThan: age)
        }
    }

    // MARK: - Pin Re-announcement

    /// Re-announce the current chain tip block and its Volume boundaries.
    /// Called periodically to keep pin announcements alive in the DHT.
    public func reannounceChainTip(directory: String) async {
        guard let network = networks[directory],
              let chain = await chain(for: directory) else { return }
        let tipCID = await chain.getMainChainTip()
        guard let data = try? await network.ivyFetcher.fetch(rawCid: tipCID) else { return }
        await network.announceStoredBlock(cid: tipCID, data: data)
    }

    // MARK: - Peer Persistence

    public func connectedPeerEndpoints(directory: String? = nil) async -> [PeerEndpoint] {
        let dir = directory ?? genesisConfig.spec.directory
        guard let network = networks[dir] else { return [] }
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
