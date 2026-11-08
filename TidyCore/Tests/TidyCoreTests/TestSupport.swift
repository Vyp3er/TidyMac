import Foundation
@testable import TidyCore
import XCTest

/// A throw-away home folder in the temporary directory. Tests never touch real user files.
final class FakeHome {
    let root: URL
    let home: HomeContext
    let trash: URL

    init(file: StaticString = #filePath) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("TidyMacTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = PathUtil.normalizeRoot(base)
        let homeURL = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        home = HomeContext(home: homeURL)
        trash = root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        for name in ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library/Preferences"] {
            try FileManager.default.createDirectory(at: home.folder(name), withIntermediateDirectories: true)
        }
    }

    deinit {
        // Safety: only ever delete inside the temporary directory.
        let tmp = PathUtil.normalizeRoot(FileManager.default.temporaryDirectory)
        if PathUtil.isDescendant(root, of: tmp, orEqual: false) {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @discardableResult
    func file(_ relative: String, _ contents: String = "x", modified: Date? = nil) -> URL {
        let url = home.home.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8))
        if let modified {
            try? FileManager.default.setAttributes([.modificationDate: modified, .creationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    @discardableResult
    func dir(_ relative: String) -> URL {
        let url = home.home.appendingPathComponent(relative, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func url(_ relative: String) -> URL {
        home.home.appendingPathComponent(relative)
    }

    func exists(_ relative: String) -> Bool {
        PathUtil.exists(url(relative))
    }

    func policy(_ settings: ProtectionSettings = ProtectionSettings()) -> ProtectionPolicy {
        ProtectionPolicy(home: home, settings: settings, references: ReferenceIndex.load(home: home))
    }

    /// Snapshot of every path below home (for "nothing changed" assertions).
    func snapshot() -> [String] {
        var result: [String] = []
        if let e = FileManager.default.enumerator(atPath: home.home.path) {
            for case let p as String in e { result.append(p) }
        }
        return result.sorted()
    }
}

/// Trash replacement for tests: moves into a folder inside the temp directory.
struct FakeTrash: TrashService {
    let folder: URL

    func trash(_ url: URL) throws -> URL {
        let name = FileNameTools.uniqueName(for: url.lastPathComponent, in: folder)
        let dest = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}

extension Date {
    static func daysAgo(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86_400) }
}
