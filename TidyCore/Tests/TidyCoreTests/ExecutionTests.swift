import Foundation
@testable import TidyCore
import XCTest

final class ExecutionTests: XCTestCase {
    func makeExecutor(_ fake: FakeHome, open: Set<String> = [], settings: ProtectionSettings = ProtectionSettings()) throws -> Executor {
        let journal = try Journal(url: fake.root.appendingPathComponent("journal.sqlite"))
        return Executor(home: fake.home, policy: fake.policy(settings), journal: journal,
                        trash: FakeTrash(folder: fake.trash), openFiles: StaticOpenFilesProvider(open))
    }

    func move(_ fake: FakeHome, _ source: String, to folder: String, name: String? = nil) -> PlannedAction {
        PlannedAction(kind: .move, source: fake.url(source), destinationFolder: fake.url(folder), newName: name,
                      reason: "Test", confidence: 1, origin: .manual)
    }

    func testMoveCreatesFoldersAndUndoRestoresEverything() throws {
        let fake = try FakeHome()
        fake.file("Downloads/a.pdf", "A")
        fake.file("Downloads/b.pdf", "B")
        let before = fake.snapshot()
        let executor = try makeExecutor(fake)
        let result = executor.execute([move(fake, "Downloads/a.pdf", to: "Documents/Neu/Tief"),
                                       move(fake, "Downloads/b.pdf", to: "Documents/Neu/Tief", name: "B umbenannt.pdf")],
                                      title: "Test")
        XCTAssertEqual(result.done, 2)
        XCTAssertTrue(fake.exists("Documents/Neu/Tief/a.pdf"))
        XCTAssertTrue(fake.exists("Documents/Neu/Tief/B umbenannt.pdf"))
        XCTAssertFalse(fake.exists("Downloads/a.pdf"))

        let undo = executor.undoRun(result.runID)
        XCTAssertEqual(undo.restored, 2)
        XCTAssertEqual(fake.snapshot(), before, "undo must restore the exact previous state, incl. removing created folders")
    }

    func testNeverOverwrites() throws {
        let fake = try FakeHome()
        fake.file("Downloads/x.txt", "neu")
        fake.file("Documents/x.txt", "alt")
        let executor = try makeExecutor(fake)
        let r = executor.execute([move(fake, "Downloads/x.txt", to: "Documents")], title: "T")
        XCTAssertEqual(r.done, 1)
        XCTAssertEqual(try String(contentsOf: fake.url("Documents/x.txt"), encoding: .utf8), "alt")
        XCTAssertEqual(try String(contentsOf: fake.url("Documents/x 2.txt"), encoding: .utf8), "neu")
    }

    func testUndoDoesNotOverwriteNewFileAtOriginalPlace() throws {
        let fake = try FakeHome()
        fake.file("Downloads/r.txt", "eins")
        let executor = try makeExecutor(fake)
        let r = executor.execute([move(fake, "Downloads/r.txt", to: "Documents")], title: "T")
        fake.file("Downloads/r.txt", "zwei") // new file appeared at the old place
        XCTAssertEqual(executor.undoRun(r.runID).restored, 1)
        XCTAssertEqual(try String(contentsOf: fake.url("Downloads/r.txt"), encoding: .utf8), "zwei")
        XCTAssertEqual(try String(contentsOf: fake.url("Downloads/r 2.txt"), encoding: .utf8), "eins")
    }

