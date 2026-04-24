import Foundation

public actor StateStore {
    private let db: SQLiteDatabase
    /// Separate read-only connection. SQLite WAL allows concurrent readers
    /// without blocking the writer. Nonisolated read methods use this to
    /// bypass actor serialization — callers no longer queue behind writes.
    private nonisolated(unsafe) let readDb: SQLiteDatabase
    private let chain: String

    public init(storagePath: URL, chain: String) throws {
        let dir = storagePath.appendingPathComponent(chain)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("state.db").path
        self.db = try SQLiteDatabase(path: dbPath)
        self.readDb = try SQLiteDatabase(path: dbPath)
        self.chain = chain
        try createTables()
    }

    private nonisolated func createTables() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS state (
                path TEXT PRIMARY KEY,
                value BLOB NOT NULL,
                height INTEGER NOT NULL
            )
        """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS tx_history (
                address TEXT NOT NULL,
                txCID TEXT NOT NULL,
                blockHash TEXT NOT NULL,
                height INTEGER NOT NULL,
                PRIMARY KEY (address, txCID)
            )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_tx_history_addr ON tx_history(address, height DESC)")

        try db.execute("""
            CREATE TABLE IF NOT EXISTS block_index (
                height INTEGER PRIMARY KEY,
                blockHash TEXT NOT NULL
            )
        """)

        // Drop legacy tables/indexes from the old duplicated-state design.
        try db.execute("DROP TABLE IF EXISTS state_diffs")
        try db.execute("DROP INDEX IF EXISTS idx_diffs_height")
        try db.execute("DROP INDEX IF EXISTS idx_diffs_height_path")
        try db.execute("DELETE FROM state WHERE path LIKE 'account:%'")
    }

    // MARK: - Transaction History

    public func indexTransaction(address: String, txCID: String, blockHash: String, height: UInt64) {
        try? db.execute(
            "INSERT OR IGNORE INTO tx_history (address, txCID, blockHash, height) VALUES (?1, ?2, ?3, ?4)",
            params: [.text(address), .text(txCID), .text(blockHash), .int(Int64(height))]
        )
    }

    /// Batch-write receipt index entries and tx history in a single SQLite transaction.
    /// Replaces N individual writes with 1 transaction commit.
    public func batchIndexReceipts(
        generalEntries: [(key: String, value: Data, height: UInt64)],
        txHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)]
    ) {
        guard !generalEntries.isEmpty || !txHistory.isEmpty else { return }
        do {
            try db.beginTransaction()
            for entry in generalEntries {
                let path = "general:\(entry.key)"
                try db.execute(
                    "INSERT OR REPLACE INTO state (path, value, height) VALUES (?1, ?2, ?3)",
                    params: [.text(path), .blob(entry.value), .int(Int64(entry.height))]
                )
            }
            for entry in txHistory {
                try db.execute(
                    "INSERT OR IGNORE INTO tx_history (address, txCID, blockHash, height) VALUES (?1, ?2, ?3, ?4)",
                    params: [.text(entry.address), .text(entry.txCID), .text(entry.blockHash), .int(Int64(entry.height))]
                )
            }
            try db.commit()
        } catch {
            try? db.rollbackTransaction()
        }
    }

    public nonisolated func getTransactionHistory(address: String, limit: Int = 50) -> [(txCID: String, blockHash: String, height: UInt64)] {
        guard let rows = try? readDb.query(
            "SELECT txCID, blockHash, height FROM tx_history WHERE address = ?1 ORDER BY height DESC LIMIT ?2",
            params: [.text(address), .int(Int64(limit))]
        ) else { return [] }
        return rows.compactMap { row in
            guard let cid = row["txCID"]?.textValue,
                  let hash = row["blockHash"]?.textValue,
                  let h = row["height"]?.intValue else { return nil }
            return (txCID: cid, blockHash: hash, height: UInt64(h))
        }
    }

    // MARK: - Maintenance

    /// Checkpoint WAL + reclaim free pages. Scheduled on a slow cadence from
    /// `startStorageMaintenanceLoop`. Without periodic `wal_checkpoint(TRUNCATE)`
    /// the WAL file grows during heavy write bursts; without `incremental_vacuum`
    /// the space freed by `pruneTransactionHistory`/`pruneDiffs` stays in the
    /// freelist and the DB file never shrinks.
    public func maintain() {
        try? db.walCheckpointTruncate()
        try? db.incrementalVacuum()
    }

    /// Drop tx_history rows below `belowHeight` for every address except
    /// `keepAddress` (the node's own address — needed for startup pin rebuild).
    /// Without this, the table grows forever on disk since every block appends
    /// one row per tx-owner and nothing ever deletes. Returns the number of rows
    /// removed so callers can log progress.
    @discardableResult
    public func pruneTransactionHistory(belowHeight: UInt64, keepAddress: String) -> Int {
        guard belowHeight > 0 else { return 0 }
        let before = (try? db.query("SELECT COUNT(*) AS c FROM tx_history WHERE height < ?1 AND address != ?2",
                                    params: [.int(Int64(belowHeight)), .text(keepAddress)])
                       .first?["c"]?.intValue) ?? 0
        try? db.execute(
            "DELETE FROM tx_history WHERE height < ?1 AND address != ?2",
            params: [.int(Int64(belowHeight)), .text(keepAddress)]
        )
        return Int(before)
    }

    /// Return all (txCID, blockHash) pairs for the given address.
    /// Used at startup to rebuild account pin sets from persisted history.
    public nonisolated func getAllTransactionCIDs(address: String) -> [(txCID: String, blockHash: String)] {
        guard let rows = try? readDb.query(
            "SELECT txCID, blockHash FROM tx_history WHERE address = ?1",
            params: [.text(address)]
        ) else { return [] }
        return rows.compactMap { row in
            guard let cid = row["txCID"]?.textValue,
                  let hash = row["blockHash"]?.textValue else { return nil }
            return (txCID: cid, blockHash: hash)
        }
    }

    // MARK: - General State

    public nonisolated func getGeneral(key: String) -> Data? {
        let path = "general:\(key)"
        guard let rows = try? readDb.query(
            "SELECT value FROM state WHERE path = ?1",
            params: [.text(path)]
        ), let row = rows.first else { return nil }
        return row["value"]?.blobValue
    }

    public func setGeneral(key: String, value: Data, atHeight: UInt64) {
        let path = "general:\(key)"
        try? db.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES (?1, ?2, ?3)",
            params: [.text(path), .blob(value), .int(Int64(atHeight))]
        )
    }

    public nonisolated func queryGeneralKeys(prefix: String) throws -> [(key: String, data: Data)] {
        let fullPrefix = "general:\(prefix)"
        let rows = try readDb.query(
            "SELECT path, value FROM state WHERE path LIKE ?1",
            params: [.text(fullPrefix + "%")]
        )
        return rows.compactMap { row in
            guard let path = row["path"]?.textValue,
                  let data = row["value"]?.blobValue else { return nil }
            let key = String(path.dropFirst("general:".count))
            return (key: key, data: data)
        }
    }

    // MARK: - Chain Metadata

    public nonisolated func getChainTip() -> String? {
        guard let rows = try? readDb.query(
            "SELECT value FROM state WHERE path = 'meta:chain-tip'"
        ), let row = rows.first else { return nil }
        return row["value"]?.blobValue.flatMap { String(data: $0, encoding: .utf8) }
    }

    public nonisolated func getHeight() -> UInt64? {
        guard let rows = try? readDb.query(
            "SELECT value FROM state WHERE path = 'meta:height'"
        ), let row = rows.first, let data = row["value"]?.blobValue else { return nil }
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        return UInt64(str)
    }

    public func setChainTip(hash: String, height: UInt64, stateRoot: String) {
        try? db.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES ('meta:chain-tip', ?1, ?2)",
            params: [.blob(Data(hash.utf8)), .int(Int64(height))]
        )
        try? db.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES ('meta:height', ?1, ?2)",
            params: [.blob(Data(String(height).utf8)), .int(Int64(height))]
        )
        try? db.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES ('meta:state-root', ?1, ?2)",
            params: [.blob(Data(stateRoot.utf8)), .int(Int64(height))]
        )
    }

    // MARK: - Block Index

    public nonisolated func getBlockHash(atHeight height: UInt64) -> String? {
        guard let rows = try? readDb.query(
            "SELECT blockHash FROM block_index WHERE height = ?1",
            params: [.int(Int64(height))]
        ), let row = rows.first else { return nil }
        return row["blockHash"]?.textValue
    }

    public nonisolated func getBlockIndexCount() -> Int {
        guard let rows = try? readDb.query("SELECT COUNT(*) AS c FROM block_index"),
              let row = rows.first,
              let c = row["c"]?.intValue else { return 0 }
        return Int(c)
    }

    public func backfillBlockIndex(_ entries: [(height: UInt64, blockHash: String)]) {
        guard !entries.isEmpty else { return }
        try? db.beginTransaction()
        for entry in entries {
            try? db.execute(
                "INSERT OR IGNORE INTO block_index (height, blockHash) VALUES (?1, ?2)",
                params: [.int(Int64(entry.height)), .text(entry.blockHash)]
            )
        }
        try? db.commit()
    }

    // MARK: - Batch Apply (Atomic)

    public func applyBlock(_ changes: StateChangeset) {
        let log = NodeLogger("statestore")
        do {
            try db.beginTransaction()
            try db.execute(
                "INSERT OR REPLACE INTO state (path, value, height) VALUES ('meta:chain-tip', ?1, ?2)",
                params: [.blob(Data(changes.blockHash.utf8)), .int(Int64(changes.height))]
            )
            try db.execute(
                "INSERT OR REPLACE INTO state (path, value, height) VALUES ('meta:height', ?1, ?2)",
                params: [.blob(Data(String(changes.height).utf8)), .int(Int64(changes.height))]
            )
            try db.execute(
                "INSERT OR REPLACE INTO state (path, value, height) VALUES ('meta:state-root', ?1, ?2)",
                params: [.blob(Data(changes.stateRoot.utf8)), .int(Int64(changes.height))]
            )
            try db.execute(
                "INSERT OR REPLACE INTO block_index (height, blockHash) VALUES (?1, ?2)",
                params: [.int(Int64(changes.height)), .text(changes.blockHash)]
            )
            try db.commit()
        } catch {
            log.error("applyBlock failed at height \(changes.height): \(error)")
            try? db.rollbackTransaction()
        }
    }
}
