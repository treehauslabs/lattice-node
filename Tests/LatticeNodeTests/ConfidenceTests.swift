import XCTest
@testable import Lattice
@testable import LatticeNode
@testable import Ivy
import Tally
import UInt256
import cashew
import Acorn

// Helpers in TestHelpers.swift: cas(), testSpec(), sign(), addr(), now()

// ============================================================================
// MARK: - 1. State Root Verification
// Verify that frontier state root is independently derivable from homestead + transactions
// ============================================================================

final class StateRootVerificationTests: XCTestCase {

    /// Build a block with a coinbase transaction, then independently verify
    /// that the frontier matches applying the transaction to homestead.
    func testFrontierMatchesHomesteadPlusTransactions() async throws {
        let f = cas()
        let t = now() - 20_000
        let s = testSpec()
        let kp = CryptoUtils.generateKeyPair()
        let minerAddr = addr(kp.publicKey)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: t, difficulty: UInt256.max, fetcher: f
        )
        let genesisHeader = VolumeImpl<Block>(node: genesis)
        let storer = BufferedStorer()
        try genesisHeader.storeRecursively(storer: storer)
        await storer.flush(to: f)

        // Build a block with a coinbase tx
        let reward = s.rewardAtBlock(1)
        let coinbaseBody = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: Int64(reward))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: [minerAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let coinbaseTx = sign(coinbaseBody, kp)

        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [coinbaseTx],
            timestamp: t + 1000, difficulty: UInt256.max, nonce: 1, fetcher: f
        )
        let blockHeader = VolumeImpl<Block>(node: block)
        let storer2 = BufferedStorer()
        try blockHeader.storeRecursively(storer: storer2)
        await storer2.flush(to: f)

        // Verify: frontier state should contain miner's balance
        let frontier = try await block.frontier.resolve(fetcher: f)
        XCTAssertNotNil(frontier.node, "Frontier should be resolvable")

        let accounts = try await frontier.node!.accountState.resolve(fetcher: f)
        XCTAssertNotNil(accounts.node, "Account state should be resolvable")

        let minerBalance = try? accounts.node!.get(key: minerAddr)
        XCTAssertNotNil(minerBalance, "Miner should have a balance")
        XCTAssertEqual(UInt64(minerBalance!), reward, "Miner balance should equal block reward")

        // Verify: homestead should NOT contain miner's balance (pre-state)
        let homestead = try await block.homestead.resolve(fetcher: f)
        XCTAssertNotNil(homestead.node)
        let oldAccounts = try await homestead.node!.accountState.resolve(fetcher: f)
        let oldMinerBalance = try? oldAccounts.node?.get(key: minerAddr)
        XCTAssertNil(oldMinerBalance, "Homestead should not have miner balance")

        // Verify: block validates its own frontier
        let valid = try await block.validateFrontierState(
            transactionBodies: [coinbaseBody], fetcher: f
        )
        XCTAssertTrue(valid, "Block should validate its own frontier state root")
    }

    /// Multiple transactions in one block: verify state conservation
    func testMultiTransactionBlockStateConservation() async throws {
        let f = cas()
        let t = now() - 30_000
        let s = testSpec("Nexus", premine: 1_000_000)
        let sender = CryptoUtils.generateKeyPair()
        let senderAddr = addr(sender.publicKey)
        let receiver = CryptoUtils.generateKeyPair()
        let receiverAddr = addr(receiver.publicKey)

        let premineAmount = s.premineAmount()
        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: senderAddr, delta: Int64(premineAmount))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: [senderAddr], fee: 0, nonce: 0
        )
        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, transactions: [sign(premineBody, sender)],
            timestamp: t, difficulty: UInt256.max, fetcher: f
        )
        let gs = BufferedStorer()
        try VolumeImpl<Block>(node: genesis).storeRecursively(storer: gs)
        await gs.flush(to: f)

        // Build block with transfer + fee
        let fee: UInt64 = 10
        let transfer: UInt64 = 500
        let reward = s.rewardAtBlock(1)
        let txBody = TransactionBody(
            accountActions: [
                AccountAction(owner: senderAddr, delta: Int64(premineAmount - transfer - fee) - Int64(premineAmount)),
                AccountAction(owner: receiverAddr, delta: Int64(transfer + reward))
            ],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: [senderAddr], fee: fee, nonce: 1
        )
        let tx = sign(txBody, sender)

        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx],
            timestamp: t + 1000, difficulty: UInt256.max, nonce: 1, fetcher: f
        )
        let bs = BufferedStorer()
        try VolumeImpl<Block>(node: block).storeRecursively(storer: bs)
        await bs.flush(to: f)

        // Verify state
        let frontier = try await block.frontier.resolve(fetcher: f)
        let accts = try await frontier.node!.accountState.resolveRecursive(fetcher: f)
        let entries = try accts.node!.allKeysAndValues()

        var totalBalance: UInt64 = 0
        for (_, balance) in entries {
            totalBalance += UInt64(balance) ?? 0
        }

        // Total should be premine + reward - fee (fee is burned in this block, no coinbase absorbs it)
        XCTAssertEqual(totalBalance, premineAmount + reward - fee, "Total balance should be premine + reward - fee")
    }

}