    func testProtectedAndOpenFilesAreSkippedAtRunTime() throws {
        let fake = try FakeHome()
        fake.file("Downloads/offen.docx")
        fake.file("Downloads/proj/package.json")
        fake.file("Downloads/proj/index.js")
        fake.file("Downloads/ok.txt")
        let open: Set<String> = [fake.url("Downloads/offen.docx").path]
        let executor = try makeExecutor(fake, open: open)
        let actions = [
            move(fake, "Downloads/offen.docx", to: "Documents"),
            move(fake, "Downloads/proj/index.js", to: "Documents"),
            PlannedAction(kind: .moveFolder, source: fake.url("Downloads/proj"), destinationFolder: fake.url("Documents"),
                          reason: "", confidence: 1, origin: .manual),
            move(fake, "Downloads/ok.txt", to: "Library/Hack"),
            move(fake, "Downloads/ok.txt", to: "Documents/proj2/.git"),
        ]
        let r = executor.execute(actions, title: "T")
        XCTAssertEqual(r.done, 0)
        XCTAssertEqual(r.skipped, 5)
        XCTAssertTrue(fake.exists("Downloads/offen.docx"))
        XCTAssertTrue(fake.exists("Downloads/proj/index.js"))
        XCTAssertFalse(fake.exists("Library/Hack"))
    }

    func testFolderWithProjectInsideIsNeverMovedOrTrashed() throws {
        let fake = try FakeHome()
        fake.file("Downloads/Sammlung/notizen.txt")
        fake.file("Downloads/Sammlung/tief/tool/go.mod")
        fake.file("Downloads/Sammlung/tief/tool/main.go")
        let executor = try makeExecutor(fake)
        let actions = [
            PlannedAction(kind: .moveFolder, source: fake.url("Downloads/Sammlung"), destinationFolder: fake.url("Documents"),
                          reason: "", confidence: 1, origin: .manual),
            PlannedAction(kind: .trash, source: fake.url("Downloads/Sammlung"), destinationFolder: nil,
                          reason: "", confidence: 1, origin: .cleanup),
            PlannedAction(kind: .archive, source: fake.url("Downloads/Sammlung"), destinationFolder: fake.url("Documents/Archiv"),
                          reason: "", confidence: 1, origin: .cleanup),
        ]
        let r = executor.execute(actions, title: "T")
        XCTAssertEqual(r.skipped, 3)
        XCTAssertTrue(fake.exists("Downloads/Sammlung/tief/tool/main.go"))
        XCTAssertFalse(fake.exists("Documents/Archiv"))
    }

    func testDeselectedActionsDoNothing() throws {
        let fake = try FakeHome()
        fake.file("Downloads/a.txt")
        var action = move(fake, "Downloads/a.txt", to: "Documents")
        action.isSelected = false
        let r = try makeExecutor(fake).execute([action], title: "T")
        XCTAssertEqual(r.done, 0)
        XCTAssertTrue(fake.exists("Downloads/a.txt"))
    }

    func testTrashAndUndo() throws {
        let fake = try FakeHome()
        fake.file("Downloads/weg.txt", "inhalt")
        let executor = try makeExecutor(fake)
        let r = executor.execute([PlannedAction(kind: .trash, source: fake.url("Downloads/weg.txt"), destinationFolder: nil,
                                                reason: "", confidence: 1, origin: .duplicate)], title: "T")
        XCTAssertEqual(r.done, 1)
        XCTAssertFalse(fake.exists("Downloads/weg.txt"))
        XCTAssertTrue(PathUtil.exists(fake.trash.appendingPathComponent("weg.txt")), "deleting means: into the Trash")
        XCTAssertEqual(executor.undoRun(r.runID).restored, 1)
        XCTAssertTrue(fake.exists("Downloads/weg.txt"))
    }

    func testArchiveCreatesVerifiedZipAndUndo() throws {
        let fake = try FakeHome()
        fake.file("Documents/Alt/bericht.txt", String(repeating: "Bericht ", count: 100))
        let executor = try makeExecutor(fake)
        let action = PlannedAction(kind: .archive, source: fake.url("Documents/Alt"), destinationFolder: fake.url("Documents/Archiv/2026-01"),
                                   reason: "", confidence: 1, origin: .cleanup)
        let r = executor.execute([action], title: "T")
        XCTAssertEqual(r.done, 1, r.messages.joined())
        XCTAssertTrue(fake.exists("Documents/Archiv/2026-01/Alt.zip"))
        XCTAssertFalse(fake.exists("Documents/Alt"))
        XCTAssertEqual(executor.undoRun(r.runID).restored, 1)
        XCTAssertTrue(fake.exists("Documents/Alt/bericht.txt"))
        XCTAssertFalse(fake.exists("Documents/Archiv"), "created archive folders are removed again on undo")
    }

