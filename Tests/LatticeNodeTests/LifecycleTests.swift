import XCTest
@testable import Lattice
@testable import LatticeNode
@testable import Ivy
import UInt256
import cashew
import Acorn
import AcornDiskWorker
import ArrayTrie
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Tests that cover the full user-facing lifecycle: mine → query → restart → verify.
/// These target the exact failure modes we've encountered in production:
///   - Receipt indexing uses correct CIDs (not dict indices)
///   - Genesis block transactions are queryable
///   - Transaction detail RPC works with blockHash param
///   - Node restart preserves chain state and CAS data
///   - Graceful shutdown persists all stores
///   - Block state endpoint resolves account balances at a block

final class LifecycleTests: XCTestCase {

    // MARK: - Helpers

    /// Boot a single-node setup with RPC, mine some blocks, return all handles.
    private func bootMiningNode(
        premine: UInt64 = 0,
        blockCount: Int = 2
    ) async throws -> (node: LatticeNode, rpcPort: UInt16, rpcTask: Task<Void, any Error>, kp: (privateKey: String, publicKey: String), tmpDir: URL) {
        let p1 = nextTestPort()
        let rpcPort = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let spec = testSpec(premine: premine)
        let genesis = testGenesis(spec: spec)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p1, storagePath: tmpDir.appendingPathComponent("node1"),
            enableLocalDiscovery: false,
            persistInterval: 5
        )

        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()

        if blockCount > 0 {
            try await mineBlocks(blockCount, on: node)
        }

        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*")
        let rpcTask = Task { try await server.run() }
        try await Task.sleep(for: .milliseconds(500))

