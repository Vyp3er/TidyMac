import Foundation
import SQLite3

public enum SQLiteValue: Sendable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    public var string: String? {
        if case let .text(s) = self { return s }
        return nil
    }

    public var int: Int64? {
        switch self {
        case let .int(i): return i
        case let .double(d): return Int64(d)
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case let .double(d): return d
        case let .int(i): return Double(i)
        default: return nil
        }
    }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "SQLite: \(message)" }
}

/// Minimal thread-safe SQLite wrapper (serialised through a lock).
public final class SQLiteDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(message: msg)
        }
        db = handle
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit {
        sqlite3_close(db)
    }

    private func errorMessage() -> String {
        guard let db else { return "no database" }
        return String(cString: sqlite3_errmsg(db))
    }

    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage()
            sqlite3_free(err)
            throw SQLiteError(message: msg)
        }
    }

    private func prepare(_ sql: String, _ params: [SQLiteValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(message: errorMessage())
        }
        for (index, value) in params.enumerated() {
            let i = Int32(index + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(stmt, i)
            case let .int(v): rc = sqlite3_bind_int64(stmt, i, v)
            case let .double(v): rc = sqlite3_bind_double(stmt, i, v)
            case let .text(v): rc = sqlite3_bind_text(stmt, i, v, -1, Self.transient)
            }
            if rc != SQLITE_OK {
                sqlite3_finalize(stmt)
                throw SQLiteError(message: errorMessage())
            }
        }
        return stmt
    }

    public func run(_ sql: String, _ params: [SQLiteValue] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError(message: errorMessage()) }
    }

    public func query(_ sql: String, _ params: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: SQLiteValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(message: errorMessage()) }
            var row: [String: SQLiteValue] = [:]
            for col in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, col))
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, col))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, col))
                case SQLITE_TEXT:
                    if let c = sqlite3_column_text(stmt, col) { row[name] = .text(String(cString: c)) }
                    else { row[name] = .null }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func transaction(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
}
