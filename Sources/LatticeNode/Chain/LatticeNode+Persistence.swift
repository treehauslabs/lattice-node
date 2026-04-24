import Lattice
import Foundation
import cashew
import Ivy

extension LatticeNode {

    func persistChainState(directory: String) async {
        guard let persister = persisters[directory],
              let chainState = await chain(for: directory) else { return }
        let persisted = await chainState.persist()
        do {
            try await persister.save(persisted)
        } catch {
            let log = NodeLogger("persistence")
            log.error("Failed to persist chain state for \(directory): \(error)")
        }
        blocksSinceLastPersist[directory] = 0
    }

    func maybePersist(directory: String) async {
        let count = (blocksSinceLastPersist[directory] ?? 0) + 1
        blocksSinceLastPersist[directory] = count
        if count >= config.persistInterval {
            await persistChainState(directory: directory)
        }
    }

    // MARK: - Mempool Persistence

    func persistMempool(directory: String, network: ChainNetwork) async {
        let persistence = MempoolPersistence(dataDir: config.storagePath.appendingPathComponent(directory))
        let txs = await network.allMempoolTransactions()
        do {
            try persistence.save(transactions: txs)
        } catch {
            let log = NodeLogger("persistence")
            log.error("Failed to persist mempool for \(directory): \(error)")
        }
    }

    func restoreMempool(directory: String, network: ChainNetwork, fetcher: Fetcher) async {
        let persistence = MempoolPersistence(dataDir: config.storagePath.appendingPathComponent(directory))
        let serialized = persistence.load()
        guard !serialized.isEmpty else { return }
        var restored = 0
        for stx in serialized {
            let bodyHeader = HeaderImpl<TransactionBody>(rawCID: stx.bodyCID)
            guard let body = try? await bodyHeader.resolve(fetcher: fetcher).node else { continue }
            let tx = Transaction(signatures: stx.signatures, body: bodyHeader)
            if let sender = body.signers.first,
               let tipNonce = try? await getNonce(address: sender, directory: directory) {
                await network.nodeMempool.seedConfirmedNonceIfUnset(sender: sender, nonce: tipNonce)
            }
            if await network.submitTransaction(tx) {
                restored += 1
            }
        }
        if restored > 0 {
            let log = NodeLogger("persistence")
            log.info("\(directory): restored \(restored) mempool transaction(s)")
        }
        persistence.delete()
    }

    // MARK: - CAS-Based Chain Recovery

    /// Recover chain state from CAS after an ungraceful shutdown.
    /// The StateStore (SQLite) is crash-safe and tracks the real tip.
    /// If it's ahead of the chain state (which is persisted periodically),
    /// walk backwards through CAS from the SQLite tip to the chain state tip,
    /// then replay those blocks forward to catch up.
    func recoverFromCAS(directory: String) async {
        let log = NodeLogger("recovery")
        guard let store = stateStores[directory],
              let network = networks[directory],
              let chainState = await chain(for: directory) else { return }

        let chainTipCID = await chainState.getMainChainTip()
        let chainHeight = await chainState.getHighestBlockIndex()

        guard let sqliteTipCID = store.getChainTip(),
              let sqliteHeight = store.getHeight() else { return }

        guard sqliteHeight > chainHeight, sqliteTipCID != chainTipCID else { return }

        log.info("\(directory): chain state at height \(chainHeight), SQLite at \(sqliteHeight) — recovering \(sqliteHeight - chainHeight) block(s) from CAS")

        // Walk backwards from the SQLite tip through CAS to collect missing blocks
        let fetcher = network.ivyFetcher
        var blocksToReplay: [(cid: String, block: Block)] = []
        var currentCID = sqliteTipCID

        while currentCID != chainTipCID {
            guard let data = try? await fetcher.fetch(rawCid: currentCID),
                  let block = Block(data: data) else {
                log.warn("Recovery: could not fetch block \(String(currentCID.prefix(16))) from CAS — stopping")
                break
            }
            blocksToReplay.append((cid: currentCID, block: block))

            guard let parentCID = block.previousBlock?.rawCID else {
                log.warn("Recovery: block at height \(block.index) has no parent link — stopping")
                break
            }
            currentCID = parentCID

            // Safety: don't walk further than the gap
            if blocksToReplay.count > Int(sqliteHeight - chainHeight) + 1 {
                log.warn("Recovery: walked more blocks than expected — aborting")
                return
            }
        }

        // Replay in forward order (oldest first)
        blocksToReplay.reverse()
        var recovered = 0
        for (_, block) in blocksToReplay {
            let header = VolumeImpl<Block>(node: block)
            let accepted = await lattice.processBlockHeader(header, fetcher: fetcher)
            if accepted {
                recovered += 1
            }
        }

        // Anchor the tip cache to the actual main-chain tip after recovery.
        // processBlockHeader returns true for child-only acceptance too, so
        // per-iteration updates here would leave the cache pointing at a block
        // that isn't the nexus's main tip. The miner's inner PoW loop then
        // breaks every iteration on tipCache != previousBlockHash, spinning
        // without producing blocks.
        let postRecoveryTip = await chainState.getMainChainTip()
        tipCaches[directory]?.update(postRecoveryTip)

        if recovered > 0 {
            log.info("\(directory): recovered \(recovered) block(s) from CAS — chain now at height \(await chainState.getHighestBlockIndex())")
            await persistChainState(directory: directory)
        }
    }

    // MARK: - Block Index Backfill

