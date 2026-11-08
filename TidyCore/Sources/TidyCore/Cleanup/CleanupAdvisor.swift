import Foundation

public enum CleanupCategory: String, Sendable, Codable, CaseIterable, Hashable {
    case large, unused, oldInstaller, emptyFolder, cacheLike, extractedArchive, staleDownload

    public var displayName: String {
        switch self {
        case .large: return "Große Dateien"
        case .unused: return "Lange nicht geöffnet"
        case .oldInstaller: return "Alte Installer"
        case .emptyFolder: return "Leere Ordner"
        case .cacheLike: return "Cache & Reste"
        case .extractedArchive: return "Bereits entpackte Archive"
        case .staleDownload: return "Abgebrochene Downloads"
        }
    }
}

public enum CleanupChoice: String, Sendable, Codable, CaseIterable, Hashable {
    case keep, trash, archive

    public var displayName: String {
        switch self {
        case .keep: return "Behalten"
        case .trash: return "Papierkorb"
        case .archive: return "Archivieren"
        }
    }
}

public struct CleanupSuggestion: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let url: URL
    public let isDirectory: Bool
    public let size: Int64
    public let lastUsed: Date?
    public let category: CleanupCategory
    public let reason: String
    /// Always "keep" initially: clean-up never happens automatically.
    public var choice: CleanupChoice
    public var allowsArchive: Bool { category != .emptyFolder && category != .cacheLike && category != .staleDownload }

    public init(url: URL, isDirectory: Bool, size: Int64, lastUsed: Date?, category: CleanupCategory, reason: String) {
        self.id = UUID()
        self.url = url
        self.isDirectory = isDirectory
        self.size = size
        self.lastUsed = lastUsed
        self.category = category
        self.reason = reason
        self.choice = .keep
    }
}

public struct CleanupAdvisor: Sendable {
    public let home: HomeContext
    public let settings: CleanupSettings
    public var now: Date

    public init(home: HomeContext, settings: CleanupSettings, now: Date = Date()) {
        self.home = home
        self.settings = settings
        self.now = now
    }

    static let cacheLikeNames: Set<String> = ["thumbs.db", "desktop.ini", "ehthumbs.db"]
    static let cacheLikeExtensions: Set<String> = ["tmp", "temp", "bak", "old", "crash", "dmp", "swp"]

