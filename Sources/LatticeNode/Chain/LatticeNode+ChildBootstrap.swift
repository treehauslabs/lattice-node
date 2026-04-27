import Lattice
import Foundation
import cashew
import UInt256

extension LatticeNode {

    /// Walk the locally-applied parent chain to derive every embedded child
    /// block's anchor (the parent block whose PoW admitted it), then validate
    /// the child chain end-to-end against those anchors before subscribing.
    ///
    /// Invoked from `applyChildBlockStates` for any directory the node is
    /// configured to subscribe to but whose `ChainLevel` doesn't yet exist.
    /// Re-runs idempotently on each subsequent parent block apply: each pass
    /// has a longer locally-available parent history, so attempts that fail
    /// for a missing anchor (e.g. parent not yet caught up to where the child
    /// was first deployed) succeed once the parent advances.
    func attemptChildBootstrapsForCurrentParent(
        parentBlock: Block,
        parentBlockCID: String,
        parentChainPath: [String],
        fetcher: Fetcher
    ) async {
        guard let cbn = try? await parentBlock.childBlocks.resolve(
            paths: [[""]: .list], fetcher: fetcher
        ).node,
              let dirs = try? cbn.allKeys() else { return }

        for directory in dirs {
            let chainPath = parentChainPath + [directory]
            guard config.isSubscribed(chainPath: chainPath) else { continue }
            guard networks[directory] == nil else { continue }
            // If lattice already subscribed (e.g. via genesis embedding) then
            // this code path isn't responsible — handleChildChainDiscovery is.
            if await lattice.nexus.findLevel(directory: directory, chainPath: parentChainPath) != nil {
                continue
            }
            await bootstrapChildChain(
                directory: directory,
                parentChainPath: parentChainPath,
                currentParentBlock: parentBlock,
                currentParentCID: parentBlockCID,
                fetcher: fetcher
            )
        }
    }

    private struct AnchorEntry {
        let parent: Block
        let parentCID: String
        let parentHash: UInt256
    }

    private func bootstrapChildChain(
        directory: String,
        parentChainPath: [String],
        currentParentBlock: Block,
        currentParentCID: String,
        fetcher: Fetcher
    ) async {
        let log = NodeLogger("bootstrap")

        // 1. Walk parent chain backward, recording (parent, hash) for every
        //    height at which `directory` is embedded. Stop on first miss after
        //    finding the earliest anchor — embedded directories are dense once
        //    mining has begun, so a gap means we've walked past deployment.
        var anchorByChildHeight: [UInt64: AnchorEntry] = [:]
        var parentCursor: Block? = currentParentBlock
        var parentCursorCID: String? = currentParentCID
        var parentCursorHash = currentParentBlock.getDifficultyHash()
        while let p = parentCursor, let pCID = parentCursorCID {
            let cbn = try? await p.childBlocks.resolve(
                paths: [[""]: .list], fetcher: fetcher
            ).node
            if let cbn,
               let header: VolumeImpl<Block> = try? cbn.get(key: directory),
               let childBlock = try? await header.resolve(fetcher: fetcher).node {
                anchorByChildHeight[childBlock.index] = AnchorEntry(
                    parent: p, parentCID: pCID, parentHash: parentCursorHash
                )
            }
            guard let prevHeader = p.previousBlock,
                  let prev = try? await prevHeader.resolve(fetcher: fetcher).node else { break }
            parentCursor = prev
            parentCursorCID = prevHeader.rawCID
            parentCursorHash = prev.getDifficultyHash()
        }

        // 2. Fetch the latest child header from the current parent block.
        guard let cbn = try? await currentParentBlock.childBlocks.resolve(
            paths: [[""]: .list], fetcher: fetcher
        ).node,
              let currentChildHeader: VolumeImpl<Block> = try? cbn.get(key: directory),
              let currentChild = try? await currentChildHeader.resolve(fetcher: fetcher).node else {
            return
        }

        // 3. Walk child.previousBlock to genesis.
        var history: [(header: BlockHeader, block: Block)] = [(currentChildHeader, currentChild)]
        var cursor = currentChild
        while cursor.index > 0, let prevH = cursor.previousBlock {
            guard let prev = try? await prevH.resolve(fetcher: fetcher).node else {
                log.warn("\(directory): bootstrap aborted — cannot resolve child block previousBlock at height \(cursor.index)")
                return
            }
            history.insert((prevH, prev), at: 0)
            cursor = prev
        }
        guard cursor.index == 0, cursor.previousBlock == nil else {
            log.warn("\(directory): bootstrap aborted — child chain does not terminate at genesis")
            return
        }

        // 4. Validate genesis.
        guard let parentSpec = try? await currentParentBlock.spec.resolve(fetcher: fetcher).node else { return }
        let genesisEntry = history[0]
        let (genesisOK, _): (Bool, StateDiff) = (try? await genesisEntry.block.validateGenesis(
            fetcher: fetcher, directory: directory, parentSpec: parentSpec
        )) ?? (false, .empty)
        guard genesisOK else {
            log.warn("\(directory): bootstrap aborted — genesis validation failed")
            return
        }

        // 5. Validate every non-genesis ancestor against its anchor parent.
        let nexusDir = genesisConfig.spec.directory
        let parentLevelHit = await lattice.nexus.findLevel(directory: parentChainPath.last ?? nexusDir, chainPath: parentChainPath)
        guard let parentLevel = parentLevelHit?.level else {
            log.warn("\(directory): bootstrap aborted — parent ChainLevel not found")
            return
        }
        for entry in history.dropFirst() {
            guard let anchor = anchorByChildHeight[entry.block.index] else {
                log.warn("\(directory): bootstrap deferred — missing anchor for child height \(entry.block.index) (parent history exhausted)")
                return
            }
            if !entry.block.validateBlockDifficulty(nexusHash: anchor.parentHash) {
                log.warn("\(directory): bootstrap aborted — PoW invalid at child height \(entry.block.index)")
                return
            }
            // ancestorSpecs for full validation: the parent's spec at the
            // moment this child was anchored. validateChildBlock reads
            // ancestor specs to enforce filters across the whole hierarchy.
            var ancestorSpecs: [ChainSpec] = []
            if let anchorParentSpec = try? await anchor.parent.spec.resolve(fetcher: fetcher).node {
                ancestorSpecs.append(anchorParentSpec)
            }
            let isValid = await parentLevel.validateChildBlock(
                childBlock: entry.block,
                parentBlock: anchor.parent,
                ancestorSpecs: ancestorSpecs,
                chainPath: parentChainPath + [directory],
                fetcher: fetcher
            )
            if !isValid {
                log.warn("\(directory): bootstrap aborted — structural validation failed at child height \(entry.block.index)")
                return
            }
        }

        // 6. Subscribe at lattice level (creates the ChainLevel from genesis).
        await parentLevel.subscribe(
            to: directory,
            genesisBlock: genesisEntry.block,
            retentionDepth: config.retentionDepth
        )
        guard let childLevel = await parentLevel.findLevel(directory: directory, chainPath: parentChainPath)?.level else {
            log.error("\(directory): bootstrap subscribe succeeded but level lookup failed")
            return
        }

        // 7. Submit historical blocks to chain (1..N). The genesis is implicit
        //    in the chain init; non-genesis entries each carry previousBlock,
        //    so submitBlock(parentBlockHeaderAndIndex: nil, ...) accepts them.
        for entry in history.dropFirst() {
            _ = await childLevel.chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: entry.header,
                block: entry.block
            )
        }

