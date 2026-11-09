import Foundation
@testable import TidyCore
import XCTest

private func runTool(_ tool: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    try p.run()
    p.waitUntilExit()
}

final class RedundancyTests: XCTestCase {
    func detector(_ fake: FakeHome, days: Double, apps: Set<String> = []) -> RedundancyDetector {
        RedundancyDetector(home: fake.home, settings: DeletionSettings(), now: Date().addingTimeInterval(days * 86_400), installedApps: apps)
    }

    func scan(_ fake: FakeHome) async -> ScanResult {
        await FileScanner(home: fake.home, policy: fake.policy(), general: GeneralSettings()).scan(.folders([fake.url("Downloads")]))
    }

    func testExtractedArchivesAreVerifiedByContent() async throws {
        let fake = try FakeHome()
        // Real ZIP, fully extracted next to it.
        fake.file("Downloads/Projekt/a.txt", "A")
        fake.file("Downloads/Projekt/sub/b.txt", "B")
        try runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", fake.url("Downloads/Projekt").path, fake.url("Downloads/Projekt.zip").path])
        // Same name, but the folder holds something else.
        fake.file("Downloads/Andere/y.txt", "Y")
        try runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", fake.url("Downloads/Andere").path, fake.url("Downloads/Fotos.zip").path])
        try FileManager.default.removeItem(at: fake.url("Downloads/Andere"))
        fake.file("Downloads/Fotos/x.jpg", "X")
        // Not checkable (RAR) but a folder with the same name exists; and an archive on its own.
        fake.file("Downloads/Daten.rar", "rar")
        fake.file("Downloads/Daten/inhalt.txt", "i")
        fake.file("Downloads/Allein.zip", "zip")

        let byName = Dictionary(uniqueKeysWithValues: detector(fake, days: 0).find(in: await scan(fake)).map { ($0.url.lastPathComponent, $0) })
        XCTAssertEqual(byName["Projekt.zip"]?.confidence, 0.97, byName["Projekt.zip"]?.reason ?? "missing")
        XCTAssertTrue(byName["Projekt.zip"]?.reason.contains("vollständig") ?? false)
        XCTAssertNil(byName["Fotos.zip"], "a folder with the same name but other content is no proof")
        XCTAssertEqual(byName["Daten.rar"]?.confidence, 0.85)
        XCTAssertNil(byName["Allein.zip"])
    }

    func testInstallersCopiesLeftoversAndAbortedDownloads() async throws {
        let fake = try FakeHome()
        fake.file("Downloads/Firefox-Setup-128.0.dmg")
        fake.file("Downloads/Unbekannt-Tool.dmg")
        fake.file("Downloads/Rechnung.pdf", "R1")
        fake.file("Downloads/Rechnung (1).pdf", "R1")
        fake.file("Downloads/Foto.jpg", "A")
        fake.file("Downloads/Foto (1).jpg", "B")
        fake.file("Downloads/~$Bericht.docx", "lock")
        fake.file("Downloads/film.mp4.crdownload", "x", modified: .daysAgo(5))
        let scan = await scan(fake)

        let tomorrow = Set(detector(fake, days: 1, apps: ["firefox"]).find(in: scan).map { $0.url.lastPathComponent })
        XCTAssertEqual(tomorrow, ["Firefox-Setup-128.0.dmg", "Rechnung (1).pdf", "~$Bericht.docx", "film.mp4.crdownload"],
                       "installed app, identical copy, leftover and aborted download – but not a different copy or an unknown new installer")

        let nextWeek = detector(fake, days: 8).find(in: scan)
        XCTAssertTrue(nextWeek.contains { $0.url.lastPathComponent == "Unbekannt-Tool.dmg" && $0.confidence == 0.85 })
        XCTAssertFalse(nextWeek.contains { $0.url.lastPathComponent == "Foto (1).jpg" })
    }

