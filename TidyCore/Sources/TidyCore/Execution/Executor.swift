import Foundation

public struct ExecutionResult: Sendable {
    public var runID: String
    public var done = 0
    public var failed = 0
    public var skipped = 0
    public var messages: [String] = []

    public var summary: String {
        var parts = ["\(done) erledigt"]
        if skipped > 0 { parts.append("\(skipped) übersprungen") }
        if failed > 0 { parts.append("\(failed) fehlgeschlagen") }
        return parts.joined(separator: ", ")
    }
}

public struct UndoResult: Sendable {
    public var restored = 0
    public var failed = 0
    public var messages: [String] = []
}

/// Runs confirmed actions. Every action is re-validated right before it runs (protection,
/// open files, destination), names never overwrite, deletion always goes to the Trash.
public final class Executor: @unchecked Sendable {
    public let home: HomeContext
    public let policy: ProtectionPolicy
    public let journal: Journal
    public let trash: TrashService
    public let openFiles: OpenFilesProvider
    public let archiver: Archiver

    public init(home: HomeContext, policy: ProtectionPolicy, journal: Journal, trash: TrashService = SystemTrash(),
                openFiles: OpenFilesProvider = ProcOpenFilesProvider(), archiver: Archiver = Archiver()) {
        self.home = home
        self.policy = policy
        self.journal = journal
        self.trash = trash
        self.openFiles = openFiles
        self.archiver = archiver
    }

    static func order(_ kind: ActionKind) -> Int {
        switch kind {
        case .rename: return 0
        case .move: return 1
        case .moveFolder: return 2
        case .archive: return 3
        case .trash: return 4
        }
    }

    public func execute(_ actions: [PlannedAction], title: String, source: String = "manual",
                        progress: (@Sendable (Int, Int) -> Void)? = nil) -> ExecutionResult {
        let selected = actions.filter(\.isSelected).enumerated()
            .sorted { (Self.order($0.element.kind), $0.offset) < (Self.order($1.element.kind), $1.offset) }
            .map(\.element)
        let runID = journal.beginRun(title: title, source: source)
        var result = ExecutionResult(runID: runID)
        policy.clearCache()
        let open = openFiles.openPaths()

        for (seq, action) in selected.enumerated() {
            progress?(seq, selected.count)
            let entryID = journal.recordPending(runID: runID, seq: seq, action: action)
            if let problem = validate(action, open: open) {
                journal.mark(entryID, status: .skipped, error: problem)
                result.skipped += 1
                result.messages.append("\(action.source.lastPathComponent): \(problem)")
                continue
            }
            do {
                try perform(action, entryID: entryID)
                result.done += 1
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                journal.mark(entryID, status: .failed, error: message)
                result.failed += 1
                result.messages.append("\(action.source.lastPathComponent): \(message)")
                Log.exec.error("action failed: \(message, privacy: .public)")
            }
        }
        progress?(selected.count, selected.count)
        journal.finishRun(runID, status: result.failed > 0 ? "partial" : "done")
        return result
    }