        // 8. Register the chain network so peer messages flow.
        await handleChildChainDiscovery(directory: directory)

        // 9. Backfill per-block state for the historical chain (1..N-1). Each
        //    historical child block was once embedded in a parent block whose
        //    `applyChildBlockStates` skipped this directory (no network).
        //    The current block (height N) is left for the surrounding
        //    `applyChildBlockStates` loop to apply normally — `networks[directory]`
        //    is now installed, so the per-child gate falls through.
        let backfill = history.dropFirst().dropLast()
        for entry in backfill {
            guard let anchor = anchorByChildHeight[entry.block.index] else { continue }
            await applyHistoricalChildBlockState(
                directory: directory,
                childBlock: entry.block,
                childHeader: entry.header,
                nexusBlockCID: anchor.parentCID,
                fetcher: fetcher
            )
        }

        log.info("\(directory): bootstrap complete — subscribed at height \(currentChild.index)")
    }

    /// Per-block state apply for historical bootstrap. Mirrors the per-child
    /// body of `applyChildBlockStates` but takes a single (directory, block,
    /// anchorParentCID) tuple rather than walking a parent's `childBlocks`.
    private func applyHistoricalChildBlockState(
        directory: String,
        childBlock: Block,
        childHeader: BlockHeader,
        nexusBlockCID: String,
        fetcher: Fetcher
    ) async {
        guard let childNet = networks[directory] else { return }

        await registerChildBlockVolume(
            childBlock: childBlock, header: childHeader, network: childNet
        )

        let childCID = childHeader.rawCID
        try? await childNet.diskBroker.pin(root: nexusBlockCID, owner: "validates:\(childCID)")
        if let store = stateStores[directory] {
            await store.persistValidatorPin(
                height: childBlock.index,
                childCID: childCID,
                parentCID: nexusBlockCID
            )
        }

        let childFetcher = await buildMempoolAwareFetcher(directory: directory, baseFetcher: childNet.ivyFetcher)
        let txEntries = await resolveBlockTransactions(block: childBlock, fetcher: childFetcher)
        await applyAcceptedBlock(
            block: childBlock, blockHash: childCID,
            txEntries: txEntries, directory: directory
        )

        let confirmed = Set(txEntries.keys)
        await childNet.nodeMempool.removeAll(txCIDs: confirmed)
    }
}
