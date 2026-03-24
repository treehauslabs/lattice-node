import Lattice
import Foundation
import Ivy
import Tally
import cashew

extension LatticeNode {

    static let maxTimestampDriftMs: Int64 = 7_200_000

    nonisolated func isBlockTimestampValid(_ block: Block) -> Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if block.timestamp > nowMs + Self.maxTimestampDriftMs {
            return false
        }
        return true
    }

    // MARK: - Recursive Block Storage

    func storeBlockRecursively(_ block: Block, fetcher: AcornFetcher) async {
        let header = HeaderImpl<Block>(node: block)
        let storer = BufferedStorer()
        do {
            try header.storeRecursively(storer: storer)
        } catch {
            let log = NodeLogger("blocks")
            log.error("Failed to store block recursively: \(error)")
        }
        await storer.flush(to: fetcher)
    }

    func deepCopyBlock(cid: String, from source: AcornFetcher, to dest: AcornFetcher) async {
        var visited = Set<String>()
        await copyCIDRecursive(cid, from: source, to: dest, visited: &visited)
    }

    private func copyCIDRecursive(_ cid: String, from source: AcornFetcher, to dest: AcornFetcher, visited: inout Set<String>) async {
        guard !cid.isEmpty, !visited.contains(cid) else { return }
        visited.insert(cid)
        guard let data = try? await source.fetch(rawCid: cid) else { return }
        await dest.store(rawCid: cid, data: data)

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

    func storeReceivedBlockRecursively(cid: String, data: Data, fetcher: AcornFetcher) async {
        await fetcher.store(rawCid: cid, data: data)
        guard let block = Block(data: data) else { return }
        let storer = BufferedStorer()
        let header = HeaderImpl<Block>(node: block)
        do {
            try header.storeRecursively(storer: storer)
        } catch {
            let log = NodeLogger("blocks")
            log.error("Failed to store received block \(cid) recursively: \(error)")
        }
        await storer.flush(to: fetcher)
    }

    // MARK: - Block Processing with Reorg Recovery

    func processBlockAndRecoverReorg(
        header: BlockHeader,
        directory: String,
        fetcher: Fetcher,
        mempool: Mempool
    ) async -> Bool {
        let chain = await lattice.nexus.chain
        let tipBefore = await chain.getMainChainTip()

        let accepted = await lattice.processBlockHeader(header, fetcher: fetcher)
        guard accepted else { return false }

        if let block = try? await header.resolve(fetcher: fetcher).node {
            await blockIndex.insert(height: block.index, hash: header.rawCID)

            let txFees = block.collectTransactionFees()
            if !txFees.isEmpty {
                await feeEstimator.recordBlock(height: block.index, transactionFees: txFees)
            }

            await subscriptions.emit(.newBlock(
                hash: header.rawCID,
                height: block.index,
                directory: directory,
                timestamp: block.timestamp
            ))

            await metrics.increment("lattice_blocks_accepted_total")
            await metrics.set("lattice_chain_height", value: Double(block.index))

            if let store = stateStores[directory] {
                let changeset = await extractStateChangeset(
                    block: block,
                    blockHash: header.rawCID,
                    fetcher: fetcher
                )
                if let changeset {
                    await store.applyBlock(changeset)
                }

                let receiptStore = TransactionReceiptStore(store: store, fetcher: fetcher)
                if let txDict = try? await block.transactions.resolveRecursive(fetcher: fetcher).node,
                   let txEntries = try? txDict.allKeysAndValues() {
                    for (cid, txHeader) in txEntries {
                        await receiptStore.indexReceipt(txCID: cid, blockHash: header.rawCID, blockHeight: block.index)
                        if let tx = txHeader.node, let body = tx.body.node {
                            for action in body.accountActions {
                                await store.indexTransaction(address: action.owner, txCID: cid, blockHash: header.rawCID, height: block.index)
                            }
                            let actions = body.accountActions.map {
                                TransactionReceipt.ReceiptAction(owner: $0.owner, oldBalance: $0.oldBalance, newBalance: $0.newBalance)
                            }
                            await receiptStore.saveReceipt(TransactionReceipt(
                                txCID: cid, blockHash: header.rawCID, blockHeight: block.index,
                                timestamp: block.timestamp, fee: body.fee,
                                sender: body.signers.first ?? "", status: "confirmed",
                                accountActions: actions
                            ))
                        }
                    }
                }
            }
        }

        let tipAfter = await chain.getMainChainTip()
        if tipBefore != tipAfter {
            let parentOfNewTip = await chain.getConsensusBlock(hash: tipAfter)?.previousBlockHash
            if parentOfNewTip != tipBefore {
                await recoverOrphanedTransactions(
                    oldTip: tipBefore,
                    newTip: tipAfter,
                    chain: chain,
                    fetcher: fetcher,
                    mempool: mempool
                )
            }
        }

        return true
    }

    private func recoverOrphanedTransactions(
        oldTip: String,
        newTip: String,
        chain: ChainState,
        fetcher: Fetcher,
        mempool: Mempool
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

        // Step 1: Roll back StateStore via CAS diffs (newest first)
        // orphanedBlockHashes is already newest-to-oldest order
        if let store = stateStores[dir] {
            for blockHash in orphanedBlockHashes {
                guard let blockData = try? await fetcher.fetch(rawCid: blockHash),
                      let block = Block(data: blockData) else { continue }
                do {
                    let newState = try await block.frontier.resolve(fetcher: fetcher)
                    let oldState = try await block.homestead.resolve(fetcher: fetcher)
                    guard let newAccounts = newState.node?.accountState,
                          let oldAccounts = oldState.node?.accountState else { continue }
                    let diff = try await newAccounts.diff(from: oldAccounts, fetcher: fetcher)

                    for (address, _) in diff.inserted {
                        await store.deleteAccount(address: address)
                    }
                    for (address, balanceStr) in diff.deleted {
                        if let balance = UInt64(balanceStr) {
                            await store.setAccount(address: address, balance: balance, nonce: 0, atHeight: block.index)
                        }
                    }
                    for (address, entry) in diff.modified {
                        if let oldBalance = UInt64(entry.old) {
                            await store.setAccount(address: address, balance: oldBalance, nonce: 0, atHeight: block.index)
                        }
                    }
                } catch {
                    log.error("CAS diff failed for orphaned block \(blockHash): \(error)")
                }
            }
        }

        // Step 2: Collect confirmed tx CIDs from the NEW chain (to avoid re-adding them)
        var newChainTxCIDs = Set<String>()
        for newBlockHash in newChainHashes {
            guard let blockData = try? await fetcher.fetch(rawCid: newBlockHash),
                  let block = Block(data: blockData),
                  let txDict = try? await block.transactions.resolveRecursive(fetcher: fetcher).node,
                  let txEntries = try? txDict.allKeysAndValues() else { continue }
            for (cid, _) in txEntries {
                newChainTxCIDs.insert(cid)
            }
        }

        // Step 3: Remove new chain's confirmed txs from both mempools
        if !newChainTxCIDs.isEmpty {
            await mempool.removeAll(txCIDs: newChainTxCIDs)
            if let network {
                await network.nodeMempool.removeAll(txCIDs: newChainTxCIDs)
            }
        }

        // Step 4: Re-validate orphaned txs and add to BOTH mempools
        let validator = TransactionValidator(fetcher: fetcher, chainState: chain)
        var recovered = 0
        for blockHash in orphanedBlockHashes {
            guard let blockData = try? await fetcher.fetch(rawCid: blockHash),
                  let block = Block(data: blockData),
                  let txDict = try? await block.transactions.resolveRecursive(fetcher: fetcher).node,
                  let txEntries = try? txDict.allKeysAndValues() else { continue }

            for (cid, txHeader) in txEntries {
                guard let tx = txHeader.node else { continue }
                if tx.body.node?.fee == 0 && tx.body.node?.nonce == block.index { continue }
                if newChainTxCIDs.contains(cid) { continue }
                let result = await validator.validate(tx)
                if case .success = result {
                    let _ = await mempool.add(transaction: tx)
                    if let network {
                        let _ = await network.nodeMempool.add(transaction: tx)
                    }
                    recovered += 1
                }
            }
        }

        log.info("Reorg complete: \(recovered) tx(s) recovered, \(newChainTxCIDs.count) confirmed in new chain")
        await emitReorgEvent(
            directory: dir,
            oldTip: oldTip,
            newTip: newTip,
            depth: UInt64(orphanedBlockHashes.count)
        )
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

        let fetcher = await network.fetcher
        await storeReceivedBlockRecursively(cid: cid, data: data, fetcher: fetcher)

        if let block = Block(data: data) {
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
        let header = HeaderImpl<Block>(rawCID: cid)
        let mempool = await network.mempool
        let accepted = await processBlockAndRecoverReorg(
            header: header, directory: directory, fetcher: fetcher, mempool: mempool
        )
        if accepted {
            tally.recordSuccess(peer: peer)
            await network.setChainTip(tipCID: cid, referencedCIDs: [])
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

        let fetcher = await network.fetcher

        let header = HeaderImpl<Block>(rawCID: cid)

        if let block = try? await header.resolve(fetcher: fetcher).node {
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
        let mempool = await network.mempool
        let accepted = await processBlockAndRecoverReorg(
            header: header, directory: directory, fetcher: fetcher, mempool: mempool
        )
        if accepted {
            tally.recordSuccess(peer: peer)
            await maybePersist(directory: directory)
        } else {
            tally.recordFailure(peer: peer)
        }
    }

    func isPeerBlockRateLimited(_ peer: PeerID) -> Bool {
        let now = ContinuousClock.Instant.now
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
        if recentPeerBlocks[key] == nil {
            recentPeerBlockOrder.append(key)
        }
        recentPeerBlocks[key] = time
        while recentPeerBlockOrder.count > Self.maxRecentPeerBlocks {
            let oldest = recentPeerBlockOrder.removeFirst()
            recentPeerBlocks.removeValue(forKey: oldest)
        }
    }

    func extractStateChangeset(
        block: Block,
        blockHash: String,
        fetcher: Fetcher
    ) async -> StateChangeset? {
        do {
            let oldState = try await block.homestead.resolve(fetcher: fetcher)
            let newState = try await block.frontier.resolve(fetcher: fetcher)
            guard let oldAccounts = oldState.node?.accountState,
                  let newAccounts = newState.node?.accountState else { return nil }

            let accountDiff = try await newAccounts.diff(from: oldAccounts, fetcher: fetcher)

            var accountUpdates: [(address: String, balance: UInt64, nonce: UInt64)] = []

            for (address, balanceStr) in accountDiff.inserted {
                if let balance = UInt64(balanceStr) {
                    accountUpdates.append((address: address, balance: balance, nonce: 0))
                }
            }

            for (address, entry) in accountDiff.modified {
                if let balance = UInt64(entry.new) {
                    accountUpdates.append((address: address, balance: balance, nonce: 0))
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
        } catch {
            let log = NodeLogger("blocks")
            log.error("CAS diff failed for block \(blockHash): \(error)")
            return nil
        }
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
                    from: nexusNetwork.fetcher,
                    to: childNetwork.fetcher
                )
            }
        }
    }
}

extension Block {
    func collectTransactionFees() -> [UInt64] {
        guard let txDict = self.transactions.node else { return [] }
        guard let entries = try? txDict.allKeysAndValues() else { return [] }
        var fees: [UInt64] = []
        for (_, txHeader) in entries {
            guard let tx = txHeader.node, let fee = tx.body.node?.fee, fee > 0 else { continue }
            fees.append(fee)
        }
        return fees
    }
}