        return (node, rpcPort, rpcTask, kp, tmpDir)
    }

    private func rpcGet(_ baseURL: String, _ path: String) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(from: URL(string: "\(baseURL)\(path)")!)
        let http = resp as? HTTPURLResponse
        XCTAssertEqual(http?.statusCode, 200, "GET \(path) returned \(http?.statusCode ?? 0)")
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func rpcGetRaw(_ baseURL: String, _ path: String) async throws -> (Data, Int) {
        let (data, resp) = try await URLSession.shared.data(from: URL(string: "\(baseURL)\(path)")!)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    private func rpcPost(_ baseURL: String, _ path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func rpcPostRaw(_ baseURL: String, _ path: String, body: [String: Any]) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    // MARK: - Receipt Indexing by CID (not dict key)

    /// Mine blocks, then verify receipts are indexed by transaction rawCID,
    /// not by the dictionary index ("0", "1", ...).
    func testReceiptIndexByTransactionCID() async throws {
        let env = try await bootMiningNode()
        defer { env.rpcTask.cancel(); Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }

        let base = "http://127.0.0.1:\(env.rpcPort)/api"
        let latest = try await rpcGet(base, "/block/latest")
        let height = latest["index"] as? Int ?? 0
        XCTAssertGreaterThan(height, 0, "Should have mined at least 1 block")

        // Walk backwards to find a block with transactions
        for h in stride(from: height, through: 0, by: -1) {
            let blk = try await rpcGet(base, "/block/\(h)")
            let txCount = blk["transactionCount"] as? Int ?? 0
            guard txCount > 0 else { continue }

            let blockHash = blk["hash"] as? String ?? ""
            let txResp = try await rpcGet(base, "/block/\(blockHash)/transactions")
            let txs = txResp["transactions"] as? [[String: Any]] ?? []
            guard let firstTx = txs.first, let txCID = firstTx["txCID"] as? String else { continue }

            // This is the critical test: look up the transaction by its CID via receipt
            let (receiptData, receiptStatus) = try await rpcGetRaw(base, "/receipt/\(txCID)")
            if receiptStatus == 200 {
                let receipt = try JSONSerialization.jsonObject(with: receiptData) as? [String: Any]
                XCTAssertEqual(receipt?["txCID"] as? String, txCID, "Receipt txCID should match query")
            }

            // Also verify transaction detail endpoint (with blockHash fallback)
            let txDetail = try await rpcGet(base, "/transaction/\(txCID)?blockHash=\(blockHash)")
            XCTAssertEqual(txDetail["txCID"] as? String, txCID)
            XCTAssertEqual(txDetail["blockHash"] as? String, blockHash)
            XCTAssertNotNil(txDetail["signers"])
            return
        }
        XCTFail("No blocks with transactions found after mining")
    }

    // MARK: - Genesis Block Transactions

    /// The genesis block (with premine) should have a resolvable transaction
    /// via the /transaction endpoint using the blockHash param.
    func testGenesisBlockTransactionResolvable() async throws {
        let p1 = nextTestPort()
        let rpcPort = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let minerAddr = addr(kp.publicKey)
        let spec = testSpec(premine: 100)
        let genesis = testGenesis(spec: spec)

        // Use a custom genesis builder that includes a premine transaction
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p1, storagePath: tmpDir.appendingPathComponent("node1"),
            enableLocalDiscovery: false
        )
        let node = try await LatticeNode(
            config: config, genesisConfig: genesis
        ) { genesisConfig, fetcher in
            let premineAmount = Int64(genesisConfig.spec.premineAmount())
            let body = TransactionBody(
                accountActions: [AccountAction(owner: minerAddr, delta: premineAmount)],
                actions: [], depositActions: [], genesisActions: [], peerActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [minerAddr], fee: 0, nonce: 0
            )
            let bodyHeader = HeaderImpl<TransactionBody>(node: body)
            let sig = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: kp.privateKey)!
            let tx = Transaction(signatures: [kp.publicKey: sig], body: bodyHeader)
            return try await BlockBuilder.buildGenesis(
                spec: genesisConfig.spec, transactions: [tx],
                timestamp: genesisConfig.timestamp, difficulty: genesisConfig.difficulty,
                fetcher: fetcher
            )
        }
        try await node.start()

        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*")
        let rpcTask = Task { try await server.run() }
        defer { rpcTask.cancel(); Task { await node.stop() } }
        try await Task.sleep(for: .milliseconds(500))

        let base = "http://127.0.0.1:\(rpcPort)/api"

        // Get genesis block (height 0)
        let genesisBlock = try await rpcGet(base, "/block/0")
        let genesisHash = genesisBlock["hash"] as? String ?? ""
        let txCount = genesisBlock["transactionCount"] as? Int ?? 0
        XCTAssertGreaterThan(txCount, 0, "Genesis with premine tx should have transactions")

        // Get the transaction CIDs from genesis
        let txResp = try await rpcGet(base, "/block/\(genesisHash)/transactions")
        let txs = txResp["transactions"] as? [[String: Any]] ?? []
        XCTAssertFalse(txs.isEmpty, "Genesis should list transactions")

        let txCID = txs[0]["txCID"] as? String ?? ""
        XCTAssertFalse(txCID.isEmpty)

        // Look up transaction detail — this requires blockHash since genesis has no receipt index
        let txDetail = try await rpcGet(base, "/transaction/\(txCID)?blockHash=\(genesisHash)")
        XCTAssertEqual(txDetail["txCID"] as? String, txCID)
        XCTAssertEqual(txDetail["blockHeight"] as? Int, 0)

        // Verify the premine account action is present
        let actions = txDetail["accountActions"] as? [[String: Any]] ?? []
        XCTAssertFalse(actions.isEmpty, "Genesis premine should have account actions")
        let delta = actions[0]["delta"] as? Int ?? 0
        XCTAssertGreaterThan(delta, 0, "Premine should credit tokens")
    }

    // MARK: - Block State Endpoint

    /// Verify we can look up account balances at a specific block height.
    func testBlockStateAccountLookup() async throws {
        let env = try await bootMiningNode(premine: 100)
        defer { env.rpcTask.cancel(); Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }

        let base = "http://127.0.0.1:\(env.rpcPort)/api"
        let minerAddr = addr(env.kp.publicKey)

        // Get latest block
        let latest = try await rpcGet(base, "/block/latest")
        let latestHash = latest["hash"] as? String ?? ""
        let height = latest["index"] as? Int ?? 0
        XCTAssertGreaterThan(height, 0)

        // Query block state overview
        let state = try await rpcGet(base, "/block/\(latestHash)/state")
        let sections = state["sections"] as? [[String: Any]] ?? []
        XCTAssertFalse(sections.isEmpty, "Block state should have sections")
        let sectionNames = sections.compactMap { $0["name"] as? String }
        XCTAssertTrue(sectionNames.contains("accountState"))

        // Look up miner balance at latest block
        let acct = try await rpcGet(base, "/block/\(latestHash)/state/account/\(minerAddr)")
        let balance = acct["balance"] as? Int ?? 0
        XCTAssertGreaterThan(balance, 0, "Miner should have balance from mining rewards")
        XCTAssertEqual(acct["blockHeight"] as? Int, height)

        // Balance at genesis should be 0 for the miner (premine goes to a different address)
        let genesisAcct = try await rpcGet(base, "/block/0/state/account/\(minerAddr)")
        let genesisBalance = genesisAcct["balance"] as? Int ?? 0
        XCTAssertEqual(genesisBalance, 0, "Miner should have 0 balance at genesis")
    }

    // MARK: - Restart Preserves State

    /// Mine blocks → stop (triggers persistence) → boot new node from same storage → verify tip.
    func testRestartPreservesChainState() async throws {
        let p1 = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let genesis = testGenesis()
        let storagePath = tmpDir.appendingPathComponent("node1")

        // --- First run: mine some blocks ---
        let config1 = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p1, storagePath: storagePath,
            enableLocalDiscovery: false,
            persistInterval: 1  // persist every block
        )
        let node1 = try await LatticeNode(config: config1, genesisConfig: genesis)
        try await node1.start()
        try await mineBlocks(2, on: node1)

        let heightBefore = await node1.lattice.nexus.chain.getHighestBlockIndex()
        let tipBefore = await node1.lattice.nexus.chain.getMainChainTip()
        XCTAssertGreaterThan(heightBefore, 0, "Should have mined blocks")

        // Graceful stop — triggers persistChainState + persistDiskState
        await node1.stop()

        // Verify persistence artifacts exist
        let chainStateFile = storagePath.appendingPathComponent("Nexus/chain_state.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chainStateFile.path), "chain_state.json should be written on stop")

        // --- Second run: boot from persisted state ---
        let p2 = nextTestPort()
        let config2 = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p2, storagePath: storagePath,
            enableLocalDiscovery: false,
            persistInterval: 1
        )
        let node2 = try await LatticeNode(config: config2, genesisConfig: genesis)
        try await node2.start()

        let heightAfter = await node2.lattice.nexus.chain.getHighestBlockIndex()
        let tipAfter = await node2.lattice.nexus.chain.getMainChainTip()

        XCTAssertEqual(heightAfter, heightBefore, "Height should survive restart")
        XCTAssertEqual(tipAfter, tipBefore, "Tip should survive restart")

        // Verify the tip block is fetchable from CAS
        let network = await node2.network(for: "Nexus")!
        let tipData = try await network.fetcher.fetch(rawCid: tipBefore)
        XCTAssertNotNil(tipData, "Tip block data should be in CAS after restart")

        await node2.stop()
    }

    // MARK: - DiskCASWorker Restart Scan

    /// Write CIDv1 files to disk, restart DiskCASWorker, verify they're found by bloom filter.
    func testDiskCASWorkerScansFindsCIDv1Files() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fs = DefaultFileSystem()

        // First worker: store some data
        let worker1 = try DiskCASWorker(directory: tmpDir, capacity: 1000, fileSystem: fs)
        let testData = "hello world".data(using: .utf8)!
        let cid = ContentIdentifier(for: testData)
        await worker1.storeLocal(cid: cid, data: testData)
        let hasBeforePersist = await worker1.has(cid: cid)
        XCTAssertTrue(hasBeforePersist, "Should find data in first worker")

        // Do NOT persist .bloom/.sizes — simulating ungraceful shutdown

        // Second worker: boot from same directory, relies on scan
        let worker2 = try DiskCASWorker(directory: tmpDir, capacity: 1000, fileSystem: fs)
        let hasAfterRestart = await worker2.has(cid: cid)
        XCTAssertTrue(hasAfterRestart, "Scan should find CIDv1 file after restart without .bloom/.sizes")

        let retrieved = await worker2.getLocal(cid: cid)
        XCTAssertEqual(retrieved, testData, "Data should be readable after restart")
    }

    // MARK: - DiskCASWorker Persist/Restore

    /// Persist .bloom/.sizes, restart, verify fast path loads correctly.
    func testDiskCASWorkerPersistAndRestore() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fs = DefaultFileSystem()

        let worker1 = try DiskCASWorker(directory: tmpDir, capacity: 1000, fileSystem: fs)
        let testData = "persist test".data(using: .utf8)!
        let cid = ContentIdentifier(for: testData)
        await worker1.storeLocal(cid: cid, data: testData)

        // Persist state (simulating graceful shutdown)
        try await worker1.persistState()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent(".bloom").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent(".sizes").path))

        // Restart — should use fast path (load .bloom/.sizes)
        let worker2 = try DiskCASWorker(directory: tmpDir, capacity: 1000, fileSystem: fs)
        let has = await worker2.has(cid: cid)
        XCTAssertTrue(has, "Should find data via persisted bloom filter")

        let retrieved = await worker2.getLocal(cid: cid)
        XCTAssertEqual(retrieved, testData)

        let bytes = await worker2.totalBytes
        XCTAssertGreaterThan(bytes, 0, "totalBytes should be restored from .sizes")
    }

    // MARK: - Block Transaction Dict Keys vs CIDs

    /// Directly verify that receipt indexing uses rawCID, not the dict key,
    /// by building a block with known transactions and checking the receipt store.
    func testReceiptIndexUsesRawCIDNotDictKey() async throws {
        let f = cas()
        let kp = CryptoUtils.generateKeyPair()
        let spec = testSpec(premine: 1_000_000)
        let minerAddr = addr(kp.publicKey)

        // Build genesis with premine so there's a balance to spend
        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: 1_000_000)],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [minerAddr], fee: 0, nonce: 0
        )
        let premineBodyHeader = HeaderImpl<TransactionBody>(node: premineBody)
        let premineSignature = CryptoUtils.sign(message: premineBodyHeader.rawCID, privateKeyHex: kp.privateKey)!
        let premineTransaction = Transaction(signatures: [kp.publicKey: premineSignature], body: premineBodyHeader)
        let genesisBlock = try await BlockBuilder.buildGenesis(
            spec: spec, transactions: [premineTransaction],
            timestamp: now() - 10_000, difficulty: UInt256.max, fetcher: f
        )
        let genesisVolume = VolumeImpl<Block>(node: genesisBlock)

        // Store genesis
        let storer = BufferedStorer()
        try genesisVolume.storeRecursively(storer: storer)
        await storer.flush(to: f)

        // Build block 1 with a transfer transaction
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: minerAddr, delta: -100),
                AccountAction(owner: "recipient_address", delta: 100),
            ],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [minerAddr], fee: 0, nonce: 1
        )
        let tx = sign(body, kp)
        let txHeader = VolumeImpl<Transaction>(node: tx)
        let txCID = txHeader.rawCID  // This is what the frontend sees

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesisBlock, transactions: [tx],
            timestamp: now(), difficulty: UInt256.max, nonce: 1, fetcher: f
        )

        // Store block 1
        let storer2 = BufferedStorer()
        try VolumeImpl<Block>(node: block1).storeRecursively(storer: storer2)
        await storer2.flush(to: f)

        // Verify the transaction dict key is NOT the CID
        let txDict = try await block1.transactions.resolveRecursive(fetcher: f).node!
        let entries = try txDict.allKeysAndValues()
        XCTAssertEqual(entries.count, 1)
        let (dictKey, dictValue) = entries.first!
        XCTAssertEqual(dictKey, "0", "BlockBuilder uses sequential index as dict key")
        XCTAssertEqual(dictValue.rawCID, txCID, "rawCID should be the transaction's content address")
        XCTAssertNotEqual(dictKey, txCID, "Dict key should NOT equal txCID")

        // Now simulate receipt indexing (what applyAcceptedBlock does)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = try StateStore(storagePath: tmpDir, chain: "Nexus")
        let receiptStore = TransactionReceiptStore(store: store, fetcher: f)

        // Index using rawCID (the fix) — not the dict key
        await receiptStore.indexReceipt(
            txCID: dictValue.rawCID,
            blockHash: VolumeImpl<Block>(node: block1).rawCID,
            blockHeight: 1
        )

        // Look up by rawCID — this is what the frontend sends
        let receipt = await receiptStore.getReceipt(txCID: txCID)
        XCTAssertNotNil(receipt, "Receipt should be findable by rawCID")
        XCTAssertEqual(receipt?.blockHeight, 1)

        // Look up by dict key "0" should NOT find anything (old buggy behavior)
        let wrongReceipt = await receiptStore.getReceipt(txCID: "0")
        XCTAssertNil(wrongReceipt, "Receipt should NOT be indexed by dict key")
    }

    // MARK: - Miner Tip Resolution After Restart

    /// Mine blocks → stop → restart → mine more blocks.
    /// This catches the notFound bug: if the tip block data is missing from CAS
    /// after restart, the miner can't resolve the current tip and fails.
    func testMinerWorksAfterRestart() async throws {
        let p1 = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let genesis = testGenesis()
        let storagePath = tmpDir.appendingPathComponent("node1")

        // First run
        let config1 = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p1, storagePath: storagePath,
            enableLocalDiscovery: false, persistInterval: 1
        )
        let node1 = try await LatticeNode(config: config1, genesisConfig: genesis)
        try await node1.start()
        try await mineBlocks(2, on: node1)
        let heightAfterFirstRun = await node1.lattice.nexus.chain.getHighestBlockIndex()
        XCTAssertGreaterThan(heightAfterFirstRun, 0)
        await node1.stop()

        // Second run — verify restart preserves state
        let p2 = nextTestPort()
        let config2 = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p2, storagePath: storagePath,
            enableLocalDiscovery: false, persistInterval: 1
        )
        let node2 = try await LatticeNode(config: config2, genesisConfig: genesis)
        try await node2.start()

        let heightOnBoot = await node2.lattice.nexus.chain.getHighestBlockIndex()
        XCTAssertEqual(heightOnBoot, heightAfterFirstRun)

        // Verify the tip block is resolvable from CAS — this is the core of the notFound bug.
        // If the tip can't be fetched, the miner would fail with notFound.
        let tipCID = await node2.lattice.nexus.chain.getMainChainTip()
        let network2 = await node2.network(for: "Nexus")!
        let tipData = try await network2.fetcher.fetch(rawCid: tipCID)
        XCTAssertNotNil(tipData, "Tip block must be fetchable from CAS after restart — miner depends on this")
        let tipBlock = Block(data: tipData)
        XCTAssertNotNil(tipBlock, "Tip data should deserialize into a Block")

        await node2.stop()
    }

    // MARK: - Chain Info, Spec, Health, Metrics

    /// Verify chain info, chain spec, health, and metrics endpoints return expected data
    /// without any mining required.
    func testChainInfoSpecHealthMetrics() async throws {
        let env = try await bootMiningNode(blockCount: 0)
        defer { env.rpcTask.cancel(); Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }

        let base = "http://127.0.0.1:\(env.rpcPort)"

        // --- /api/chain/info ---
        let info = try await rpcGet(base, "/api/chain/info")
        let chains = info["chains"] as? [[String: Any]] ?? []
        XCTAssertFalse(chains.isEmpty, "Should have at least one chain")
        let nexusChain = chains.first { ($0["directory"] as? String) == "Nexus" }
        XCTAssertNotNil(nexusChain, "Nexus chain should be present")
        XCTAssertNotNil(info["genesisHash"] as? String)
        XCTAssertEqual(info["nexus"] as? String, "Nexus")

        // --- /api/chain/spec ---
        let spec = try await rpcGet(base, "/api/chain/spec")
        XCTAssertEqual(spec["directory"] as? String, "Nexus")
        XCTAssertEqual(spec["initialReward"] as? Int, 1024)
        XCTAssertEqual(spec["halvingInterval"] as? Int, 10_000)
        XCTAssertGreaterThan(spec["maxTransactionsPerBlock"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(spec["maxBlockSize"] as? Int ?? 0, 0)
        XCTAssertEqual(spec["targetBlockTime"] as? Int, 1000)

        // --- /health ---
        let health = try await rpcGet(base, "/health")
        XCTAssertNotNil(health["status"] as? String)
        XCTAssertNotNil(health["chainHeight"])
        XCTAssertNotNil(health["peerCount"])
        XCTAssertNotNil(health["uptimeSeconds"])
        XCTAssertEqual(health["chains"] as? Int, 1)

        // --- /metrics ---
        let (metricsData, metricsStatus) = try await rpcGetRaw(base, "/metrics")
        XCTAssertEqual(metricsStatus, 200)
        let metricsText = String(data: metricsData, encoding: .utf8) ?? ""
        XCTAssertTrue(metricsText.contains("lattice_chain_height"), "Metrics should include chain height gauge")
    }

    // MARK: - Block Explorer Browsing

    /// Mine blocks, then browse: latest → by height → by hash → transactions → children.
    func testBlockExplorerBrowsing() async throws {
        let env = try await bootMiningNode()
        defer { env.rpcTask.cancel(); Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }

        let base = "http://127.0.0.1:\(env.rpcPort)/api"

        // --- GET /block/latest ---
        let latest = try await rpcGet(base, "/block/latest")
        let height = latest["index"] as? Int ?? 0
        let tip = latest["hash"] as? String ?? ""
        XCTAssertGreaterThan(height, 0)
        XCTAssertFalse(tip.isEmpty)
        XCTAssertEqual(latest["chain"] as? String, "Nexus")

        // --- GET /block/{height} (by numeric index) ---
        let block1 = try await rpcGet(base, "/block/1")
        XCTAssertEqual(block1["index"] as? Int, 1)
        let block1Hash = block1["hash"] as? String ?? ""
        XCTAssertFalse(block1Hash.isEmpty)
        XCTAssertNotNil(block1["previousBlock"] as? String, "Block 1 should have previous block (genesis)")
        XCTAssertNotNil(block1["difficulty"] as? String)
        XCTAssertNotNil(block1["nonce"])
        XCTAssertEqual(block1["version"] as? Int, 1)
        XCTAssertNotNil(block1["transactionsCID"] as? String)
        XCTAssertNotNil(block1["homesteadCID"] as? String)
        XCTAssertNotNil(block1["frontierCID"] as? String)

        // --- GET /block/{hash} (by hash) ---
        let blockByHash = try await rpcGet(base, "/block/\(block1Hash)")
        XCTAssertEqual(blockByHash["hash"] as? String, block1Hash)
        XCTAssertEqual(blockByHash["index"] as? Int, 1)

        // --- GET /block/{id}/transactions ---
        let txResp = try await rpcGet(base, "/block/\(block1Hash)/transactions")
        let txs = txResp["transactions"] as? [[String: Any]] ?? []
        XCTAssertGreaterThan(txResp["count"] as? Int ?? 0, 0, "Mined block should have coinbase tx")
        let coinbase = txs[0]
        XCTAssertNotNil(coinbase["txCID"] as? String)
        XCTAssertNotNil(coinbase["bodyCID"] as? String)
        XCTAssertNotNil(coinbase["signers"] as? [String])
        XCTAssertEqual(coinbase["fee"] as? Int, 0, "Coinbase tx has fee 0")
        XCTAssertGreaterThanOrEqual(coinbase["accountActionCount"] as? Int ?? 0, 1, "Coinbase should have account action")

        // --- GET /block/{id}/children ---
        let children = try await rpcGet(base, "/block/\(block1Hash)/children")
        XCTAssertEqual(children["count"] as? Int, 0, "Single-chain node has no child blocks")

        // --- GET /block/0 (genesis) ---
        let genesis = try await rpcGet(base, "/block/0")
        XCTAssertEqual(genesis["index"] as? Int, 0)
        XCTAssertNil(genesis["previousBlock"], "Genesis has no previous block")
    }

    // MARK: - Account Data Access

    /// Verify balance, nonce, account state, and transaction history endpoints.
    func testAccountDataAccess() async throws {
        let env = try await bootMiningNode()
        defer { env.rpcTask.cancel(); Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }

        let base = "http://127.0.0.1:\(env.rpcPort)/api"
        let minerAddr = addr(env.kp.publicKey)

        // --- GET /balance/{address} ---
        let bal = try await rpcGet(base, "/balance/\(minerAddr)")
        XCTAssertEqual(bal["address"] as? String, minerAddr)
        let balance = bal["balance"] as? Int ?? 0
        XCTAssertGreaterThan(balance, 0, "Miner should have mining rewards")

        // --- GET /nonce/{address} ---
        let nonceResp = try await rpcGet(base, "/nonce/\(minerAddr)")
        XCTAssertEqual(nonceResp["address"] as? String, minerAddr)
        let nonce = nonceResp["nonce"] as? Int ?? -1
        // Nonce reflects all transactions from this sender, including fee-0 coinbase txs
        XCTAssertGreaterThan(nonce, 0, "Miner nonce should reflect coinbase transactions")

        // --- GET /state/account/{address} ---
        let acctState = try await rpcGet(base, "/state/account/\(minerAddr)")
        XCTAssertEqual(acctState["address"] as? String, minerAddr)
        XCTAssertEqual(acctState["chain"] as? String, "Nexus")
        XCTAssertEqual(acctState["balance"] as? Int, balance, "Account state balance should match /balance endpoint")
        XCTAssertEqual(acctState["nonce"] as? Int, nonce, "Account state nonce should match /nonce endpoint")
        XCTAssertTrue(acctState["exists"] as? Bool ?? false)
        let recentTxs = acctState["recentTransactions"] as? [[String: Any]] ?? []
        XCTAssertFalse(recentTxs.isEmpty, "Miner should have transaction history from coinbase")
        XCTAssertGreaterThan(acctState["transactionCount"] as? Int ?? 0, 0)

        // --- GET /transactions/{address} ---
        let history = try await rpcGet(base, "/transactions/\(minerAddr)")
        XCTAssertEqual(history["address"] as? String, minerAddr)
        let historyTxs = history["transactions"] as? [[String: Any]] ?? []
        XCTAssertFalse(historyTxs.isEmpty)
        XCTAssertEqual(history["count"] as? Int, historyTxs.count)
        let firstHistoryTx = historyTxs[0]
        XCTAssertNotNil(firstHistoryTx["txCID"] as? String)
        XCTAssertNotNil(firstHistoryTx["blockHash"] as? String)
        XCTAssertNotNil(firstHistoryTx["height"])

        // --- Unknown address should return zero balance ---
        let unknownBal = try await rpcGet(base, "/balance/unknown_address_123")
        XCTAssertEqual(unknownBal["balance"] as? Int, 0)

        // --- GET /state/account for unknown address ---
        let unknownAcct = try await rpcGet(base, "/state/account/unknown_address_123")
        XCTAssertFalse(unknownAcct["exists"] as? Bool ?? true, "Unknown account should not exist")
        XCTAssertEqual(unknownAcct["balance"] as? Int, 0)

        // --- GET /state/summary ---
        let summary = try await rpcGet(base, "/state/summary")
        XCTAssertEqual(summary["chain"] as? String, "Nexus")
        XCTAssertGreaterThan(summary["height"] as? Int ?? 0, 0)
        XCTAssertFalse((summary["tip"] as? String ?? "").isEmpty)
        XCTAssertFalse((summary["stateRoot"] as? String ?? "").isEmpty)
    }

    // MARK: - Transaction Lifecycle

    /// Full end-to-end: prepare → sign → submit → mempool → mine → receipt → detail → history.
    func testTransactionLifecycle() async throws {
        // Mine first to get miner balance, stop, submit tx with correct nonce, mine again.
        // Nonce management: coinbase and user txs share a nonce space per signer. After
        // mining H blocks, coinbase nonces were 0..H-1. The next block's coinbase will use
        // nonce H. Our user tx must use nonce H+1 so they form a contiguous sequence.
        let p1 = nextTestPort()
        let rpcPort = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let minerAddr = addr(kp.publicKey)

        let spec = testSpec()
        let genesis = testGenesis(spec: spec)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p1, storagePath: tmpDir.appendingPathComponent("node1"),
            enableLocalDiscovery: false, persistInterval: 5
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()

        // Mine a few blocks to build up miner balance
        try await mineBlocks(2, on: node)

        let height = await node.lattice.nexus.chain.getHighestBlockIndex()
        XCTAssertGreaterThan(height, 0, "Need mined blocks for balance")

        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*")
        let rpcTask = Task { try await server.run() }
        defer { rpcTask.cancel(); Task { await node.stop(); try? FileManager.default.removeItem(at: tmpDir) } }
        try await Task.sleep(for: .milliseconds(500))

        let base = "http://127.0.0.1:\(rpcPort)/api"
        let recipientKp = CryptoUtils.generateKeyPair()
        let recipientAddr = addr(recipientKp.publicKey)

        // After mining H blocks, the miner's TransactionState nonce is H-1
        // (coinbase nonces 0..H-1 for blocks 1..H). The next available nonce is H.
        let userTxNonce = Int(height)

        // --- POST /transaction/prepare ---
        let prepareBody: [String: Any] = [
            "nonce": userTxNonce,
            "signers": [minerAddr],
            "fee": 1,
            "accountActions": [
                ["owner": minerAddr, "delta": -101],
                ["owner": recipientAddr, "delta": 100],
            ],
        ]
        let prepared = try await rpcPost(base, "/transaction/prepare", body: prepareBody)
        let bodyCID = prepared["bodyCID"] as? String ?? ""
        let bodyData = prepared["bodyData"] as? String ?? ""
        XCTAssertFalse(bodyCID.isEmpty, "Prepare should return bodyCID")
        XCTAssertFalse(bodyData.isEmpty, "Prepare should return bodyData hex")

        // --- Sign and submit ---
        let sig = CryptoUtils.sign(message: bodyCID, privateKeyHex: kp.privateKey)!
        let submitBody: [String: Any] = [
            "signatures": [kp.publicKey: sig],
            "bodyCID": bodyCID,
            "bodyData": bodyData,
        ]
        let submitResp = try await rpcPost(base, "/transaction", body: submitBody)
        XCTAssertTrue(submitResp["accepted"] as? Bool ?? false, "Transaction should be accepted")

        // --- GET /mempool — tx should be pending ---
        let mempoolBefore = try await rpcGet(base, "/mempool")
        XCTAssertGreaterThan(mempoolBefore["count"] as? Int ?? 0, 0, "Mempool should have our tx")

        // Now mine to include the tx.
        try await mineBlocks(1, on: node)

        let heightAfterTx = await node.lattice.nexus.chain.getHighestBlockIndex()
        XCTAssertGreaterThan(heightAfterTx, height, "Should have mined new blocks after tx submit")

        // Find the txCID by scanning new blocks for our bodyCID.
        // Submit returns bodyCID, but receipts/blocks index by the full
        // transaction CID (VolumeImpl<Transaction>.rawCID).
        var txCID: String?
        var txBlockHash: String?
        for h in stride(from: Int(heightAfterTx), through: 1, by: -1) {
            let blk = try await rpcGet(base, "/block/\(h)")
            let blockHash = blk["hash"] as? String ?? ""
            let txResp = try await rpcGet(base, "/block/\(blockHash)/transactions")
            let txs = txResp["transactions"] as? [[String: Any]] ?? []
            for tx in txs {
                if (tx["bodyCID"] as? String) == bodyCID {
                    txCID = tx["txCID"] as? String
                    txBlockHash = blockHash
                    break
                }
            }
            if txCID != nil { break }
        }
        XCTAssertNotNil(txCID, "Should find our transaction in a mined block")
        guard let txCID, let txBlockHash else { return }

        // --- GET /receipt/{txCID} ---
        let receipt = try await rpcGet(base, "/receipt/\(txCID)")
        XCTAssertEqual(receipt["txCID"] as? String, txCID)
        XCTAssertEqual(receipt["blockHash"] as? String, txBlockHash)
        XCTAssertEqual(receipt["status"] as? String, "confirmed")
        XCTAssertEqual(receipt["fee"] as? Int, 1)
        let receiptActions = receipt["accountActions"] as? [[String: Any]] ?? []
        XCTAssertEqual(receiptActions.count, 2, "Transfer has 2 account actions")

        // --- GET /transaction/{txCID} (via receipt index) ---
        let txDetail = try await rpcGet(base, "/transaction/\(txCID)")
        XCTAssertEqual(txDetail["txCID"] as? String, txCID)
        XCTAssertEqual(txDetail["fee"] as? Int, 1)
        XCTAssertEqual(txDetail["nonce"] as? Int, userTxNonce)
        let signers = txDetail["signers"] as? [String] ?? []
        XCTAssertTrue(signers.contains(minerAddr))
        let txActions = txDetail["accountActions"] as? [[String: Any]] ?? []
        XCTAssertEqual(txActions.count, 2)
        let detailSigs = txDetail["signatures"] as? [String: String] ?? [:]
        XCTAssertEqual(detailSigs[kp.publicKey], sig)
        XCTAssertEqual(txDetail["chain"] as? String, "Nexus")

        // --- Verify recipient balance ---
        let recipientBal = try await rpcGet(base, "/balance/\(recipientAddr)")
        XCTAssertEqual(recipientBal["balance"] as? Int, 100, "Recipient should have 100")

        // --- GET /mempool — should be empty ---
        let mempoolAfter = try await rpcGet(base, "/mempool")
        XCTAssertEqual(mempoolAfter["count"] as? Int, 0, "Mempool should be empty after mining")

        // --- Transaction history for both parties ---
        let senderHistory = try await rpcGet(base, "/transactions/\(minerAddr)")
        let senderTxs = senderHistory["transactions"] as? [[String: Any]] ?? []
        let senderTxCIDs = senderTxs.compactMap { $0["txCID"] as? String }
        XCTAssertTrue(senderTxCIDs.contains(txCID), "Sender history should include the transfer")

        let recipientHistory = try await rpcGet(base, "/transactions/\(recipientAddr)")
        let recipientTxs = recipientHistory["transactions"] as? [[String: Any]] ?? []
        let recipientTxCIDs = recipientTxs.compactMap { $0["txCID"] as? String }
        XCTAssertTrue(recipientTxCIDs.contains(txCID), "Recipient history should include the transfer")
    }

    // MARK: - Fee Estimation and Finality

    /// Verify fee estimate, fee histogram, finality, and finality config.
    func testFeeEstimationAndFinality() async throws {
        let env = try await bootMiningNode()
        defer { env.rpcTask.cancel(); Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }

        let base = "http://127.0.0.1:\(env.rpcPort)/api"

        // --- GET /fee/estimate ---
        let estimate = try await rpcGet(base, "/fee/estimate")
        XCTAssertNotNil(estimate["fee"])
        XCTAssertEqual(estimate["target"] as? Int, 5, "Default target should be 5")
        XCTAssertEqual(estimate["chain"] as? String, "Nexus")

        // --- GET /fee/estimate?target=1 ---
        let fastEstimate = try await rpcGet(base, "/fee/estimate?target=1")
        XCTAssertEqual(fastEstimate["target"] as? Int, 1)

        // --- GET /fee/histogram ---
        let histogram = try await rpcGet(base, "/fee/histogram")
        XCTAssertNotNil(histogram["buckets"] as? [[String: Any]])
        XCTAssertNotNil(histogram["blockCount"])
        XCTAssertEqual(histogram["chain"] as? String, "Nexus")

        // --- GET /finality/{height} ---
        let latest = try await rpcGet(base, "/block/latest")
        let height = latest["index"] as? Int ?? 0

        let finality = try await rpcGet(base, "/finality/\(height)")
        XCTAssertEqual(finality["height"] as? Int, height)
        XCTAssertEqual(finality["currentHeight"] as? Int, height)
        XCTAssertEqual(finality["confirmations"] as? Int, 0, "Latest block has 0 confirmations")
        XCTAssertFalse(finality["isFinal"] as? Bool ?? true, "Latest block should not be final yet")
        XCTAssertGreaterThan(finality["required"] as? Int ?? 0, 0, "Required confirmations should be > 0")
        XCTAssertEqual(finality["chain"] as? String, "Nexus")

        // Block 0 (genesis) should be final if enough blocks mined
        if height > 0 {
            let genesisFinality = try await rpcGet(base, "/finality/0")
            XCTAssertEqual(genesisFinality["confirmations"] as? Int, height)
        }

        // --- GET /finality/config ---
        let finalityConfig = try await rpcGet(base, "/finality/config")
        let chainConfigs = finalityConfig["chains"] as? [[String: Any]] ?? []
        XCTAssertFalse(chainConfigs.isEmpty)
        let nexusConfig = chainConfigs.first { ($0["chain"] as? String) == "Nexus" }
        XCTAssertNotNil(nexusConfig)
        XCTAssertNotNil(nexusConfig?["confirmations"])
        XCTAssertNotNil(finalityConfig["defaultConfirmations"])
    }

    // MARK: - Mining Control via RPC

    /// Start and stop mining via the RPC endpoints, verify chain/info reflects state.
    func testMiningControlViaRPC() async throws {
        let env = try await bootMiningNode(blockCount: 0)
        defer { env.rpcTask.cancel(); Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }

        let base = "http://127.0.0.1:\(env.rpcPort)"

        // Initially not mining
        let info1 = try await rpcGet(base, "/api/chain/info")
        let chains1 = info1["chains"] as? [[String: Any]] ?? []
        let nexus1 = chains1.first { ($0["directory"] as? String) == "Nexus" }
        XCTAssertEqual(nexus1?["mining"] as? Bool, false, "Should not be mining initially")

        // --- POST /mining/start ---
        let startResp = try await rpcPost(base, "/api/mining/start", body: ["chain": "Nexus"])
        XCTAssertTrue(startResp["started"] as? Bool ?? false)

        // Verify mining is active
        let info2 = try await rpcGet(base, "/api/chain/info")
        let chains2 = info2["chains"] as? [[String: Any]] ?? []
        let nexus2 = chains2.first { ($0["directory"] as? String) == "Nexus" }
        XCTAssertEqual(nexus2?["mining"] as? Bool, true, "Should be mining after start")

        // Wait for at least one block to be mined
        while await env.node.lattice.nexus.chain.getHighestBlockIndex() < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }

        let info3 = try await rpcGet(base, "/api/chain/info")
        let chains3 = info3["chains"] as? [[String: Any]] ?? []
        let nexus3 = chains3.first { ($0["directory"] as? String) == "Nexus" }
        XCTAssertGreaterThan(nexus3?["height"] as? Int ?? 0, 0, "Should have mined blocks")

        // --- POST /mining/stop ---
        let stopResp = try await rpcPost(base, "/api/mining/stop", body: ["chain": "Nexus"])
        XCTAssertTrue(stopResp["stopped"] as? Bool ?? false)

        let info4 = try await rpcGet(base, "/api/chain/info")
        let chains4 = info4["chains"] as? [[String: Any]] ?? []
        let nexus4 = chains4.first { ($0["directory"] as? String) == "Nexus" }
        XCTAssertEqual(nexus4?["mining"] as? Bool, false, "Should not be mining after stop")
    }

    // MARK: - Balance Growth Across Blocks

    /// Verify miner balance grows monotonically across mined blocks.
    func testMinerBalanceGrowsAcrossBlocks() async throws {
        let env = try await bootMiningNode()
        defer { env.rpcTask.cancel(); Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }

        let base = "http://127.0.0.1:\(env.rpcPort)/api"
        let minerAddr = addr(env.kp.publicKey)

        let latest = try await rpcGet(base, "/block/latest")
        let height = latest["index"] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(height, 2, "Need at least 2 blocks for comparison")

        // Check balance at block 1 vs later block — should increase
        let acct1 = try await rpcGet(base, "/block/1/state/account/\(minerAddr)")
        let balance1 = acct1["balance"] as? Int ?? 0
        XCTAssertGreaterThan(balance1, 0, "Miner should have balance at block 1")

        let acctN = try await rpcGet(base, "/block/\(height)/state/account/\(minerAddr)")
        let balanceN = acctN["balance"] as? Int ?? 0
        XCTAssertGreaterThan(balanceN, balance1, "Balance at block \(height) should exceed block 1")

        // Also verify the growth matches reward expectations (1024 per block, no halving yet)
        let expectedGrowth = (height - 1) * 1024
        XCTAssertEqual(balanceN - balance1, expectedGrowth,
                       "Balance difference should equal (height-1) * reward")
    }

    // MARK: - Peers and Proof Endpoints

    /// Verify peers endpoint returns valid structure, proof endpoint works for known address.
    func testPeersAndProofEndpoints() async throws {
        let env = try await bootMiningNode()
        defer { env.rpcTask.cancel(); Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }

        let base = "http://127.0.0.1:\(env.rpcPort)/api"
        let minerAddr = addr(env.kp.publicKey)

        // --- GET /peers ---
        let peers = try await rpcGet(base, "/peers")
        XCTAssertEqual(peers["count"] as? Int, 0, "Solo node has no peers")
        XCTAssertNotNil(peers["peers"] as? [Any])

        // --- GET /proof/{address} ---
        let (proofData, proofStatus) = try await rpcGetRaw(base, "/proof/\(minerAddr)")
        XCTAssertEqual(proofStatus, 200, "Proof endpoint should succeed for known address")
        XCTAssertGreaterThan(proofData.count, 0)

        // --- Light client: GET /light/headers (stub returns empty) ---
        let headers = try await rpcGet(base, "/light/headers?from=0&to=5")
        let headerList = headers["headers"] as? [Any] ?? []
        XCTAssertEqual(headers["count"] as? Int, headerList.count)

        // --- Light client: GET /light/proof/{address} ---
        let lightProof = try await rpcGet(base, "/light/proof/\(minerAddr)")
        XCTAssertNotNil(lightProof["address"] as? String)
    }

    // MARK: - Error Paths

    /// Verify error responses for invalid inputs.
    func testRPCErrorPaths() async throws {
        let env = try await bootMiningNode(blockCount: 0)
        defer { env.rpcTask.cancel(); Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }

        let base = "http://127.0.0.1:\(env.rpcPort)/api"

        // --- 404: Block not found ---
        let (_, blockStatus) = try await rpcGetRaw(base, "/block/999999")
        XCTAssertEqual(blockStatus, 404)

        // --- 404: Block by bad hash ---
        let (_, badHashStatus) = try await rpcGetRaw(base, "/block/not_a_real_hash")
        XCTAssertEqual(badHashStatus, 404)

        // --- 404: Receipt not found ---
        let (_, receiptStatus) = try await rpcGetRaw(base, "/receipt/nonexistent_cid")
        XCTAssertEqual(receiptStatus, 404)

        // --- 404: Transaction not found ---
        let (_, txStatus) = try await rpcGetRaw(base, "/transaction/nonexistent_cid")
        XCTAssertEqual(txStatus, 404)

        // --- 400: Submit invalid transaction ---
        let (_, badTxStatus) = try await rpcPostRaw(base, "/transaction", body: [
            "signatures": ["fake": "sig"],
            "bodyCID": "not_a_real_cid",
        ])
        // Should be 400 (bad CID/body not found)
        XCTAssertNotEqual(badTxStatus, 200, "Invalid tx should not succeed")

        // --- 400: Submit tx with wrong format ---
        let (_, badFormatStatus) = try await rpcPostRaw(base, "/transaction", body: ["garbage": true])
        XCTAssertNotEqual(badFormatStatus, 200)

        // --- 404: Unknown chain ---
        let (_, unknownChainStatus) = try await rpcGetRaw(base, "/block/latest?chain=DoesNotExist")
        XCTAssertEqual(unknownChainStatus, 404)

        // --- 400: Finality with invalid height ---
        let (_, badFinalityStatus) = try await rpcGetRaw(base, "/finality/not_a_number")
        XCTAssertEqual(badFinalityStatus, 400)
    }

    // MARK: - Block Navigation Consistency

    /// Walk the chain backwards from tip to genesis using previousBlock links,
    /// verifying data consistency at each step.
    func testBlockChainWalkbackConsistency() async throws {
        let env = try await bootMiningNode()
        defer { env.rpcTask.cancel(); Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }

        let base = "http://127.0.0.1:\(env.rpcPort)/api"

        let latest = try await rpcGet(base, "/block/latest")
        var currentHash = latest["hash"] as? String ?? ""
        var currentHeight = latest["index"] as? Int ?? 0
        XCTAssertGreaterThan(currentHeight, 0)

        // Walk backwards from tip to genesis
        while currentHeight > 0 {
            let block = try await rpcGet(base, "/block/\(currentHash)")
            XCTAssertEqual(block["index"] as? Int, currentHeight)
            XCTAssertEqual(block["hash"] as? String, currentHash)

            // Verify block-by-index returns the same hash
            let byIndex = try await rpcGet(base, "/block/\(currentHeight)")
            XCTAssertEqual(byIndex["hash"] as? String, currentHash,
                           "Block \(currentHeight) hash should match by-index and by-hash lookup")

            // Verify transaction count matches actual transaction list
            let txCount = block["transactionCount"] as? Int ?? 0
            let txResp = try await rpcGet(base, "/block/\(currentHash)/transactions")
            XCTAssertEqual(txResp["count"] as? Int, txCount,
                           "Block \(currentHeight) txCount should match transactions list")

            // Move to previous block
            guard let prevHash = block["previousBlock"] as? String else {
                XCTFail("Block \(currentHeight) should have previousBlock")
                break
            }
            currentHash = prevHash
            currentHeight -= 1
        }

        // Should have reached genesis
        XCTAssertEqual(currentHeight, 0)
        let genesis = try await rpcGet(base, "/block/\(currentHash)")
        XCTAssertEqual(genesis["index"] as? Int, 0)
        XCTAssertNil(genesis["previousBlock"], "Genesis should have nil previousBlock")
    }

    // MARK: - Cross-Chain Helpers

    /// Boot a node with nexus + a child chain ("Child"). The child chain gets a
    /// premine of `childPremine` credited to `demanderAddr`. A separate dummy key
    /// signs the genesis tx so the demander has balance but no TransactionState
    /// nonce — avoiding the coinbase nonce divergence issue.
    ///
    /// Merged mining is active: nexus blocks embed child blocks so that child
    /// chain transactions are confirmed alongside nexus blocks.
    private func bootCrossChainNode(
        minerKp: (privateKey: String, publicKey: String),
        demanderKp: (privateKey: String, publicKey: String),
        childPremine: UInt64 = 10_000,
        blockCount: Int = 1
    ) async throws -> (node: LatticeNode, rpcPort: UInt16, rpcTask: Task<Void, any Error>, tmpDir: URL) {
        let p1 = nextTestPort()
        let p2 = nextTestPort()
        let rpcPort = nextTestPort()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let demanderAddr = addr(demanderKp.publicKey)

        let nexusSpec = testSpec("Nexus")
        let nexusGenesis = testGenesis(spec: nexusSpec)
        // Subscribe to both Nexus and the Child chain so merged mining
        // produces child blocks alongside nexus blocks.
        var subs = ArrayTrie<Bool>()
        subs.set(["Nexus"], value: true)
        subs.set(["Nexus", "Child"], value: true)
        let config = LatticeNodeConfig(
            publicKey: minerKp.publicKey, privateKey: minerKp.privateKey,
            listenPort: p1, storagePath: tmpDir.appendingPathComponent("node1"),
            enableLocalDiscovery: false, persistInterval: 5,
            subscribedChains: subs
        )
        let node = try await LatticeNode(config: config, genesisConfig: nexusGenesis)
        try await node.start()

        guard let nexusNet = await node.network(for: "Nexus") else {
            XCTFail("Nexus network missing"); throw CancellationError()
        }

        // Build child genesis with premine for demander.
        // Use a throw-away signer so demander has no TransactionState nonce.
        let dummySigner = CryptoUtils.generateKeyPair()
        let childSpec = testSpec("Child")
        let childPremineBody = TransactionBody(
            accountActions: [AccountAction(owner: demanderAddr, delta: Int64(childPremine))],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [addr(dummySigner.publicKey)], fee: 0, nonce: 0
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, transactions: [sign(childPremineBody, dummySigner)],
            timestamp: nexusGenesis.timestamp, difficulty: UInt256.max,
            fetcher: nexusNet.ivyFetcher
        )

        // Subscribe and register child chain before mining so merged mining
        // produces child blocks alongside nexus blocks.
        await node.lattice.nexus.subscribe(to: "Child", genesisBlock: childGenesis)
        let ivyConfig = IvyConfig(
            publicKey: minerKp.publicKey, listenPort: p2,
            bootstrapPeers: [], enableLocalDiscovery: false
        )
        try await node.registerChainNetwork(directory: "Child", config: ivyConfig)

        // Store child genesis data in the child network's CAS
        guard let childNet = await node.network(for: "Child") else {
            XCTFail("Child network not registered"); throw CancellationError()
        }
        let storer = BufferedStorer()
        try VolumeImpl<Block>(node: childGenesis).storeRecursively(storer: storer)
        await storer.flush(to: childNet)

        // Apply child genesis block state (premine balances, receipts) to the child StateStore.
        // Genesis is never embedded in a nexus block, so applyChildBlockStates won't cover it.
        await node.applyGenesisBlock(directory: "Child", block: childGenesis)

        // Mine with merged mining active
        if blockCount > 0 {
            try await mineBlocks(blockCount, on: node)
        }

        let server = RPCServer(node: node, port: rpcPort, bindAddress: "127.0.0.1", allowedOrigin: "*")
        let rpcTask = Task { try await server.run() }
        try await Task.sleep(for: .milliseconds(500))

        return (node, rpcPort, rpcTask, tmpDir)
    }

    // MARK: - Cross-Chain Tests

    /// Verify child chain appears in chain info and spec/balance endpoints work.
    func testChildChainInfoAndBlocks() async throws {
        let minerKp = CryptoUtils.generateKeyPair()
        let demanderKp = CryptoUtils.generateKeyPair()
        let env = try await bootCrossChainNode(minerKp: minerKp, demanderKp: demanderKp)
        defer { env.rpcTask.cancel(); Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }
        let base = "http://127.0.0.1:\(env.rpcPort)/api"

        // --- Chain info should include both chains ---
        let info = try await rpcGet(base, "/chain/info")
        let chains = info["chains"] as? [[String: Any]] ?? []
        let dirs = chains.compactMap { $0["directory"] as? String }
        XCTAssertTrue(dirs.contains("Nexus"), "Chain info should include Nexus")
        XCTAssertTrue(dirs.contains("Child"), "Chain info should include Child")

        // Both chains should have mined blocks (merged mining)
        let nexusInfo = chains.first { ($0["directory"] as? String) == "Nexus" }
        let nexusHeight = nexusInfo?["height"] as? Int ?? 0
        XCTAssertGreaterThan(nexusHeight, 0, "Nexus should have mined blocks")
        let childInfo = chains.first { ($0["directory"] as? String) == "Child" }
        let childHeight = childInfo?["height"] as? Int ?? 0
        XCTAssertGreaterThan(childHeight, 0, "Child should have blocks from merged mining")

        // --- Chain spec for child ---
        let childSpec = try await rpcGet(base, "/chain/spec?chain=Child")
        XCTAssertEqual(childSpec["directory"] as? String, "Child")

        // --- Demander should have premine balance on child chain ---
        let demanderAddr = addr(demanderKp.publicKey)
        let balance = try await rpcGet(base, "/balance/\(demanderAddr)?chain=Child")
        XCTAssertEqual(balance["balance"] as? Int, 10_000, "Demander should have child premine")

        // --- Nexus block endpoints should work ---
        let nexusLatest = try await rpcGet(base, "/block/latest")
        XCTAssertNotNil(nexusLatest["hash"] as? String)
        XCTAssertEqual(nexusLatest["chain"] as? String, "Nexus")
    }

    /// Verify cross-chain validation: deposits rejected on nexus, receipts rejected on child.
    func testCrossChainValidationErrors() async throws {
        let minerKp = CryptoUtils.generateKeyPair()
        let demanderKp = CryptoUtils.generateKeyPair()
        let env = try await bootCrossChainNode(minerKp: minerKp, demanderKp: demanderKp)
        defer { env.rpcTask.cancel(); Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }
        let base = "http://127.0.0.1:\(env.rpcPort)/api"

        let minerAddr = addr(minerKp.publicKey)
        let demanderAddr = addr(demanderKp.publicKey)

        // Prepare a deposit on the NEXUS (should be rejected)
        let depositBody: [String: Any] = [
            "nonce": 0,
            "signers": [demanderAddr],
            "fee": 1,
            "accountActions": [["owner": demanderAddr, "delta": -101]],
            "depositActions": [
                ["nonce": "2a", "demander": demanderAddr, "amountDemanded": 100, "amountDeposited": 100]
            ],
        ]
        let prepared = try await rpcPost(base, "/transaction/prepare", body: depositBody)
        let bodyCID = prepared["bodyCID"] as? String ?? ""
        let bodyData = prepared["bodyData"] as? String ?? ""
        let sig = CryptoUtils.sign(message: bodyCID, privateKeyHex: demanderKp.privateKey)!
        let submitBody: [String: Any] = [
            "signatures": [demanderKp.publicKey: sig],
            "bodyCID": bodyCID, "bodyData": bodyData,
        ]
        let (_, depositOnNexusStatus) = try await rpcPostRaw(base, "/transaction", body: submitBody)
        XCTAssertEqual(depositOnNexusStatus, 400, "Deposit on nexus should be rejected")

        // Prepare a receipt on the CHILD chain (should be rejected)
        let receiptBody: [String: Any] = [
            "nonce": 0,
            "signers": [minerAddr],
            "fee": 1,
            "accountActions": [["owner": minerAddr, "delta": -1]],
            "receiptActions": [
                ["withdrawer": minerAddr, "nonce": "2a", "demander": demanderAddr,
                 "amountDemanded": 100, "directory": "Child"]
            ],
        ]
        let rPrep = try await rpcPost(base, "/transaction/prepare", body: receiptBody)
        let rBodyCID = rPrep["bodyCID"] as? String ?? ""
        let rBodyData = rPrep["bodyData"] as? String ?? ""
        let rSig = CryptoUtils.sign(message: rBodyCID, privateKeyHex: minerKp.privateKey)!
        let rSubmit: [String: Any] = [
            "signatures": [minerKp.publicKey: rSig],
            "bodyCID": rBodyCID, "bodyData": rBodyData,
            "chain": "Child",
        ]
        let (_, receiptOnChildStatus) = try await rpcPostRaw(base, "/transaction", body: rSubmit)
        XCTAssertEqual(receiptOnChildStatus, 400, "Receipt on child chain should be rejected")
    }

    /// Deposit on child → query deposit state → list deposits.
    func testDepositAndStateQueries() async throws {
        let minerKp = CryptoUtils.generateKeyPair()
        let demanderKp = CryptoUtils.generateKeyPair()
        let env = try await bootCrossChainNode(minerKp: minerKp, demanderKp: demanderKp)
        defer { env.rpcTask.cancel(); Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }
        let base = "http://127.0.0.1:\(env.rpcPort)/api"

        let demanderAddr = addr(demanderKp.publicKey)
        let depositAmount = 500
        let depositNonce = "00000000000000000000000000000064" // UInt128 hex for 100

        // --- Prepare and submit deposit on child chain ---
        let prepBody: [String: Any] = [
            "nonce": 0,
            "signers": [demanderAddr],
            "fee": 1,
            "accountActions": [["owner": demanderAddr, "delta": -(depositAmount + 1)]],
            "depositActions": [
                ["nonce": depositNonce, "demander": demanderAddr,
                 "amountDemanded": depositAmount, "amountDeposited": depositAmount]
            ],
        ]
        let prepared = try await rpcPost(base, "/transaction/prepare", body: prepBody)
        let bodyCID = prepared["bodyCID"] as? String ?? ""
        let bodyData = prepared["bodyData"] as? String ?? ""
        XCTAssertFalse(bodyCID.isEmpty, "Prepare should return bodyCID")

        let sig = CryptoUtils.sign(message: bodyCID, privateKeyHex: demanderKp.privateKey)!
        let submitBody: [String: Any] = [
            "signatures": [demanderKp.publicKey: sig],
            "bodyCID": bodyCID, "bodyData": bodyData,
            "chain": "Child",
        ]
        let submitResp = try await rpcPost(base, "/transaction", body: submitBody)
        XCTAssertTrue(submitResp["accepted"] as? Bool ?? false, "Deposit tx should be accepted")

        // Mine to include the deposit on the child chain via merged mining.
        try await mineBlocks(1, on: env.node, chain: "Child")

        // --- GET /deposit — query the deposit ---
        let depositQ = try await rpcGet(base, "/deposit?demander=\(demanderAddr)&amount=\(depositAmount)&nonce=\(depositNonce)&chain=Child")
        XCTAssertTrue(depositQ["exists"] as? Bool ?? false, "Deposit should exist in state")
        XCTAssertEqual(depositQ["amountDeposited"] as? Int, depositAmount)
        XCTAssertEqual(depositQ["chain"] as? String, "Child")

        // --- GET /deposits — list deposits on child ---
        let depositList = try await rpcGet(base, "/deposits?chain=Child")
        let deposits = depositList["deposits"] as? [[String: Any]] ?? []
        XCTAssertGreaterThan(deposits.count, 0, "Should have at least one deposit")
        let found = deposits.contains { ($0["demander"] as? String) == demanderAddr }
        XCTAssertTrue(found, "Deposit list should include our deposit")

        // --- Verify demander balance decreased ---
        let bal = try await rpcGet(base, "/balance/\(demanderAddr)?chain=Child")
        let remaining = bal["balance"] as? Int ?? 0
        XCTAssertEqual(remaining, 10_000 - depositAmount - 1, "Demander balance should reflect deposit + fee")
    }

    /// Full cross-chain trade: deposit → receipt → withdrawal, querying state at each step.
    func testFullCrossChainTrade() async throws {
        let minerKp = CryptoUtils.generateKeyPair()
        let demanderKp = CryptoUtils.generateKeyPair()
        let env = try await bootCrossChainNode(minerKp: minerKp, demanderKp: demanderKp)
        defer { env.rpcTask.cancel(); Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }
        let base = "http://127.0.0.1:\(env.rpcPort)/api"

        let minerAddr = addr(minerKp.publicKey)
        let demanderAddr = addr(demanderKp.publicKey)
        let depositAmount = 200
        let depositNonce = "000000000000000000000000000000ff" // UInt128 hex for 255

        // ====== PHASE 1: DEPOSIT on child chain ======
        let depPrep = try await rpcPost(base, "/transaction/prepare", body: [
            "nonce": 0,
            "signers": [demanderAddr],
            "fee": 1,
            "accountActions": [["owner": demanderAddr, "delta": -(depositAmount + 1)]],
            "depositActions": [
                ["nonce": depositNonce, "demander": demanderAddr,
                 "amountDemanded": depositAmount, "amountDeposited": depositAmount]
            ],
        ] as [String: Any])
        let depCID = depPrep["bodyCID"] as? String ?? ""
        let depData = depPrep["bodyData"] as? String ?? ""
        let depSig = CryptoUtils.sign(message: depCID, privateKeyHex: demanderKp.privateKey)!
        let depSubmit = try await rpcPost(base, "/transaction", body: [
            "signatures": [demanderKp.publicKey: depSig],
            "bodyCID": depCID, "bodyData": depData, "chain": "Child",
        ] as [String: Any])
        XCTAssertTrue(depSubmit["accepted"] as? Bool ?? false, "Deposit should be accepted")

        // Mine to include the deposit on the child chain via merged mining.
        try await mineBlocks(1, on: env.node, chain: "Child")

        // Verify deposit exists
        let depState = try await rpcGet(base, "/deposit?demander=\(demanderAddr)&amount=\(depositAmount)&nonce=\(depositNonce)&chain=Child")
        XCTAssertTrue(depState["exists"] as? Bool ?? false, "Deposit should be in child state")

        // ====== PHASE 2: RECEIPT on nexus ======
        // The miner (withdrawer) pays demander on nexus via receipt. The receipt
        // implicitly debits the withdrawer and credits the demander by depositAmount.
        // After mining H blocks, the miner's TransactionState nonce is H-1
        // (coinbase nonces 0..H-1 for blocks 1..H). The next available nonce is H.
        let nexusHeight = await env.node.lattice.nexus.chain.getHighestBlockIndex()
        let receiptTxNonce = Int(nexusHeight)

        let rcptPrep = try await rpcPost(base, "/transaction/prepare", body: [
            "nonce": receiptTxNonce,
            "signers": [minerAddr],
            "fee": 1,
            "accountActions": [["owner": minerAddr, "delta": -1]],
            "receiptActions": [
                ["withdrawer": minerAddr, "nonce": depositNonce, "demander": demanderAddr,
                 "amountDemanded": depositAmount, "directory": "Child"]
            ],
        ] as [String: Any])
        let rcptCID = rcptPrep["bodyCID"] as? String ?? ""
        let rcptData = rcptPrep["bodyData"] as? String ?? ""
        XCTAssertFalse(rcptCID.isEmpty, "Receipt prepare should succeed")
        let rcptSig = CryptoUtils.sign(message: rcptCID, privateKeyHex: minerKp.privateKey)!
        let rcptSubmit = try await rpcPost(base, "/transaction", body: [
            "signatures": [minerKp.publicKey: rcptSig],
            "bodyCID": rcptCID, "bodyData": rcptData,
        ] as [String: Any])
        XCTAssertTrue(rcptSubmit["accepted"] as? Bool ?? false, "Receipt should be accepted on nexus")

        // Mine to include receipt on nexus.
        try await mineBlocks(1, on: env.node)

        // Verify receipt exists on nexus
        let rcptState = try await rpcGet(base,
            "/receipt-state?demander=\(demanderAddr)&amount=\(depositAmount)&nonce=\(depositNonce)&directory=Child")
        XCTAssertTrue(rcptState["exists"] as? Bool ?? false, "Receipt should be in nexus state")
        XCTAssertEqual(rcptState["withdrawer"] as? String, minerAddr)

        // Verify demander received funds on nexus
        let demanderNexusBal = try await rpcGet(base, "/balance/\(demanderAddr)")
        XCTAssertEqual(demanderNexusBal["balance"] as? Int, depositAmount,
            "Demander should have received depositAmount on nexus")

        // ====== PHASE 3: WITHDRAWAL on child chain ======
        // Withdrawer (miner) claims the deposited funds on the child chain.
        // The withdrawal credits the withdrawer and removes the deposit.
        // Conservation: 0 + withdrawn(200) = credits(199) + fee(1) + deposited(0)
        // The miner has no prior transactions on the child chain (child blocks
        // don't have coinbase txs — only nexus does), so nonce starts at 0.
        let wdPrep = try await rpcPost(base, "/transaction/prepare", body: [
            "nonce": 0,
            "signers": [minerAddr],
            "fee": 1,
            "accountActions": [["owner": minerAddr, "delta": depositAmount - 1]],
            "withdrawalActions": [
                ["withdrawer": minerAddr, "nonce": depositNonce, "demander": demanderAddr,
                 "amountDemanded": depositAmount, "amountWithdrawn": depositAmount]
            ],
        ] as [String: Any])
        let wdCID = wdPrep["bodyCID"] as? String ?? ""
        let wdData = wdPrep["bodyData"] as? String ?? ""
        XCTAssertFalse(wdCID.isEmpty, "Withdrawal prepare should succeed")
        let wdSig = CryptoUtils.sign(message: wdCID, privateKeyHex: minerKp.privateKey)!
        let wdSubmit = try await rpcPost(base, "/transaction", body: [
            "signatures": [minerKp.publicKey: wdSig],
            "bodyCID": wdCID, "bodyData": wdData, "chain": "Child",
        ] as [String: Any])
        XCTAssertTrue(wdSubmit["accepted"] as? Bool ?? false, "Withdrawal should be accepted on child")

        // Mine to include withdrawal on child chain via merged mining.
        try await mineBlocks(1, on: env.node, chain: "Child")

        // Verify deposit is removed
        let depAfter = try await rpcGet(base, "/deposit?demander=\(demanderAddr)&amount=\(depositAmount)&nonce=\(depositNonce)&chain=Child")
        XCTAssertFalse(depAfter["exists"] as? Bool ?? true, "Deposit should be removed after withdrawal")

        // Verify withdrawer received funds on child chain
        let wdBal = try await rpcGet(base, "/balance/\(minerAddr)?chain=Child")
        XCTAssertEqual(wdBal["balance"] as? Int, depositAmount - 1,
            "Withdrawer should have deposit amount minus fee on child")
    }
}
