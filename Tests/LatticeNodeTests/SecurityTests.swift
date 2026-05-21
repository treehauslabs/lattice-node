import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew

// Security smoke tests — each test demonstrates a specific vulnerability.
// These run WITHOUT the CI skip since they're lightweight unit-level checks.

final class SecurityTests: XCTestCase {

    // MARK: - SEC-001: unauthenticated deployChain

    /// Any caller can deploy child chains on a node that has --rpc-bind 0.0.0.0
    /// and no --rpc-auth flag. This test verifies that deployChain REQUIRES
    /// authentication even when global auth is disabled.
    func testDeployChainRequiresAuth() async throws {
        let p = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let genesis = testGenesis()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p, storagePath: tmp, enableLocalDiscovery: false
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        defer { Task { await node.stop() } }

        let rpcPort = nextTestPort()
        // Start RPC bound to 0.0.0.0 with NO auth — simulates a publicly-exposed node
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "0.0.0.0", allowedOrigin: "*")
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await Task.sleep(for: .milliseconds(500))

        // Attempt to deploy a child chain without any auth token
        // Request uses a non-loopback Host header to simulate an internet request
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/chain/deploy")!)
        req.addValue("external-host.example.com", forHTTPHeaderField: "Host")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct DeployBody: Encodable {
            let directory = "AttackerChain"; let parentDirectory = "Nexus"
            let targetBlockTime: UInt64 = 1000; let initialReward: UInt64 = 1000000
            let halvingInterval: UInt64 = 210000; let premine: UInt64 = 0
            let maxTransactionsPerBlock: UInt64 = 100; let maxStateGrowth: Int = 100000
            let maxBlockSize: Int = 1000000; let difficultyAdjustmentWindow: UInt64 = 120
        }
        req.httpBody = try JSONEncoder().encode(DeployBody())

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // SHOULD be 401 Unauthorized — currently returns 200 (VULNERABLE)
        XCTAssertEqual(status, 401, "deployChain must require authentication (SEC-001): got \(status), body: \(String(data: data, encoding: .utf8) ?? "")")
    }

    // MARK: - SEC-002: validateBalances overflow continue (silent skip)

    /// When netDebit accumulation overflows Int64, the validator silently skips
    /// the update via `continue`, potentially allowing a transaction to bypass
    /// the balance check for that account. The fix is to return
    /// .balanceNotConserved on overflow instead of continuing.
    func testValidateBalancesRejectsOnOverflow() async throws {
        let p = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let genesis = testGenesis()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p, storagePath: tmp, enableLocalDiscovery: false
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        defer { Task { await node.stop() } }

        // Wait for genesis to be processed
        try await Task.sleep(for: .milliseconds(200))

        let attacker = CryptoUtils.generateKeyPair()
        let attackerAddr = CryptoUtils.createAddress(from: attacker.publicKey)

        // Attacker has 0 tokens. Build a transaction where:
        // Action1: attacker delta = +Int64.max (huge credit)
        // Action2: attacker delta = +1          (another credit → overflow in accumulation)
        // Net after overflow bug: attacker netDebit stays at Int64.max (positive → not checked)
        // This bypasses the "does attacker have enough tokens" check
        // BUT validateConservation catches fee discrepancy — so the fix here is belt-and-suspenders.
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: attackerAddr, delta: Int64.max),
                AccountAction(owner: attackerAddr, delta: 1),          // overflow: silent skip BUG
                AccountAction(owner: attackerAddr, delta: -Int64.max), // debit same amount
                AccountAction(owner: attackerAddr, delta: -1)          // debit the +1
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [attackerAddr], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        guard let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: attacker.privateKey) else {
            XCTFail("Failed to sign"); return
        }
        let tx = Transaction(signatures: [attacker.publicKey: sig], body: bodyHeader)

        // This transaction should be REJECTED because attacker has 0 tokens
        let result = await node.submitTransaction(directory: "Nexus", transaction: tx)
        XCTAssertFalse(result, "Transaction from zero-balance account must be rejected (SEC-002)")
    }

    // MARK: - SEC-003: validateBalances overflow must not silently continue

    /// Direct unit test of the overflow path in validateBalances.
    /// If netDebit overflows, the validator must return an error, not continue.
    func testValidatorRejectsOverflowDelta() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let genesis = testGenesis()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        defer { Task { await node.stop() } }
        try await Task.sleep(for: .milliseconds(200))

        let attacker = CryptoUtils.generateKeyPair()
        let attackerAddr = CryptoUtils.createAddress(from: attacker.publicKey)

        // Single overflow: attacker sends themselves Int64.max tokens they don't have
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: attackerAddr, delta: -Int64.max), // debit Int64.max
                AccountAction(owner: attackerAddr, delta: Int64.max)   // cancel with credit
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [attackerAddr], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        guard let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: attacker.privateKey) else {
            XCTFail("Failed to sign"); return
        }
        let tx = Transaction(signatures: [attacker.publicKey: sig], body: bodyHeader)

        let result = await node.submitTransaction(directory: "Nexus", transaction: tx)
        // debit(Int64.max) ≠ credit(Int64.max) + fee(1) → should fail conservation
        XCTAssertFalse(result, "Self-cancel transaction with fee must be rejected (SEC-003)")
    }

    // MARK: - SEC-004: Replay attack — same transaction twice

    /// A confirmed transaction must not be re-submittable (replay attack).
    func testTransactionCannotBeReplayed() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let minerAddr = CryptoUtils.createAddress(from: kp.publicKey)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let premineAmt: UInt64 = 1_000_000
        let spec = testSpec(premine: premineAmt)
        let genesis = testGenesis(spec: spec)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false
        )
        // Custom genesis builder that sends premine to minerAddr
        let node = try await LatticeNode(config: config, genesisConfig: genesis) { gc, f in
            let amount = Int64(gc.spec.premineAmount())
            let body = TransactionBody(
                accountActions: [AccountAction(owner: minerAddr, delta: amount)],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [minerAddr], fee: 0, nonce: 0
            )
            let bh = HeaderImpl<TransactionBody>(node: body)
            let tx = Transaction(signatures: [kp.publicKey: "genesis"], body: bh)
            return try await BlockBuilder.buildGenesis(
                spec: gc.spec, transactions: [tx],
                timestamp: gc.timestamp, difficulty: gc.difficulty, fetcher: f
            )
        }
        try await node.start()
        defer { Task { await node.stop() } }
        try await mineBlocks(1, on: node)

        let balance = (try? await node.getBalance(address: minerAddr)) ?? 0
        guard balance > 0 else { XCTFail("Need balance from genesis premine, got 0"); return }

        let recipient = CryptoUtils.generateKeyPair()
        let recipientAddr = CryptoUtils.createAddress(from: recipient.publicKey)

        // Build and submit a valid transfer
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: minerAddr, delta: -11),
                AccountAction(owner: recipientAddr, delta: 10)
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [minerAddr], fee: 1, nonce: 1, chainPath: ["Nexus"]  // nonce 0 used by genesis premine
        )
        let bh = HeaderImpl<TransactionBody>(node: body)
        guard let sig = CryptoUtils.sign(message: bh.rawCID, privateKeyHex: kp.privateKey) else {
            XCTFail("sign failed"); return
        }
        let tx = Transaction(signatures: [kp.publicKey: sig], body: bh)

        let first = await node.submitTransaction(directory: "Nexus", transaction: tx)
        XCTAssertTrue(first, "First submission should succeed (SEC-004)")

        // Mine to confirm it
        try await mineBlocks(1, on: node)

        // Replay the SAME transaction
        let replay = await node.submitTransaction(directory: "Nexus", transaction: tx)
        XCTAssertFalse(replay, "Replayed transaction must be rejected (SEC-004)")
    }

    // MARK: - SEC-005: Unsigned transaction must be rejected

    /// A transaction with no signatures must never be accepted.
    func testUnsignedTransactionRejected() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let genesis = testGenesis()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        defer { Task { await node.stop() } }
        try await Task.sleep(for: .milliseconds(200))

        let addr = CryptoUtils.createAddress(from: kp.publicKey)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: addr, delta: -10)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [addr], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        // NO signature
        let tx = Transaction(signatures: [:], body: HeaderImpl<TransactionBody>(node: body))
        let result = await node.submitTransaction(directory: "Nexus", transaction: tx)
        XCTAssertFalse(result, "Transaction with no signatures must be rejected (SEC-005)")
    }

    // MARK: - SEC-006: Wrong-signer transaction rejected

    /// A transaction signed by a different key than listed in `signers` must fail.
    func testWrongSignerRejected() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let impostor = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let genesis = testGenesis()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        defer { Task { await node.stop() } }
        try await Task.sleep(for: .milliseconds(200))

        let body = TransactionBody(
            accountActions: [AccountAction(owner: addr, delta: -10)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [addr], fee: 1, nonce: 0, chainPath: ["Nexus"]
        )
        let bh = HeaderImpl<TransactionBody>(node: body)
        // Sign with IMPOSTOR key, not the listed signer
        guard let sig = CryptoUtils.sign(message: bh.rawCID, privateKeyHex: impostor.privateKey) else {
            XCTFail("sign failed"); return
        }
        let tx = Transaction(signatures: [impostor.publicKey: sig], body: bh)
        let result = await node.submitTransaction(directory: "Nexus", transaction: tx)
        XCTAssertFalse(result, "Transaction signed by wrong key must be rejected (SEC-006)")
    }

    // MARK: - SEC-007: Double-spend in same block

    /// Two transactions spending the same nonce slot cannot both be confirmed.
    func testDoubleSpendSameNonce() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: kp.publicKey)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let spec = testSpec(premine: 1_000_000)
        let genesis = testGenesis(spec: spec)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        defer { Task { await node.stop() } }
        try await mineBlocks(2, on: node)

        let r1 = CryptoUtils.generateKeyPair()
        let r2 = CryptoUtils.generateKeyPair()

        func makeTx(to recipientAddr: String) -> Transaction? {
            let body = TransactionBody(
                accountActions: [
                    AccountAction(owner: addr, delta: -11),
                    AccountAction(owner: recipientAddr, delta: 10)
                ],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [addr], fee: 1, nonce: 0, chainPath: ["Nexus"]
            )
            let bh = HeaderImpl<TransactionBody>(node: body)
            guard let sig = CryptoUtils.sign(message: bh.rawCID, privateKeyHex: kp.privateKey) else { return nil }
            return Transaction(signatures: [kp.publicKey: sig], body: bh)
        }

        guard let tx1 = makeTx(to: CryptoUtils.createAddress(from: r1.publicKey)),
              let tx2 = makeTx(to: CryptoUtils.createAddress(from: r2.publicKey)) else {
            XCTFail("Failed to build txs"); return
        }

        // Both spend nonce=0 — only one can win
        let s1 = await node.submitTransaction(directory: "Nexus", transaction: tx1)
        let s2 = await node.submitTransaction(directory: "Nexus", transaction: tx2)

        // At most one should be in mempool (RBF allows the second to replace if higher fee,
        // but same fee means first wins)
        let accepted = [s1, s2].filter { $0 }.count
        XCTAssertLessThanOrEqual(accepted, 1, "At most one of two same-nonce transactions can be accepted (SEC-007)")
    }

    // MARK: - SEC-008: Empty chainPath accepted on all chains (cross-chain replay)

    /// A transaction with chainPath: [] bypasses chain routing validation and is
    /// accepted by any chain's mempool AND included in any chain's blocks.
    /// This enables cross-chain replay: spend tokens on one chain and replay
    /// the same transaction on another chain.
    func testEmptyChainPathRejected() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let senderAddr = CryptoUtils.createAddress(from: kp.publicKey)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let spec = testSpec(premine: 1_000_000)
        let genesisConfig = testGenesis(spec: spec)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesisConfig) { gc, f in
            let body = TransactionBody(
                accountActions: [AccountAction(owner: senderAddr, delta: Int64(gc.spec.premineAmount()))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [senderAddr], fee: 0, nonce: 0
            )
            let bh = HeaderImpl<TransactionBody>(node: body)
            let tx = Transaction(signatures: [kp.publicKey: "genesis"], body: bh)
            return try await BlockBuilder.buildGenesis(
                spec: gc.spec, transactions: [tx],
                timestamp: gc.timestamp, difficulty: gc.difficulty, fetcher: f
            )
        }
        try await node.start()
        defer { Task { await node.stop() } }
        try await mineBlocks(1, on: node)

        let recipient = CryptoUtils.generateKeyPair()
        let recipientAddr = CryptoUtils.createAddress(from: recipient.publicKey)

        // Transaction with EMPTY chainPath — should be REJECTED, currently ACCEPTED
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: senderAddr, delta: -11),
                AccountAction(owner: recipientAddr, delta: 10)
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [senderAddr], fee: 1, nonce: 1,
            chainPath: []   // ← EMPTY — bypasses chain isolation
        )
        let bh = HeaderImpl<TransactionBody>(node: body)
        guard let sig = CryptoUtils.sign(message: bh.rawCID, privateKeyHex: kp.privateKey) else {
            XCTFail("sign failed"); return
        }
        let tx = Transaction(signatures: [kp.publicKey: sig], body: bh)

        let result = await node.submitTransaction(directory: "Nexus", transaction: tx)
        // SHOULD be rejected — empty chainPath must not be accepted (SEC-008)
        XCTAssertFalse(result, "Transaction with empty chainPath must be rejected (SEC-008)")
    }

    // MARK: - SEC-009: Unauthenticated startMining (adversary can redirect rewards)

    /// POST /api/mining/start accepts a foreign private key, redirecting all
    /// block rewards to the attacker's address on internet-exposed nodes.
    func testStartMiningRequiresAuth() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "0.0.0.0", allowedOrigin: "*")
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await Task.sleep(for: .milliseconds(500))

        let attacker = CryptoUtils.generateKeyPair()
        struct MineBody: Encodable {
            let chain = "Nexus"
            let publicKey: String
            let privateKey: String
        }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/mining/start")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(MineBody(publicKey: attacker.publicKey, privateKey: attacker.privateKey))
        req.addValue("external-host.example.com", forHTTPHeaderField: "Host")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 401,
            "mining/start must require auth on public bind (SEC-009): got \(status), body: \(String(data: data, encoding: .utf8) ?? "")")
    }

    // MARK: - SEC-010: Unauthenticated stopMining (griefing attack)

    /// POST /api/mining/stop lets any caller halt block production on an
    /// internet-exposed node.
    func testStopMiningRequiresAuth() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()
        defer { Task { await node.stop() } }

        let rpcPort = nextTestPort()
        let server = RPCServer(node: node, port: rpcPort, bindAddress: "0.0.0.0", allowedOrigin: "*")
        let serverTask = Task { try await server.run() }
        defer { serverTask.cancel() }
        try await Task.sleep(for: .milliseconds(500))

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/api/mining/stop")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["chain": "Nexus"])
        req.addValue("external-host.example.com", forHTTPHeaderField: "Host")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 401,
            "mining/stop must require auth on public bind (SEC-010): got \(status), body: \(String(data: data, encoding: .utf8) ?? "")")
    }
}
