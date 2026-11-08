import Foundation

/// Describes the home folder TidyMac works on. Everything that refers to "~" goes through
/// this type, so tests can run against a fake home inside a temporary directory.
public struct HomeContext: Sendable, Hashable {
    public let home: URL

    public init(home: URL) {
        self.home = PathUtil.normalizeRoot(home)
    }

    public static var current: HomeContext {
        HomeContext(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    public func folder(_ name: String) -> URL {
        home.appendingPathComponent(name, isDirectory: true)
    }

    public var desktop: URL { folder("Desktop") }
    public var documents: URL { folder("Documents") }
    public var downloads: URL { folder("Downloads") }
    public var pictures: URL { folder("Pictures") }
    public var movies: URL { folder("Movies") }
    public var music: URL { folder("Music") }
    public var library: URL { folder("Library") }
    public var applications: URL { folder("Applications") }

    /// Folders where things typically land unsorted.
    public var inboxFolders: [URL] { [downloads, desktop] }

    /// Expands "~/x" (or a relative path) against this home. Absolute paths stay as they are.
    public func expand(_ path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") {
            return home.appendingPathComponent(String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("/") {
            let url = URL(fileURLWithPath: trimmed)
            // Map the real home onto a fake test home only if it literally is our home.
            return url.standardizedFileURL
        }
        return home.appendingPathComponent(trimmed)
    }

    /// "~/Documents/x" style display path.
    public func abbreviate(_ url: URL) -> String {
        if let rel = PathUtil.relativePath(of: url, to: home) {
            return rel.isEmpty ? "~" : "~/" + rel
        }
        return url.standardizedFileURL.path
    }

    public func contains(_ url: URL) -> Bool {
        PathUtil.isDescendant(url, of: home, orEqual: false)
    }
}

public enum PathUtil {
    /// Normalises a root folder (home, scan root). Never call this on scanned items,
    /// because it would resolve symbolic links to their targets.
    public static func normalizeRoot(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public static func path(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        if p.count > 1 && p.hasSuffix("/") { return String(p.dropLast()) }
        return p
    }

    public static func isSame(_ a: URL, _ b: URL) -> Bool {
        path(a) == path(b)
    }

    public static func isDescendant(_ url: URL, of ancestor: URL, orEqual: Bool = true) -> Bool {
        let p = path(url)
        let a = path(ancestor)
        if p == a { return orEqual }
        let prefix = a.hasSuffix("/") ? a : a + "/"
        return p.hasPrefix(prefix)
    }

    /// Path of `url` relative to `base` ("" if equal), or nil if it is not inside.
    public static func relativePath(of url: URL, to base: URL) -> String? {
        let p = path(url)
        let b = path(base)
        if p == b { return "" }
        let prefix = b.hasSuffix("/") ? b : b + "/"
        guard p.hasPrefix(prefix) else { return nil }
        return String(p.dropFirst(prefix.count))
    }

    /// Number of path components of `url` below `base`.
    public static func depth(of url: URL, below base: URL) -> Int? {
        guard let rel = relativePath(of: url, to: base) else { return nil }
        if rel.isEmpty { return 0 }
        return rel.split(separator: "/").count
    }

    public static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    public static func isSymlink(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Deepest ancestor of `url` (including itself) that exists on disk.
    public static func deepestExistingAncestor(of url: URL) -> URL {
        var current = url.standardizedFileURL
        while !exists(current) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return current
    }
}