    func testAppTokens() {
        XCTAssertEqual(RedundancyDetector.appToken(forInstaller: "Firefox-Setup-128.0.dmg"), "firefox")
        XCTAssertEqual(RedundancyDetector.appToken(forInstaller: "Slack-4.41.105-macOS.dmg"), "slack")
        XCTAssertEqual(RedundancyDetector.appToken(forInstaller: "googlechrome.dmg"), "googlechrome")
        XCTAssertEqual(RedundancyDetector.appToken(forInstaller: "VLC-3.0.21-universal.dmg"), "vlc")
        XCTAssertEqual(FileNameTools.removingCopySuffix("Rechnung (1)"), "Rechnung")
    }
}

final class DocumentsModeTests: XCTestCase {
    func makePlanner(_ fake: FakeHome, provider: AIProvider?) -> (FileScanner, Planner) {
        let policy = fake.policy()
        let general = GeneralSettings()
        let scanner = FileScanner(home: fake.home, policy: policy, general: general)
        let planner = Planner(home: fake.home, policy: policy,
                              engine: RuleEngine(home: fake.home, settings: RuleSettings(), resolver: DestinationResolver(home: fake.home)),
                              structure: StructureIndex.build(home: fake.home, policy: policy), provider: provider, cache: nil,
                              general: general, aiSettings: AISettings())
        return (scanner, planner)
    }

    func testDownloadsAreEmptiedIntoDocuments() async throws {
        let fake = try FakeHome()
        fake.file("Downloads/Rechnung Telekom.pdf", "Rechnung")
        fake.file("Downloads/Urlaub.jpg", "jpg")
        fake.file("Downloads/Bildschirmfoto 2025-02-14 um 09.12.33.png", "png")
        fake.file("Downloads/Notizen.docx", "docx")
        fake.file("Downloads/Tabelle.xlsx", "xlsx")
        fake.file("Downloads/Musik.mp3", "mp3")
        fake.file("Downloads/irgendwas.xyz", "xyz")
        fake.file("Downloads/App.dmg", "dmg")
        fake.file("Downloads/Projekt.zip", "zip")
        fake.file("Downloads/Projekt/readme.txt", "r")
        fake.file("Desktop/Desktop-Notiz.docx", "d")

        let (scanner, planner) = makePlanner(fake, provider: nil)
        let plan = await planner.plan(scan: await scanner.scan(.folders([fake.url("Downloads"), fake.url("Desktop")])))
        let dest = Dictionary(uniqueKeysWithValues: plan.actions.map {
            ($0.source.lastPathComponent, fake.home.abbreviate($0.destinationFolder ?? fake.home.home))
        })
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        XCTAssertEqual(dest["Rechnung Telekom.pdf"], "~/Documents/Finanzen/Rechnungen/\(year)")
        XCTAssertEqual(dest["Urlaub.jpg"], "~/Documents/Bilder")
        XCTAssertEqual(dest["Bildschirmfoto 2025-02-14 um 09.12.33.png"], "~/Documents/Bilder/Bildschirmfotos/2025")
        XCTAssertEqual(dest["Notizen.docx"], "~/Documents/Unterlagen")
        XCTAssertEqual(dest["Tabelle.xlsx"], "~/Documents/Tabellen")
        XCTAssertEqual(dest["Musik.mp3"], "~/Documents/Audio")
        XCTAssertEqual(dest["irgendwas.xyz"], "~/Documents/Sonstiges")
        XCTAssertEqual(dest["Projekt"], "~/Documents/Sonstiges")
        XCTAssertNil(dest["Desktop-Notiz.docx"], "Desktop is not emptied unless configured")
        XCTAssertEqual(Set(plan.disposable.map(\.name)), ["App.dmg", "Projekt.zip"])
        let trash = plan.actions.filter { $0.kind == .trash }
        XCTAssertEqual(Set(trash.map { $0.source.lastPathComponent }), ["App.dmg", "Projekt.zip"])
        XCTAssertTrue(trash.allSatisfy { !$0.isSelected }, "deleting needs an individual tick")
        XCTAssertTrue(plan.actions.filter { $0.kind != .trash }.allSatisfy { ($0.kind == .move || $0.kind == .moveFolder) && $0.isSelected },
                      "every move out of Downloads is pre-selected")
        XCTAssertTrue(plan.unsorted.filter { $0.parent.lastPathComponent == "Downloads" }.isEmpty)

        let journal = try Journal(url: fake.root.appendingPathComponent("j.sqlite"))
        let executor = Executor(home: fake.home, policy: fake.policy(), journal: journal,
                                trash: FakeTrash(folder: fake.trash), openFiles: StaticOpenFilesProvider())
        let result = executor.execute(plan.actions.filter(\.isSelected), title: "Downloads leeren")
        XCTAssertEqual(result.done, 8, result.messages.joined(separator: "\n"))
        let left = try FileManager.default.contentsOfDirectory(atPath: fake.url("Downloads").path).filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertEqual(left, ["App.dmg", "Projekt.zip"], "only the Trash suggestions (not ticked) remain")
        _ = executor.undoRun(result.runID)
        XCTAssertTrue(fake.exists("Downloads/Notizen.docx"))
        XCTAssertFalse(fake.exists("Documents/Unterlagen"))
    }

