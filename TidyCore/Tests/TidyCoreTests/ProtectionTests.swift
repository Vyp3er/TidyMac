import Foundation
@testable import TidyCore
import XCTest

final class ProjectDetectorTests: XCTestCase {
    let detector = ProjectDetector()

    func testEveryRequiredMarkerIsDetected() {
        let required = [".git", "package.json", "Cargo.toml", "CMakeLists.txt", "Makefile", "pyproject.toml",
                         "requirements.txt", "MyApp.xcodeproj", "MyApp.xcworkspace", "go.mod", "pom.xml", "build.gradle",
                         ".vscode", ".idea", "node_modules", "venv", ".venv", "Package.swift", "Gemfile", "setup.py"]
        for marker in required {
            XCTAssertNotNil(detector.marker(folderName: "proj", entries: [marker, "README.md"]), "\(marker) not detected")
        }
    }

    func testLatexProjects() {
        XCTAssertNotNil(detector.marker(folderName: "thesis", entries: ["main.tex", "chapter1.tex"]))
        XCTAssertNotNil(detector.marker(folderName: "paper", entries: ["paper.tex", "refs.bib"]))
        XCTAssertNil(detector.marker(folderName: "single", entries: ["notes.tex"]))
    }

    func testArduinoAndUnity() {
        XCTAssertNotNil(detector.marker(folderName: "Blink", entries: ["Blink.ino"]))
        XCTAssertNotNil(detector.marker(folderName: "Game", entries: ["Assets", "ProjectSettings"]))
    }

    func testPlainFolderIsNoProject() {
        XCTAssertNil(detector.marker(folderName: "Fotos", entries: ["a.jpg", "b.jpg", "notes.txt"]))
    }

    func testExtraMarkers() {
        let d = ProjectDetector(extraMarkers: ["MEINPROJEKT"])
        XCTAssertEqual(d.marker(folderName: "x", entries: ["MEINPROJEKT"]), "MEINPROJEKT")
    }
}

final class ProtectionPolicyTests: XCTestCase {
    func testTabooZones() throws {
        let fake = try FakeHome()
        let policy = fake.policy()
        let lib = fake.file("Library/Preferences/foo.plist")
        XCTAssertEqual(policy.itemProtection(lib), .library)
        XCTAssertEqual(policy.itemProtection(fake.file("Downloads/.hidden")), .hidden)
        XCTAssertEqual(policy.itemProtection(URL(fileURLWithPath: "/System/Library")), .systemLocation)
        XCTAssertEqual(policy.itemProtection(URL(fileURLWithPath: "/Applications/Safari.app")), .systemLocation)
        XCTAssertNil(policy.itemProtection(fake.file("Downloads/normal.pdf")))
    }

    func testBundlesAndPackages() throws {
        let fake = try FakeHome()
        let policy = fake.policy()
        let app = fake.dir("Downloads/Tool.app")
        fake.file("Downloads/Tool.app/Contents/Info.plist")
        XCTAssertEqual(policy.itemProtection(app), .bundle(ext: "app"))
        let photos = fake.dir("Pictures/Fotos.photoslibrary")
        XCTAssertEqual(policy.itemProtection(photos), .bundle(ext: "photoslibrary"))
        let fcp = fake.dir("Movies/Film.fcpbundle")
        XCTAssertEqual(policy.itemProtection(fcp), .bundle(ext: "fcpbundle"))
    }