// ============================================================================
// MARK: - 2. Message Deserialization Fuzz Tests
// ============================================================================

final class MessageFuzzTests: XCTestCase {

    /// Feed random bytes to Message.deserialize — must never crash
    func testRandomBytesNeverCrash() {
        for _ in 0..<10_000 {
            let length = Int.random(in: 0...512)
            var bytes = Data(count: length)
            for i in 0..<length {
                bytes[i] = UInt8.random(in: 0...255)
            }
            // Must not crash — nil is fine
            let _ = Message.deserialize( bytes)
        }
    }

    /// Truncated valid messages should not crash
    func testTruncatedMessagesNeverCrash() {
        let validMessages: [Message] = [
            .ping(nonce: 42),
            .pong(nonce: 99),
            .block(cid: "testcid", data: Data("hello".utf8)),
            .dontHave(cid: "testcid"),
            .findNode(target: Data(repeating: 0xAB, count: 32), fee: 100),
            .announceBlock(cid: "blockcid"),
            .peerMessage(topic: "test", payload: Data("payload".utf8)),
            .feeExhausted(consumed: 50),
            .pinAnnounce(rootCID: "root", selector: "/", publicKey: "pk", expiry: 1000, signature: Data(), fee: 5),
            .balanceCheck(sequence: 1, balance: -50),
        ]

        for msg in validMessages {
            let full = msg.serialize()
            // Try every truncation point
            for len in 0..<full.count {
                let truncated = full.prefix(len)
                let _ = Message.deserialize( Data(truncated))
                // Must not crash
            }
        }
    }

    /// Valid messages round-trip correctly
    func testValidMessagesRoundTrip() {
        let messages: [Message] = [
            .ping(nonce: 12345),
            .pong(nonce: 67890),
            .block(cid: "bafyrei123", data: Data("blockdata".utf8)),
            .dontHave(cid: "missing"),
            .announceBlock(cid: "newblock"),
            .feeExhausted(consumed: 42),
            .peerMessage(topic: "gossip", payload: Data("hello".utf8)),
            .balanceCheck(sequence: 7, balance: -100),
        ]

        for original in messages {
            let serialized = original.serialize()
            let deserialized = Message.deserialize( serialized)
            XCTAssertNotNil(deserialized, "Message should deserialize: \(original)")
        }
    }

    /// Oversized payloads should be handled gracefully
    func testOversizedPayload() {
        // 1MB of random data with a valid tag byte
        var data = Data(count: 1_048_576)
        data[0] = 0 // ping tag
        let _ = Message.deserialize( data) // Must not crash or OOM
    }
}

// ============================================================================
// MARK: - 3. Mempool Load Test
// ============================================================================

final class MempoolLoadTests: XCTestCase {

