import Foundation

public enum DirectoryClass: Sendable, Hashable {
    case protected(ProtectionReason)
    /// A project folder that may be moved as a whole (only if the user allowed it).
    case movableProject(marker: String)
    case normal
}

/// The central safety gate. Every scan, plan and execution step asks this policy.
/// When in doubt it protects.
public final class ProtectionPolicy: @unchecked Sendable {
    public let home: HomeContext
    public let settings: ProtectionSettings
    public private(set) var references: ReferenceIndex
    public let projects: ProjectDetector
    let cloud: CloudSyncDetector
    let excludedURLs: [URL]
    let allowedCloudURLs: [URL]
    /// Explicitly selected roots outside the home folder (e.g. an external drive).
    let extraAllowedRoots: [URL]

    private let cacheLock = NSLock()
    private var directoryCache: [String: DirectoryClass] = [:]

    public static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey, .isHiddenKey, .fileSizeKey,
        .creationDateKey, .contentModificationDateKey, .contentAccessDateKey, .addedToDirectoryDateKey,
        .contentTypeKey, .isRegularFileKey,
    ]

    static let systemPrefixes = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private",
                                 "/etc", "/var", "/opt", "/cores", "/dev", "/Network", "/Users/Shared", "/tmp"]

    /// Packages that are never moved (app bundles, media libraries, VMs, ...).
    /// Every other package is protected too unless it is listed in `movableDocumentPackages`.
    public static let neverMoveExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "photoboothlibrary", "aplibrary", "migratedphotolibrary",
        "imovielibrary", "theater", "fcpbundle", "logicx", "band", "lrdata", "bundle", "framework", "plugin", "kext",
        "prefpane", "appex", "xpc", "xcarchive", "xcodeproj", "xcworkspace", "playground", "sparsebundle", "vmwarevm",
        "pvm", "pvmp", "utm", "vbox", "dtbase2", "dtsparse", "noindex", "lproj", "dsym", "qlgenerator", "saver",
        "wdgt", "mdimporter", "component", "vst", "vst3", "aaxplugin", "mlmodelc", "photolibrary", "library",
    ]

    /// Document packages that behave like single files and may be moved as a whole.
    public static let movableDocumentPackages: Set<String> = ["pages", "numbers", "key", "rtfd", "scriv", "graffle"]

    /// Single files that belong to an app's data store.
    static let appDataFileExtensions: Set<String> = ["lrcat", "vmdk", "vdi", "qcow2", "vhd", "vhdx", "hdd"]

    /// Files whose presence marks a folder as app data (databases).
    static let databaseExtensions: Set<String> = ["sqlite", "sqlite3", "sqlitedb", "db", "realm", "lrcat", "ldb", "fmp12", "accdb", "mdb"]

    public static let incompleteDownloadExtensions: Set<String> = [
        "crdownload", "download", "part", "partial", "opdownload", "filepart", "tmp", "!qb", "aria2", "dtapart", "crswap",
    ]

    /// Folders (relative to home) that apps manage themselves.
    static let appManagedRelativePaths: [String] = [
        "Music/Music", "Music/iTunes", "Music/Audio Music Apps", "Music/GarageBand", "Music/Logic", "Music/Ableton",
        "Music/Native Instruments", "Movies/TV", "Movies/Motion Templates", "Movies/Final Cut Backups",
        "Movies/CapCut", "Pictures/Photo Booth Library", "Pictures/Lightroom", "Pictures/Capture One",
        "Documents/Zoom", "Documents/Microsoft User Data", "Documents/Adobe", "Documents/Arduino", "Documents/MATLAB",
        "Documents/Virtual Machines.localized", "Documents/Parallels", "Documents/Paradox Interactive",
        "Documents/My Games", "Documents/Klei", "Documents/Elgato", "Documents/Native Instruments",
        "Documents/Steinberg", "Documents/Image-Line", "Documents/Blackmagic Design", "Documents/Rockstar Games",
        "Documents/Outlook Files", "Documents/OneNote Notebooks", "Documents/Processing", "Documents/KiCad",
        "Documents/Wolfram Mathematica", "Documents/Cities_Skylines", "Documents/League of Legends",
        "Documents/Ableton", "Documents/Reaper Media", "Documents/Unity", "Documents/Unreal Projects",
        "Documents/Fusion 360", "Documents/Roblox", "Documents/Obsidian Vault", "Documents/GitHub",
        "Parallels", "VirtualBox VMs", "Calibre Library", "Calibre-Bibliothek", "Zotero", "Creative Cloud Files",
        "OrbStack", "Postman", "Sites", "Public", "go", "Applications", "Library", "Movies/iMovie Theater.theater",
    ]

    public init(home: HomeContext, settings: ProtectionSettings, references: ReferenceIndex = ReferenceIndex(),
                extraAllowedRoots: [URL] = []) {
        self.home = home
        self.settings = settings
        self.references = references
        self.projects = ProjectDetector(extraMarkers: settings.extraProjectMarkers)
        self.cloud = CloudSyncDetector(home: home)
        self.excludedURLs = settings.excludedPaths.filter { !$0.isEmpty }.map { home.expand($0) }
        self.allowedCloudURLs = settings.allowedCloudPaths.filter { !$0.isEmpty }.map { home.expand($0) }
        self.extraAllowedRoots = extraAllowedRoots.filter { url in
            let p = PathUtil.path(url)
            return p.hasPrefix("/Volumes/") && !Self.systemPrefixes.contains { p == $0 || p.hasPrefix($0 + "/") }
        }
    }

    public func addReferences(_ entries: [String: String]) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        references.merge(entries)
    }

    // MARK: - Areas

    /// True if `url` lies in an area TidyMac may work in at all.
    public func isInAllowedArea(_ url: URL) -> Bool {
        if home.contains(url) { return true }
        return extraAllowedRoots.contains { PathUtil.isDescendant(url, of: $0, orEqual: false) }
    }

    private func isUnderSystemPrefix(_ url: URL) -> Bool {
        let p = PathUtil.path(url)
        if home.contains(url) { return false }
        return Self.systemPrefixes.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    func isCloudAllowed(_ url: URL) -> Bool {
        allowedCloudURLs.contains { PathUtil.isDescendant(url, of: $0) }
    }

    // MARK: - Single item

    /// Protection that follows from the item alone (name, type, location).
    /// Does not look into folders; see `directoryClass` for that.
    public func itemProtection(_ url: URL, values: URLResourceValues? = nil) -> ProtectionReason? {
        if isUnderSystemPrefix(url) { return .systemLocation }
        if !isInAllowedArea(url) { return .outsideHome }

        let v = values ?? (try? url.resourceValues(forKeys: Set(Self.resourceKeys)))
        if v?.isSymbolicLink == true || PathUtil.isSymlink(url) { return .symlink }
        if v?.isAliasFile == true && v?.isSymbolicLink != true { return .alias }

        if PathUtil.isDescendant(url, of: home.library) { return .library }
        if PathUtil.isDescendant(url, of: home.applications) { return .applications }

        let name = url.lastPathComponent
        if name.hasPrefix(".") { return .hidden }
        if v?.isHidden == true && name != "Icon\r" { return .hidden }
        if name == "Icon\r" { return .hidden }

        if let rule = userExclusion(for: url) { return .userExcluded(rule: rule) }

        let isDirectory = v?.isDirectory ?? PathUtil.isDirectory(url)
        let ext = FileNameTools.split(name).ext.lowercased()

        if isDirectory {
            if let rel = PathUtil.relativePath(of: url, to: home.home),
               Self.appManagedRelativePaths.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) {
                return .appManaged(name: name)
            }
            if name.hasSuffix(".localized") { return .appManaged(name: name) }
            let isPackage = v?.isPackage ?? false
            if Self.neverMoveExtensions.contains(ext) { return .bundle(ext: ext) }
            if isPackage && !Self.movableDocumentPackages.contains(ext) {
                return .bundle(ext: ext.isEmpty ? "Paket" : ext)
            }
        } else {
            if Self.appDataFileExtensions.contains(ext) { return .appDatabase(file: name) }
            if Self.incompleteDownloadExtensions.contains(ext) { return .incompleteDownload }
        }
        return nil
    }

    public func userExclusion(for url: URL) -> String? {
        for excluded in excludedURLs where PathUtil.isDescendant(url, of: excluded) {
            return home.abbreviate(excluded)
        }
        let display = home.abbreviate(url)
        let name = url.lastPathComponent
        for pattern in settings.excludedPatterns where Glob.matches(pattern, name: name, displayPath: display) {
            return pattern
        }
        return nil
    }

    // MARK: - Folders

    /// Looks at the folder's entries: project roots, cloud sync folders, app databases.
    public func directoryClass(_ url: URL, entries: [String]) -> DirectoryClass {
        let key = PathUtil.path(url)
        cacheLock.lock()
        if let cached = directoryCache[key] { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        let result = computeDirectoryClass(url, entries: entries)
        cacheLock.lock()
        directoryCache[key] = result
        cacheLock.unlock()
        return result
    }

    public func clearCache() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        directoryCache.removeAll()
    }

    /// Home, Desktop, Documents, Downloads ... are no projects just because a loose
    /// "requirements.txt" lies in them; only version-control folders count there.
    private func isStandardFolder(_ url: URL) -> Bool {
        let standard = [home.home, home.desktop, home.documents, home.downloads, home.pictures, home.movies, home.music]
        return standard.contains { PathUtil.isSame($0, url) }
    }

    private func computeDirectoryClass(_ url: URL, entries: [String]) -> DirectoryClass {
        if let service = cloud.service(forDirectory: url, entries: entries), !isCloudAllowed(url) {
            return .protected(.cloudSync(service: service))
        }
        let standard = isStandardFolder(url)
        let markerEntries = standard ? entries.filter { [".git", ".hg", ".svn", ".bzr", "_darcs", ".fossil"].contains($0) } : entries
        if let marker = projects.marker(folderName: url.lastPathComponent, entries: markerEntries) {
            return settings.allowMovingProjectFolders ? .movableProject(marker: marker) : .protected(.projectRoot(marker: marker))
        }
        for entry in entries where !standard {
            let ext = FileNameTools.split(entry).ext.lowercased()
            if Self.databaseExtensions.contains(ext) || entry.hasSuffix(".db-wal") || entry.hasSuffix(".sqlite-wal") {
                return .protected(.appDatabase(file: entry))
            }
        }
        return .normal
    }

    public func directoryClass(_ url: URL) -> DirectoryClass {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return directoryClass(url, entries: entries)
    }

    /// Checks every ancestor between the home folder (exclusive) and `url` (inclusive when `includeSelf`)
    /// for taboo areas, projects, cloud folders and packages.
    public func ancestorProtection(of url: URL, includeSelf: Bool = false) -> ProtectionReason? {
        if isUnderSystemPrefix(url) { return .systemLocation }
        if !isInAllowedArea(url) && !(includeSelf && PathUtil.isSame(url, home.home)) { return .outsideHome }

        let base = extraAllowedRoots.first { PathUtil.isDescendant(url, of: $0) } ?? home.home
        var chain: [URL] = []
        var current = includeSelf ? url.standardizedFileURL : url.standardizedFileURL.deletingLastPathComponent()
        while PathUtil.isDescendant(current, of: base, orEqual: false) {
            chain.append(current)
            current = current.deletingLastPathComponent()
        }
        for dir in chain.reversed() {
            guard PathUtil.exists(dir) else {
                // Not yet created: only the name can be checked.
                let name = dir.lastPathComponent
                if name.hasPrefix(".") { return .hidden }
                let ext = FileNameTools.split(name).ext.lowercased()
                if Self.neverMoveExtensions.contains(ext) { return .bundle(ext: ext) }
                continue
            }
            if let reason = itemProtection(dir) { return reason }
            switch directoryClass(dir) {
            case let .protected(reason):
                if case let .projectRoot(marker) = reason {
                    return PathUtil.isSame(dir, url) ? .projectRoot(marker: marker) : .insideProject(root: home.abbreviate(dir))
                }
                return reason
            case .movableProject:
                if !PathUtil.isSame(dir, url) { return .insideProject(root: home.abbreviate(dir)) }
            case .normal:
                break
            }
        }
        return nil
    }

    /// Validates a target folder for moves (it may not exist yet).
    public func destinationProtection(for folder: URL) -> ProtectionReason? {
        ancestorProtection(of: folder, includeSelf: true)
    }

    /// First protected folder (project, cloud, app data, app-managed) somewhere inside `folder`.
    /// Used before a folder is moved, archived or trashed as a whole.
    public func protectedDescendant(in folder: URL, limit: Int = 50_000) -> (URL, ProtectionReason)? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { _, _ in true }) else { return nil }
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count > limit { return (folder, .appManaged(name: "zu viele Einträge zum Prüfen")) }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isDirectory == true, v.isSymbolicLink != true else { continue }
            if v.isPackage == true { enumerator.skipDescendants(); continue }
            if let rel = PathUtil.relativePath(of: url, to: home.home),
               Self.appManagedRelativePaths.contains(where: { rel == $0 }) {
                return (url, .appManaged(name: url.lastPathComponent))
            }
            if case let .protected(reason) = directoryClass(url) { return (url, reason) }
        }
        return nil
    }

    /// References (Dock, Finder sidebar, symlinks, aliases) pointing at or into `url`.
    public func referenceWarning(for url: URL) -> String? {
        let refs = references.references(insideOrAt: url)
        guard let first = refs.first else { return nil }
        let where_ = PathUtil.path(url) == first.path ? "" : " (auf \(home.abbreviate(URL(fileURLWithPath: first.path))))"
        return "Wird referenziert: \(first.source)\(where_)" + (refs.count > 1 ? " und \(refs.count - 1) weitere" : "")
    }
}