    func testSingleEntryUndoAndHistory() throws {
        let fake = try FakeHome()
        fake.file("Downloads/1.txt")
        fake.file("Downloads/2.txt")
        let executor = try makeExecutor(fake)
        let r = executor.execute([move(fake, "Downloads/1.txt", to: "Documents/Z"), move(fake, "Downloads/2.txt", to: "Documents/Z")], title: "Lauf")
        let entries = executor.journal.entries(runID: r.runID)
        XCTAssertEqual(entries.count, 2)
        guard let first = entries.first else { return XCTFail() }
        XCTAssertEqual(executor.undoEntry(first.id).restored, 1)
        XCTAssertTrue(fake.exists("Downloads/1.txt"))
        XCTAssertTrue(fake.exists("Documents/Z/2.txt"), "the other action stays, and so does its folder")
        let runs = executor.journal.runs()
        XCTAssertEqual(runs.first?.title, "Lauf")
        XCTAssertEqual(runs.first?.done, 1)
        XCTAssertEqual(runs.first?.undone, 1)
    }

    func testEmptyFolderTrashRechecksEmptiness() throws {
        let fake = try FakeHome()
        fake.dir("Documents/Leer")
        fake.file("Documents/Leer/neu.txt") // became non-empty after the suggestion
        let action = PlannedAction(kind: .trash, source: fake.url("Documents/Leer"), destinationFolder: nil, reason: "leer",
                                   confidence: 1, origin: .cleanup, requiresEmptyFolder: true)
        let r = try makeExecutor(fake).execute([action], title: "T")
        XCTAssertEqual(r.skipped, 1)
        XCTAssertTrue(fake.exists("Documents/Leer/neu.txt"))
    }

    func testFullPipelineOnMessyHomeKeepsProjectsIntact() async throws {
        let fake = try FakeHome()
        // Realistic messy home with nested projects
        fake.file("Downloads/Rechnung_Vodafone.pdf")
        fake.file("Downloads/Installer.pkg")
        fake.file("Desktop/Bildschirmfoto 2025-01-02 um 10.11.12.png")
        fake.file("Downloads/repo/.git/HEAD", "ref")
        fake.file("Downloads/repo/Rechnung_im_Repo.pdf")
        fake.file("Downloads/repo/Setup.dmg")
        fake.file("Documents/Code/game/Cargo.toml")
        fake.file("Documents/Code/game/assets/IMG_0001.png")
        let projectSnapshot = { (fake.snapshot().filter { $0.hasPrefix("Downloads/repo") || $0.hasPrefix("Documents/Code") }) }
        let projectsBefore = projectSnapshot()

        let policy = fake.policy()
        let scanner = FileScanner(home: fake.home, policy: policy, general: GeneralSettings())
        let planner = Planner(home: fake.home, policy: policy,
                              engine: RuleEngine(home: fake.home, settings: RuleSettings(), resolver: DestinationResolver(home: fake.home)),
                              structure: StructureIndex.build(home: fake.home, policy: policy), provider: nil, cache: nil,
                              general: GeneralSettings(), aiSettings: AISettings())
        let plan = await planner.plan(scan: await scanner.scan(.everything))
        let executor = try makeExecutor(fake)
        let r = executor.execute(plan.actions, title: "Alles")
        XCTAssertEqual(r.done, 3, r.messages.joined(separator: "\n"))
        XCTAssertEqual(projectSnapshot(), projectsBefore, "project folders must be untouched")
        XCTAssertTrue(fake.exists("Documents/Finanzen/Rechnungen"))
        XCTAssertTrue(fake.exists("Downloads/Installer/Installer.pkg"))
        _ = executor.undoRun(r.runID)
        XCTAssertTrue(fake.exists("Downloads/Rechnung_Vodafone.pdf"))
        XCTAssertFalse(fake.exists("Documents/Finanzen"))
    }
}

