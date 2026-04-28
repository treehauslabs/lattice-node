import XCTest
import UInt256
import cashew
@testable import Lattice
@testable import LatticeNode

/// Pending-pool admission / promotion / demotion behaviors introduced for the
/// cross-chain receipt-visibility race fix. NodeMempool tracks withdrawal-
/// bearing txs whose parent-chain receipts haven't arrived yet as `pending`:
/// they reserve their nonce slot but stay out of `selectTransactions`. When a
/// parent block adds receipts, `recheckPending` promotes them; on reorg,
/// `demoteValidWithdrawals` symmetrically demotes valid → pending.
final class PendingMempoolTests: XCTestCase {

    private func wallet() -> Wallet { Wallet.create() }

    private func transferTx(_ w: Wallet, fee: UInt64 = 10, nonce: UInt64 = 0) -> Transaction {
        w.buildTransfer(to: w.address, amount: 1, fee: fee, nonce: nonce)!
    }

    private func withdrawalTx(
        _ w: Wallet,
        directory: String,
        nonce: UInt128,
        demander: String,
        amountDemanded: UInt64,
        amountWithdrawn: UInt64,
        accountNonce: UInt64,
        fee: UInt64 = 10
    ) -> Transaction {
        let withdrawal = WithdrawalAction(
            withdrawer: w.address,
            nonce: nonce,
            demander: demander,
            amountDemanded: amountDemanded,
            amountWithdrawn: amountWithdrawn
        )
        let body = TransactionBody(
            accountActions: [AccountAction(owner: w.address, delta: -Int64(fee))],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [withdrawal],
            signers: [w.address],
            fee: fee,
            nonce: accountNonce,
            chainPath: [directory]
        )
        let h = HeaderImpl<TransactionBody>(node: body)
        let sig = CryptoUtils.sign(message: h.rawCID, privateKeyHex: w.privateKeyHex)!
        return Transaction(signatures: [w.publicKeyHex: sig], body: h)
    }

    // MARK: - addPendingTransaction

    func testPendingEntryReservesSlotButIsNotSelectable() async {
        let mempool = NodeMempool(maxSize: 100, maxPerAccount: 16, maxPendingPerAccount: 8)
        let w = wallet()
        let tx = transferTx(w, nonce: 0)
        let req = Set([ReceiptRequirement(receiptKey: "r1", expectedWithdrawer: w.address)])

        let r = await mempool.addPendingTransaction(tx, receiptRequirements: req)
        guard case .addedPending = r else {
            return XCTFail("pending admission should succeed: \(r)")
        }

        let count = await mempool.count
        XCTAssertEqual(count, 1, "byCID should hold the pending entry")

        let selected = await mempool.selectTransactions(maxCount: 10)
        XCTAssertTrue(selected.isEmpty, "pending entry must not be selected for inclusion")
    }

    func testPendingNonceSlotBlocksHigherNonceFromSameSender() async {
        // A pending entry reserves nonce N so a higher-nonce tx from the same
        // sender does NOT get selected ahead of it (would skip the gap).
        let mempool = NodeMempool(maxSize: 100, maxPendingPerAccount: 8)
        let w = wallet()
        let pending = transferTx(w, nonce: 0)
        _ = await mempool.addPendingTransaction(
            pending,
            receiptRequirements: [ReceiptRequirement(receiptKey: "r1", expectedWithdrawer: w.address)]
        )

        let next = transferTx(w, nonce: 1)
        let r = await mempool.addTransaction(next)
        switch r {
        case .added: break
        default: XCTFail("nonce=1 follow-on should still admit, got \(r)")
        }

        let selected = await mempool.selectTransactions(maxCount: 10)
        XCTAssertTrue(selected.isEmpty, "selection must skip both pending and its dependent follow-on")
    }

    func testPendingRejectsEmptyRequirements() async {
        let mempool = NodeMempool()
        let w = wallet()
        let r = await mempool.addPendingTransaction(transferTx(w, nonce: 0), receiptRequirements: [])
        switch r {
        case .rejected(let reason):
            XCTAssertTrue(reason.contains("no receipt requirements"), "got: \(reason)")
        default:
            XCTFail("must reject pending with no requirements: \(r)")
        }
    }

