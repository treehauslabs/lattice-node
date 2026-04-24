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

public enum NodeError: Error, CustomStringConvertible {
    case parentChainNotFound(String)

    public var description: String {
        switch self {
        case .parentChainNotFound(let dir): return "Parent chain not found: \(dir)"
        }
    }
}

public actor LatticeNode: ChainNetworkDelegate, MinerDelegate, LatticeDelegate {
    public var config: LatticeNodeConfig
    public let lattice: Lattice
    public let genesisConfig: GenesisConfig
    public let genesisResult: GenesisResult
    var networks: [String: ChainNetwork]
    var miners: [String: MinerLoop]
    var persisters: [String: ChainStatePersister]
    var blocksSinceLastPersist: [String: UInt64]
    /// Parent chain directory for every non-nexus chain, keyed by child
    /// directory. Captured when `deployChildChain` registers a chain so the
    /// hierarchy survives restarts via the parent-hierarchy sidecar file.
    var parentDirectoryByChain: [String: String]
    var recentPeerBlocks: OrderedDictionary<String, ContinuousClock.Instant>
    var peerBlockCounts: OrderedDictionary<PeerID, (count: Int, windowStart: ContinuousClock.Instant)>
    /// CIDs currently being validated by `processBlockAndRecoverReorg`. The actor
    /// suspends during `lattice.processBlockHeader`, so a gossip echo of a block
    /// we just submitted (or just received) can re-enter while the first call is
    /// still in flight — `chain.contains` can't see it until validation finishes.
    /// Tracking in-flight CIDs here lets the re-entrant call short-circuit
    /// instead of burning ~1.5s re-validating a block that will be rejected as a
    /// duplicate anyway.
    var inFlightBlockCIDs: Set<String> = []
    // The rate limiter exists to bound validation cost from a misbehaving
    // peer; it is not meant to throttle legitimate gossip. `validateNexus`
    // costs ~25ms/block, so even 30/s is bounded (≈75% of one core). Setting
    // this below burst block-production rates silently strands catch-up sync.
    static let maxBlocksPerPeerPerWindow = 300
    static let peerRateWindow: Duration = .seconds(10)
    var syncTask: Task<Void, Never>?
    var peerRefreshTask: Task<Void, Never>?
    private var mempoolPruneTask: Task<Void, Never>?
    private var pinReannounceTask: Task<Void, Never>?
    private var storageMaintenanceTask: Task<Void, Never>?
    public var feeEstimators: [String: FeeEstimator]
    public let subscriptions: SubscriptionManager
    public let anchorPeers: AnchorPeers
    public let metrics: NodeMetrics
    public var stateStores: [String: StateStore]
    var tipCaches: [String: TipCache]
    var frontierCaches: [String: FrontierCache]
    public let nodeAddress: String
    /// Shared node-level content-addressed store — one LRU budget for all chains.
    /// Per-chain protection policies (registered in `unionProtection`) decide what
    /// survives eviction; nothing else is retention-obligated.
    public let sharedStore: ProfitWeightedStore
    /// Raw disk worker behind `sharedStore`, referenced only for `persistState` on shutdown.
    private let sharedDisk: DiskCASWorker<DefaultFileSystem>
    /// Aggregates every subscribed chain's BlockchainProtectionPolicy into one
    /// EvictionProtectionPolicy that the shared store consults on eviction.
    public let unionProtection: UnionProtectionPolicy

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

        // Shared node-level content store. One disk budget, one LRU, consulted by every chain.
        // Per-chain BlockchainProtectionPolicy registers its pins in `unionProtection`;
        // eviction asks whether any chain protects a CID before dropping it.
        let totalDiskBytes = resourcesWithIdentity.totalDiskBytes()
        let sharedCASPath = config.storagePath.appendingPathComponent("shared-cas")
        let sharedDisk = try DiskCASWorker(
            directory: sharedCASPath,
            maxBytes: totalDiskBytes
        )
        let unionProtection = UnionProtectionPolicy()
        let sharedStore = ProfitWeightedStore(
            inner: sharedDisk,
            nodePublicKey: config.publicKey,
            maxEntries: resourcesWithIdentity.maxStorageEntries,
            protectionPolicy: unionProtection
        )
        self.sharedDisk = sharedDisk
        self.sharedStore = sharedStore
        self.unionProtection = unionProtection

        let nexusProtection = BlockchainProtectionPolicy()
        await unionProtection.register(chain: genesisConfig.spec.directory, policy: nexusProtection)
        let nexusNetwork = try await ChainNetwork(
            directory: genesisConfig.spec.directory,
            config: IvyConfig(
                publicKey: config.publicKey,
                listenPort: config.listenPort,
                bootstrapPeers: config.bootstrapPeers,
                enableLocalDiscovery: config.enableLocalDiscovery
            ),
            resources: resourcesWithIdentity,
            chainCount: chainCount,
            maxPeerConnections: config.maxPeerConnections,
            sharedStore: sharedStore,
            protectionPolicy: nexusProtection
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
        await nexusNetwork.storeBlockBatch(rootCID: genesisHeader.rawCID, entries: storer.entryList)

        self.genesisResult = genesis
        let nexusLevel = ChainLevel(chain: genesis.chainState, children: [:])
        let latticeInstance = Lattice(nexus: nexusLevel)
        self.lattice = latticeInstance
        self.networks = [genesisConfig.spec.directory: nexusNetwork]
        self.miners = [:]
        self.persisters = [genesisConfig.spec.directory: persister]
        self.parentDirectoryByChain = [:]
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
            pinReannounceTask = startPinReannounceLoop(node: self)
            storageMaintenanceTask = startStorageMaintenanceLoop(node: self)
        }
    }

    public func stop() async {
        mempoolPruneTask?.cancel()
        mempoolPruneTask = nil
        pinReannounceTask?.cancel()
        pinReannounceTask = nil
        storageMaintenanceTask?.cancel()
        storageMaintenanceTask = nil
        // One last WAL checkpoint + incremental vacuum on a graceful stop so
        // the file on disk is consistent-and-compact before the process exits.
        await maintainStorage()
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
        try? await sharedDisk.persistState()
        let currentPeers = await connectedPeerEndpoints()
        let scoring = await nexusReputationScoring()
        await anchorPeers.update(peers: currentPeers, scoring: scoring)
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

    public func isMining(directory: String) async -> Bool {
        let nexusDir = genesisConfig.spec.directory
        if directory == nexusDir {
            return miners[nexusDir] != nil
        }
        guard miners[nexusDir] != nil else { return false }
        guard let path = await chainPath(for: directory) else { return false }
        return config.isSubscribed(chainPath: path)
    }

    public func registerChainNetwork(
        directory: String,
        config: IvyConfig
    ) async throws {
        guard networks[directory] == nil else { return }
        let resourcesWithIdentity = self.config.resources.withIdentity(publicKey: self.config.publicKey)
        let chainCount = max(networks.count + 1, 1)
        let chainProtection = BlockchainProtectionPolicy()
        await unionProtection.register(chain: directory, policy: chainProtection)
        let network = try await ChainNetwork(
            directory: directory,
            config: config,
            resources: resourcesWithIdentity,
            chainCount: chainCount,
            sharedStore: sharedStore,
            protectionPolicy: chainProtection
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
            let tip = await chain(for: directory)?.getMainChainTip() ?? ""
            tipCaches[directory] = TipCache(tip: tip)
        }
        if frontierCaches[directory] == nil {
            frontierCaches[directory] = FrontierCache()
        }
        try await network.start()
    }

    /// Tear down every per-chain resource registered under `directory` — stop the
    /// network, release the StateStore / persister / caches, unregister the
    /// chain's protection policy from the shared CAS, and drop any per-chain
    /// metric series. Without this, every deploy-then-destroy cycle leaks one
    /// entry in each map (UNSTOPPABLE_LATTICE P1 #14,#15).
    /// Refuses to tear down the nexus — it's load-bearing and cannot be
    /// recreated without re-initializing the node.
    public func destroyChainNetwork(directory: String) async {
        let nexusDir = genesisConfig.spec.directory
        guard directory != nexusDir else { return }
        guard let network = networks[directory] else { return }

        // Persist one last time so a subsequent redeploy can restore cleanly.
        await persistChainState(directory: directory)
        await persistMempool(directory: directory, network: network)
        await network.stop()

        networks.removeValue(forKey: directory)
        persisters.removeValue(forKey: directory)
        blocksSinceLastPersist.removeValue(forKey: directory)
        parentDirectoryByChain.removeValue(forKey: directory)
        stateStores.removeValue(forKey: directory)
        tipCaches.removeValue(forKey: directory)
        frontierCaches.removeValue(forKey: directory)
        feeEstimators.removeValue(forKey: directory)

        await unionProtection.unregister(chain: directory)

        // Per-chain Prometheus label form is {chain="<directory>"}; strip every
        // series carrying that exact label value.
        metrics.removeKeys(containing: "chain=\"\(directory)\"")

        // Drop the subscription so the nexus miner stops trying to build child
        // contexts for this directory.
        if let path = await chainPath(for: directory),
           config.isSubscribed(chainPath: path) {
            config = config.removingSubscription(chainPath: path)
        }
    }

    public func registerChainNetworkUsingNodeConfig(directory: String) async throws {
        let port = deterministicPort(basePort: self.config.listenPort, directory: directory)
        let ivyConfig = IvyConfig(
            publicKey: self.config.publicKey,
            listenPort: port,
            enableLocalDiscovery: self.config.enableLocalDiscovery
        )
        try await registerChainNetwork(directory: directory, config: ivyConfig)
    }

    // MARK: - Chain Lookup

    public func chain(for directory: String) async -> ChainState? {
        let nexusDir = genesisConfig.spec.directory
        if directory == nexusDir {
            return await lattice.nexus.chain
        }
        guard let hit = await lattice.nexus.findLevel(directory: directory, chainPath: [nexusDir]) else {
            return nil
        }
        return await hit.level.chain
    }

    /// Full chain path from nexus down to `directory`, e.g. `[nexus, child, grandchild]`.
    /// Returns nil for unknown directories.
    func chainPath(for directory: String) async -> [String]? {
        let nexusDir = genesisConfig.spec.directory
        if directory == nexusDir { return [nexusDir] }
        return await lattice.nexus.findLevel(directory: directory, chainPath: [nexusDir])?.chainPath
    }

    // MARK: - Mempool Maintenance

    public func pruneExpiredTransactions(olderThan age: Duration = .seconds(600)) async {
        for (_, network) in networks {
            await network.nodeMempool.pruneExpired(olderThan: age)
        }
    }

    /// Drop tx_history rows for foreign addresses older than `retentionBlocks`
    /// behind the chain tip. Own-address rows are always retained — startup pin
    /// rebuild (`rebuildAccountPinsFromTxHistory`) depends on them. Without
    /// this, `tx_history` grows forever on disk (UNSTOPPABLE_LATTICE P0 #4).
    public func pruneTransactionHistory(retentionBlocks: UInt64) async {
        for (dir, store) in stateStores {
            guard let chain = await chain(for: dir) else { continue }
            let height = await chain.getHighestBlockIndex()
            guard height > retentionBlocks else { continue }
            let below = height - retentionBlocks
            let removed = await store.pruneTransactionHistory(
                belowHeight: below,
                keepAddress: nodeAddress
            )
            if removed > 0 {
                NodeLogger("gc").info("Pruned \(removed) tx_history rows on \(dir) below height \(below)")
            }
        }
    }

    /// Capture a scoring closure bound to the nexus network's Tally ledger so
    /// `AnchorPeers` can evict peers that have degraded since they were
    /// promoted. Returns nil when the nexus network hasn't started yet (the
    /// caller should skip scoring in that case and accept raw endpoints).
    func nexusReputationScoring() async -> ReputationScoring? {
        let nexusDir = genesisConfig.spec.directory
        guard let network = networks[nexusDir] else { return nil }
        let tally = await network.ivy.tally
        return { endpoint in
            tally.reputation(for: PeerID(publicKey: endpoint.publicKey))
        }
    }

    /// Drop anchor peers whose Tally reputation has fallen at or below zero.
    /// Called on the same cadence as pin re-announcement so a Byzantine
    /// bootstrap peer doesn't linger across restarts (UNSTOPPABLE_LATTICE S9).
    public func demoteLowScoringAnchors() async {
        guard let scoring = await nexusReputationScoring() else { return }
        let removed = await anchorPeers.evictLowScoring(scoring: scoring)
        if removed > 0 {
            NodeLogger("anchor").info("Demoted \(removed) anchor peers below reputation floor")
        }
    }

    /// Checkpoint WAL and reclaim freelist pages on every chain's StateStore.
    /// Scheduled on a slow cadence so the per-chain SQLite file doesn't bloat
    /// across a long mining session (UNSTOPPABLE_LATTICE S7).
    public func maintainStorage() async {
        for (dir, store) in stateStores {
            await store.maintain()
            NodeLogger("gc").debug("Storage maintenance pass on \(dir)")
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