    /// Submit 10K transactions from 100 senders and verify mempool handles it
    func testTenThousandTransactions() async throws {
        let mempool = NodeMempool(maxSize: 10_000, maxPerAccount: 100)

        var added = 0
        // 100 senders, 100 txs each
        var senders: [(privateKey: String, publicKey: String)] = []
        for _ in 0..<100 { senders.append(CryptoUtils.generateKeyPair()) }

        for (senderIdx, kp) in senders.enumerated() {
            let senderAddr = addr(kp.publicKey)
            for nonce in 0..<100 {
                let body = TransactionBody(
                    accountActions: [AccountAction(owner: senderAddr, delta: -1)],
                    actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
                    settleActions: [], signers: [senderAddr], fee: UInt64(senderIdx * 100 + nonce + 1), nonce: UInt64(nonce)
                )
                let tx = sign(body, kp)
                if await mempool.add(transaction: tx) { added += 1 }
            }
        }

        XCTAssertEqual(added, 10_000, "All 10K transactions should be accepted")
        let count = await mempool.count
        XCTAssertEqual(count, 10_000)

        // Selection: each sender starts at nonce 0, so we get one tx per sender (highest fee first)
        let selected = await mempool.selectTransactions(maxCount: 100)
        XCTAssertGreaterThan(selected.count, 0, "Should select from pool")

        // Fee histogram should work
        let histogram = await mempool.feeHistogram()
        XCTAssertFalse(histogram.isEmpty, "Histogram should have entries")

        // Prune should work — sleep briefly so txs are "old"
        try await Task.sleep(for: .milliseconds(10))
        await mempool.pruneExpired(olderThan: .milliseconds(1))
        let afterPrune = await mempool.count
        XCTAssertEqual(afterPrune, 0, "All should be pruned")
    }

    /// RBF under pressure: replace low-fee txs with high-fee ones
    func testRBFUnderPressure() async throws {
        let mempool = NodeMempool(maxSize: 100, maxPerAccount: 100)
        let kp = CryptoUtils.generateKeyPair()
        let senderAddr = addr(kp.publicKey)

        // Fill mempool with low-fee txs
        for i in 0..<100 {
            let body = TransactionBody(
                accountActions: [AccountAction(owner: senderAddr, delta: Int64(999) - Int64(1000))],
                actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
                settleActions: [], signers: [senderAddr], fee: 1, nonce: UInt64(i)
            )
            let _ = await mempool.add(transaction: sign(body, kp))
        }
        let fullCount = await mempool.count
        XCTAssertEqual(fullCount, 100)

        // High-fee tx should evict lowest
        let kp2 = CryptoUtils.generateKeyPair()
        let addr2 = addr(kp2.publicKey)
        let highFeeBody = TransactionBody(
            accountActions: [AccountAction(owner: addr2, delta: Int64(999) - Int64(1000))],
            actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
            settleActions: [], signers: [addr2], fee: 100, nonce: 0
        )
        let added = await mempool.add(transaction: sign(highFeeBody, kp2))
        XCTAssertTrue(added, "High-fee tx should be accepted")
        let afterCount = await mempool.count
        XCTAssertEqual(afterCount, 100, "Size should stay at limit")
    }

    /// Nonce update correctly purges stale entries from all structures
    func testNonceUpdateCleansAllStructures() async throws {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 100)
        let kp = CryptoUtils.generateKeyPair()
        let senderAddr = addr(kp.publicKey)

        // Add 10 txs with nonces 0-9
        for i in 0..<10 {
            let body = TransactionBody(
                accountActions: [AccountAction(owner: senderAddr, delta: Int64(999) - Int64(1000))],
                actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
                settleActions: [], signers: [senderAddr], fee: UInt64(i + 1), nonce: UInt64(i)
            )
            let _ = await mempool.add(transaction: sign(body, kp))
        }
        let initialCount = await mempool.count
        XCTAssertEqual(initialCount, 10)

        // Confirm nonce 5 — nonces 0-4 should be purged
        await mempool.updateConfirmedNonce(sender: senderAddr, nonce: 5)
        let afterNonceUpdate = await mempool.count
        XCTAssertLessThan(afterNonceUpdate, initialCount, "Some stale entries should be removed")

        // Stale CIDs (nonces 0-4) should not be findable
        // Selection starting at confirmed nonce 5 should still work
        let selected = await mempool.selectTransactions(maxCount: 100)
        for tx in selected {
            let nonce = tx.body.node?.nonce ?? 0
            XCTAssertGreaterThanOrEqual(nonce, 5, "Selected tx should have nonce >= confirmed")
        }
    }
}

