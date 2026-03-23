import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import Acorn
import ArrayTrie

private actor E2EWorker: AcornCASWorker {
    var near: (any AcornCASWorker)?
    var far: (any AcornCASWorker)?
    var timeout: Duration? { nil }
    private var store: [ContentIdentifier: Data] = [:]
    func has(cid: ContentIdentifier) -> Bool { store[cid] != nil }
    func getLocal(cid: ContentIdentifier) async -> Data? { store[cid] }
    func storeLocal(cid: ContentIdentifier, data: Data) async { store[cid] = data }
}

private func fetcher() -> AcornFetcher { AcornFetcher(worker: E2EWorker()) }

private func testSpec(_ dir: String = "Nexus", premine: UInt64 = 0) -> ChainSpec {
    ChainSpec(directory: dir, maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: premine, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: 5)
}

private func sign(_ body: TransactionBody, _ kp: (privateKey: String, publicKey: String)) -> Transaction {
    let h = HeaderImpl<TransactionBody>(node: body)
    let sig = CryptoUtils.sign(message: h.rawCID, privateKeyHex: kp.privateKey)!
    return Transaction(signatures: [kp.publicKey: sig], body: h)
}

private func addr(_ pubKey: String) -> String {
    HeaderImpl<PublicKey>(node: PublicKey(key: pubKey)).rawCID
}

private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

// ============================================================================
// MARK: - Smoke Tests: Node boots, mines, persists
// ============================================================================

final class SmokeTests: XCTestCase {

    func testNexusGenesisBootAndChainState() async throws {
        let f = fetcher()
        let result = try await NexusGenesis.create(fetcher: f)
        XCTAssertFalse(result.blockHash.isEmpty)
        let height = await result.chainState.getHighestBlockIndex()
        XCTAssertEqual(height, 0)
        let tip = await result.chainState.getMainChainTip()
        XCTAssertEqual(tip, result.blockHash)
    }

    func testMineBlocksAndAdvanceChain() async throws {
        let f = fetcher()
        let t = now() - 50_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let chain = ChainState.fromGenesis(block: genesis)

        var prev = genesis
        for i in 1...10 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: f
            )
            let header = HeaderImpl<Block>(node: block)
            await f.store(rawCid: header.rawCID, data: block.toData()!)
            let result = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil, blockHeader: header, block: block
            )
            XCTAssertTrue(result.extendsMainChain, "Block \(i) should extend")
            prev = block
        }

        let height = await chain.getHighestBlockIndex()
        XCTAssertEqual(height, 10)
    }

    func testMinerProducesCoinbaseTransaction() async throws {
        let f = fetcher()
        let t = now() - 20_000
        let spec = testSpec()
        let kp = CryptoUtils.generateKeyPair()
        let identity = MinerIdentity(publicKeyHex: kp.publicKey, privateKeyHex: kp.privateKey)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let mempool = Mempool(maxSize: 100)

        await f.store(rawCid: HeaderImpl<Block>(node: genesis).rawCID, data: genesis.toData()!)

        let miner = MinerLoop(
            chainState: chain, mempool: mempool, fetcher: f,
            spec: spec, identity: identity
        )

        let before = await miner.isMining
        XCTAssertFalse(before)
        await miner.start()
        let during = await miner.isMining
        XCTAssertTrue(during)
        await miner.stop()
        let after = await miner.isMining
        XCTAssertFalse(after)
    }

    func testChainStatePersistAndRestore() async throws {
        let f = fetcher()
        let t = now() - 30_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let chain = ChainState.fromGenesis(block: genesis)

        var prev = genesis
        for i in 1...5 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: f
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: block), block: block
            )
            prev = block
        }

        let persisted = await chain.persist()
        let data = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(PersistedChainState.self, from: data)
        let restored = ChainState.restore(from: decoded)

        let origTip = await chain.getMainChainTip()
        let resTip = await restored.getMainChainTip()
        XCTAssertEqual(origTip, resTip)

        let block6 = try await BlockBuilder.buildBlock(
            previous: prev, timestamp: t + 6000,
            difficulty: UInt256(1000), nonce: 6, fetcher: f
        )
        let result = await restored.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: block6), block: block6
        )
        XCTAssertTrue(result.extendsMainChain)
        let rh = await restored.getHighestBlockIndex()
        XCTAssertEqual(rh, 6)
    }

    func testPersistToDiskAndReload() async throws {
        let f = fetcher()
        let t = now() - 20_000
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let persister = ChainStatePersister(storagePath: tmpDir, directory: "Nexus")
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let b1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: b1), block: b1
        )

        let persisted = await chain.persist()
        try await persister.save(persisted)

        let loaded = try await persister.load()
        XCTAssertNotNil(loaded)
        let restored = ChainState.restore(from: loaded!)
        let resTip = await restored.getMainChainTip()
        let origTip = await chain.getMainChainTip()
        XCTAssertEqual(resTip, origTip)
    }
}

// ============================================================================
// MARK: - Multi-Chain End-to-End: Nexus + Child chains
// ============================================================================

final class MultiChainEndToEndTests: XCTestCase {