    func testClaudeMustPlaceDownloadsUnderDocuments() async throws {
        let fake = try FakeHome()
        fake.file("Downloads/brief.docx", "Brief")
        fake.file("Downloads/skript.pdf", "Analysis")
        fake.file("Downloads/reise.pdf", "Italien")
        fake.file("Downloads/anderes.pdf", "x")
        fake.dir("Documents/Uni")
        let mock = MockAIProvider { d in
            switch d.name {
            case "brief.docx": return AISuggestion(id: d.id, targetFolder: "", description: "", confidence: 0.4, reason: "unklar")
            case "skript.pdf": return AISuggestion(id: d.id, targetFolder: "~/Documents/Uni/Analysis", description: "", confidence: 0.9, reason: "Uni")
            case "reise.pdf": return AISuggestion(id: d.id, targetFolder: "~/Documents/Reisen/Italien 2024", description: "", confidence: 0.9, reason: "Reise")
            default: return AISuggestion(id: d.id, targetFolder: "~/Pictures/X", description: "", confidence: 0.9, reason: "falsch")
            }
        }
        let (scanner, planner) = makePlanner(fake, provider: mock)
        let plan = await planner.plan(scan: await scanner.scan(.folders([fake.url("Downloads")])))
        XCTAssertTrue(mock.sentFiles.allSatisfy { $0.mustMove == true })
        XCTAssertTrue(PromptBuilder.systemPrompt.contains("mustMove"))
        let dest = Dictionary(uniqueKeysWithValues: plan.actions.map {
            ($0.source.lastPathComponent, fake.home.abbreviate($0.destinationFolder ?? fake.home.home))
        })
        XCTAssertEqual(dest["brief.docx"], "~/Documents/Unterlagen", "no answer → category by type")
        XCTAssertEqual(dest["skript.pdf"], "~/Documents/Uni/Analysis", "one new level below an existing folder is fine")
        XCTAssertEqual(dest["reise.pdf"], "~/Documents/Reisen", "a new category for one file, but not two new levels")
        XCTAssertEqual(dest["anderes.pdf"], "~/Documents/Unterlagen", "targets outside Documents are not accepted")
        XCTAssertTrue(plan.unsorted.isEmpty)
    }