// ============================================================================
// MARK: - 4. Sync with 1000-Block Gap
// ============================================================================

final class LongChainSyncTests: XCTestCase {

    /// Build a 50-block chain, snapshot sync the recent window
    func testSnapshotSyncWith50Blocks() async throws {
        let f = cas()
        let t = now() - 2_000_000
        let s = testSpec()

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: t, difficulty: UInt256.max, fetcher: f
        )
        let genesisHeader = VolumeImpl<Block>(node: genesis)
        let genesisStorer = BufferedStorer()
        try genesisHeader.storeRecursively(storer: genesisStorer)
        await genesisStorer.flush(to: f)
        let genesisHash = genesisHeader.rawCID

        // Build 50-block chain
        var prev = genesis
        for i in 1...50 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                difficulty: UInt256.max, nonce: UInt64(i), fetcher: f
            )
            let header = VolumeImpl<Block>(node: block)
            await f.store(rawCid: header.rawCID, data: block.toData()!)
            let storer = BufferedStorer()
            try header.storeRecursively(storer: storer)
            await storer.flush(to: f)
            prev = block
        }

        let tipCID = VolumeImpl<Block>(node: prev).rawCID

        // Snapshot sync from tip
        let syncer = ChainSyncer(
            fetcher: f,
            store: { cid, data in await f.store(rawCid: cid, data: data) },
            genesisBlockHash: genesisHash,
            retentionDepth: 20
        )

        let result = try await syncer.syncSnapshot(peerTipCID: tipCID, depth: 20)

        XCTAssertEqual(result.tipBlockHash, tipCID)
        XCTAssertEqual(result.tipBlockIndex, 50)
        XCTAssertEqual(result.persisted.blocks.count, 20, "Snapshot should retain 20 blocks")
        XCTAssertEqual(result.persisted.mainChainHashes.count, 20)

        // Verify chain continuity in persisted result
        let hashes = result.persisted.mainChainHashes
        for i in 1..<hashes.count {
            let block = result.persisted.blocks[i]
            let prev = result.persisted.blocks[i - 1]
            XCTAssertEqual(block.previousBlockHash, prev.blockHash,
                "Block \(i) should point to previous block")
        }
    }

    /// Full sync with 100 blocks (complete chain validation)
    func testFullSyncWith100Blocks() async throws {
        let f = cas()
        let t = now() - 200_000
        let s = testSpec()

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: t, difficulty: UInt256.max, fetcher: f
        )
        let genesisHeader = VolumeImpl<Block>(node: genesis)
        let genesisStorer = BufferedStorer()
        try genesisHeader.storeRecursively(storer: genesisStorer)
        await genesisStorer.flush(to: f)
        let genesisHash = genesisHeader.rawCID

        var prev = genesis
        for i in 1...100 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                difficulty: UInt256.max, nonce: UInt64(i), fetcher: f
            )
            let header = VolumeImpl<Block>(node: block)
            await f.store(rawCid: header.rawCID, data: block.toData()!)
            let storer = BufferedStorer()
            try header.storeRecursively(storer: storer)
            await storer.flush(to: f)
            prev = block
        }

        let tipCID = VolumeImpl<Block>(node: prev).rawCID

        let syncer = ChainSyncer(
            fetcher: f,
            store: { cid, data in await f.store(rawCid: cid, data: data) },
            genesisBlockHash: genesisHash,
            retentionDepth: 1000
        )

        let result = try await syncer.syncFull(peerTipCID: tipCID)

        XCTAssertEqual(result.tipBlockIndex, 100)
        XCTAssertEqual(result.persisted.blocks.count, 101, "Should include genesis + 100 blocks")
        XCTAssertTrue(result.cumulativeWork > UInt256.zero)

        // Restore chain from sync result and verify it accepts new blocks
        let chain = ChainState.restore(from: result.persisted)
        let height = await chain.getHighestBlockIndex()
        XCTAssertEqual(height, 100)

        let block101 = try await BlockBuilder.buildBlock(
            previous: prev, timestamp: t + 101_000,
            difficulty: UInt256.max, nonce: 101, fetcher: f
        )
        let submitResult = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: VolumeImpl<Block>(node: block101), block: block101
        )
        XCTAssertTrue(submitResult.extendsMainChain, "Restored chain should accept new blocks")
    }
}

