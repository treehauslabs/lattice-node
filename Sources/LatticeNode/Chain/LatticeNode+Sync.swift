import Lattice
import Foundation
import cashew
import UInt256

extension LatticeNode {

    public var isSyncing: Bool { syncTask != nil }

    func checkSyncNeeded(
        peerBlock: Block,
        peerTipCID: String,
        network: ChainNetwork
    ) async -> Bool {
        guard syncTask == nil else { return true }
        let directory = await network.directory
        guard let chainState = await chain(for: directory) else { return false }
        let localHeight = await chainState.getHighestBlockIndex()
        let gap = peerBlock.index > localHeight ? peerBlock.index - localHeight : 0
        guard gap > config.retentionDepth else { return false }

        if let localSnapshot = await chainState.tipSnapshot {
            if peerBlock.difficulty <= localSnapshot.difficulty && peerBlock.index <= localHeight {
                return false
            }
        }

        startSync(peerTipCID: peerTipCID, network: network)
        return true
    }

    static let syncTimeout: Duration = .seconds(600)

    func startSync(peerTipCID: String, network: ChainNetwork) {
        let strategy = self.config.syncStrategy
        syncTask = Task { [weak self] in
            guard let self = self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    switch strategy {
                    case .headersFirst:
                        await self.performHeadersFirstSync(peerTipCID: peerTipCID, network: network)
                    case .full, .snapshot:
                        await self.performSync(peerTipCID: peerTipCID, network: network)
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: Self.syncTimeout)
                }
                await group.next()
                group.cancelAll()
            }
            if Task.isCancelled {
                let log = NodeLogger("sync")
                log.warn("Sync timed out — will retry on next peer block")
            }
            await self.clearSyncTask()
        }
    }

    func clearSyncTask() {
        syncTask = nil
    }

    func performSync(peerTipCID: String, network: ChainNetwork) async {
        let fetcher: any Fetcher = await network.ivyFetcher
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
            case .snapshot, .headersFirst:
                result = try await syncer.syncSnapshot(peerTipCID: peerTipCID)
            }

            await finalizeSyncResult(result, network: network, fetcher: fetcher)
        } catch {
            let log = NodeLogger("sync")
            log.error("Sync failed: \(error) — will retry on next peer block")
        }
    }

    func performHeadersFirstSync(peerTipCID: String, network: ChainNetwork) async {
        let log = NodeLogger("sync")
        log.info("Starting headers-first sync from \(String(peerTipCID.prefix(16)))...")

        let fetcher: any Fetcher = await network.ivyFetcher
        let headerChain = HeaderChain()

        do {
            let headers = try await headerChain.downloadHeaders(
                peerTipCID: peerTipCID,
                fetcher: fetcher,
                genesisBlockHash: genesisResult.blockHash,
                localWork: UInt256.zero,
                progress: { current, total in
                    if current % 100 == 0 {
                        log.info("Headers: \(current)/\(total)")
                    }
                }
            )

            log.info("Downloaded \(headers.count) headers, fetching full blocks...")

            let blockFetcher = ParallelBlockFetcher(fetcher: fetcher)
            let cids = headers.map { $0.cid }

            try await blockFetcher.fetchBlocks(
                cids: cids,
                storeFn: { [network] cid, data in
                    await network.storeBlock(cid: cid, data: data)
                },
                progress: { current, total in
                    if current % 50 == 0 {
                        log.info("Blocks: \(current)/\(total)")
                    }
                }
            )

            if let tipHeader = headers.last {
                let tipData = try await fetcher.fetch(rawCid: tipHeader.cid)
                if let tipBlock = Block(data: tipData) {
                    let stateValid = await verifyTipStateRoot(tipBlock, fetcher: fetcher)
                    if !stateValid {
                        log.warn("Tip block state root verification failed, falling back to standard sync")
                        await performSync(peerTipCID: peerTipCID, network: network)
                        return
                    }
                    log.info("State root verified for tip block at height \(tipHeader.index)")
                }
            }

            let syncer = ChainSyncer(
                fetcher: fetcher,
                store: { _, _ in },
                genesisBlockHash: genesisResult.blockHash,
                retentionDepth: config.retentionDepth
            )

            let result = try await syncer.syncSnapshot(
                peerTipCID: peerTipCID
            )

            log.info("Sync complete: height \(result.tipBlockIndex), applying to chain...")

            await finalizeSyncResult(result, network: network, fetcher: fetcher)

            log.info("Headers-first sync complete")

        } catch {
            log.error("Headers-first sync failed: \(error), falling back to standard sync")
            await performSync(peerTipCID: peerTipCID, network: network)
        }
    }

    private func verifyTipStateRoot(_ block: Block, fetcher: Fetcher) async -> Bool {
        let basicValid = (try? await block.validateFrontierState(
            transactionBodies: [], fetcher: fetcher
        )) ?? false
        if basicValid { return true }

        guard let transactionsNode = try? await block.transactions.resolveRecursive(fetcher: fetcher).node else {
            return false
        }
        guard let txKeysAndValues = try? transactionsNode.allKeysAndValues() else {
            return false
        }
        let bodies = txKeysAndValues.values.compactMap { $0.node?.body.node }
        return (try? await block.validateFrontierState(transactionBodies: bodies, fetcher: fetcher)) ?? false
    }

    private func reprocessSyncedBlocksForChildChains(
        persisted: PersistedChainState,
        fetcher: Fetcher,
        network: ChainNetwork
    ) async {
        for blockMeta in persisted.blocks {
            guard let blockData = try? await fetcher.fetch(rawCid: blockMeta.blockHash),
                  let block = Block(data: blockData) else { continue }
            let header = VolumeImpl<Block>(node: block)

            let storer = BufferedStorer()
            try? header.storeRecursively(storer: storer)
            await storer.flush(to: network)

            let _ = await lattice.processBlockHeader(header, fetcher: fetcher)
        }
    }

    private func finalizeSyncResult(_ result: SyncResult, network: ChainNetwork, fetcher: Fetcher) async {
        let log = NodeLogger("sync")
        let nexusDir = genesisConfig.spec.directory

        await lattice.nexus.chain.resetFrom(result.persisted, retentionDepth: config.retentionDepth)
        await persistChainState(directory: nexusDir)

        if let store = stateStores[nexusDir] {
            log.info("Rebuilding StateStore via block replay (sparse — no full state pull)...")

            // Replay synced blocks in order: each block's accountActions carry
            // balance deltas, so we derive state from transactions alone.
            // This avoids resolveRecursive on the account state tree entirely.
            let sortedBlocks = result.persisted.blocks.sorted { $0.blockIndex < $1.blockIndex }
            for blockMeta in sortedBlocks {
                guard let data = try? await fetcher.fetch(rawCid: blockMeta.blockHash),
                      let blk = Block(data: data) else { continue }
                if let txDict = try? await blk.transactions.resolveRecursive(fetcher: fetcher).node,
                   let txEntries = try? txDict.allKeysAndValues() {
                    let changeset = extractStateChangeset(
                        block: blk, blockHash: blockMeta.blockHash,
                        txEntries: txEntries, store: store
                    )
                    await store.applyBlock(changeset)
                }
            }

            // Set tip metadata from the last synced block
            if let tipMeta = sortedBlocks.last,
               let tipData = try? await fetcher.fetch(rawCid: tipMeta.blockHash),
               let tipBlock = Block(data: tipData) {
                await store.setChainTip(
                    hash: tipMeta.blockHash,
                    height: tipBlock.index,
                    stateRoot: tipBlock.frontier.rawCID
                )
            }

            log.info("StateStore rebuilt from \(sortedBlocks.count) blocks (sparse replay)")
        }

        await reprocessSyncedBlocksForChildChains(persisted: result.persisted, fetcher: fetcher, network: network)
        await verifySyncWithPeers(tipCID: result.tipBlockHash, tipHeight: result.tipBlockIndex, network: network)
    }

    func verifySyncWithPeers(tipCID: String, tipHeight: UInt64, network: ChainNetwork) async {
        let log = NodeLogger("sync")
        let peerCount = await network.ivy.directPeerCount
        if peerCount < 2 {
            log.warn("Sync completed with only \(peerCount) peer(s) — insufficient for cross-verification")
            return
        }

        if let data = try? await network.ivyFetcher.fetch(rawCid: tipCID),
           let block = Block(data: data) {
            let valid = block.index == tipHeight
            if valid {
                log.info("Sync verified: tip at height \(tipHeight) with \(peerCount) connected peers")
            } else {
                log.warn("Sync tip height mismatch: expected \(tipHeight), got \(block.index)")
            }
        } else {
            log.warn("Sync verification: could not resolve tip block from CAS")
        }
    }

    func isChildChainSyncing(directory: String) -> Bool {
        return false
    }
}
