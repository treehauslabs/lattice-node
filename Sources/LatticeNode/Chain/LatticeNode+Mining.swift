import Lattice
import Foundation
import Ivy
import Tally
import cashew

extension LatticeNode {

    public func startMining(directory: String) async {
        guard let network = networks[directory] else { return }
        guard miners[directory] == nil else { return }

        let nexus = await lattice.nexus
        let chainState = await nexus.chain
        let identity = MinerIdentity(
            publicKeyHex: config.publicKey,
            privateKeyHex: config.privateKey
        )
        let tipCache = tipCaches[directory]
        let miner = MinerLoop(
            chainState: chainState,
            mempool: network.nodeMempool,
            fetcher: network.ivyFetcher,
            spec: genesisConfig.spec,
            identity: identity,
            childContextProvider: { [weak self] in
                await self?.buildChildMiningContexts() ?? []
            },
            batchSize: config.resources.miningBatchSize,
            tipCache: tipCache
        )
        await miner.setDelegate(self)
        miners[directory] = miner
        await miner.start()
    }

    public func stopMining(directory: String) async {
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

        await storeBlockRecursively(block, network: network)
        await network.publishBlock(cid: header.rawCID, data: blockData)
        await network.setChainTip(tipCID: header.rawCID, referencedCIDs: [])

        // Settlement: submit mining work to Ivy creditors
        // The block hash serves as proof of work — creditors verify it meets difficulty
        let blockHash = Data(header.rawCID.utf8)
        await settleWithCreditors(network: network, nonce: block.nonce, blockHash: blockHash)

        let accepted = await processBlockAndRecoverReorg(
            header: header,
            directory: directory,
            fetcher: network.ivyFetcher,
            resolvedBlock: block
        )
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
        var contexts: [ChildMiningContext] = []
        let nexusDir = genesisConfig.spec.directory
        let childDirs = await lattice.nexus.childDirectories()
        for dir in childDirs {
            guard config.isSubscribed(chainPath: [nexusDir, dir]) else { continue }
            guard let network = networks[dir] else { continue }
            guard let childChainState = await lattice.nexus.children[dir]?.chain else { continue }
            let tipSnapshot = await childChainState.tipSnapshot
            guard let specCID = tipSnapshot?.specCID else { continue }
            let specHeader = HeaderImpl<ChainSpec>(rawCID: specCID)
            guard let childSpec = try? await specHeader.resolve(fetcher: network.ivyFetcher).node else { continue }
            contexts.append(ChildMiningContext(
                directory: dir,
                chainState: childChainState,
                mempool: network.nodeMempool,
                fetcher: network.ivyFetcher,
                spec: childSpec
            ))
        }
        return contexts
    }
}