    func testNexusWithChildChainHierarchy() async throws {
        let f = fetcher()
        let t = now() - 50_000
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Payments")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Payments": childLevel])

        let dirs = await nexusLevel.childDirectories()
        XCTAssertEqual(dirs, ["Payments"])

        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            childBlocks: ["Payments": childGenesis],
            timestamp: t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let result = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: nexusBlock1), block: nexusBlock1
        )
        XCTAssertTrue(result.extendsMainChain)
        let nh = await nexusChain.getHighestBlockIndex()
        XCTAssertEqual(nh, 1)
    }

    func testMergedMiningWithChildTransactions() async throws {
        let f = fetcher()
        let t = now() - 50_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Payments", premine: 1000)
        let childPremine = childSpec.premineAmount()

        let childPremineBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: 0, newBalance: childPremine)],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, transactions: [sign(childPremineBody, kp)],
            timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)

        await f.store(rawCid: HeaderImpl<Block>(node: childGenesis).rawCID, data: childGenesis.toData()!)

        let childMempool = Mempool(maxSize: 100)

        let receiver = CryptoUtils.generateKeyPair()
        let receiverAddr = addr(receiver.publicKey)
        let childReward = childSpec.rewardAtBlock(0)
        let transferBody = TransactionBody(
            accountActions: [
                AccountAction(owner: kpAddr, oldBalance: childPremine, newBalance: childPremine - 100),
                AccountAction(owner: receiverAddr, oldBalance: 0, newBalance: 100 + childReward)
            ],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: [kpAddr], fee: 0, nonce: 1
        )
        let childTx = sign(transferBody, kp)
        let added = await childMempool.add(transaction: childTx)
        XCTAssertTrue(added)

        let childCtx = ChildMiningContext(
            directory: "Payments", chainState: childChain,
            mempool: childMempool, fetcher: f, spec: childSpec
        )

        let nexusMempool = Mempool(maxSize: 100)
        let miner = MinerLoop(
            chainState: nexusChain, mempool: nexusMempool, fetcher: f,
            spec: nexusSpec, childContexts: [childCtx]
        )

        XCTAssertNotNil(miner)

        let childMempoolCount = await childMempool.count
        XCTAssertEqual(childMempoolCount, 1)
    }

    func testMultipleChildChainsInMiner() async throws {
        let f = fetcher()
        let t = now() - 50_000
        let nexusSpec = testSpec("Nexus")
        let childASpec = testSpec("Payments")
        let childBSpec = testSpec("Identity")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let childAGenesis = try await BlockBuilder.buildGenesis(
            spec: childASpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let childBGenesis = try await BlockBuilder.buildGenesis(
            spec: childBSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let chainA = ChainState.fromGenesis(block: childAGenesis)
        let chainB = ChainState.fromGenesis(block: childBGenesis)

        await f.store(rawCid: HeaderImpl<Block>(node: childAGenesis).rawCID, data: childAGenesis.toData()!)
        await f.store(rawCid: HeaderImpl<Block>(node: childBGenesis).rawCID, data: childBGenesis.toData()!)

        let mempoolA = Mempool(maxSize: 100)
        let mempoolB = Mempool(maxSize: 100)

        let ctxA = ChildMiningContext(directory: "Payments", chainState: chainA, mempool: mempoolA, fetcher: f, spec: childASpec)
        let ctxB = ChildMiningContext(directory: "Identity", chainState: chainB, mempool: mempoolB, fetcher: f, spec: childBSpec)

        let nexusMempool = Mempool(maxSize: 100)
        let miner = MinerLoop(
            chainState: nexusChain, mempool: nexusMempool, fetcher: f,
            spec: nexusSpec, childContexts: [ctxA, ctxB]
        )
        XCTAssertNotNil(miner)
    }
}

// ============================================================================
// MARK: - Chain Subscription Tests
// ============================================================================

final class SubscriptionTests: XCTestCase {

    func testArrayTrieSubscriptionPaths() {
        var subs = ArrayTrie<Bool>()
        subs.set(["Nexus"], value: true)
        subs.set(["Nexus", "Payments"], value: true)
        subs.set(["Nexus", "Payments", "US"], value: true)

        XCTAssertEqual(subs.get(["Nexus"]), true)
        XCTAssertEqual(subs.get(["Nexus", "Payments"]), true)
        XCTAssertEqual(subs.get(["Nexus", "Payments", "US"]), true)
        XCTAssertNil(subs.get(["Nexus", "Identity"]))
    }

    func testSubscribeAndUnsubscribe() {
        var subs = ArrayTrie<Bool>()
        subs.set(["Nexus"], value: true)
        subs.set(["Nexus", "Payments"], value: true)

        XCTAssertEqual(subs.get(["Nexus", "Payments"]), true)

        subs = subs.deleting(path: ["Nexus", "Payments"])
        XCTAssertNil(subs.get(["Nexus", "Payments"]))
        XCTAssertEqual(subs.get(["Nexus"]), true)
    }

    func testNexusAlwaysSubscribed() {
        var subs = ArrayTrie<Bool>()
        subs.set(["Nexus"], value: true)

        let config = LatticeNodeConfig(
            publicKey: "test", privateKey: "test",
            storagePath: URL(fileURLWithPath: "/tmp"),
            subscribedChains: subs
        )
        XCTAssertTrue(config.isSubscribed(chainPath: ["Nexus"]))
    }

    func testChildChainSubscriptionCheck() {
        var subs = ArrayTrie<Bool>()
        subs.set(["Nexus"], value: true)
        subs.set(["Nexus", "Payments"], value: true)

        let config = LatticeNodeConfig(
            publicKey: "test", privateKey: "test",
            storagePath: URL(fileURLWithPath: "/tmp"),
            subscribedChains: subs
        )
        XCTAssertTrue(config.isSubscribed(chainPath: ["Nexus", "Payments"]))
        XCTAssertFalse(config.isSubscribed(chainPath: ["Nexus", "Identity"]))
    }

    func testEmptySubscriptionsStillHasNexus() {
        let config = LatticeNodeConfig(
            publicKey: "test", privateKey: "test",
            storagePath: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertTrue(config.isSubscribed(chainPath: ["Nexus"]))
    }
}

// ============================================================================
// MARK: - Mempool End-to-End
// ============================================================================

final class MempoolEndToEndTests: XCTestCase {

    func testTransactionAddedAndSelected() async {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let mempool = Mempool(maxSize: 100)

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [],
            signers: [kpAddr], fee: 50, nonce: 0
        )
        let tx = sign(body, kp)
        let added = await mempool.add(transaction: tx)
        XCTAssertTrue(added)

        let count = await mempool.count
        XCTAssertEqual(count, 1)

        let selected = await mempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(selected.count, 1)
    }

    func testMempoolRejectsDuplicates() async {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let mempool = Mempool(maxSize: 100)

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [],
            signers: [kpAddr], fee: 10, nonce: 0
        )
        let tx = sign(body, kp)
        let first = await mempool.add(transaction: tx)
        let second = await mempool.add(transaction: tx)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testMempoolSelectsHighestFeeFirst() async {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let mempool = Mempool(maxSize: 100)

        for i: UInt64 in 0..<5 {
            let body = TransactionBody(
                accountActions: [], actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
                peerActions: [], settleActions: [],
                signers: [kpAddr], fee: i * 10, nonce: i
            )
            let _ = await mempool.add(transaction: sign(body, kp))
        }

        let selected = await mempool.selectTransactions(maxCount: 3)
        let fees = selected.compactMap { $0.body.node?.fee }
        XCTAssertEqual(fees, fees.sorted(by: >))
    }

    func testMempoolPrunesConfirmedTransactions() async {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let mempool = Mempool(maxSize: 100)

        var cids: [String] = []
        for i: UInt64 in 0..<3 {
            let body = TransactionBody(
                accountActions: [], actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
                peerActions: [], settleActions: [],
                signers: [kpAddr], fee: 10, nonce: i
            )
            let tx = sign(body, kp)
            let _ = await mempool.add(transaction: tx)
            cids.append(tx.body.rawCID)
        }

        let mc3 = await mempool.count
        XCTAssertEqual(mc3, 3)

        await mempool.removeAll(txCIDs: Set([cids[0], cids[1]]))
        let mc1 = await mempool.count
        XCTAssertEqual(mc1, 1)
    }

    func testMempoolRejectsInvalidSignature() async {
        let kp = CryptoUtils.generateKeyPair()
        let mempool = Mempool(maxSize: 100)

        let body = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [],
            signers: ["fake"], fee: 10, nonce: 0
        )
        let tx = Transaction(signatures: [kp.publicKey: "deadbeef"], body: HeaderImpl<TransactionBody>(node: body))

        let added = await mempool.add(transaction: tx)
        XCTAssertFalse(added)
    }

    func testMempoolPerChainIsolation() async {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let nexusMempool = Mempool(maxSize: 100)
        let childMempool = Mempool(maxSize: 100)

        let nexusBody = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [],
            signers: [kpAddr], fee: 10, nonce: 0
        )
        let childBody = TransactionBody(
            accountActions: [], actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [],
            signers: [kpAddr], fee: 20, nonce: 1
        )

        let _ = await nexusMempool.add(transaction: sign(nexusBody, kp))
        let _ = await childMempool.add(transaction: sign(childBody, kp))

        let nmc = await nexusMempool.count
        XCTAssertEqual(nmc, 1)
        let cmc = await childMempool.count
        XCTAssertEqual(cmc, 1)

        let nexusTxs = await nexusMempool.selectTransactions(maxCount: 10)
        let childTxs = await childMempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(nexusTxs.first?.body.node?.fee, 10)
        XCTAssertEqual(childTxs.first?.body.node?.fee, 20)
    }
}