// ============================================================================
// MARK: - 5. Persistence Across Restart
// ============================================================================

final class RestartResilienceTests: XCTestCase {

    /// Simulate node restart: persist mid-chain, restore, continue mining
    func testPersistRestoreContinueMining() async throws {
        let f = cas()
        let t = now() - 50_000
        let s = testSpec()

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: t, difficulty: UInt256.max, fetcher: f
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        // Mine 50 blocks
        var prev = genesis
        for i in 1...50 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                difficulty: UInt256.max, nonce: UInt64(i), fetcher: f
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: VolumeImpl<Block>(node: block), block: block
            )
            prev = block
        }
        let height50 = await chain.getHighestBlockIndex()
        XCTAssertEqual(height50, 50)

        // Persist (simulate shutdown)
        let persisted = await chain.persist()
        let data = try JSONEncoder().encode(persisted)

        // Restore (simulate startup)
        let decoded = try JSONDecoder().decode(PersistedChainState.self, from: data)
        let restored = ChainState.restore(from: decoded)
        let restoredHeight = await restored.getHighestBlockIndex()
        XCTAssertEqual(restoredHeight, 50)
        let restoredTip = await restored.getMainChainTip()
        let originalTip = await chain.getMainChainTip()
        XCTAssertEqual(restoredTip, originalTip)

        // Continue mining from restored state
        for i in 51...60 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: t + Int64(i) * 1000,
                difficulty: UInt256.max, nonce: UInt64(i), fetcher: f
            )
            let result = await restored.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: VolumeImpl<Block>(node: block), block: block
            )
            XCTAssertTrue(result.extendsMainChain, "Block \(i) should extend restored chain")
            prev = block
        }
        let finalHeight = await restored.getHighestBlockIndex()
        XCTAssertEqual(finalHeight, 60)
    }

    /// Mempool persistence roundtrip
    func testMempoolPersistenceRoundTrip() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let mempool = NodeMempool(maxSize: 100)
        let kp = CryptoUtils.generateKeyPair()
        let senderAddr = addr(kp.publicKey)

        // Add some txs
        for i in 0..<5 {
            let body = TransactionBody(
                accountActions: [AccountAction(owner: senderAddr, delta: Int64(999) - Int64(1000))],
                actions: [], swapActions: [], swapClaimActions: [], genesisActions: [], peerActions: [],
                settleActions: [], signers: [senderAddr], fee: UInt64(i + 1), nonce: UInt64(i)
            )
            let _ = await mempool.add(transaction: sign(body, kp))
        }
        let mempoolCount = await mempool.count
        XCTAssertEqual(mempoolCount, 5)

        // Save
        let persistence = MempoolPersistence(dataDir: tmpDir)
        let txs = await mempool.allTransactions()
        try persistence.save(transactions: txs)

        // Load
        let loaded = persistence.load()
        XCTAssertEqual(loaded.count, 5, "Should load 5 serialized transactions")

        // Verify CIDs are preserved
        let originalCIDs = Set(txs.map { $0.body.rawCID })
        let loadedCIDs = Set(loaded.map { $0.bodyCID })
        XCTAssertEqual(originalCIDs, loadedCIDs, "Body CIDs should survive roundtrip")
    }
}

// ============================================================================
// MARK: - 6. StateStore Rollback Under Stress
// ============================================================================

final class StateStoreStressTests: XCTestCase {

    /// Apply 100 blocks then rollback 50 — verify state consistency
    func testDeepRollback() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = try StateStore(storagePath: tmpDir, chain: "test")

        // Apply 100 blocks, each modifying an account
        for i in 0..<100 {
            let changeset = StateChangeset(
                height: UInt64(i),
                blockHash: "block\(i)",
                accountUpdates: [(address: "alice", balance: UInt64(i * 100), nonce: UInt64(i))],
                timestamp: Int64(i) * 1000,
                difficulty: "1000",
                stateRoot: "state\(i)"
            )
            await store.applyBlock(changeset)
        }

