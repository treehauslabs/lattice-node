import Lattice
import Foundation
import Ivy
import Tally
import cashew

extension LatticeNode {

    private static let receiptEncoder = JSONEncoder()

    static let maxTimestampDriftMs: Int64 = 7_200_000
    static let maxTimestampAgeMs: Int64 = 86_400_000
    static let blockDeduplicationWindow: Duration = .milliseconds(100)
    static let peerBlockCountCleanupThreshold = 5000
    static let peerBlockCountWindow: Duration = .seconds(30)
    static let maxReorgDepth: Int = 100

    nonisolated func isBlockTimestampValid(_ block: Block) -> Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if block.timestamp > nowMs + Self.maxTimestampDriftMs { return false }
        if block.timestamp < nowMs - Self.maxTimestampAgeMs { return false }
        return true
    }

    // MARK: - Recursive Block Storage

    func storeBlockRecursively(_ block: Block, network: ChainNetwork) async {
        let header = VolumeImpl<Block>(node: block)
        let storer = BufferedStorer()
        do {
            try header.storeRecursively(storer: storer)
        } catch {
            let log = NodeLogger("blocks")
            log.error("Failed to store block recursively: \(error)")
        }
        await storer.flush(to: network)
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
        guard let data = try? await source.fetcher.fetch(rawCid: cid) else { return }
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
        await network.storeLocally(cid: cid, data: data)
        guard let block = Block(data: data) else { return }
        let storer = BufferedStorer()
        let header = VolumeImpl<Block>(node: block)
        do {
            try header.storeRecursively(storer: storer)
        } catch {
            let log = NodeLogger("blocks")
            log.error("Failed to store received block \(cid) recursively: \(error)")
        }
        await storer.flush(to: network)
    }

    // MARK: - Block Processing with Reorg Recovery

    func processBlockAndRecoverReorg(
        header: BlockHeader,
        directory: String,
        fetcher: Fetcher,
        resolvedBlock: Block? = nil
    ) async -> Bool {
        guard let chain = await chain(for: directory) else { return false }
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
        let accepted = await lattice.processBlockHeader(header, fetcher: validationFetcher)
        guard accepted else { return false }

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
                await applyChildBlockStates(nexusBlock: block, fetcher: fetcher)
            }
        }

        let tipAfter = await chain.getMainChainTip()
        tipCaches[directory]?.update(tipAfter)
        if tipBefore != tipAfter {
            let parentOfNewTip = await chain.getConsensusBlock(hash: tipAfter)?.previousBlockHash
            if parentOfNewTip != tipBefore {
                await recoverOrphanedTransactions(
                    oldTip: tipBefore,
                    newTip: tipAfter,
                    directory: directory,
                    chain: chain,
                    fetcher: fetcher
                )
            }
        }

        return true
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

        var orphanedBlockHashes: [String] = []
        var current = oldTip
        for _ in 0..<config.retentionDepth {
            if newChainHashes.contains(current) { break }
            orphanedBlockHashes.append(current)
            guard let meta = await chain.getConsensusBlock(hash: current),
                  let prev = meta.previousBlockHash else { break }
            current = prev
        }

        guard !orphanedBlockHashes.isEmpty else { return }
        log.info("Reorg: \(orphanedBlockHashes.count) orphaned block(s)")

        if orphanedBlockHashes.count > Self.maxReorgDepth {
            log.error("Reorg depth \(orphanedBlockHashes.count) exceeds limit \(Self.maxReorgDepth) — potential attack")
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

        // Step 1: Roll back StateStore and resolve orphaned block transactions (newest first)
        // orphanedBlockHashes is already newest-to-oldest order
        let reorgFetcher = await buildMempoolAwareFetcher(directory: dir, baseFetcher: fetcher)

        var orphanedBlockTxs: [(block: Block, txEntries: [String: VolumeImpl<Transaction>])] = []
        for blockHash in orphanedBlockHashes {
            guard let blockData = try? await fetcher.fetch(rawCid: blockHash),
                  let block = Block(data: blockData) else {
                log.error("Missing CAS data for orphaned block \(blockHash) — skipping")
                continue
            }
            let txEntries = await resolveBlockTransactions(block: block, fetcher: reorgFetcher)
            orphanedBlockTxs.append((block: block, txEntries: txEntries))

            if let store = stateStores[dir] {
                for (_, txHeader) in txEntries {
                    guard let body = txHeader.node?.body.node else { continue }
                    for action in body.accountActions {
                        guard action.delta != Int64.min else { continue }
                        let currentBalance = store.getBalance(address: action.owner) ?? 0
                        let previousBalance: UInt64
                        if action.delta > 0 {
                            let credit = UInt64(action.delta)
                            previousBalance = currentBalance >= credit ? currentBalance - credit : 0
                        } else {
                            let (result, overflow) = currentBalance.addingReportingOverflow(UInt64(-action.delta))
                            previousBalance = overflow ? currentBalance : result
                        }
                        if previousBalance == 0 {
                            await store.deleteAccount(address: action.owner)
                        } else {
                            let existingNonce = store.getNonce(address: action.owner) ?? 0
                            await store.setAccount(address: action.owner, balance: previousBalance, nonce: existingNonce, atHeight: block.index)
                        }
                    }
                }
            }
        }

        // Step 2: Collect confirmed tx CIDs from the NEW chain (to avoid re-adding them)
        // Fetch blocks in parallel — each is independent. Use .list to load only radix structure.
        let newChainTxCIDs: Set<String> = await withTaskGroup(of: Set<String>.self) { group in
            for newBlockHash in newChainHashes {
                group.addTask {
                    guard let blockData = try? await fetcher.fetch(rawCid: newBlockHash),
                          let block = Block(data: blockData),
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

        // Step 4: Re-validate orphaned txs and return to mempool
        let isNexus = dir == genesisConfig.spec.directory
        let validator = TransactionValidator(fetcher: fetcher, chainState: chain, stateStore: stateStores[dir], frontierCache: frontierCaches[dir], chainDirectory: dir, isNexus: isNexus)
        var recovered = 0
        for entry in orphanedBlockTxs {
            for (cid, txHeader) in entry.txEntries {
                guard let tx = txHeader.node else { continue }
                if tx.body.node?.fee == 0 && tx.body.node?.nonce == entry.block.index { continue }
                if newChainTxCIDs.contains(cid) { continue }
                let result = await validator.validate(tx)
                if case .success = result, let network {
                    let _ = await network.nodeMempool.add(transaction: tx)
                    recovered += 1
                }
            }
        }

        log.info("Reorg complete: \(recovered) tx(s) recovered, \(newChainTxCIDs.count) confirmed in new chain")

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
            guard let blockData = try? await fetcher.fetch(rawCid: blockHash),
                  let block = Block(data: blockData),
                  let childDict = try? await block.childBlocks.resolve(
                      paths: [[""]: .list], fetcher: fetcher
                  ).node,
                  let childDirs = try? childDict.allKeys() else { continue }

            for childDir in childDirs {
                guard let store = stateStores[childDir] else { continue }
                guard let childBlockHeader: VolumeImpl<Block> = try? childDict.get(key: childDir) else { continue }
                let childBlock: Block
                if let n = childBlockHeader.node {
                    childBlock = n
                } else {
                    guard let resolved = try? await childBlockHeader.resolve(fetcher: fetcher).node else { continue }
                    childBlock = resolved
                }

                let childTxEntries = await resolveBlockTransactions(block: childBlock, fetcher: fetcher)

                // Roll back account state from transaction accountActions
                for (_, txHeader) in childTxEntries {
                    guard let body = txHeader.node?.body.node else { continue }
                    for action in body.accountActions {
                        guard action.delta != Int64.min else { continue }
                        let currentBalance = store.getBalance(address: action.owner) ?? 0
                        let previousBalance: UInt64
                        if action.delta > 0 {
                            let credit = UInt64(action.delta)
                            previousBalance = currentBalance >= credit ? currentBalance - credit : 0
                        } else {
                            let (result, overflow) = currentBalance.addingReportingOverflow(UInt64(-action.delta))
                            previousBalance = overflow ? currentBalance : result
                        }
                        if previousBalance == 0 {
                            await store.deleteAccount(address: action.owner)
                        } else {
                            let nonce = store.getNonce(address: action.owner) ?? 0
                            await store.setAccount(address: action.owner, balance: previousBalance, nonce: nonce, atHeight: childBlock.index)
                        }
                    }
                }

                // Recover orphaned child txs to child mempool (with validation)
                if let childNetwork = networks[childDir],
                   let childChain = await lattice.nexus.children[childDir]?.chain {
                    let validator = TransactionValidator(
                        fetcher: fetcher,
                        chainState: childChain,
                        stateStore: stateStores[childDir],
                        frontierCache: frontierCaches[childDir],
                        chainDirectory: childDir,
                        isNexus: false
                    )
                    for (cid, txHeader) in childTxEntries {
                        guard let tx = txHeader.node else { continue }
                        if tx.body.node?.fee == 0 { continue }
                        if await childNetwork.nodeMempool.contains(txCID: cid) { continue }
                        let result = await validator.validate(tx)
                        if case .success = result {
                            let _ = await childNetwork.nodeMempool.add(transaction: tx)
                        }
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
        let tally = await network.ivy.tally
        guard tally.shouldAllow(peer: peer) else { return }
        if await isPeerBlockRateLimited(peer) { return }

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

        if block.index == 0 && block.previousBlock != nil {
            tally.recordFailure(peer: peer)
            return
        }

        // Basic checks passed — store to CAS
        await storeReceivedBlockRecursively(cid: cid, data: data, network: network)

        if await checkSyncNeeded(
            peerBlock: block,
            peerTipCID: cid,
            network: network
        ) {
            tally.recordSuccess(peer: peer)
            return
        }

        let directory = await network.directory
        let header = VolumeImpl<Block>(rawCID: cid)
        let accepted = await processBlockAndRecoverReorg(
            header: header, directory: directory, fetcher: await network.ivyFetcher,
            resolvedBlock: block
        )
        if accepted {
            tally.recordSuccess(peer: peer)
            await network.setChainTip(tipCID: cid, referencedCIDs: [])
            // Announce accepted block so we earn from serving it
            await network.announceStoredBlock(cid: cid, data: data)
        } else {
            tally.recordFailure(peer: peer)
        }
        await maybePersist(directory: directory)
    }

    nonisolated public func chainNetwork(
        _ network: ChainNetwork,
        didReceiveBlockAnnouncement cid: String,
        from peer: PeerID
    ) async {
        let tally = await network.ivy.tally
        guard tally.shouldAllow(peer: peer) else { return }
        if await isPeerBlockRateLimited(peer) { return }

        let now = ContinuousClock.Instant.now
        if let lastSeen = await recentBlockTime(for: cid) {
            if now - lastSeen < Self.blockDeduplicationWindow { return }
        }
        await recordBlockTime(key: cid, time: now)

        guard !(await isSyncing) else { return }

        let resolveFetcher: any Fetcher = await network.ivyFetcher

        let header = VolumeImpl<Block>(rawCID: cid)

        // Resolve the full block before processing — don't update chain tip
        // unless the block data is locally available for the miner to read.
        guard let block = try? await header.resolve(fetcher: resolveFetcher).node else {
            return
        }

        if !isBlockTimestampValid(block) {
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

        let directory = await network.directory
        let accepted = await processBlockAndRecoverReorg(
            header: header, directory: directory, fetcher: resolveFetcher,
            resolvedBlock: block
        )
        if accepted {
            tally.recordSuccess(peer: peer)
            if let blockData = try? await resolveFetcher.fetch(rawCid: cid) {
                await network.announceStoredBlock(cid: cid, data: blockData)
            }
            await maybePersist(directory: directory)
        } else {
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

    func recordBlockTime(key: String, time: ContinuousClock.Instant) {
        // Move to end on update (LRU touch)
        recentPeerBlocks.removeValue(forKey: key)
        recentPeerBlocks[key] = time
        // Hard cap: evict oldest entries from front
        while recentPeerBlocks.count > Self.maxRecentPeerBlocks {
            recentPeerBlocks.removeFirst()
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

    /// Apply child block state changes for each child block embedded in a nexus block.
    /// Stores the child block in the child CAS, applies state changes (StateStore,
    /// mempool nonces, receipts), and prunes confirmed transactions from the child mempool.
    private func applyChildBlockStates(nexusBlock: Block, fetcher: Fetcher) async {
        guard let childBlocksNode = try? await nexusBlock.childBlocks.resolve(
            paths: [[""]: .list], fetcher: fetcher
        ).node,
              let childDirs = try? childBlocksNode.allKeys() else { return }
        for childDir in childDirs {
            guard let childBlockHeader: VolumeImpl<Block> = try? childBlocksNode.get(key: childDir) else { continue }
            let childBlock: Block
            if let n = childBlockHeader.node {
                childBlock = n
            } else {
                guard let resolved = try? await childBlockHeader.resolve(fetcher: fetcher).node else { continue }
                childBlock = resolved
            }
            // Store the child block and its frontier state in the child CAS.
            // The block data is needed so the miner can fetch the previous block.
            // The frontier state tree (deposits, accounts, etc.) is needed for
            // RPC queries that resolve state from the child chain's CAS.
            // The miner stores everything in the nexus CAS, but the child CAS
            // only has what we explicitly copy here.
            if let childNet = networks[childDir] {
                await storeBlockRecursively(childBlock, network: childNet)
                // The frontier/homestead state trees are content-addressed tries
                // that only exist in the nexus CAS after mining. Resolve them from
                // the nexus fetcher and store in the child CAS so queries work.
                let storer = BufferedStorer()
                if let frontier = try? await childBlock.frontier.resolveRecursive(fetcher: fetcher) {
                    try? frontier.storeRecursively(storer: storer)
                }
                if let homestead = try? await childBlock.homestead.resolveRecursive(fetcher: fetcher) {
                    try? homestead.storeRecursively(storer: storer)
                }
                await storer.flush(to: childNet)
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
        }
    }

    /// Apply an accepted block's state changes, receipts, fees, events, and metrics.
    private func applyAcceptedBlock(
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

        let changeset = extractStateChangeset(
            block: block, blockHash: blockHash,
            txEntries: txEntries, store: store
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
            let nonceUpdates = changeset.accountUpdates.map {
                (sender: $0.address, nonce: $0.nonce)
            }
            await network.nodeMempool.batchUpdateConfirmedNonces(updates: nonceUpdates)
        }

        if let store {
            await store.batchIndexReceipts(generalEntries: generalEntries, txHistory: txHistoryEntries)
        }

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

    func extractStateChangeset(
        block: Block,
        blockHash: String,
        txEntries: [String: VolumeImpl<Transaction>],
        store: StateStore?
    ) -> StateChangeset {
        var senderTxCounts: [String: UInt64] = [:]
        // Aggregate deltas per address across all transactions
        var addressOrder: [String] = []
        var netDeltas: [String: Int64] = [:]

        for (_, txHeader) in txEntries {
            guard let body = txHeader.node?.body.node else { continue }
            let sender = body.signers.first ?? ""
            senderTxCounts[sender, default: 0] += 1
            for action in body.accountActions {
                if netDeltas[action.owner] == nil {
                    addressOrder.append(action.owner)
                }
                let (sum, _) = netDeltas[action.owner, default: 0].addingReportingOverflow(action.delta)
                netDeltas[action.owner] = sum
            }
        }

        // Remove zero-net-delta addresses
        addressOrder.removeAll { netDeltas[$0] == 0 }

        // Batch fetch current balances for all affected addresses
        let currentBalances: [String: UInt64]
        let nonces: [String: UInt64]
        if let store, !addressOrder.isEmpty {
            currentBalances = store.batchGetBalances(addresses: addressOrder)
            nonces = store.batchGetNonces(addresses: addressOrder)
        } else {
            currentBalances = [:]
            nonces = [:]
        }

        var accountUpdates: [(address: String, balance: UInt64, nonce: UInt64)] = []

        for address in addressOrder {
            let delta = netDeltas[address]!
            let current = currentBalances[address] ?? 0
            let newBalance: UInt64
            if delta > 0 {
                let (result, overflow) = current.addingReportingOverflow(UInt64(delta))
                newBalance = overflow ? current : result
            } else if delta != Int64.min {
                let debit = UInt64(-delta)
                newBalance = current >= debit ? current - debit : 0
            } else {
                newBalance = current
            }
            let currentNonce = nonces[address] ?? 0
            let txCount = senderTxCounts[address] ?? 0
            if current == 0 {
                accountUpdates.append((address: address, balance: newBalance, nonce: txCount))
            } else {
                accountUpdates.append((address: address, balance: newBalance, nonce: currentNonce + txCount))
            }
        }

        return StateChangeset(
            height: block.index,
            blockHash: blockHash,
            accountUpdates: accountUpdates,
            timestamp: block.timestamp,
            difficulty: block.difficulty.toHexString(),
            stateRoot: block.frontier.rawCID
        )
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

    func handleChildChainDiscovery(directory: String) async {
        guard config.isSubscribed(chainPath: [genesisConfig.spec.directory, directory]) else { return }
        guard networks[directory] == nil else { return }
        let ivyConfig = IvyConfig(
            publicKey: config.publicKey,
            listenPort: config.listenPort,
            bootstrapPeers: config.bootstrapPeers,
            enableLocalDiscovery: config.enableLocalDiscovery
        )
        try? await registerChainNetwork(directory: directory, config: ivyConfig)

        // Restore any persisted mempool transactions for this child chain
        if let childNetwork = networks[directory], !config.discoveryOnly {
            await restoreMempool(directory: directory, network: childNetwork, fetcher: childNetwork.ivyFetcher)
        }

        if let childNetwork = networks[directory],
           let childLevel = await lattice.nexus.children[directory] {
            let tipHash = await childLevel.chain.getMainChainTip()
            let nexusDir = genesisConfig.spec.directory
            if let nexusNetwork = networks[nexusDir] {
                await deepCopyBlock(
                    cid: tipHash,
                    from: nexusNetwork,
                    to: childNetwork
                )
            }
        }
    }

}

