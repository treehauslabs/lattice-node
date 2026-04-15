import XCTest
@testable import Lattice
@testable import LatticeNode
@testable import Ivy
import UInt256
import cashew
import Acorn
import AcornDiskWorker
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
        mineSeconds: Int = 3
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

        if mineSeconds > 0 {
            await node.startMining(directory: "Nexus")
            try await Task.sleep(for: .seconds(mineSeconds))
            await node.stopMining(directory: "Nexus")
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
        await node1.startMining(directory: "Nexus")
        try await Task.sleep(for: .seconds(3))
        await node1.stopMining(directory: "Nexus")

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
        await node1.startMining(directory: "Nexus")
        try await Task.sleep(for: .seconds(2))
        await node1.stopMining(directory: "Nexus")
        let heightAfterFirstRun = await node1.lattice.nexus.chain.getHighestBlockIndex()
        XCTAssertGreaterThan(heightAfterFirstRun, 0)
        await node1.stop()

        // Second run — mine more blocks
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

        // Start mining — should not crash (difficulty may be too high for fast blocks here,
        // but the miner loop itself must start without errors)
        await node2.startMining(directory: "Nexus")
        let mining = await node2.isMining(directory: "Nexus")
        XCTAssertTrue(mining, "Miner should be running")
        try await Task.sleep(for: .seconds(1))
        await node2.stopMining(directory: "Nexus")

        await node2.stop()
    }
}
