import Foundation

/// "Automatik": once a day at a fixed time (e.g. 10:00) a few folders are scanned and sorted.
/// A run that was missed (Mac asleep or off, app not running) is made up for later the same day.
public enum DailySchedule {
    public static func scheduledTime(on day: Date, hour: Int, minute: Int, calendar: Calendar = .current) -> Date? {
        calendar.date(bySettingHour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59), second: 0, of: day)
    }

    /// Due when today's time has passed, nothing ran today yet, and the reference (last run, or
    /// the moment the automation was switched on) lies before today's time. Switching it on in the
    /// afternoon therefore starts tomorrow, not immediately.
    public static func isDue(now: Date, lastRun: Date?, enabledAt: Date?, hour: Int, minute: Int,
                             calendar: Calendar = .current) -> Bool {
        guard let today = scheduledTime(on: now, hour: hour, minute: minute, calendar: calendar), now >= today else { return false }
        if let lastRun, calendar.isDate(lastRun, inSameDayAs: now) { return false }
        guard let reference = lastRun ?? enabledAt else { return true }
        return reference < today
    }

    public static func nextRun(now: Date, lastRun: Date?, enabledAt: Date?, hour: Int, minute: Int,
                               calendar: Calendar = .current) -> Date? {
        if isDue(now: now, lastRun: lastRun, enabledAt: enabledAt, hour: hour, minute: minute, calendar: calendar) { return now }
        guard let today = scheduledTime(on: now, hour: hour, minute: minute, calendar: calendar) else { return nil }
        if now < today { return today }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
        return scheduledTime(on: tomorrow, hour: hour, minute: minute, calendar: calendar)
    }
}

/// Splits a plan into actions that run automatically and items for "Zur Prüfung", then executes.
/// Shared by the background mode and the daily automation.
enum AutoExecution {
    static func apply(plan: Plan, home: HomeContext, journal: Journal, reviewUnsorted: Bool,
                      title: (Int) -> String,
                      autoAction: (PlannedAction) -> PlannedAction?,
                      execute: ([PlannedAction], String) -> ExecutionResult) -> BackgroundOutcome {
        var outcome = BackgroundOutcome()
        var auto: [PlannedAction] = []
        func review(_ action: PlannedAction) {
            journal.addReviewItem(path: action.source.path, suggestedFolder: action.destinationFolder.map { home.abbreviate($0) },
                                  suggestedName: action.newName, confidence: action.confidence, reason: action.reason)
            outcome.reviewCount += 1
        }
        for action in plan.actions {
            if var chosen = autoAction(action) {
                chosen.isSelected = true
                auto.append(chosen)
            } else if action.kind == .move || action.kind == .rename {
                review(action)
            }
        }
        if reviewUnsorted {
            for item in plan.unsorted {
                journal.addReviewItem(path: item.url.path, suggestedFolder: nil, suggestedName: nil, confidence: 0,
                                      reason: "Kein sicherer Zielordner gefunden")
                outcome.reviewCount += 1
            }
        } else {
            outcome.leftAlone = plan.unsorted.count
        }
        if !auto.isEmpty {
            let result = execute(auto, title(auto.count))
            outcome.runID = result.runID
            let done = Set(journal.entries(runID: result.runID).filter { $0.status == .done }.map(\.sourcePath))
            outcome.moved = auto.filter { done.contains($0.source.path) }
            outcome.messages = result.messages
            for action in auto where !done.contains(action.source.path) && PathUtil.exists(action.source) {
                review(action)
            }
        }
        return outcome
    }
}

/// One automatic sorting run over a few folders (the daily automation and "Jetzt ausführen").
public struct AutoSorter: Sendable {
    public let home: HomeContext
    public let journal: Journal
    public let autoThreshold: Double
    public let allowRenames: Bool
    /// Files changed more recently than this are left for the next run (they may still be in use).
    public var minimumAge: TimeInterval = 120
    let makePolicy: @Sendable () -> ProtectionPolicy
    let makeScanner: @Sendable (ProtectionPolicy) -> FileScanner
    let makePlanner: @Sendable (ProtectionPolicy) -> Planner
    let executor: @Sendable (ProtectionPolicy) -> Executor

    public init(home: HomeContext, journal: Journal, autoThreshold: Double, allowRenames: Bool,
                makePolicy: @escaping @Sendable () -> ProtectionPolicy,
                makeScanner: @escaping @Sendable (ProtectionPolicy) -> FileScanner,
                makePlanner: @escaping @Sendable (ProtectionPolicy) -> Planner,
                executor: @escaping @Sendable (ProtectionPolicy) -> Executor) {
        self.home = home
        self.journal = journal
        self.autoThreshold = autoThreshold
        self.allowRenames = allowRenames
        self.makePolicy = makePolicy
        self.makeScanner = makeScanner
        self.makePlanner = makePlanner
        self.executor = executor
    }

    /// Only plain file moves/renames without warnings and with high confidence run on their own.
    /// Folders, Trash and archives never run automatically.
    func autoAction(_ action: PlannedAction) -> PlannedAction? {
        guard action.warnings.isEmpty, action.confidence >= autoThreshold else { return nil }
        switch action.kind {
        case .move:
            var copy = action
            if !allowRenames { copy.newName = nil }
            return copy
        case .rename:
            return allowRenames ? action : nil
        case .moveFolder, .trash, .archive:
            return nil
        }
    }

    public func run(folders: [URL], now: Date = Date(), source: String = "schedule",
                    isCancelled: @escaping @Sendable () -> Bool = { false }) async -> BackgroundOutcome {
        let existing = folders.map(PathUtil.normalizeRoot).filter(PathUtil.isDirectory)
        guard !existing.isEmpty else {
            var outcome = BackgroundOutcome()
            outcome.messages = ["Keiner der Ordner für die Automatik existiert."]
            return outcome
        }
        let policy = makePolicy()
        var scan = await makeScanner(policy).scan(.folders(existing), isCancelled: isCancelled)
        let fresh = now.addingTimeInterval(-minimumAge)
        scan.candidates.removeAll { item in
            [item.modified, item.created, item.addedToFolder].compactMap { $0 }.contains { $0 > fresh }
        }
        guard !isCancelled() else { return BackgroundOutcome() }
        let plan = await makePlanner(policy).plan(scan: scan, mode: .sortAndRename, isCancelled: isCancelled)
        guard !isCancelled() else { return BackgroundOutcome() }
        let names = existing.map(\.lastPathComponent).joined(separator: ", ")
        var outcome = AutoExecution.apply(
            plan: plan, home: home, journal: journal, reviewUnsorted: false,
            title: { count in "Automatik: \(count) Datei\(count == 1 ? "" : "en") (\(names))" },
            autoAction: autoAction,
            execute: { actions, title in executor(policy).execute(actions, title: title, source: source) })
        outcome.messages += plan.aiStats.errors
        Log.background.info("automation run: \(outcome.summary, privacy: .public)")
        return outcome
    }
}
