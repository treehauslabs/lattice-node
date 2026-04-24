import XCTest
@testable import LatticeNode

/// UNSTOPPABLE_LATTICE P1 #11: `backfillBlockIndex` re-walks the entire chain
/// on every start, looping `0...height` and paying a ChainState lookup per
/// index. Every `applyBlock` already writes its own (height, hash) row into
/// `block_index` atomically, so on any steady-state restart the table already
/// has `height+1` rows and the scan is pure overhead. The fix skips the scan
/// when `StateStore.getBlockIndexCount() >= height+1`.
///
/// These tests pin the contract that the skip relies on: after N applyBlock
/// calls the count equals N, and `backfillBlockIndex`'s INSERT OR IGNORE is
/// idempotent so a double-call never corrupts the table.
final class BackfillBlockIndexTests: XCTestCase {

    private func makeStore() throws -> (StateStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StateStore(storagePath: dir, chain: "Nexus"), dir)
    }

    func testApplyBlockPopulatesBlockIndexCount() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(store.getBlockIndexCount(), 0, "Fresh store must report zero block_index rows")

        for h in 0..<5 {
            await store.applyBlock(StateChangeset(
                height: UInt64(h),
                blockHash: "hash-\(h)",
                timestamp: Int64(h) * 1000,
                difficulty: "ff",
                stateRoot: "root-\(h)"
            ))
        }

        // Steady-state invariant the skip relies on.
        XCTAssertEqual(store.getBlockIndexCount(), 5,
                       "After 5 applyBlock calls, block_index must have 5 rows — this is the signal backfillBlockIndex uses to skip the O(height) scan")
    }

    func testBackfillIsIdempotent() async throws {
        // Even if the skip ever misfires, repeated backfills must not
        // duplicate rows — the table is PRIMARY KEY on height and the insert
        // is INSERT OR IGNORE, but pin that behavior so a future refactor
        // (e.g. to INSERT OR REPLACE or plain INSERT) breaks this test, not
        // a production restart.
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let entries: [(height: UInt64, blockHash: String)] = (0..<10).map {
            (height: UInt64($0), blockHash: "hash-\($0)")
        }
        await store.backfillBlockIndex(entries)
        await store.backfillBlockIndex(entries)
        await store.backfillBlockIndex(entries)

        XCTAssertEqual(store.getBlockIndexCount(), 10,
                       "Triple backfill must not duplicate rows")
        XCTAssertEqual(store.getBlockHash(atHeight: 7), "hash-7")
    }
}
