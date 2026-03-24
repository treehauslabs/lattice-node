import XCTest
@testable import LatticeNode
import Lattice
import cashew
import UInt256
import AcornMemoryWorker
import Acorn
import Ivy

// MARK: - Test Infrastructure

private func testSpec(blockTime: UInt64 = 1000) -> ChainSpec {
    ChainSpec(
        directory: "Nexus",
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        premine: 0,
        targetBlockTime: blockTime,
        initialReward: 1024,
        halvingInterval: 210_000
    )
}

private actor TestCAS: Fetcher {
    var store: [String: Data] = [:]
    func fetch(rawCid: String) async throws -> Data {
        guard let data = store[rawCid] else { throw NSError(domain: "NotFound", code: 404) }
        return data
    }
    func put(cid: String, data: Data) { store[cid] = data }
}

// MARK: - StateStore Scenario Tests

final class StateStoreScenarioTests: XCTestCase {

    private func makeStore() throws -> StateStore {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try StateStore(storagePath: tmp, chain: "Test")
    }

    func testAccountCreateReadDelete() async throws {
        let store = try makeStore()
        let b0 = await store.getBalance(address: "alice")
        XCTAssertNil(b0)

        await store.setAccount(address: "alice", balance: 1000, nonce: 0, atHeight: 1)
        let b1 = await store.getBalance(address: "alice")
        XCTAssertEqual(b1, 1000)

        await store.deleteAccount(address: "alice")
        let b2 = await store.getBalance(address: "alice")
        XCTAssertNil(b2)
    }

    func testBlockIndexRoundtrip() async throws {
        let store = try makeStore()
        await store.setBlock(height: 0, hash: "genesis", timestamp: 0, difficulty: "max")
        await store.setBlock(height: 1, hash: "block1", timestamp: 1000, difficulty: "half")

        let _v2 = await store.getBlockHash(atHeight: 0)


        XCTAssertEqual(_v2, "genesis")
        let _v3 = await store.getBlockHash(atHeight: 1)

        XCTAssertEqual(_v3, "block1")
        let _v4 = await store.getBlockHeight(forHash: "block1")

        XCTAssertEqual(_v4, 1)
        let noBlock = await store.getBlockHash(atHeight: 99)
        XCTAssertNil(noBlock)
    }

    func testApplyBlockAtomicity() async throws {
        let store = try makeStore()
        let changeset = StateChangeset(
            height: 1,
            blockHash: "block1",
            accountUpdates: [
                (address: "alice", balance: 500, nonce: 0),
                (address: "bob", balance: 300, nonce: 0),
            ],
            timestamp: 1000,
            difficulty: "ff",
            stateRoot: "root1"
        )
        await store.applyBlock(changeset)

        let _v5 = await store.getBalance(address: "alice")


        XCTAssertEqual(_v5, 500)
        let _v6 = await store.getBalance(address: "bob")

        XCTAssertEqual(_v6, 300)
        let _v7 = await store.getBlockHash(atHeight: 1)

        XCTAssertEqual(_v7, "block1")
        let _v8 = await store.getHeight()

        XCTAssertEqual(_v8, 1)
        let _v9 = await store.getChainTip()

        XCTAssertEqual(_v9, "block1")
    }

    func testRollbackRestoresPreviousState() async throws {
        let store = try makeStore()

        await store.setAccount(address: "alice", balance: 1000, nonce: 0, atHeight: 0)

        let changeset = StateChangeset(
            height: 1,
            blockHash: "block1",
            accountUpdates: [(address: "alice", balance: 500, nonce: 1)],
            timestamp: 1000,
            difficulty: "ff",
            stateRoot: "root1"
        )
        await store.applyBlock(changeset)
        let _v10 = await store.getBalance(address: "alice")

        XCTAssertEqual(_v10, 500)

        await store.rollbackTo(height: 0)
        let _v11 = await store.getBalance(address: "alice")

        XCTAssertEqual(_v11, 1000)
    }

