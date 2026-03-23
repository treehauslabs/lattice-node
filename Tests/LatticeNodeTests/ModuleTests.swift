import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import Acorn

// MARK: - Test Helpers

private func makeWallet() -> Wallet {
    Wallet.create()
}

private func makeTx(wallet: Wallet, fee: UInt64, nonce: UInt64 = 0, recipientAddress: String? = nil) -> Transaction {
    let recipient = recipientAddress ?? makeWallet().address
    return wallet.buildTransfer(
        to: recipient,
        amount: 1,
        senderOldBalance: fee + 100,
        recipientOldBalance: 0,
        fee: fee,
        nonce: nonce
    )!
}

// ============================================================================
// MARK: - NodeMempool Tests
// ============================================================================

final class NodeMempoolTests: XCTestCase {

    func testSelectTransactionsReturnHighestFeeFirst() async {
        let mempool = NodeMempool(maxSize: 100)
        let wallet = makeWallet()

        let fees: [UInt64] = [5, 50, 10, 100, 25]
        for (i, fee) in fees.enumerated() {
            let tx = makeTx(wallet: wallet, fee: fee, nonce: UInt64(i))
            let added = await mempool.add(transaction: tx)
            XCTAssertTrue(added, "Transaction with fee \(fee) should be added")
        }

        let selected = await mempool.selectTransactions(maxCount: 5)
        XCTAssertEqual(selected.count, 5)

        var previousFee: UInt64 = UInt64.max
        for tx in selected {
            let body = tx.body.node!
            XCTAssertGreaterThanOrEqual(previousFee, body.fee,
                "Transactions should be returned in descending fee order")
            previousFee = body.fee
        }
    }

    func testPerAccountLimitEnforced() async {
        let mempool = NodeMempool(maxSize: 1000, maxPerAccount: 3)
        let wallet = makeWallet()

        for i: UInt64 in 0..<3 {
            let tx = makeTx(wallet: wallet, fee: 10, nonce: i)
            let added = await mempool.add(transaction: tx)
            XCTAssertTrue(added, "Transaction \(i) should be accepted")
        }

        let tx4 = makeTx(wallet: wallet, fee: 10, nonce: 3)
        let added = await mempool.add(transaction: tx4)
        XCTAssertFalse(added, "4th transaction from same account should be rejected")

        let count = await mempool.count
        XCTAssertEqual(count, 3)
    }

    func testReplaceByFeeWith10PercentBump() async {
        let mempool = NodeMempool(maxSize: 100)
        let wallet = makeWallet()

        let tx1 = makeTx(wallet: wallet, fee: 100, nonce: 1)
        let added1 = await mempool.add(transaction: tx1)
        XCTAssertTrue(added1)

        let txLowBump = makeTx(wallet: wallet, fee: 105, nonce: 1)
        let addedLow = await mempool.add(transaction: txLowBump)
        XCTAssertFalse(addedLow, "Fee bump of 5% should be rejected (need >10%)")

        let txHighBump = makeTx(wallet: wallet, fee: 111, nonce: 1)
        let addedHigh = await mempool.add(transaction: txHighBump)
        XCTAssertTrue(addedHigh, "Fee bump of 11% should be accepted")

        let count = await mempool.count
        XCTAssertEqual(count, 1, "RBF should replace, not add")
    }

    func testEvictionRemovesLowestFee() async {
        let mempool = NodeMempool(maxSize: 3)

        let w1 = makeWallet()
        let w2 = makeWallet()
        let w3 = makeWallet()
        let w4 = makeWallet()

        let tx10 = makeTx(wallet: w1, fee: 10, nonce: 0)
        let tx20 = makeTx(wallet: w2, fee: 20, nonce: 0)
        let tx30 = makeTx(wallet: w3, fee: 30, nonce: 0)

        let _ = await mempool.add(transaction: tx10)
        let _ = await mempool.add(transaction: tx20)
        let _ = await mempool.add(transaction: tx30)

        let countBefore = await mempool.count
        XCTAssertEqual(countBefore, 3)

        let tx25 = makeTx(wallet: w4, fee: 25, nonce: 0)
        let added = await mempool.add(transaction: tx25)
        XCTAssertTrue(added, "Tx with fee 25 should evict lowest fee and be added")

        let countAfter = await mempool.count
        XCTAssertEqual(countAfter, 3, "Mempool should remain at max size")

        let cid10 = tx10.body.rawCID
        let contains10 = await mempool.contains(txCID: cid10)
        XCTAssertFalse(contains10, "Lowest fee tx (fee=10) should have been evicted")

        let cid25 = tx25.body.rawCID
        let contains25 = await mempool.contains(txCID: cid25)
        XCTAssertTrue(contains25, "New tx (fee=25) should be present")
    }