    func testHigherFeeReplacesSameNoncePending() async {
        let mempool = NodeMempool(maxPendingPerAccount: 8)
        let w = wallet()
        let req = Set([ReceiptRequirement(receiptKey: "r1", expectedWithdrawer: w.address)])

        let lowFee = transferTx(w, fee: 10, nonce: 0)
        _ = await mempool.addPendingTransaction(lowFee, receiptRequirements: req)
        let lowCID = lowFee.body.rawCID

        let highFee = transferTx(w, fee: 100, nonce: 0)
        let r = await mempool.addPendingTransaction(highFee, receiptRequirements: req)
        switch r {
        case .replacedExisting(let old):
            XCTAssertEqual(old, lowCID, "RBF should evict the old low-fee entry")
        default:
            XCTFail("higher fee at same nonce must RBF: \(r)")
        }

        let stillThereLow = await mempool.contains(txCID: lowCID)
        let stillThereHigh = await mempool.contains(txCID: highFee.body.rawCID)
        XCTAssertFalse(stillThereLow)
        XCTAssertTrue(stillThereHigh)
    }

    // MARK: - recheckPending

    func testRecheckPromotesWhenReceiptArrivesWithMatchingWithdrawer() async {
        let mempool = NodeMempool(maxPendingPerAccount: 8)
        let w = wallet()
        let tx = transferTx(w, nonce: 0)
        let cid = tx.body.rawCID
        let req = ReceiptRequirement(receiptKey: "rk", expectedWithdrawer: w.address)
        _ = await mempool.addPendingTransaction(tx, receiptRequirements: [req])

        let (promoted, evicted) = await mempool.recheckPending(
            affectedReceiptKeys: ["rk"],
            probe: { _ in w.address }
        )
        XCTAssertEqual(promoted, [cid])
        XCTAssertTrue(evicted.isEmpty)

        let selected = await mempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(selected.count, 1, "promoted entry must now be selectable")
        XCTAssertEqual(selected.first?.body.rawCID, cid)
    }

    func testRecheckEvictsOnWrongWithdrawerMismatch() async {
        let mempool = NodeMempool(maxPendingPerAccount: 8)
        let w = wallet()
        let tx = transferTx(w, nonce: 0)
        let cid = tx.body.rawCID
        let req = ReceiptRequirement(receiptKey: "rk", expectedWithdrawer: w.address)
        _ = await mempool.addPendingTransaction(tx, receiptRequirements: [req])

        let (promoted, evicted) = await mempool.recheckPending(
            affectedReceiptKeys: ["rk"],
            probe: { _ in "someoneElse" }
        )
        XCTAssertTrue(promoted.isEmpty)
        XCTAssertEqual(evicted, [cid])

        let still = await mempool.contains(txCID: cid)
        XCTAssertFalse(still, "wrong-owner mismatch must permanently evict the pending entry")
    }

    func testRecheckLeavesPendingWhenReceiptStillAbsent() async {
        let mempool = NodeMempool(maxPendingPerAccount: 8)
        let w = wallet()
        let tx = transferTx(w, nonce: 0)
        let cid = tx.body.rawCID
        _ = await mempool.addPendingTransaction(
            tx,
            receiptRequirements: [ReceiptRequirement(receiptKey: "rk", expectedWithdrawer: w.address)]
        )

        let (promoted, evicted) = await mempool.recheckPending(
            affectedReceiptKeys: ["rk"],
            probe: { _ in nil }
        )
        XCTAssertTrue(promoted.isEmpty)
        XCTAssertTrue(evicted.isEmpty)

        let stillPending = await mempool.contains(txCID: cid)
        let selected = await mempool.selectTransactions(maxCount: 10)
        XCTAssertTrue(stillPending)
        XCTAssertTrue(selected.isEmpty)
    }

    func testPendingReceiptKeysSnapshotsAllOutstanding() async {
        let mempool = NodeMempool(maxPendingPerAccount: 8)
        let w1 = wallet()
        let w2 = wallet()
        _ = await mempool.addPendingTransaction(
            transferTx(w1, nonce: 0),
            receiptRequirements: [ReceiptRequirement(receiptKey: "rA", expectedWithdrawer: w1.address)]
        )
        _ = await mempool.addPendingTransaction(
            transferTx(w2, nonce: 0),
            receiptRequirements: [
                ReceiptRequirement(receiptKey: "rB", expectedWithdrawer: w2.address),
                ReceiptRequirement(receiptKey: "rC", expectedWithdrawer: w2.address),
            ]
        )

        let keys = await mempool.pendingReceiptKeys()
        XCTAssertEqual(keys, ["rA", "rB", "rC"])
    }

    // MARK: - demoteValidWithdrawals

