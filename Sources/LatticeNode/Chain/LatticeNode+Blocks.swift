import Lattice
import Foundation
import Ivy
import Tally
import cashew

extension LatticeNode {

    static let maxTimestampDriftMs: Int64 = 7_200_000
    static let maxReorgDepth: Int = 100

    nonisolated func isBlockTimestampValid(_ block: Block) -> Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if block.timestamp > nowMs + Self.maxTimestampDriftMs { return false }
        if block.timestamp < nowMs - 86_400_000 { return false }
        return true
    }

    // MARK: - Recursive Block Storage

    func storeBlockRecursively(_ block: Block, network: ChainNetwork) async {
        let header = HeaderImpl<Block>(node: block)
        let storer = BufferedStorer()
        do {
            try header.storeRecursively(storer: storer)
        } catch {
            let log = NodeLogger("blocks")
            log.error("Failed to store block recursively: \(error)")
        }
        await storer.flush(to: network)
    }

    func deepCopyBlock(cid: String, from source: ChainNetwork, to dest: ChainNetwork) async {
        var visited = Set<String>()
        await copyCIDRecursive(cid, from: source, to: dest, visited: &visited)
    }

    private func copyCIDRecursive(_ cid: String, from source: ChainNetwork, to dest: ChainNetwork, visited: inout Set<String>) async {
        guard !cid.isEmpty, !visited.contains(cid) else { return }
        visited.insert(cid)
        guard let data = try? await source.fetcher.fetch(rawCid: cid) else { return }
        await dest.storeLocally(cid: cid, data: data)

        if let block = Block(data: data) {
            if let prevCID = block.previousBlock?.rawCID {
                await copyCIDRecursive(prevCID, from: source, to: dest, visited: &visited)
            }
            await copyCIDRecursive(block.transactions.rawCID, from: source, to: dest, visited: &visited)
            await copyCIDRecursive(block.spec.rawCID, from: source, to: dest, visited: &visited)
            await copyCIDRecursive(block.homestead.rawCID, from: source, to: dest, visited: &visited)
            await copyCIDRecursive(block.frontier.rawCID, from: source, to: dest, visited: &visited)
            await copyCIDRecursive(block.parentHomestead.rawCID, from: source, to: dest, visited: &visited)
            await copyCIDRecursive(block.childBlocks.rawCID, from: source, to: dest, visited: &visited)
        }
    }

    func storeReceivedBlockRecursively(cid: String, data: Data, network: ChainNetwork) async {
        await network.storeLocally(cid: cid, data: data)
        guard let block = Block(data: data) else { return }
        let storer = BufferedStorer()
        let header = HeaderImpl<Block>(node: block)
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
        let chain: ChainState
        if directory == genesisConfig.spec.directory {
            chain = await lattice.nexus.chain
        } else if let childLevel = await lattice.nexus.children[directory] {
            chain = await childLevel.chain
        } else {
            return false
        }
        let tipBefore = await chain.getMainChainTip()

        let accepted = await lattice.processBlockHeader(header, fetcher: fetcher)
        guard accepted else { return false }

        let block: Block?
        if let r = resolvedBlock {
            block = r
        } else {
            block = try? await header.resolve(fetcher: fetcher).node
        }
        if let block {
            // Build mempool-aware fetcher: pre-compute Volume CIDs from mempool
            // transactions so resolveRecursive hits in-memory cache instead of network.
            // Each transaction in the block is a VolumeImpl<Transaction> boundary —
            // the cache short-circuits both fetch() and provide() (pinner discovery).
            let txFetcher: Fetcher
            if let network = networks[directory] {
                let mempoolTxs = await network.nodeMempool.allTransactions()
                var txDataCache: [String: Data] = [:]
                txDataCache.reserveCapacity(mempoolTxs.count * 2)
                for tx in mempoolTxs {
                    if let data = tx.toData() {
                        let volumeCID = VolumeImpl<Transaction>(node: tx).rawCID
                        txDataCache[volumeCID] = data
                    }
                    // Also cache body data so body resolution is in-memory too
                    if let bodyNode = tx.body.node, let bodyData = bodyNode.toData() {
                        txDataCache[tx.body.rawCID] = bodyData
                    }
                }
                txFetcher = txDataCache.isEmpty ? fetcher : MempoolAwareFetcher(inner: fetcher, cache: txDataCache)
            } else {
                txFetcher = fetcher
            }

            // Resolve transactions once — used for fees, state changeset, and receipts
            let txEntries: [String: HeaderImpl<Transaction>]
            if let txDict = try? await block.transactions.resolveRecursive(fetcher: txFetcher).node,
               let entries = try? txDict.allKeysAndValues() {
                txEntries = entries
            } else {
                txEntries = [:]
            }

            let store = stateStores[directory]
            let network = networks[directory]

            // Parallel Phase: extract changeset + build receipts concurrently.
            // extractStateChangeset uses batch SQL (1 query for all nonces).
            // Receipt building runs concurrently using a task group for JSON encoding.
            let blockHash = header.rawCID
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

            // Extract fees inline (lightweight — just reads from already-resolved tx bodies)
            var txFees: [UInt64] = []
            for (_, txHeader) in txEntries {
                if let fee = txHeader.node?.body.node?.fee, fee > 0 {
                    txFees.append(fee)
                }
            }

            // Wait for receipts
            let (generalEntries, txHistoryEntries) = await receiptTask

            // Sequential Phase: apply state, emit events, index receipts
            if let store {
                await store.applyBlock(changeset)
            }

            // Batch mempool nonce update — one actor hop instead of N
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
                await feeEstimator.recordBlock(height: blockHeight, transactionFees: txFees)
            }

            await subscriptions.emit(.newBlock(
                hash: blockHash,
                height: blockHeight,
                directory: directory,
                timestamp: blockTimestamp
            ))

            await metrics.increment("lattice_blocks_accepted_total")
            await metrics.set("lattice_chain_height", value: Double(blockHeight))
        }

        let tipAfter = await chain.getMainChainTip()
        tipCaches[directory]?.update(tipAfter)
        if tipBefore != tipAfter {
            let parentOfNewTip = await chain.getConsensusBlock(hash: tipAfter)?.previousBlockHash
            if parentOfNewTip != tipBefore {
                await recoverOrphanedTransactions(
                    oldTip: tipBefore,
                    newTip: tipAfter,
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
        chain: ChainState,
        fetcher: Fetcher
    ) async {
        let log = NodeLogger("reorg")
        let dir = genesisConfig.spec.directory
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
        // Build mempool-aware fetcher once for all orphaned blocks
        let reorgFetcher: Fetcher
        if let network {
            let mempoolTxs = await network.nodeMempool.allTransactions()
            var txDataCache: [String: Data] = [:]
            txDataCache.reserveCapacity(mempoolTxs.count * 2)
            for tx in mempoolTxs {
                if let data = tx.toData() {
                    txDataCache[VolumeImpl<Transaction>(node: tx).rawCID] = data
                }
                if let bodyNode = tx.body.node, let bodyData = bodyNode.toData() {
                    txDataCache[tx.body.rawCID] = bodyData
                }
            }
            reorgFetcher = txDataCache.isEmpty ? fetcher : MempoolAwareFetcher(inner: fetcher, cache: txDataCache)
        } else {
            reorgFetcher = fetcher
        }

        var orphanedBlockTxs: [(block: Block, txEntries: [String: HeaderImpl<Transaction>])] = []
        for blockHash in orphanedBlockHashes {
            guard let blockData = try? await fetcher.fetch(rawCid: blockHash),
                  let block = Block(data: blockData) else {
                log.error("Missing CAS data for orphaned block \(blockHash) — skipping")
                continue
            }
            let txEntries: [String: HeaderImpl<Transaction>]
            if let txDict = try? await block.transactions.resolveRecursive(fetcher: reorgFetcher).node,
               let entries = try? txDict.allKeysAndValues() {
                txEntries = entries
            } else {
                txEntries = [:]
            }
            orphanedBlockTxs.append((block: block, txEntries: txEntries))

            if let store = stateStores[dir] {
                for (_, txHeader) in txEntries {
                    guard let body = txHeader.node?.body.node else { continue }
                    for action in body.accountActions {
                        if action.oldBalance == 0 {
                            await store.deleteAccount(address: action.owner)
                        } else if action.newBalance != action.oldBalance {
                            let existingNonce = store.getNonce(address: action.owner) ?? 0
                            await store.setAccount(address: action.owner, balance: action.oldBalance, nonce: existingNonce, atHeight: block.index)
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
        let validator = TransactionValidator(fetcher: fetcher, chainState: chain, stateStore: stateStores[dir])
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
                guard let childBlockHeader: HeaderImpl<Block> = try? childDict.get(key: childDir) else { continue }
                let childBlock: Block
                if let n = childBlockHeader.node {
                    childBlock = n
                } else {
                    guard let resolved = try? await childBlockHeader.resolve(fetcher: fetcher).node else { continue }
                    childBlock = resolved
                }

                let childTxEntries: [String: HeaderImpl<Transaction>]
                if let txDict = try? await childBlock.transactions.resolveRecursive(fetcher: fetcher).node,
                   let txEs = try? txDict.allKeysAndValues() {
                    childTxEntries = txEs
                } else {
                    childTxEntries = [:]
                }

                // Roll back account state from transaction accountActions
                for (_, txHeader) in childTxEntries {
                    guard let body = txHeader.node?.body.node else { continue }
                    for action in body.accountActions {
                        if action.oldBalance == 0 {
                            await store.deleteAccount(address: action.owner)
                        } else if action.newBalance != action.oldBalance {
                            let nonce = store.getNonce(address: action.owner) ?? 0
                            await store.setAccount(address: action.owner, balance: action.oldBalance, nonce: nonce, atHeight: childBlock.index)
                        }
                    }
                }

                // Recover orphaned child txs to child mempool (with validation)
                if let childNetwork = networks[childDir],
                   let childChain = await lattice.nexus.children[childDir]?.chain {
                    let validator = TransactionValidator(
                        fetcher: fetcher,
                        chainState: childChain,
                        stateStore: stateStores[childDir]
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
            if elapsed < .milliseconds(100) {
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
        let header = HeaderImpl<Block>(rawCID: cid)
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
            if now - lastSeen < .milliseconds(100) { return }
        }
        await recordBlockTime(key: cid, time: now)

        guard !(await isSyncing) else { return }

        let resolveFetcher: any Fetcher = await network.ivyFetcher

        let header = HeaderImpl<Block>(rawCID: cid)

        if let block = try? await header.resolve(fetcher: resolveFetcher).node {
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
        }

        let directory = await network.directory
        let accepted = await processBlockAndRecoverReorg(
            header: header, directory: directory, fetcher: resolveFetcher
        )
        if accepted {
            tally.recordSuccess(peer: peer)
            // Announce accepted block for earning
            if let block = try? await header.resolve(fetcher: resolveFetcher).node,
               let blockData = block.toData() {
                await network.announceStoredBlock(cid: cid, data: blockData)
            }
            await maybePersist(directory: directory)
        } else {
            tally.recordFailure(peer: peer)
        }
    }

    func isPeerBlockRateLimited(_ peer: PeerID) -> Bool {
        let now = ContinuousClock.Instant.now

        if peerBlockCounts.count > 5000 {
            peerBlockCounts = peerBlockCounts.filter { now - $0.value.windowStart < .seconds(30) }
        }

        if let entry = peerBlockCounts[peer] {
            if now - entry.windowStart < Self.peerRateWindow {
                if entry.count >= Self.maxBlocksPerPeerPerWindow {
                    return true
                }
                peerBlockCounts[peer] = (count: entry.count + 1, windowStart: entry.windowStart)
            } else {
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
        recentPeerBlocks[key] = time
        if recentPeerBlocks.count > Self.maxRecentPeerBlocks * 2 {
            let cutoff = time - .seconds(30)
            recentPeerBlocks = recentPeerBlocks.filter { $0.value >= cutoff }
        }
    }

    func extractStateChangeset(
        block: Block,
        blockHash: String,
        txEntries: [String: HeaderImpl<Transaction>],
        store: StateStore?
    ) -> StateChangeset {
        var senderTxCounts: [String: UInt64] = [:]
        var accountChanges: [(address: String, oldBalance: UInt64, newBalance: UInt64)] = []

        for (_, txHeader) in txEntries {
            guard let body = txHeader.node?.body.node else { continue }
            if body.fee > 0 {
                let sender = body.signers.first ?? ""
                senderTxCounts[sender, default: 0] += 1
            }
            for action in body.accountActions {
                accountChanges.append((action.owner, action.oldBalance, action.newBalance))
            }
        }

        // Batch fetch all nonces in a single SQL query instead of N individual lookups
        let addressesNeedingNonce = Set(
            accountChanges
                .filter { $0.oldBalance != 0 && $0.oldBalance != $0.newBalance }
                .map { $0.address }
        )
        let nonces: [String: UInt64]
        if let store, !addressesNeedingNonce.isEmpty {
            nonces = store.batchGetNonces(addresses: Array(addressesNeedingNonce))
        } else {
            nonces = [:]
        }

        var accountUpdates: [(address: String, balance: UInt64, nonce: UInt64)] = []

        for change in accountChanges {
            if change.oldBalance == 0 {
                let txCount = senderTxCounts[change.address] ?? 0
                accountUpdates.append((address: change.address, balance: change.newBalance, nonce: txCount))
            } else if change.oldBalance != change.newBalance {
                let currentNonce = nonces[change.address] ?? 0
                let txCount = senderTxCounts[change.address] ?? 0
                accountUpdates.append((address: change.address, balance: change.newBalance, nonce: currentNonce + txCount))
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
        txEntries: [String: HeaderImpl<Transaction>],
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
        let results: [TxReceiptData] = await withTaskGroup(of: TxReceiptData.self) { group in
            for (cid, txHeader) in txList {
                group.addTask {
                    var generalEntries: [(key: String, value: Data, height: UInt64)] = []
                    var txHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)] = []

                    struct ReceiptIdx: Codable { let blockHash: String; let blockHeight: UInt64 }
                    if let idxData = try? JSONEncoder().encode(ReceiptIdx(blockHash: blockHash, blockHeight: blockHeight)) {
                        generalEntries.append((key: "receipt-idx:\(cid)", value: idxData, height: blockHeight))
                    }

                    if let tx = txHeader.node, let body = tx.body.node {
                        for action in body.accountActions {
                            txHistory.append((address: action.owner, txCID: cid, blockHash: blockHash, height: blockHeight))
                        }
                        let actions = body.accountActions.map {
                            TransactionReceipt.ReceiptAction(owner: $0.owner, oldBalance: $0.oldBalance, newBalance: $0.newBalance)
                        }
                        let receipt = TransactionReceipt(
                            txCID: cid, blockHash: blockHash, blockHeight: blockHeight,
                            timestamp: blockTimestamp, fee: body.fee,
                            sender: body.signers.first ?? "", status: "confirmed",
                            accountActions: actions
                        )
                        if let data = try? JSONEncoder().encode(receipt) {
                            generalEntries.append((key: "receipt:\(cid)", value: data, height: blockHeight))
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

        // Merge results
        var allGeneral: [(key: String, value: Data, height: UInt64)] = []
        var allTxHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)] = []
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