final class DuplicateAndCleanupTests: XCTestCase {
    func testDuplicatesWithKeeperChoice() async throws {
        let fake = try FakeHome()
        fake.file("Downloads/Vertrag (1).pdf", "VERTRAG")
        fake.file("Documents/Verträge/Mietvertrag.pdf", "VERTRAG")
        fake.file("Desktop/Mietvertrag Kopie.pdf", "VERTRAG")
        fake.file("Downloads/anders.pdf", "ANDERS!")
        fake.file("Downloads/proj/.git/HEAD")
        fake.file("Downloads/proj/Mietvertrag.pdf", "VERTRAG")
        let policy = fake.policy()
        let scan = await FileScanner(home: fake.home, policy: policy, general: GeneralSettings()).scan(.everything)
        let groups = await DuplicateFinder(home: fake.home).find(in: scan.allFiles)
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.files.count, 3, "copies inside projects are ignored")
        XCTAssertEqual(group.keeper.name, "Mietvertrag.pdf")
        XCTAssertTrue(group.keeper.url.path.contains("/Documents/"))
        let actions = DuplicateFinder(home: fake.home).actions(for: groups)
        XCTAssertEqual(Set(actions.map { $0.source.lastPathComponent }), ["Vertrag (1).pdf", "Mietvertrag Kopie.pdf"])
        XCTAssertTrue(actions.allSatisfy { $0.kind == .trash })
    }

    func testHardLinksAreNoDuplicates() async throws {
        let fake = try FakeHome()
        let a = fake.file("Documents/a.bin", "SAME")
        try FileManager.default.linkItem(at: a, to: fake.url("Documents/b.bin"))
        let scan = await FileScanner(home: fake.home, policy: fake.policy(), general: GeneralSettings()).scan(.everything)
        let groups = await DuplicateFinder(home: fake.home).find(in: scan.allFiles)
        XCTAssertTrue(groups.isEmpty)
    }

    func testCleanupSuggestionsNeverAutomatic() async throws {
        let fake = try FakeHome()
        fake.file("Downloads/Alt.dmg")
        fake.file("Downloads/Paket.zip")
        fake.file("Downloads/Paket/inhalt.txt")
        fake.dir("Documents/Leer")
        fake.file("Downloads/kaputt.crdownload", modified: .daysAgo(10))
        let scan = await FileScanner(home: fake.home, policy: fake.policy(), general: GeneralSettings()).scan(.everything)
        // "Added to Downloads" cannot be back-dated, so the advisor's clock runs 100 days ahead instead.
        let advisor = CleanupAdvisor(home: fake.home, settings: CleanupSettings(), now: Date().addingTimeInterval(100 * 86_400))
        let suggestions = await advisor.suggestions(for: scan)
        let categories = Dictionary(grouping: suggestions, by: \.category)
        XCTAssertEqual(categories[.oldInstaller]?.first?.url.lastPathComponent, "Alt.dmg")
        XCTAssertEqual(categories[.extractedArchive]?.first?.url.lastPathComponent, "Paket.zip")
        XCTAssertEqual(categories[.emptyFolder]?.first?.url.lastPathComponent, "Leer")
        XCTAssertEqual(categories[.staleDownload]?.first?.url.lastPathComponent, "kaputt.crdownload")
        XCTAssertTrue(suggestions.allSatisfy { $0.choice == .keep }, "nothing is pre-selected")
        XCTAssertTrue(advisor.actions(for: suggestions).isEmpty)

        var chosen = suggestions
        for i in chosen.indices { chosen[i].choice = chosen[i].allowsArchive ? .archive : .trash }
        let actions = advisor.actions(for: chosen)
        XCTAssertEqual(actions.count, suggestions.count)
        let journal = try Journal(url: fake.root.appendingPathComponent("j.sqlite"))
        let executor = Executor(home: fake.home, policy: fake.policy(), journal: journal, trash: FakeTrash(folder: fake.trash),
                                openFiles: StaticOpenFilesProvider())
        let r = executor.execute(actions, title: "Aufräumen")
        XCTAssertEqual(r.done, actions.count, r.messages.joined(separator: "\n"))
        XCTAssertTrue(PathUtil.exists(fake.trash.appendingPathComponent("kaputt.crdownload")))
        XCTAssertEqual(executor.undoRun(r.runID).failed, 0)
        XCTAssertTrue(fake.exists("Downloads/Alt.dmg"))
        XCTAssertTrue(fake.exists("Documents/Leer"))
    }
}

