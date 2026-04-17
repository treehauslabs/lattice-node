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
        for (cid, block) in blocksToReplay {
            let header = VolumeImpl<Block>(node: block)
            let accepted = await lattice.processBlockHeader(header, fetcher: fetcher)
            if accepted {
                recovered += 1
                // Update the tip cache
                tipCaches[directory]?.update(cid)
            }
        }

        if recovered > 0 {
            log.info("\(directory): recovered \(recovered) block(s) from CAS — chain now at height \(await chainState.getHighestBlockIndex())")
            await persistChainState(directory: directory)
        }
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

            // Register network so child chain is operational immediately
            if networks[dirName] == nil {
                let port = deterministicPort(basePort: config.listenPort, directory: dirName)
                let childConfig = IvyConfig(
                    publicKey: config.publicKey,
                    listenPort: port,
                    enableLocalDiscovery: config.enableLocalDiscovery
                )
                try? await registerChainNetwork(directory: dirName, config: childConfig)
            }
        }
    }
}