    func testMultiBlockRollback() async throws {
        let store = try makeStore()
        await store.setAccount(address: "alice", balance: 1000, nonce: 0, atHeight: 0)

        for i in 1...5 {
            let changeset = StateChangeset(
                height: UInt64(i),
                blockHash: "block\(i)",
                accountUpdates: [(address: "alice", balance: UInt64(1000 - i * 100), nonce: UInt64(i))],
                timestamp: Int64(i * 1000),
                difficulty: "ff",
                stateRoot: "root\(i)"
            )
            await store.applyBlock(changeset)
        }
        let _v12 = await store.getBalance(address: "alice")

        XCTAssertEqual(_v12, 500)

        await store.rollbackTo(height: 2)
        let _v13 = await store.getBalance(address: "alice")

        XCTAssertEqual(_v13, 800)

        await store.rollbackTo(height: 0)
        let _v14 = await store.getBalance(address: "alice")

        XCTAssertEqual(_v14, 1000)
    }

    func testPruneDiffsRemovesOldEntries() async throws {
        let store = try makeStore()
        for i in 0..<10 {
            await store.setAccount(address: "alice", balance: UInt64(i * 100), nonce: 0, atHeight: UInt64(i))
        }
        await store.pruneDiffs(belowHeight: 5)
        await store.rollbackTo(height: 4)
        // After pruning diffs below 5, rolling back to 4 should fail gracefully
        // (no diff data to restore from for heights 0-4)
        let balance = await store.getBalance(address: "alice")
        XCTAssertNotNil(balance)
    }

    func testTransactionHistoryQuery() async throws {
        let store = try makeStore()
        await store.indexTransaction(address: "alice", txCID: "tx1", blockHash: "b1", height: 1)
        await store.indexTransaction(address: "alice", txCID: "tx2", blockHash: "b2", height: 2)
        await store.indexTransaction(address: "bob", txCID: "tx3", blockHash: "b2", height: 2)

        let aliceHistory = await store.getTransactionHistory(address: "alice")
        XCTAssertEqual(aliceHistory.count, 2)
        XCTAssertEqual(aliceHistory.first?.txCID, "tx2")  // newest first

        let bobHistory = await store.getTransactionHistory(address: "bob")
        XCTAssertEqual(bobHistory.count, 1)
    }

    func testStateExpiry() async throws {
        let store = try makeStore()
        await store.setAccount(address: "old", balance: 999, nonce: 0, atHeight: 1)
        await store.setAccount(address: "new", balance: 111, nonce: 0, atHeight: 100)

        let expired = try await store.queryAccountsBelowHeight(50)
        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(expired.first?.address, "old")

        let accountData = await store.getAccount(address: "old")
        XCTAssertNotNil(accountData)

        await store.expireAccount(address: "old", atHeight: 100)
        let expiredBalance = await store.getBalance(address: "old")
        XCTAssertNil(expiredBalance)

        let proof = try JSONEncoder().encode(accountData!)
        let revived = await store.reviveAccount(address: "old", proof: proof, atHeight: 101)
        XCTAssertTrue(revived)
        let revivedBalance = await store.getBalance(address: "old")
        XCTAssertEqual(revivedBalance, 999)
    }

    func testReviveWithWrongProofFails() async throws {
        let store = try makeStore()
        await store.setAccount(address: "victim", balance: 999, nonce: 0, atHeight: 1)
        await store.expireAccount(address: "victim", atHeight: 100)

        let result = await store.reviveAccount(address: "victim", proof: Data("wrong".utf8), atHeight: 101)
        XCTAssertFalse(result)
    }

    func testReviveWithEmptyProofFails() async throws {
        let store = try makeStore()
        await store.setAccount(address: "victim", balance: 999, nonce: 0, atHeight: 1)
        await store.expireAccount(address: "victim", atHeight: 100)

        let result = await store.reviveAccount(address: "victim", proof: Data(), atHeight: 101)
        XCTAssertFalse(result)
    }
}

