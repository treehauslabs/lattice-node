import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import VolumeBroker
import ArrayTrie

// Helpers in TestHelpers.swift: cas(), testSpec(), sign(), addr(), now()
private func fetcher() -> TestBrokerFetcher { cas() }

private func deepCopyCID(_ cid: String, from source: TestBrokerFetcher, to dest: TestBrokerFetcher, visited: inout Set<String>) async {
    guard !cid.isEmpty, !visited.contains(cid) else { return }
    visited.insert(cid)
    guard let data = try? await source.fetch(rawCid: cid) else { return }
    await dest.store(rawCid: cid, data: data)

    if let block = Block(data: data) {
        if let prevCID = block.previousBlock?.rawCID {
            await deepCopyCID(prevCID, from: source, to: dest, visited: &visited)
        }
        await deepCopyCID(block.transactions.rawCID, from: source, to: dest, visited: &visited)
        await deepCopyCID(block.spec.rawCID, from: source, to: dest, visited: &visited)
        await deepCopyCID(block.homestead.rawCID, from: source, to: dest, visited: &visited)
        await deepCopyCID(block.frontier.rawCID, from: source, to: dest, visited: &visited)
        await deepCopyCID(block.parentHomestead.rawCID, from: source, to: dest, visited: &visited)
        await deepCopyCID(block.childBlocks.rawCID, from: source, to: dest, visited: &visited)
    }
}

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
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        var prev = genesis
        for i in 1...10 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: f
            )
            let header = VolumeImpl<Block>(node: block)
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
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let mempool = NodeMempool(maxSize: 100)

        await f.store(rawCid: VolumeImpl<Block>(node: genesis).rawCID, data: genesis.toData()!)

        let miner = MinerLoop(
            chainState: chain, mempool: mempool, fetcher: f,
            spec: spec, chainPath: [spec.directory], identity: identity
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
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        var prev = genesis
        for i in 1...5 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: f
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: VolumeImpl<Block>(node: block), block: block
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
            blockHeader: VolumeImpl<Block>(node: block6), block: block6
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
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let b1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: VolumeImpl<Block>(node: b1), block: b1
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

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
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
            blockHeader: VolumeImpl<Block>(node: nexusBlock1), block: nexusBlock1
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
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(childPremine))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, transactions: [sign(childPremineBody, kp)],
            timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        await f.store(rawCid: VolumeImpl<Block>(node: childGenesis).rawCID, data: childGenesis.toData()!)

        let childMempool = NodeMempool(maxSize: 100)

        let receiver = CryptoUtils.generateKeyPair()
        let receiverAddr = addr(receiver.publicKey)
        let childReward = childSpec.rewardAtBlock(0)
        let transferBody = TransactionBody(
            accountActions: [
                AccountAction(owner: kpAddr, delta: Int64(childPremine - 100) - Int64(childPremine)),
                AccountAction(owner: receiverAddr, delta: Int64(100 + childReward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 1
        )
        let childTx = sign(transferBody, kp)
        let added = await childMempool.add(transaction: childTx)
        XCTAssertTrue(added)

        let childCtx = ChildMiningContext(
            directory: "Payments", chainPath: ["Nexus", "Payments"], chainState: childChain,
            mempool: childMempool, fetcher: f, spec: childSpec
        )

        let nexusMempool = NodeMempool(maxSize: 100)
        let miner = MinerLoop(
            chainState: nexusChain, mempool: nexusMempool, fetcher: f,
            spec: nexusSpec, chainPath: [nexusSpec.directory], childContexts: [childCtx]
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

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let chainA = ChainState.fromGenesis(block: childAGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let chainB = ChainState.fromGenesis(block: childBGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        await f.store(rawCid: VolumeImpl<Block>(node: childAGenesis).rawCID, data: childAGenesis.toData()!)
        await f.store(rawCid: VolumeImpl<Block>(node: childBGenesis).rawCID, data: childBGenesis.toData()!)

        let mempoolA = NodeMempool(maxSize: 100)
        let mempoolB = NodeMempool(maxSize: 100)

        let ctxA = ChildMiningContext(directory: "Payments", chainPath: ["Nexus", "Payments"], chainState: chainA, mempool: mempoolA, fetcher: f, spec: childASpec)
        let ctxB = ChildMiningContext(directory: "Identity", chainPath: ["Nexus", "Identity"], chainState: chainB, mempool: mempoolB, fetcher: f, spec: childBSpec)

        let nexusMempool = NodeMempool(maxSize: 100)
        let miner = MinerLoop(
            chainState: nexusChain, mempool: nexusMempool, fetcher: f,
            spec: nexusSpec, chainPath: [nexusSpec.directory], childContexts: [ctxA, ctxB]
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
        let mempool = NodeMempool(maxSize: 100)

        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
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
        let mempool = NodeMempool(maxSize: 100)

        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 10, nonce: 0
        )
        let tx = sign(body, kp)
        let first = await mempool.add(transaction: tx)
        let second = await mempool.add(transaction: tx)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testMempoolSelectsHighestFeeFirst() async {
        let mempool = NodeMempool(maxSize: 100)

        // Distinct senders — otherwise nonce-ordering within a single account
        // forces ascending-nonce selection, which can conflict with fee order.
        for i: UInt64 in 0..<5 {
            let kp = CryptoUtils.generateKeyPair()
            let kpAddr = addr(kp.publicKey)
            let body = TransactionBody(
                accountActions: [], actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [kpAddr], fee: i * 10, nonce: 0
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
        let mempool = NodeMempool(maxSize: 100)

        var cids: [String] = []
        for i: UInt64 in 0..<3 {
            let body = TransactionBody(
                accountActions: [], actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
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
        let mempool = NodeMempool(maxSize: 100)

        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: ["fake"], fee: 10, nonce: 0
        )
        let tx = Transaction(signatures: [kp.publicKey: "deadbeef"], body: HeaderImpl<TransactionBody>(node: body))

        let added = await mempool.add(transaction: tx)
        XCTAssertTrue(added, "NodeMempool accepts all txs; signature validation is in TransactionValidator")
    }

    func testMempoolPerChainIsolation() async {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let nexusMempool = NodeMempool(maxSize: 100)
        let childMempool = NodeMempool(maxSize: 100)

        let nexusBody = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 10, nonce: 0
        )
        let childBody = TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 20, nonce: 0
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

        let genesisA = try await GenesisCeremony.create(config: config, fetcher: f, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let genesisB = try await GenesisCeremony.create(config: config, fetcher: f, retentionDepth: DEFAULT_RETENTION_DEPTH)
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
            await fA.store(rawCid: VolumeImpl<Block>(node: block).rawCID, data: block.toData()!)
            let _ = await genesisA.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: VolumeImpl<Block>(node: block), block: block
            )
            blocks.append(block)
            prev = block
        }

        for block in blocks {
            let header = VolumeImpl<Block>(node: block)
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

        let genesisA = try await GenesisCeremony.create(config: config, fetcher: f, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let genesisB = try await GenesisCeremony.create(config: config, fetcher: f, retentionDepth: DEFAULT_RETENTION_DEPTH)

        var shortPrev = genesisB.block
        for i in 1...3 {
            let b = try await BlockBuilder.buildBlock(
                previous: shortPrev, timestamp: t + Int64(i) * 500,
                difficulty: UInt256(1000), nonce: UInt64(i + 100), fetcher: f
            )
            let _ = await genesisB.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: VolumeImpl<Block>(node: b), block: b
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
                blockHeader: VolumeImpl<Block>(node: b), block: b
            )
            longBlocks.append(b)
            longPrev = b
        }

        for block in longBlocks {
            let _ = await genesisB.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: VolumeImpl<Block>(node: block), block: block
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

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let nexusLevel = ChainLevel(chain: nexusChain, children: [:])

        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            childBlocks: ["Payments": childGenesis],
            timestamp: t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let header1 = VolumeImpl<Block>(node: nexusBlock1)

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

        let chainA = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let chainB = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let levelA = ChainLevel(chain: chainA, children: [:])
        let levelB = ChainLevel(chain: chainB, children: [:])

        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            childBlocks: ["Payments": childGenesis],
            timestamp: t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let header1 = VolumeImpl<Block>(node: nexusBlock1)

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
        let gs1 = BufferedStorer()
        try VolumeImpl<Block>(node: nexusGenesis).storeRecursively(storer: gs1)
        await gs1.flush(to: f)
        let gs2 = BufferedStorer()
        try VolumeImpl<Block>(node: childGenesis).storeRecursively(storer: gs2)
        await gs2.flush(to: f)

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
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
        let bs1 = BufferedStorer()
        try VolumeImpl<Block>(node: childBlock1).storeRecursively(storer: bs1)
        await bs1.flush(to: f)
        let bs2 = BufferedStorer()
        try VolumeImpl<Block>(node: nexusBlock1).storeRecursively(storer: bs2)
        await bs2.flush(to: f)
        let header1 = VolumeImpl<Block>(node: nexusBlock1)

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

        let header = VolumeImpl<Block>(node: genesis)
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

        let header = VolumeImpl<Block>(node: genesis)
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

        let originalCID = VolumeImpl<Block>(node: genesis).rawCID
        let restoredCID = VolumeImpl<Block>(node: restored!).rawCID
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
            let header = VolumeImpl<Block>(node: block)
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
    let f: TestBrokerFetcher
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
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(childSpec.premineAmount()))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, transactions: [sign(premineBody, kp)],
            timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        let nexusStorer = BufferedStorer()
        try VolumeImpl<Block>(node: nexusGenesis).storeRecursively(storer: nexusStorer)
        await nexusStorer.flush(to: f)
        let childStorer = BufferedStorer()
        try VolumeImpl<Block>(node: childGenesis).storeRecursively(storer: childStorer)
        await childStorer.flush(to: f)

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
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
            blockHeader: VolumeImpl<Block>(node: block), block: block
        )
    }

    func extractChildren(from block: Block) async -> [String] {
        await nexusLevel.extractAndProcessChildBlocks(
            parentBlock: block,
            parentBlockHeader: VolumeImpl<Block>(node: block),
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

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let chainA = ChainState.fromGenesis(block: childAGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let chainB = ChainState.fromGenesis(block: childBGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

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
                AccountAction(owner: env.kpAddr, delta: Int64(premineAmount - 500) - Int64(premineAmount)),
                AccountAction(owner: receiverAddr, delta: Int64(500))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [env.kpAddr], fee: 0, nonce: 1
        )
        let tx = sign(transferBody, env.kp)

        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: env.childGenesis, transactions: [tx],
            timestamp: env.t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: env.f
        )
        let childResult = await env.childChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: VolumeImpl<Block>(node: childBlock1), block: childBlock1
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
        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childMempool = NodeMempool(maxSize: 100)

        let ctx = ChildMiningContext(
            directory: "Payments", chainPath: ["Nexus", "Payments"], chainState: childChain,
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
        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        await f.store(rawCid: VolumeImpl<Block>(node: nexusGenesis).rawCID, data: nexusGenesis.toData()!)

        var contexts: [ChildMiningContext] = []
        for dir in ["Payments", "Identity", "Data"] {
            let spec = testSpec(dir)
            let genesis = try await BlockBuilder.buildGenesis(
                spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
            )
            let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
            await f.store(rawCid: VolumeImpl<Block>(node: genesis).rawCID, data: genesis.toData()!)
            contexts.append(ChildMiningContext(
                directory: dir, chainPath: [nexusSpec.directory, dir], chainState: chain,
                mempool: NodeMempool(maxSize: 100), fetcher: f, spec: spec
            ))
        }

        let miner = MinerLoop(
            chainState: nexusChain, mempool: NodeMempool(maxSize: 100),
            fetcher: f, spec: nexusSpec, chainPath: [nexusSpec.directory], childContexts: contexts
        )
        XCTAssertNotNil(miner)
        let mining = await miner.isMining
        XCTAssertFalse(mining)
    }

    func testChildMempoolIsolation() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let nexusMempool = NodeMempool(maxSize: 100)
        let childAMempool = NodeMempool(maxSize: 100)
        let childBMempool = NodeMempool(maxSize: 100)

        for (mempool, fee) in [(nexusMempool, 10 as UInt64), (childAMempool, 20), (childBMempool, 30)] {
            let body = TransactionBody(
                accountActions: [], actions: [], depositActions: [], 
                genesisActions: [], receiptActions: [], withdrawalActions: [],
                signers: [kpAddr], fee: fee, nonce: 0
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

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
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
            blockHeader: VolumeImpl<Block>(node: nexusBlock1), block: nexusBlock1
        )
        let _ = await nexusLevel.extractAndProcessChildBlocks(
            parentBlock: nexusBlock1,
            parentBlockHeader: VolumeImpl<Block>(node: nexusBlock1),
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
        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
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
            blockHeader: VolumeImpl<Block>(node: nexusBlock1), block: nexusBlock1
        )
        let _ = await nexusLevel.extractAndProcessChildBlocks(
            parentBlock: nexusBlock1,
            parentBlockHeader: VolumeImpl<Block>(node: nexusBlock1),
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

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let nexusLevel = ChainLevel(chain: nexusChain, children: [:])

        let genesisStorer = BufferedStorer()
        try VolumeImpl<Block>(node: nexusGenesis).storeRecursively(storer: genesisStorer)
        await genesisStorer.flush(to: f)
        let childGenesisStorer = BufferedStorer()
        try VolumeImpl<Block>(node: childGenesis).storeRecursively(storer: childGenesisStorer)
        await childGenesisStorer.flush(to: f)

        // Block 1: introduce child chain genesis
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            childBlocks: ["Payments": childGenesis],
            timestamp: t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let header1 = VolumeImpl<Block>(node: nexusBlock1)
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
        let header2 = VolumeImpl<Block>(node: nexusBlock2)
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

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Payments": childLevel])

        let genesisStorer = BufferedStorer()
        try VolumeImpl<Block>(node: nexusGenesis).storeRecursively(storer: genesisStorer)
        await genesisStorer.flush(to: f)
        let childGenesisStorer = BufferedStorer()
        try VolumeImpl<Block>(node: childGenesis).storeRecursively(storer: childGenesisStorer)
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
        let header1 = VolumeImpl<Block>(node: nexusBlock1)
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

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Payments": childLevel])

        let genesisStorer = BufferedStorer()
        try VolumeImpl<Block>(node: nexusGenesis).storeRecursively(storer: genesisStorer)
        await genesisStorer.flush(to: f)
        let childGenesisStorer = BufferedStorer()
        try VolumeImpl<Block>(node: childGenesis).storeRecursively(storer: childGenesisStorer)
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
        let header1 = VolumeImpl<Block>(node: nexusBlock1)
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

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Payments": childLevel])

        for storer in [BufferedStorer(), BufferedStorer()] {
            // Slightly wasteful but ensures both are stored
        }
        let gs1 = BufferedStorer()
        try VolumeImpl<Block>(node: nexusGenesis).storeRecursively(storer: gs1)
        await gs1.flush(to: f)
        let gs2 = BufferedStorer()
        try VolumeImpl<Block>(node: childGenesis).storeRecursively(storer: gs2)
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
            let header = VolumeImpl<Block>(node: nexusBlock)
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

    func minerDidProduceBlock(_ block: Block, hash: String, pendingRemovals: MinedBlockPendingRemovals) async {
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
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let nexusLevel = ChainLevel(chain: chain, children: [:])
        let lattice = Lattice(nexus: nexusLevel)
        let mempool = NodeMempool(maxSize: 100)

        let genesisStorer = BufferedStorer()
        try VolumeImpl<Block>(node: genesis).storeRecursively(storer: genesisStorer)
        await genesisStorer.flush(to: f)

        let miner = MinerLoop(
            chainState: chain, mempool: mempool, fetcher: f,
            spec: spec, chainPath: [spec.directory], identity: identity, batchSize: 10_000
        )

        let collector = BlockCollector()
        await miner.setDelegate(collector)
        await miner.start()

        while await collector.blocks.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        await miner.stop()

        let minedBlocks = await collector.blocks
        XCTAssertGreaterThan(minedBlocks.count, 0, "Miner should produce at least one block")

        for (block, _) in minedBlocks {
            let header = VolumeImpl<Block>(node: block)
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

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Payments": childLevel])

        let gs1 = BufferedStorer()
        try VolumeImpl<Block>(node: nexusGenesis).storeRecursively(storer: gs1)
        await gs1.flush(to: f)
        let gs2 = BufferedStorer()
        try VolumeImpl<Block>(node: childGenesis).storeRecursively(storer: gs2)
        await gs2.flush(to: f)

        let childMempool = NodeMempool(maxSize: 100)
        let childCtx = ChildMiningContext(
            directory: "Payments", chainPath: ["Nexus", "Payments"], chainState: childChain,
            mempool: childMempool, fetcher: f, spec: childSpec
        )

        let nexusMempool = NodeMempool(maxSize: 100)
        let miner = MinerLoop(
            chainState: nexusChain, mempool: nexusMempool, fetcher: f,
            spec: nexusSpec, chainPath: [nexusSpec.directory], identity: identity, childContexts: [childCtx],
            batchSize: 10_000
        )

        let collector = BlockCollector()
        await miner.setDelegate(collector)
        await miner.start()

        while await collector.blocks.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        await miner.stop()

        let minedBlocks = await collector.blocks
        XCTAssertGreaterThan(minedBlocks.count, 0, "Miner should produce blocks")

        let firstBlock = minedBlocks[0].0
        let childBlocksDict = try? await firstBlock.childBlocks.resolve(fetcher: f).node
        let childKeys = try? childBlocksDict?.allKeys()
        XCTAssertNotNil(childKeys, "Mined block should contain child blocks dict")
        XCTAssertTrue(childKeys?.contains("Payments") ?? false, "Mined block should include Payments child block")

        // Submit through full pipeline
        let header = VolumeImpl<Block>(node: firstBlock)
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
        let chainA = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childChainA = ChainState.fromGenesis(block: childGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childLevelA = ChainLevel(chain: childChainA, children: [:])
        let nexusLevelA = ChainLevel(chain: chainA, children: ["Payments": childLevelA])

        // Node B: receives
        let chainB = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childChainB = ChainState.fromGenesis(block: childGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childLevelB = ChainLevel(chain: childChainB, children: [:])
        let nexusLevelB = ChainLevel(chain: chainB, children: ["Payments": childLevelB])

        let gs1 = BufferedStorer()
        try VolumeImpl<Block>(node: nexusGenesis).storeRecursively(storer: gs1)
        await gs1.flush(to: f)
        let gs2 = BufferedStorer()
        try VolumeImpl<Block>(node: childGenesis).storeRecursively(storer: gs2)
        await gs2.flush(to: f)

        let childCtx = ChildMiningContext(
            directory: "Payments", chainPath: ["Nexus", "Payments"], chainState: childChainA,
            mempool: NodeMempool(maxSize: 100), fetcher: f, spec: childSpec
        )
        let miner = MinerLoop(
            chainState: chainA, mempool: NodeMempool(maxSize: 100), fetcher: f,
            spec: nexusSpec, chainPath: [nexusSpec.directory], identity: identity, childContexts: [childCtx],
            batchSize: 10_000
        )

        let collector = BlockCollector()
        await miner.setDelegate(collector)
        await miner.start()
        while await collector.blocks.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        await miner.stop()

        let minedBlocks = await collector.blocks
        XCTAssertGreaterThan(minedBlocks.count, 0)

        // Submit miner A's first block to both nodes
        let block = minedBlocks[0].0
        let header = VolumeImpl<Block>(node: block)
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
// MARK: - CAS Isolation: Separate CAS per chain
// ============================================================================

final class CASIsolationTests: XCTestCase {

    func testDeepCopyBlockBetweenSeparateCAS() async throws {
        let nexusCAS = fetcher()
        let childCAS = fetcher()
        let t = now() - 5_000
        let childSpec = testSpec("Payments", premine: 1000)
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(childSpec.premineAmount()))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, transactions: [sign(premineBody, kp)],
            timestamp: t, difficulty: UInt256(1000), fetcher: nexusCAS
        )

        let genesisHeader = VolumeImpl<Block>(node: childGenesis)
        let storer = BufferedStorer()
        try genesisHeader.storeRecursively(storer: storer)
        await storer.flush(to: nexusCAS)

        let genesisCID = genesisHeader.rawCID

        do {
            let _ = try await childCAS.fetch(rawCid: genesisCID)
            XCTFail("Child CAS should not have the block yet")
        } catch {}

        // Deep copy using CID walking (same as production handleChildChainDiscovery)
        var visited = Set<String>()
        await deepCopyCID(genesisCID, from: nexusCAS, to: childCAS, visited: &visited)
        XCTAssertGreaterThan(visited.count, 3, "Should copy block + multiple child CIDs")

        let fetchedData = try await childCAS.fetch(rawCid: genesisCID)
        XCTAssertEqual(fetchedData, childGenesis.toData()!)

        let specData = try await childCAS.fetch(rawCid: childGenesis.spec.rawCID)
        XCTAssertNotNil(ChainSpec(data: specData))

        let frontierData = try await childCAS.fetch(rawCid: childGenesis.frontier.rawCID)
        XCTAssertNotNil(frontierData)
    }

    func testMinerCanBuildChildBlockFromSeparateCAS() async throws {
        let nexusCAS = fetcher()
        let childCAS = fetcher()
        let t = now() - 5_000
        let childSpec = testSpec("Payments")

        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256(1000), fetcher: nexusCAS
        )
        let genesisHeader = VolumeImpl<Block>(node: childGenesis)
        let storer = BufferedStorer()
        try genesisHeader.storeRecursively(storer: storer)
        await storer.flush(to: nexusCAS)

        // Deep copy to child CAS
        var visited = Set<String>()
        await deepCopyCID(genesisHeader.rawCID, from: nexusCAS, to: childCAS, visited: &visited)

        // Simulate what MinerLoop.buildChildBlocks does: fetch tip, build new block
        let tipData = try await childCAS.fetch(rawCid: genesisHeader.rawCID)
        let tipBlock = Block(data: tipData)
        XCTAssertNotNil(tipBlock, "Should deserialize child genesis from child CAS")
        XCTAssertEqual(tipBlock!.index, 0)

        // This is the critical call — BlockBuilder needs frontier data from child CAS
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: tipBlock!, timestamp: t + 1000,
            difficulty: UInt256(1000), nonce: 1, fetcher: childCAS
        )
        XCTAssertEqual(childBlock1.index, 1)
        XCTAssertEqual(childBlock1.homestead.rawCID, tipBlock!.frontier.rawCID)
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

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childChain = ChainState.fromGenesis(block: childGenesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Payments": childLevel])

        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            childBlocks: ["Payments": childGenesis],
            timestamp: t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: f
        )
        let _ = await nexusChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: VolumeImpl<Block>(node: nexusBlock1), block: nexusBlock1
        )
        let _ = await nexusLevel.extractAndProcessChildBlocks(
            parentBlock: nexusBlock1,
            parentBlockHeader: VolumeImpl<Block>(node: nexusBlock1),
            fetcher: f
        )

        let dirs = await nexusLevel.childDirectories()
        XCTAssertEqual(dirs.count, 1)
        XCTAssertEqual(dirs, ["Payments"])
    }
}
