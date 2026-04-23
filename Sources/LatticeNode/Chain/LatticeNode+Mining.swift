import Lattice
import Foundation
import Ivy
import Tally
import cashew

extension LatticeNode {

    public func startMining(directory: String, identity: MinerIdentity? = nil) async {
        let nexusDir = genesisConfig.spec.directory
        if directory != nexusDir {
            guard networks[directory] != nil else { return }
            let chainPath = [nexusDir, directory]
            if !config.isSubscribed(chainPath: chainPath) {
                config = config.addingSubscription(chainPath: chainPath)
            }
            if miners[nexusDir] == nil {
                await startMining(directory: nexusDir, identity: identity)
            }
            return
        }

        guard let network = networks[directory] else { return }
        guard miners[directory] == nil else { return }
        guard let chainState = await chain(for: directory) else { return }
        let identity = identity ?? MinerIdentity(
            publicKeyHex: config.publicKey,
            privateKeyHex: config.privateKey
        )
        let tipCache = tipCaches[directory]
        let childProvider: (@Sendable () async -> [ChildMiningContext])? = { @Sendable [weak self] in
            await self?.buildChildMiningContexts() ?? []
        }
        let miner = MinerLoop(
            chainState: chainState,
            mempool: network.nodeMempool,
            fetcher: network.ivyFetcher,
            spec: genesisConfig.spec,
            chainPath: [nexusDir],
            identity: identity,
            childContextProvider: childProvider,
            batchSize: config.resources.miningBatchSize,
            tipCache: tipCache
        )
        await miner.setDelegate(self)
        miners[directory] = miner
        await miner.start()
    }

    public func stopMining(directory: String) async {
        let nexusDir = genesisConfig.spec.directory
        if directory != nexusDir {
            let chainPath = [nexusDir, directory]
            if config.isSubscribed(chainPath: chainPath) {
                config = config.removingSubscription(chainPath: chainPath)
            }
            return
        }
        guard let miner = miners[directory] else { return }
        await miner.stop()
        miners.removeValue(forKey: directory)
    }

    nonisolated public func minerDidProduceBlock(_ block: Block, hash: String, pendingRemovals: MinedBlockPendingRemovals) async {
        let directory = block.spec.node?.directory ?? "Nexus"
        await submitMinedBlock(directory: directory, block: block, pendingRemovals: pendingRemovals)
    }

    public func submitMinedBlock(directory: String, block: Block, pendingRemovals: MinedBlockPendingRemovals? = nil) async {
        guard let network = networks[directory] else { return }
        let header = VolumeImpl<Block>(node: block)
        guard let blockData = block.toData() else { return }

        let log = NodeLogger("miner")
        log.info("\(directory): mined block \(String(header.rawCID.prefix(16)))… at index \(block.index) (txs=\(block.transactions.node?.count ?? 0))")

        await storeBlockRecursively(block, network: network)
        await network.publishBlock(cid: header.rawCID, data: blockData)
        await network.setChainTip(tipCID: header.rawCID, stateRoots: Self.stateRoots(of: block))

        // Settlement: submit mining work to Ivy creditors
        // The block hash serves as proof of work — creditors verify it meets difficulty
        let blockHash = Data(header.rawCID.utf8)
        await settleWithCreditors(network: network, nonce: block.nonce, blockHash: blockHash)

        Self.diagLog("submitMinedBlock \(directory) index=\(block.index) cid=\(String(header.rawCID.prefix(16)))…")
        let outcome = await processBlockAndRecoverReorg(
            header: header,
            directory: directory,
            fetcher: network.ivyFetcher,
            resolvedBlock: block,
            skipValidation: true
        )
        Self.diagLog("submitMinedBlock done \(directory) index=\(block.index) outcome=\(outcome)")
        let accepted = outcome == .accepted
        if outcome == .rejected {
            log.warn("\(directory): mined block at index \(block.index) was NOT accepted")
        }
        if accepted, let removals = pendingRemovals {
            await network.pruneConfirmedTransactions(txCIDs: removals.nexusTxCIDs)
            for childRemoval in removals.childTxRemovals {
                await childRemoval.mempool.removeAll(txCIDs: childRemoval.txCIDs)
            }
        }
        await maybePersist(directory: directory)
    }

    /// Submit mining proof to Ivy creditors to settle outstanding debt.
    /// Each mined block is simultaneously a settlement proof — the work was real.
    /// We settle whenever we have any debt, not just past threshold, because
    /// graduated debt pressure means even small debt reduces our service quality.
    private func settleWithCreditors(network: ChainNetwork, nonce: UInt64, blockHash: Data) async {
        let ledger = await network.ivy.ledger
        let allLines = await ledger.allLines
        for (peer, line) in allLines {
            // Settle with any peer we owe (negative balance = we're the debtor)
            guard line.balance < 0 else { continue }

            await network.ivy.submitSettlement(
                to: peer,
                nonce: nonce,
                hash: blockHash,
                blockNonce: nonce
            )
        }
    }

    func buildChildMiningContexts() async -> [ChildMiningContext] {
        let nexusDir = genesisConfig.spec.directory
        return await buildChildMiningContexts(level: lattice.nexus, chainPath: [nexusDir])
    }

    private func buildChildMiningContexts(level: ChainLevel, chainPath: [String]) async -> [ChildMiningContext] {
        var contexts: [ChildMiningContext] = []
        let childDirs = await level.childDirectories()
        for dir in childDirs {
            let childPath = chainPath + [dir]
            guard config.isSubscribed(chainPath: childPath) else { continue }
            guard let childChainState = await level.children[dir]?.chain else { continue }
            guard let childLevel = await level.children[dir] else { continue }
            guard let network = networks[dir] else { continue }
            let tipSnapshot = await childChainState.tipSnapshot
            guard let specCID = tipSnapshot?.specCID else { continue }
            let specHeader = HeaderImpl<ChainSpec>(rawCID: specCID)
            guard let childSpec = try? await specHeader.resolve(fetcher: network.ivyFetcher).node else { continue }
            let grandchildren = await buildChildMiningContexts(level: childLevel, chainPath: childPath)
            contexts.append(ChildMiningContext(
                directory: dir,
                chainPath: childPath,
                chainState: childChainState,
                mempool: network.nodeMempool,
                fetcher: network.ivyFetcher,
                spec: childSpec,
                children: grandchildren
            ))
        }
        return contexts
    }
}
