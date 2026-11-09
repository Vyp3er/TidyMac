import Foundation

/// The user's existing folder structure. Used to prefer existing folders over new ones and
/// given to Claude as context. Only folders that are valid move destinations are listed.
public struct StructureIndex: Sendable {
    public private(set) var folders: [URL]
    private var pathSet: Set<String>

    public init(folders: [URL]) {
        self.folders = folders
        self.pathSet = Set(folders.map(PathUtil.path))
    }

    public static func build(home: HomeContext, policy: ProtectionPolicy, roots: [URL]? = nil,
                             maxDepth: Int = 4, limit: Int = 4000) -> StructureIndex {
        let start = roots ?? [home.documents, home.pictures, home.movies, home.music, home.downloads, home.desktop]
        var result: [URL] = []
        var queue: [(URL, Int)] = start.filter(PathUtil.isDirectory).map { ($0, 0) }
        var index = 0
        while index < queue.count && result.count < limit {
            let (dir, depth) = queue[index]
            index += 1
            if policy.destinationProtection(for: dir) != nil && depth == 0 { continue }
            result.append(dir)
            guard depth < maxDepth else { continue }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: ProtectionPolicy.resourceKeys, options: [])) ?? []
            let childNames = Set(children.map(\.lastPathComponent))
            for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                guard let values = try? child.resourceValues(forKeys: Set(ProtectionPolicy.resourceKeys)),
                      values.isDirectory == true, values.isPackage != true else { continue }
                if policy.itemProtection(child, values: values) != nil { continue }
                let grandChildren = (try? FileManager.default.contentsOfDirectory(
                    at: child, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [])) ?? []
                let names = grandChildren.map(\.lastPathComponent)
                guard case .normal = policy.destinationDirectoryClass(child, entries: names) else { continue }
                let infos = grandChildren.map { url -> EntryInfo in
                    let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    return EntryInfo(name: url.lastPathComponent, isDirectory: v?.isDirectory == true && v?.isPackage != true)
                }
                // Albums, photo series, websites ... are units: no files get added to them.
                if let kind = CohesionDetector.kind(folderName: child.lastPathComponent, entries: infos, siblingNames: childNames),
                   kind != .submission {
                    continue
                }
                queue.append((child, depth + 1))
            }
        }
        return StructureIndex(folders: result)
    }

    public func contains(_ url: URL) -> Bool {
        pathSet.contains(PathUtil.path(url))
    }

    public func children(of url: URL) -> [URL] {
        let base = PathUtil.path(url) + "/"
        return folders.filter { f in
            let p = PathUtil.path(f)
            return p.hasPrefix(base) && !p.dropFirst(base.count).contains("/")
        }
    }

    /// "~/..." paths for the AI prompt, shallow folders first.
    public func displayList(home: HomeContext, limit: Int = 400) -> [String] {
        let sorted = folders.sorted { a, b in
            let da = PathUtil.depth(of: a, below: home.home) ?? 99
            let db = PathUtil.depth(of: b, below: home.home) ?? 99
            return da == db ? a.path < b.path : da < db
        }
        return sorted.prefix(limit).map { home.abbreviate($0) }.sorted()
    }
}
