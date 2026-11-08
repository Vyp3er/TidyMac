import Foundation

/// Fast, parallel and read-only scan. The scanner never changes anything on disk.
public final class FileScanner: @unchecked Sendable {
    public let home: HomeContext
    public let policy: ProtectionPolicy
    public let general: GeneralSettings

    public init(home: HomeContext, policy: ProtectionPolicy, general: GeneralSettings) {
        self.home = home
        self.policy = policy
        self.general = general
    }

    // MARK: Roots

    public func roots(for target: ScanTarget) -> [ScanRoot] {
        switch target {
        case .everything:
            var roots = [
                ScanRoot(url: home.home, mode: .looseOnly),
                ScanRoot(url: home.desktop, mode: .inbox),
                ScanRoot(url: home.downloads, mode: .inbox),
                ScanRoot(url: home.documents, mode: .selected),
            ]
            let special = Set([home.desktop, home.downloads, home.documents, home.library, home.applications].map(PathUtil.path))
            let children = (try? FileManager.default.contentsOfDirectory(
                at: home.home, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true,
                      !special.contains(PathUtil.path(child)), !child.lastPathComponent.hasPrefix(".") else { continue }
                roots.append(ScanRoot(url: child, mode: .structure))
            }
            return roots
        case let .folders(urls):
            let normalized = urls.map(PathUtil.normalizeRoot)
            var unique: [URL] = []
            for url in normalized.sorted(by: { $0.path.count < $1.path.count }) {
                if unique.contains(where: { PathUtil.isDescendant(url, of: $0) }) { continue }
                unique.append(url)
            }
            return unique.map { url in
                let inbox = home.inboxFolders.contains { PathUtil.isSame($0, url) }
                return ScanRoot(url: url, mode: inbox ? .inbox : .selected)
            }
        }
    }

    // MARK: Scan

    public func scan(_ target: ScanTarget,
                     progress: (@Sendable (ScanProgress) -> Void)? = nil,
                     isCancelled: @escaping @Sendable () -> Bool = { false }) async -> ScanResult {
        let started = Date()
        let roots = roots(for: target)
        let counter = ProgressCounter(callback: progress)
        var total = Accumulator()

        for root in roots {
            if isCancelled() || Task.isCancelled { break }
            let isHomeRoot = PathUtil.isSame(root.url, home.home)
            if !isHomeRoot, let reason = policy.ancestorProtection(of: root.url, includeSelf: true) {
                total.protected.append(ProtectedEntry(url: root.url, reason: reason, isDirectory: true))
                total.notes.append("\(home.abbreviate(root.url)) ist geschützt: \(reason.description)")
                continue
            }
            if !isHomeRoot, !policy.isInAllowedArea(root.url) {
                total.notes.append("\(home.abbreviate(root.url)) liegt außerhalb des erlaubten Bereichs.")
                continue
            }
            guard PathUtil.isDirectory(root.url) else { continue }

            let listing = listEntries(root.url)
            let names = listing.map { $0.url.lastPathComponent }
            let webPairs = CohesionDetector.savedWebPageNames(in: names)
            let siblings = Set(names)

            var rootAcc = Accumulator()
            var directoryEntries: [Entry] = []
            for entry in listing {
                if entry.values.isDirectory == true, entry.values.isSymbolicLink != true,
                   policy.itemProtection(entry.url, values: entry.values) == nil,
                   !webPairs.contains(entry.url.lastPathComponent), root.mode != .looseOnly {
                    directoryEntries.append(entry)
                } else {
                    var unit: UnitStats?
                    process(entry, root: root, depth: 0, context: .loose, siblings: siblings, webPairs: webPairs,
                            acc: &rootAcc, unit: &unit, counter: counter, isCancelled: isCancelled)
                }
            }

            let partials = await withTaskGroup(of: Accumulator.self) { group -> [Accumulator] in
                for entry in directoryEntries {
                    group.addTask { [self] in
                        var acc = Accumulator()
                        var unit: UnitStats?
                        self.process(entry, root: root, depth: 0, context: .loose, siblings: siblings, webPairs: webPairs,
                                     acc: &acc, unit: &unit, counter: counter, isCancelled: isCancelled)
                        return acc
                    }
                }
                var results: [Accumulator] = []
                for await partial in group { results.append(partial) }
                return results
            }
            rootAcc.merge(partials)
            total.merge([rootAcc])
        }

        policy.addReferences(total.linkTargets)
        counter.finish()
        return ScanResult(
            roots: roots,
            candidates: total.candidates.sorted { $0.url.path < $1.url.path },
            folderCandidates: total.folderCandidates.sorted { $0.url.path < $1.url.path },
            allFiles: total.allFiles,
            emptyFolders: total.emptyFolders.sorted { $0.path < $1.path },
            protected: total.protected.sorted { $0.url.path < $1.url.path },
            linkTargets: total.linkTargets,
            scannedCount: counter.value,
            duration: Date().timeIntervalSince(started),
            notes: total.notes)
    }

    // MARK: Walking

    struct Entry: @unchecked Sendable {
        let url: URL
        let values: URLResourceValues
    }

    struct UnitStats {
        var size: Int64 = 0
        var count = 0
        var samples: [String] = []
        var blocked: String?
    }

    struct Accumulator {
        var candidates: [FileItem] = []
        var folderCandidates: [FolderItem] = []
        var allFiles: [FileItem] = []
        var emptyFolders: [URL] = []
        var protected: [ProtectedEntry] = []
        var linkTargets: [String: String] = [:]
        var notes: [String] = []

        mutating func merge(_ others: [Accumulator]) {
            for o in others {
                candidates += o.candidates
                folderCandidates += o.folderCandidates
                allFiles += o.allFiles
                emptyFolders += o.emptyFolders
                protected += o.protected
                notes += o.notes
                for (k, v) in o.linkTargets where linkTargets[k] == nil { linkTargets[k] = v }
            }
        }
    }

    func listEntries(_ dir: URL) -> [Entry] {
        let keys = ProtectionPolicy.resourceKeys
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) else {
            return []
        }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Entry(url: url, values: values)
        }
    }

    static let trivialNames: Set<String> = [".DS_Store", ".localized", "Icon\r", ".com.apple.timemachine.supported"]

    private func process(_ entry: Entry, root: ScanRoot, depth: Int, context: FileContext, siblings: Set<String>,
                         webPairs: Set<String>, acc: inout Accumulator, unit: inout UnitStats?,
                         counter: ProgressCounter, isCancelled: @Sendable () -> Bool) {
        if isCancelled() { return }
        let url = entry.url
        let values = entry.values
        let name = url.lastPathComponent
        counter.increment(path: url.path)
        if Self.trivialNames.contains(name) { return }

        if let reason = policy.itemProtection(url, values: values) {
            recordLinkTarget(url, reason: reason, acc: &acc)
            switch reason {
            case .hidden:
                // Hidden things are skipped silently except top-level folders (for transparency).
                if depth == 0 && values.isDirectory == true {
                    acc.protected.append(ProtectedEntry(url: url, reason: reason, isDirectory: true, modified: values.contentModificationDate))
                }
            default:
                acc.protected.append(ProtectedEntry(url: url, reason: reason, isDirectory: values.isDirectory == true,
                                                    modified: values.contentModificationDate ?? values.creationDate))
            }
            return
        }
        if webPairs.contains(name) {
            acc.protected.append(ProtectedEntry(url: url, reason: .savedWebPage, isDirectory: values.isDirectory == true))
            return
        }

        let isPackageDocument = values.isDirectory == true && (values.isPackage == true
            || ProtectionPolicy.movableDocumentPackages.contains(FileNameTools.split(name).ext.lowercased()))
        if values.isDirectory == true && !isPackageDocument {
            if root.mode == .looseOnly { return }
            let listing = listEntries(url)
            let names = listing.map { $0.url.lastPathComponent }
            switch policy.directoryClass(url, entries: names) {
            case let .protected(reason):
                acc.protected.append(ProtectedEntry(url: url, reason: reason, isDirectory: true, modified: values.contentModificationDate))
                if unit != nil, case .projectRoot = reason { unit?.blocked = "Enthält einen Projektordner (\(home.abbreviate(url)))" }
                if unit != nil, case .cloudSync = reason { unit?.blocked = "Enthält einen Cloud-Ordner" }
                return
            case let .movableProject(marker):
                if depth == 0 && (root.mode == .inbox || root.mode == .selected) && context == .loose {
                    let stats = quickStats(url)
                    acc.folderCandidates.append(FolderItem(url: url, kind: .project, size: stats.size, fileCount: stats.count,
                                                           modified: values.contentModificationDate, sampleNames: Array(names.prefix(15))))
                } else {
                    acc.protected.append(ProtectedEntry(url: url, reason: .projectRoot(marker: marker), isDirectory: true))
                    if unit != nil { unit?.blocked = "Enthält einen Projektordner" }
                }
                return
            case .normal:
                break
            }

            let childWebPairs = CohesionDetector.savedWebPageNames(in: names)
            let childSiblings = Set(names)
            if names.allSatisfy({ Self.trivialNames.contains($0) }) {
                if context != .inUnit { acc.emptyFolders.append(url) }
                return
            }

            if context == .inUnit {
                for child in listing {
                    process(child, root: root, depth: depth + 1, context: .inUnit, siblings: childSiblings,
                            webPairs: childWebPairs, acc: &acc, unit: &unit, counter: counter, isCancelled: isCancelled)
                }
                return
            }

            let infos = listing.map { EntryInfo(name: $0.url.lastPathComponent, isDirectory: $0.values.isDirectory == true && $0.values.isPackage != true) }
            let cohesive = depth == 0 ? CohesionDetector.kind(folderName: name, entries: infos, siblingNames: siblings) : nil
            let asUnit = depth == 0 && context == .loose && (root.mode == .inbox || (root.mode == .selected && cohesive != nil))

            if asUnit {
                var stats: UnitStats? = UnitStats()
                for child in listing {
                    process(child, root: root, depth: depth + 1, context: .inUnit, siblings: childSiblings,
                            webPairs: childWebPairs, acc: &acc, unit: &stats, counter: counter, isCancelled: isCancelled)
                }
                let s = stats ?? UnitStats()
                acc.folderCandidates.append(FolderItem(
                    url: url, kind: cohesive ?? .generic, size: s.size, fileCount: s.count,
                    modified: values.contentModificationDate, sampleNames: s.samples, blockedReason: s.blocked))
            } else {
                var none: UnitStats?
                for child in listing {
                    process(child, root: root, depth: depth + 1, context: .nested, siblings: childSiblings,
                            webPairs: childWebPairs, acc: &acc, unit: &none, counter: counter, isCancelled: isCancelled)
                }
            }
            return
        }

        // A file (or a document package such as .pages).
        let item = makeItem(url, values: values, context: context,
                            packageSize: isPackageDocument ? quickStats(url).size : nil)
        acc.allFiles.append(item)
        if unit != nil {
            unit?.size += item.size
            unit?.count += 1
            if (unit?.samples.count ?? 0) < 15 { unit?.samples.append(name) }
        }
        switch (root.mode, context) {
        case (.inbox, .loose), (.selected, .loose), (.looseOnly, .loose):
            acc.candidates.append(item)
        case (.selected, .nested) where general.includeSubfolderFiles && depth <= general.maxSubfolderDepth:
            acc.candidates.append(item)
        default:
            break
        }
    }

    private func recordLinkTarget(_ url: URL, reason: ProtectionReason, acc: inout Accumulator) {
        switch reason {
        case .symlink:
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                let target = dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : url.deletingLastPathComponent().appendingPathComponent(dest)
                acc.linkTargets[PathUtil.path(target.standardizedFileURL)] = "Symlink \(home.abbreviate(url))"
            }
        case .alias:
            if let target = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]) {
                acc.linkTargets[PathUtil.path(target)] = "Alias \(home.abbreviate(url))"
            }
        default:
            break
        }
    }

    func makeItem(_ url: URL, values: URLResourceValues, context: FileContext, packageSize: Int64? = nil) -> FileItem {
        FileItem(
            url: url,
            isPackage: values.isPackage == true,
            size: packageSize ?? Int64(values.fileSize ?? 0),
            created: values.creationDate,
            modified: values.contentModificationDate,
            accessed: values.contentAccessDate,
            addedToFolder: values.addedToDirectoryDate,
            typeIdentifier: values.contentType?.identifier,
            context: context,
            whereFroms: XAttr.whereFroms(url),
            quarantineAgent: XAttr.quarantineAgent(url),
            isScreenshot: XAttr.isScreenCapture(url))
    }

    /// Total size and file count of a folder (used for units and packages).
    func quickStats(_ url: URL) -> (size: Int64, count: Int) {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                              options: [], errorHandler: { _, _ in true }) else { return (0, 0) }
        var size: Int64 = 0
        var count = 0
        for case let child as URL in enumerator {
            guard let v = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            size += Int64(v.fileSize ?? 0)
            count += 1
        }
        return (size, count)
    }
}

