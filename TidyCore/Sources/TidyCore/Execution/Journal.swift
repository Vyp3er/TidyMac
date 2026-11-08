import Foundation

public enum EntryStatus: String, Codable, Sendable, Hashable {
    case pending, done, failed, skipped, undone, undoFailed

    public var displayName: String {
        switch self {
        case .pending: return "Ausstehend"
        case .done: return "Erledigt"
        case .failed: return "Fehlgeschlagen"
        case .skipped: return "Übersprungen"
        case .undone: return "Rückgängig gemacht"
        case .undoFailed: return "Rückgängig fehlgeschlagen"
        }
    }
}

public struct RunRecord: Identifiable, Sendable, Hashable {
    public let id: String
    public let started: Date
    public let finished: Date?
    public let title: String
    public let source: String
    public let status: String
    public let total: Int
    public let done: Int
    public let undone: Int
}

public struct JournalEntry: Identifiable, Sendable, Hashable {
    public let id: String
    public let runID: String
    public let seq: Int
    public let kind: ActionKind
    public let sourcePath: String
    public let destPath: String?
    public let trashPath: String?
    public let archivePath: String?
    public let createdDirs: [String]
    public let status: EntryStatus
    public let error: String?
    public let reason: String
    public let confidence: Double
    public let origin: String
    public let timestamp: Date
}

public struct ReviewItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let path: String
    public let suggestedFolder: String?
    public let suggestedName: String?
    public let confidence: Double
    public let reason: String
    public let added: Date
}

/// SQLite journal of every run. Each action is written *before* it is executed (pending)
/// and updated afterwards, so even a crash leaves a trace that allows undo.
public final class Journal: @unchecked Sendable {
    let db: SQLiteDatabase