    func testEvictionRejectsTooLowFee() async {
        let mempool = NodeMempool(maxSize: 3)

        let w1 = makeWallet()
        let w2 = makeWallet()
        let w3 = makeWallet()
        let w4 = makeWallet()

        let _ = await mempool.add(transaction: makeTx(wallet: w1, fee: 10, nonce: 0))
        let _ = await mempool.add(transaction: makeTx(wallet: w2, fee: 20, nonce: 0))
        let _ = await mempool.add(transaction: makeTx(wallet: w3, fee: 30, nonce: 0))

        let txLow = makeTx(wallet: w4, fee: 5, nonce: 0)
        let added = await mempool.add(transaction: txLow)
        XCTAssertFalse(added, "Tx with fee lower than the minimum in full mempool should be rejected")
    }

    func testPruneExpiredRemovesOldEntries() async throws {
        let mempool = NodeMempool(maxSize: 100)
        let wallet = makeWallet()

        let tx = makeTx(wallet: wallet, fee: 10, nonce: 0)
        let _ = await mempool.add(transaction: tx)

        let countBefore = await mempool.count
        XCTAssertEqual(countBefore, 1)

        try await Task.sleep(for: .milliseconds(50))

        await mempool.pruneExpired(olderThan: .milliseconds(10))

        let countAfter = await mempool.count
        XCTAssertEqual(countAfter, 0, "Expired entries should be pruned")
    }

    func testCountAndTotalFees() async {
        let mempool = NodeMempool(maxSize: 100)
        let w1 = makeWallet()
        let w2 = makeWallet()
        let w3 = makeWallet()

        let _ = await mempool.add(transaction: makeTx(wallet: w1, fee: 10, nonce: 0))
        let _ = await mempool.add(transaction: makeTx(wallet: w2, fee: 20, nonce: 0))
        let _ = await mempool.add(transaction: makeTx(wallet: w3, fee: 30, nonce: 0))

        let count = await mempool.count
        XCTAssertEqual(count, 3)

        let total = await mempool.totalFees()
        XCTAssertEqual(total, 60)
    }

    func testRemoveTransaction() async {
        let mempool = NodeMempool(maxSize: 100)
        let wallet = makeWallet()

        let tx = makeTx(wallet: wallet, fee: 50, nonce: 0)
        let cid = tx.body.rawCID
        let _ = await mempool.add(transaction: tx)

        let containsBefore = await mempool.contains(txCID: cid)
        XCTAssertTrue(containsBefore)

        await mempool.remove(txCID: cid)

        let containsAfter = await mempool.contains(txCID: cid)
        XCTAssertFalse(containsAfter)

        let count = await mempool.count
        XCTAssertEqual(count, 0)
    }

    func testDuplicateTransactionRejected() async {
        let mempool = NodeMempool(maxSize: 100)
        let wallet = makeWallet()

        let tx = makeTx(wallet: wallet, fee: 50, nonce: 0)
        let added1 = await mempool.add(transaction: tx)
        XCTAssertTrue(added1)

        let added2 = await mempool.add(transaction: tx)
        XCTAssertFalse(added2, "Duplicate transaction should be rejected")

        let count = await mempool.count
        XCTAssertEqual(count, 1)
    }

    func testSelectTransactionsRespectsMaxCount() async {
        let mempool = NodeMempool(maxSize: 100)

        for i: UInt64 in 0..<10 {
            let w = makeWallet()
            let _ = await mempool.add(transaction: makeTx(wallet: w, fee: i + 1, nonce: 0))
        }

        let selected3 = await mempool.selectTransactions(maxCount: 3)
        XCTAssertEqual(selected3.count, 3)

        let selected20 = await mempool.selectTransactions(maxCount: 20)
        XCTAssertEqual(selected20.count, 10, "Should return all when maxCount exceeds pool size")
    }

    func testFeeHistogram() async {
        let mempool = NodeMempool(maxSize: 100)

        for i: UInt64 in 1...20 {
            let w = makeWallet()
            let _ = await mempool.add(transaction: makeTx(wallet: w, fee: i * 5, nonce: 0))
        }

        let histogram = await mempool.feeHistogram(bucketCount: 5)
        XCTAssertFalse(histogram.isEmpty)

        let totalInBuckets = histogram.reduce(0) { $0 + $1.count }
        XCTAssertEqual(totalInBuckets, 20)
    }
}

