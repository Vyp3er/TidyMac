import Darwin
import Foundation

/// "Delete" in TidyMac always means: move to the Trash.
public protocol TrashService: Sendable {
    /// Moves the item to the Trash and returns its new location there.
    func trash(_ url: URL) throws -> URL
}

public struct SystemTrash: TrashService {
    public init() {}

    public func trash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let result = resulting as URL? else {
            throw FileOperationError.trashFailed(url.path)
        }
        return result
    }
}

public enum FileOperationError: Error, LocalizedError, Sendable {
    case sourceMissing(String)
    case destinationExists(String)
    case crossDevice(String)
    case trashFailed(String)
    case protected(String)
    case archiveFailed(String)
    case system(String)

    public var errorDescription: String? {
        switch self {
        case let .sourceMissing(p): return "Quelle existiert nicht mehr: \(p)"
        case let .destinationExists(p): return "Ziel existiert bereits: \(p)"
        case let .crossDevice(p): return "Ziel liegt auf einem anderen Volume (nicht unterstützt): \(p)"
        case let .trashFailed(p): return "Konnte nicht in den Papierkorb legen: \(p)"
        case let .protected(r): return "Geschützt: \(r)"
        case let .archiveFailed(r): return "Archivieren fehlgeschlagen: \(r)"
        case let .system(r): return r
        }
    }
}

public enum SafeFileOps {
    /// Atomic rename that fails instead of overwriting (`renamex_np` with `RENAME_EXCL`).
    public static func moveExclusive(from source: URL, to destination: URL) throws {
        let rc = source.withUnsafeFileSystemRepresentation { src -> Int32 in
            destination.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let src, let dst else { return -1 }
                return renamex_np(src, dst, UInt32(RENAME_EXCL))
            }
        }
        if rc == 0 { return }
        let code = errno
        switch code {
        case EEXIST: throw FileOperationError.destinationExists(destination.path)
        case ENOENT: throw FileOperationError.sourceMissing(source.path)
        case EXDEV: throw FileOperationError.crossDevice(destination.path)
        default: throw FileOperationError.system(String(cString: strerror(code)) + " (\(destination.path))")
        }
    }

    /// Moves `source` into `folder` with the wanted name; picks "Name 2.ext" etc. on conflicts.
    /// Never overwrites. Returns the final URL.
    public static func moveAvoidingConflicts(_ source: URL, toFolder folder: URL, name: String) throws -> URL {
        var candidate = name
        for _ in 0..<1000 {
            let dest = folder.appendingPathComponent(candidate)
            do {
                try moveExclusive(from: source, to: dest)
                return dest
            } catch FileOperationError.destinationExists {
                candidate = FileNameTools.uniqueName(for: name, in: folder, reserved: [candidate])
            }
        }
        throw FileOperationError.destinationExists(folder.appendingPathComponent(name).path)
    }

    /// Creates `folder` and missing parents one by one. Returns the folders that were created
    /// (outermost first), so undo can remove exactly those — and only if they are empty.
    public static func createFolders(_ folder: URL) throws -> [URL] {
        var missing: [URL] = []
        var current = folder.standardizedFileURL
        while !PathUtil.exists(current) {
            missing.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        guard PathUtil.isDirectory(current) else {
            throw FileOperationError.system("Kein Ordner: \(current.path)")
        }
        var created: [URL] = []
        for dir in missing.reversed() {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            created.append(dir)
        }
        return created
    }

    /// Removes a folder only if it is empty (ignoring .DS_Store). Never recursive.
    @discardableResult
    public static func removeIfEmpty(_ folder: URL) -> Bool {
        guard PathUtil.isDirectory(folder), !PathUtil.isSymlink(folder),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        let rest = entries.filter { $0 != ".DS_Store" && $0 != ".localized" }
        guard rest.isEmpty else { return false }
        for e in entries { unlink(folder.appendingPathComponent(e).path) }
        return rmdir(folder.path) == 0
    }
}