        let balanceAt99 = await store.getBalance(address: "alice")
        XCTAssertEqual(balanceAt99, 9900)

        // Rollback to height 50
        await store.rollbackTo(height: 50)

        let balanceAt50 = await store.getBalance(address: "alice")
        XCTAssertEqual(balanceAt50, 5000, "Rollback should restore balance at height 50")

        let nonce = await store.getNonce(address: "alice")
        XCTAssertEqual(nonce, 50)
    }

    /// Multiple accounts, verify independent rollback
    func testMultiAccountRollback() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = try StateStore(storagePath: tmpDir, chain: "test")

        // Block 0: create alice
        await store.applyBlock(StateChangeset(
            height: 0, blockHash: "b0",
            accountUpdates: [(address: "alice", balance: 1000, nonce: 0)],
            timestamp: 0, difficulty: "1000", stateRoot: "s0"
        ))

        // Block 1: create bob, modify alice
        await store.applyBlock(StateChangeset(
            height: 1, blockHash: "b1",
            accountUpdates: [
                (address: "alice", balance: 900, nonce: 1),
                (address: "bob", balance: 100, nonce: 0)
            ],
            timestamp: 1000, difficulty: "1000", stateRoot: "s1"
        ))

        // Block 2: modify both
        await store.applyBlock(StateChangeset(
            height: 2, blockHash: "b2",
            accountUpdates: [
                (address: "alice", balance: 800, nonce: 2),
                (address: "bob", balance: 200, nonce: 1)
            ],
            timestamp: 2000, difficulty: "1000", stateRoot: "s2"
        ))

        // Rollback to height 1
        await store.rollbackTo(height: 1)

        let aliceBalance = await store.getBalance(address: "alice")
        let bobBalance = await store.getBalance(address: "bob")
        XCTAssertEqual(aliceBalance, 900)
        XCTAssertEqual(bobBalance, 100)
    }
}

// ============================================================================
// MARK: - 7. Ivy Credit Line Economics
// ============================================================================

final class IvyCreditLineEconomicsTests: XCTestCase {

    /// Verify credit lines grow with successful settlements
    func testSettlementGrowsThreshold() async throws {
        let ledger = CreditLineLedger(
            localID: PeerID(publicKey: "local"),
            baseThresholdMultiplier: 100
        )
        let peer = PeerID(publicKey: "peer1")
        await ledger.establish(with: peer)

        let line1 = await ledger.creditLine(for: peer)
        XCTAssertNotNil(line1)
        let threshold1 = line1!.threshold

        // Record a successful settlement
        await ledger.recordSettlement(peer: peer)

        let line2 = await ledger.creditLine(for: peer)
        let threshold2 = line2!.threshold
        XCTAssertGreaterThan(threshold2, threshold1, "Settlement should grow trust threshold")
    }

    /// Verify relay fees are properly tracked
    func testRelayFeeAccounting() async throws {
        let ledger = CreditLineLedger(
            localID: PeerID(publicKey: "local"),
            baseThresholdMultiplier: 100
        )
        let peer = PeerID(publicKey: "peer1")
        await ledger.establish(with: peer)

        // Earn from relaying
        await ledger.earnFromRelay(peer: peer, amount: 10)
        let line1 = await ledger.creditLine(for: peer)
        XCTAssertEqual(line1!.balance, 10, "Balance should reflect earned relay fee")

        // Charge for relay
        await ledger.chargeForRelay(peer: peer, amount: 3)
        let line2 = await ledger.creditLine(for: peer)
        XCTAssertEqual(line2!.balance, 7, "Balance should reflect charge")
    }
}

// ============================================================================
// MARK: - Block collector helper (for mining tests)
// ============================================================================

private actor BlockCollector: MinerDelegate {
    var blocks: [(Block, String)] = []
    nonisolated func minerDidProduceBlock(_ block: Block, hash: String, pendingRemovals: MinedBlockPendingRemovals) async {
        await record(block, hash)
    }
    func record(_ block: Block, _ hash: String) {
        blocks.append((block, hash))
    }
}