// ============================================================================
// MARK: - FeeEstimator Tests
// ============================================================================

final class FeeEstimatorTests: XCTestCase {

    func testEstimateWithNoDataReturnsMinimum() async {
        let estimator = FeeEstimator()
        let fee = await estimator.estimate(confirmationTarget: 5)
        XCTAssertEqual(fee, 1, "With no data, estimator should return minimum fee of 1")
    }

    func testEstimateWithKnownDistribution() async {
        let estimator = FeeEstimator()
        await estimator.recordBlock(height: 1, transactionFees: [10, 20, 30])
        await estimator.recordBlock(height: 2, transactionFees: [15, 25, 35])
        await estimator.recordBlock(height: 3, transactionFees: [5, 10, 50])

        let highPriority = await estimator.estimate(confirmationTarget: 1)
        let lowPriority = await estimator.estimate(confirmationTarget: 20)
        XCTAssertGreaterThan(highPriority, lowPriority,
            "High priority (target=1) should have higher fee than low priority (target=20)")
    }

    func testEstimateHigherTargetProducesLowerFee() async {
        let estimator = FeeEstimator()
        for h: UInt64 in 1...20 {
            let fees = (1...10).map { _ in UInt64.random(in: 1...1000) }
            await estimator.recordBlock(height: h, transactionFees: fees)
        }

        let target1 = await estimator.estimate(confirmationTarget: 1)
        let target5 = await estimator.estimate(confirmationTarget: 5)
        let target10 = await estimator.estimate(confirmationTarget: 10)
        let target20 = await estimator.estimate(confirmationTarget: 20)

        XCTAssertGreaterThanOrEqual(target1, target5)
        XCTAssertGreaterThanOrEqual(target5, target10)
        XCTAssertGreaterThanOrEqual(target10, target20)
    }

    func testWindowRotation() async {
        let estimator = FeeEstimator(windowSize: 3)
        await estimator.recordBlock(height: 1, transactionFees: [100])
        await estimator.recordBlock(height: 2, transactionFees: [200])
        await estimator.recordBlock(height: 3, transactionFees: [300])
        await estimator.recordBlock(height: 4, transactionFees: [400])

        let count = await estimator.blockCount
        XCTAssertEqual(count, 3, "Window should evict oldest block when exceeding windowSize")
    }

    func testWindowRotationAffectsEstimates() async {
        let estimator = FeeEstimator(windowSize: 2)

        await estimator.recordBlock(height: 1, transactionFees: [1000])
        let estimateBefore = await estimator.estimate(confirmationTarget: 1)

        await estimator.recordBlock(height: 2, transactionFees: [1])
        await estimator.recordBlock(height: 3, transactionFees: [1])

        let estimateAfter = await estimator.estimate(confirmationTarget: 1)
        XCTAssertLessThan(estimateAfter, estimateBefore,
            "After high-fee block is evicted, estimate should drop")
    }

    func testHistogramWithData() async {
        let estimator = FeeEstimator()
        await estimator.recordBlock(height: 1, transactionFees: [1, 5, 10, 50, 100, 500])
        let histogram = await estimator.histogram()
        XCTAssertFalse(histogram.isEmpty, "Histogram should have entries when data exists")

        let totalCount = histogram.reduce(0) { $0 + $1.count }
        XCTAssertEqual(totalCount, 6, "Histogram should account for all fees")
    }

    func testHistogramWithNoData() async {
        let estimator = FeeEstimator()
        let histogram = await estimator.histogram()
        XCTAssertTrue(histogram.isEmpty, "Histogram should be empty with no data")
    }

    func testHistogramBucketRanges() async {
        let estimator = FeeEstimator()
        await estimator.recordBlock(height: 1, transactionFees: [5])
        await estimator.recordBlock(height: 2, transactionFees: [500])
        await estimator.recordBlock(height: 3, transactionFees: [50000])

        let histogram = await estimator.histogram()
        XCTAssertGreaterThanOrEqual(histogram.count, 3,
            "Fees spanning multiple orders of magnitude should produce multiple buckets")
    }

