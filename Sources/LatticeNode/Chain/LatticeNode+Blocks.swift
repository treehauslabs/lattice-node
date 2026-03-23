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
        try? header.storeRecursively(storer: storer)
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
        try? header.storeRecursively(storer: storer)
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
        let validator = TransactionValidator(fetcher: fetcher, chainState: chain)
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

        for blockHash in orphanedBlockHashes {
            guard let blockData = try? await fetcher.fetch(rawCid: blockHash),
                  let block = Block(data: blockData) else { continue }
            guard let txDict = try? await block.transactions.resolveRecursive(fetcher: fetcher).node else { continue }
            guard let txEntries = try? txDict.allKeysAndValues() else { continue }

            for (_, txHeader) in txEntries {
                guard let tx = txHeader.node else { continue }
                if tx.body.node?.fee == 0 && tx.body.node?.nonce == block.index {
                    continue
                }
                let validationResult = await validator.validate(tx)
                if case .success = validationResult {
                    let _ = await mempool.add(transaction: tx)
                }
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

        if let blockData = try? await fetcher.fetch(rawCid: cid) {
            await storeReceivedBlockRecursively(cid: cid, data: blockData, fetcher: fetcher as! AcornFetcher)
        }

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
