import Foundation

public enum ActionKind: String, Codable, Sendable, Hashable, CaseIterable {
    case move
    case rename
    case moveFolder
    case trash
    case archive

    public var displayName: String {
        switch self {
        case .move: return "Verschieben"
        case .rename: return "Umbenennen"
        case .moveFolder: return "Ordner verschieben"
        case .trash: return "In den Papierkorb"
        case .archive: return "Archivieren (ZIP)"
        }
    }
}

public enum ActionOrigin: Codable, Sendable, Hashable {
    case builtInRule(String)
    case userRule(String)
    case ai
    case duplicate
    case cleanup
    case renameScheme
    case manual

    public var displayName: String {
        switch self {
        case let .builtInRule(name): return "Regel: \(name)"
        case let .userRule(name): return "Eigene Regel: \(name)"
        case .ai: return "Claude"
        case .duplicate: return "Duplikat"
        case .cleanup: return "Aufräum-Vorschlag"
        case .renameScheme: return "Umbenennen"
        case .manual: return "Manuell"
        }
    }

    public var isAI: Bool { if case .ai = self { return true } else { return false } }
}

/// One planned file operation. Nothing happens until the user confirms and the executor runs it.
public struct PlannedAction: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var kind: ActionKind
    public var source: URL
    /// Target folder for move/rename; for archive: folder that receives the ZIP.
    public var destinationFolder: URL?
    /// New file name (nil = keep the current name).
    public var newName: String?
    public var reason: String
    public var confidence: Double
    public var origin: ActionOrigin
    public var group: String
    public var isSelected: Bool
    public var warnings: [String]
    public var sizeBytes: Int64
    /// For trashing empty folders: the executor re-checks that the folder is still empty.
    public var requiresEmptyFolder: Bool

    public init(id: UUID = UUID(), kind: ActionKind, source: URL, destinationFolder: URL?, newName: String? = nil,
                reason: String, confidence: Double, origin: ActionOrigin, group: String = "",
                isSelected: Bool = true, warnings: [String] = [], sizeBytes: Int64 = 0, requiresEmptyFolder: Bool = false) {
        self.requiresEmptyFolder = requiresEmptyFolder
        self.id = id
        self.kind = kind
        self.source = source
        self.destinationFolder = destinationFolder
        self.newName = newName
        self.reason = reason
        self.confidence = confidence
        self.origin = origin
        self.group = group
        self.isSelected = isSelected
        self.warnings = warnings
        self.sizeBytes = sizeBytes
    }

    public var finalName: String { newName ?? source.lastPathComponent }

    public var destinationURL: URL? {
        switch kind {
        case .move, .moveFolder:
            return destinationFolder?.appendingPathComponent(finalName)
        case .rename:
            return source.deletingLastPathComponent().appendingPathComponent(finalName)
        case .archive:
            return destinationFolder?.appendingPathComponent(source.lastPathComponent + ".zip")
        case .trash:
            return nil
        }
    }

    public var isRename: Bool { newName != nil && newName != source.lastPathComponent }
}

public struct AIStats: Sendable, Hashable, Codable {
    public var provider: String = ""
    public var filesSent: Int = 0
    public var foldersSent: Int = 0
    public var batches: Int = 0
    public var cacheHits: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var costUSD: Double = 0
    public var errors: [String] = []

    public init() {}
}

public struct Plan: Sendable {
    public var actions: [PlannedAction]
    /// Files no rule or AI could place confidently.
    public var unsorted: [FileItem]
    public var notes: [String]
    public var aiStats: AIStats
    public var createdAt: Date

    public init(actions: [PlannedAction] = [], unsorted: [FileItem] = [], notes: [String] = [],
                aiStats: AIStats = AIStats(), createdAt: Date = Date()) {
        self.actions = actions
        self.unsorted = unsorted
        self.notes = notes
        self.aiStats = aiStats
        self.createdAt = createdAt
    }

    /// Folders that would be created by the selected actions (shown as "Neuer Ordner").
    public func newFolders(selectedOnly: Bool = true) -> [URL: Int] {
        var result: [URL: Int] = [:]
        for action in actions where !selectedOnly || action.isSelected {
            guard action.kind == .move || action.kind == .moveFolder || action.kind == .archive,
                  let folder = action.destinationFolder else { continue }
            var current = folder.standardizedFileURL
            var missing: [URL] = []
            while !PathUtil.exists(current) {
                missing.append(current)
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
            for m in missing { result[m, default: 0] += 1 }
        }
        return result
    }
}
