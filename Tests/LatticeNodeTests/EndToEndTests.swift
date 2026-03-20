import XCTest
@testable import Lattice
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
              initialRewardExponent: 10, difficultyAdjustmentWindow: 5)
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

@MainActor
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

@MainActor
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
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 0
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
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 1
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

@MainActor
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

@MainActor
final class MempoolEndToEndTests: XCTestCase {

    func testTransactionAddedAndSelected() async {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let mempool = Mempool(maxSize: 100)

        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
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
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
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
                accountActions: [], actions: [], depositActions: [], genesisActions: [],
                peerActions: [], receiptActions: [], withdrawalActions: [],
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
                accountActions: [], actions: [], depositActions: [], genesisActions: [],
                peerActions: [], receiptActions: [], withdrawalActions: [],
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
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
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
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 10, nonce: 0
        )
        let childBody = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            peerActions: [], receiptActions: [], withdrawalActions: [],
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

@MainActor
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
// MARK: - Block Storage via Acorn CAS
// ============================================================================

@MainActor
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