// ============================================================================
// MARK: - Two-Node Convergence
// ============================================================================

final class TwoNodeEndToEndTests: XCTestCase {

    func testTwoNodesConvergeFromSameGenesis() async throws {
        let f = fetcher()
        let t = now() - 50_000
        let spec = testSpec()
        let config = GenesisConfig.standard(spec: spec)

        let genesisA = try await GenesisCeremony.create(config: config, fetcher: f)
        let genesisB = try await GenesisCeremony.create(config: config, fetcher: f)
        XCTAssertEqual(genesisA.blockHash, genesisB.blockHash)

        let fA = fetcher()
        let fB = fetcher()
        await fA.store(rawCid: genesisA.blockHash, data: genesisA.block.toData()!)
        await fB.store(rawCid: genesisB.blockHash, data: genesisB.block.toData()!)

        var prev = genesisA.block
        var blocks: [Block] = []
        for i in 1...5 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: fA
            )
            await fA.store(rawCid: HeaderImpl<Block>(node: block).rawCID, data: block.toData()!)
            let _ = await genesisA.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: block), block: block
            )
            blocks.append(block)
            prev = block
        }

        for block in blocks {
            let header = HeaderImpl<Block>(node: block)
            await fB.store(rawCid: header.rawCID, data: block.toData()!)
            let _ = await genesisB.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil, blockHeader: header, block: block
            )
        }

        let tipA = await genesisA.chainState.getMainChainTip()
        let tipB = await genesisB.chainState.getMainChainTip()
        XCTAssertEqual(tipA, tipB)
        let ah5 = await genesisA.chainState.getHighestBlockIndex()
        XCTAssertEqual(ah5, 5)
        let bh5 = await genesisB.chainState.getHighestBlockIndex()
        XCTAssertEqual(bh5, 5)
    }

    func testNodeConvergesAfterReceivingLongerFork() async throws {
        let f = fetcher()
        let t = now() - 100_000
        let spec = testSpec()
        let config = GenesisConfig.standard(spec: spec)

        let genesisA = try await GenesisCeremony.create(config: config, fetcher: f)
        let genesisB = try await GenesisCeremony.create(config: config, fetcher: f)

        var shortPrev = genesisB.block
        for i in 1...3 {
            let b = try await BlockBuilder.buildBlock(
                previous: shortPrev, timestamp: t + Int64(i) * 500,
                difficulty: UInt256(1000), nonce: UInt64(i + 100), fetcher: f
            )
            let _ = await genesisB.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: b), block: b
            )
            shortPrev = b
        }
        let bh3 = await genesisB.chainState.getHighestBlockIndex()
        XCTAssertEqual(bh3, 3)

        var longPrev = genesisA.block
        var longBlocks: [Block] = []
        for i in 1...5 {
            let b = try await BlockBuilder.buildBlock(
                previous: longPrev, timestamp: t + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: f
            )
            let _ = await genesisA.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: b), block: b
            )
            longBlocks.append(b)
            longPrev = b
        }

        for block in longBlocks {
            let _ = await genesisB.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: HeaderImpl<Block>(node: block), block: block
            )
        }

        let tipA = await genesisA.chainState.getMainChainTip()
        let tipB = await genesisB.chainState.getMainChainTip()
        XCTAssertEqual(tipA, tipB, "Node B should reorg to longer chain")
        let bh5 = await genesisB.chainState.getHighestBlockIndex()
        XCTAssertEqual(bh5, 5)
    }
}

// ============================================================================
// MARK: - Multi-Chain Block Reception & Propagation
// ============================================================================

final class MultiChainReceptionTests: XCTestCase {

    func testReceivedNexusBlockWithChildBlockExtractsChildChain() async throws {
        let f = fetcher()
        let t = now() - 5_000
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Payments")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let nexusLevel = ChainLevel(chain: nexusChain, children: [:])

        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            childBlocks: ["Payments": childGenesis],
            timestamp: t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let header1 = HeaderImpl<Block>(node: nexusBlock1)

        let result = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header1, block: nexusBlock1
        )
        XCTAssertTrue(result.extendsMainChain)

        let nexusHeight = await nexusChain.getHighestBlockIndex()
        XCTAssertEqual(nexusHeight, 1)