    public func suggestions(for scan: ScanResult) async -> [CleanupSuggestion] {
        let candidates = scan.allFiles.filter { $0.context != .inUnit }
        let enriched = await MetadataEnricher.enrich(candidates.filter { $0.size >= Int64(settings.minSizeForUnusedMB) * 1_048_576 || $0.kind == .diskImage || $0.kind == .installer })
        let enrichedByPath = Dictionary(enriched.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [CleanupSuggestion] = []
        var used = Set<String>()
        func add(_ s: CleanupSuggestion) {
            guard used.insert(s.url.path).inserted else { return }
            result.append(s)
        }
        let day = 86_400.0
        let largeBytes = Int64(settings.largeFileMB) * 1_048_576
        let unusedLimit = Double(settings.unusedDays) * day
        let installerLimit = Double(settings.installerAgeDays) * day
        let folderPaths = Set(scan.folderCandidates.map(\.url.path))

        for original in candidates {
            let item = enrichedByPath[original.url.path] ?? original
            let ext = item.ext
            let lower = item.name.lowercased()
            let age = now.timeIntervalSince(item.addedToFolder ?? item.created ?? item.modified ?? now)
            let lastActivity = item.lastUsed ?? item.modified

            if (item.kind == .diskImage || item.kind == .installer) && age > installerLimit {
                add(CleanupSuggestion(url: item.url, isDirectory: false, size: item.size, lastUsed: lastActivity,
                                      category: .oldInstaller, reason: "Installer seit \(Int(age / day)) Tagen hier"))
                continue
            }
            if item.kind == .archive {
                let base = item.url.deletingPathExtension()
                let extracted = folderPaths.contains(base.path) || PathUtil.isDirectory(base)
                if extracted {
                    add(CleanupSuggestion(url: item.url, isDirectory: false, size: item.size, lastUsed: lastActivity,
                                          category: .extractedArchive, reason: "Inhalt liegt bereits entpackt daneben (\(base.lastPathComponent))"))
                    continue
                }
            }
            if Self.cacheLikeNames.contains(lower) || (Self.cacheLikeExtensions.contains(ext) && age > 7 * day)
                || (lower.hasPrefix("~$") && age > day) {
                add(CleanupSuggestion(url: item.url, isDirectory: false, size: item.size, lastUsed: lastActivity,
                                      category: .cacheLike, reason: "Temporäre Datei / Rest"))
                continue
            }
            if item.size >= largeBytes {
                add(CleanupSuggestion(url: item.url, isDirectory: false, size: item.size, lastUsed: lastActivity,
                                      category: .large, reason: "Größer als \(settings.largeFileMB) MB"))
                continue
            }
            if item.size >= Int64(settings.minSizeForUnusedMB) * 1_048_576, let last = lastActivity,
               now.timeIntervalSince(last) > unusedLimit {
                add(CleanupSuggestion(url: item.url, isDirectory: false, size: item.size, lastUsed: last,
                                      category: .unused, reason: "Seit \(Int(now.timeIntervalSince(last) / day)) Tagen nicht geöffnet"))
            }
        }

        for folder in scan.emptyFolders {
            let isStandard = [home.desktop, home.documents, home.downloads, home.pictures, home.movies, home.music]
                .contains { PathUtil.isSame($0, folder) }
            if isStandard || scan.roots.contains(where: { PathUtil.isSame($0.url, folder) }) { continue }
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            add(CleanupSuggestion(url: folder, isDirectory: true, size: 0, lastUsed: modified,
                                  category: .emptyFolder, reason: "Ordner ist leer"))
        }

        for entry in scan.protected where entry.reason == .incompleteDownload {
            let modified = entry.modified ?? (try? entry.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > 2 * day else { continue }
            let size = Int64((try? entry.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            add(CleanupSuggestion(url: entry.url, isDirectory: entry.isDirectory, size: size, lastUsed: modified,
                                  category: .staleDownload, reason: "Unvollständiger Download, seit \(Int(now.timeIntervalSince(modified) / day)) Tagen unverändert"))
        }

        for folder in scan.folderCandidates where folder.blockedReason == nil && folder.kind == .extractedArchive {
            if let modified = folder.modified, now.timeIntervalSince(modified) > unusedLimit {
                add(CleanupSuggestion(url: folder.url, isDirectory: true, size: folder.size, lastUsed: modified,
                                      category: .unused, reason: "Entpackter Ordner, seit \(Int(now.timeIntervalSince(modified) / day)) Tagen unverändert"))
            }
        }
        return result.sorted { ($0.category.rawValue, -$0.size) < ($1.category.rawValue, -$1.size) }
    }

    /// Converts the user's choices into actions. "keep" produces nothing.
    public func actions(for suggestions: [CleanupSuggestion]) -> [PlannedAction] {
        let archiveRoot = home.expand(settings.archiveFolder)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        let archiveFolder = archiveRoot.appendingPathComponent(df.string(from: now), isDirectory: true)
        return suggestions.compactMap { s in
            switch s.choice {
            case .keep:
                return nil
            case .trash:
                return PlannedAction(kind: .trash, source: s.url, destinationFolder: nil, reason: s.reason, confidence: 1,
                                     origin: .cleanup, group: s.category.displayName, isSelected: true, sizeBytes: s.size,
                                     requiresEmptyFolder: s.category == .emptyFolder)
            case .archive:
                guard s.allowsArchive else { return nil }
                return PlannedAction(kind: .archive, source: s.url, destinationFolder: archiveFolder, reason: s.reason,
                                     confidence: 1, origin: .cleanup, group: s.category.displayName, isSelected: true,
                                     sizeBytes: s.size)
            }
        }
    }
}
