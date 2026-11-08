import Foundation

/// Why something is never touched.
public enum ProtectionReason: Sendable, Hashable, Codable {
    case projectRoot(marker: String)
    case insideProject(root: String)
    case containsProject(path: String)
    case library
    case systemLocation
    case applications
    case hidden
    case bundle(ext: String)
    case appManaged(name: String)
    case appDatabase(file: String)
    case cloudSync(service: String)
    case symlink
    case alias
    case inUse
    case userExcluded(rule: String)
    case referenced(by: String)
    case incompleteDownload
    case savedWebPage
    case outsideHome

    public var description: String {
        switch self {
        case let .projectRoot(marker): return "Projektordner (erkannt an „\(marker)“)"
        case let .insideProject(root): return "Liegt in einem Projektordner (\(root))"
        case let .containsProject(path): return "Enthält einen Projektordner (\(path))"
        case .library: return "Library-Ordner (Tabu)"
        case .systemLocation: return "Systemordner (Tabu)"
        case .applications: return "Programme-Ordner (Tabu)"
        case .hidden: return "Versteckt"
        case let .bundle(ext): return "App-Bundle oder Paket (.\(ext))"
        case let .appManaged(name): return "Wird von einer App verwaltet (\(name))"
        case let .appDatabase(file): return "Enthält eine App-Datenbank (\(file))"
        case let .cloudSync(service): return "Cloud-Ordner im Sync (\(service)) – nur nach Freigabe"
        case .symlink: return "Symbolischer Link"
        case .alias: return "Alias"
        case .inUse: return "Gerade geöffnet"
        case let .userExcluded(rule): return "Eigene Ausschlussregel (\(rule))"
        case let .referenced(by): return "Wird referenziert (\(by))"
        case .incompleteDownload: return "Download noch nicht fertig"
        case .savedWebPage: return "Gespeicherte Webseite (HTML + Ordner gehören zusammen)"
        case .outsideHome: return "Außerhalb des erlaubten Bereichs"
        }
    }

    /// Short label for grouping in the UI.
    public var category: String {
        switch self {
        case .projectRoot, .insideProject, .containsProject: return "Projekte"
        case .library, .systemLocation, .applications, .outsideHome: return "System & Library"
        case .hidden: return "Versteckt"
        case .bundle, .appManaged, .appDatabase: return "Apps & Pakete"
        case .cloudSync: return "Cloud"
        case .symlink, .alias, .referenced: return "Links & Verweise"
        case .inUse, .incompleteDownload: return "In Benutzung"
        case .userExcluded: return "Eigene Ausschlüsse"
        case .savedWebPage: return "Zusammengehörig"
        }
    }
}

public struct ProtectedEntry: Sendable, Hashable, Identifiable, Codable {
    public var id: String { url.path }
    public let url: URL
    public let reason: ProtectionReason
    public let isDirectory: Bool
    public let modified: Date?

    public init(url: URL, reason: ProtectionReason, isDirectory: Bool, modified: Date? = nil) {
        self.url = url
        self.reason = reason
        self.isDirectory = isDirectory
        self.modified = modified
    }
}

/// How a scan root is treated.
public enum RootMode: String, Sendable, Codable, Hashable {
    /// Downloads, Desktop: loose files sorted, sub folders handled as units.
    case inbox
    /// A folder the user picked: loose files sorted, cohesive sub folders as units, others stay.
    case selected
    /// Only indexed (duplicates, clean-up, existing structure). Nothing sorted.
    case structure
    /// Only the files directly inside (used for the home folder itself).
    case looseOnly
}

public struct ScanRoot: Sendable, Hashable, Codable {
    public let url: URL
    public let mode: RootMode

    public init(url: URL, mode: RootMode) {
        self.url = url
        self.mode = mode
    }
}

public enum ScanTarget: Sendable, Hashable {
    /// Home folder minus taboo areas.
    case everything
    case folders([URL])
}

public struct ScanProgress: Sendable {
    public var scannedItems: Int
    public var currentPath: String
    public var phase: String

    public init(scannedItems: Int, currentPath: String, phase: String) {
        self.scannedItems = scannedItems
        self.currentPath = currentPath
        self.phase = phase
    }
}

public struct ScanResult: Sendable {
    public var roots: [ScanRoot]
    /// Loose files that may be sorted.
    public var candidates: [FileItem]
    /// Folders that may only be moved as a whole.
    public var folderCandidates: [FolderItem]
    /// Every unprotected file found (for duplicates and clean-up suggestions).
    public var allFiles: [FileItem]
    public var emptyFolders: [URL]
    public var protected: [ProtectedEntry]
    /// Targets of symlinks/aliases found while scanning (must not move).
    public var linkTargets: [String: String]
    public var scannedCount: Int
    public var duration: TimeInterval
    public var notes: [String]

    public init(roots: [ScanRoot] = [], candidates: [FileItem] = [], folderCandidates: [FolderItem] = [],
                allFiles: [FileItem] = [], emptyFolders: [URL] = [], protected: [ProtectedEntry] = [],
                linkTargets: [String: String] = [:], scannedCount: Int = 0, duration: TimeInterval = 0,
                notes: [String] = []) {
        self.roots = roots
        self.candidates = candidates
        self.folderCandidates = folderCandidates
        self.allFiles = allFiles
        self.emptyFolders = emptyFolders
        self.protected = protected
        self.linkTargets = linkTargets
        self.scannedCount = scannedCount
        self.duration = duration
        self.notes = notes
    }
}