    func testRecordBlockWithEmptyFees() async {
        let estimator = FeeEstimator()
        await estimator.recordBlock(height: 1, transactionFees: [])
        await estimator.recordBlock(height: 2, transactionFees: [10])

        let fee = await estimator.estimate(confirmationTarget: 1)
        XCTAssertGreaterThanOrEqual(fee, 1)
    }

    func testBlockCountTracksRecordings() async {
        let estimator = FeeEstimator()
        let count0 = await estimator.blockCount
        XCTAssertEqual(count0, 0)

        await estimator.recordBlock(height: 1, transactionFees: [10])
        let count1 = await estimator.blockCount
        XCTAssertEqual(count1, 1)

        await estimator.recordBlock(height: 2, transactionFees: [20])
        let count2 = await estimator.blockCount
        XCTAssertEqual(count2, 2)
    }
}

// ============================================================================
// MARK: - BatchAuction Tests
// ============================================================================

final class BatchAuctionTests: XCTestCase {

    func testCommitAndVerify() {
        let order = Order(id: "o1", owner: "alice", side: .buy, price: 100, amount: 10)
        let salt = "secret123"
        let hash = BatchAuction.commitOrder(order: order, salt: salt)

        XCTAssertFalse(hash.isEmpty, "Commit hash should not be empty")

        let committed = BatchAuction.CommittedOrder(commitHash: hash, sender: "alice", commitHeight: 5)
        XCTAssertTrue(BatchAuction.verifyReveal(committed: committed, order: order, salt: salt))
    }

    func testVerifyRejectsBadSalt() {
        let order = Order(id: "o1", owner: "alice", side: .buy, price: 100, amount: 10)
        let salt = "secret123"
        let hash = BatchAuction.commitOrder(order: order, salt: salt)

        let committed = BatchAuction.CommittedOrder(commitHash: hash, sender: "alice", commitHeight: 5)
        XCTAssertFalse(BatchAuction.verifyReveal(committed: committed, order: order, salt: "wrong"),
            "Verification should fail with incorrect salt")
    }

    func testVerifyRejectsBadOrder() {
        let order = Order(id: "o1", owner: "alice", side: .buy, price: 100, amount: 10)
        let salt = "secret123"
        let hash = BatchAuction.commitOrder(order: order, salt: salt)

        let committed = BatchAuction.CommittedOrder(commitHash: hash, sender: "alice", commitHeight: 5)
        let differentOrder = Order(id: "o1", owner: "alice", side: .buy, price: 200, amount: 10)
        XCTAssertFalse(BatchAuction.verifyReveal(committed: committed, order: differentOrder, salt: salt),
            "Verification should fail with different order parameters")
    }

    func testCommitHashIsDeterministic() {
        let order = Order(id: "o1", owner: "alice", side: .buy, price: 100, amount: 10)
        let salt = "mysalt"
        let hash1 = BatchAuction.commitOrder(order: order, salt: salt)
        let hash2 = BatchAuction.commitOrder(order: order, salt: salt)
        XCTAssertEqual(hash1, hash2)
    }

    func testDifferentOrdersProduceDifferentHashes() {
        let order1 = Order(id: "o1", owner: "alice", side: .buy, price: 100, amount: 10)
        let order2 = Order(id: "o2", owner: "bob", side: .sell, price: 90, amount: 5)
        let salt = "same-salt"
        XCTAssertNotEqual(
            BatchAuction.commitOrder(order: order1, salt: salt),
            BatchAuction.commitOrder(order: order2, salt: salt)
        )
    }

    func testCanRevealTiming() {
        XCTAssertFalse(BatchAuction.canReveal(commitHeight: 10, currentHeight: 10),
            "Cannot reveal at commit height")
        XCTAssertFalse(BatchAuction.canReveal(commitHeight: 10, currentHeight: 11),
            "Cannot reveal 1 block after commit")
        XCTAssertFalse(BatchAuction.canReveal(commitHeight: 10, currentHeight: 12),
            "Cannot reveal 2 blocks after commit")
        XCTAssertTrue(BatchAuction.canReveal(commitHeight: 10, currentHeight: 13),
            "Can reveal exactly auctionDuration blocks after commit")
        XCTAssertTrue(BatchAuction.canReveal(commitHeight: 10, currentHeight: 100),
            "Can reveal long after commit")
    }

    func testCanRevealAtExactBoundary() {
        let commitHeight: UInt64 = 50
        let duration = BatchAuction.auctionDuration
        XCTAssertFalse(BatchAuction.canReveal(commitHeight: commitHeight, currentHeight: commitHeight + duration - 1))
        XCTAssertTrue(BatchAuction.canReveal(commitHeight: commitHeight, currentHeight: commitHeight + duration))
    }

