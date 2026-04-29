import Lattice
import Foundation
import Ivy
import VolumeBroker
import Tally
import cashew

extension LatticeNode {

    private static let receiptEncoder = JSONEncoder()

    static let maxTimestampDriftMs: Int64 = 7_200_000
    static let maxTimestampAgeMs: Int64 = 86_400_000
    static let blockDeduplicationWindow: Duration = .milliseconds(100)
    static let peerBlockCountCleanupThreshold = 5000
    static let peerBlockCountWindow: Duration = .seconds(30)

    /// Reorg depth limit, scaled to this node's retention window. The walk
    /// in `findCommonAncestor` is already bounded by `retentionDepth` (a
    /// deeper fork has no common ancestor and is refused outright), so an
    /// independent constant either silently strands legitimate retention-bounded
    /// reorgs (when retentionDepth > 100) or falsely reassures (when
    /// retentionDepth < 100). Cap at retentionDepth so the two limits agree.
    var maxReorgDepth: Int { Int(config.retentionDepth) }

    nonisolated func isBlockTimestampValid(_ block: Block) -> Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if block.timestamp > nowMs + Self.maxTimestampDriftMs { return false }
        if block.timestamp < nowMs - Self.maxTimestampAgeMs { return false }
        return true
    }

    /// Cheap O(1) proof-of-work sanity check: does the block's hash actually
    /// meet its own claimed difficulty target? Runs against header fields only
    /// — no CAS touch, no state resolve. Catches lazy gossip spam that forged
    /// `difficulty` without burning any nonce work; correctness of the claimed
    /// difficulty itself (vs. chain rules) is re-checked later in
    /// `validateNextDifficulty` once ancestor timestamps are available.
    nonisolated func isBlockPoWValid(_ block: Block) -> Bool {
        block.validateBlockDifficulty(nexusHash: block.getDifficultyHash())
    }

    // MARK: - State Root Extraction

    /// Volume boundary CIDs that must stay resolvable to answer queries at `block`.
    /// Pinned in the per-chain protection policy to survive LRU eviction.
    static func stateRoots(of block: Block) -> [String] {
        [
            block.frontier.rawCID,
            block.homestead.rawCID,
            block.transactions.rawCID,
            block.childBlocks.rawCID,
        ].filter { !$0.isEmpty }
    }

    // MARK: - Recursive Block Storage

    func storeBlockRecursively(_ block: Block, network: ChainNetwork, directory: String? = nil, stateDiff: StateDiff = .empty) async {
        let dir = directory ?? network.directory
        let header = VolumeImpl<Block>(node: block)
        let storer = BrokerStorer(broker: network.diskBroker)
        do {
            try header.storeRecursively(storer: storer)
            try await storer.flush()

            let owner = "\(dir):\(block.index)"
            let fee = await network.ivy.config.relayFee * 2
            let expiry = UInt64(Date().timeIntervalSince1970) + 86400
            for root in storer.storedRoots {
                try await network.diskBroker.pin(root: root, owner: owner)
                await network.announce(cid: root, expiry: expiry, fee: fee)
            }
            if let store = stateStores[dir] {
                await store.persistStoredRoots(height: block.index, roots: storer.storedRoots)
                if !stateDiff.replaced.isEmpty {
                    await store.persistReplacedRoots(height: block.index, roots: stateDiff.replaced)
                }
            }

            try await pruneBlocks(block: block, directory: dir, network: network)
            try await pruneState(block: block, directory: dir, network: network)
        } catch {
            let log = NodeLogger("blocks")
            log.error("Failed to store block recursively: \(error)")
        }
    }

    private func pruneBlocks(block: Block, directory: String, network: ChainNetwork) async throws {
        switch config.blockRetention {
        case .tip:
            if block.index > 0 {
                let prevOwner = "\(directory):\(block.index - 1)"
                try await network.diskBroker.unpinAll(owner: prevOwner)
                await releaseValidatorPins(directory: directory, height: block.index - 1, network: network)
            }

        case .retention:
            if block.index > config.retentionDepth {
                let pruneHeight = block.index - config.retentionDepth
                let pruneOwner = "\(directory):\(pruneHeight)"
                try await network.diskBroker.unpinAll(owner: pruneOwner)
                if let store = stateStores[directory] {
                    await store.deleteStoredRoots(height: pruneHeight)
                    await store.deleteReplacedRoots(height: pruneHeight)
                }
                await releaseValidatorPins(directory: directory, height: pruneHeight, network: network)
            }

        case .historical:
            if block.index > config.retentionDepth {
                let pruneHeight = block.index - config.retentionDepth
                guard let chain = await chain(for: directory) else { return }
                guard let blockHash = stateStores[directory]?.getBlockHash(atHeight: pruneHeight) else { return }
                let onMainChain = await chain.isOnMainChain(hash: blockHash)
                if !onMainChain {
                    let pruneOwner = "\(directory):\(pruneHeight)"
                    try await network.diskBroker.unpinAll(owner: pruneOwner)
                    await releaseValidatorPins(directory: directory, height: pruneHeight, network: network)
                }
            }
        }
    }

    private func pruneState(block: Block, directory: String, network: ChainNetwork) async throws {
        guard block.index > config.retentionDepth else { return }
        let pruneHeight = block.index - config.retentionDepth
        let pruneOwner = "\(directory):\(pruneHeight)"
        guard let store = stateStores[directory] else { return }

        switch config.storageMode {
        case .stateful:
            let replacedRoots = store.getReplacedRoots(height: pruneHeight)
            for (root, count) in replacedRoots {
                try await network.diskBroker.unpin(root: root, owner: pruneOwner, count: count)
            }
            await store.deleteReplacedRoots(height: pruneHeight)

        case .historical:
            guard let chain = await chain(for: directory) else { return }
            guard let blockHash = store.getBlockHash(atHeight: pruneHeight) else { return }
            let onMainChain = await chain.isOnMainChain(hash: blockHash)
            if !onMainChain {
                let replacedRoots = store.getReplacedRoots(height: pruneHeight)
                for (root, count) in replacedRoots {
                    try await network.diskBroker.unpin(root: root, owner: pruneOwner, count: count)
                }
                await store.deleteReplacedRoots(height: pruneHeight)
            }

        case .stateless:
            break
        }
    }

    /// Invoked from `applyChildBlockStates` after the parent's
    /// `storeBlockRecursively` walked the merged-mined nexus block. The
    /// shared CAS already holds the child subtree's bytes (pinned under the
    /// parent's `<parentDir>:<parentIndex>` owner), but those pins are
    /// released when the parent block falls past `retentionDepth`. The child
    /// chain still references that data, so we re-walk on the child network
    /// to install per-chain owner pins (`<childDir>:<childIndex>`) and
    /// record the roots in the child's StateStore. Disk writes are
    /// idempotent (`INSERT OR REPLACE`) and the broker's pin table is keyed
    /// by (root, owner), so the walk is correct even when bytes already
    /// exist locally.
    func registerChildBlockVolume(childBlock: Block, header: VolumeImpl<Block>, network: ChainNetwork) async {
        await storeBlockRecursively(childBlock, network: network)
    }

    static let maxCopyDepth = 64

    func deepCopyBlock(cid: String, from source: ChainNetwork, to dest: ChainNetwork) async {
        var visited = Set<String>()
        await copyCIDRecursive(cid, from: source, to: dest, visited: &visited, depth: 0)
    }

    private func copyCIDRecursive(_ cid: String, from source: ChainNetwork, to dest: ChainNetwork, visited: inout Set<String>, depth: Int) async {
        guard depth < Self.maxCopyDepth else { return }
        guard !cid.isEmpty, !visited.contains(cid) else { return }
        visited.insert(cid)
        guard let data = try? await source.ivyFetcher.fetch(rawCid: cid) else { return }
        await dest.storeLocally(cid: cid, data: data)

        if let block = Block(data: data) {
            if let prevCID = block.previousBlock?.rawCID {
                await copyCIDRecursive(prevCID, from: source, to: dest, visited: &visited, depth: depth + 1)
            }
            await copyCIDRecursive(block.transactions.rawCID, from: source, to: dest, visited: &visited, depth: depth + 1)
            await copyCIDRecursive(block.spec.rawCID, from: source, to: dest, visited: &visited, depth: depth + 1)
            await copyCIDRecursive(block.homestead.rawCID, from: source, to: dest, visited: &visited, depth: depth + 1)
            await copyCIDRecursive(block.frontier.rawCID, from: source, to: dest, visited: &visited, depth: depth + 1)
            await copyCIDRecursive(block.parentHomestead.rawCID, from: source, to: dest, visited: &visited, depth: depth + 1)
            await copyCIDRecursive(block.childBlocks.rawCID, from: source, to: dest, visited: &visited, depth: depth + 1)
        }
    }

    func storeReceivedBlockRecursively(cid: String, data: Data, network: ChainNetwork) async {
        _ = (cid, data, network)
    }

    // MARK: - Block Processing with Reorg Recovery

    enum BlockProcessOutcome {
        case accepted
        case duplicate
        case rejected
    }

    func processBlockAndRecoverReorg(
        header: BlockHeader,
        directory: String,
        fetcher: Fetcher,
        resolvedBlock: Block? = nil,
        skipValidation: Bool = false
    ) async -> BlockProcessOutcome {
        guard let chain = await chain(for: directory) else { return .rejected }

        // Peers echo our own block announcements back via gossip. Detect the
        // duplicate here so the caller can record peer success without
        // warning or re-announcing.
        if await chain.contains(blockHash: header.rawCID) { return .duplicate }

        // A gossip echo can arrive ~60ms after we submit/receive a block, while
        // the first call is still suspended inside `lattice.processBlockHeader`.
        // The chain hasn't recorded the block yet, so `chain.contains` above
        // misses it. Guard with an in-flight set so the echo short-circuits
        // instead of re-validating.
        if inFlightBlockCIDs.contains(header.rawCID) { return .duplicate }
        inFlightBlockCIDs.insert(header.rawCID)
        defer { inFlightBlockCIDs.remove(header.rawCID) }

        let tipBefore = await chain.getMainChainTip()

        // When processing nexus blocks, child block validation needs access to
        // state data in child CAS stores (e.g., radix trie nodes for the
        // frontier state). Build a composite fetcher that falls back to child
        // CAS stores when the nexus CAS doesn't have the requested data.
        let validationFetcher: Fetcher
        if directory == genesisConfig.spec.directory {
            let childFetchers = await lattice.nexus.childDirectories().compactMap { networks[$0]?.ivyFetcher }
            if childFetchers.isEmpty {
                validationFetcher = fetcher
            } else {
                validationFetcher = CompositeFetcher(primary: fetcher, fallbacks: childFetchers)
            }
        } else {
            validationFetcher = fetcher
        }
        let phLog = NodeLogger("blocks")
        let phShort = String(header.rawCID.prefix(16))
        if let vaf = validationFetcher as? VolumeAwareFetcher {
            try? await vaf.enterVolume(rootCID: header.rawCID, paths: .init())
        }
        let (accepted, stateDiff) = await lattice.processBlockHeader(header, fetcher: validationFetcher, skipValidation: skipValidation)
        if let vaf = validationFetcher as? VolumeAwareFetcher {
            await vaf.exitVolume(rootCID: header.rawCID)
        }
        guard accepted else {
            phLog.warn("\(directory): block \(phShort)… rejected by processBlockHeader")
            return .rejected
        }

        let block: Block?
        if let r = resolvedBlock {
            block = r
        } else {
            block = try? await header.resolve(fetcher: fetcher).node
        }
        if let block {
            let txFetcher = await buildMempoolAwareFetcher(directory: directory, baseFetcher: fetcher)
            let txEntries = await resolveBlockTransactions(block: block, fetcher: txFetcher)
            await applyAcceptedBlock(
                block: block, blockHash: header.rawCID,
                txEntries: txEntries, directory: directory
            )
            // Apply child block state changes (StateStore, mempool, receipts).
            // The Lattice library processes child blocks into ChainState, but
            // LatticeNode-level state (deposits, balances, etc.) must be applied here.
            if directory == genesisConfig.spec.directory {
                await applyChildBlockStates(parentBlock: block, nexusBlockCID: header.rawCID, fetcher: fetcher)
            }
            // Promote any pending child-mempool entries whose required
            // receipt just landed in this block. Sibling fix for the
            // receipt-visibility race: pending entries gated on receipts
            // newly committed here become selectable on the next round.
            await runReceiptPromotionHook(txEntries: txEntries, parentDirectory: directory)
            // Evict mempool entries holding deposit keys consumed by this
            // block's withdrawals. The included withdrawal itself was
            // already removed via batchUpdateConfirmedNonces; this catches
            // cross-pool conflicts (e.g. a pending entry on the same
            // deposit that lost the inclusion race).
            await runDepositEvictionHook(txEntries: txEntries, directory: directory)
        }

        let tipAfter = await chain.getMainChainTip()
        tipCaches[directory]?.update(tipAfter)
        if tipBefore != tipAfter {
            let parentOfNewTip = await chain.getConsensusBlock(hash: tipAfter)?.previousBlockHash
            if parentOfNewTip != tipBefore {
                // Reorg (new tip's parent is not the old tip). Drop the
                // miner's cached account-trie slice so the next iteration
                // re-reads from the canonical frontier — paths resolved
                // against a no-longer-canonical ancestor would produce a
                // coinbase that trips `nonceGap` forever otherwise.
                await miners[directory]?.invalidateAccountCache()
                await recoverOrphanedTransactions(
                    oldTip: tipBefore,
                    newTip: tipAfter,
                    directory: directory,
                    chain: chain,
                    fetcher: fetcher
                )
            }
        }

        return .accepted
    }

    /// Walk back from `oldTip` up to `retentionDepth` blocks, collecting
    /// hashes that are NOT in `newChainHashes` as orphans. Reports whether a
    /// common ancestor was actually found — if not, the reorg exceeds the
    /// retention window and the caller must refuse recovery rather than
    /// proceed with a truncated orphan set (S3).
    ///
    /// Static + `resolveParent` closure so the walk is directly testable
    /// without spinning up a `ChainState`/`LatticeNode`.
    static func walkOrphansToCommonAncestor(
        oldTip: String,
        newChainHashes: Set<String>,
        retentionDepth: UInt64,
        resolveParent: (String) async -> String?
    ) async -> (orphans: [String], foundCommonAncestor: Bool) {
        var orphans: [String] = []
        var current = oldTip
        for _ in 0..<retentionDepth {
            if newChainHashes.contains(current) {
                return (orphans, true)
            }
            orphans.append(current)
            guard let prev = await resolveParent(current) else {
                return (orphans, false)
            }
            current = prev
        }
        return (orphans, false)
    }

    private func recoverOrphanedTransactions(
        oldTip: String,
        newTip: String,
        directory: String,
        chain: ChainState,
        fetcher: Fetcher
    ) async {
        let log = NodeLogger("reorg")
        let dir = directory
        let network = networks[dir]

        let newChainHashes = await collectAncestors(
            from: newTip, chain: chain, limit: config.retentionDepth
        )

        let walk = await Self.walkOrphansToCommonAncestor(
            oldTip: oldTip,
            newChainHashes: newChainHashes,
            retentionDepth: config.retentionDepth,
            resolveParent: { hash in
                await chain.getConsensusBlock(hash: hash)?.previousBlockHash
            }
        )
        let orphanedBlockHashes = walk.orphans

        guard !orphanedBlockHashes.isEmpty else { return }

        // S3: retentionDepth is a consensus-safety parameter, not just storage.
        // If we walked `retentionDepth` blocks back from oldTip without finding
        // a common ancestor with the new chain, the fork is deeper than our
        // retention window and we cannot correctly identify the orphan set.
        // Applying a reorg with a truncated/incomplete orphan list silently
        // corrupts mempool recovery and child-chain rollback — refuse and log
        // loudly instead of guessing.
        if !walk.foundCommonAncestor {
            log.error("Reorg refused: no common ancestor within retentionDepth=\(config.retentionDepth) blocks from oldTip=\(String(oldTip.prefix(16)))… to newTip=\(String(newTip.prefix(16)))…. Fork either exceeds the retention window (honest — raise retentionDepth) or indicates a malicious peer.")
            return
        }

        log.info("Reorg: \(orphanedBlockHashes.count) orphaned block(s)")

        if orphanedBlockHashes.count > maxReorgDepth {
            log.error("Reorg depth \(orphanedBlockHashes.count) exceeds limit \(maxReorgDepth) — potential attack")
            return
        }

        // Enforce finality: refuse to reorg past finalized blocks
        let currentHeight = await chain.getHighestBlockIndex()
        for blockHash in orphanedBlockHashes {
            if let meta = await chain.getConsensusBlock(hash: blockHash) {
                if config.finality.isFinal(chain: dir, blockHeight: meta.blockIndex, currentHeight: currentHeight) {
                    log.error("Reorg would undo finalized block at height \(meta.blockIndex) — rejected")
                    return
                }
            }
        }

        // Step 1: Resolve orphaned block transactions (newest first) so we can
        // re-validate them against the new tip. AccountState lives on-chain —
        // no explicit rollback needed; the new tip's frontier is authoritative.
        let reorgFetcher = await buildMempoolAwareFetcher(directory: dir, baseFetcher: fetcher)

        var orphanedBlockTxs: [(block: Block, txEntries: [String: VolumeImpl<Transaction>])] = []
        for blockHash in orphanedBlockHashes {
            let stub = VolumeImpl<Block>(rawCID: blockHash, node: nil, encryptionInfo: nil)
            guard let block = try? await stub.resolve(fetcher: fetcher).node else {
                log.error("Missing CAS data for orphaned block \(blockHash) — skipping")
                continue
            }
            let txEntries = await resolveBlockTransactions(block: block, fetcher: reorgFetcher)
            orphanedBlockTxs.append((block: block, txEntries: txEntries))
        }

        // Step 2: Collect confirmed tx CIDs from the NEW chain (to avoid re-adding them)
        // Fetch blocks in parallel — each is independent. Use .list to load only radix structure.
        let newChainTxCIDs: Set<String> = await withTaskGroup(of: Set<String>.self) { group in
            for newBlockHash in newChainHashes {
                group.addTask {
                    let stub = VolumeImpl<Block>(rawCID: newBlockHash, node: nil, encryptionInfo: nil)
                    guard let block = try? await stub.resolve(fetcher: fetcher).node,
                          let txDict = try? await block.transactions.resolve(
                              paths: [[""]: .list], fetcher: fetcher
                          ).node,
                          let txKeys = try? txDict.allKeys() else { return [] }
                    return Set(txKeys)
                }
            }
            var cids = Set<String>()
            for await keys in group {
                for cid in keys { cids.insert(cid) }
            }
            return cids
        }

        // Step 3: Remove new chain's confirmed txs from mempool
        if !newChainTxCIDs.isEmpty, let network {
            await network.nodeMempool.removeAll(txCIDs: newChainTxCIDs)
        }

        // Step 4: Re-classify orphaned txs through the unified admission
        // helper. admitToMempool runs the validator + parent-receipt probe
        // so a withdrawal whose required receipt is no longer canonical in
        // the new chain lands in pending (or evicts on wrong-owner) instead
        // of being silently dropped.
        var recovered = 0
        for entry in orphanedBlockTxs {
            for (cid, txHeader) in entry.txEntries {
                guard let tx = txHeader.node else { continue }
                if tx.body.node?.fee == 0 && tx.body.node?.nonce == entry.block.index { continue }
                if newChainTxCIDs.contains(cid) { continue }
                let addResult = await admitToMempool(transaction: tx, directory: dir)
                switch addResult {
                case .added, .addedPending, .replacedExisting:
                    recovered += 1
                case .rejected:
                    continue
                }
            }
        }

        log.info("Reorg complete: \(recovered) tx(s) recovered, \(newChainTxCIDs.count) confirmed in new chain")

        // Step 4.5: Demote any direct child mempool's valid withdrawals
        // whose required receipt is no longer canonical at the new parent
        // tip, and re-probe pending entries against the new state. A
        // reorg can both add and remove receipts; admitToMempool only
        // covers orphaned txs being re-admitted, not entries that were
        // already in the child mempool as valid before the reorg fired.
        await runChildReorgHook(parentDirectory: dir)

        // Step 5: Roll back child chain states from orphaned nexus blocks
        await rollbackChildChains(orphanedBlockHashes: orphanedBlockHashes, fetcher: fetcher)

        await emitReorgEvent(
            directory: dir,
            oldTip: oldTip,
            newTip: newTip,
            depth: UInt64(orphanedBlockHashes.count)
        )
    }

    /// Roll back child chain StateStores for child blocks embedded in orphaned nexus blocks.
    private func rollbackChildChains(orphanedBlockHashes: [String], fetcher: Fetcher) async {
        let log = NodeLogger("reorg")
        for blockHash in orphanedBlockHashes {
            let stub = VolumeImpl<Block>(rawCID: blockHash, node: nil, encryptionInfo: nil)
            guard let block = try? await stub.resolve(fetcher: fetcher).node,
                  let childDict = try? await block.childBlocks.resolve(
                      paths: [[""]: .list], fetcher: fetcher
                  ).node,
                  let childDirs = try? childDict.allKeys() else { continue }

            for childDir in childDirs {
                guard let childBlockHeader: VolumeImpl<Block> = try? childDict.get(key: childDir) else { continue }
                let childBlock: Block
                if let n = childBlockHeader.node {
                    childBlock = n
                } else {
                    guard let resolved = try? await childBlockHeader.resolve(fetcher: fetcher).node else { continue }
                    childBlock = resolved
                }

                let childTxEntries = await resolveBlockTransactions(block: childBlock, fetcher: fetcher)

                // Recover orphaned child txs through the unified admission
                // helper. Withdrawals whose receipt is no longer canonical
                // in the new parent chain go pending (or evict on wrong-
                // owner) — same classifier as gossip and direct submit.
                if let childNetwork = networks[childDir] {
                    for (cid, txHeader) in childTxEntries {
                        guard let tx = txHeader.node else { continue }
                        if tx.body.node?.fee == 0 { continue }
                        if await childNetwork.nodeMempool.contains(txCID: cid) { continue }
                        _ = await admitToMempool(transaction: tx, directory: childDir)
                    }
                }

                log.info("Child chain \(childDir): rolled back block at height \(childBlock.index)")
            }
        }
    }

    private func collectAncestors(
        from tip: String,
        chain: ChainState,
        limit: UInt64
    ) async -> Set<String> {
        var hashes = Set<String>()
        var current = tip
        for _ in 0..<limit {
            hashes.insert(current)
            guard let meta = await chain.getConsensusBlock(hash: current),
                  let prev = meta.previousBlockHash else { break }
            current = prev
        }
        return hashes
    }

    // MARK: - Block Reception (ChainNetworkDelegate) with Rate Limiting & Reputation

    nonisolated public func chainNetwork(
        _ network: ChainNetwork,
        didReceiveBlock cid: String,
        data: Data,
        from peer: PeerID
    ) async {
        if await isPeerBlockRateLimited(peer) { return }

        let tally = await network.ivy.tally
        if data.count > genesisConfig.spec.maxBlockSize {
            tally.recordFailure(peer: peer)
            return
        }

        let now = ContinuousClock.Instant.now
        let key = cid
        if let lastSeen = await recentBlockTime(for: key) {
            let elapsed = now - lastSeen
            if elapsed < Self.blockDeduplicationWindow {
                return
            }
        }
        await recordBlockTime(key: key, time: now)

        tally.recordReceived(peer: peer, bytes: data.count)

        // Validate before storing — don't waste disk on invalid blocks
        guard let block = Block(data: data) else {
            tally.recordFailure(peer: peer)
            return
        }

        if !isBlockTimestampValid(block) {
            tally.recordFailure(peer: peer)
            return
        }

        // Reject insufficient-PoW before any CAS write. A block whose own hash
        // doesn't meet its claimed difficulty cost zero PoW to forge; we must
        // not spend a disk write or a retention slot on it.
        if !isBlockPoWValid(block) {
            tally.recordFailure(peer: peer)
            return
        }

        if block.index == 0 && block.previousBlock != nil {
            tally.recordFailure(peer: peer)
            return
        }

        let directory = await network.directory
        // Skip CAS store + processing for blocks we've already accepted.
        // hashToBlock contains only blocks we've fully processed, so presence
        // implies the block and its state are already resident in CAS.
        if let chainState = await chain(for: directory),
           await chainState.contains(blockHash: cid) {
            tally.recordSuccess(peer: peer)
            return
        }

        // Basic checks passed — store to CAS
        await storeReceivedBlockRecursively(cid: cid, data: data, network: network)

        let blockFetcher = await network.ivyFetcher
        await blockFetcher.bindPinner(rootCID: cid, peer: peer)
        await blockFetcher.bindBlockRoots(block, peer: peer)

        if await checkSyncNeeded(
            peerBlock: block,
            peerTipCID: cid,
            network: network
        ) {
            tally.recordSuccess(peer: peer)
            return
        }

        let header = VolumeImpl<Block>(rawCID: cid)
        let outcome = await processBlockAndRecoverReorg(
            header: header, directory: directory, fetcher: blockFetcher,
            resolvedBlock: block
        )
        switch outcome {
        case .accepted:
            tally.recordSuccess(peer: peer)
            await network.setChainTip(tipCID: cid, stateRoots: Self.stateRoots(of: block))
            // Announce accepted block so we earn from serving it
            await network.announceStoredBlock(cid: cid, data: data)
        case .duplicate:
            tally.recordSuccess(peer: peer)
        case .rejected:
            tally.recordFailure(peer: peer)
        }
        await maybePersist(directory: directory)
    }

    nonisolated public func chainNetwork(
        _ network: ChainNetwork,
        didReceiveBlockAnnouncement cid: String,
        from peer: PeerID
    ) async {
        if await isPeerBlockRateLimited(peer) { return }

        let now = ContinuousClock.Instant.now
        if let lastSeen = await recentBlockTime(for: cid) {
            if now - lastSeen < Self.blockDeduplicationWindow { return }
        }
        await recordBlockTime(key: cid, time: now)

        guard !(await isSyncing) else { return }

        let directory = await network.directory
        let tally = await network.ivy.tally

        if let chainState = await chain(for: directory),
           await chainState.contains(blockHash: cid) {
            tally.recordSuccess(peer: peer)
            return
        }

        let resolveFetcher = await network.ivyFetcher

        // The peer who announced this block is a guaranteed source for its
        // entire tree. Skip DHT discovery — bind them directly so fetch()
        // can hop straight to them for any sub-CID we don't have locally.
        await resolveFetcher.bindPinner(rootCID: cid, peer: peer)

        let header = VolumeImpl<Block>(rawCID: cid)

        // Resolve the full block before processing — don't update chain tip
        // unless the block data is locally available for the miner to read.
        guard let block = try? await header.resolve(fetcher: resolveFetcher).node else {
            return
        }

        // Now that we have the block's boundary CIDs, bind the same peer as
        // a known source for each sub-Volume root. validateNexus and friends
        // will walk these trees via IvyFetcher; binding the peer up front
        // avoids the 15s DHT-walk timeout when the peer hasn't yet reached
        // the DHT as a discoverable pinner for every inner CID.
        await resolveFetcher.bindBlockRoots(block, peer: peer)

        if !isBlockTimestampValid(block) {
            tally.recordFailure(peer: peer)
            return
        }

        // PoW short-circuit *before* checkSyncNeeded / processBlockAndRecoverReorg.
        // `resolve` already paid a CAS hit, but this still avoids the full-subtree
        // resolve + state-apply cost that follows for forged announcements.
        if !isBlockPoWValid(block) {
            tally.recordFailure(peer: peer)
            return
        }

        if await checkSyncNeeded(
            peerBlock: block,
            peerTipCID: cid,
            network: network
        ) {
            tally.recordSuccess(peer: peer)
            return
        }

        let outcome = await processBlockAndRecoverReorg(
            header: header, directory: directory, fetcher: resolveFetcher,
            resolvedBlock: block
        )
        switch outcome {
        case .accepted:
            tally.recordSuccess(peer: peer)
            if let blockData = try? await resolveFetcher.fetch(rawCid: cid) {
                await network.announceStoredBlock(cid: cid, data: blockData)
            }
            await maybePersist(directory: directory)
        case .duplicate:
            tally.recordSuccess(peer: peer)
        case .rejected:
            tally.recordFailure(peer: peer)
        }
    }

    func isPeerBlockRateLimited(_ peer: PeerID) -> Bool {
        let now = ContinuousClock.Instant.now

        // Evict oldest entries when over hard cap (LRU: oldest are at front)
        while peerBlockCounts.count > Self.peerBlockCountCleanupThreshold {
            peerBlockCounts.removeFirst()
        }

        if let entry = peerBlockCounts[peer] {
            if now - entry.windowStart < Self.peerRateWindow {
                if entry.count >= Self.maxBlocksPerPeerPerWindow {
                    return true
                }
                // Move to end (most recently used)
                peerBlockCounts.removeValue(forKey: peer)
                peerBlockCounts[peer] = (count: entry.count + 1, windowStart: entry.windowStart)
            } else {
                peerBlockCounts.removeValue(forKey: peer)
                peerBlockCounts[peer] = (count: 1, windowStart: now)
            }
        } else {
            peerBlockCounts[peer] = (count: 1, windowStart: now)
        }
        return false
    }

    func recentBlockTime(for key: String) -> ContinuousClock.Instant? {
        recentPeerBlocks[key]
    }

    static let maxRecentPeerBlocks = 4096
    /// How long a `recentPeerBlocks` entry remains useful. The dedup check
    /// only cares about hits inside `blockDeduplicationWindow` (100ms), so
    /// anything older than ~60s is dead weight that the LRU hard-cap would
    /// eventually evict — a periodic sweep drops it earlier and keeps memory
    /// bounded under steady-state churn.
    static let recentPeerBlockRetention: Duration = .seconds(60)

    func recordBlockTime(key: String, time: ContinuousClock.Instant) {
        // Move to end on update (LRU touch)
        recentPeerBlocks.removeValue(forKey: key)
        recentPeerBlocks[key] = time
        // Hard cap: evict oldest entries from front
        while recentPeerBlocks.count > Self.maxRecentPeerBlocks {
            recentPeerBlocks.removeFirst()
        }
    }

    /// Drop peer-tracking entries whose time window has elapsed. Hard caps
    /// already keep the dicts from unbounded growth, but a peer that bursts
    /// once and disappears would otherwise sit in `peerBlockCounts` until
    /// 5000 other peers showed up to evict it. Called from the mempool loop.
    func sweepPeerTracking() {
        let now = ContinuousClock.Instant.now
        peerBlockCounts = peerBlockCounts.filter { _, entry in
            now - entry.windowStart < Self.peerRateWindow
        }
        let recentCutoff = Self.recentPeerBlockRetention
        recentPeerBlocks = recentPeerBlocks.filter { _, t in
            now - t < recentCutoff
        }
    }

    // MARK: - Shared Helpers

    /// Build a fetcher that pre-caches mempool transaction data for in-memory resolution.
    func buildMempoolAwareFetcher(directory: String, baseFetcher: Fetcher) async -> Fetcher {
        guard let network = networks[directory] else { return baseFetcher }
        let txDataCache = await network.nodeMempool.fetcherCache()
        return txDataCache.isEmpty ? baseFetcher : MempoolAwareFetcher(inner: baseFetcher, cache: txDataCache)
    }

    /// Resolve a block's transaction dictionary into keyed entries.
    func resolveBlockTransactions(block: Block, fetcher: Fetcher) async -> [String: VolumeImpl<Transaction>] {
        if let txDict = try? await block.transactions.resolveRecursive(fetcher: fetcher).node,
           let entries = try? txDict.allKeysAndValues() {
            return entries
        }
        return [:]
    }

    /// Apply a genesis block's state changes (balances, receipts, etc.) to the chain's StateStore.
    /// Must be called after `registerChainNetwork` and after the genesis block is stored in the CAS.
    public func applyGenesisBlock(directory: String, block: Block) async {
        guard let network = networks[directory] else { return }
        let fetcher = await buildMempoolAwareFetcher(directory: directory, baseFetcher: network.ivyFetcher)
        let blockHash = VolumeImpl<Block>(node: block).rawCID
        let txEntries = await resolveBlockTransactions(block: block, fetcher: fetcher)
        await applyAcceptedBlock(
            block: block, blockHash: blockHash,
            txEntries: txEntries, directory: directory
        )
    }

    /// Register and activate a new child chain with its genesis block.
    /// Orders the steps so the lattice subscription isn't created until the
    /// network is live (avoiding orphan entries on failure), seeds the tip
    /// cache with the genesis hash so the miner's lock-free tip check works,
    /// and persists chain state so the chain survives a restart before any
    /// blocks are mined.
    ///
    /// `parentDirectory` identifies the chain that will anchor the new chain
    /// via merged mining. When `nil`, defaults to the nexus so existing callers
    /// continue to work. For grandchildren (and deeper), pass the intermediate
    /// chain's directory.
    public func deployChildChain(directory: String, parentDirectory: String? = nil, genesisBlock: Block) async throws {
        let nexusDir = genesisConfig.spec.directory
        let parentDir = parentDirectory ?? nexusDir
        guard let parentHit = await lattice.nexus.findLevel(directory: parentDir, chainPath: [nexusDir]) else {
            throw NodeError.parentChainNotFound(parentDir)
        }
        try await registerChainNetworkUsingNodeConfig(directory: directory)
        await parentHit.level.subscribe(to: directory, genesisBlock: genesisBlock, retentionDepth: config.retentionDepth)
        let childPath = parentHit.chainPath + [directory]
        config = config.addingSubscription(chainPath: childPath)
        parentDirectoryByChain[directory] = parentDir
        await persistParentHierarchy()
        if let tip = await chain(for: directory)?.getMainChainTip() {
            tipCaches[directory]?.update(tip)
        }
        guard let network = networks[directory] else { return }
        await storeBlockRecursively(genesisBlock, network: network)
        await pinSpec(block: genesisBlock, chainPath: childPath, network: network)
        await applyGenesisBlock(directory: directory, block: genesisBlock)
        await persistChainState(directory: directory)
    }

    func pinSpec(block: Block, chainPath: [String], network: ChainNetwork) async {
        guard let specData = block.spec.node?.toData() else { return }
        let specCID = block.spec.rawCID
        let pathStr = chainPath.joined(separator: "/")
        let payload = VolumePayload(root: specCID, entries: [specCID: specData])
        try? await network.diskBroker.storeVolumeLocal(payload)
        try? await network.diskBroker.pin(root: specCID, owner: "\(pathStr):spec")
        let fee = await network.ivy.config.relayFee * 2
        let expiry = UInt64(Date().timeIntervalSince1970) + 86400 * 365
        await network.announce(cid: specCID, expiry: expiry, fee: fee)
    }

    /// Apply child block state changes for each child block embedded in `parentBlock`.
    /// Threads `nexusBlockCID` UNCHANGED through recursion: every descendant at
    /// any merged-mining depth pins the same topmost nexus block that admitted
    /// it. One-hop, so prune and cross-chain sync don't need to walk a chain.
    private func applyChildBlockStates(parentBlock: Block, nexusBlockCID: String, fetcher: Fetcher) async {
        let nexusDir = genesisConfig.spec.directory
        await applyChildBlockStates(
            parentBlock: parentBlock,
            parentBlockCID: nexusBlockCID,
            parentChainPath: [nexusDir],
            nexusBlockCID: nexusBlockCID,
            fetcher: fetcher
        )
    }

    private func applyChildBlockStates(
        parentBlock: Block,
        parentBlockCID: String,
        parentChainPath: [String],
        nexusBlockCID: String,
        fetcher: Fetcher
    ) async {
        // Before applying the current parent's child state, attempt to
        // bootstrap any configured-but-unsubscribed child chain present in
        // this parent block. The bootstrap walks parent history backward to
        // anchor every historical child block, validates the chain end-to-end,
        // and registers the network. Idempotent: re-runs only while the
        // directory remains unsubscribed.
        await attemptChildBootstrapsForCurrentParent(
            parentBlock: parentBlock,
            parentBlockCID: parentBlockCID,
            parentChainPath: parentChainPath,
            fetcher: fetcher
        )

        let log = NodeLogger("apply-child")
        guard let childBlocksNode = try? await parentBlock.childBlocks.resolve(
            paths: [[""]: .list], fetcher: fetcher
        ).node,
              let childDirs = try? childBlocksNode.allKeys() else {
            log.warn("parent \(parentBlockCID): childBlocks resolve failed — skipping child apply for this parent")
            return
        }
        for childDir in childDirs {
            guard let childBlockHeader: VolumeImpl<Block> = try? childBlocksNode.get(key: childDir) else {
                log.warn("\(childDir): missing child header in parent \(parentBlockCID) — skipping")
                continue
            }
            let childBlock: Block
            if let n = childBlockHeader.node {
                childBlock = n
            } else {
                guard let resolved = try? await childBlockHeader.resolve(fetcher: fetcher).node else {
                    log.warn("\(childDir): child block resolve failed (header CID \(childBlockHeader.rawCID)) — skipping")
                    continue
                }
                childBlock = resolved
            }

            if let childNet = networks[childDir] {
                await registerChildBlockVolume(
                    childBlock: childBlock,
                    header: childBlockHeader,
                    network: childNet
                )

                // Install the validator pin: child block validates against
                // the topmost nexus block whose PoW admitted this whole tree.
                // Broker pin tag (`validates:<childCID>`) makes the relationship
                // queryable from the network side; StateStore row makes it
                // queryable for prune at retention.
                let childCID = childBlockHeader.rawCID
                try? await childNet.diskBroker.pin(root: nexusBlockCID, owner: "validates:\(childCID)")
                if let store = stateStores[childDir] {
                    await store.persistValidatorPin(
                        height: childBlock.index,
                        childCID: childCID,
                        parentCID: nexusBlockCID
                    )
                }
            }

            // Use the child network's fetcher for resolving child transactions
            // since child tx data lives in the child CAS
            let childFetcher: Fetcher
            if let childNet = networks[childDir] {
                childFetcher = await buildMempoolAwareFetcher(directory: childDir, baseFetcher: childNet.ivyFetcher)
            } else {
                childFetcher = fetcher
            }

            let txEntries = await resolveBlockTransactions(block: childBlock, fetcher: childFetcher)

            await applyAcceptedBlock(
                block: childBlock, blockHash: childBlockHeader.rawCID,
                txEntries: txEntries, directory: childDir
            )

            // Prune confirmed child transactions from the child mempool
            if let childNet = networks[childDir] {
                let confirmedCIDs = Set(txEntries.keys)
                await childNet.nodeMempool.removeAll(txCIDs: confirmedCIDs)
            }

            // Recurse with the SAME nexus CID — every descendant pins the
            // topmost ancestor, not its immediate parent.
            await applyChildBlockStates(
                parentBlock: childBlock,
                parentBlockCID: childBlockHeader.rawCID,
                parentChainPath: parentChainPath + [childDir],
                nexusBlockCID: nexusBlockCID,
                fetcher: childFetcher
            )
        }
    }

    /// Cross-store lookup: a child CID's validator pin row may live in any
    /// chain's StateStore (whichever chain that childCID belongs to). Scan
    /// all per-chain stores until one resolves.
    public func validatorParent(forChildCID childCID: String) async -> String? {
        for (_, store) in stateStores {
            if let parent = store.getValidatorParent(childCID: childCID) {
                return parent
            }
        }
        return nil
    }

    /// Release validator pins at a height: removes both the broker pin
    /// (`validates:<childCID>` owner on the nexus root) and the StateStore
    /// row. Invoked from `pruneBlocks` at the retention boundary so the
    /// nexus block can age out once no descendant references remain.
    private func releaseValidatorPins(directory: String, height: UInt64, network: ChainNetwork) async {
        guard let store = stateStores[directory] else { return }
        let entries = store.getValidatorPins(height: height)
        if entries.isEmpty { return }
        for entry in entries {
            try? await network.diskBroker.unpinAll(owner: "validates:\(entry.childCID)")
        }
        await store.deleteValidatorPins(height: height)
    }

    /// Apply an accepted block's state changes, receipts, fees, events, and metrics.
    func applyAcceptedBlock(
        block: Block,
        blockHash: String,
        txEntries: [String: VolumeImpl<Transaction>],
        directory: String
    ) async {
        let store = stateStores[directory]
        let network = networks[directory]
        let blockHeight = block.index
        let blockTimestamp = block.timestamp

        async let receiptTask = buildReceiptsParallel(
            txEntries: txEntries, blockHash: blockHash,
            blockHeight: blockHeight, blockTimestamp: blockTimestamp
        )

        let (changeset, mempoolNonceUpdates) = extractStateChangeset(
            block: block, blockHash: blockHash,
            txEntries: txEntries
        )

        var txFees: [UInt64] = []
        for (_, txHeader) in txEntries {
            if let fee = txHeader.node?.body.node?.fee, fee > 0 {
                txFees.append(fee)
            }
        }

        let (generalEntries, txHistoryEntries) = await receiptTask

        if let store {
            await store.applyBlock(changeset)
        }

        if let network {
            await network.nodeMempool.batchUpdateConfirmedNonces(updates: mempoolNonceUpdates)
        }

        if let store {
            await store.batchIndexReceipts(generalEntries: generalEntries, txHistory: txHistoryEntries)
        }

        // Pin CIDs for transactions involving our account
        await pinAccountData(
            blockHash: blockHash,
            txEntries: txEntries,
            txHistoryEntries: txHistoryEntries,
            directory: directory
        )

        if !txFees.isEmpty {
            await feeEstimator(for: directory).recordBlock(height: blockHeight, transactionFees: txFees)
        }

        await subscriptions.emit(.newBlock(
            hash: blockHash,
            height: blockHeight,
            directory: directory,
            timestamp: blockTimestamp
        ))

        metrics.increment("lattice_blocks_accepted_total")
        metrics.set("lattice_chain_height", value: Double(blockHeight))
    }

    /// Pin block, transaction, and body CIDs for transactions that involve our account.
    /// These pins are permanent (not subject to FIFO eviction) so the node always
    /// retains and can serve data related to its own address.
    private func pinAccountData(
        blockHash: String,
        txEntries: [String: VolumeImpl<Transaction>],
        txHistoryEntries: [(address: String, txCID: String, blockHash: String, height: UInt64)],
        directory: String
    ) async {
        // Collect txCIDs that involve our address
        let myTxCIDs = Set(txHistoryEntries.filter { $0.address == nodeAddress }.map(\.txCID))
        guard !myTxCIDs.isEmpty, let network = networks[directory] else { return }

        var cidsToPin: [String] = [blockHash]
        for (_, txHeader) in txEntries {
            let txCID = txHeader.rawCID
            guard myTxCIDs.contains(txCID) else { continue }
            cidsToPin.append(txCID)
            if let bodyCID = txHeader.node?.body.rawCID, !bodyCID.isEmpty {
                cidsToPin.append(bodyCID)
            }
        }

        // Pin via the disk broker so the data survives eviction
        for cid in cidsToPin {
            try? await network.diskBroker.pin(root: cid, owner: "account:\(directory)")
        }

        // Announce so peers can discover us as a provider of our own tx data.
        let fee = await network.ivy.config.relayFee * 2
        let expiry = UInt64(Date().timeIntervalSince1970) + 86400
        await withTaskGroup(of: Void.self) { group in
            for cid in cidsToPin {
                group.addTask {
                    await network.announce(cid: cid, expiry: expiry, fee: fee)
                }
            }
        }
    }

    func extractStateChangeset(
        block: Block,
        blockHash: String,
        txEntries: [String: VolumeImpl<Transaction>]
    ) -> (changeset: StateChangeset, mempoolNonceUpdates: [(sender: String, nonce: UInt64)]) {
        // Produce (sender, nextNonce) pairs for mempool confirmedNonce sync.
        // AccountState tree stores `last-used` nonce; mempool stores `next-to-use`.
        var maxSignedNonce: [String: UInt64] = [:]
        var signerOrder: [String] = []
        for (_, txHeader) in txEntries {
            guard let body = txHeader.node?.body.node else { continue }
            let sender = body.signers.first ?? ""
            if maxSignedNonce[sender] == nil {
                signerOrder.append(sender)
                maxSignedNonce[sender] = body.nonce
            } else if body.nonce > maxSignedNonce[sender]! {
                maxSignedNonce[sender] = body.nonce
            }
        }

        let mempoolNonceUpdates: [(sender: String, nonce: UInt64)] = signerOrder.map {
            (sender: $0, nonce: maxSignedNonce[$0]! + 1)
        }

        let changeset = StateChangeset(
            height: block.index,
            blockHash: blockHash,
            timestamp: block.timestamp,
            difficulty: block.difficulty.toHexString(),
            stateRoot: block.frontier.rawCID
        )
        return (changeset, mempoolNonceUpdates)
    }

    /// Build receipt index entries and tx history concurrently.
    /// Each transaction's receipt is independent — JSON encoding runs in parallel via TaskGroup.
    nonisolated func buildReceiptsParallel(
        txEntries: [String: VolumeImpl<Transaction>],
        blockHash: String,
        blockHeight: UInt64,
        blockTimestamp: Int64
    ) async -> (
        generalEntries: [(key: String, value: Data, height: UInt64)],
        txHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)]
    ) {
        struct TxReceiptData: Sendable {
            let generalEntries: [(key: String, value: Data, height: UInt64)]
            let txHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)]
        }

        let txList = Array(txEntries)

        // Process transactions in parallel — each receipt is independent
        // Note: dict keys are sequential indices ("0","1",...) — use rawCID for receipt indexing.
        let results: [TxReceiptData] = await withTaskGroup(of: TxReceiptData.self) { group in
            for (_, txHeader) in txList {
                let txCID = txHeader.rawCID
                group.addTask {
                    var generalEntries: [(key: String, value: Data, height: UInt64)] = []
                    var txHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)] = []

                    struct ReceiptIdx: Codable { let blockHash: String; let blockHeight: UInt64 }
                    if let idxData = try? Self.receiptEncoder.encode(ReceiptIdx(blockHash: blockHash, blockHeight: blockHeight)) {
                        generalEntries.append((key: "receipt-idx:\(txCID)", value: idxData, height: blockHeight))
                    }

                    if let tx = txHeader.node, let body = tx.body.node {
                        // Single iteration: build both txHistory and receipt actions
                        var actions: [TransactionReceipt.ReceiptAction] = []
                        actions.reserveCapacity(body.accountActions.count)
                        for action in body.accountActions {
                            txHistory.append((address: action.owner, txCID: txCID, blockHash: blockHash, height: blockHeight))
                            actions.append(TransactionReceipt.ReceiptAction(owner: action.owner, delta: action.delta))
                        }
                        let receipt = TransactionReceipt(
                            txCID: txCID, blockHash: blockHash, blockHeight: blockHeight,
                            timestamp: blockTimestamp, fee: body.fee,
                            sender: body.signers.first ?? "", status: "confirmed",
                            accountActions: actions
                        )
                        if let data = try? Self.receiptEncoder.encode(receipt) {
                            generalEntries.append((key: "receipt:\(txCID)", value: data, height: blockHeight))
                        }
                    }

                    return TxReceiptData(generalEntries: generalEntries, txHistory: txHistory)
                }
            }

            var collected: [TxReceiptData] = []
            collected.reserveCapacity(txList.count)
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // Merge results — pre-allocate since each tx produces ~2 general + ~1 history entries
        var allGeneral: [(key: String, value: Data, height: UInt64)] = []
        allGeneral.reserveCapacity(txList.count * 2)
        var allTxHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)] = []
        allTxHistory.reserveCapacity(txList.count)
        for result in results {
            allGeneral.append(contentsOf: result.generalEntries)
            allTxHistory.append(contentsOf: result.txHistory)
        }
        return (generalEntries: allGeneral, txHistory: allTxHistory)
    }

    func emitReorgEvent(directory: String, oldTip: String, newTip: String, depth: UInt64) async {
        await subscriptions.emit(.chainReorg(
            directory: directory,
            oldTip: oldTip,
            newTip: newTip,
            depth: depth
        ))
    }

    nonisolated public func lattice(_ lattice: Lattice, didDiscoverChildChain directory: String) async {
        await handleChildChainDiscovery(directory: directory)
    }

    // MARK: - Peer Connection (Chain Tip Exchange)

    nonisolated public func chainNetwork(_ network: ChainNetwork, didConnectPeer peer: PeerID) async {
        let directory = await network.directory
        guard let chainState = await chain(for: directory) else { return }
        let tipCID = await chainState.getMainChainTip()
        let tipIndex = await chainState.getHighestBlockIndex()
        let specCID = await genesisResult.block.spec.rawCID
        await network.sendChainAnnounce(to: peer, tipCID: tipCID, tipIndex: tipIndex, specCID: specCID)
    }

    func handleChildChainDiscovery(directory: String) async {
        let nexusDir = genesisConfig.spec.directory
        // The lattice delegate only carries the directory name; the discovered
        // chain may live anywhere in the tree, so look up its full chain path.
        guard let hit = await lattice.nexus.findLevel(directory: directory, chainPath: [nexusDir]) else { return }
        guard config.isSubscribed(chainPath: hit.chainPath) else { return }
        guard networks[directory] == nil else { return }
        try? await registerChainNetworkUsingNodeConfig(directory: directory)

        // Record the parent so a restart restores the hierarchy correctly.
        if hit.chainPath.count >= 2 {
            let parentDir = hit.chainPath[hit.chainPath.count - 2]
            parentDirectoryByChain[directory] = parentDir
            await persistParentHierarchy()
        }

        // Restore any persisted mempool transactions for this child chain
        if let childNetwork = networks[directory], !config.discoveryOnly {
            await restoreMempool(directory: directory, network: childNetwork, fetcher: childNetwork.ivyFetcher)
        }

        if let childNetwork = networks[directory] {
            let tipHash = await hit.level.chain.getMainChainTip()
            // Seed blocks from the parent's CAS — that's where the merged-mined
            // child block data lives before it's copied into the child network.
            let parentDir = hit.chainPath.count >= 2 ? hit.chainPath[hit.chainPath.count - 2] : nexusDir
            if let parentNetwork = networks[parentDir] {
                await deepCopyBlock(
                    cid: tipHash,
                    from: parentNetwork,
                    to: childNetwork
                )
            }
        }
    }

}

extension IvyFetcher {
    /// Bind `peer` as a known source for every Volume-boundary CID referenced
    /// by `block`. A peer that just announced this block is by transitive
    /// pinning guaranteed to hold every subtree it points at — routing
    /// subsequent resolves directly to them avoids a DHT discovery round
    /// (and the 15s untargeted-walk timeout that follows when the pinner
    /// announcement hasn't yet reached us).
    func bindBlockRoots(_ block: Block, peer: PeerID) async {
        if let prev = block.previousBlock?.rawCID { await bindPinner(rootCID: prev, peer: peer) }
        await bindPinner(rootCID: block.spec.rawCID, peer: peer)
        await bindPinner(rootCID: block.transactions.rawCID, peer: peer)
        await bindPinner(rootCID: block.frontier.rawCID, peer: peer)
        await bindPinner(rootCID: block.homestead.rawCID, peer: peer)
        await bindPinner(rootCID: block.parentHomestead.rawCID, peer: peer)
        await bindPinner(rootCID: block.childBlocks.rawCID, peer: peer)
    }
}

