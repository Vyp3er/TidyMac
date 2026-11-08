import CoreServices
import Foundation

/// Watches folders with FSEvents and reports changed paths.
public final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let queue = DispatchQueue(label: "de.tidymac.fsevents")
    private let handler: @Sendable ([String]) -> Void

    public init(folders: [URL], handler: @escaping @Sendable ([String]) -> Void) {
        self.paths = folders.map(\.path)
        self.handler = handler
    }

    deinit { stop() }

    public func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            let changed = (array as? [String]) ?? []
            if !changed.isEmpty && count > 0 { watcher.handler(changed) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

public struct BackgroundOutcome: Sendable {
    public var runID: String?
    public var moved: [PlannedAction] = []
    public var reviewCount = 0
    /// Files without a confident target that were simply left where they are.
    public var leftAlone = 0
    public var messages: [String] = []

    public init() {}

    public var summary: String {
        var parts: [String] = []
        if !moved.isEmpty { parts.append("\(moved.count) Datei\(moved.count == 1 ? "" : "en") einsortiert") }
        if reviewCount > 0 { parts.append("\(reviewCount) zur Prüfung") }
        return parts.joined(separator: ", ")
    }
}

/// Background mode: new files in watched folders are sorted after they have settled
/// (download finished, size stable, not open). Only safe rules / very high confidence run
/// automatically; everything else goes to the "Zur Prüfung" list.
public final class BackgroundOrganizer: @unchecked Sendable {
    struct Pending {
        var firstSeen: Date
        var lastChange: Date
        var lastSize: Int64
        var lastModified: Date?
    }

    public let watchedFolders: [URL]
    public let settleSeconds: TimeInterval
    public let autoThreshold: Double
    let makePlanner: @Sendable (ProtectionPolicy) -> Planner
    let makePolicy: @Sendable () -> ProtectionPolicy
    let executor: @Sendable (ProtectionPolicy) -> Executor
    let journal: Journal
    let openFiles: OpenFilesProvider
    let home: HomeContext

    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    private var processing = false

    public init(home: HomeContext, watchedFolders: [URL], settleSeconds: TimeInterval, autoThreshold: Double, journal: Journal,
                openFiles: OpenFilesProvider = ProcOpenFilesProvider(),
                makePolicy: @escaping @Sendable () -> ProtectionPolicy,
                makePlanner: @escaping @Sendable (ProtectionPolicy) -> Planner,
                executor: @escaping @Sendable (ProtectionPolicy) -> Executor) {
        self.home = home
        self.watchedFolders = watchedFolders.map(PathUtil.normalizeRoot)
        self.settleSeconds = max(5, settleSeconds)
        self.autoThreshold = autoThreshold
        self.journal = journal
        self.openFiles = openFiles
        self.makePolicy = makePolicy
        self.makePlanner = makePlanner
        self.executor = executor
    }

    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    /// Feed FSEvents paths. Only items directly inside a watched folder are considered.
    public func note(paths: [String], now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        for raw in paths {
            let url = URL(fileURLWithPath: raw).standardizedFileURL
            let parent = url.deletingLastPathComponent()
            guard watchedFolders.contains(where: { PathUtil.isSame($0, parent) }) else { continue }
            guard !url.lastPathComponent.hasPrefix("."), PathUtil.exists(url) else {
                pending.removeValue(forKey: url.path)
                continue
            }
            let (size, modified) = Self.sizeAndDate(url)
            if var p = pending[url.path] {
                if p.lastSize != size || p.lastModified != modified {
                    p.lastChange = now
                    p.lastSize = size
                    p.lastModified = modified
                }
                pending[url.path] = p
            } else {
                pending[url.path] = Pending(firstSeen: now, lastChange: now, lastSize: size, lastModified: modified)
            }
        }
    }

    static func sizeAndDate(_ url: URL) -> (Int64, Date?) {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (Int64(v?.fileSize ?? 0), v?.contentModificationDate)
    }

    /// Files that have settled: unchanged for `settleSeconds`, complete, not open.
    func readyPaths(now: Date) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let open = openFiles.openPaths()
        var ready: [URL] = []
        for (path, var p) in pending {
            let url = URL(fileURLWithPath: path)
            guard PathUtil.exists(url) else { pending.removeValue(forKey: path); continue }
            let (size, modified) = Self.sizeAndDate(url)
            if size != p.lastSize || modified != p.lastModified {
                p.lastChange = now
                p.lastSize = size
                p.lastModified = modified
                pending[path] = p
                continue
            }
            let ext = FileNameTools.split(url.lastPathComponent).ext.lowercased()
            if ProtectionPolicy.incompleteDownloadExtensions.contains(ext) { continue }
            guard now.timeIntervalSince(p.lastChange) >= settleSeconds else { continue }
            if OpenFileCheck.isInUse(url, open: open) { p.lastChange = now; pending[path] = p; continue }
            ready.append(url)
            pending.removeValue(forKey: path)
        }
        return ready
    }

    /// Call periodically (e.g. every 10 s).
    public func tick(now: Date = Date()) async -> BackgroundOutcome? {
        let busy = lock.withLock { () -> Bool in
            if processing { return true }
            processing = true
            return false
        }
        if busy { return nil }
        defer { lock.withLock { processing = false } }

        let ready = readyPaths(now: now)
        guard !ready.isEmpty else { return nil }
        let policy = makePolicy()
        let scanner = FileScanner(home: home, policy: policy, general: GeneralSettings())
        var candidates: [FileItem] = []
        for url in ready {
            guard let values = try? url.resourceValues(forKeys: Set(ProtectionPolicy.resourceKeys)) else { continue }
            if values.isDirectory == true && values.isPackage != true { continue } // folders: never automatic
            if policy.itemProtection(url, values: values) != nil || policy.ancestorProtection(of: url) != nil { continue }
            candidates.append(scanner.makeItem(url, values: values, context: .loose))
        }
        guard !candidates.isEmpty else { return nil }

        let scan = ScanResult(roots: watchedFolders.map { ScanRoot(url: $0, mode: .inbox) }, candidates: candidates)
        let plan = await makePlanner(policy).plan(scan: scan)
        let threshold = autoThreshold
        let outcome = AutoExecution.apply(
            plan: plan, home: home, journal: journal, reviewUnsorted: true,
            title: { count in "Hintergrund: \(count) Datei\(count == 1 ? "" : "en")" },
            autoAction: { action in
                action.kind == .move && action.warnings.isEmpty && action.confidence >= threshold ? action : nil
            },
            execute: { actions, title in executor(policy).execute(actions, title: title, source: "background") })
        Log.background.info("background tick: \(outcome.summary, privacy: .public)")
        return outcome
    }
}
