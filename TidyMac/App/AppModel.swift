import AppKit
import Observation
import SwiftUI
import TidyCore

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case sort, duplicates, cleanup, review, protected, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sort: return "Aufräumen"
        case .duplicates: return "Duplikate"
        case .cleanup: return "Aufräum-Vorschläge"
        case .review: return "Zur Prüfung"
        case .protected: return "Geschützt"
        case .history: return "Verlauf"
        }
    }

    var symbol: String {
        switch self {
        case .sort: return "wand.and.stars"
        case .duplicates: return "doc.on.doc"
        case .cleanup: return "trash.slash"
        case .review: return "tray.full"
        case .protected: return "lock.shield"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

enum ScanScope: String, CaseIterable, Identifiable {
    case selected, everything
    var id: String { rawValue }
    var title: String { self == .everything ? "Alles (Home-Ordner)" : "Ausgewählte Ordner" }
}

enum ActionFilter: String, CaseIterable, Identifiable {
    case all, selected, lowConfidence, warnings, ai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Alle"
        case .selected: return "Ausgewählt"
        case .lowConfidence: return "Unsicher"
        case .warnings: return "Mit Warnung"
        case .ai: return "Von Claude"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let home: HomeContext = DebugOptions.home ?? .current
    private(set) var journal: Journal?
    let background = BackgroundService()

    var settings: TidySettings {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
            if settings.background != oldValue.background || settings.ai.useInBackground != oldValue.ai.useInBackground
                || settings.protection != oldValue.protection || settings.rules != oldValue.rules {
                configureBackground()
            }
            if settings.ai.provider != oldValue.ai.provider || settings.ai.cliPath != oldValue.ai.cliPath
                || settings.ai.apiModel != oldValue.ai.apiModel {
                aiStatus = nil
            }
        }
    }

    var apiKey: String {
        didSet { if apiKey != oldValue { Keychain.save(apiKey); aiStatus = nil } }
    }

    // Navigation
    var selection: SidebarItem? = .sort
    var showOnboarding = false

    // Scan & plan
    var scope: ScanScope = .selected
    var planMode: PlanMode = .sortAndRename
    var isWorking = false
    var workTitle = ""
    var progressText = ""
    var progressCount = 0
    var scanResult: ScanResult?
    var plan: Plan?
    var actions: [PlannedAction] = []
    var filter: ActionFilter = .all
    var lastResult: ExecutionResult?
    var lastResultTitle = ""
    var errorMessage: String?
    private let cancelFlag = CancelFlag()

    // Duplicates & clean-up
    var duplicateGroups: [DuplicateGroup] = []
    var duplicateSelection: Set<String> = []
    var cleanupSuggestions: [CleanupSuggestion] = []
    var hasSearchedDuplicates = false
    var hasSearchedCleanup = false

    // Review & history
    var reviewItems: [ReviewItem] = []
    var runs: [RunRecord] = []

    // AI
    var aiStatus: AIAvailability?
    var isCheckingAI = false
    var cacheCount = 0

    var fullDiskAccess = FullDiskAccess.isGranted

    private init() {
        let env = TidyEnvironment(home: DebugOptions.home ?? .current, settings: TidySettings(), supportDirectory: DebugOptions.supportDirectory)
        settings = TidySettings.load(from: env.settingsURL)
        apiKey = Keychain.read() ?? ""
        journal = try? env.makeJournal()
        showOnboarding = !settings.general.onboardingDone
        refreshHistory()
        refreshReview()
        NotificationManager.shared.onUndo = { [weak self] runID in self?.undoRun(runID) }
        NotificationManager.shared.onOpenReview = { [weak self] in
            self?.selection = .review
            NSApp.activate()
        }
        configureBackground()
    }

    var environment: TidyEnvironment {
        TidyEnvironment(home: home, settings: settings, supportDirectory: DebugOptions.supportDirectory,
                        apiKey: apiKey.isEmpty ? nil : apiKey)
    }

    private func saveSettings() {
        try? settings.save(to: environment.settingsURL)
    }

    // MARK: Folders

    var selectedFolders: [URL] { settings.general.selectedFolders.map { home.expand($0) } }

    func addFolders(_ urls: [URL]) {
        for url in urls where PathUtil.isDirectory(url) {
            let path = home.abbreviate(url)
            if !settings.general.selectedFolders.contains(path) { settings.general.selectedFolders.append(path) }
        }
        scope = .selected
    }

    func removeFolder(_ path: String) {
        settings.general.selectedFolders.removeAll { $0 == path }
    }

    // MARK: Scan + plan

    var currentTarget: ScanTarget {
        scope == .everything ? .everything : .folders(selectedFolders)
    }

    func startScan(_ target: ScanTarget? = nil) {
        guard !isWorking else { return }
        let target = target ?? currentTarget
        if case let .folders(urls) = target, urls.isEmpty {
            errorMessage = "Bitte zuerst mindestens einen Ordner auswählen."
            return
        }
        isWorking = true
        workTitle = "Scan & Vorschau"
        progressText = "Starte Scan …"
        progressCount = 0
        plan = nil
        actions = []
        lastResult = nil
        errorMessage = nil
        cancelFlag.reset()
        let env = environment
        let mode = planMode
        let flag = cancelFlag
        let extraRoots: [URL]
        if case let .folders(urls) = target { extraRoots = urls } else { extraRoots = [] }

        Task {
            let progress: @Sendable (ScanProgress) -> Void = { p in
                Task { @MainActor in
                    AppModel.shared.progressCount = p.scannedItems
                    AppModel.shared.progressText = p.currentPath.isEmpty ? p.phase : "\(p.phase): \(p.currentPath)"
                }
            }
            let planProgress: @Sendable (String) -> Void = { text in
                Task { @MainActor in AppModel.shared.progressText = text }
            }
            let (scan, plan) = await Task.detached(priority: .userInitiated) { () -> (ScanResult, Plan) in
                let policy = env.makePolicy(extraRoots: extraRoots)
                let scan = await env.makeScanner(policy: policy).scan(target, progress: progress, isCancelled: { flag.isSet })
                if flag.isSet { return (scan, Plan()) }
                planProgress("Lese vorhandene Ordnerstruktur …")
                let provider = env.makeProvider()
                var plan = await env.makePlanner(policy: policy, provider: provider)
                    .plan(scan: scan, mode: mode, progress: planProgress, isCancelled: { flag.isSet })
                if env.settings.ai.provider != .off && provider == nil {
                    plan.notes.insert("KI nicht verfügbar (\(env.settings.ai.provider.displayName)) – nur Regeln verwendet.", at: 0)
                }
                return (scan, plan)
            }.value
            self.scanResult = scan
            if !flag.isSet {
                self.plan = plan
                self.actions = plan.actions
            }
            self.isWorking = false
            self.cacheCount = env.makeCache()?.count() ?? 0
        }
    }

    func cancelWork() {
        cancelFlag.set()
        progressText = "Breche ab …"
    }

    // MARK: ID-based bindings (rows must survive removals while SwiftUI re-renders)

    func actionBinding(_ id: UUID, fallback: PlannedAction) -> Binding<PlannedAction> {
        Binding(
            get: { self.actions.first { $0.id == id } ?? fallback },
            set: { newValue in
                if let i = self.actions.firstIndex(where: { $0.id == id }) { self.actions[i] = newValue }
            })
    }

    func setSelected(_ ids: [UUID], _ value: Bool) {
        let set = Set(ids)
        for i in actions.indices where set.contains(actions[i].id) { actions[i].isSelected = value }
    }

    func cleanupChoiceBinding(_ id: UUID) -> Binding<CleanupChoice> {
        Binding(
            get: { self.cleanupSuggestions.first { $0.id == id }?.choice ?? .keep },
            set: { newValue in
                if let i = self.cleanupSuggestions.firstIndex(where: { $0.id == id }) { self.cleanupSuggestions[i].choice = newValue }
            })
    }

    func ruleBinding(_ id: String, fallback: SortRule) -> Binding<SortRule> {
        Binding(
            get: { self.settings.rules.userRules.first { $0.id == id } ?? fallback },
            set: { newValue in
                if let i = self.settings.rules.userRules.firstIndex(where: { $0.id == id }) { self.settings.rules.userRules[i] = newValue }
            })
    }

    // MARK: Execute

    var selectedActionCount: Int { actions.filter(\.isSelected).count }

    func executeSelected() {
        let chosen = actions.filter(\.isSelected)
        execute(chosen, title: titleForRun()) { [weak self] result in
            guard let self else { return }
            let done = Set(self.journal?.entries(runID: result.runID).filter { $0.status == .done }.map(\.sourcePath) ?? [])
            self.actions.removeAll { done.contains($0.source.path) }
        }
    }

    private func titleForRun() -> String {
        switch currentTarget {
        case .everything: return "Alles aufgeräumt"
        case let .folders(urls): return "Aufgeräumt: " + urls.map(\.lastPathComponent).joined(separator: ", ")
        }
    }

    func execute(_ chosen: [PlannedAction], title: String, completion: (@MainActor (ExecutionResult) -> Void)? = nil) {
        guard !chosen.isEmpty, let journal, !isWorking else { return }
        isWorking = true
        workTitle = "Ausführen"
        progressText = "Führe \(chosen.count) Aktionen aus …"
        let env = environment
        let roots = chosen.map { $0.source.deletingLastPathComponent() }
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ExecutionResult in
                let policy = env.makePolicy(extraRoots: roots.filter { !env.home.contains($0) })
                return Executor(home: env.home, policy: policy, journal: journal).execute(chosen, title: title)
            }.value
            self.lastResult = result
            self.lastResultTitle = title
            self.isWorking = false
            completion?(result)
            self.refreshHistory()
        }
    }

    // MARK: Undo & history

    func undoRun(_ runID: String) {
        guard let journal else { return }
        let env = environment
        Task {
            let result = await Task.detached { Executor(home: env.home, policy: env.makePolicy(), journal: journal).undoRun(runID) }.value
            if self.lastResult?.runID == runID { self.lastResult = nil }
            self.errorMessage = result.failed > 0 ? "Rückgängig: \(result.restored) wiederhergestellt, \(result.failed) fehlgeschlagen.\n" + result.messages.joined(separator: "\n") : nil
            self.refreshHistory()
        }
    }

    func undoEntry(_ entryID: String) {
        guard let journal else { return }
        let env = environment
        Task {
            let result = await Task.detached { Executor(home: env.home, policy: env.makePolicy(), journal: journal).undoEntry(entryID) }.value
            if result.failed > 0 { self.errorMessage = result.messages.joined(separator: "\n") }
            self.refreshHistory()
        }
    }

    func refreshHistory() {
        runs = journal?.runs(limit: 100) ?? []
    }

    func entries(for runID: String) -> [JournalEntry] {
        journal?.entries(runID: runID) ?? []
    }

    // MARK: Duplicates

    func findDuplicates() {
        guard !isWorking else { return }
        isWorking = true
        workTitle = "Duplikate"
        progressText = "Scanne …"
        cancelFlag.reset()
        let env = environment
        let target = currentTarget
        let flag = cancelFlag
        Task {
            let groups = await Task.detached(priority: .userInitiated) { () -> [DuplicateGroup] in
                let policy = env.makePolicy()
                let scan = await env.makeScanner(policy: policy).scan(target, isCancelled: { flag.isSet })
                return await DuplicateFinder(home: env.home).find(in: scan.allFiles, progress: { text in
                    Task { @MainActor in AppModel.shared.progressText = text }
                }, isCancelled: { flag.isSet })
            }.value
            self.duplicateGroups = groups
            self.duplicateSelection = Set(groups.flatMap { $0.removable.map(\.url.path) })
            self.hasSearchedDuplicates = true
            self.isWorking = false
        }
    }

    func setKeeper(groupID: String, index: Int) {
        guard let g = duplicateGroups.firstIndex(where: { $0.id == groupID }) else { return }
        duplicateGroups[g].keeperIndex = index
        duplicateGroups[g].keeperReason = "Manuell gewählt"
        let group = duplicateGroups[g]
        for (i, file) in group.files.enumerated() {
            if i == index || file.context == .inUnit { duplicateSelection.remove(file.url.path) } else { duplicateSelection.insert(file.url.path) }
        }
    }

    var duplicateActions: [PlannedAction] {
        DuplicateFinder(home: home).actions(for: duplicateGroups).filter { duplicateSelection.contains($0.source.path) }
    }

    func trashDuplicates() {
        let chosen = duplicateActions
        execute(chosen, title: "Duplikate in den Papierkorb") { [weak self] _ in
            guard let self else { return }
            let gone = Set(chosen.map(\.source.path)).filter { !PathUtil.exists(URL(fileURLWithPath: $0)) }
            self.duplicateGroups = self.duplicateGroups.compactMap { group in
                var g = group
                let keeper = g.keeper
                g.files.removeAll { gone.contains($0.url.path) }
                guard g.files.count > 1, let idx = g.files.firstIndex(of: keeper) else { return nil }
                g.keeperIndex = idx
                return g.removable.isEmpty ? nil : g
            }
            self.duplicateSelection.subtract(gone)
        }
    }

    // MARK: Clean-up

    func findCleanup() {
        guard !isWorking else { return }
        isWorking = true
        workTitle = "Aufräum-Vorschläge"
        progressText = "Scanne …"
        cancelFlag.reset()
        let env = environment
        let target = currentTarget
        let flag = cancelFlag
        Task {
            let suggestions = await Task.detached(priority: .userInitiated) { () -> [CleanupSuggestion] in
                let policy = env.makePolicy()
                let scan = await env.makeScanner(policy: policy).scan(target, isCancelled: { flag.isSet })
                return await CleanupAdvisor(home: env.home, settings: env.settings.cleanup).suggestions(for: scan)
            }.value
            self.cleanupSuggestions = suggestions
            self.hasSearchedCleanup = true
            self.isWorking = false
        }
    }

    var cleanupActions: [PlannedAction] {
        CleanupAdvisor(home: home, settings: settings.cleanup).actions(for: cleanupSuggestions)
    }

    func executeCleanup() {
        let chosen = cleanupActions
        execute(chosen, title: "Aufräum-Vorschläge umgesetzt") { [weak self] _ in
            guard let self else { return }
            self.cleanupSuggestions.removeAll { s in s.choice != .keep && !PathUtil.exists(s.url) }
        }
    }

    // MARK: Review queue

    func refreshReview() {
        reviewItems = (journal?.reviewItems() ?? []).filter { PathUtil.exists(URL(fileURLWithPath: $0.path)) }
    }

    func acceptReview(_ item: ReviewItem, folder: URL? = nil) {
        let source = URL(fileURLWithPath: item.path)
        let target = folder ?? item.suggestedFolder.map { home.expand($0) }
        let action: PlannedAction
        if let target, !PathUtil.isSame(target, source.deletingLastPathComponent()) {
            action = PlannedAction(kind: .move, source: source, destinationFolder: target, newName: item.suggestedName,
                                   reason: item.reason, confidence: item.confidence, origin: .manual)
        } else if let name = item.suggestedName {
            action = PlannedAction(kind: .rename, source: source, destinationFolder: source.deletingLastPathComponent(),
                                   newName: name, reason: item.reason, confidence: item.confidence, origin: .manual)
        } else {
            errorMessage = "Kein Ziel – bitte „Ziel wählen …“ benutzen."
            return
        }
        execute([action], title: "Geprüft: \(source.lastPathComponent)") { [weak self] result in
            if result.done > 0 { self?.journal?.removeReviewItem(id: item.id) }
            self?.refreshReview()
        }
    }

    func dismissReview(_ item: ReviewItem) {
        journal?.removeReviewItem(id: item.id)
        refreshReview()
    }

    // MARK: Background

    func configureBackground() {
        background.configure(settings: settings, environment: environment, journal: journal) { [weak self] outcome in
            guard let self else { return }
            self.refreshReview()
            self.refreshHistory()
            guard self.settings.background.notify, !outcome.summary.isEmpty else { return }
            let names = outcome.moved.prefix(3).map { $0.source.lastPathComponent }.joined(separator: ", ")
            NotificationManager.shared.post(title: "TidyMac: \(outcome.summary)",
                                            body: names.isEmpty ? "Siehe „Zur Prüfung“." : names + (outcome.moved.count > 3 ? " …" : ""),
                                            runID: outcome.runID)
        }
    }

    // MARK: AI status

    func checkAI() {
        isCheckingAI = true
        let env = environment
        Task {
            let status = await Task.detached { () -> AIAvailability in
                guard let provider = env.makeProvider() else {
                    switch env.settings.ai.provider {
                    case .off: return AIAvailability(isAvailable: false, summary: "KI ist ausgeschaltet – nur Regeln.")
                    case .claudeCLI: return AIAvailability(isAvailable: false, summary: "Claude Code CLI nicht gefunden",
                                                           detail: "Installieren: https://claude.com/claude-code – danach im Terminal `claude` starten und anmelden.")
                    case .anthropicAPI: return AIAvailability(isAvailable: false, summary: "Kein API-Key hinterlegt")
                    }
                }
                return await provider.checkAvailability()
            }.value
            self.aiStatus = status
            self.isCheckingAI = false
            self.cacheCount = env.makeCache()?.count() ?? 0
        }
    }

    func clearAICache() {
        environment.makeCache()?.clear()
        cacheCount = 0
    }

    func refreshFullDiskAccess() {
        fullDiskAccess = FullDiskAccess.isGranted
    }

    func finishOnboarding() {
        settings.general.onboardingDone = true
        showOnboarding = false
    }
}
