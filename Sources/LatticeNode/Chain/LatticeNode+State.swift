import Lattice
import Foundation
import cashew
import UInt256

extension LatticeNode {

    public struct ChainInfo: Sendable {
        public let directory: String
        public let height: UInt64
        public let tip: String
        public let mining: Bool
        public let mempoolCount: Int
        public let syncing: Bool
    }

    public func chainStatus() async -> [ChainInfo] {
        var result: [ChainInfo] = []
        let nexusDir = genesisConfig.spec.directory
        let nexusHeight = await lattice.nexus.chain.getHighestBlockIndex()
        let nexusTip = await lattice.nexus.chain.getMainChainTip()
        let nexusMempoolCount = await networks[nexusDir]?.nodeMempool.count ?? 0
        result.append(ChainInfo(
            directory: nexusDir, height: nexusHeight, tip: nexusTip,
            mining: miners[nexusDir] != nil, mempoolCount: nexusMempoolCount,
            syncing: isSyncing
        ))
        let childDirs = await lattice.nexus.childDirectories()
        for dir in childDirs.sorted() {
            if let childLevel = await lattice.nexus.children[dir] {
                let h = await childLevel.chain.getHighestBlockIndex()
                let t = await childLevel.chain.getMainChainTip()
                let mc = await networks[dir]?.nodeMempool.count ?? 0
                result.append(ChainInfo(
                    directory: dir, height: h, tip: t,
                    mining: miners[dir] != nil, mempoolCount: mc,
                    syncing: isChildChainSyncing(directory: dir)
                ))
            }
        }
        return result
    }

    public func getBalance(address: String, directory: String? = nil) async throws -> UInt64 {
        let dir = directory ?? genesisConfig.spec.directory

        if let store = stateStores[dir], let balance = store.getBalance(address: address) {
            return balance
        }

        guard let network = networks[dir] else { return 0 }
        let chain = dir == genesisConfig.spec.directory
            ? await lattice.nexus.chain
            : await lattice.nexus.children[dir]?.chain
        guard let chain else { return 0 }
        guard let snapshot = await chain.tipSnapshot else { return 0 }
        let frontierHeader = LatticeStateHeader(rawCID: snapshot.frontierCID)
        let resolved = try await frontierHeader.resolve(fetcher: network.fetcher)
        guard let state = resolved.node else { return 0 }
        let accountResolved = try await state.accountState.resolve(paths: [[address]: .targeted], fetcher: network.fetcher)
        guard let accountDict = accountResolved.node else { return 0 }
        guard let balance = try? accountDict.get(key: address) else { return 0 }
        return balance
    }

    public func getBlock(hash: String) async throws -> Block? {
        let dir = genesisConfig.spec.directory
        guard let network = networks[dir] else { return nil }
        let header = VolumeImpl<Block>(rawCID: hash)
        return try await header.resolve(fetcher: network.fetcher).node
    }

    public func getBlockHash(atIndex index: UInt64) async -> String? {
        await lattice.nexus.chain.getMainChainBlockHash(atIndex: index)
    }

    public func getDeposit(demander: String, amountDemanded: UInt64, nonce: UInt128, directory: String) async throws -> UInt64? {
        guard let network = networks[directory] else { return nil }
        let chain = directory == genesisConfig.spec.directory
            ? await lattice.nexus.chain
            : await lattice.nexus.children[directory]?.chain
        guard let chain else { return nil }
        guard let snapshot = await chain.tipSnapshot else { return nil }
        let frontierHeader = LatticeStateHeader(rawCID: snapshot.frontierCID)
        let resolved = try await frontierHeader.resolve(fetcher: network.fetcher)
        guard let state = resolved.node else { return nil }
        let key = DepositKey(nonce: nonce, demander: demander, amountDemanded: amountDemanded).description
        let depositResolved = try await state.depositState.resolve(paths: [[key]: .targeted], fetcher: network.fetcher)
        guard let depositDict = depositResolved.node else { return nil }
        return try? depositDict.get(key: key)
    }

    public func getReceipt(demander: String, amountDemanded: UInt64, nonce: UInt128, directory: String) async throws -> String? {
        let nexusDir = genesisConfig.spec.directory
        guard let network = networks[nexusDir] else { return nil }
        let chain = await lattice.nexus.chain
        guard let snapshot = await chain.tipSnapshot else { return nil }
        let frontierHeader = LatticeStateHeader(rawCID: snapshot.frontierCID)
        let resolved = try await frontierHeader.resolve(fetcher: network.fetcher)
        guard let state = resolved.node else { return nil }
        let key = ReceiptKey(receiptAction: ReceiptAction(withdrawer: "", nonce: nonce, demander: demander, amountDemanded: amountDemanded, directory: directory)).description
        let receiptResolved = try await state.receiptState.resolve(paths: [[key]: .targeted], fetcher: network.fetcher)
        guard let receiptDict = receiptResolved.node else { return nil }
        guard let stored: HeaderImpl<PublicKey> = try? receiptDict.get(key: key) else { return nil }
        return stored.rawCID
    }

    public func getBalanceProof(address: String, directory: String? = nil) async throws -> Data? {
        let dir = directory ?? genesisConfig.spec.directory
        guard let network = networks[dir] else { return nil }
        let chain = dir == genesisConfig.spec.directory
            ? await lattice.nexus.chain
            : await lattice.nexus.children[dir]?.chain
        guard let chain else { return nil }
        guard let snapshot = await chain.tipSnapshot else { return nil }
        let frontierHeader = LatticeStateHeader(rawCID: snapshot.frontierCID)
        let resolved = try await frontierHeader.resolve(fetcher: network.fetcher)
        guard let state = resolved.node else { return nil }
        let proofPaths: [[String]: SparseMerkleProof] = [[address]: .existence]
        let proof = try await state.accountState.proof(paths: proofPaths, fetcher: network.fetcher)
        let balance: UInt64
        if let dict = proof.node, let val = try? dict.get(key: address) {
            balance = val
        } else {
            balance = 0
        }
        struct BalanceProof: Encodable {
            let address: String
            let balance: UInt64
            let stateRoot: String
            let accountRoot: String
            let blockHeight: UInt64
            let blockHash: String
        }
        let result = BalanceProof(
            address: address,
            balance: balance,
            stateRoot: snapshot.frontierCID,
            accountRoot: state.accountState.rawCID,
            blockHeight: snapshot.index,
            blockHash: await chain.getMainChainTip()
        )
        return try JSONEncoder().encode(result)
    }
}