    func testDemotionFlipsValidBackToPendingWhenReceiptVanishes() async {
        let mempool = NodeMempool(maxPendingPerAccount: 8)
        let w = wallet()
        let tx = transferTx(w, nonce: 0)
        let cid = tx.body.rawCID
        // Admit straight as valid (simulating a withdrawal that was accepted
        // when the parent receipt was visible).
        _ = await mempool.addTransaction(tx)
        let beforeCount = await mempool.selectTransactions(maxCount: 10).count
        XCTAssertEqual(beforeCount, 1)

        // Reorg: parent rolled back, receipt no longer present (probe → nil).
        let req = ReceiptRequirement(receiptKey: "rk", expectedWithdrawer: w.address)
        let (demoted, evicted) = await mempool.demoteValidWithdrawals(
            candidates: [(cid: cid, requirements: [req])],
            probe: { _ in nil }
        )
        XCTAssertEqual(demoted, [cid])
        XCTAssertTrue(evicted.isEmpty)
        let afterSelected = await mempool.selectTransactions(maxCount: 10)
        XCTAssertTrue(afterSelected.isEmpty, "demoted entry must drop out of selection")
    }

    func testDemotionEvictsOnWrongWithdrawerAfterReorg() async {
        let mempool = NodeMempool(maxPendingPerAccount: 8)
        let w = wallet()
        let tx = transferTx(w, nonce: 0)
        let cid = tx.body.rawCID
        _ = await mempool.addTransaction(tx)

        let req = ReceiptRequirement(receiptKey: "rk", expectedWithdrawer: w.address)
        let (demoted, evicted) = await mempool.demoteValidWithdrawals(
            candidates: [(cid: cid, requirements: [req])],
            probe: { _ in "differentWithdrawer" }
        )
        XCTAssertTrue(demoted.isEmpty)
        XCTAssertEqual(evicted, [cid])
        let stillThere = await mempool.contains(txCID: cid)
        XCTAssertFalse(stillThere)
    }

    func testDemotionLeavesValidWhenReceiptStillCorrect() async {
        let mempool = NodeMempool()
        let w = wallet()
        let tx = transferTx(w, nonce: 0)
        let cid = tx.body.rawCID
        _ = await mempool.addTransaction(tx)

        let req = ReceiptRequirement(receiptKey: "rk", expectedWithdrawer: w.address)
        let (demoted, evicted) = await mempool.demoteValidWithdrawals(
            candidates: [(cid: cid, requirements: [req])],
            probe: { _ in w.address }
        )
        XCTAssertTrue(demoted.isEmpty)
        XCTAssertTrue(evicted.isEmpty)
        let selected = await mempool.selectTransactions(maxCount: 10)
        XCTAssertEqual(selected.count, 1)
    }

    // MARK: - evictByDepositKeys

    func testEvictByDepositKeysRemovesPendingEntryWithIntersectingKey() async {
        let mempool = NodeMempool(maxPendingPerAccount: 8)
        let w = wallet()
        let demander = wallet().address
        let tx = withdrawalTx(
            w,
            directory: "Child",
            nonce: 42,
            demander: demander,
            amountDemanded: 500,
            amountWithdrawn: 500,
            accountNonce: 0
        )
        let cid = tx.body.rawCID
        let depositKey = DepositKey(
            nonce: 42,
            demander: demander,
            amountDemanded: 500
        ).description
        let receiptKey = ReceiptKey(
            withdrawalAction: WithdrawalAction(
                withdrawer: w.address,
                nonce: 42,
                demander: demander,
                amountDemanded: 500,
                amountWithdrawn: 500
            ),
            directory: "Child"
        ).description

        _ = await mempool.addPendingTransaction(
            tx,
            receiptRequirements: [ReceiptRequirement(receiptKey: receiptKey, expectedWithdrawer: w.address)]
        )
        let admittedThere = await mempool.contains(txCID: cid)
        XCTAssertTrue(admittedThere)

        // Local chain accepted a different withdrawal that drained the same
        // deposit — pending entry is now permanently invalid.
        let removed = await mempool.evictByDepositKeys([depositKey])
        XCTAssertEqual(removed, [cid])
        let stillThere = await mempool.contains(txCID: cid)
        XCTAssertFalse(stillThere)
    }

    // MARK: - pending caps

    func testPendingPerAccountCapBlocksExcessAdmission() async {
        let mempool = NodeMempool(maxPerAccount: 64, maxPendingSize: 1000, maxPendingPerAccount: 2)
        let w = wallet()
        let req = Set([ReceiptRequirement(receiptKey: "r", expectedWithdrawer: w.address)])

        for n in 0..<2 {
            let r = await mempool.addPendingTransaction(transferTx(w, nonce: UInt64(n)), receiptRequirements: req)
            guard case .addedPending = r else { return XCTFail("under-cap admission must succeed: \(r)") }
        }

        let over = await mempool.addPendingTransaction(transferTx(w, nonce: 2), receiptRequirements: req)
        switch over {
        case .rejected(let reason):
            XCTAssertTrue(reason.contains("Pending per-account"), "got: \(reason)")
        default:
            XCTFail("over-cap admission must reject: \(over)")
        }
    }
}