    func testExecuteBatchMatching() {
        let buy1 = Order(id: "b1", owner: "alice", side: .buy, price: 100, amount: 10)
        let sell1 = Order(id: "s1", owner: "bob", side: .sell, price: 90, amount: 5)

        let revealed = [
            BatchAuction.RevealedOrder(order: buy1, salt: "a"),
            BatchAuction.RevealedOrder(order: sell1, salt: "b"),
        ]

        let matches = BatchAuction.executeBatch(orders: revealed)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].fillAmount, 5, "Fill amount should be min of buy/sell amounts")
        XCTAssertEqual(matches[0].fillPrice, 95, "Fill price should be midpoint of buy/sell prices")
    }

    func testExecuteBatchPartialFill() {
        let buy = Order(id: "b1", owner: "alice", side: .buy, price: 100, amount: 3)
        let sell = Order(id: "s1", owner: "bob", side: .sell, price: 80, amount: 10)

        let matches = BatchAuction.executeBatch(orders: [
            BatchAuction.RevealedOrder(order: buy, salt: "a"),
            BatchAuction.RevealedOrder(order: sell, salt: "b"),
        ])

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].fillAmount, 3, "Fill should be limited by smaller order")
    }

    func testNoMatchWhenPricesDontOverlap() {
        let buy = Order(id: "b1", owner: "alice", side: .buy, price: 80, amount: 10)
        let sell = Order(id: "s1", owner: "bob", side: .sell, price: 90, amount: 5)

        let matches = BatchAuction.executeBatch(orders: [
            BatchAuction.RevealedOrder(order: buy, salt: "a"),
            BatchAuction.RevealedOrder(order: sell, salt: "b"),
        ])
        XCTAssertTrue(matches.isEmpty, "No match when buy price < sell price")
    }

    func testMultipleMatchesInBatch() {
        let buy1 = Order(id: "b1", owner: "alice", side: .buy, price: 100, amount: 5)
        let buy2 = Order(id: "b2", owner: "carol", side: .buy, price: 95, amount: 5)
        let sell1 = Order(id: "s1", owner: "bob", side: .sell, price: 80, amount: 5)
        let sell2 = Order(id: "s2", owner: "dave", side: .sell, price: 90, amount: 5)

        let matches = BatchAuction.executeBatch(orders: [
            BatchAuction.RevealedOrder(order: buy1, salt: "a"),
            BatchAuction.RevealedOrder(order: buy2, salt: "b"),
            BatchAuction.RevealedOrder(order: sell1, salt: "c"),
            BatchAuction.RevealedOrder(order: sell2, salt: "d"),
        ])

        XCTAssertEqual(matches.count, 2, "Two buy-sell pairs should match")
    }

    func testBatchWithOnlyBuysProducesNoMatches() {
        let buy1 = Order(id: "b1", owner: "alice", side: .buy, price: 100, amount: 5)
        let buy2 = Order(id: "b2", owner: "bob", side: .buy, price: 90, amount: 5)

        let matches = BatchAuction.executeBatch(orders: [
            BatchAuction.RevealedOrder(order: buy1, salt: "a"),
            BatchAuction.RevealedOrder(order: buy2, salt: "b"),
        ])
        XCTAssertTrue(matches.isEmpty)
    }

    func testBatchWithOnlySellsProducesNoMatches() {
        let sell1 = Order(id: "s1", owner: "alice", side: .sell, price: 100, amount: 5)
        let sell2 = Order(id: "s2", owner: "bob", side: .sell, price: 90, amount: 5)

        let matches = BatchAuction.executeBatch(orders: [
            BatchAuction.RevealedOrder(order: sell1, salt: "a"),
            BatchAuction.RevealedOrder(order: sell2, salt: "b"),
        ])
        XCTAssertTrue(matches.isEmpty)
    }

    func testEmptyBatchProducesNoMatches() {
        let matches = BatchAuction.executeBatch(orders: [])
        XCTAssertTrue(matches.isEmpty)
    }

    func testBatchSortsBuysByPriceDescending() {
        let cheapBuy = Order(id: "b1", owner: "alice", side: .buy, price: 90, amount: 5)
        let expensiveBuy = Order(id: "b2", owner: "carol", side: .buy, price: 110, amount: 5)
        let sell = Order(id: "s1", owner: "bob", side: .sell, price: 85, amount: 5)

        let matches = BatchAuction.executeBatch(orders: [
            BatchAuction.RevealedOrder(order: cheapBuy, salt: "a"),
            BatchAuction.RevealedOrder(order: expensiveBuy, salt: "b"),
            BatchAuction.RevealedOrder(order: sell, salt: "c"),
        ])

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].buy.id, "b2", "Highest-priced buy should match first")
    }
}

