import Lattice
import Foundation
import Ivy
import Acorn
import AcornDiskWorker
import Tally
import cashew
import UInt256
import ArrayTrie

public struct LatticeNodeConfig: Sendable {
    public let publicKey: String
    public let privateKey: String
    public let listenPort: UInt16
    public let bootstrapPeers: [PeerEndpoint]
    public let storagePath: URL
    public let enableLocalDiscovery: Bool
    public let persistInterval: UInt64
    public let subscribedChains: ArrayTrie<Bool>
    public let syncStrategy: SyncStrategy
    public let retentionDepth: UInt64
    public let resources: NodeResourceConfig

    public init(
        publicKey: String,
        privateKey: String,
        listenPort: UInt16 = 4001,
        bootstrapPeers: [PeerEndpoint] = [],
        storagePath: URL,
        enableLocalDiscovery: Bool = true,
        persistInterval: UInt64 = 100,
        subscribedChains: ArrayTrie<Bool> = {
            var t = ArrayTrie<Bool>()
            t.set(["Nexus"], value: true)
            return t
        }(),
        syncStrategy: SyncStrategy = .snapshot,
        retentionDepth: UInt64 = RECENT_BLOCK_DISTANCE,
        resources: NodeResourceConfig = .default
    ) {
        self.publicKey = publicKey
        self.privateKey = privateKey
        self.listenPort = listenPort
        self.bootstrapPeers = bootstrapPeers
        self.storagePath = storagePath
        self.enableLocalDiscovery = enableLocalDiscovery
        self.persistInterval = persistInterval
        var subs = subscribedChains
        subs.set(["Nexus"], value: true)
        self.subscribedChains = subs
        self.syncStrategy = syncStrategy
        self.retentionDepth = retentionDepth
        self.resources = resources
    }

    public func isSubscribed(chainPath: [String]) -> Bool {
        subscribedChains.get(chainPath) == true
    }
}