// MARK: - NodeMempool Adversarial Tests

final class MempoolAdversarialTests: XCTestCase {

    func testRBFOverflowProtection() async {
        let mempool = NodeMempool(maxSize: 100)
        let kp = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)

        let body1 = TransactionBody(
            accountActions: [AccountAction(owner: addr, oldBalance: 1000, newBalance: 0)],
            actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [addr], fee: UInt64.max - 10, nonce: 1
        )
        let h1 = HeaderImpl<TransactionBody>(node: body1)
        let sig1 = CryptoUtils.sign(message: h1.rawCID, privateKeyHex: kp.privateKey)!
        let tx1 = Transaction(signatures: [kp.publicKey: sig1], body: h1)
        let r1 = await mempool.addTransaction(tx1)
        if case .added = r1 {} else { XCTFail("Expected .added") }

        // Try to replace with same nonce but lower fee — should fail even with overflow
        let body2 = TransactionBody(
            accountActions: [AccountAction(owner: addr, oldBalance: 1000, newBalance: 0)],
            actions: [], swapActions: [], swapClaimActions: [],
            genesisActions: [], peerActions: [], settleActions: [],
            signers: [addr], fee: 5, nonce: 1
        )
        let h2 = HeaderImpl<TransactionBody>(node: body2)
        let sig2 = CryptoUtils.sign(message: h2.rawCID, privateKeyHex: kp.privateKey)!
        let tx2 = Transaction(signatures: [kp.publicKey: sig2], body: h2)
        let r2 = await mempool.addTransaction(tx2)
        if case .rejected = r2 {
            // Expected
        } else {
            XCTFail("Should reject RBF with lower fee")
        }
    }

    func testMempoolStressTest() async {
        let mempool = NodeMempool(maxSize: 500)
        var added = 0

        for i in 0..<1000 {
            let kp = CryptoUtils.generateKeyPair()
            let addr = CryptoUtils.createAddress(from: kp.publicKey)
            let body = TransactionBody(
                accountActions: [AccountAction(owner: addr, oldBalance: 1000, newBalance: 0)],
                actions: [], swapActions: [], swapClaimActions: [],
                genesisActions: [], peerActions: [], settleActions: [],
                signers: [addr], fee: UInt64(i + 1), nonce: UInt64(i)
            )
            let h = HeaderImpl<TransactionBody>(node: body)
            let sig = CryptoUtils.sign(message: h.rawCID, privateKeyHex: kp.privateKey)!
            let tx = Transaction(signatures: [kp.publicKey: sig], body: h)
            if await mempool.add(transaction: tx) { added += 1 }
        }

        let count = await mempool.count
        XCTAssertTrue(count <= 500)
        XCTAssertGreaterThan(added, 0)

        let selected = await mempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(selected.count, 10)

        // Verify fee ordering — each tx should have >= fee of next
        for i in 0..<(selected.count - 1) {
            let fee1 = selected[i].body.node?.fee ?? 0
            let fee2 = selected[i + 1].body.node?.fee ?? 0
            XCTAssertGreaterThanOrEqual(fee1, fee2)
        }
    }

    func testPerAccountFloodPrevention() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 10)
        let kp = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)

        var accepted = 0
        for i in 0..<20 {
            let body = TransactionBody(
                accountActions: [AccountAction(owner: addr, oldBalance: 1000, newBalance: UInt64(999 - i))],
                actions: [], swapActions: [], swapClaimActions: [],
                genesisActions: [], peerActions: [], settleActions: [],
                signers: [addr], fee: UInt64(100 + i), nonce: UInt64(i)
            )
            let h = HeaderImpl<TransactionBody>(node: body)
            let sig = CryptoUtils.sign(message: h.rawCID, privateKeyHex: kp.privateKey)!
            let tx = Transaction(signatures: [kp.publicKey: sig], body: h)
            if await mempool.add(transaction: tx) { accepted += 1 }
        }

        XCTAssertEqual(accepted, 10, "Should accept exactly maxPerAccount transactions")
    }
}