    /// Backfill the SQLite block_index table from the in-memory chain state.
    /// This ensures blocks persisted before the block_index table existed
    /// become queryable by height after restart.
    func backfillBlockIndex(directory: String) async {
        guard let store = stateStores[directory],
              let chainState = await chain(for: directory) else { return }
        let log = NodeLogger("persistence")
        let height = await chainState.getHighestBlockIndex()
        // Skip the full chain walk when block_index is already populated up to
        // `height`. Each `applyBlock` writes its own height into block_index
        // atomically, so on any steady-state restart the table already has
        // height+1 rows and the scan is pure overhead. At ~300 blocks/hour a
        // year-old chain is ~2.6M rows to walk; the skip drops restart from
        // seconds-to-minutes to O(1).
        if store.getBlockIndexCount() >= Int(height) + 1 { return }
        let tip = await chainState.getMainChainTip()
        var entries: [(height: UInt64, blockHash: String)] = []
        var missing: [UInt64] = []
        for i in 0...height {
            if let hash = await chainState.getMainChainBlockHash(atIndex: i) {
                entries.append((height: i, blockHash: hash))
            } else {
                missing.append(i)
            }
        }
        if !missing.isEmpty {
            log.warn("\(directory): chain height=\(height) tip=\(String(tip.prefix(16)))… but \(missing.count) index(es) missing from in-memory state: \(missing.prefix(10))")
        }
        guard !entries.isEmpty else { return }
        await store.backfillBlockIndex(entries)
        log.info("\(directory): backfilled \(entries.count)/\(height + 1) block index entries")
    }

    // MARK: - Account Pin Rebuild

    /// Rebuild account pins from tx_history so the node retains and serves
    /// all data related to its own address across restarts.
    func rebuildAccountPins(directory: String) async {
        guard let store = stateStores[directory],
              let network = networks[directory] else { return }

        let history = store.getAllTransactionCIDs(address: nodeAddress)
        guard !history.isEmpty else { return }

        var cids: [String] = []
        cids.reserveCapacity(history.count * 2)
        for entry in history {
            cids.append(entry.txCID)
            cids.append(entry.blockHash)
        }

        await network.protectionPolicy.pinAccountBatch(cids)

        let log = NodeLogger("persistence")
        log.info("\(directory): rebuilt \(cids.count) account pin(s) from \(history.count) transaction(s)")
    }

    // MARK: - Parent Hierarchy Persistence

    /// Sidecar file in the top-level storage directory mapping each non-nexus
    /// chain directory to its parent. Written whenever a chain is deployed and
    /// consulted on startup to rebuild the ChainLevel tree in the right shape.
    private var parentHierarchyURL: URL {
        config.storagePath.appendingPathComponent("parent_hierarchy.json")
    }

    func persistParentHierarchy() async {
        do {
            let data = try JSONEncoder().encode(parentDirectoryByChain)
            try data.write(to: parentHierarchyURL, options: .atomic)
        } catch {
            let log = NodeLogger("persistence")
            log.error("Failed to persist parent hierarchy: \(error)")
        }
    }

    func loadParentHierarchy() -> [String: String] {
        guard let data = try? Data(contentsOf: parentHierarchyURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }

    public func restoreChildChains() async throws {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: config.storagePath,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        let nexusDir = genesisConfig.spec.directory

        // Discover every persisted non-nexus chain. The persisted sidecar may be
        // stale or absent — fall back to "parent is nexus" so single-level
        // deployments still restore, and legacy data (deployed before the
        // sidecar existed) keeps working.
        let persistedHierarchy = loadParentHierarchy()
        var discovered: [String] = []
        for dir in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let dirName = dir.lastPathComponent
            guard dirName != nexusDir else { continue }
            let stateFile = dir.appendingPathComponent("chain_state.json")
            guard fm.fileExists(atPath: stateFile.path) else { continue }
            discovered.append(dirName)
        }
        parentDirectoryByChain = [:]
        for d in discovered {
            parentDirectoryByChain[d] = persistedHierarchy[d] ?? nexusDir
        }

        // Restore deepest-first isn't required — topological order is. Because
        // a child's parent must be restored before the child subscribes on it,
        // iterate until nothing new can be restored.
        var restored: Set<String> = [nexusDir]
        var progress = true
        while progress {
            progress = false
            for dirName in discovered where !restored.contains(dirName) {
                let parent = parentDirectoryByChain[dirName] ?? nexusDir
                guard restored.contains(parent) else { continue }
                // Resolve parent level via DFS. Nexus is at chainPath [nexusDir].
                guard let parentHit = await lattice.nexus.findLevel(directory: parent, chainPath: [nexusDir]) else {
                    let log = NodeLogger("persistence")
                    log.warn("Cannot restore \(dirName): parent \(parent) not found in lattice tree")
                    continue
                }
                let persister = ChainStatePersister(storagePath: config.storagePath, directory: dirName)
                guard let persisted = try? await persister.load() else { continue }
                let childChain = ChainState.restore(
                    from: persisted,
                    retentionDepth: config.retentionDepth
                )
                let childLevel = ChainLevel(chain: childChain, children: [:])
                await parentHit.level.restoreChildChain(directory: dirName, level: childLevel)
                persisters[dirName] = persister
                let childPath = parentHit.chainPath + [dirName]
                config = config.addingSubscription(chainPath: childPath)

                if networks[dirName] == nil {
                    let port = deterministicPort(basePort: config.listenPort, directory: dirName)
                    let childConfig = IvyConfig(
                        publicKey: config.publicKey,
                        listenPort: port,
                        enableLocalDiscovery: config.enableLocalDiscovery
                    )
                    try? await registerChainNetwork(directory: dirName, config: childConfig)
                }
                restored.insert(dirName)
                progress = true
            }
        }
        // Persist the normalized hierarchy so any fallbacks get captured on disk.
        await persistParentHierarchy()
    }
}
