import Foundation
import TidyCore

// tidyctl – command line front end of TidyCore for dry runs and tests.
// Changing files (`run`, `undo`) is only allowed with an explicit --home (test home).

struct Options {
    var command = "help"
    var home: URL?
    var all = false
    var folders: [URL] = []
    var ai: String?
    var renameOnly = false
    var json = false
    var runID: String?
}

func parse() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { return o }
    o.command = args.removeFirst()
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--home": if !args.isEmpty { o.home = URL(fileURLWithPath: (args.removeFirst() as NSString).expandingTildeInPath) }
        case "--all": o.all = true
        case "--ai": if !args.isEmpty { o.ai = args.removeFirst() }
        case "--rename-only": o.renameOnly = true
        case "--json": o.json = true
        default:
            if o.command == "undo" && o.runID == nil && !a.hasPrefix("/") && !a.hasPrefix("~") && !a.hasPrefix(".") {
                o.runID = a
            } else {
                o.folders.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath))
            }
        }
    }
    return o
}

/// Trash replacement inside the test area, so test runs never touch the real Trash.
struct FolderTrash: TrashService {
    let folder: URL
    func trash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(FileNameTools.uniqueName(for: url.lastPathComponent, in: folder))
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}

func printUsage() {
    print("""
    tidyctl – TidyMac-Kern auf der Kommandozeile

      tidyctl scan     [--home DIR] (--all | ORDNER …)
      tidyctl plan     [--home DIR] [--ai none|cli|api] [--rename-only] [--json] (--all | ORDNER …)
      tidyctl run      --home DIR   [--ai none|cli|api] (--all | ORDNER …)    führt den Plan aus (nur Test-Home!)
      tidyctl undo     --home DIR   (RUN-ID | last)
      tidyctl history  [--home DIR]
      tidyctl dupes    [--home DIR] (--all | ORDNER …)
      tidyctl cleanup  [--home DIR] (--all | ORDNER …)
      tidyctl ai-status
    """)
}

let options = parse()
let realHome = HomeContext.current
let home = options.home.map(HomeContext.init(home:)) ?? realHome
let isTestHome = options.home != nil && !PathUtil.isSame(home.home, realHome.home)
let support = isTestHome ? home.home.deletingLastPathComponent().appendingPathComponent(".tidymac-support") : TidyEnvironment.defaultSupportDirectory
var loadedSettings = TidySettings.load(from: support.appendingPathComponent("settings.json"))
switch options.ai {
case "none": loadedSettings.ai.provider = .off
case "cli": loadedSettings.ai.provider = .claudeCLI
case "api": loadedSettings.ai.provider = .anthropicAPI
default: if options.ai == nil && isTestHome { loadedSettings.ai.provider = .off }
}
let settings = loadedSettings
let env = TidyEnvironment(home: home, settings: settings, supportDirectory: support,
                          apiKey: ProcessInfo.processInfo.environment["TIDYMAC_API_KEY"])
let target: ScanTarget = options.all || options.folders.isEmpty ? .everything : .folders(options.folders)

func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

func scan(_ policy: ProtectionPolicy) async -> ScanResult {
    await env.makeScanner(policy: policy).scan(target)
}

func makePlan() async -> (Plan, ProtectionPolicy) {
    let policy = env.makePolicy(extraRoots: options.folders)
    let result = await scan(policy)
    let provider = env.makeProvider()
    if settings.ai.provider != .off && provider == nil {
        FileHandle.standardError.write(Data("KI-Anbieter nicht verfügbar – nur Regeln.\n".utf8))
    }
    let planner = env.makePlanner(policy: policy, provider: provider)
    let plan = await planner.plan(scan: result, mode: options.renameOnly ? .renameOnly : .sortAndRename) { msg in
        FileHandle.standardError.write(Data("… \(msg)\n".utf8))
    }
    return (plan, policy)
}

func printPlan(_ plan: Plan) {
    if options.json {
        let rows: [[String: Any]] = plan.actions.map { a in
            ["kind": a.kind.rawValue, "source": home.abbreviate(a.source),
             "destination": a.destinationURL.map { home.abbreviate($0) } ?? "", "confidence": a.confidence,
             "selected": a.isSelected, "origin": a.origin.displayName, "reason": a.reason, "warnings": a.warnings]
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) { print(s) }
        return
    }
    var currentGroup = ""
    for a in plan.actions {
        if a.group != currentGroup {
            currentGroup = a.group
            print("\n▸ \(a.group)")
        }
        let mark = a.isSelected ? "[x]" : "[ ]"
        let dest = a.destinationURL.map { home.abbreviate($0) } ?? "Papierkorb"
        print("  \(mark) \(a.kind.displayName): \(home.abbreviate(a.source)) → \(dest)  (\(Int(a.confidence * 100)) %, \(a.origin.displayName))")
        if !a.reason.isEmpty { print("      \(a.reason)") }
        for w in a.warnings { print("      ⚠︎ \(w)") }
    }
    let newFolders = plan.newFolders().keys.map { home.abbreviate($0) }.sorted()
    if !newFolders.isEmpty { print("\nNeue Ordner: \(newFolders.joined(separator: ", "))") }
    if !plan.unsorted.isEmpty { print("Nicht zugeordnet: \(plan.unsorted.map(\.name).joined(separator: ", "))") }
    for n in plan.notes { print("Hinweis: \(n)") }
    let s = plan.aiStats
    if !s.provider.isEmpty {
        print("KI: \(s.provider) – \(s.filesSent) Dateien, \(s.foldersSent) Ordner, \(s.batches) Anfragen, \(s.cacheHits) aus Cache, \(s.inputTokens)/\(s.outputTokens) Tokens")
    }
}

