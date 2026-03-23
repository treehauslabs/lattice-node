import Lattice
import Foundation
import cashew

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
            await self.performSync(peerTipCID: peerTipCID, network: network)
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
            case .snapshot:
                result = try await syncer.syncSnapshot(peerTipCID: peerTipCID)
            }

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
        } catch {
            print("  [sync] Failed: \(error) — will retry on next peer block")
        }

        syncTask = nil
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