        let _ = await nexusLevel.extractAndProcessChildBlocks(
            parentBlock: nexusBlock1, parentBlockHeader: header1, fetcher: f
        )
        let childDirs = await nexusLevel.childDirectories()
        XCTAssertTrue(childDirs.contains("Payments"))
    }

    func testTwoNodesConvergeOnMultiChainWithChildExtraction() async throws {
        let f = fetcher()
        let t = now() - 5_000
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Payments")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let chainA = ChainState.fromGenesis(block: nexusGenesis)
        let chainB = ChainState.fromGenesis(block: nexusGenesis)
        let levelA = ChainLevel(chain: chainA, children: [:])
        let levelB = ChainLevel(chain: chainB, children: [:])

        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            childBlocks: ["Payments": childGenesis],
            timestamp: t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let header1 = HeaderImpl<Block>(node: nexusBlock1)

        let resultA = await chainA.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header1, block: nexusBlock1
        )
        XCTAssertTrue(resultA.extendsMainChain)

        let resultB = await chainB.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header1, block: nexusBlock1
        )
        XCTAssertTrue(resultB.extendsMainChain)

        let tipA = await chainA.getMainChainTip()
        let tipB = await chainB.getMainChainTip()
        XCTAssertEqual(tipA, tipB)

        let _ = await levelA.extractAndProcessChildBlocks(
            parentBlock: nexusBlock1, parentBlockHeader: header1, fetcher: f
        )
        let _ = await levelB.extractAndProcessChildBlocks(
            parentBlock: nexusBlock1, parentBlockHeader: header1, fetcher: f
        )
        let childDirsA = await levelA.childDirectories()
        let childDirsB = await levelB.childDirectories()
        XCTAssertEqual(childDirsA, childDirsB)
        XCTAssertTrue(childDirsA.contains("Payments"))
    }

    func testChildChainBlocksPropagateViaNexusBlocks() async throws {
        let f = fetcher()
        let t = now() - 5_000
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Payments")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Payments": childLevel])

        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, timestamp: t + 1000,
            difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            childBlocks: ["Payments": childBlock1],
            timestamp: t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let header1 = HeaderImpl<Block>(node: nexusBlock1)

        let result = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header1, block: nexusBlock1
        )
        XCTAssertTrue(result.extendsMainChain)

        let _ = await nexusLevel.extractAndProcessChildBlocks(
            parentBlock: nexusBlock1, parentBlockHeader: header1, fetcher: f
        )

        let nexusHeight = await nexusChain.getHighestBlockIndex()
        XCTAssertEqual(nexusHeight, 1)

        let childHeight = await childChain.getHighestBlockIndex()
        XCTAssertEqual(childHeight, 1)
    }

    func testBufferedStorerFlushesAllData() async throws {
        let f = fetcher()
        let t = now() - 10_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let header = HeaderImpl<Block>(node: genesis)
        let storer = BufferedStorer()
        try header.storeRecursively(storer: storer)
        XCTAssertGreaterThan(storer.entries.count, 1)

        let freshFetcher = fetcher()
        await storer.flush(to: freshFetcher)

        let fetched = try await freshFetcher.fetch(rawCid: header.rawCID)
        XCTAssertEqual(fetched, genesis.toData()!)

        let specData = try await freshFetcher.fetch(rawCid: genesis.spec.rawCID)
        XCTAssertNotNil(ChainSpec(data: specData))
    }
}

// ============================================================================
// MARK: - Block Storage via Acorn CAS
// ============================================================================

final class AcornStorageTests: XCTestCase {

    func testBlockStoreAndRetrieve() async throws {
        let f = fetcher()
        let t = now() - 10_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let header = HeaderImpl<Block>(node: genesis)
        let blockData = genesis.toData()!

        await f.store(rawCid: header.rawCID, data: blockData)

        let fetched = try await f.fetch(rawCid: header.rawCID)
        XCTAssertEqual(fetched, blockData)
    }

    func testBlockSerializeDeserializeRoundtrip() async throws {
        let f = fetcher()
        let t = now() - 10_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let data = genesis.toData()!
        let restored = Block(data: data)
        XCTAssertNotNil(restored)

        let originalCID = HeaderImpl<Block>(node: genesis).rawCID
        let restoredCID = HeaderImpl<Block>(node: restored!).rawCID
        XCTAssertEqual(originalCID, restoredCID)
    }

    func testFetchMissingBlockThrows() async {
        let f = fetcher()
        do {
            let _ = try await f.fetch(rawCid: "nonexistent-cid")
            XCTFail("Should throw for missing CID")
        } catch {
            // expected
        }
    }

    func testMultiBlockStoreAndRetrieve() async throws {
        let f = fetcher()
        let t = now() - 30_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        var prev = genesis
        var cids: [String] = []
        for i in 0...5 {
            let block = i == 0 ? genesis : try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: f
            )
            let header = HeaderImpl<Block>(node: block)
            await f.store(rawCid: header.rawCID, data: block.toData()!)
            cids.append(header.rawCID)
            prev = block
        }

        for cid in cids {
            let data = try await f.fetch(rawCid: cid)
            let block = Block(data: data)
            XCTAssertNotNil(block)
        }
    }
}

// ============================================================================
// MARK: - Multi-Chain Deep Integration Tests
// ============================================================================

private struct MultiChainEnv {
    let f: AcornFetcher
    let t: Int64
    let nexusSpec: ChainSpec
    let childSpec: ChainSpec
    let nexusGenesis: Block
    let childGenesis: Block
    let nexusChain: ChainState
    let childChain: ChainState
    let nexusLevel: ChainLevel
    let kp: (privateKey: String, publicKey: String)
    let kpAddr: String

    static func create(childDir: String = "Payments", premine: UInt64 = 1000) async throws -> MultiChainEnv {
        let f = fetcher()
        let t = now() - 10_000
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec(childDir, premine: premine)
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, oldBalance: 0, newBalance: childSpec.premineAmount())],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, transactions: [sign(premineBody, kp)],
            timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let nexusStorer = BufferedStorer()
        try HeaderImpl<Block>(node: nexusGenesis).storeRecursively(storer: nexusStorer)
        await nexusStorer.flush(to: f)
        let childStorer = BufferedStorer()
        try HeaderImpl<Block>(node: childGenesis).storeRecursively(storer: childStorer)
        await childStorer.flush(to: f)

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: [childDir: childLevel])

        return MultiChainEnv(
            f: f, t: t, nexusSpec: nexusSpec, childSpec: childSpec,
            nexusGenesis: nexusGenesis, childGenesis: childGenesis,
            nexusChain: nexusChain, childChain: childChain, nexusLevel: nexusLevel,
            kp: kp, kpAddr: kpAddr
        )
    }

    func buildNexusBlock(
        previous: Block, childBlocks: [String: Block] = [:],
        offset: Int64 = 1000, nonce: UInt64 = 1
    ) async throws -> Block {
        try await BlockBuilder.buildBlock(
            previous: previous, childBlocks: childBlocks,
            timestamp: previous.timestamp + offset,
            difficulty: UInt256(1000), nonce: nonce, fetcher: f
        )
    }

    func submitNexus(_ block: Block) async -> SubmissionResult {
        await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: block), block: block
        )
    }

    func extractChildren(from block: Block) async -> [String] {
        await nexusLevel.extractAndProcessChildBlocks(
            parentBlock: block,
            parentBlockHeader: HeaderImpl<Block>(node: block),
            fetcher: f
        )
    }
}

final class MultiChainReorgTests: XCTestCase {

    func testChildChainAdvancesWithParentBlocks() async throws {
        let env = try await MultiChainEnv.create()

        let nexusBlock1 = try await env.buildNexusBlock(
            previous: env.nexusGenesis,
            childBlocks: ["Payments": env.childGenesis]
        )
        let r1 = await env.submitNexus(nexusBlock1)
        XCTAssertTrue(r1.extendsMainChain)
        let _ = await env.extractChildren(from: nexusBlock1)

        let childDirs = await env.nexusLevel.childDirectories()
        XCTAssertTrue(childDirs.contains("Payments"))

        let nexusHeight = await env.nexusChain.getHighestBlockIndex()
        XCTAssertEqual(nexusHeight, 1)
    }

