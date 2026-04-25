import Lattice
import Foundation
import cashew
import UInt256

extension LatticeNode {

    public struct ChainInfo: Sendable {
        public let directory: String
        public let parentDirectory: String?
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
            directory: nexusDir, parentDirectory: nil,
            height: nexusHeight, tip: nexusTip,
            mining: miners[nexusDir] != nil, mempoolCount: nexusMempoolCount,
            syncing: isSyncing
        ))
        // Walk the whole ChainLevel tree so grandchildren show up too.
        let allLevels = await lattice.nexus.collectAllLevels(chainPath: [nexusDir])
        let children = allLevels.filter { $0.chainPath.count >= 2 }
            .sorted { $0.chainPath.joined(separator: "/") < $1.chainPath.joined(separator: "/") }
        for (childLevel, path) in children {
            let dir = path.last ?? ""
            let parent = path.count >= 2 ? path[path.count - 2] : nil
            let h = await childLevel.chain.getHighestBlockIndex()
            let t = await childLevel.chain.getMainChainTip()
            let mc = await networks[dir]?.nodeMempool.count ?? 0
            result.append(ChainInfo(
                directory: dir, parentDirectory: parent,
                height: h, tip: t,
                mining: await isMining(directory: dir), mempoolCount: mc,
                syncing: isChildChainSyncing(directory: dir)
            ))
        }
        return result
    }

    public func getBalance(address: String, directory: String? = nil) async throws -> UInt64 {
        let dir = directory ?? genesisConfig.spec.directory
        return try await getAccount(address: address, directory: dir).balance
    }

    public func getNextNonce(address: String, directory: String? = nil) async throws -> UInt64 {
        let dir = directory ?? genesisConfig.spec.directory
        guard let tip = try await resolveTipFrontier(directory: dir) else { return 0 }
        let nonceKey = AccountStateHeader.nonceTrackingKey(address)
        let accountResolved = try await tip.state.accountState.resolve(
            paths: [[nonceKey]: .targeted],
            fetcher: tip.fetcher
        )
        guard let dict = accountResolved.node else { return 0 }
        let stored: UInt64? = try? dict.get(key: nonceKey)
        return stored.map { $0 + 1 } ?? 0
    }

    public func getNonce(address: String, directory: String? = nil) async throws -> UInt64 {
        try await getNextNonce(address: address, directory: directory)
    }

    public func getAccount(address: String, directory: String? = nil) async throws -> (balance: UInt64, nonce: UInt64) {
        let dir = directory ?? genesisConfig.spec.directory
        guard let tip = try await resolveTipFrontier(directory: dir) else { return (0, 0) }
        let nonceKey = AccountStateHeader.nonceTrackingKey(address)
        let accountResolved = try await tip.state.accountState.resolve(
            paths: [[address]: .targeted, [nonceKey]: .targeted],
            fetcher: tip.fetcher
        )
        guard let dict = accountResolved.node else { return (0, 0) }
        let balance: UInt64 = (try? dict.get(key: address)) ?? 0
        let stored: UInt64? = try? dict.get(key: nonceKey)
        let nonce = stored.map { $0 + 1 } ?? 0
        return (balance, nonce)
    }

    /// Batch variant — resolves all balances and nonces in a single tree walk.
    /// Used by mining and block-assembly hot paths that need many addresses at once.
    public func batchGetAccounts(addresses: [String], directory: String? = nil) async throws -> [String: (balance: UInt64, nonce: UInt64)] {
        guard !addresses.isEmpty else { return [:] }
        let dir = directory ?? genesisConfig.spec.directory
        guard let tip = try await resolveTipFrontier(directory: dir) else { return [:] }
        var paths = [[String]: ResolutionStrategy]()
        paths.reserveCapacity(addresses.count * 2)
        for addr in addresses {
            paths[[addr]] = .targeted
            paths[[AccountStateHeader.nonceTrackingKey(addr)]] = .targeted
        }
        let resolved = try await tip.state.accountState.resolve(paths: paths, fetcher: tip.fetcher)
        guard let dict = resolved.node else { return [:] }
        var out: [String: (balance: UInt64, nonce: UInt64)] = [:]
        out.reserveCapacity(addresses.count)
        for addr in addresses {
            let balance: UInt64 = (try? dict.get(key: addr)) ?? 0
            let nonce: UInt64 = (try? dict.get(key: AccountStateHeader.nonceTrackingKey(addr))) ?? 0
            out[addr] = (balance, nonce)
        }
        return out
    }

    private func resolveTipFrontier(directory: String) async throws -> (state: LatticeState, fetcher: Fetcher)? {
        guard let network = networks[directory] else { return nil }
        guard let chain = await chain(for: directory) else { return nil }
        guard let snapshot = await chain.tipSnapshot else { return nil }
        let frontierCID = snapshot.frontierCID
        let fetcher = await network.fetcher
        if let cached = await frontierCaches[directory]?.get(frontierCID: frontierCID) {
            return (cached, fetcher)
        }
        let frontierHeader = LatticeStateHeader(rawCID: frontierCID)
        let resolved = try await frontierHeader.resolve(fetcher: fetcher)
        guard let state = resolved.node else { return nil }
        await frontierCaches[directory]?.set(frontierCID: frontierCID, state: state)
        return (state, fetcher)
    }

    public func getBlock(hash: String, directory: String? = nil) async throws -> Block? {
        let dir = directory ?? genesisConfig.spec.directory
        guard let network = networks[dir] else { return nil }
        let header = VolumeImpl<Block>(rawCID: hash)
        return try await header.resolve(fetcher: network.fetcher).node
    }

    public func getBlockHash(atIndex index: UInt64, directory: String? = nil) async -> String? {
        let dir = directory ?? genesisConfig.spec.directory
        if let chainState = await chain(for: dir),
           let hash = await chainState.getMainChainBlockHash(atIndex: index) {
            return hash
        }
        return stateStores[dir]?.getBlockHash(atHeight: index)
    }

    public func getDeposit(demander: String, amountDemanded: UInt64, nonce: UInt128, directory: String) async throws -> UInt64? {
        guard let network = networks[directory] else { return nil }
        guard let chain = await chain(for: directory) else { return nil }
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
        // A receipt for a withdrawal on `directory` lives on `directory`'s
        // direct parent chain (that's what TransactionBody.withdrawalsAreValid
        // resolves via parentState.receiptState). For a grandchild, the parent
        // is not the nexus.
        let parentDir = parentDirectoryByChain[directory] ?? genesisConfig.spec.directory
        guard let network = networks[parentDir] else { return nil }
        guard let chain = await chain(for: parentDir) else { return nil }
        guard let snapshot = await chain.tipSnapshot else { return nil }
        let frontierHeader = LatticeStateHeader(rawCID: snapshot.frontierCID)
        let resolved = try await frontierHeader.resolve(fetcher: network.fetcher)
        guard let state = resolved.node else { return nil }
        let key = ReceiptKey(receiptAction: ReceiptAction(withdrawer: "", nonce: nonce, demander: demander, amountDemanded: amountDemanded, directory: directory)).description
        // Use .list to resolve the trie structure without resolving leaf values.
        // The receipt state stores withdrawer addresses as CID references in
        // HeaderImpl<PublicKey>; .targeted would try to fetch the CID as data.
        let receiptResolved = try await state.receiptState.resolve(paths: [[""]: .list], fetcher: network.fetcher)
        guard let receiptDict = receiptResolved.node else { return nil }
        guard let stored: HeaderImpl<PublicKey> = try? receiptDict.get(key: key) else { return nil }
        return stored.rawCID
    }

    public func listDeposits(directory: String, limit: Int = 100, after: String? = nil) async throws -> [(key: String, amountDeposited: UInt64)] {
        guard let network = networks[directory] else { return [] }
        guard let chain = await chain(for: directory) else { return [] }
        guard let snapshot = await chain.tipSnapshot else { return [] }
        let frontierHeader = LatticeStateHeader(rawCID: snapshot.frontierCID)
        let resolved = try await frontierHeader.resolve(fetcher: network.fetcher)
        guard let state = resolved.node else { return [] }
        let depositResolved = try await state.depositState.resolveRecursive(fetcher: network.fetcher)
        guard let depositDict = depositResolved.node else { return [] }
        let entries = try depositDict.sortedKeysAndValues(limit: limit, after: after)
        return entries.map { (key: $0.key, amountDeposited: $0.value) }
    }

    public func getBalanceProof(address: String, directory: String? = nil) async throws -> Data? {
        let dir = directory ?? genesisConfig.spec.directory
        guard let network = networks[dir] else { return nil }
        guard let chain = await chain(for: dir) else { return nil }
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
