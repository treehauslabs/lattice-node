import Lattice
import Foundation
import Ivy
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
        let childContexts = await buildChildMiningContexts()
        let miner = MinerLoop(
            chainState: chainState,
            mempool: network.nodeMempool,
            fetcher: network.fetcher,
            spec: genesisConfig.spec,
            identity: identity,
            childContexts: childContexts,
            batchSize: config.resources.miningBatchSize
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
        let header = HeaderImpl<Block>(node: block)
        guard let blockData = block.toData() else { return }

        await storeBlockRecursively(block, fetcher: network.fetcher)
        await network.publishBlock(cid: header.rawCID, data: blockData)
        await network.setChainTip(tipCID: header.rawCID, referencedCIDs: [])
        let accepted = await processBlockAndRecoverReorg(
            header: header,
            directory: directory,
            fetcher: network.fetcher
        )
        if accepted, let removals = pendingRemovals {
            await network.pruneConfirmedTransactions(txCIDs: removals.nexusTxCIDs)
            for childRemoval in removals.childTxRemovals {
                await childRemoval.mempool.removeAll(txCIDs: childRemoval.txCIDs)
            }
        }
        await maybePersist(directory: directory)
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
            guard let childSpec = try? await specHeader.resolve(fetcher: network.fetcher).node else { continue }
            contexts.append(ChildMiningContext(
                directory: dir,
                chainState: childChainState,
                mempool: network.nodeMempool,
                fetcher: network.fetcher,
                spec: childSpec
            ))
        }
        return contexts
    }
}