/// Spotlight enrichment for files that are about to be planned (screenshots, camera, last use).
public enum MetadataEnricher {
    public static func enrich(_ items: [FileItem]) async -> [FileItem] {
        let chunks = stride(from: 0, to: items.count, by: 64).map { Array(items[$0..<min($0 + 64, items.count)]) }
        let results = await withTaskGroup(of: (Int, [FileItem]).self) { group -> [(Int, [FileItem])] in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    (index, chunk.map(enrich))
                }
            }
            var out: [(Int, [FileItem])] = []
            for await r in group { out.append(r) }
            return out
        }
        return results.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
    }

    public static func enrich(_ item: FileItem) -> FileItem {
        guard !item.spotlightLoaded else { return item }
        var copy = item
        let info = Spotlight.info(for: item.url)
        copy.isScreenshot = item.isScreenshot || info.isScreenCapture
        copy.cameraModel = info.cameraModel
        // Spotlight reports the file system date for ordinary files; only keep real capture dates.
        if let captured = info.contentCreated, let created = item.created, abs(captured.timeIntervalSince(created)) < 120 {
            copy.contentCreated = nil
        } else {
            copy.contentCreated = info.contentCreated
        }
        copy.lastUsed = info.lastUsed
        copy.spotlightLoaded = true
        return copy
    }
}

final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var lastReport = Date.distantPast
    private let callback: (@Sendable (ScanProgress) -> Void)?

    init(callback: (@Sendable (ScanProgress) -> Void)?) {
        self.callback = callback
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment(path: String) {
        lock.lock()
        count += 1
        let now = Date()
        let shouldReport = now.timeIntervalSince(lastReport) > 0.1
        if shouldReport { lastReport = now }
        let current = count
        lock.unlock()
        if shouldReport { callback?(ScanProgress(scannedItems: current, currentPath: path, phase: "Scanne")) }
    }

    func finish() {
        callback?(ScanProgress(scannedItems: value, currentPath: "", phase: "Fertig"))
    }
}
