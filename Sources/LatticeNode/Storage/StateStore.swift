import Foundation

public actor StateStore {
    private let db: SQLiteDatabase
    private let chain: String

    public init(storagePath: URL, chain: String) throws {
        let dir = storagePath.appendingPathComponent(chain)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("state.db").path
        self.db = try SQLiteDatabase(path: dbPath)
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

        try db.execute("""
            CREATE TABLE IF NOT EXISTS blocks (
                height INTEGER PRIMARY KEY,
                hash TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                difficulty TEXT NOT NULL
            )
        """)

        try db.execute("CREATE INDEX IF NOT EXISTS idx_blocks_hash ON blocks(hash)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_diffs_height ON state_diffs(height)")
    }

    // MARK: - Account State

    public func getBalance(address: String) -> UInt64? {
        let path = "account:\(address)"
        guard let rows = try? db.query(
            "SELECT value FROM state WHERE path = ?1",
            params: [.text(path)]
        ), let row = rows.first, let data = row["value"]?.blobValue else {
            return nil
        }
        return decodeAccount(data)?.balance
    }

    public func getNonce(address: String) -> UInt64? {
        let path = "account:\(address)"
        guard let rows = try? db.query(
            "SELECT value FROM state WHERE path = ?1",
            params: [.text(path)]
        ), let row = rows.first, let data = row["value"]?.blobValue else {
            return nil
        }
        return decodeAccount(data)?.nonce
    }

    public func getAccount(address: String) -> AccountState? {
        let path = "account:\(address)"
        guard let rows = try? db.query(
            "SELECT value FROM state WHERE path = ?1",
            params: [.text(path)]
        ), let row = rows.first, let data = row["value"]?.blobValue else {
            return nil
        }
        return decodeAccount(data)
    }

    public func setAccount(address: String, balance: UInt64, nonce: UInt64, atHeight: UInt64) {
        let path = "account:\(address)"
        let account = AccountState(balance: balance, nonce: nonce)
        guard let data = encodeAccount(account) else { return }

        let oldValue = currentValue(forPath: path)
        try? db.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES (?1, ?2, ?3)",
            params: [.text(path), .blob(data), .int(Int64(atHeight))]
        )
        recordDiff(height: atHeight, path: path, oldValue: oldValue)
    }

    // MARK: - Block References

    public func getBlockHash(atHeight height: UInt64) -> String? {
        guard let rows = try? db.query(
            "SELECT hash FROM blocks WHERE height = ?1",
            params: [.int(Int64(height))]
        ), let row = rows.first else { return nil }
        return row["hash"]?.textValue
    }

    public func getBlockHeight(forHash hash: String) -> UInt64? {
        guard let rows = try? db.query(
            "SELECT height FROM blocks WHERE hash = ?1",
            params: [.text(hash)]
        ), let row = rows.first, let h = row["height"]?.intValue else { return nil }
        return UInt64(h)
    }

    public func setBlock(height: UInt64, hash: String, timestamp: Int64, difficulty: String) {
        try? db.execute(
            "INSERT OR REPLACE INTO blocks (height, hash, timestamp, difficulty) VALUES (?1, ?2, ?3, ?4)",
            params: [.int(Int64(height)), .text(hash), .int(timestamp), .text(difficulty)]
        )
    }

    public func getLatestBlock() -> BlockRef? {
        guard let rows = try? db.query(
            "SELECT height, hash, timestamp, difficulty FROM blocks ORDER BY height DESC LIMIT 1"
        ), let row = rows.first else { return nil }
        guard let h = row["height"]?.intValue,
              let hash = row["hash"]?.textValue,
              let ts = row["timestamp"]?.intValue,
              let diff = row["difficulty"]?.textValue else { return nil }
        return BlockRef(hash: hash, height: UInt64(h), timestamp: ts, difficulty: diff)
    }

    // MARK: - General State

    public func getGeneral(key: String) -> Data? {
        let path = "general:\(key)"
        guard let rows = try? db.query(
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

    // MARK: - Chain Metadata

    public func getChainTip() -> String? {
        guard let rows = try? db.query(
            "SELECT value FROM state WHERE path = 'meta:chain-tip'"
        ), let row = rows.first else { return nil }
        return row["value"]?.blobValue.flatMap { String(data: $0, encoding: .utf8) }
    }

    public func getHeight() -> UInt64? {
        guard let rows = try? db.query(
            "SELECT value FROM state WHERE path = 'meta:height'"
        ), let row = rows.first, let data = row["value"]?.blobValue else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    }

    public func setChainTip(hash: String, height: UInt64, stateRoot: String) {
        let heightData = withUnsafeBytes(of: height) { Data($0) }
        try? db.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES ('meta:chain-tip', ?1, ?2)",
            params: [.blob(Data(hash.utf8)), .int(Int64(height))]
        )
        try? db.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES ('meta:height', ?1, ?2)",
            params: [.blob(heightData), .int(Int64(height))]
        )
        try? db.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES ('meta:state-root', ?1, ?2)",
            params: [.blob(Data(stateRoot.utf8)), .int(Int64(height))]
        )
    }

    // MARK: - Batch Apply (Atomic)

    public func applyBlock(_ changes: StateChangeset) {
        do {
            try db.beginTransaction()

            setBlock(
                height: changes.height,
                hash: changes.blockHash,
                timestamp: changes.timestamp,
                difficulty: changes.difficulty
            )

            for update in changes.accountUpdates {
                setAccount(
                    address: update.address,
                    balance: update.balance,
                    nonce: update.nonce,
                    atHeight: changes.height
                )
            }

            for update in changes.generalUpdates {
                setGeneral(key: update.key, value: update.value, atHeight: changes.height)
            }

            setChainTip(
                hash: changes.blockHash,
                height: changes.height,
                stateRoot: changes.stateRoot
            )

            try db.commit()
        } catch {
            try? db.rollbackTransaction()
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
            try db.execute("DELETE FROM blocks WHERE height > ?1", params: [.int(Int64(height))])

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

    private func encodeAccount(_ account: AccountState) -> Data? {
        try? JSONEncoder().encode(account)
    }

    private func decodeAccount(_ data: Data) -> AccountState? {
        try? JSONDecoder().decode(AccountState.self, from: data)
    }
}
