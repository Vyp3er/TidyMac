import Foundation
@testable import TidyCore
import XCTest

final class ScannerTests: XCTestCase {
    func makeScanner(_ fake: FakeHome, general: GeneralSettings = GeneralSettings(),
                     protection: ProtectionSettings = ProtectionSettings()) -> FileScanner {
        FileScanner(home: fake.home, policy: fake.policy(protection), general: general)
    }

    /// Builds a realistic messy Downloads folder with projects and units inside.
    func buildMessyDownloads(_ fake: FakeHome) {
        fake.file("Downloads/Rechnung_Telekom_2024.pdf")
        fake.file("Downloads/Installer.dmg")
        fake.file("Downloads/Scan_0012.pdf")
        // Project folders in all flavours
        fake.dir("Downloads/webapp/.git")
        fake.file("Downloads/webapp/package.json", "{}")
        fake.file("Downloads/webapp/src/index.js")
        fake.file("Downloads/rustproj/Cargo.toml")
        fake.file("Downloads/rustproj/src/main.rs")
        fake.file("Downloads/pyproj/requirements.txt")
        fake.file("Downloads/pyproj/main.py")
        fake.file("Downloads/thesis/main.tex")
        fake.file("Downloads/thesis/kapitel1.tex")
        fake.dir("Downloads/iosapp/App.xcodeproj")
        fake.file("Downloads/iosapp/App/ContentView.swift")
        // Cohesive units
        for i in 1...6 { fake.file("Downloads/Urlaub/IMG_\(i).jpg") }
        fake.file("Downloads/Paket.zip")
        fake.file("Downloads/Paket/readme.txt")
        // A unit that contains a project must never move
        fake.file("Downloads/Sammlung/notes.txt")
        fake.file("Downloads/Sammlung/tool/Makefile")
        // Saved web page
        fake.file("Downloads/Artikel.html")
        fake.file("Downloads/Artikel_files/style.css")
        // Empty folder, hidden file, incomplete download, app bundle
        fake.dir("Downloads/Leer")
        fake.file("Downloads/.geheim")
        fake.file("Downloads/film.mp4.crdownload")
        fake.file("Downloads/Tool.app/Contents/Info.plist")
    }

    func testProjectContentsAreNeverCandidates() async throws {
        let fake = try FakeHome()
        buildMessyDownloads(fake)
        let result = await makeScanner(fake).scan(.folders([fake.url("Downloads")]))

        let candidateNames = Set(result.candidates.map(\.name))
        XCTAssertEqual(candidateNames, ["Rechnung_Telekom_2024.pdf", "Installer.dmg", "Scan_0012.pdf", "Paket.zip"])

        let allPaths = result.allFiles.map { fake.home.abbreviate($0.url) }
        for project in ["webapp", "rustproj", "pyproj", "thesis", "iosapp"] {
            XCTAssertFalse(allPaths.contains { $0.contains("/\(project)/") }, "\(project) content leaked into scan")
            XCTAssertTrue(result.protected.contains { $0.url.lastPathComponent == project }, "\(project) not listed as protected")
        }
        XCTAssertFalse(result.folderCandidates.contains { ["webapp", "rustproj", "pyproj", "thesis", "iosapp"].contains($0.name) })
    }

    func testUnitsAndSpecialCases() async throws {
        let fake = try FakeHome()
        buildMessyDownloads(fake)
        let result = await makeScanner(fake).scan(.folders([fake.url("Downloads")]))

        let units = Dictionary(uniqueKeysWithValues: result.folderCandidates.map { ($0.name, $0) })
        XCTAssertEqual(units["Urlaub"]?.kind, .photoSeries)
        XCTAssertEqual(units["Urlaub"]?.fileCount, 6)
        XCTAssertEqual(units["Paket"]?.kind, .extractedArchive)
        XCTAssertNotNil(units["Sammlung"]?.blockedReason, "unit with a project inside must be blocked")
        XCTAssertNil(units["Leer"], "empty folders are no units")
        XCTAssertTrue(result.emptyFolders.contains { $0.lastPathComponent == "Leer" })

        XCTAssertTrue(result.allFiles.filter { $0.url.path.contains("/Urlaub/") }.allSatisfy { $0.context == .inUnit })

        func reason(_ name: String) -> ProtectionReason? { result.protected.first { $0.url.lastPathComponent == name }?.reason }
        XCTAssertEqual(reason("Artikel.html"), .savedWebPage)
        XCTAssertEqual(reason("Artikel_files"), .savedWebPage)
        XCTAssertEqual(reason("film.mp4.crdownload"), .incompleteDownload)
        XCTAssertEqual(reason("Tool.app"), .bundle(ext: "app"))
        XCTAssertFalse(result.candidates.contains { $0.name == ".geheim" })
    }