// ============================================================================
// MARK: - Consensus Fuzz Tests
// ============================================================================

final class ConsensusFuzzTests: XCTestCase {

    func testRandomTransactionFeeOrdering() async {
        let mempool = NodeMempool(maxSize: 100)

        var wallets: [Wallet] = []
        for _ in 0..<50 {
            wallets.append(makeWallet())
        }

        var expectedFees: [UInt64] = []
        for (_, wallet) in wallets.enumerated() {
            let fee = UInt64.random(in: 1...10000)
            expectedFees.append(fee)
            let tx = makeTx(wallet: wallet, fee: fee, nonce: 0)
            let _ = await mempool.add(transaction: tx)
        }

        let selected = await mempool.selectTransactions(maxCount: 100)

        var previousFee: UInt64 = UInt64.max
        for tx in selected {
            let body = tx.body.node!
            XCTAssertLessThanOrEqual(body.fee, previousFee,
                "Selected transactions must be in descending fee order")
            previousFee = body.fee
        }
    }

    func testRandomMempoolOperationsDoNotCrash() async {
        let mempool = NodeMempool(maxSize: 20)

        var addedCIDs: [String] = []

        for _ in 0..<100 {
            let action = Int.random(in: 0..<4)

            switch action {
            case 0:
                let w = makeWallet()
                let fee = UInt64.random(in: 1...500)
                let tx = makeTx(wallet: w, fee: fee, nonce: 0)
                let _ = await mempool.add(transaction: tx)
                addedCIDs.append(tx.body.rawCID)
            case 1:
                if !addedCIDs.isEmpty {
                    let idx = Int.random(in: 0..<addedCIDs.count)
                    await mempool.remove(txCID: addedCIDs[idx])
                    addedCIDs.remove(at: idx)
                }
            case 2:
                let _ = await mempool.selectTransactions(maxCount: Int.random(in: 1...50))
            case 3:
                let _ = await mempool.totalFees()
            default:
                break
            }
        }

        let count = await mempool.count
        XCTAssertGreaterThanOrEqual(count, 0, "Count should be non-negative after random operations")
    }

    func testRandomFeeEstimatorInputs() async {
        let estimator = FeeEstimator(windowSize: 50)

        for h: UInt64 in 1...100 {
            let feeCount = Int.random(in: 0...20)
            let fees = (0..<feeCount).map { _ in UInt64.random(in: 1...100000) }
            await estimator.recordBlock(height: h, transactionFees: fees)
        }

        let blockCount = await estimator.blockCount
        XCTAssertEqual(blockCount, 50, "Window should cap at windowSize")

        for target in [1, 2, 5, 10, 20, 50] {
            let fee = await estimator.estimate(confirmationTarget: target)
            XCTAssertGreaterThanOrEqual(fee, 1, "Estimated fee should always be >= 1")
        }

        let histogram = await estimator.histogram()
        XCTAssertFalse(histogram.isEmpty, "Histogram should have data after recordings")
    }

    func testRandomBatchAuctionMatching() {
        for _ in 0..<20 {
            let orderCount = Int.random(in: 0...10)
            var orders: [BatchAuction.RevealedOrder] = []

            for i in 0..<orderCount {
                let side: OrderSide = Bool.random() ? .buy : .sell
                let price = UInt64.random(in: 1...200)
                let amount = UInt64.random(in: 1...100)
                let order = Order(id: "o\(i)", owner: "user\(i)", side: side, price: price, amount: amount)
                orders.append(BatchAuction.RevealedOrder(order: order, salt: "salt\(i)"))
            }

            let matches = BatchAuction.executeBatch(orders: orders)

            for match in matches {
                XCTAssertGreaterThanOrEqual(match.buy.price, match.sell.price,
                    "Buy price must be >= sell price for a valid match")
                XCTAssertGreaterThan(match.fillAmount, 0,
                    "Fill amount must be positive")
                XCTAssertGreaterThan(match.fillPrice, 0,
                    "Fill price must be positive")
            }
        }
    }
}