    func testCloudDocumentsProjectsAndWebPages() async throws {
        let fake = try FakeHome()
        // "Documents" in iCloud: simulated with a cloud marker file.
        fake.file("Documents/.tresorit", "")
        fake.dir("Documents/Uni")
        fake.file("Downloads/skript.pdf", "x")
        fake.file("Downloads/repo/.git/HEAD", "ref")
        fake.file("Downloads/repo/main.py", "print(1)")
        fake.file("Downloads/Paket/inner/.git/HEAD", "ref")
        fake.file("Downloads/Paket/readme.txt", "r")
        fake.file("Downloads/Artikel.html", "<html>")
        fake.file("Downloads/Artikel_files/style.css", "css")
        let inbox = fake.url("Downloads")
        let docs = fake.url("Documents")

        let strict = ProtectionPolicy(home: fake.home, settings: ProtectionSettings())
        XCTAssertNotNil(strict.destinationProtection(for: docs.appendingPathComponent("Uni")), "cloud folders are protected by default")

        let policy = ProtectionPolicy(home: fake.home, settings: ProtectionSettings(), cloudDestinationRoots: [docs], wholeMoveInboxes: [inbox])
        XCTAssertNil(policy.destinationProtection(for: docs.appendingPathComponent("Uni")), "Documents is a valid target even in the cloud")
        XCTAssertNotNil(policy.ancestorProtection(of: docs.appendingPathComponent("Uni/x.pdf")), "but not a source for sorting")
        XCTAssertTrue(StructureIndex.build(home: fake.home, policy: policy).folders.contains { $0.lastPathComponent == "Uni" })

        let general = GeneralSettings()
        let scanner = FileScanner(home: fake.home, policy: policy, general: general)
        let planner = Planner(home: fake.home, policy: policy,
                              engine: RuleEngine(home: fake.home, settings: RuleSettings(), resolver: DestinationResolver(home: fake.home)),
                              structure: StructureIndex.build(home: fake.home, policy: policy), provider: nil, cache: nil,
                              general: general, aiSettings: AISettings())
        planner.installedApps = []
        let plan = await planner.plan(scan: await scanner.scan(.folders([inbox])))
        let byName = Dictionary(uniqueKeysWithValues: plan.actions.map { ($0.source.lastPathComponent, $0) })
        XCTAssertEqual(byName["skript.pdf"].map { fake.home.abbreviate($0.destinationFolder ?? fake.home.home) }, "~/Documents/Unterlagen")
        XCTAssertEqual(byName["repo"]?.kind, .moveFolder, "a project leaves as a whole")
        XCTAssertEqual(byName["repo"]?.isSelected, false, "… but only after a look")
        XCTAssertEqual(byName["Paket"]?.kind, .moveFolder)
        XCTAssertTrue(byName["Paket"]?.warnings.contains { $0.contains("Projektordner") } ?? false)
        XCTAssertEqual(byName["Artikel.html"].map { fake.home.abbreviate($0.destinationFolder ?? fake.home.home) }, "~/Documents/Websites")
        XCTAssertEqual(byName["Artikel_files"]?.kind, .moveFolder)
        XCTAssertTrue(plan.unsorted.isEmpty)

        // Executing: the project moves intact, the cloud target is accepted at run time too.
        let journal = try Journal(url: fake.root.appendingPathComponent("c.sqlite"))
        let executor = Executor(home: fake.home, policy: policy, journal: journal,
                                trash: FakeTrash(folder: fake.trash), openFiles: StaticOpenFilesProvider())
        let all = plan.actions.map { a -> PlannedAction in var c = a; c.isSelected = true; return c }.filter { $0.kind != .trash }
        let result = executor.execute(all, title: "Alles raus")
        XCTAssertEqual(result.failed, 0, result.messages.joined(separator: "\n"))
        XCTAssertTrue(fake.exists("Documents/Projekte/repo/.git/HEAD"))
        XCTAssertTrue(fake.exists("Documents/Websites/Artikel_files/style.css"))
        let left = try FileManager.default.contentsOfDirectory(atPath: inbox.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(left, [], "Downloads is empty")
    }
}