    func testScanIsReadOnly() async throws {
        let fake = try FakeHome()
        buildMessyDownloads(fake)
        let before = fake.snapshot()
        _ = await makeScanner(fake).scan(.everything)
        XCTAssertEqual(before, fake.snapshot())
    }

    func testEverythingSkipsLibraryAndKeepsStructure() async throws {
        let fake = try FakeHome()
        fake.file("Library/Application Support/app/data.db")
        fake.file("Documents/Uni/Mathe/blatt1.pdf")
        fake.file("Documents/lose.pdf")
        fake.file("loose-in-home.txt")
        fake.file("Projekte/website/.git/HEAD")
        fake.file("Projekte/website/index.html")
        let result = await makeScanner(fake).scan(.everything)

        let names = Set(result.candidates.map(\.name))
        XCTAssertTrue(names.contains("lose.pdf"))
        XCTAssertTrue(names.contains("loose-in-home.txt"))
        XCTAssertFalse(names.contains("blatt1.pdf"), "files in existing structure stay where they are")
        XCTAssertTrue(result.allFiles.contains { $0.name == "blatt1.pdf" && $0.context == .nested })
        XCTAssertFalse(result.allFiles.contains { $0.url.path.contains("/Library/") })
        XCTAssertFalse(result.allFiles.contains { $0.url.path.contains("/website/") })
    }

    func testSubfolderFilesOnlyWhenEnabled() async throws {
        let fake = try FakeHome()
        fake.file("Documents/Chaos/Unterordner/datei.pdf")
        var general = GeneralSettings()
        let off = await makeScanner(fake, general: general).scan(.folders([fake.url("Documents/Chaos")]))
        XCTAssertTrue(off.candidates.isEmpty)
        general.includeSubfolderFiles = true
        let on = await makeScanner(fake, general: general).scan(.folders([fake.url("Documents/Chaos")]))
        XCTAssertEqual(on.candidates.map(\.name), ["datei.pdf"])
    }

    func testSelectedRootInsideProjectIsRefused() async throws {
        let fake = try FakeHome()
        fake.file("Documents/app/Package.swift")
        fake.file("Documents/app/Sources/x.swift")
        let result = await makeScanner(fake).scan(.folders([fake.url("Documents/app/Sources")]))
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertFalse(result.notes.isEmpty)
    }

    func testSymlinkTargetsBecomeReferences() async throws {
        let fake = try FakeHome()
        let target = fake.dir("Documents/Ziel")
        try FileManager.default.createSymbolicLink(at: fake.url("Desktop/Verknüpfung"), withDestinationURL: target)
        let scanner = makeScanner(fake)
        _ = await scanner.scan(.folders([fake.url("Desktop")]))
        XCTAssertNotNil(scanner.policy.referenceWarning(for: target))
    }

    func testStructureIndexExcludesProtectedFolders() throws {
        let fake = try FakeHome()
        fake.dir("Documents/Uni/Mathe")
        fake.file("Documents/Code/app/.git/HEAD")
        for i in 1...6 { fake.file("Pictures/Album/IMG_\(i).jpg") }
        let index = StructureIndex.build(home: fake.home, policy: fake.policy())
        let list = index.displayList(home: fake.home)
        XCTAssertTrue(list.contains("~/Documents/Uni/Mathe"))
        XCTAssertFalse(list.contains("~/Documents/Code/app"))
        XCTAssertFalse(list.contains("~/Pictures/Album"))
    }
}