    func testMultipleNexusBlocksWithChildGenesis() async throws {
        let env = try await MultiChainEnv.create()

        let nexusBlock1 = try await env.buildNexusBlock(
            previous: env.nexusGenesis,
            childBlocks: ["Payments": env.childGenesis]
        )
        let r1 = await env.submitNexus(nexusBlock1)
        XCTAssertTrue(r1.extendsMainChain)
        let _ = await env.extractChildren(from: nexusBlock1)

        let nexusBlock2 = try await env.buildNexusBlock(
            previous: nexusBlock1, offset: 2000, nonce: 2
        )
        let r2 = await env.submitNexus(nexusBlock2)
        XCTAssertTrue(r2.extendsMainChain)

        let nexusBlock3 = try await env.buildNexusBlock(
            previous: nexusBlock2, offset: 3000, nonce: 3
        )
        let r3 = await env.submitNexus(nexusBlock3)
        XCTAssertTrue(r3.extendsMainChain)

        let nexusHeight = await env.nexusChain.getHighestBlockIndex()
        XCTAssertEqual(nexusHeight, 3)

        let childDirs = await env.nexusLevel.childDirectories()
        XCTAssertTrue(childDirs.contains("Payments"))
    }

    func testNexusBlockWithoutChildBlockDoesNotAdvanceChild() async throws {
        let env = try await MultiChainEnv.create()

        let nexusBlock1 = try await env.buildNexusBlock(previous: env.nexusGenesis)
        let r1 = await env.submitNexus(nexusBlock1)
        XCTAssertTrue(r1.extendsMainChain)
        let _ = await env.extractChildren(from: nexusBlock1)

        let nexusHeight = await env.nexusChain.getHighestBlockIndex()
        XCTAssertEqual(nexusHeight, 1)
        let childHeight = await env.childChain.getHighestBlockIndex()
        XCTAssertEqual(childHeight, 0)
    }
}

final class MultiChainPersistenceTests: XCTestCase {

    func testChildChainPersistsAndRestores() async throws {
        let env = try await MultiChainEnv.create()

        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: env.childGenesis, timestamp: env.t + 1000,
            difficulty: UInt256(1000), nonce: 1, fetcher: env.f
        )
        let nexusBlock1 = try await env.buildNexusBlock(
            previous: env.nexusGenesis,
            childBlocks: ["Payments": childBlock1]
        )
        let _ = await env.submitNexus(nexusBlock1)
        let _ = await env.extractChildren(from: nexusBlock1)

        let childPersisted = await env.childChain.persist()
        let data = try JSONEncoder().encode(childPersisted)
        let decoded = try JSONDecoder().decode(PersistedChainState.self, from: data)
        let restored = ChainState.restore(from: decoded)

        let origTip = await env.childChain.getMainChainTip()
        let resTip = await restored.getMainChainTip()
        XCTAssertEqual(origTip, resTip)

        let resHeight = await restored.getHighestBlockIndex()
        XCTAssertEqual(resHeight, 1)
    }

    func testMultipleChildChainsPersistIndependently() async throws {
        let f = fetcher()
        let t = now() - 10_000
        let nexusSpec = testSpec("Nexus")
        let childASpec = testSpec("Payments")
        let childBSpec = testSpec("Identity")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let childAGenesis = try await BlockBuilder.buildGenesis(
            spec: childASpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let childBGenesis = try await BlockBuilder.buildGenesis(
            spec: childBSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let chainA = ChainState.fromGenesis(block: childAGenesis)
        let chainB = ChainState.fromGenesis(block: childBGenesis)

        let persistedA = await chainA.persist()
        let persistedB = await chainB.persist()

        let restoredA = ChainState.restore(from: persistedA)
        let restoredB = ChainState.restore(from: persistedB)

        let tipA = await restoredA.getMainChainTip()
        let tipB = await restoredB.getMainChainTip()
        XCTAssertNotEqual(tipA, tipB)

        let nexusTip = await nexusChain.getMainChainTip()
        XCTAssertNotEqual(nexusTip, tipA)
        XCTAssertNotEqual(nexusTip, tipB)
    }
}

final class MultiChainBalanceAndStateTests: XCTestCase {

    func testChildChainHasValidTipSnapshot() async throws {
        let env = try await MultiChainEnv.create()
        let snapshot = await env.childChain.tipSnapshot
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.index, 0)
        XCTAssertFalse(snapshot!.frontierCID.isEmpty)
        XCTAssertFalse(snapshot!.specCID.isEmpty)
    }

    func testChainStatusReportsMultipleChains() async throws {
        let env = try await MultiChainEnv.create()

        let nexusBlock1 = try await env.buildNexusBlock(
            previous: env.nexusGenesis,
            childBlocks: ["Payments": env.childGenesis]
        )
        let _ = await env.submitNexus(nexusBlock1)
        let _ = await env.extractChildren(from: nexusBlock1)

        let nexusHeight = await env.nexusChain.getHighestBlockIndex()
        XCTAssertEqual(nexusHeight, 1)

        let childDirs = await env.nexusLevel.childDirectories()
        XCTAssertEqual(childDirs, ["Payments"])

        let childHeight = await env.childChain.getHighestBlockIndex()
        XCTAssertEqual(childHeight, 0)
    }

    func testChildChainTransactionAdvancesChain() async throws {
        let env = try await MultiChainEnv.create()
        let receiver = CryptoUtils.generateKeyPair()
        let receiverAddr = addr(receiver.publicKey)
        let premineAmount = env.childSpec.premineAmount()

        let transferBody = TransactionBody(
            accountActions: [
                AccountAction(owner: env.kpAddr, oldBalance: premineAmount, newBalance: premineAmount - 500),
                AccountAction(owner: receiverAddr, oldBalance: 0, newBalance: 500)
            ],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [],
            peerActions: [], settleActions: [], signers: [env.kpAddr], fee: 0, nonce: 1
        )
        let tx = sign(transferBody, env.kp)

        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: env.childGenesis, transactions: [tx],
            timestamp: env.t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: env.f
        )
        let childResult = await env.childChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: childBlock1), block: childBlock1
        )
        XCTAssertTrue(childResult.extendsMainChain)

        let childHeight = await env.childChain.getHighestBlockIndex()
        XCTAssertEqual(childHeight, 1)

        let snapshot = await env.childChain.tipSnapshot
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.index, 1)
    }
}

final class MultiChainMiningContextTests: XCTestCase {

    func testChildMiningContextUsesCorrectSpec() async throws {
        let f = fetcher()
        let t = now() - 10_000
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Payments")

        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let childMempool = Mempool(maxSize: 100)

        let ctx = ChildMiningContext(
            directory: "Payments", chainState: childChain,
            mempool: childMempool, fetcher: f, spec: childSpec
        )
        XCTAssertEqual(ctx.directory, "Payments")
        XCTAssertEqual(ctx.spec.directory, "Payments")
        XCTAssertNotEqual(ctx.spec.directory, nexusSpec.directory)
    }

