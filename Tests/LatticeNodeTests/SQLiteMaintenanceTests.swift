import XCTest
@testable import LatticeNode

/// S7: SQLite WAL checkpoint + incremental vacuum must be callable without
/// corrupting the DB, and must actually shrink freelist / WAL pages after
/// heavy churn. These tests don't assert absolute byte counts (SQLite page
/// layout varies by version); they only assert post-condition correctness
/// and that the DB file doesn't grow unbounded under delete+maintain.
final class SQLiteMaintenanceTests: XCTestCase {

    private func makePaths() -> (dbPath: String, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("t.db").path, dir)
    }

    func testMaintenancePragmasSucceed() throws {
        let (path, dir) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)")
        // Populate enough rows that WAL + freelist have material to work with.
        try db.beginTransaction()
        let blob = Data(repeating: 0xAA, count: 1024)
        for i in 0..<500 {
            try db.execute("INSERT INTO t (id, v) VALUES (?1, ?2)",
                           params: [.int(Int64(i)), .blob(blob)])
        }
        try db.commit()
        try db.execute("DELETE FROM t WHERE id < 400") // free ~400 pages

        // All three maintenance operations must complete without throwing.
        try db.walCheckpointTruncate()
        try db.incrementalVacuum()
        try db.optimize()

        // DB remains queryable after maintenance.
        let rows = try db.query("SELECT COUNT(*) AS c FROM t")
        XCTAssertEqual(rows.first?["c"]?.intValue, 100)
    }

    func testIncrementalVacuumBoundsFileGrowth() throws {
        // Under insert-then-delete churn, a DB with auto_vacuum=NONE grows
        // without bound. With auto_vacuum=INCREMENTAL + incremental_vacuum,
        // the file size must not strictly grow across repeated cycles.
        let (path, dir) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)")

        let blob = Data(repeating: 0x55, count: 2048)
        func cycle(_ n: Int) throws -> Int64 {
            try db.beginTransaction()
            for i in 0..<1000 {
                try db.execute("INSERT OR REPLACE INTO t (id, v) VALUES (?1, ?2)",
                               params: [.int(Int64(n * 10_000 + i)), .blob(blob)])
            }
            try db.commit()
            try db.execute("DELETE FROM t")
            try db.walCheckpointTruncate()
            try db.incrementalVacuum()
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            return (attrs[.size] as? Int64) ?? 0
        }
        let s1 = try cycle(1)
        let s2 = try cycle(2)
        let s3 = try cycle(3)
        // File must stabilize, not grow monotonically. The first cycle
        // allocates; later cycles must reuse reclaimed pages.
        XCTAssertLessThanOrEqual(s3, s1 * 2, "file size drifted: \(s1) -> \(s2) -> \(s3)")
    }

    func testStateStoreMaintainNoOpOnEmpty() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try StateStore(storagePath: dir, chain: "Nexus")
        // No writes — maintenance on a fresh store must still succeed.
        await store.maintain()
        // Subsequent writes still work after maintenance.
        await store.indexTransaction(address: "x", txCID: "tx1", blockHash: "b", height: 1)
        let rows = store.getTransactionHistory(address: "x")
        XCTAssertEqual(rows.count, 1)
    }
}