// MARK: - Protocol Version Tests

final class ProtocolVersionTests: XCTestCase {

    func testCompatibility() {
        XCTAssertTrue(LatticeProtocol.isCompatible(peerVersion: 1))
        XCTAssertFalse(LatticeProtocol.isCompatible(peerVersion: 0))
        XCTAssertFalse(LatticeProtocol.isCompatible(peerVersion: 99))
    }

    func testActiveForks() {
        let forks = LatticeProtocol.activeForks(atHeight: 0)
        XCTAssertEqual(forks.count, 1)
        XCTAssertEqual(forks.first?.name, "genesis")
    }

    func testChainAnnounceDataRoundtrip() {
        let original = ChainAnnounceData(
            chainDirectory: "Nexus",
            tipIndex: 42,
            tipCID: "baguqeera123",
            specCID: "baguqeera456",
            capabilities: [.fullNode, .miner],
            protocolVersion: LatticeProtocol.version
        )

        let serialized = original.serialize()
        let deserialized = ChainAnnounceData.deserialize(serialized)

        XCTAssertNotNil(deserialized)
        XCTAssertEqual(deserialized?.chainDirectory, "Nexus")
        XCTAssertEqual(deserialized?.tipIndex, 42)
        XCTAssertEqual(deserialized?.tipCID, "baguqeera123")
        XCTAssertEqual(deserialized?.specCID, "baguqeera456")
        XCTAssertEqual(deserialized?.protocolVersion, LatticeProtocol.version)
        XCTAssertTrue(deserialized?.capabilities.contains(.fullNode) ?? false)
        XCTAssertTrue(deserialized?.capabilities.contains(.miner) ?? false)
    }

    func testChainAnnounceDataRejectsCorruptedData() {
        let bad = Data([0x00])
        XCTAssertNil(ChainAnnounceData.deserialize(bad))
        XCTAssertNil(ChainAnnounceData.deserialize(Data()))
    }
}

// MARK: - Metrics Tests

final class MetricsTests: XCTestCase {

    func testCounterIncrement() async {
        let m = NodeMetrics()
        await m.increment("test_counter")
        await m.increment("test_counter")
        await m.increment("test_counter", by: 5)

        let output = await m.prometheus()
        XCTAssertTrue(output.contains("test_counter 7"))
    }

    func testGaugeSet() async {
        let m = NodeMetrics()
        await m.set("test_gauge", value: 42.5)

        let output = await m.prometheus()
        XCTAssertTrue(output.contains("test_gauge 42.5"))
    }

    func testPrometheusFormat() async {
        let m = NodeMetrics()
        await m.increment("blocks_total")
        await m.set("chain_height", value: 100)

        let output = await m.prometheus()
        XCTAssertTrue(output.contains("# TYPE blocks_total counter"))
        XCTAssertTrue(output.contains("# TYPE chain_height gauge"))
    }
}

// MARK: - Peer Diversity Tests

final class PeerDiversityTests: XCTestCase {

    func testSubnetExtraction() {
        XCTAssertEqual(PeerDiversity.subnet("192.168.1.1"), "192.168")
        XCTAssertEqual(PeerDiversity.subnet("10.0.0.1"), "10.0")
        XCTAssertEqual(PeerDiversity.subnet("::1"), "::1")
    }