    public init(url: URL) throws {
        db = try SQLiteDatabase(url: url)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS runs (
            id TEXT PRIMARY KEY, started REAL NOT NULL, finished REAL, title TEXT NOT NULL,
            source TEXT NOT NULL, status TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS actions (
            id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, seq INTEGER NOT NULL,
            kind TEXT NOT NULL, source_path TEXT NOT NULL, dest_path TEXT, trash_path TEXT, archive_path TEXT,
            created_dirs TEXT, status TEXT NOT NULL, error TEXT, reason TEXT, confidence REAL, origin TEXT, ts REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS actions_run ON actions(run_id, seq);
        CREATE TABLE IF NOT EXISTS review_items (
            id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, suggested_folder TEXT, suggested_name TEXT,
            confidence REAL, reason TEXT, added REAL NOT NULL
        );
        """)
    }

    // MARK: Runs

    public func beginRun(title: String, source: String) -> String {
        let id = UUID().uuidString
        try? db.run("INSERT INTO runs (id, started, title, source, status) VALUES (?, ?, ?, ?, 'running')",
                    [.text(id), .double(Date().timeIntervalSince1970), .text(title), .text(source)])
        return id
    }

    public func finishRun(_ id: String, status: String) {
        try? db.run("UPDATE runs SET finished = ?, status = ? WHERE id = ?",
                    [.double(Date().timeIntervalSince1970), .text(status), .text(id)])
    }

    public func setRunStatus(_ id: String, _ status: String) {
        try? db.run("UPDATE runs SET status = ? WHERE id = ?", [.text(status), .text(id)])
    }

    public func runs(limit: Int = 50) -> [RunRecord] {
        let sql = """
        SELECT r.id, r.started, r.finished, r.title, r.source, r.status,
               (SELECT COUNT(*) FROM actions a WHERE a.run_id = r.id) AS total,
               (SELECT COUNT(*) FROM actions a WHERE a.run_id = r.id AND a.status = 'done') AS done,
               (SELECT COUNT(*) FROM actions a WHERE a.run_id = r.id AND a.status = 'undone') AS undone
        FROM runs r ORDER BY r.started DESC LIMIT ?
        """
        let rows = (try? db.query(sql, [.int(Int64(limit))])) ?? []
        return rows.compactMap { row in
            guard let id = row["id"]?.string, let started = row["started"]?.double else { return nil }
            return RunRecord(id: id, started: Date(timeIntervalSince1970: started),
                             finished: row["finished"]?.double.map(Date.init(timeIntervalSince1970:)),
                             title: row["title"]?.string ?? "", source: row["source"]?.string ?? "",
                             status: row["status"]?.string ?? "", total: Int(row["total"]?.int ?? 0),
                             done: Int(row["done"]?.int ?? 0), undone: Int(row["undone"]?.int ?? 0))
        }
    }

    // MARK: Entries

    public func recordPending(runID: String, seq: Int, action: PlannedAction) -> String {
        let id = UUID().uuidString
        try? db.run("""
        INSERT INTO actions (id, run_id, seq, kind, source_path, dest_path, status, reason, confidence, origin, ts)
        VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?)
        """, [.text(id), .text(runID), .int(Int64(seq)), .text(action.kind.rawValue), .text(action.source.path),
              action.destinationURL.map { .text($0.path) } ?? .null, .text(action.reason),
              .double(action.confidence), .text(action.origin.displayName), .double(Date().timeIntervalSince1970)])
        return id
    }

    public func markDone(_ id: String, destPath: String?, trashPath: String? = nil, archivePath: String? = nil, createdDirs: [URL] = []) {
        let dirs = (try? JSONEncoder().encode(createdDirs.map(\.path))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try? db.run("UPDATE actions SET status = 'done', dest_path = ?, trash_path = ?, archive_path = ?, created_dirs = ?, ts = ? WHERE id = ?",
                    [destPath.map { .text($0) } ?? .null, trashPath.map { .text($0) } ?? .null,
                     archivePath.map { .text($0) } ?? .null, .text(dirs), .double(Date().timeIntervalSince1970), .text(id)])
    }

    public func mark(_ id: String, status: EntryStatus, error: String? = nil) {
        try? db.run("UPDATE actions SET status = ?, error = ?, ts = ? WHERE id = ?",
                    [.text(status.rawValue), error.map { .text($0) } ?? .null, .double(Date().timeIntervalSince1970), .text(id)])
    }

    public func entries(runID: String) -> [JournalEntry] {
        let rows = (try? db.query("SELECT * FROM actions WHERE run_id = ? ORDER BY seq", [.text(runID)])) ?? []
        return rows.compactMap(Self.entry(from:))
    }

    public func entry(id: String) -> JournalEntry? {
        (try? db.query("SELECT * FROM actions WHERE id = ?", [.text(id)]))?.first.flatMap(Self.entry(from:))
    }

    static func entry(from row: [String: SQLiteValue]) -> JournalEntry? {
        guard let id = row["id"]?.string, let runID = row["run_id"]?.string,
              let kind = row["kind"]?.string.flatMap(ActionKind.init(rawValue:)),
              let source = row["source_path"]?.string else { return nil }
        let dirs = row["created_dirs"]?.string.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return JournalEntry(id: id, runID: runID, seq: Int(row["seq"]?.int ?? 0), kind: kind, sourcePath: source,
                            destPath: row["dest_path"]?.string, trashPath: row["trash_path"]?.string,
                            archivePath: row["archive_path"]?.string, createdDirs: dirs,
                            status: row["status"]?.string.flatMap(EntryStatus.init(rawValue:)) ?? .pending,
                            error: row["error"]?.string, reason: row["reason"]?.string ?? "",
                            confidence: row["confidence"]?.double ?? 0, origin: row["origin"]?.string ?? "",
                            timestamp: Date(timeIntervalSince1970: row["ts"]?.double ?? 0))
    }

    // MARK: Review queue (background mode)

    public func addReviewItem(path: String, suggestedFolder: String?, suggestedName: String?, confidence: Double, reason: String) {
        try? db.run("""
        INSERT OR REPLACE INTO review_items (id, path, suggested_folder, suggested_name, confidence, reason, added)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, [.text(UUID().uuidString), .text(path), suggestedFolder.map { .text($0) } ?? .null,
              suggestedName.map { .text($0) } ?? .null, .double(confidence), .text(reason), .double(Date().timeIntervalSince1970)])
    }

    public func reviewItems() -> [ReviewItem] {
        let rows = (try? db.query("SELECT * FROM review_items ORDER BY added DESC")) ?? []
        return rows.compactMap { row in
            guard let id = row["id"]?.string, let path = row["path"]?.string else { return nil }
            return ReviewItem(id: id, path: path, suggestedFolder: row["suggested_folder"]?.string,
                              suggestedName: row["suggested_name"]?.string, confidence: row["confidence"]?.double ?? 0,
                              reason: row["reason"]?.string ?? "", added: Date(timeIntervalSince1970: row["added"]?.double ?? 0))
        }
    }

    public func removeReviewItem(id: String) {
        try? db.run("DELETE FROM review_items WHERE id = ?", [.text(id)])
    }

    public func removeReviewItem(path: String) {
        try? db.run("DELETE FROM review_items WHERE path = ?", [.text(path)])
    }
}