    func testSymlinksAreNeverTouched() throws {
        let fake = try FakeHome()
        let target = fake.dir("Documents/Ziel")
        let link = fake.url("Downloads/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(fake.policy().itemProtection(link), .symlink)
    }

    func testUserExclusions() throws {
        let fake = try FakeHome()
        var settings = ProtectionSettings()
        settings.excludedPaths = ["~/Documents/Steuer"]
        settings.excludedPatterns = ["*.psd", "~/Downloads/Behalten/*"]
        let policy = fake.policy(settings)
        XCTAssertNotNil(policy.itemProtection(fake.file("Documents/Steuer/2024.pdf")))
        XCTAssertNotNil(policy.itemProtection(fake.file("Downloads/design.psd")))
        XCTAssertNotNil(policy.itemProtection(fake.file("Downloads/Behalten/x.txt")))
        XCTAssertNil(policy.itemProtection(fake.file("Downloads/x.txt")))
    }

    func testIncompleteDownloads() throws {
        let fake = try FakeHome()
        XCTAssertEqual(fake.policy().itemProtection(fake.file("Downloads/movie.mp4.crdownload")), .incompleteDownload)
        XCTAssertEqual(fake.policy().itemProtection(fake.file("Downloads/a.part")), .incompleteDownload)
    }

    func testCloudFolders() throws {
        let fake = try FakeHome()
        let policy = fake.policy()
        let dropbox = fake.dir("Dropbox")
        fake.file("Dropbox/a.txt")
        guard case .protected(.cloudSync) = policy.directoryClass(dropbox) else { return XCTFail("Dropbox not protected") }
        let marked = fake.dir("Documents/Sync")
        fake.file("Documents/Sync/.dropbox")
        guard case .protected(.cloudSync) = policy.directoryClass(marked) else { return XCTFail("marker not detected") }

        var settings = ProtectionSettings()
        settings.allowedCloudPaths = ["~/Dropbox"]
        guard case .normal = fake.policy(settings).directoryClass(dropbox) else { return XCTFail("release not honoured") }
    }

    func testAppDatabaseFolder() throws {
        let fake = try FakeHome()
        let zot = fake.dir("Documents/Literatur")
        fake.file("Documents/Literatur/library.sqlite")
        guard case .protected(.appDatabase) = fake.policy().directoryClass(zot) else { return XCTFail() }
    }

    func testAppManagedFolders() throws {
        let fake = try FakeHome()
        let music = fake.dir("Music/Music")
        XCTAssertEqual(fake.policy().itemProtection(music), .appManaged(name: "Music"))
        let vm = fake.dir("Documents/Virtual Machines.localized")
        XCTAssertNotNil(fake.policy().itemProtection(vm))
    }

    func testStandardFoldersAreNoProjectsBecauseOfLooseFiles() throws {
        let fake = try FakeHome()
        fake.file("Downloads/requirements.txt")
        fake.file("Downloads/Makefile")
        guard case .normal = fake.policy().directoryClass(fake.url("Downloads")) else {
            return XCTFail("Downloads must not become a project because of loose files")
        }
        fake.dir("Documents/.git")
        guard case .protected(.projectRoot) = fake.policy().directoryClass(fake.url("Documents")) else {
            return XCTFail("a git repository stays protected")
        }
    }

    func testAncestorAndDestinationProtection() throws {
        let fake = try FakeHome()
        fake.dir("Documents/Code/app/.git")
        let inner = fake.file("Documents/Code/app/src/main.swift")
        let policy = fake.policy()
        guard case .insideProject = policy.ancestorProtection(of: inner) else { return XCTFail("inside project not detected") }
        guard case .insideProject = policy.destinationProtection(for: fake.url("Documents/Code/app/neu")) else {
            return XCTFail("moving into a project must be refused")
        }
        guard case .projectRoot = policy.destinationProtection(for: fake.url("Documents/Code/app")) else {
            return XCTFail("project root as destination must be refused")
        }
        XCTAssertEqual(policy.destinationProtection(for: fake.url("Library/Foo")), .library)
        XCTAssertEqual(policy.destinationProtection(for: fake.url("Documents/.versteckt/x")), .hidden)
        XCTAssertNil(policy.destinationProtection(for: fake.url("Documents/Finanzen/Neu/2024")))
        XCTAssertEqual(policy.destinationProtection(for: URL(fileURLWithPath: "/tmp/x")), .systemLocation)
    }

    func testReferencesFromDock() throws {
        let fake = try FakeHome()
        let projects = fake.dir("Documents/Wichtig")
        let dock: [String: Any] = ["persistent-others": [["tile-data": ["file-data": ["_CFURLString": projects.absoluteString, "_CFURLStringType": 15]]]]]
        let data = try PropertyListSerialization.data(fromPropertyList: dock, format: .binary, options: 0)
        try data.write(to: fake.url("Library/Preferences/com.apple.dock.plist"))
        let policy = fake.policy()
        XCTAssertNotNil(policy.referenceWarning(for: projects))
        XCTAssertNotNil(policy.referenceWarning(for: fake.url("Documents")), "parent of a referenced folder warns too")
        XCTAssertNil(policy.referenceWarning(for: fake.dir("Documents/Anderes")))
    }
}

final class CohesionTests: XCTestCase {
    func info(_ names: [String], dirs: [String] = []) -> [EntryInfo] {
        names.map { EntryInfo(name: $0, isDirectory: false) } + dirs.map { EntryInfo(name: $0, isDirectory: true) }
    }

