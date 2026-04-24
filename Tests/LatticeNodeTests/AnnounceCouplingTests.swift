import XCTest
@testable import LatticeNode

/// Announce/eviction coupling invariant (UNSTOPPABLE_LATTICE P0 #4a):
/// when we tell peers "we pin CID X until time T", eviction must not
/// drop X before T, or peers routed here will see 404s.
final class AnnounceCouplingTests: XCTestCase {

    func testFreshAnnounceProtectsCID() async {
        let policy = BlockchainProtectionPolicy()
        let cid = "QmTestCid123"
        let futureExpiry = UInt64(Date().timeIntervalSince1970) + 3600
        await policy.recordAnnounce(cid: cid, expirySecsSinceEpoch: futureExpiry)
        let isProtected = await policy.isProtected(cid)
        XCTAssertTrue(isProtected, "freshly announced CID must be protected")
    }

    func testExpiredAnnounceDoesNotProtect() async {
        let policy = BlockchainProtectionPolicy()
        let cid = "QmExpiredCid"
        let pastExpiry = UInt64(Date().timeIntervalSince1970) - 1
        await policy.recordAnnounce(cid: cid, expirySecsSinceEpoch: pastExpiry)
        let isProtected = await policy.isProtected(cid)
        XCTAssertFalse(isProtected, "expired announce must not protect CID")
    }

    func testReAnnounceExtendsButNeverShortensExpiry() async {
        let policy = BlockchainProtectionPolicy()
        let cid = "QmExtendCid"
        let longExpiry = UInt64(Date().timeIntervalSince1970) + 7200
        let shortExpiry = UInt64(Date().timeIntervalSince1970) + 60

        // Record a longer expiry first, then try to shorten it.
        await policy.recordAnnounce(cid: cid, expirySecsSinceEpoch: longExpiry)
        await policy.recordAnnounce(cid: cid, expirySecsSinceEpoch: shortExpiry)

        // Protection must still honor the longer window.
        let isProtected = await policy.isProtected(cid)
        XCTAssertTrue(isProtected, "CID must remain protected under longer expiry")

        // And a further extension must succeed.
        let evenLonger = UInt64(Date().timeIntervalSince1970) + 14400
        await policy.recordAnnounce(cid: cid, expirySecsSinceEpoch: evenLonger)
        let stillProtected = await policy.isProtected(cid)
        XCTAssertTrue(stillProtected)
    }

    func testPruneDropsExpiredEntries() async {
        let policy = BlockchainProtectionPolicy()
        let liveCid = "QmLive"
        let deadCid = "QmDead"
        let now = UInt64(Date().timeIntervalSince1970)
        await policy.recordAnnounce(cid: liveCid, expirySecsSinceEpoch: now + 3600)
        await policy.recordAnnounce(cid: deadCid, expirySecsSinceEpoch: now - 1)

        let before = await policy.announcedCount
        XCTAssertEqual(before, 2)

        await policy.pruneExpiredAnnounces()

        let after = await policy.announcedCount
        XCTAssertEqual(after, 1, "prune must drop the expired entry")
        let liveProtected = await policy.isProtected(liveCid)
        let deadProtected = await policy.isProtected(deadCid)
        XCTAssertTrue(liveProtected)
        XCTAssertFalse(deadProtected)
    }

    func testEmptyCIDIsIgnored() async {
        let policy = BlockchainProtectionPolicy()
        let futureExpiry = UInt64(Date().timeIntervalSince1970) + 3600
        await policy.recordAnnounce(cid: "", expirySecsSinceEpoch: futureExpiry)
        let count = await policy.announcedCount
        XCTAssertEqual(count, 0, "empty CID must never enter the announce map")
    }
}