final class BackgroundTests: XCTestCase {
    func testFolderWatcherReportsNewFiles() throws {
        let fake = try FakeHome()
        let folder = fake.url("Downloads")
        let seen = expectation(description: "FSEvents callback")
        seen.assertForOverFulfill = false
        let watcher = FolderWatcher(folders: [folder]) { paths in
            if paths.contains(where: { $0.hasSuffix("neu.pdf") }) { seen.fulfill() }
        }
        watcher.start()
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.5)
        fake.file("Downloads/neu.pdf")
        wait(for: [seen], timeout: 10)
    }

    func testOnlySettledSafeFilesAreMovedRestGoesToReview() async throws {
        let fake = try FakeHome()
        let journal = try Journal(url: fake.root.appendingPathComponent("bg.sqlite"))
        let home = fake.home
        let organizer = BackgroundOrganizer(
            home: home, watchedFolders: [fake.url("Downloads")], settleSeconds: 30, autoThreshold: 0.9, journal: journal,
            openFiles: StaticOpenFilesProvider(),
            makePolicy: { ProtectionPolicy(home: home, settings: ProtectionSettings()) },
            makePlanner: { policy in
                Planner(home: home, policy: policy,
                        engine: RuleEngine(home: home, settings: RuleSettings(), resolver: DestinationResolver(home: home)),
                        structure: StructureIndex(folders: []), provider: nil, cache: nil, general: GeneralSettings(), aiSettings: AISettings())
            },
            executor: { policy in
                Executor(home: home, policy: policy, journal: journal, trash: FakeTrash(folder: fake.trash), openFiles: StaticOpenFilesProvider())
            })
        let start = Date()
        fake.file("Downloads/Setup.dmg")
        fake.file("Downloads/bild.png")
        fake.file("Downloads/laeuft.crdownload")
        fake.file("Downloads/Unterordner/x.txt")
        organizer.note(paths: [fake.url("Downloads/Setup.dmg").path, fake.url("Downloads/bild.png").path,
                               fake.url("Downloads/laeuft.crdownload").path, fake.url("Downloads/Unterordner/x.txt").path], now: start)
        let early = await organizer.tick(now: start.addingTimeInterval(5))
        XCTAssertNil(early, "nothing happens before the settle time")
        XCTAssertTrue(fake.exists("Downloads/Setup.dmg"))

        let maybeOutcome = await organizer.tick(now: start.addingTimeInterval(40))
        let outcome = try XCTUnwrap(maybeOutcome)
        XCTAssertEqual(outcome.moved.map { $0.source.lastPathComponent }, ["Setup.dmg"])
        XCTAssertTrue(fake.exists("Downloads/Installer/Setup.dmg"))
        XCTAssertTrue(fake.exists("Downloads/bild.png"), "low confidence stays and goes to review")
        XCTAssertEqual(journal.reviewItems().map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["bild.png"])
        XCTAssertTrue(fake.exists("Downloads/laeuft.crdownload"))
        XCTAssertTrue(fake.exists("Downloads/Unterordner/x.txt"))

        // Undo from the notification
        let runID = try XCTUnwrap(outcome.runID)
        let undo = Executor(home: home, policy: ProtectionPolicy(home: home, settings: ProtectionSettings()), journal: journal,
                            trash: FakeTrash(folder: fake.trash), openFiles: StaticOpenFilesProvider()).undoRun(runID)
        XCTAssertEqual(undo.restored, 1)
        XCTAssertTrue(fake.exists("Downloads/Setup.dmg"))
    }
}