    func testMinerWithMultipleChildContexts() async throws {
        let f = fetcher()
        let t = now() - 10_000
        let nexusSpec = testSpec("Nexus")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        await f.store(rawCid: HeaderImpl<Block>(node: nexusGenesis).rawCID, data: nexusGenesis.toData()!)

        var contexts: [ChildMiningContext] = []
        for dir in ["Payments", "Identity", "Data"] {
            let spec = testSpec(dir)
            let genesis = try await BlockBuilder.buildGenesis(
                spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
            )
            let chain = ChainState.fromGenesis(block: genesis)
            await f.store(rawCid: HeaderImpl<Block>(node: genesis).rawCID, data: genesis.toData()!)
            contexts.append(ChildMiningContext(
                directory: dir, chainState: chain,
                mempool: Mempool(maxSize: 100), fetcher: f, spec: spec
            ))
        }

        let miner = MinerLoop(
            chainState: nexusChain, mempool: Mempool(maxSize: 100),
            fetcher: f, spec: nexusSpec, childContexts: contexts
        )
        XCTAssertNotNil(miner)
        let mining = await miner.isMining
        XCTAssertFalse(mining)
    }

    func testChildMempoolIsolation() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let nexusMempool = Mempool(maxSize: 100)
        let childAMempool = Mempool(maxSize: 100)
        let childBMempool = Mempool(maxSize: 100)

        for (mempool, fee) in [(nexusMempool, 10 as UInt64), (childAMempool, 20), (childBMempool, 30)] {
            let body = TransactionBody(
                accountActions: [], actions: [], swapActions: [], swapClaimActions: [],
                genesisActions: [], peerActions: [], settleActions: [],
                signers: [kpAddr], fee: fee, nonce: fee
            )
            let _ = await mempool.add(transaction: sign(body, kp))
        }

        let nc = await nexusMempool.count
        let ac = await childAMempool.count
        let bc = await childBMempool.count
        XCTAssertEqual(nc, 1)
        XCTAssertEqual(ac, 1)
        XCTAssertEqual(bc, 1)

        let nexusTxs = await nexusMempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(nexusTxs.first?.body.node?.fee, 10)
        let aTxs = await childAMempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(aTxs.first?.body.node?.fee, 20)
        let bTxs = await childBMempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(bTxs.first?.body.node?.fee, 30)
    }
}

final class MultiChainDiscoveryTests: XCTestCase {