func journal() -> Journal? {
    do { return try env.makeJournal() } catch {
        print("Journal nicht verfügbar: \(error)")
        return nil
    }
}

func executor(_ policy: ProtectionPolicy, _ journal: Journal) -> Executor {
    Executor(home: home, policy: policy, journal: journal,
             trash: isTestHome ? FolderTrash(folder: home.home.deletingLastPathComponent().appendingPathComponent(".Trash-tidyctl")) : SystemTrash())
}

switch options.command {
case "scan":
    let result = await scan(env.makePolicy(extraRoots: options.folders))
    print("Gescannt: \(result.scannedCount) Einträge in \(String(format: "%.2f", result.duration)) s")
    print("Sortierbare Dateien: \(result.candidates.count), Ordner-Einheiten: \(result.folderCandidates.count), alle Dateien: \(result.allFiles.count)")
    for f in result.folderCandidates { print("  ▣ \(home.abbreviate(f.url)) – \(f.kind.displayName), \(f.fileCount) Dateien\(f.blockedReason.map { " (gesperrt: \($0))" } ?? "")") }
    print("Geschützt: \(result.protected.count)")
    for p in result.protected.prefix(60) { print("  🔒 \(home.abbreviate(p.url)) – \(p.reason.description)") }
    for n in result.notes { print("Hinweis: \(n)") }
case "plan":
    let (plan, _) = await makePlan()
    printPlan(plan)
case "run":
    guard isTestHome else {
        print("Abgebrochen: `run` ist nur mit --home <Testordner> erlaubt. Für echte Dateien die App benutzen.")
        exit(2)
    }
    let (plan, policy) = await makePlan()
    printPlan(plan)
    guard let j = journal() else { exit(1) }
    let result = executor(policy, j).execute(plan.actions, title: "tidyctl run", source: "tidyctl")
    print("\nAusgeführt: \(result.summary) – Lauf-ID \(result.runID)")
    for m in result.messages { print("  • \(m)") }
case "undo":
    guard isTestHome else { print("`undo` per tidyctl nur mit --home. In der App: Verlauf → Rückgängig."); exit(2) }
    guard let j = journal() else { exit(1) }
    let id = options.runID == "last" || options.runID == nil ? j.runs(limit: 1).first?.id : options.runID
    guard let id else { print("Kein Lauf gefunden."); exit(1) }
    let r = executor(env.makePolicy(), j).undoRun(id)
    print("Wiederhergestellt: \(r.restored), fehlgeschlagen: \(r.failed)")
    for m in r.messages { print("  • \(m)") }
case "history":
    guard let j = journal() else { exit(1) }
    let df = DateFormatter()
    df.dateStyle = .short
    df.timeStyle = .short
    for run in j.runs() {
        print("\(df.string(from: run.started))  \(run.id)  \(run.title)  [\(run.status)]  \(run.done)/\(run.total) erledigt, \(run.undone) rückgängig")
    }
case "dupes":
    let result = await scan(env.makePolicy(extraRoots: options.folders))
    let finder = DuplicateFinder(home: home)
    let groups = await finder.find(in: result.allFiles)
    for g in groups {
        print("\n\(size(g.size)) × \(g.files.count) – behalten: \(home.abbreviate(g.keeper.url)) (\(g.keeperReason))")
        for f in g.removable { print("   → Papierkorb: \(home.abbreviate(f.url))") }
    }
    print("\n\(groups.count) Gruppen, \(size(groups.reduce(0) { $0 + $1.wastedBytes })) belegt durch Kopien")
case "cleanup":
    let result = await scan(env.makePolicy(extraRoots: options.folders))
    let suggestions = await CleanupAdvisor(home: home, settings: settings.cleanup).suggestions(for: result)
    for s in suggestions {
        print("[\(s.category.displayName)] \(home.abbreviate(s.url)) – \(size(s.size)) – \(s.reason)")
    }
    print("\(suggestions.count) Vorschläge (nichts wird automatisch gelöscht)")
case "ai-status":
    guard let provider = env.makeProvider() else {
        print("Kein KI-Anbieter verfügbar (Einstellung: \(settings.ai.provider.displayName)).")
        exit(1)
    }
    let status = await provider.checkAvailability()
    print("\(provider.displayName): \(status.summary)")
    if !status.detail.isEmpty { print(status.detail) }
default:
    printUsage()
}
