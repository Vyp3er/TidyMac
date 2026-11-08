import Foundation

/// Detects folders of cloud sync services. These are only touched after explicit release.
public struct CloudSyncDetector: Sendable {
    public let home: HomeContext

    public init(home: HomeContext) {
        self.home = home
    }

    static let markerFiles: [String: String] = [
        ".dropbox": "Dropbox", ".dropbox.cache": "Dropbox", ".dropbox.attr": "Dropbox",
        ".tresorit": "Tresorit", ".owncloudsync.log": "ownCloud", ".nextcloudsync.log": "Nextcloud",
        ".sync": "Resilio Sync", ".megaignore": "MEGA", ".debris": "MEGA", ".pcloud": "pCloud",
        ".SynologyWorkingDirectory": "Synology Drive", ".seafile-data": "Seafile", ".tmp.drivedownload": "Google Drive",
        ".tmp.driveupload": "Google Drive", ".shortcut-targets-by-id": "Google Drive", "desktop.ini.icloud": "iCloud",
    ]

    /// Names of sync folders that live directly in the home folder.
    static let topLevelPrefixes = [
        "Dropbox", "OneDrive", "Google Drive", "GoogleDrive", "My Drive", "Box", "Box Sync", "Nextcloud", "ownCloud",
        "pCloud Drive", "MEGA", "MEGAsync", "Sync", "Tresorit", "SynologyDrive", "Seafile", "Yandex.Disk",
        "iCloud Drive", "Creative Cloud Files", "IDrive", "Proton Drive", "Filen",
    ]

    public func service(forDirectory url: URL, entries: [String]) -> String? {
        for entry in entries {
            if let service = Self.markerFiles[entry] { return service }
            if entry.hasPrefix(".sync_") && entry.hasSuffix(".db") { return "Nextcloud/ownCloud" }
            if entry.hasPrefix("._sync_") && entry.hasSuffix(".db") { return "Nextcloud/ownCloud" }
        }
        if PathUtil.isSame(url.deletingLastPathComponent(), home.home) {
            let name = url.lastPathComponent
            for prefix in Self.topLevelPrefixes where name == prefix || name.hasPrefix(prefix + " ") || name.hasPrefix(prefix + "-") || name.hasPrefix(prefix + "(") {
                return prefix
            }
        }
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]), values.isUbiquitousItem == true {
            return "iCloud Drive"
        }
        if XAttr.data("com.apple.fileprovider.fpfs#P", at: url) != nil {
            return "iCloud / File Provider"
        }
        return nil
    }
}

/// Paths the user (or the system) points at: Dock items, Finder sidebar favourites, and
/// targets of symlinks/aliases found while scanning. Such folders are not moved without warning.
public struct ReferenceIndex: Sendable, Hashable {
    /// path -> where the reference comes from
    public private(set) var entries: [String: String]

    public init(entries: [String: String] = [:]) {
        self.entries = entries
    }

    public mutating func add(_ url: URL, source: String) {
        let path = PathUtil.path(url)
        if entries[path] == nil { entries[path] = source }
    }

    public mutating func merge(_ other: [String: String]) {
        for (k, v) in other where entries[k] == nil { entries[k] = v }
    }

    /// References that point at `url` itself or at something inside it.
    public func references(insideOrAt url: URL) -> [(path: String, source: String)] {
        let base = PathUtil.path(url)
        let prefix = base + "/"
        return entries.compactMap { key, value in
            (key == base || key.hasPrefix(prefix)) ? (key, value) : nil
        }.sorted { $0.path < $1.path }
    }

    public static func load(home: HomeContext) -> ReferenceIndex {
        var index = ReferenceIndex()
        let dock = home.library.appendingPathComponent("Preferences/com.apple.dock.plist")
        if let data = try? Data(contentsOf: dock),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            for url in collectFileURLs(in: plist) { index.add(url, source: "Dock") }
        }
        let sharedLists = home.library.appendingPathComponent("Application Support/com.apple.sharedfilelist")
        for name in ["com.apple.LSSharedFileList.FavoriteItems.sfl4", "com.apple.LSSharedFileList.FavoriteItems.sfl3",
                     "com.apple.LSSharedFileList.FavoriteItems.sfl2"] {
            let file = sharedLists.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
            for url in collectFileURLs(in: plist) { index.add(url, source: "Finder-Seitenleiste") }
            break
        }
        // Standard folders always count as referenced (sidebar defaults).
        for folder in [home.desktop, home.documents, home.downloads, home.pictures, home.movies, home.music] {
            index.add(folder, source: "macOS-Standardordner")
        }
        return index
    }

    /// Walks a property list and returns every file URL it contains, either as
    /// `_CFURLString` / "file://" strings or as bookmark data.
    static func collectFileURLs(in plist: Any) -> [URL] {
        var result: [URL] = []
        func visit(_ value: Any) {
            switch value {
            case let dict as [String: Any]:
                for (_, v) in dict { visit(v) }
            case let array as [Any]:
                for v in array { visit(v) }
            case let string as String:
                if string.hasPrefix("file://"), let url = URL(string: string), url.isFileURL {
                    result.append(url)
                }
            case let data as Data:
                if data.count > 8, data.prefix(4) == Data("book".utf8) || data.prefix(4) == Data("alis".utf8) {
                    if let values = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data),
                       let path = values.path {
                        result.append(URL(fileURLWithPath: path))
                    }
                } else if data.count > 8, let nested = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                    visit(nested)
                }
            default:
                break
            }
        }
        visit(plist)
        return result
    }
}