    func testNewChildChainDiscoveredFromNexusBlock() async throws {
        let f = fetcher()
        let t = now() - 10_000
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("NewChain")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let nexusLevel = ChainLevel(chain: nexusChain, children: [:])

        let dirsBefore = await nexusLevel.childDirectories()
        XCTAssertTrue(dirsBefore.isEmpty)

        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            childBlocks: ["NewChain": childGenesis],
            timestamp: t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let _ = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: nexusBlock1), block: nexusBlock1
        )
        let _ = await nexusLevel.extractAndProcessChildBlocks(
            parentBlock: nexusBlock1,
            parentBlockHeader: HeaderImpl<Block>(node: nexusBlock1),
            fetcher: f
        )

        let dirsAfter = await nexusLevel.childDirectories()
        XCTAssertEqual(dirsAfter, ["NewChain"])
    }

    func testMultipleChildChainsDiscoveredSimultaneously() async throws {
        let f = fetcher()
        let t = now() - 10_000
        let nexusSpec = testSpec("Nexus")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let nexusLevel = ChainLevel(chain: nexusChain, children: [:])

        var childBlocks: [String: Block] = [:]
        for dir in ["Alpha", "Beta", "Gamma"] {
            let spec = testSpec(dir)
            let genesis = try await BlockBuilder.buildGenesis(
                spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
            )
            childBlocks[dir] = genesis
        }

        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, childBlocks: childBlocks,
            timestamp: t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let _ = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: nexusBlock1), block: nexusBlock1
        )
        let _ = await nexusLevel.extractAndProcessChildBlocks(
            parentBlock: nexusBlock1,
            parentBlockHeader: HeaderImpl<Block>(node: nexusBlock1),
            fetcher: f
        )

        let dirs = await nexusLevel.childDirectories().sorted()
        XCTAssertEqual(dirs, ["Alpha", "Beta", "Gamma"])
    }

    func testFullChildValidationPipeline() async throws {
        let f = fetcher()
        let t = now() - 5_000
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Payments")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let nexusLevel = ChainLevel(chain: nexusChain, children: [:])

        let genesisStorer = BufferedStorer()
        try HeaderImpl<Block>(node: nexusGenesis).storeRecursively(storer: genesisStorer)
        await genesisStorer.flush(to: f)
        let childGenesisStorer = BufferedStorer()
        try HeaderImpl<Block>(node: childGenesis).storeRecursively(storer: childGenesisStorer)
        await childGenesisStorer.flush(to: f)

        // Block 1: introduce child chain genesis
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            childBlocks: ["Payments": childGenesis],
            timestamp: t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let header1 = HeaderImpl<Block>(node: nexusBlock1)
        let storer1 = BufferedStorer()
        try header1.storeRecursively(storer: storer1)
        await storer1.flush(to: f)

        let _ = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header1, block: nexusBlock1
        )
        let newDirs = await nexusLevel.extractAndProcessChildBlocks(
            parentBlock: nexusBlock1, parentBlockHeader: header1, fetcher: f
        )
        XCTAssertEqual(newDirs, ["Payments"])

        // Block 2: child chain block 1 with shared timestamp
        let sharedTimestamp = t + 2000
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, parentChainBlock: nexusBlock1,
            timestamp: sharedTimestamp, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let nexusBlock2 = try await BlockBuilder.buildBlock(
            previous: nexusBlock1,
            childBlocks: ["Payments": childBlock1],
            timestamp: sharedTimestamp, difficulty: UInt256(1000), nonce: 2, fetcher: f
        )
        let header2 = HeaderImpl<Block>(node: nexusBlock2)
        let storer2 = BufferedStorer()
        try header2.storeRecursively(storer: storer2)
        await storer2.flush(to: f)

        let _ = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header2, block: nexusBlock2
        )
        let _ = await nexusLevel.extractAndProcessChildBlocks(
            parentBlock: nexusBlock2, parentBlockHeader: header2, fetcher: f
        )

        // Verify both chains advanced
        let nexusHeight = await nexusChain.getHighestBlockIndex()
        XCTAssertEqual(nexusHeight, 2)

        let childLevel = await nexusLevel.children["Payments"]
        XCTAssertNotNil(childLevel)
        let childHeight = await childLevel!.chain.getHighestBlockIndex()
        XCTAssertEqual(childHeight, 1, "Child chain should advance to height 1 after validated child block")
    }

    func testChildBlockWithMismatchedTimestampRejected() async throws {
        let f = fetcher()
        let t = now() - 5_000
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Payments")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Payments": childLevel])

        let genesisStorer = BufferedStorer()
        try HeaderImpl<Block>(node: nexusGenesis).storeRecursively(storer: genesisStorer)
        await genesisStorer.flush(to: f)
        let childGenesisStorer = BufferedStorer()
        try HeaderImpl<Block>(node: childGenesis).storeRecursively(storer: childGenesisStorer)
        await childGenesisStorer.flush(to: f)

        // Build child block with DIFFERENT timestamp than nexus block
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, parentChainBlock: nexusGenesis,
            timestamp: t + 999, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            childBlocks: ["Payments": childBlock1],
            timestamp: t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let header1 = HeaderImpl<Block>(node: nexusBlock1)
        let storer1 = BufferedStorer()
        try header1.storeRecursively(storer: storer1)
        await storer1.flush(to: f)

        let _ = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header1, block: nexusBlock1
        )
        let _ = await nexusLevel.extractAndProcessChildBlocks(
            parentBlock: nexusBlock1, parentBlockHeader: header1, fetcher: f
        )

        // Child block should NOT advance due to timestamp mismatch
        let childHeight = await childChain.getHighestBlockIndex()
        XCTAssertEqual(childHeight, 0, "Child block with mismatched timestamp should be rejected")
    }

    func testChildBlockWithCorrectTimestampAccepted() async throws {
        let f = fetcher()
        let t = now() - 5_000
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Payments")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Payments": childLevel])

        let genesisStorer = BufferedStorer()
        try HeaderImpl<Block>(node: nexusGenesis).storeRecursively(storer: genesisStorer)
        await genesisStorer.flush(to: f)
        let childGenesisStorer = BufferedStorer()
        try HeaderImpl<Block>(node: childGenesis).storeRecursively(storer: childGenesisStorer)
        await childGenesisStorer.flush(to: f)

        // Build child block with SAME timestamp as nexus block
        let sharedTimestamp = t + 1000
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, parentChainBlock: nexusGenesis,
            timestamp: sharedTimestamp, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            childBlocks: ["Payments": childBlock1],
            timestamp: sharedTimestamp, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let header1 = HeaderImpl<Block>(node: nexusBlock1)
        let storer1 = BufferedStorer()
        try header1.storeRecursively(storer: storer1)
        await storer1.flush(to: f)

        let _ = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header1, block: nexusBlock1
        )
        let _ = await nexusLevel.extractAndProcessChildBlocks(
            parentBlock: nexusBlock1, parentBlockHeader: header1, fetcher: f
        )

        // Child block SHOULD advance
        let childHeight = await childChain.getHighestBlockIndex()
        XCTAssertEqual(childHeight, 1, "Child block with matching timestamp should be accepted")
    }

    func testMultiBlockChildChainProgression() async throws {
        let f = fetcher()
        let t = now() - 5_000
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Payments")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Payments": childLevel])

        for storer in [BufferedStorer(), BufferedStorer()] {
            // Slightly wasteful but ensures both are stored
        }
        let gs1 = BufferedStorer()
        try HeaderImpl<Block>(node: nexusGenesis).storeRecursively(storer: gs1)
        await gs1.flush(to: f)
        let gs2 = BufferedStorer()
        try HeaderImpl<Block>(node: childGenesis).storeRecursively(storer: gs2)
        await gs2.flush(to: f)

        var prevNexus = nexusGenesis
        var prevChild = childGenesis
        for i in 1...5 {
            let ts = t + Int64(i) * 1000
            let childBlock = try await BlockBuilder.buildBlock(
                previous: prevChild, parentChainBlock: prevNexus,
                timestamp: ts, difficulty: UInt256(1000), nonce: UInt64(i), fetcher: f
            )
            let nexusBlock = try await BlockBuilder.buildBlock(
                previous: prevNexus,
                childBlocks: ["Payments": childBlock],
                timestamp: ts, difficulty: UInt256(1000), nonce: UInt64(i), fetcher: f
            )
            let header = HeaderImpl<Block>(node: nexusBlock)
            let storer = BufferedStorer()
            try header.storeRecursively(storer: storer)
            await storer.flush(to: f)

            let _ = await nexusChain.submitBlock(
                parentBlockHeaderAndIndex: nil, blockHeader: header, block: nexusBlock
            )
            let _ = await nexusLevel.extractAndProcessChildBlocks(
                parentBlock: nexusBlock, parentBlockHeader: header, fetcher: f
            )
            prevNexus = nexusBlock
            prevChild = childBlock
        }

        let nexusHeight = await nexusChain.getHighestBlockIndex()
        XCTAssertEqual(nexusHeight, 5)
        let childHeight = await childChain.getHighestBlockIndex()
        XCTAssertEqual(childHeight, 5, "Child chain should advance in lockstep with nexus")
    }

}

// ============================================================================
// MARK: - Full Integration: MinerLoop → Lattice → Child Chain Validation
// ============================================================================

private actor BlockCollector: MinerDelegate {
    var blocks: [(Block, String)] = []

    func minerDidProduceBlock(_ block: Block, hash: String) async {
        blocks.append((block, hash))
    }
}

final class FullMiningIntegrationTests: XCTestCase {

    func testMinerProducesBlockAndChainAdvances() async throws {
        let f = fetcher()
        let t = now() - 5_000
        let spec = testSpec("Nexus")
        let kp = CryptoUtils.generateKeyPair()
        let identity = MinerIdentity(publicKeyHex: kp.publicKey, privateKeyHex: kp.privateKey)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256.max, fetcher: f
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let nexusLevel = ChainLevel(chain: chain, children: [:])
        let lattice = Lattice(nexus: nexusLevel)
        let mempool = Mempool(maxSize: 100)

        let genesisStorer = BufferedStorer()
        try HeaderImpl<Block>(node: genesis).storeRecursively(storer: genesisStorer)
        await genesisStorer.flush(to: f)

        let miner = MinerLoop(
            chainState: chain, mempool: mempool, fetcher: f,
            spec: spec, identity: identity, batchSize: 10_000
        )

        let collector = BlockCollector()
        await miner.setDelegate(collector)
        await miner.start()

        try await Task.sleep(for: .seconds(3))
        await miner.stop()

        let minedBlocks = await collector.blocks
        XCTAssertGreaterThan(minedBlocks.count, 0, "Miner should produce at least one block")

        for (block, _) in minedBlocks {
            let header = HeaderImpl<Block>(node: block)
            let storer = BufferedStorer()
            try header.storeRecursively(storer: storer)
            await storer.flush(to: f)

            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil, blockHeader: header, block: block
            )
        }

