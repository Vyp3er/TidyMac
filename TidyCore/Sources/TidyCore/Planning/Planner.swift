import Foundation

public enum PlanMode: String, Sendable, Codable, CaseIterable {
    case sortAndRename
    case renameOnly

    public var displayName: String {
        switch self {
        case .sortAndRename: return "Sortieren & umbenennen"
        case .renameOnly: return "Nur umbenennen"
        }
    }
}

/// Hybrid planning: fast rules first, Claude only for unclear cases. Produces a dry-run plan;
/// nothing on disk changes here.
public final class Planner: @unchecked Sendable {
    public let home: HomeContext
    public let policy: ProtectionPolicy
    public let engine: RuleEngine
    public let structure: StructureIndex
    public let provider: AIProvider?
    public let cache: AICache?
    public let general: GeneralSettings
    public let aiSettings: AISettings
    public let privacy: PrivacyFilter
    public let renamer: Renamer
    public var now: () -> Date = { Date() }
    /// Inboxes that are emptied into `documentsRoot` (e.g. Downloads → Documents).
    public let documentsInboxes: [URL]
    public let documentsRoot: URL

    public init(home: HomeContext, policy: ProtectionPolicy, engine: RuleEngine, structure: StructureIndex,
                provider: AIProvider?, cache: AICache?, general: GeneralSettings, aiSettings: AISettings) {
        self.home = home
        self.policy = policy
        self.engine = engine
        self.structure = structure
        self.provider = provider
        self.cache = cache
        self.general = general
        self.aiSettings = aiSettings
        self.privacy = PrivacyFilter(home: home, settings: aiSettings)
        self.renamer = Renamer(scheme: general.renameScheme, mediaWithDate: general.renameMediaWithDate)
        self.documentsInboxes = general.inboxToDocuments.filter { !$0.isEmpty }.map { PathUtil.normalizeRoot(home.expand($0)) }
        let root = PathUtil.normalizeRoot(home.expand(general.documentsRoot))
        self.documentsRoot = home.contains(root) && !PathUtil.isSame(root, home.home) ? root : PathUtil.normalizeRoot(home.documents)
    }

    /// Files directly inside such an inbox must leave it (sorted into Documents).
    func isDocumentsInbox(_ folder: URL) -> Bool {
        documentsInboxes.contains { PathUtil.isSame($0, folder) } && !PathUtil.isDescendant(folder, of: documentsRoot)
    }

