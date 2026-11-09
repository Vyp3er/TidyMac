import Foundation

/// Files that are redundant regardless of their age: already extracted archives, installers of
/// installed apps, identical "(1)" copies, temporary leftovers, aborted downloads. These are
/// checked locally (no AI). They are only ever suggested; the user confirms each one.
public struct RedundancyDetector: Sendable {
    public struct Finding: Sendable, Hashable {
        public let url: URL
        public let isDirectory: Bool
        public let size: Int64
        public let modified: Date?
        public let kind: FileKind
        public let reason: String
        public let confidence: Double
    }

    public let home: HomeContext
    public let settings: DeletionSettings
    public let now: Date
    /// Normalized names of installed apps ("googlechrome", "firefox", …).
    public let installedApps: Set<String>

    public init(home: HomeContext, settings: DeletionSettings, now: Date = Date(), installedApps: Set<String>? = nil) {
        self.home = home
        self.settings = settings
        self.now = now
        self.installedApps = installedApps ?? Self.installedAppNames(home: home)
    }

    static let day = 86_400.0
    static let cacheLikeExtensions: Set<String> = ["tmp", "temp", "bak", "old", "crash", "dmp", "swp"]
    static let cacheLikeNames: Set<String> = ["thumbs.db", "desktop.ini", "ehthumbs.db"]
    static let archiveSuffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tgz", ".tbz", ".zip", ".rar", ".7z",
                                  ".tar", ".gz", ".bz2", ".xz", ".zst", ".sitx", ".sit"]
    static let installerNoise: Set<String> = ["setup", "installer", "install", "mac", "macos", "osx", "universal", "arm64",
                                              "aarch64", "x64", "x86", "intel", "darwin", "latest", "release", "stable",
                                              "apple", "silicon", "dmg", "pkg", "for", "beta"]

    // MARK: Quick checks (also used by the planner: such files are not sorted but deleted)

    /// Cheap, name-based check without hashing or reading archives.
    public static func quickReason(for item: FileItem) -> String? {
        let lower = item.name.lowercased()
        if item.kind == .installer || item.kind == .diskImage { return "Installer" }
        if cacheLikeNames.contains(lower) || cacheLikeExtensions.contains(item.ext) || lower.hasPrefix("~$") { return "Temporäre Datei" }
        if item.kind == .torrent { return "Torrent-Datei" }
        if item.kind == .archive, extractedFolder(for: item.url) != nil { return "Bereits entpacktes Archiv" }
        return nil
    }

    // MARK: Archives

    static func archiveBaseName(_ name: String) -> String? {
        let lower = name.lowercased()
        guard let suffix = archiveSuffixes.first(where: { lower.hasSuffix($0) }), name.count > suffix.count else { return nil }
        return String(name.dropLast(suffix.count))
    }

    /// The folder next to an archive with the same name ("Projekt.zip" → "Projekt", also "Projekt (1).zip" → "Projekt").
    public static func extractedFolder(for archive: URL) -> URL? {
        guard let base = archiveBaseName(archive.lastPathComponent) else { return nil }
        let parent = archive.deletingLastPathComponent()
        for candidate in [base, FileNameTools.removingCopySuffix(base)] where !candidate.isEmpty {
            let dir = parent.appendingPathComponent(candidate, isDirectory: true)
            let values = try? dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true, values?.isPackage != true { return dir }
        }
        return nil
    }

    /// File entries of a ZIP (without folders, "__MACOSX" and ".DS_Store"), or nil if unreadable.
    static func zipEntries(_ url: URL) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", url.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        // "._name" entries are macOS metadata (AppleDouble); unzipping turns them into attributes, not files.
        return text.split(separator: "\n").map(String.init).filter { entry in
            let last = entry.split(separator: "/").last.map(String.init) ?? entry
            return !entry.hasSuffix("/") && !entry.hasPrefix("__MACOSX/") && last != ".DS_Store" && !last.hasPrefix("._")
        }
    }

    /// Share of the archive's files that exist in the extracted folder (or nil if not checkable).
    static func extractedShare(zip: URL, folder: URL) -> Double? {
        guard let entries = zipEntries(zip), !entries.isEmpty else { return nil }
        let parent = folder.deletingLastPathComponent()
        let found = entries.filter { entry in
            PathUtil.exists(folder.appendingPathComponent(entry)) || PathUtil.exists(parent.appendingPathComponent(entry))
        }
        return Double(found.count) / Double(entries.count)
    }

    func archiveFinding(_ item: FileItem) -> Finding? {
        guard item.kind == .archive else { return nil }
        var folder = Self.extractedFolder(for: item.url)
        var share: Double?
        if item.ext == "zip" {
            if let folder { share = Self.extractedShare(zip: item.url, folder: folder) }
            // Archives with one top-level folder are extracted under that folder's name.
            if folder == nil || (share ?? 0) < 0.9, let entries = Self.zipEntries(item.url),
               let top = Self.commonTopFolder(entries) {
                let candidate = item.parent.appendingPathComponent(top, isDirectory: true)
                if PathUtil.isDirectory(candidate), !PathUtil.isSymlink(candidate),
                   let s = Self.extractedShare(zip: item.url, folder: candidate), s >= (share ?? 0) {
                    folder = candidate
                    share = s
                }
            }
        }
        guard let folder else { return nil }
        let name = folder.lastPathComponent
        switch share {
        case let s? where s >= 0.9:
            return finding(item, "Bereits entpackt: Der Inhalt liegt vollständig im Ordner „\(name)“ daneben.", 0.97)
        case let s? where s >= 0.5:
            return finding(item, "Größtenteils entpackt: \(Int(s * 100)) % des Inhalts liegen im Ordner „\(name)“.", 0.7)
        case .some:
            return nil
        case nil:
            return finding(item, "Bereits entpackt: Daneben liegt der Ordner „\(name)“.", 0.85)
        }
    }

    static func commonTopFolder(_ entries: [String]) -> String? {
        let tops = Set(entries.compactMap { $0.split(separator: "/", maxSplits: 1).count > 1 ? String($0.split(separator: "/")[0]) : nil })
        guard tops.count == 1, entries.allSatisfy({ $0.contains("/") }) else { return nil }
        return tops.first
    }

    // MARK: Installers

    public static func installedAppNames(home: HomeContext) -> Set<String> {
        let folders = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"),
                       URL(fileURLWithPath: "/System/Applications"), home.applications]
        var names = Set<String>()
        for folder in folders {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for entry in entries where entry.hasSuffix(".app") {
                let n = normalize(String(entry.dropLast(4)))
                if n.count >= 3 { names.insert(n) }
            }
        }
        return names
    }

    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// "Firefox-Setup-128.0.dmg" → "firefox", "Slack-4.41.105-macOS.dmg" → "slack".
    static func appToken(forInstaller name: String) -> String? {
        let base = FileNameTools.split(name).base
        var words: [String] = []
        for raw in base.split(whereSeparator: { "-_ .()[]".contains($0) }) {
            let word = String(raw)
            let lower = word.lowercased()
            if installerNoise.contains(lower) || word.first?.isNumber == true || lower.hasPrefix("v") && lower.dropFirst().first?.isNumber == true {
                break
            }
            words.append(word)
        }
        let token = normalize(words.joined())
        return token.count >= 3 ? token : nil
    }

    func installedApp(forInstaller name: String) -> Bool {
        guard let token = Self.appToken(forInstaller: name) else { return false }
        return installedApps.contains { app in
            app == token || (token.count >= 4 && app.hasPrefix(token)) || (app.count >= 4 && token.hasPrefix(app))
        }
    }

    // MARK: Find

    func finding(_ item: FileItem, _ reason: String, _ confidence: Double) -> Finding {
        Finding(url: item.url, isDirectory: false, size: item.size, modified: item.modified, kind: item.kind,
                reason: reason, confidence: confidence)
    }

    func ageDays(_ item: FileItem) -> Double {
        let added = [item.addedToFolder, item.modified, item.created].compactMap { $0 }.max() ?? now
        return now.timeIntervalSince(added) / Self.day
    }

    public func find(in scan: ScanResult) -> [Finding] {
        var results: [Finding] = []
        var seen = Set<String>()
        func add(_ f: Finding?) {
            guard let f, seen.insert(f.url.path).inserted else { return }
            results.append(f)
        }
        let byFolder = Dictionary(grouping: scan.allFiles, by: { $0.parent.path })

        for item in scan.allFiles {
            let lower = item.name.lowercased()
            let age = ageDays(item)
            // Disposable kinds are fine to suggest even inside a unit folder.
            if item.kind == .installer || item.kind == .diskImage {
                if installedApp(forInstaller: item.name), age >= 1.0 / 24 {
                    add(finding(item, "Installer – die App ist bereits installiert.", 0.95))
                } else if age >= Double(max(settings.installerAgeDays, 0)) {
                    add(finding(item, "Installer, seit \(Int(age)) Tagen hier – nach der Installation nicht mehr nötig.", 0.85))
                }
                continue
            }
            if Self.cacheLikeNames.contains(lower) || Self.cacheLikeExtensions.contains(item.ext) || lower.hasPrefix("~$") {
                if age >= 1 { add(finding(item, "Temporäre Datei oder Rest eines Programms.", 0.85)) }
                continue
            }
            if item.kind == .torrent {
                if age >= 7 { add(finding(item, "Torrent-Datei, der Download ist längst erledigt.", 0.85)) }
                continue
            }
            guard item.context != .inUnit else { continue }
            if let archive = archiveFinding(item) {
                add(archive)
                continue
            }
            // Identical "(1)" copies of a file in the same folder.
            let split = FileNameTools.split(item.name)
            if FileNameTools.hasCopySuffix(split.base) {
                let originalName = FileNameTools.join(FileNameTools.removingCopySuffix(split.base), split.ext)
                if originalName != item.name,
                   let original = byFolder[item.parent.path]?.first(where: { $0.name == originalName && $0.size == item.size }),
                   item.size > 0, let a = FileHasher.fullHash(of: item.url), a == FileHasher.fullHash(of: original.url) {
                    add(finding(item, "Doppelter Download – identisch mit „\(originalName)“ im selben Ordner.", 0.95))
                }
            }
        }

        // Aborted downloads (the scanner protects them from sorting).
        for entry in scan.protected where entry.reason == .incompleteDownload {
            let modified = entry.modified ?? (try? entry.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > 2 * Self.day else { continue }
            let size = Int64((try? entry.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            add(Finding(url: entry.url, isDirectory: entry.isDirectory, size: size, modified: modified, kind: .other,
                        reason: "Abgebrochener Download, seit \(Int(now.timeIntervalSince(modified) / Self.day)) Tagen unverändert.",
                        confidence: 0.9))
        }
        return results
    }
}
