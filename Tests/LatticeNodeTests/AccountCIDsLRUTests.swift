import XCTest
@testable import LatticeNode

/// P0 #3: accountCIDs must LRU-cap so a long-running miner doesn't accumulate
/// millions of entries in memory forever. Safe to evict because the announce
/// coupling (P0 #4a) keeps anything we told peers about protected anyway.
final class AccountCIDsLRUTests: XCTestCase {

    func testAccountCIDsEvictOldestOverCap() async {
        let policy = BlockchainProtectionPolicy(maxAccountCIDs: 3)
        await policy.pinAccount("a")
        await policy.pinAccount("b")
        await policy.pinAccount("c")
        let afterThree = await policy.accountPinnedCount
        XCTAssertEqual(afterThree, 3)

        // Fourth insert evicts the oldest ("a") — FIFO-on-insert, LRU-on-touch.
        await policy.pinAccount("d")
        let afterFour = await policy.accountPinnedCount
        XCTAssertEqual(afterFour, 3)
        let aProtected = await policy.isAccountPinned("a")
        let dProtected = await policy.isAccountPinned("d")
        XCTAssertFalse(aProtected, "oldest entry must be evicted when over cap")
        XCTAssertTrue(dProtected, "newest entry must remain")
    }

    func testRepinBumpsLRUPosition() async {
        let policy = BlockchainProtectionPolicy(maxAccountCIDs: 3)
        await policy.pinAccount("a")
        await policy.pinAccount("b")
        await policy.pinAccount("c")
        // Touch "a" again — it should move to the tail so "b" becomes the oldest.
        await policy.pinAccount("a")
        await policy.pinAccount("d")

        let aProtected = await policy.isAccountPinned("a")
        let bProtected = await policy.isAccountPinned("b")
        XCTAssertTrue(aProtected, "recently-touched entry must survive eviction")
        XCTAssertFalse(bProtected, "oldest non-touched entry must be evicted")
    }

    func testAnnounceStillProtectsAfterLRUEviction() async {
        // Soundness guard: even if LRU drops a CID from accountCIDs, the
        // announce-expiry coupling must still hold it in `isProtected` until
        // the announce lapses — otherwise peers routed here would 404.
        let policy = BlockchainProtectionPolicy(maxAccountCIDs: 2)
        let cid = "Qm-evicted-but-announced"
        let future = UInt64(Date().timeIntervalSince1970) + 3600
        await policy.pinAccount(cid)
        await policy.recordAnnounce(cid: cid, expirySecsSinceEpoch: future)

        // Push cid out of the LRU cap.
        await policy.pinAccount("x")
        await policy.pinAccount("y")
        let stillInAccountSet = await policy.isAccountPinned(cid)
        XCTAssertFalse(stillInAccountSet, "LRU should have evicted the original CID")

        let isProtected = await policy.isProtected(cid)
        XCTAssertTrue(isProtected, "live announce must still protect after LRU eviction")
    }

    func testBatchPinEvictsOnce() async {
        let policy = BlockchainProtectionPolicy(maxAccountCIDs: 2)
        await policy.pinAccountBatch(["a", "b", "c", "d"])
        // Cap=2, so only the last two survive. Regression guard: eviction
        // must run AFTER the whole batch is inserted, not inside each step.
        let count = await policy.accountPinnedCount
        XCTAssertEqual(count, 2)
        let c = await policy.isAccountPinned("c")
        let d = await policy.isAccountPinned("d")
        XCTAssertTrue(c && d, "tail of the batch must survive")
    }
}
