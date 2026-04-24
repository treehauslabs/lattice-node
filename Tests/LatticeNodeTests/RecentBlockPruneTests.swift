import XCTest
@testable import LatticeNode

/// P0 #2: recentBlockExpiry entries outlive their TTL without a GC pass,
/// pinning CIDs past the retention window. pruneExpiredRecentBlocks must
/// drop any entry whose deadline is in the past.
final class RecentBlockPruneTests: XCTestCase {

    func testPruneDropsExpiredEntriesAndKeepsLive() async {
        // Short TTL so expiry is deterministic without sleeping for an hour.
        let policy = BlockchainProtectionPolicy(recentBlockTTL: .milliseconds(50))
        await policy.addRecentBlock("cidExpireSoon")

        // Slightly longer TTL for the second entry — still short but outlives
        // our 100ms wait.
        let livePolicy = BlockchainProtectionPolicy(recentBlockTTL: .seconds(60))
        await livePolicy.addRecentBlock("cidLiveLong")

        try? await Task.sleep(for: .milliseconds(100))

        let preCount = await policy.recentBlockCount
        XCTAssertEqual(preCount, 1, "entry still present before prune")
        await policy.pruneExpiredRecentBlocks()
        let postCount = await policy.recentBlockCount
        XCTAssertEqual(postCount, 0, "prune must drop the expired entry")

        let livePre = await livePolicy.recentBlockCount
        XCTAssertEqual(livePre, 1)
        await livePolicy.pruneExpiredRecentBlocks()
        let livePost = await livePolicy.recentBlockCount
        XCTAssertEqual(livePost, 1, "prune must keep non-expired entries")
    }

    func testExpiredRecentBlockNoLongerProtected() async {
        let policy = BlockchainProtectionPolicy(recentBlockTTL: .milliseconds(50))
        await policy.addRecentBlock("cid123")
        let wasProtected = await policy.isProtected("cid123")
        XCTAssertTrue(wasProtected)

        try? await Task.sleep(for: .milliseconds(100))
        await policy.pruneExpiredRecentBlocks()

        let stillProtected = await policy.isProtected("cid123")
        XCTAssertFalse(stillProtected, "expired recent block must not be protected after prune")
    }
}