    static let screenshotName = try? NSRegularExpression(pattern: #"^(Bildschirmfoto|Screenshot|Screen Shot|CleanShot) \d{4}-\d{2}-\d{2}"#, options: [.caseInsensitive])
    static let recordingName = try? NSRegularExpression(pattern: #"^(Bildschirmaufnahme|Screen Recording|Bildschirmaufzeichnung)"#, options: [.caseInsensitive])

    static func matches(_ re: NSRegularExpression?, _ s: String) -> Bool {
        guard let re else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Category folder under Documents by file type, used when nothing better is known.
    func documentsCategory(for item: FileItem) -> RuleMatch {
        let template: String
        let confidence: Double
        let name: String
        if item.isScreenshot || (item.kind == .image && Self.matches(Self.screenshotName, item.name)) {
            (template, confidence, name) = ("Bilder/Bildschirmfotos/{year}", 0.95, "Bildschirmfotos")
        } else if item.kind == .video && Self.matches(Self.recordingName, item.name) {
            (template, confidence, name) = ("Videos/Bildschirmaufnahmen/{year}", 0.95, "Bildschirmaufnahmen")
        } else if item.looksLikeCameraPhoto {
            (template, confidence, name) = ("Bilder/Fotos/{year}", 0.88, "Fotos")
        } else {
            switch item.kind {
            case .image, .rawImage: (template, confidence, name) = ("Bilder", 0.8, "Bilder")
            case .video: (template, confidence, name) = ("Videos", 0.8, "Videos")
            case .audio: (template, confidence, name) = ("Audio", 0.8, "Audio")
            case .archive: (template, confidence, name) = ("Archive", 0.75, "Archive")
            case .code: (template, confidence, name) = ("Code", 0.75, "Code")
            case .ebook: (template, confidence, name) = ("Bücher", 0.9, "Bücher")
            case .font: (template, confidence, name) = ("Schriften", 0.88, "Schriften")
            case .model3D: (template, confidence, name) = ("3D-Modelle", 0.85, "3D-Modelle")
            case .spreadsheet: (template, confidence, name) = ("Tabellen", 0.7, "Tabellen")
            case .presentation: (template, confidence, name) = ("Präsentationen", 0.7, "Präsentationen")
            case .pdf, .document, .text: (template, confidence, name) = ("Unterlagen", 0.7, "Unterlagen")
            case .calendar, .contact: (template, confidence, name) = ("Kontakte und Termine", 0.8, "Kontakte und Termine")
            case .installer, .diskImage, .torrent, .other: (template, confidence, name) = ("Sonstiges", 0.65, "Sonstiges")
            }
        }
        let rendered = TemplateRenderer.render(template, item: item)
        let folder = engine.resolver.resolve(documentsRoot.appendingPathComponent(rendered, isDirectory: true))
        let rule = SortRule(id: "documents.category", name: "Kategorie \(name)", conditions: [],
                            destination: home.abbreviate(documentsRoot) + "/" + template, confidence: confidence, isBuiltIn: true)
        return RuleMatch(rule: rule, destinationFolder: folder, newName: nil, confidence: confidence, isUserRule: false)
    }

    struct Decision {
        var item: FileItem
        var folder: URL?
        var description: String?
        var confidence: Double
        var reason: String
        var origin: ActionOrigin
        var ruleNewName: String?
        var warnings: [String] = []
    }

    struct AIJob {
        var item: FileItem
        var hint: RuleMatch?
        var needsName: Bool
        var cacheKey: String?
        var mustMove = false
    }

    // MARK: Plan

    public func plan(scan: ScanResult, mode: PlanMode = .sortAndRename,
                     progress: (@Sendable (String) -> Void)? = nil,
                     isCancelled: @escaping @Sendable () -> Bool = { false }) async -> Plan {
        var plan = Plan()
        plan.notes = scan.notes
        progress?("Lese Metadaten …")
        let candidates = await MetadataEnricher.enrich(scan.candidates)

        var decisions: [Decision] = []
        var aiJobs: [AIJob] = []
        let aiActive = provider != nil

        for item in candidates {
            if isCancelled() { break }
            let needsName = general.renameEnabled && renamer.needsName(item)
            if mode == .renameOnly {
                if needsName {
                    if aiActive && privacy.allows(item.url) && item.kind.hasReadableText {
                        aiJobs.append(AIJob(item: item, hint: nil, needsName: true))
                    } else {
                        decisions.append(Decision(item: item, folder: nil, description: nil, confidence: 0.9,
                                                  reason: "Nichtssagender Name", origin: .renameScheme))
                    }
                }
                continue
            }

            let mustMove = isDocumentsInbox(item.parent)
            if mustMove, RedundancyDetector.quickReason(for: item) != nil {
                // Installers, leftovers, extracted archives: not worth a place in Documents → "Löschen".
                plan.disposable.append(item)
                continue
            }
            var match = engine.match(item, now: now())
            if mustMove, !(match?.isUserRule ?? false),
               match.map({ !PathUtil.isDescendant($0.destinationFolder, of: documentsRoot, orEqual: false) }) ?? true {
                match = documentsCategory(for: item)
            }
            let aiAllowed = aiActive && privacy.allows(item.url)
            if let m = match, m.isUserRule || m.confidence >= general.certainThreshold || !aiAllowed {
                // Document with a meaningless name but a certain rule: still ask the AI for a description.
                if needsName && aiAllowed && item.kind.hasReadableText && !m.isUserRule {
                    aiJobs.append(AIJob(item: item, hint: m, needsName: true, mustMove: mustMove))
                    continue
                }
                decisions.append(ruleDecision(item, m))
            } else if aiAllowed {
                aiJobs.append(AIJob(item: item, hint: match, needsName: needsName, mustMove: mustMove))
            } else {
                if needsName && item.kind.isMedia && general.renameMediaWithDate {
                    decisions.append(Decision(item: item, folder: nil, description: nil, confidence: 0.8,
                                              reason: "Nichtssagender Name", origin: .renameScheme))
                } else {
                    plan.unsorted.append(item)
                }
                if !privacy.allows(item.url) && aiActive {
                    plan.notes.append("\(item.name): aus Datenschutzgründen nicht an die KI gesendet.")
                }
            }
        }

        var folderDecisions: [(FolderItem, URL, Double, String, ActionOrigin)] = []
        var aiFolders: [FolderItem] = []
        if mode == .sortAndRename {
            for folder in scan.folderCandidates {
                if let blocked = folder.blockedReason {
                    plan.notes.append("\(folder.name) bleibt liegen: \(blocked)")
                    continue
                }
                let mustMove = isDocumentsInbox(folder.url.deletingLastPathComponent())
                if let (dest, conf, reason) = mustMove ? documentsFolderRule(folder) : folderRule(folder) {
                    folderDecisions.append((folder, dest, conf, reason, .builtInRule(folder.kind.displayName)))
                } else if aiActive && privacy.allows(folder.url) {
                    aiFolders.append(folder)
                } else if mustMove {
                    folderDecisions.append((folder, documentsFallbackFolder, 0.6, "Ordner aus Downloads", .builtInRule("Kategorie Sonstiges")))
                }
            }
        }

        // AI for unclear cases
        if let provider, !aiJobs.isEmpty || !aiFolders.isEmpty {
            progress?("Frage \(provider.displayName) …")
            let (aiDecisions, aiFolderDecisions, stats, rest) = await runAI(provider: provider, jobs: aiJobs, folders: aiFolders,
                                                                           progress: progress, isCancelled: isCancelled)
            decisions += aiDecisions
            folderDecisions += aiFolderDecisions
            plan.aiStats = stats
            plan.unsorted += rest
            plan.notes += stats.errors
        }

        progress?("Erstelle Vorschau …")
        var actions: [PlannedAction] = []
        for d in decisions {
            if let action = makeAction(d) { actions.append(action) }
        }
        for (folder, dest, conf, reason, origin) in folderDecisions {
            if let action = makeFolderAction(folder, dest: dest, confidence: conf, reason: reason, origin: origin) {
                actions.append(action)
            }
        }
        actions = enforceNewFolderRules(actions)
        actions = markIdenticalTargets(actions)
        actions = resolveNameConflicts(actions)
        for i in actions.indices {
            actions[i].isSelected = actions[i].confidence >= general.selectThreshold && actions[i].warnings.isEmpty
        }
        plan.actions = actions.sorted { ($0.group, $0.source.lastPathComponent) < ($1.group, $1.source.lastPathComponent) }
        // Everything without an action is reported as "not assigned".
        let handled = Set(actions.map { PathUtil.path($0.source) }).union(plan.disposable.map { PathUtil.path($0.url) })
        let alreadyListed = Set(plan.unsorted.map { PathUtil.path($0.url) })
        plan.unsorted += candidates.filter { !handled.contains(PathUtil.path($0.url)) && !alreadyListed.contains(PathUtil.path($0.url)) }
        plan.unsorted = plan.unsorted.filter { !handled.contains(PathUtil.path($0.url)) }
        if !plan.disposable.isEmpty {
            let n = plan.disposable.count
            plan.notes.append("\(n) Datei\(n == 1 ? "" : "en") in Downloads \(n == 1 ? "ist" : "sind") überflüssig (Installer, entpackte Archive, Reste) und \(n == 1 ? "bleibt" : "bleiben") für „Löschen“ liegen.")
        }
        return plan
    }

    // MARK: Rules

    func ruleDecision(_ item: FileItem, _ m: RuleMatch) -> Decision {
        Decision(item: item, folder: m.destinationFolder, description: nil, confidence: m.confidence,
                 reason: "Regel „\(m.rule.name)“", origin: m.isUserRule ? .userRule(m.rule.name) : .builtInRule(m.rule.name),
                 ruleNewName: m.newName)
    }

    var documentsFallbackFolder: URL {
        engine.resolver.resolve(documentsRoot.appendingPathComponent("Sonstiges", isDirectory: true))
    }

    /// Folders from an inbox that is emptied into Documents.
    func documentsFolderRule(_ folder: FolderItem) -> (URL, Double, String)? {
        switch folder.kind {
        case .photoSeries:
            return (engine.resolver.resolve(documentsRoot.appendingPathComponent("Bilder", isDirectory: true)), 0.75, "Ordner enthält eine Fotoserie")
        case .musicAlbum:
            return (engine.resolver.resolve(documentsRoot.appendingPathComponent("Audio/Alben", isDirectory: true)), 0.75, "Ordner enthält ein Musikalbum")
        case .website:
            return (engine.resolver.resolve(documentsRoot.appendingPathComponent("Websites", isDirectory: true)), 0.6, "Ordner enthält eine Website")
        case .project:
            return folderRule(folder)
        case .extractedArchive, .submission, .generic:
            return nil
        }
    }

    func folderRule(_ folder: FolderItem) -> (URL, Double, String)? {
        switch folder.kind {
        case .photoSeries:
            return (engine.resolver.resolve(home.folder("Pictures/Fotos")), 0.72, "Ordner enthält eine Fotoserie")
        case .musicAlbum:
            return (engine.resolver.resolve(home.folder("Music/Alben")), 0.72, "Ordner enthält ein Musikalbum")
        case .website:
            return (engine.resolver.resolve(home.folder("Documents/Websites")), 0.6, "Ordner enthält eine Website")
        case .project:
            return (home.folder("Documents/Projekte"), 0.5, "Projektordner (als Ganzes)")
        case .extractedArchive, .submission, .generic:
            return nil
        }
    }

    // MARK: AI

    func descriptor(for job: AIJob, id: String) -> AIFileDescriptor {
        let item = job.item
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate]
        var excerpt: String?
        if privacy.allowsExcerpt(item) {
            excerpt = TextExtractor.excerpt(for: item, limit: privacy.excerptLimit)
        }
        let hint = job.hint.map { "\($0.rule.name) → \(home.abbreviate($0.destinationFolder))" }
        return AIFileDescriptor(
            id: id, name: item.name, path: home.abbreviate(item.parent), kind: item.kind.displayName,
            sizeKB: Int(item.size / 1024), created: (item.contentCreated ?? item.created).map { df.string(from: $0) },
            modified: item.modified.map { df.string(from: $0) }, source: item.sourceDomain, needsName: job.needsName,
            ruleHint: hint, excerpt: excerpt, mustMove: job.mustMove ? true : nil)
    }

    func runAI(provider: AIProvider, jobs: [AIJob], folders: [FolderItem],
               progress: (@Sendable (String) -> Void)?, isCancelled: @escaping @Sendable () -> Bool) async
        -> ([Decision], [(FolderItem, URL, Double, String, ActionOrigin)], AIStats, [FileItem]) {
        var stats = AIStats()
        stats.provider = provider.displayName
        var decisions: [Decision] = []
        var folderDecisions: [(FolderItem, URL, Double, String, ActionOrigin)] = []
        var leftovers: [FileItem] = []

        // 1. Cache
        var pending: [AIJob] = []
        for var job in jobs {
            job.cacheKey = cache != nil ? AICache.key(for: job.item, needsName: job.needsName, mustMove: job.mustMove) : nil
            if let key = job.cacheKey, let cached = cache?.lookup(key) {
                stats.cacheHits += 1
                decisions.append(contentsOf: decision(from: cached, job: job))
            } else {
                pending.append(job)
            }
        }

        // 2. Quota guard
        let limit = max(0, aiSettings.maxFilesPerRun)
        if pending.count > limit {
            for job in pending[limit...] { decisions.append(contentsOf: fallback(for: job)) }
            stats.errors.append("Nur \(limit) Dateien an die KI gesendet (Limit pro Lauf); der Rest wird nur per Regel behandelt.")
            pending = Array(pending.prefix(limit))
        }

        // 3. Batches
        let structureList = structure.displayList(home: home)
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate]
        let today = df.string(from: now())
        let batchSize = max(1, min(aiSettings.batchSize, 50))
        var batches: [(AIRequest, [String: AIJob], [String: FolderItem])] = []
        var index = 0
        for chunk in stride(from: 0, to: pending.count, by: batchSize).map({ Array(pending[$0..<min($0 + batchSize, pending.count)]) }) {
            var map: [String: AIJob] = [:]
            var files: [AIFileDescriptor] = []
            for job in chunk {
                index += 1
                let id = "f\(index)"
                map[id] = job
                files.append(descriptor(for: job, id: id))
            }
            batches.append((AIRequest(today: today, existingFolders: structureList, files: files, folders: []), map, [:]))
        }
        for chunk in stride(from: 0, to: folders.count, by: batchSize).map({ Array(folders[$0..<min($0 + batchSize, folders.count)]) }) {
            var map: [String: FolderItem] = [:]
            var descs: [AIFolderDescriptor] = []
            for folder in chunk {
                index += 1
                let id = "d\(index)"
                map[id] = folder
                descs.append(AIFolderDescriptor(id: id, name: folder.name, path: home.abbreviate(folder.url.deletingLastPathComponent()),
                                                kind: folder.kind.displayName, fileCount: folder.fileCount,
                                                sampleNames: Array(folder.sampleNames.prefix(12)),
                                                mustMove: isDocumentsInbox(folder.url.deletingLastPathComponent()) ? true : nil))
            }
            batches.append((AIRequest(today: today, existingFolders: structureList, files: [], folders: descs), [:], map))
        }

        stats.filesSent = pending.count
        stats.foldersSent = folders.count
        let concurrency = max(1, min(provider.maxConcurrentRequests, aiSettings.maxConcurrentBatches))
        let stopFlag = StopFlag()
        let total = batches.count
        let counter = BatchCounter()

        let results = await withTaskGroup(of: (Int, Result<AIResponse, Error>).self) { group -> [(Int, Result<AIResponse, Error>)] in
            var next = 0
            var collected: [(Int, Result<AIResponse, Error>)] = []
            func addNext() {
                guard next < batches.count else { return }
                let i = next
                let request = batches[i].0
                next += 1
                group.addTask {
                    if isCancelled() || stopFlag.isSet { return (i, .failure(CancellationError())) }
                    do {
                        let response = try await provider.suggest(request)
                        let done = counter.increment()
                        progress?("KI: Stapel \(done) von \(total) fertig …")
                        return (i, .success(response))
                    } catch {
                        if let e = error as? AIError, e.stopsRun { stopFlag.set() }
                        return (i, .failure(error))
                    }
                }
            }
            for _ in 0..<concurrency { addNext() }
            for await result in group {
                collected.append(result)
                addNext()
            }
            return collected
        }

        var errorMessages: [String] = []
        for (i, result) in results.sorted(by: { $0.0 < $1.0 }) {
            let (_, jobMap, folderMap) = batches[i]
            switch result {
            case let .success(response):
                stats.batches += 1
                stats.inputTokens += response.inputTokens
                stats.outputTokens += response.outputTokens
                stats.costUSD += response.costUSD
                var answered = Set<String>()
                for suggestion in response.items {
                    if let job = jobMap[suggestion.id] {
                        answered.insert(suggestion.id)
                        if let key = job.cacheKey { cache?.store(key, suggestion) }
                        decisions.append(contentsOf: decision(from: suggestion, job: job))
                    } else if let folder = folderMap[suggestion.id] {
                        answered.insert(suggestion.id)
                        let target = suggestion.targetFolder.trimmingCharacters(in: .whitespaces)
                        let mustMove = isDocumentsInbox(folder.url.deletingLastPathComponent())
                        if !target.isEmpty, let url = parseTarget(target),
                           !mustMove || PathUtil.isDescendant(url, of: documentsRoot, orEqual: false) {
                            folderDecisions.append((folder, url, clamp(suggestion.confidence), suggestion.reason, .ai))
                        } else if mustMove {
                            folderDecisions.append((folder, documentsFallbackFolder, 0.6, "Ordner aus Downloads", .builtInRule("Kategorie Sonstiges")))
                        }
                    }
                }
                for (id, job) in jobMap where !answered.contains(id) {
                    decisions.append(contentsOf: fallback(for: job))
                }
            case let .failure(error):
                if !(error is CancellationError) {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    if !errorMessages.contains(message) { errorMessages.append(message) }
                }
                for job in jobMap.values { decisions.append(contentsOf: fallback(for: job)) }
            }
        }
        stats.errors += errorMessages.map { "KI: \($0)" }
        // Items that ended without any decision
        let decided = Set(decisions.map { $0.item.url.path })
        leftovers = pending.map(\.item).filter { !decided.contains($0.url.path) }
        return (decisions, folderDecisions, stats, leftovers)
    }

    /// Rule result (if any) when the AI could not help. Low confidence rules stay deselected.
    func fallback(for job: AIJob) -> [Decision] {
        if let hint = job.hint { return [ruleDecision(job.item, hint)] }
        if job.needsName && job.item.kind.isMedia {
            return [Decision(item: job.item, folder: nil, description: nil, confidence: 0.8,
                             reason: "Nichtssagender Name", origin: .renameScheme)]
        }
        return []
    }

    func decision(from s: AISuggestion, job: AIJob) -> [Decision] {
        if let hint = job.hint, hint.isUserRule || hint.confidence >= general.certainThreshold {
            // A certain rule decides the folder; the AI only contributed the description.
            var d = ruleDecision(job.item, hint)
            d.description = job.needsName ? s.description : nil
            return [d]
        }
        let target = s.targetFolder.trimmingCharacters(in: .whitespaces)
        if job.mustMove {
            // Inbox files must end up under Documents; otherwise the category by type decides.
            let parsed = target.isEmpty ? nil : parseTarget(target)
            if let url = parsed, PathUtil.isDescendant(url, of: documentsRoot, orEqual: false) {
                return [Decision(item: job.item, folder: url, description: job.needsName ? s.description : nil,
                                 confidence: clamp(s.confidence), reason: s.reason.isEmpty ? "Vorschlag von Claude" : s.reason, origin: .ai)]
            }
            if let hint = job.hint {
                var d = ruleDecision(job.item, hint)
                d.description = job.needsName ? s.description : nil
                return [d]
            }
        }
        var folder: URL?
        if !target.isEmpty {
            folder = parseTarget(target)
            if folder == nil, let hint = job.hint { return [ruleDecision(job.item, hint)] }
        } else if let hint = job.hint, hint.confidence >= general.certainThreshold {
            // The AI only described the file; the certain rule decides the folder.
            folder = hint.destinationFolder
        }
        let description = job.needsName ? s.description : nil
        return [Decision(item: job.item, folder: folder, description: description, confidence: clamp(s.confidence),
                         reason: s.reason.isEmpty ? "Vorschlag von Claude" : s.reason, origin: .ai)]
    }

    func parseTarget(_ raw: String) -> URL? {
        guard !raw.contains(".."), !raw.contains("\0") else { return nil }
        var s = raw
        if s.hasPrefix("~") == false && s.hasPrefix("/") == false { s = "~/" + s }
        let url = home.expand(s).standardizedFileURL
        guard home.contains(url) else { return nil }
        return url
    }

    func clamp(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0 }

    // MARK: Actions

    func makeAction(_ d: Decision) -> PlannedAction? {
        let item = d.item
        var warnings = d.warnings
        var confidence = d.confidence
        var reason = d.reason
        var newName = d.ruleNewName ?? (general.renameEnabled ? renamer.proposal(for: item, description: d.description) : nil)
        if newName == item.name { newName = nil }

        var folder = d.folder.map { engine.resolver.resolve($0) }
        if let f = folder, PathUtil.isSame(f, item.parent) { folder = nil }
        if let f = folder {
            if let problem = policy.destinationProtection(for: f) {
                reason += " – Ziel nicht erlaubt (\(problem.description))"
                folder = nil
                confidence = min(confidence, 0.3)
                if newName == nil { return nil }
            } else if let ref = policy.referenceWarning(for: item.url) {
                warnings.append(ref)
            }
        }
        if let f = folder {
            // Not more than N new levels.
            let existing = PathUtil.deepestExistingAncestor(of: f)
            if let depth = PathUtil.depth(of: f, below: existing), depth > general.maxNewFolderDepth,
               let rel = PathUtil.relativePath(of: f, to: existing) {
                let parts = rel.split(separator: "/").prefix(general.maxNewFolderDepth)
                folder = existing.appendingPathComponent(parts.joined(separator: "/"), isDirectory: true)
                warnings.append("Zielpfad auf \(general.maxNewFolderDepth) neue Ebenen gekürzt")
            }
        }
        guard folder != nil || newName != nil else { return nil }
        let kind: ActionKind = folder == nil ? .rename : .move
        return PlannedAction(kind: kind, source: item.url, destinationFolder: folder ?? item.parent, newName: newName,
                             reason: reason, confidence: confidence, origin: d.origin,
                             group: group(for: kind, folder: folder), warnings: warnings, sizeBytes: item.size)
    }

    func makeFolderAction(_ folder: FolderItem, dest: URL, confidence: Double, reason: String, origin: ActionOrigin) -> PlannedAction? {
        let target = engine.resolver.resolve(dest)
        if PathUtil.isSame(target, folder.url.deletingLastPathComponent()) { return nil }
        if PathUtil.isDescendant(target, of: folder.url) { return nil }
        if policy.destinationProtection(for: target) != nil { return nil }
        var warnings: [String] = []
        if let ref = policy.referenceWarning(for: folder.url) { warnings.append(ref) }
        if folder.kind == .project { warnings.append("Projektordner – wird nur als Ganzes verschoben") }
        return PlannedAction(kind: .moveFolder, source: folder.url, destinationFolder: target, newName: nil,
                             reason: "\(reason) (\(folder.kind.displayName), \(folder.fileCount) Dateien)", confidence: confidence,
                             origin: origin, group: group(for: .moveFolder, folder: target), warnings: warnings,
                             sizeBytes: folder.size)
    }

    func group(for kind: ActionKind, folder: URL?) -> String {
        switch kind {
        case .rename: return "Umbenennen"
        default: return folder.map { home.abbreviate($0) } ?? "Sonstiges"
        }
    }

    /// "New folders only if several files fit": AI-invented folders with a single file are
    /// replaced by the nearest existing folder.
    func enforceNewFolderRules(_ actions: [PlannedAction]) -> [PlannedAction] {
        var counts: [String: Int] = [:]
        for a in actions where a.kind == .move || a.kind == .moveFolder {
            guard let f = a.destinationFolder, !PathUtil.exists(f) else { continue }
            var current = f
            while !PathUtil.exists(current) {
                counts[PathUtil.path(current), default: 0] += 1
                current = current.deletingLastPathComponent()
            }
        }
        let minimum = max(1, general.minFilesForNewFolder)
        return actions.compactMap { action -> PlannedAction? in
            guard action.origin.isAI, action.kind == .move || action.kind == .moveFolder,
                  let f = action.destinationFolder, !PathUtil.exists(f),
                  (counts[PathUtil.path(f)] ?? 0) < minimum else { return action }
            var a = action
            if isDocumentsInbox(action.source.deletingLastPathComponent()) {
                // Emptying an inbox: a new category folder is fine even for one file; deeper new
                // levels only when several files share them.
                let existing = PathUtil.deepestExistingAncestor(of: f)
                var target = f
                while (PathUtil.depth(of: target, below: existing) ?? 0) > 1 && (counts[PathUtil.path(target)] ?? 0) < minimum {
                    target = target.deletingLastPathComponent()
                }
                if PathUtil.isSame(target, f) { return action }
                a.destinationFolder = target
                a.group = group(for: a.kind, folder: target)
                a.confidence *= 0.95
                a.reason += " (in „\(target.lastPathComponent)“ statt eines neuen Unterordners für nur eine Datei)"
                return a
            }
            // Walk up to the highest new folder that still has enough files, or the existing parent.
            var target = f.deletingLastPathComponent()
            while !PathUtil.exists(target) && (counts[PathUtil.path(target)] ?? 0) < minimum {
                target = target.deletingLastPathComponent()
            }
            if PathUtil.isSame(target, a.source.deletingLastPathComponent()) || target.path.count <= home.home.path.count
                || PathUtil.isSame(target, home.home) {
                guard a.isRename else { return nil }
                a.kind = .rename
                a.destinationFolder = a.source.deletingLastPathComponent()
                a.group = group(for: .rename, folder: nil)
                return a
            }
            a.destinationFolder = target
            a.group = group(for: a.kind, folder: target)
            a.confidence *= 0.9
            a.reason += " (statt neuem Ordner „\(f.lastPathComponent)“ für nur eine Datei)"
            return a
        }
    }

    /// If the target folder already holds an identical copy, moving would only create a duplicate:
    /// such moves are deselected with a hint to the duplicate finder.
    func markIdenticalTargets(_ actions: [PlannedAction]) -> [PlannedAction] {
        actions.map { action in
            guard action.kind == .move, let folder = action.destinationFolder, PathUtil.isDirectory(folder),
                  let twin = Self.identicalFile(to: action.source, size: action.sizeBytes, in: folder) else { return action }
            var a = action
            a.warnings.append("Identische Datei liegt schon im Ziel (\(twin.lastPathComponent)) – eher ein Fall für „Duplikate“")
            return a
        }
    }

    static func identicalFile(to source: URL, size: Int64, in folder: URL) -> URL? {
        guard size > 0, size <= 512 * 1024 * 1024,
              let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return nil }
        let sameSize = entries.filter {
            let v = try? $0.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return v?.isRegularFile == true && Int64(v?.fileSize ?? -1) == size && !PathUtil.isSame($0, source)
        }
        guard !sameSize.isEmpty, let sourceHash = FileHasher.fullHash(of: source) else { return nil }
        return sameSize.first { FileHasher.fullHash(of: $0) == sourceHash }
    }

    /// Pre-assigns unique names so the preview shows exactly what will happen. The executor
    /// checks again at run time and never overwrites.
    func resolveNameConflicts(_ actions: [PlannedAction]) -> [PlannedAction] {
        var reserved: [String: Set<String>] = [:]
        var result = actions
        let order = result.indices.sorted { result[$0].confidence > result[$1].confidence }
        for i in order {
            guard result[i].kind == .move || result[i].kind == .moveFolder || result[i].kind == .rename,
                  let folder = result[i].destinationFolder else { continue }
            let key = PathUtil.path(folder)
            let wanted = result[i].finalName
            if result[i].kind == .rename && wanted == result[i].source.lastPathComponent { continue }
            let unique = FileNameTools.uniqueName(for: wanted, in: folder, reserved: reserved[key] ?? [])
            if unique != wanted {
                result[i].newName = unique
            }
            reserved[key, default: []].insert(unique)
        }
        return result
    }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

final class BatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