    func testKinds() {
        XCTAssertEqual(CohesionDetector.kind(folderName: "Urlaub", entries: info((1...8).map { "IMG_\($0).jpg" }), siblingNames: []), .photoSeries)
        XCTAssertEqual(CohesionDetector.kind(folderName: "Album", entries: info(["01 a.mp3", "02 b.mp3", "03 c.mp3", "cover.jpg"]), siblingNames: []), .musicAlbum)
        XCTAssertEqual(CohesionDetector.kind(folderName: "site", entries: info(["index.html", "about.html"], dirs: ["css"]), siblingNames: []), .website)
        XCTAssertEqual(CohesionDetector.kind(folderName: "Paket", entries: info(["a.txt"]), siblingNames: ["Paket.zip"]), .extractedArchive)
        XCTAssertEqual(CohesionDetector.kind(folderName: "Abgabe Blatt 3", entries: info(["loesung.pdf"]), siblingNames: []), .submission)
        XCTAssertNil(CohesionDetector.kind(folderName: "Kram", entries: info(["a.pdf", "b.docx"]), siblingNames: []))
    }

    func testSavedWebPages() {
        let names = CohesionDetector.savedWebPageNames(in: ["Artikel.html", "Artikel_files", "andere.html"])
        XCTAssertEqual(names, ["Artikel.html", "Artikel_files"])
    }
}

final class NameToolsTests: XCTestCase {
    func testMeaninglessNames() {
        for name in ["IMG_4831.jpg", "Scan_0012.pdf", "Dokument (3).docx", "DSC01234.JPG", "Untitled.png", "12345.pdf",
                     "PXL_20240101_123456789.jpg", "document.pdf", "Unbenannt 2.txt", "8f3a9c1b2e7d4a6b9c0d1e2f.pdf"] {
            XCTAssertTrue(NameAnalyzer.isMeaningless(name), name)
        }
        for name in ["Rechnung Telekom März 2024.pdf", "Bewerbung Lebenslauf.docx", "Bildschirmfoto 2024-01-01 um 10.00.00.png",
                     "my_project_report_2024_final.pdf", "Urlaub Italien.jpg", "Steuererklärung 2023.pdf"] {
            XCTAssertFalse(NameAnalyzer.isMeaningless(name), name)
        }
    }

    func testUniqueNamesNeverCollide() throws {
        let fake = try FakeHome()
        fake.file("Documents/a.pdf")
        fake.file("Documents/a 2.pdf")
        XCTAssertEqual(FileNameTools.uniqueName(for: "a.pdf", in: fake.url("Documents")), "a 3.pdf")
        XCTAssertEqual(FileNameTools.uniqueName(for: "b.pdf", in: fake.url("Documents"), reserved: ["b.pdf"]), "b 2.pdf")
    }

    func testDatesFromNames() {
        func ymd(_ name: String) -> String? {
            FileItem.parseDate(in: name).map {
                let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: $0)
                return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            }
        }
        XCTAssertEqual(ymd("Bildschirmfoto 2025-02-14 um 09.12.33"), "2025-02-14")
        XCTAssertEqual(ymd("PXL_20240101_123456789"), "2024-01-01")
        XCTAssertEqual(ymd("Rechnung 05.03.2023"), "2023-03-05")
        XCTAssertEqual(ymd("Rechnung_Telekom_03-2025"), "2025-03-01")
        XCTAssertNil(ymd("Scan_0012"))
        XCTAssertNil(ymd("Version 2.13.99"))
    }

    func testSanitize() {
        XCTAssertEqual(FileNameTools.sanitize("  Rechnung: März/April  "), "Rechnung- März-April")
        XCTAssertEqual(FileNameTools.sanitize("..versteckt"), "versteckt")
        XCTAssertEqual(FileNameTools.split("archiv.tar.gz").ext, "gz")
        XCTAssertEqual(FileNameTools.split("Version 1.2 final").ext, "")
        XCTAssertEqual(FileNameTools.split(".bashrc").ext, "")
    }
}