        let height = await chain.getHighestBlockIndex()
        XCTAssertGreaterThan(height, 0, "Chain should advance after submitting mined blocks")
    }

    func testMergedMiningProducesChildBlocks() async throws {
        let f = fetcher()
        let t = now() - 5_000
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Payments")
        let kp = CryptoUtils.generateKeyPair()
        let identity = MinerIdentity(publicKeyHex: kp.publicKey, privateKeyHex: kp.privateKey)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256.max, fetcher: f
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256.max, fetcher: f
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Payments": childLevel])

        let gs1 = BufferedStorer()
        try HeaderImpl<Block>(node: nexusGenesis).storeRecursively(storer: gs1)
        await gs1.flush(to: f)
        let gs2 = BufferedStorer()
        try HeaderImpl<Block>(node: childGenesis).storeRecursively(storer: gs2)
        await gs2.flush(to: f)

        let childMempool = Mempool(maxSize: 100)
        let childCtx = ChildMiningContext(
            directory: "Payments", chainState: childChain,
            mempool: childMempool, fetcher: f, spec: childSpec
        )

        let nexusMempool = Mempool(maxSize: 100)
        let miner = MinerLoop(
            chainState: nexusChain, mempool: nexusMempool, fetcher: f,
            spec: nexusSpec, identity: identity, childContexts: [childCtx],
            batchSize: 10_000
        )

        let collector = BlockCollector()
        await miner.setDelegate(collector)
        await miner.start()

        try await Task.sleep(for: .seconds(3))
        await miner.stop()

        let minedBlocks = await collector.blocks
        XCTAssertGreaterThan(minedBlocks.count, 0, "Miner should produce blocks")

        let firstBlock = minedBlocks[0].0
        let childBlocksDict = try? await firstBlock.childBlocks.resolve(fetcher: f).node
        let childKeys = try? childBlocksDict?.allKeys()
        XCTAssertNotNil(childKeys, "Mined block should contain child blocks dict")
        XCTAssertTrue(childKeys?.contains("Payments") ?? false, "Mined block should include Payments child block")

        // Submit through full pipeline
        let header = HeaderImpl<Block>(node: firstBlock)
        let storer = BufferedStorer()
        try header.storeRecursively(storer: storer)
        await storer.flush(to: f)

        let _ = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header, block: firstBlock
        )
        let _ = await nexusLevel.extractAndProcessChildBlocks(
            parentBlock: firstBlock, parentBlockHeader: header, fetcher: f
        )

        let nexusHeight = await nexusChain.getHighestBlockIndex()
        XCTAssertGreaterThan(nexusHeight, 0)

        let childHeight = await childChain.getHighestBlockIndex()
        XCTAssertGreaterThan(childHeight, 0, "Child chain should advance after processing mined block with child")
    }

    func testTwoMinerConvergenceWithChildChain() async throws {
        let f = fetcher()
        let t = now() - 5_000
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Payments")
        let kp = CryptoUtils.generateKeyPair()
        let identity = MinerIdentity(publicKeyHex: kp.publicKey, privateKeyHex: kp.privateKey)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256.max, fetcher: f
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256.max, fetcher: f
        )

        // Node A: mines
        let chainA = ChainState.fromGenesis(block: nexusGenesis)
        let childChainA = ChainState.fromGenesis(block: childGenesis)
        let childLevelA = ChainLevel(chain: childChainA, children: [:])
        let nexusLevelA = ChainLevel(chain: chainA, children: ["Payments": childLevelA])

        // Node B: receives
        let chainB = ChainState.fromGenesis(block: nexusGenesis)
        let childChainB = ChainState.fromGenesis(block: childGenesis)
        let childLevelB = ChainLevel(chain: childChainB, children: [:])
        let nexusLevelB = ChainLevel(chain: chainB, children: ["Payments": childLevelB])

        let gs1 = BufferedStorer()
        try HeaderImpl<Block>(node: nexusGenesis).storeRecursively(storer: gs1)
        await gs1.flush(to: f)
        let gs2 = BufferedStorer()
        try HeaderImpl<Block>(node: childGenesis).storeRecursively(storer: gs2)
        await gs2.flush(to: f)

        let childCtx = ChildMiningContext(
            directory: "Payments", chainState: childChainA,
            mempool: Mempool(maxSize: 100), fetcher: f, spec: childSpec
        )
        let miner = MinerLoop(
            chainState: chainA, mempool: Mempool(maxSize: 100), fetcher: f,
            spec: nexusSpec, identity: identity, childContexts: [childCtx],
            batchSize: 10_000
        )

        let collector = BlockCollector()
        await miner.setDelegate(collector)
        await miner.start()
        try await Task.sleep(for: .seconds(3))
        await miner.stop()

        let minedBlocks = await collector.blocks
        XCTAssertGreaterThan(minedBlocks.count, 0)

        // Submit miner A's first block to both nodes
        let block = minedBlocks[0].0
        let header = HeaderImpl<Block>(node: block)
        let storer = BufferedStorer()
        try header.storeRecursively(storer: storer)
        await storer.flush(to: f)

        // Node A processes
        let _ = await chainA.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header, block: block
        )
        let _ = await nexusLevelA.extractAndProcessChildBlocks(
            parentBlock: block, parentBlockHeader: header, fetcher: f
        )

        // Node B processes same block (simulates receiving from peer)
        let _ = await chainB.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header, block: block
        )
        let _ = await nexusLevelB.extractAndProcessChildBlocks(
            parentBlock: block, parentBlockHeader: header, fetcher: f
        )

        // Verify convergence
        let tipA = await chainA.getMainChainTip()
        let tipB = await chainB.getMainChainTip()
        XCTAssertEqual(tipA, tipB, "Both nodes should agree on nexus tip")

        let childHeightA = await childChainA.getHighestBlockIndex()
        let childHeightB = await childChainB.getHighestBlockIndex()
        XCTAssertEqual(childHeightA, childHeightB, "Both nodes should agree on child chain height")
        XCTAssertGreaterThan(childHeightA, 0, "Child chain should advance on both nodes")
    }
}

// ============================================================================
// MARK: - Remaining Discovery Tests
// ============================================================================

final class MultiChainDiscoveryRemainingTests: XCTestCase {

    func testDuplicateChildChainDiscoveryIsIdempotent() async throws {
        let f = fetcher()
        let t = now() - 10_000
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Payments")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Payments": childLevel])

        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            childBlocks: ["Payments": childGenesis],
            timestamp: t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let _ = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: nexusBlock1), block: nexusBlock1
        )
        let _ = await nexusLevel.extractAndProcessChildBlocks(
            parentBlock: nexusBlock1,
            parentBlockHeader: HeaderImpl<Block>(node: nexusBlock1),
            fetcher: f
        )

        let dirs = await nexusLevel.childDirectories()
        XCTAssertEqual(dirs.count, 1)
        XCTAssertEqual(dirs, ["Payments"])
    }
}