    /// Returns a reason if the action must not run (anymore).
    func validate(_ action: PlannedAction, open: Set<String>) -> String? {
        let source = action.source
        guard PathUtil.exists(source) else { return "Quelle existiert nicht mehr" }
        if PathUtil.isSymlink(source) { return ProtectionReason.symlink.description }
        if let reason = policy.itemProtection(source) {
            // A stale, unfinished download may go to the Trash (only via clean-up, only if not open).
            let staleDownload = action.kind == .trash && reason == .incompleteDownload
            // A downloaded copy of an app (in Downloads) may go to the Trash after confirmation.
            let appCopy = action.kind == .trash && reason == .bundle(ext: "app") && policy.isInsideWholeMoveInbox(source)
            if !staleDownload && !appCopy { return reason.description }
        }
        if let reason = policy.ancestorProtection(of: source) { return reason.description }
        let isDir = PathUtil.isDirectory(source)
        if isDir {
            let packageDoc = ProtectionPolicy.movableDocumentPackages.contains(FileNameTools.split(source.lastPathComponent).ext.lowercased())
            if !packageDoc {
                switch policy.directoryClass(source) {
                case let .protected(reason):
                    return reason.description
                case .movableProject:
                    if action.kind != .moveFolder { return "Projektordner wird nur als Ganzes verschoben" }
                case .normal:
                    break
                }
            }
        }
        if isDir && (action.kind == .moveFolder || action.kind == .trash || action.kind == .archive),
           !ProtectionPolicy.movableDocumentPackages.contains(FileNameTools.split(source.lastPathComponent).ext.lowercased()),
           let (inner, reason) = policy.protectedDescendant(in: source) {
            return "Enthält geschützten Inhalt: \(home.abbreviate(inner)) – \(reason.description)"
        }
        if OpenFileCheck.isInUse(source, open: open) { return ProtectionReason.inUse.description }
        if action.requiresEmptyFolder {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? ["?"]
            if !entries.allSatisfy({ $0 == ".DS_Store" || $0 == ".localized" }) { return "Ordner ist nicht mehr leer" }
        }

        switch action.kind {
        case .move, .moveFolder, .archive:
            guard let folder = action.destinationFolder else { return "Kein Ziel" }
            if let reason = policy.destinationProtection(for: folder) { return "Ziel geschützt: \(reason.description)" }
            if PathUtil.isDescendant(folder, of: source) { return "Ziel liegt im Ordner selbst" }
            if action.kind == .moveFolder && !isDir { return "Kein Ordner" }
        case .rename:
            guard let name = action.newName, !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
                return "Ungültiger neuer Name"
            }
        case .trash:
            break
        }
        if let name = action.newName, name.contains("/") || name.contains(":") || name.hasPrefix(".") || name.isEmpty {
            return "Ungültiger neuer Name"
        }
        return nil
    }

    func perform(_ action: PlannedAction, entryID: String) throws {
        switch action.kind {
        case .move, .moveFolder:
            guard let folder = action.destinationFolder else { throw FileOperationError.system("Kein Ziel") }
            let created = try SafeFileOps.createFolders(folder)
            do {
                let final = try SafeFileOps.moveAvoidingConflicts(action.source, toFolder: folder, name: action.finalName)
                journal.markDone(entryID, destPath: final.path, createdDirs: created)
            } catch {
                for dir in created.reversed() { SafeFileOps.removeIfEmpty(dir) }
                throw error
            }
        case .rename:
            let folder = action.source.deletingLastPathComponent()
            let final = try SafeFileOps.moveAvoidingConflicts(action.source, toFolder: folder, name: action.finalName)
            journal.markDone(entryID, destPath: final.path)
        case .trash:
            let trashed = try trash.trash(action.source)
            journal.markDone(entryID, destPath: nil, trashPath: trashed.path)
        case .archive:
            guard let folder = action.destinationFolder else { throw FileOperationError.system("Kein Archivordner") }
            let created = try SafeFileOps.createFolders(folder)
            let zip: URL
            do {
                zip = try archiver.zip(action.source, intoFolder: folder)
            } catch {
                for dir in created.reversed() { SafeFileOps.removeIfEmpty(dir) }
                throw error
            }
            let trashed = try trash.trash(action.source)
            journal.markDone(entryID, destPath: zip.path, trashPath: trashed.path, archivePath: zip.path, createdDirs: created)
        }
    }

    // MARK: Undo

    public func undoRun(_ runID: String) -> UndoResult {
        var result = UndoResult()
        let entries = journal.entries(runID: runID).filter { $0.status == .done }.sorted { $0.seq > $1.seq }
        for entry in entries {
            do {
                try undo(entry)
                result.restored += 1
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                journal.mark(entry.id, status: .undoFailed, error: message)
                result.failed += 1
                result.messages.append("\(URL(fileURLWithPath: entry.sourcePath).lastPathComponent): \(message)")
            }
        }
        journal.setRunStatus(runID, result.failed > 0 ? "partially-undone" : "undone")
        return result
    }

    public func undoEntry(_ entryID: String) -> UndoResult {
        var result = UndoResult()
        guard let entry = journal.entry(id: entryID), entry.status == .done else {
            result.messages.append("Aktion kann nicht rückgängig gemacht werden.")
            result.failed = 1
            return result
        }
        do {
            try undo(entry)
            result.restored = 1
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            journal.mark(entry.id, status: .undoFailed, error: message)
            result.failed = 1
            result.messages.append(message)
        }
        return result
    }

    func undo(_ entry: JournalEntry) throws {
        let original = URL(fileURLWithPath: entry.sourcePath)
        switch entry.kind {
        case .move, .moveFolder, .rename:
            guard let dest = entry.destPath.map(URL.init(fileURLWithPath:)), PathUtil.exists(dest) else {
                throw FileOperationError.sourceMissing(entry.destPath ?? "?")
            }
            try restore(dest, to: original)
            for dir in entry.createdDirs.reversed() { SafeFileOps.removeIfEmpty(URL(fileURLWithPath: dir)) }
        case .trash:
            guard let trashed = entry.trashPath.map(URL.init(fileURLWithPath:)), PathUtil.exists(trashed) else {
                throw FileOperationError.sourceMissing("Nicht mehr im Papierkorb")
            }
            try restore(trashed, to: original)
        case .archive:
            guard let trashed = entry.trashPath.map(URL.init(fileURLWithPath:)), PathUtil.exists(trashed) else {
                throw FileOperationError.sourceMissing("Original nicht mehr im Papierkorb")
            }
            try restore(trashed, to: original)
            if let zip = entry.archivePath.map(URL.init(fileURLWithPath:)), PathUtil.exists(zip) {
                _ = try? trash.trash(zip)
            }
            for dir in entry.createdDirs.reversed() { SafeFileOps.removeIfEmpty(URL(fileURLWithPath: dir)) }
        }
        journal.mark(entry.id, status: .undone)
    }

    /// Moves `item` back to `original`. If the original place is taken meanwhile, the item
    /// gets a unique name next to it — nothing is overwritten.
    func restore(_ item: URL, to original: URL) throws {
        let folder = original.deletingLastPathComponent()
        if !PathUtil.isDirectory(folder) { _ = try SafeFileOps.createFolders(folder) }
        _ = try SafeFileOps.moveAvoidingConflicts(item, toFolder: folder, name: original.lastPathComponent)
    }
}

/// Creates verified ZIP archives with `ditto` (keeps macOS metadata).
public struct Archiver: Sendable {
    public init() {}

    public func zip(_ source: URL, intoFolder folder: URL) throws -> URL {
        let name = FileNameTools.uniqueName(for: source.lastPathComponent + ".zip", in: folder)
        let dest = folder.appendingPathComponent(name)
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, dest.path])
        guard let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else {
            try? FileManager.default.removeItem(at: dest)
            throw FileOperationError.archiveFailed("ZIP ist leer")
        }
        do {
            try run("/usr/bin/unzip", ["-tqq", dest.path])
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw FileOperationError.archiveFailed("ZIP-Prüfung fehlgeschlagen")
        }
        return dest
    }

    func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FileOperationError.archiveFailed("\(URL(fileURLWithPath: tool).lastPathComponent) Status \(process.terminationStatus)")
        }
    }
}