public actor LatticeNode: ChainNetworkDelegate, MinerDelegate, LatticeDelegate {
    public let config: LatticeNodeConfig
    public let lattice: Lattice
    public let genesisConfig: GenesisConfig
    public let genesisResult: GenesisResult
    private var networks: [String: ChainNetwork]
    private var miners: [String: MinerLoop]
    private var persisters: [String: ChainStatePersister]
    private var blocksSinceLastPersist: [String: UInt64]
    private var recentPeerBlocks: [String: ContinuousClock.Instant]
    private var syncTask: Task<Void, Never>?

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
                fetcher: nexusNetwork.fetcher
            )
            if let blockData = genesis.block.toData() {
                await nexusNetwork.storeBlock(cid: genesis.blockHash, data: blockData)
            }
        }

        self.genesisResult = genesis
        let nexusLevel = ChainLevel(chain: genesis.chainState, children: [:])
        let latticeInstance = Lattice(nexus: nexusLevel)
        self.lattice = latticeInstance
        self.networks = [genesisConfig.spec.directory: nexusNetwork]
        self.miners = [:]
        self.persisters = [genesisConfig.spec.directory: persister]
        self.blocksSinceLastPersist = [:]
        self.recentPeerBlocks = [:]
    }

    // MARK: - Lifecycle

    public func start() async throws {
        await lattice.setDelegate(self)
        for (_, network) in networks {
            await network.setDelegate(self)
            try await network.start()
        }
    }

    public func stop() async {
        syncTask?.cancel()
        syncTask = nil
        for (_, miner) in miners {
            await miner.stop()
        }
        for (dir, _) in networks {
            await persistChainState(directory: dir)
        }
        for (_, network) in networks {
            await network.stop()
        }
    }

    // MARK: - Persistence

    private func persistChainState(directory: String) async {
        guard let persister = persisters[directory] else { return }
        let nexus = await lattice.nexus
        let chainState = await nexus.chain
        let persisted = await chainState.persist()
        try? await persister.save(persisted)
        blocksSinceLastPersist[directory] = 0
    }

    private func maybePersist(directory: String) async {
        let count = (blocksSinceLastPersist[directory] ?? 0) + 1
        blocksSinceLastPersist[directory] = count
        if count >= config.persistInterval {
            await persistChainState(directory: directory)
        }
    }

    // MARK: - Sync

    public var isSyncing: Bool { syncTask != nil }

    private func checkSyncNeeded(
        peerBlockIndex: UInt64,
        peerTipCID: String,
        network: ChainNetwork
    ) async -> Bool {
        guard syncTask == nil else { return true }
        let localHeight = await lattice.nexus.chain.getHighestBlockIndex()
        let gap = peerBlockIndex > localHeight ? peerBlockIndex - localHeight : 0
        guard gap > config.retentionDepth else { return false }
        startSync(peerTipCID: peerTipCID, network: network)
        return true
    }

    private func startSync(peerTipCID: String, network: ChainNetwork) {
        syncTask = Task { [weak self] in
            guard let self = self else { return }
            await self.performSync(peerTipCID: peerTipCID, network: network)
        }
    }

    private func performSync(peerTipCID: String, network: ChainNetwork) async {
        let fetcher = await network.fetcher
        let syncer = ChainSyncer(
            fetcher: fetcher,
            store: { [network] cid, data in await network.storeBlock(cid: cid, data: data) },
            genesisBlockHash: genesisResult.blockHash,
            retentionDepth: config.retentionDepth
        )

        do {
            let result: SyncResult
            switch config.syncStrategy {
            case .full:
                result = try await syncer.syncFull(peerTipCID: peerTipCID)
            case .snapshot:
                result = try await syncer.syncSnapshot(peerTipCID: peerTipCID)
            }

            let nexusDir = genesisConfig.spec.directory
            await lattice.nexus.chain.resetFrom(
                result.persisted,
                retentionDepth: config.retentionDepth
            )
            await persistChainState(directory: nexusDir)
        } catch {
            // Sync failed — will retry on next peer block
        }

        syncTask = nil
    }

    // MARK: - Mining

    public func startMining(directory: String) async {
        guard let network = networks[directory] else { return }
        guard miners[directory] == nil else { return }

        let nexus = await lattice.nexus
        let chainState = await nexus.chain
        let identity = MinerIdentity(
            publicKeyHex: config.publicKey,
            privateKeyHex: config.privateKey
        )
        let childContexts = await buildChildMiningContexts()
        let miner = MinerLoop(
            chainState: chainState,
            mempool: network.mempool,
            fetcher: network.fetcher,
            spec: genesisConfig.spec,
            identity: identity,
            childContexts: childContexts,
            batchSize: config.resources.miningBatchSize
        )
        await miner.setDelegate(self)
        miners[directory] = miner
        await miner.start()
    }

    public func stopMining(directory: String) async {
        guard let miner = miners[directory] else { return }
        await miner.stop()
        miners.removeValue(forKey: directory)
    }

    // MARK: - MinerDelegate

    nonisolated public func minerDidProduceBlock(_ block: Block, hash: String) async {
        let directory = block.spec.node?.directory ?? "Nexus"
        await submitMinedBlock(directory: directory, block: block)
    }

    // MARK: - Transaction Submission & Mempool Gossip

    public func submitTransaction(directory: String, transaction: Transaction) async -> Bool {
        guard let network = networks[directory] else { return false }
        let added = await network.submitTransaction(transaction)
        if added {
            await network.announceBlock(cid: transaction.body.rawCID)
        }
        return added
    }

    // MARK: - Block Submission (from mining)

    public func submitMinedBlock(directory: String, block: Block) async {
        guard let network = networks[directory] else { return }
        let header = HeaderImpl<Block>(node: block)
        guard let blockData = block.toData() else { return }

        await network.storeBlock(cid: header.rawCID, data: blockData)
        await network.pinTipBlock(cid: header.rawCID, data: blockData)
        let _ = await lattice.processBlockHeader(header, fetcher: network.fetcher)
        await network.broadcastBlock(cid: header.rawCID, data: blockData)
        await maybePersist(directory: directory)
    }

    // MARK: - Block Reception (ChainNetworkDelegate) with Rate Limiting

    nonisolated public func chainNetwork(
        _ network: ChainNetwork,
        didReceiveBlock cid: String,
        data: Data
    ) async {
        let now = ContinuousClock.Instant.now
        let key = cid
        if let lastSeen = await recentBlockTime(for: key) {
            let elapsed = now - lastSeen
            if elapsed < .milliseconds(100) {
                return
            }
        }
        await recordBlockTime(key: key, time: now)

        await network.storeBlock(cid: cid, data: data)
        await network.pinTipBlock(cid: cid, data: data)

        if let block = Block(data: data) {
            if await checkSyncNeeded(
                peerBlockIndex: block.index,
                peerTipCID: cid,
                network: network
            ) {
                return
            }
        }

        let directory = await network.directory
        let header = HeaderImpl<Block>(rawCID: cid)
        let fetcher = await network.fetcher
        let _ = await lattice.processBlockHeader(header, fetcher: fetcher)
        await maybePersist(directory: directory)
    }

    nonisolated public func chainNetwork(
        _ network: ChainNetwork,
        didReceiveBlockAnnouncement cid: String
    ) async {
        let now = ContinuousClock.Instant.now
        if let lastSeen = await recentBlockTime(for: cid) {
            if now - lastSeen < .milliseconds(100) { return }
        }
        await recordBlockTime(key: cid, time: now)

        guard !(await isSyncing) else { return }

        let fetcher = await network.fetcher
        let header = HeaderImpl<Block>(rawCID: cid)

        if let block = try? await header.resolve(fetcher: fetcher).node {
            if await checkSyncNeeded(
                peerBlockIndex: block.index,
                peerTipCID: cid,
                network: network
            ) {
                return
            }
        }

        let _ = await lattice.processBlockHeader(header, fetcher: fetcher)
    }

    private func recentBlockTime(for key: String) -> ContinuousClock.Instant? {
        recentPeerBlocks[key]
    }

    private func recordBlockTime(key: String, time: ContinuousClock.Instant) {
        recentPeerBlocks[key] = time
        if recentPeerBlocks.count > 10_000 {
            let cutoff = ContinuousClock.Instant.now - .seconds(60)
            recentPeerBlocks = recentPeerBlocks.filter { $0.value > cutoff }
        }
    }

    // MARK: - LatticeDelegate (Child Chain Discovery)

    nonisolated public func lattice(_ lattice: Lattice, didDiscoverChildChain directory: String) async {
        await handleChildChainDiscovery(directory: directory)
    }

    private func handleChildChainDiscovery(directory: String) async {
        guard config.isSubscribed(chainPath: [genesisConfig.spec.directory, directory]) else { return }
        guard networks[directory] == nil else { return }
        let ivyConfig = IvyConfig(
            publicKey: config.publicKey,
            listenPort: config.listenPort,
            bootstrapPeers: config.bootstrapPeers,
            enableLocalDiscovery: config.enableLocalDiscovery
        )
        try? await registerChainNetwork(directory: directory, config: ivyConfig)
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

    public struct ChainInfo: Sendable {
        public let directory: String
        public let height: UInt64
        public let tip: String
        public let mining: Bool
        public let mempoolCount: Int
        public let syncing: Bool
    }

    public func chainStatus() async -> [ChainInfo] {
        var result: [ChainInfo] = []
        let nexusDir = genesisConfig.spec.directory
        let nexusHeight = await lattice.nexus.chain.getHighestBlockIndex()
        let nexusTip = await lattice.nexus.chain.getMainChainTip()
        let nexusMempoolCount = await networks[nexusDir]?.mempool.count ?? 0
        result.append(ChainInfo(
            directory: nexusDir, height: nexusHeight, tip: nexusTip,
            mining: miners[nexusDir] != nil, mempoolCount: nexusMempoolCount,
            syncing: isSyncing
        ))
        let childDirs = await lattice.nexus.childDirectories()
        for dir in childDirs.sorted() {
            if let childLevel = await lattice.nexus.children[dir] {
                let h = await childLevel.chain.getHighestBlockIndex()
                let t = await childLevel.chain.getMainChainTip()
                let mc = await networks[dir]?.mempool.count ?? 0
                result.append(ChainInfo(
                    directory: dir, height: h, tip: t,
                    mining: miners[dir] != nil, mempoolCount: mc,
                    syncing: false
                ))
            }
        }
        return result
    }

    public func restoreChildChains() async throws {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: config.storagePath,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        let nexusDir = genesisConfig.spec.directory
        for dir in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let dirName = dir.lastPathComponent
            guard dirName != nexusDir else { continue }
            let stateFile = dir.appendingPathComponent("chain_state.json")
            guard fm.fileExists(atPath: stateFile.path) else { continue }
            let persister = ChainStatePersister(storagePath: config.storagePath, directory: dirName)
            guard let persisted = try? await persister.load() else { continue }
            let childChain = ChainState.restore(
                from: persisted,
                retentionDepth: config.retentionDepth
            )
            let childLevel = ChainLevel(chain: childChain, children: [:])
            await lattice.nexus.restoreChildChain(directory: dirName, level: childLevel)
            persisters[dirName] = persister
        }
    }

    private func buildChildMiningContexts() async -> [ChildMiningContext] {
        var contexts: [ChildMiningContext] = []
        let nexusDir = genesisConfig.spec.directory
        let childDirs = await lattice.nexus.childDirectories()
        for dir in childDirs {
            guard config.isSubscribed(chainPath: [nexusDir, dir]) else { continue }
            guard let network = networks[dir] else { continue }
            guard let childChainState = await lattice.nexus.children[dir]?.chain else { continue }
            contexts.append(ChildMiningContext(
                directory: dir,
                chainState: childChainState,
                mempool: network.mempool,
                fetcher: network.fetcher,
                spec: genesisConfig.spec
            ))
        }
        return contexts
    }

    // MARK: - State Queries

    public func getBalance(address: String, directory: String? = nil) async throws -> UInt64 {
        let dir = directory ?? genesisConfig.spec.directory
        guard let network = networks[dir] else { return 0 }
        let chain = dir == genesisConfig.spec.directory
            ? await lattice.nexus.chain
            : await lattice.nexus.children[dir]?.chain
        guard let chain else { return 0 }
        guard let snapshot = await chain.tipSnapshot else { return 0 }
        let frontierHeader = LatticeStateHeader(rawCID: snapshot.frontierCID)
        let resolved = try await frontierHeader.resolve(fetcher: network.fetcher)
        guard let state = resolved.node else { return 0 }
        let accountResolved = try await state.accountState.resolve(fetcher: network.fetcher)
        guard let accountDict = accountResolved.node else { return 0 }
        guard let balanceStr = try? accountDict.get(key: address) else { return 0 }
        return UInt64(balanceStr) ?? 0
    }

    public func getBlock(hash: String) async throws -> Block? {
        let dir = genesisConfig.spec.directory
        guard let network = networks[dir] else { return nil }
        let header = HeaderImpl<Block>(rawCID: hash)
        return try await header.resolve(fetcher: network.fetcher).node
    }

    public func getBlockHash(atIndex index: UInt64) async -> String? {
        await lattice.nexus.chain.getMainChainBlockHash(atIndex: index)
    }

    public func getOrders() async throws -> [Order] {
        let dir = genesisConfig.spec.directory
        guard let network = networks[dir] else { return [] }
        guard let snapshot = await lattice.nexus.chain.tipSnapshot else { return [] }
        let frontierHeader = LatticeStateHeader(rawCID: snapshot.frontierCID)
        let resolved = try await frontierHeader.resolve(fetcher: network.fetcher)
        guard let state = resolved.node else { return [] }
        let generalResolved = try await state.generalState.resolve(fetcher: network.fetcher)
        guard let generalDict = generalResolved.node else { return [] }
        guard let allEntries = try? generalDict.allKeysAndValues() else { return [] }
        var orders: [Order] = []
        for (key, value) in allEntries {
            guard key.hasPrefix("order:") else { continue }
            if let order = Order.fromStateValue(value) {
                orders.append(order)
            }
        }
        return orders
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
        try await network.start()
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
