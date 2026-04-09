import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public final class SQLiteDatabase: @unchecked Sendable {
    private let db: OpaquePointer
    private let lock = NSLock()

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let h = handle { sqlite3_close(h) }
            throw SQLiteError.openFailed(msg)
        }
        self.db = handle
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA cache_size=-65536")     // 64MB page cache (default ~2MB)
        try execute("PRAGMA mmap_size=268435456")   // 256MB memory-mapped I/O
        try execute("PRAGMA temp_store=MEMORY")     // Temp tables in memory
    }

    deinit {
        sqlite3_close(db)
    }

    @discardableResult
    public func execute(_ sql: String, params: [SQLiteValue] = []) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case .text(let s):
                sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .int(let v):
                sqlite3_bind_int64(stmt, idx, v)
            case .blob(let d):
                d.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(d.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .null:
                sqlite3_bind_null(stmt, idx)
            }
        }

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_changes(db))
    }

    public func query(_ sql: String, params: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case .text(let s):
                sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .int(let v):
                sqlite3_bind_int64(stmt, idx, v)
            case .blob(let d):
                d.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(d.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .null:
                sqlite3_bind_null(stmt, idx)
            }
        }

        var rows: [[String: SQLiteValue]] = []
        let colCount = sqlite3_column_count(stmt)

        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: SQLiteValue] = [:]
            for i in 0..<colCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                let type = sqlite3_column_type(stmt, i)
                switch type {
                case SQLITE_INTEGER:
                    row[name] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_TEXT:
                    row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    let len = sqlite3_column_bytes(stmt, i)
                    if let ptr = sqlite3_column_blob(stmt, i) {
                        row[name] = .blob(Data(bytes: ptr, count: Int(len)))
                    } else {
                        row[name] = .null
                    }
                default:
                    row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func beginTransaction() throws {
        try execute("BEGIN TRANSACTION")
    }

    public func commit() throws {
        try execute("COMMIT")
    }

    public func rollbackTransaction() throws {
        try execute("ROLLBACK")
    }
}

public enum SQLiteValue: Sendable {
    case text(String)
    case int(Int64)
    case blob(Data)
    case null

    public var textValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let v) = self { return v }
        return nil
    }

    public var blobValue: Data? {
        if case .blob(let d) = self { return d }
        return nil
    }
}

public enum SQLiteError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
}
