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
            CREATE TABLE IF NOT EXISTS state_diffs (
                height INTEGER NOT NULL,
                path TEXT NOT NULL,
                old_value BLOB,
                PRIMARY KEY (height, path)
            )
        """)

        // Single composite index covers both height-only and (height, path) queries
        try db.execute("CREATE INDEX IF NOT EXISTS idx_diffs_height_path ON state_diffs(height DESC, path)")
        // Drop legacy redundant index if it exists (subsumed by composite index)
        try db.execute("DROP INDEX IF EXISTS idx_diffs_height")

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
    }

    // MARK: - Account State (nonisolated reads via readDb)

    public nonisolated func getBalance(address: String) -> UInt64? {
        getAccount(address: address)?.balance
    }

    public nonisolated func getNonce(address: String) -> UInt64? {
        getAccount(address: address)?.nonce
    }

    public nonisolated func getAccount(address: String) -> AccountState? {
        let path = "account:\(address)"
        guard let rows = try? readDb.query(
            "SELECT value FROM state WHERE path = ?1",
            params: [.text(path)]
        ), let row = rows.first, let data = row["value"]?.blobValue else {
            return nil
        }
        return Self.decodeAccount(data)
    }

    /// Batch fetch nonces for multiple addresses in a single SQL query.
    /// Returns [address: nonce] for found accounts; missing addresses omitted.
    public nonisolated func batchGetNonces(addresses: [String]) -> [String: UInt64] {
        guard !addresses.isEmpty else { return [:] }
        let paths = addresses.map { "account:\($0)" }
        let placeholders = (1...paths.count).map { "?\($0)" }.joined(separator: ",")
        let sql = "SELECT path, value FROM state WHERE path IN (\(placeholders))"
        let params = paths.map { SQLiteValue.text($0) }
        guard let rows = try? readDb.query(sql, params: params) else { return [:] }
        var result: [String: UInt64] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            guard let path = row["path"]?.textValue,
                  let data = row["value"]?.blobValue,
                  let account = Self.decodeAccount(data) else { continue }
            let address = String(path.dropFirst("account:".count))
            result[address] = account.nonce
        }
        return result
    }

    /// Batch fetch balances for multiple addresses in a single SQL query.
    public nonisolated func batchGetBalances(addresses: [String]) -> [String: UInt64] {
        guard !addresses.isEmpty else { return [:] }
        let paths = addresses.map { "account:\($0)" }
        let placeholders = (1...paths.count).map { "?\($0)" }.joined(separator: ",")
        let sql = "SELECT path, value FROM state WHERE path IN (\(placeholders))"
        let params = paths.map { SQLiteValue.text($0) }
        guard let rows = try? readDb.query(sql, params: params) else { return [:] }
        var result: [String: UInt64] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            guard let path = row["path"]?.textValue,
                  let data = row["value"]?.blobValue,
                  let account = Self.decodeAccount(data) else { continue }
            let address = String(path.dropFirst("account:".count))
            result[address] = account.balance
        }
        return result
    }

    /// Batch fetch raw values for multiple paths in a single SQL query.
    /// Used by applyBlock to pre-fetch old values before the write transaction.
    public nonisolated func batchGetValues(paths: [String]) -> [String: Data] {
        guard !paths.isEmpty else { return [:] }
        let placeholders = (1...paths.count).map { "?\($0)" }.joined(separator: ",")
        let sql = "SELECT path, value FROM state WHERE path IN (\(placeholders))"
        let params = paths.map { SQLiteValue.text($0) }
        guard let rows = try? readDb.query(sql, params: params) else { return [:] }
        var result: [String: Data] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            if let path = row["path"]?.textValue, let data = row["value"]?.blobValue {
                result[path] = data
            }
        }
        return result
    }

    public func setAccount(address: String, balance: UInt64, nonce: UInt64, atHeight: UInt64) {
        let path = "account:\(address)"
        let account = AccountState(balance: balance, nonce: nonce)
        let data = Self.encodeAccount(account)
        let oldValue = currentValue(forPath: path)
        try? db.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES (?1, ?2, ?3)",
            params: [.text(path), .blob(data), .int(Int64(atHeight))]
        )
        recordDiff(height: atHeight, path: path, oldValue: oldValue)
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

    public func deleteAccount(address: String) {
        let path = "account:\(address)"
        try? db.execute("DELETE FROM state WHERE path = ?1", params: [.text(path)])
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
        let oldValue = currentValue(forPath: path)
        try? db.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES (?1, ?2, ?3)",
            params: [.text(path), .blob(value), .int(Int64(atHeight))]
        )
        recordDiff(height: atHeight, path: path, oldValue: oldValue)
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
        let tTotal = ContinuousClock.now
        let tPrep = ContinuousClock.now
        let (encodedAccounts, oldValues) = prepareBlockChanges(changes)
        let dPrep = ContinuousClock.now - tPrep
        let tTxn = ContinuousClock.now
        executeBlockTransaction(changes, encodedAccounts: encodedAccounts, oldValues: oldValues)
        let dTxn = ContinuousClock.now - tTxn
        let dTotal = ContinuousClock.now - tTotal
        print("[TIMING] storeApplyBlock \(chain) #\(changes.height) accts=\(changes.accountUpdates.count) general=\(changes.generalUpdates.count) total=\(dTotal) prep=\(dPrep) txn=\(dTxn)")
    }

    private func prepareBlockChanges(_ changes: StateChangeset) -> (
        encodedAccounts: [(path: String, data: Data)],
        oldValues: [String: Data]
    ) {
        var allPaths: [String] = []
        allPaths.reserveCapacity(changes.accountUpdates.count + changes.generalUpdates.count)
        for update in changes.accountUpdates {
            allPaths.append("account:\(update.address)")
        }
        for update in changes.generalUpdates {
            allPaths.append("general:\(update.key)")
        }
        let oldValues = batchGetValues(paths: allPaths)

        let encodedAccounts: [(path: String, data: Data)] = changes.accountUpdates.map { update in
            let path = "account:\(update.address)"
            let account = AccountState(balance: update.balance, nonce: update.nonce)
            return (path: path, data: Self.encodeAccount(account))
        }

        return (encodedAccounts, oldValues)
    }

    private func executeBlockTransaction(
        _ changes: StateChangeset,
        encodedAccounts: [(path: String, data: Data)],
        oldValues: [String: Data]
    ) {
        let log = NodeLogger("statestore")
        do {
            try db.beginTransaction()

            for encoded in encodedAccounts {
                try db.execute(
                    "INSERT OR REPLACE INTO state (path, value, height) VALUES (?1, ?2, ?3)",
                    params: [.text(encoded.path), .blob(encoded.data), .int(Int64(changes.height))]
                )
                recordDiff(height: changes.height, path: encoded.path, oldValue: oldValues[encoded.path])
            }

            for update in changes.generalUpdates {
                let path = "general:\(update.key)"
                try db.execute(
                    "INSERT OR REPLACE INTO state (path, value, height) VALUES (?1, ?2, ?3)",
                    params: [.text(path), .blob(update.value), .int(Int64(changes.height))]
                )
                recordDiff(height: changes.height, path: path, oldValue: oldValues[path])
            }

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
            do {
                try db.rollbackTransaction()
            } catch {
                log.error("CRITICAL: rollback also failed — database may be corrupted: \(error)")
            }
        }
    }

    // MARK: - Reorg Support

    public func rollbackTo(height: UInt64) {
        do {
            try db.beginTransaction()

            let diffs = try db.query(
                "SELECT height, path, old_value FROM state_diffs WHERE height > ?1 ORDER BY height DESC",
                params: [.int(Int64(height))]
            )

            for diff in diffs {
                guard let path = diff["path"]?.textValue else { continue }
                if let oldData = diff["old_value"]?.blobValue {
                    try db.execute(
                        "INSERT OR REPLACE INTO state (path, value, height) VALUES (?1, ?2, ?3)",
                        params: [.text(path), .blob(oldData), .int(Int64(height))]
                    )
                } else {
                    try db.execute("DELETE FROM state WHERE path = ?1", params: [.text(path)])
                }
            }

            try db.execute("DELETE FROM state_diffs WHERE height > ?1", params: [.int(Int64(height))])

            try db.commit()
        } catch {
            try? db.rollbackTransaction()
        }
    }

    public func pruneDiffs(belowHeight: UInt64) {
        try? db.execute(
            "DELETE FROM state_diffs WHERE height < ?1",
            params: [.int(Int64(belowHeight))]
        )
    }

    // MARK: - Helpers

    private func currentValue(forPath path: String) -> Data? {
        guard let rows = try? db.query(
            "SELECT value FROM state WHERE path = ?1",
            params: [.text(path)]
        ) else { return nil }
        return rows.first?["value"]?.blobValue
    }

    private func recordDiff(height: UInt64, path: String, oldValue: Data?) {
        if let old = oldValue {
            try? db.execute(
                "INSERT OR REPLACE INTO state_diffs (height, path, old_value) VALUES (?1, ?2, ?3)",
                params: [.int(Int64(height)), .text(path), .blob(old)]
            )
        } else {
            try? db.execute(
                "INSERT OR REPLACE INTO state_diffs (height, path, old_value) VALUES (?1, ?2, NULL)",
                params: [.int(Int64(height)), .text(path)]
            )
        }
    }

    private static func encodeAccount(_ account: AccountState) -> Data {
        var data = Data(count: 16)
        data.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: account.balance.littleEndian, as: UInt64.self)
            ptr.storeBytes(of: account.nonce.littleEndian, toByteOffset: 8, as: UInt64.self)
        }
        return data
    }

    private static func decodeAccount(_ data: Data) -> AccountState? {
        // Fast path: 16-byte binary format
        if data.count == 16 {
            return data.withUnsafeBytes { ptr in
                let balance = UInt64(littleEndian: ptr.load(as: UInt64.self))
                let nonce = UInt64(littleEndian: ptr.load(fromByteOffset: 8, as: UInt64.self))
                return AccountState(balance: balance, nonce: nonce)
            }
        }
        // Fallback: JSON format from existing databases
        return try? JSONDecoder().decode(AccountState.self, from: data)
    }
}