    func testShouldConnectRespectsLimit() {
        let existing = [
            PeerEndpoint(publicKey: "a", host: "192.168.1.1", port: 4001),
            PeerEndpoint(publicKey: "b", host: "192.168.1.2", port: 4001),
        ]
        let sameSubnet = PeerEndpoint(publicKey: "c", host: "192.168.1.3", port: 4001)
        let diffSubnet = PeerEndpoint(publicKey: "d", host: "10.0.0.1", port: 4001)

        XCTAssertFalse(PeerDiversity.shouldConnect(to: sameSubnet, existingPeers: existing))
        XCTAssertTrue(PeerDiversity.shouldConnect(to: diffSubnet, existingPeers: existing))
    }

    func testSelectDiversePeersDistributesAcrossSubnets() {
        let candidates = (0..<20).map {
            PeerEndpoint(publicKey: "p\($0)", host: "\($0 / 5).\($0 % 5).0.1", port: 4001)
        }
        let selected = PeerDiversity.selectDiversePeers(from: candidates, existing: [], maxNew: 8)
        XCTAssertEqual(selected.count, 8)

        var subnets = Set<String>()
        for peer in selected {
            subnets.insert(PeerDiversity.subnet(peer.host))
        }
        XCTAssertGreaterThan(subnets.count, 1, "Should select from multiple subnets")
    }
}

// MARK: - SQLite Edge Cases

final class SQLiteDatabaseTests: XCTestCase {

    func testOpenAndCreateTable() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db").path
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)")
        try db.execute("INSERT INTO test (id, name) VALUES (?1, ?2)", params: [.int(1), .text("hello")])

        let rows = try db.query("SELECT * FROM test")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["name"]?.textValue, "hello")
    }

    func testTransactionRollback() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db").path
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, val TEXT)")
        try db.execute("INSERT INTO test VALUES (1, 'original')")

        try db.beginTransaction()
        try db.execute("UPDATE test SET val = 'modified' WHERE id = 1")
        try db.rollbackTransaction()

        let rows = try db.query("SELECT val FROM test WHERE id = 1")
        XCTAssertEqual(rows[0]["val"]?.textValue, "original")
    }

    func testBlobStorageRoundtrip() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db").path
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE blobs (key TEXT PRIMARY KEY, data BLOB)")

        let testData = Data([0x00, 0xFF, 0x42, 0x13, 0x37])
        try db.execute("INSERT INTO blobs VALUES (?1, ?2)", params: [.text("test"), .blob(testData)])

        let rows = try db.query("SELECT data FROM blobs WHERE key = ?1", params: [.text("test")])
        XCTAssertEqual(rows[0]["data"]?.blobValue, testData)
    }
}

// MARK: - Genesis Determinism

final class GenesisDeterminismTests: XCTestCase {

    func testGenesisIsDeterministic() async throws {
        let memory = MemoryCASWorker(capacity: 100_000)
        struct TestFetcher: Fetcher {
            let worker: MemoryCASWorker
            func fetch(rawCid: String) async throws -> Data {
                guard let data = await worker.getLocal(cid: ContentIdentifier(rawValue: rawCid)) else {
                    throw NSError(domain: "NotFound", code: 404)
                }
                return data
            }
        }
        let fetcher = TestFetcher(worker: memory)
        let r1 = try await NexusGenesis.create(fetcher: fetcher)
        let r2 = try await NexusGenesis.create(fetcher: fetcher)
        XCTAssertEqual(r1.blockHash, r2.blockHash, "Genesis must be deterministic")
    }

    func testGenesisHasCorrectReward() {
        let spec = NexusGenesis.spec
        XCTAssertEqual(spec.initialReward, 1_048_576)
        XCTAssertEqual(spec.halvingInterval, 315_576_000)
        XCTAssertEqual(spec.targetBlockTime, 10_000)
    }

    func testPremineAmountIsAbout10Percent() {
        let spec = NexusGenesis.spec
        let premineAmount = spec.premineAmount()
        let totalSupply = spec.initialReward * spec.halvingInterval * 2
        let ratio = Double(premineAmount) / Double(totalSupply)
        XCTAssertGreaterThan(ratio, 0.09)
        XCTAssertLessThan(ratio, 0.11)
    }
}
