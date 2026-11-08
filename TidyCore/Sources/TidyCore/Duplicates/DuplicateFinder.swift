import Foundation

public struct DuplicateGroup: Identifiable, Sendable, Hashable {
    public var id: String { hash }
    public let hash: String
    public let size: Int64
    public var files: [FileItem]
    /// Index into `files` of the copy that stays.
    public var keeperIndex: Int
    public var keeperReason: String

    public var keeper: FileItem { files[keeperIndex] }
    public var wastedBytes: Int64 { size * Int64(files.count - 1) }

    /// Copies that may be trashed (never files inside units such as albums).
    public var removable: [FileItem] {
        files.enumerated().filter { $0.offset != keeperIndex && $0.element.context != .inUnit }.map(\.element)
    }
}

/// Finds identical files: size → partial hash → full SHA-256. Files in projects, packages
/// and other protected places never get here (the scanner already left them out).
public struct DuplicateFinder: Sendable {
    public let home: HomeContext
    public var minSize: Int64

    public init(home: HomeContext, minSize: Int64 = 1) {
        self.home = home
        self.minSize = max(1, minSize)
    }

    public func find(in files: [FileItem], progress: (@Sendable (String) -> Void)? = nil,
                     isCancelled: @escaping @Sendable () -> Bool = { false }) async -> [DuplicateGroup] {
        // 1. Same size, real files only, hard links collapsed (same inode = same file).
        var bySize: [Int64: [FileItem]] = [:]
        var seenInodes = Set<String>()
        for item in files where item.size >= minSize && !item.isPackage {
            var st = stat()
            guard lstat(item.url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let inode = "\(st.st_dev):\(st.st_ino)"
            if !seenInodes.insert(inode).inserted { continue }
            bySize[item.size, default: []].append(item)
        }
        let sizeGroups = bySize.values.filter { $0.count > 1 }
        progress?("\(sizeGroups.count) Größengruppen prüfen …")

        // 2. Partial hash, 3. full hash.
        let partial = await hashGroups(sizeGroups, isCancelled: isCancelled) { FileHasher.partialHash(of: $0.url, size: $0.size) }
        let fullInput = partial.values.filter { $0.count > 1 }
        progress?("\(fullInput.count) Kandidatengruppen vollständig vergleichen …")
        let full = await hashGroups(Array(fullInput), isCancelled: isCancelled) { FileHasher.fullHash(of: $0.url, isCancelled: isCancelled) }

        var groups: [DuplicateGroup] = []
        for (hash, items) in full where items.count > 1 {
            let sorted = items.sorted { $0.url.path < $1.url.path }
            let (index, reason) = chooseKeeper(sorted)
            let group = DuplicateGroup(hash: hash, size: sorted[0].size, files: sorted, keeperIndex: index, keeperReason: reason)
            if !group.removable.isEmpty { groups.append(group) }
        }
        return groups.sorted { $0.wastedBytes > $1.wastedBytes }
    }

    private func hashGroups(_ groups: [[FileItem]], isCancelled: @escaping @Sendable () -> Bool,
                            hasher: @escaping @Sendable (FileItem) -> String?) async -> [String: [FileItem]] {
        let items = groups.flatMap { $0 }
        let hashes = await withTaskGroup(of: [(String, FileItem)].self) { group -> [(String, FileItem)] in
            let chunkSize = max(1, items.count / 8 + 1)
            for start in stride(from: 0, to: items.count, by: chunkSize) {
                let chunk = Array(items[start..<min(start + chunkSize, items.count)])
                group.addTask {
                    var out: [(String, FileItem)] = []
                    for item in chunk {
                        if isCancelled() { break }
                        if let h = hasher(item) { out.append(("\(item.size):\(h)", item)) }
                    }
                    return out
                }
            }
            var all: [(String, FileItem)] = []
            for await part in group { all += part }
            return all
        }
        var result: [String: [FileItem]] = [:]
        for (h, item) in hashes { result[h, default: []].append(item) }
        return result
    }

    /// The copy in the most sensible place with the best name stays.
    public func chooseKeeper(_ files: [FileItem]) -> (Int, String) {
        let inboxes = home.inboxFolders + [home.home]
        func score(_ f: FileItem) -> (Double, [String]) {
            var s = 0.0
            var why: [String] = []
            if f.context == .inUnit { s += 100; why.append("gehört zu einem zusammengehörigen Ordner") }
            let inInbox = inboxes.contains { PathUtil.isSame($0, f.parent) }
            if !inInbox { s += 20; why.append("liegt in einem sortierten Ordner") }
            let depth = Double(PathUtil.depth(of: f.url, below: home.home) ?? 0)
            s += min(depth, 6) * 2
            if !NameAnalyzer.isMeaningless(f.name) { s += 10; why.append("aussagekräftiger Name") }
            if FileNameTools.hasCopySuffix(f.baseName) { s -= 15 } else { why.append("kein Kopie-Zusatz") }
            return (s, why)
        }
        var best = 0
        var bestScore = -Double.infinity
        var bestWhy: [String] = []
        let oldest = files.indices.min { (files[$0].created ?? .distantFuture) < (files[$1].created ?? .distantFuture) }
        for (i, f) in files.enumerated() {
            var (s, why) = score(f)
            if i == oldest { s += 3; why.append("ältestes Exemplar") }
            if s > bestScore || (s == bestScore && f.name.count < files[best].name.count) {
                best = i
                bestScore = s
                bestWhy = why
            }
        }
        return (best, bestWhy.prefix(2).joined(separator: ", ").capitalizedFirst)
    }

    /// Trash actions for all removable copies (selected; still require confirmation).
    public func actions(for groups: [DuplicateGroup]) -> [PlannedAction] {
        groups.flatMap { group in
            group.removable.map { item in
                PlannedAction(kind: .trash, source: item.url, destinationFolder: nil,
                              reason: "Identisch mit \(home.abbreviate(group.keeper.url))", confidence: 0.99,
                              origin: .duplicate, group: "Duplikate", isSelected: true, sizeBytes: item.size)
            }
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
