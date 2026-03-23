import Lattice
import Foundation
import cashew
import UInt256

extension LatticeNode {

    public var isSyncing: Bool { syncTask != nil }
    var childSyncTasks: [String: Task<Void, Never>] { [:] }

    func checkSyncNeeded(
        peerBlock: Block,
        peerTipCID: String,
        network: ChainNetwork
    ) async -> Bool {
        guard syncTask == nil else { return true }
        let localHeight = await lattice.nexus.chain.getHighestBlockIndex()
        let gap = peerBlock.index > localHeight ? peerBlock.index - localHeight : 0
        guard gap > config.retentionDepth else { return false }

        if let localSnapshot = await lattice.nexus.chain.tipSnapshot {
            if peerBlock.difficulty <= localSnapshot.difficulty && peerBlock.index <= localHeight {
                return false
            }
        }

        startSync(peerTipCID: peerTipCID, network: network)
        return true
    }

    func startSync(peerTipCID: String, network: ChainNetwork) {
        syncTask = Task { [weak self] in
            guard let self = self else { return }
            switch self.config.syncStrategy {
            case .headersFirst:
                await self.performHeadersFirstSync(peerTipCID: peerTipCID, network: network)
            case .full, .snapshot:
                await self.performSync(peerTipCID: peerTipCID, network: network)
            }
        }
    }

    func performSync(peerTipCID: String, network: ChainNetwork) async {
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
            case .snapshot, .headersFirst:
                result = try await syncer.syncSnapshot(peerTipCID: peerTipCID)
            }

            let nexusDir = genesisConfig.spec.directory
            await lattice.nexus.chain.resetFrom(
                result.persisted,
                retentionDepth: config.retentionDepth
            )
            await persistChainState(directory: nexusDir)

            if let store = stateStores[nexusDir] {
                let log = NodeLogger("sync")
                log.info("Rebuilding StateStore from \(result.persisted.blocks.count) synced blocks...")
                for block in result.persisted.blocks {
                    if let data = try? await fetcher.fetch(rawCid: block.blockHash),
                       let blk = Block(data: data) {
                        let changeset = await extractStateChangeset(block: blk, blockHash: block.blockHash, fetcher: fetcher)
                        if let changeset { await store.applyBlock(changeset) }
                    }
                }
                log.info("StateStore rebuilt")
            }

            await reprocessSyncedBlocksForChildChains(
                persisted: result.persisted,
                fetcher: fetcher
            )
        } catch {
            let log = NodeLogger("sync")
            log.error("Sync failed: \(error) — will retry on next peer block")
        }

        syncTask = nil
    }

    func performHeadersFirstSync(peerTipCID: String, network: ChainNetwork) async {
        print("  [sync] Starting headers-first sync from \(String(peerTipCID.prefix(16)))...")

        let fetcher = await network.fetcher
        let headerChain = HeaderChain()

        do {
            let headers = try await headerChain.downloadHeaders(
                peerTipCID: peerTipCID,
                fetcher: fetcher,
                genesisBlockHash: genesisResult.blockHash,
                localWork: UInt256.zero,
                progress: { current, total in
                    if current % 100 == 0 {
                        print("  [sync] Headers: \(current)/\(total)")
                    }
                }
            )

            print("  [sync] Downloaded \(headers.count) headers, fetching full blocks...")

            let blockFetcher = ParallelBlockFetcher(fetcher: fetcher)
            let cids = headers.map { $0.cid }

            try await blockFetcher.fetchBlocks(
                cids: cids,
                storeFn: { [network] cid, data in
                    await network.storeBlock(cid: cid, data: data)
                },
                progress: { current, total in
                    if current % 50 == 0 {
                        print("  [sync] Blocks: \(current)/\(total)")
                    }
                }
            )

            if let tipHeader = headers.last {
                let tipData = try await fetcher.fetch(rawCid: tipHeader.cid)
                if let tipBlock = Block(data: tipData) {
                    let stateValid = await verifyTipStateRoot(tipBlock, fetcher: fetcher)
                    if !stateValid {
                        print("  [sync] Tip block state root verification failed, falling back to standard sync")
                        await performSync(peerTipCID: peerTipCID, network: network)
                        return
                    }
                    print("  [sync] State root verified for tip block at height \(tipHeader.index)")
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

            print("  [sync] Sync complete: height \(result.tipBlockIndex), applying to chain...")

            let nexusDir = genesisConfig.spec.directory
            await lattice.nexus.chain.resetFrom(
                result.persisted,
                retentionDepth: config.retentionDepth
            )

            await persistChainState(directory: nexusDir)
            await reprocessSyncedBlocksForChildChains(
                persisted: result.persisted,
                fetcher: fetcher
            )

            if let store = stateStores[genesisConfig.spec.directory] {
                for header in headers {
                    if let data = try? await fetcher.fetch(rawCid: header.cid),
                       let block = Block(data: data) {
                        let changeset = await extractStateChangeset(
                            block: block, blockHash: header.cid, fetcher: fetcher
                        )
                        if let changeset {
                            await store.applyBlock(changeset)
                        }
                    }
                }
                print("  [sync] StateStore rebuilt with \(headers.count) blocks")
            }

            syncTask = nil
            print("  [sync] Headers-first sync complete")

        } catch {
            print("  [sync] Headers-first sync failed: \(error), falling back to standard sync")
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
        fetcher: Fetcher
    ) async {
        for blockMeta in persisted.blocks {
            guard let blockData = try? await fetcher.fetch(rawCid: blockMeta.blockHash),
                  let block = Block(data: blockData) else { continue }
            let header = HeaderImpl<Block>(node: block)

            let storer = BufferedStorer()
            try? header.storeRecursively(storer: storer)
            await storer.flush(to: fetcher as! AcornFetcher)

            let _ = await lattice.processBlockHeader(header, fetcher: fetcher)
        }
    }

    func isChildChainSyncing(directory: String) -> Bool {
        return false
    }
}
