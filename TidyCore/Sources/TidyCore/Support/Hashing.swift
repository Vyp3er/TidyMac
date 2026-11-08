import CryptoKit
import Foundation

public enum FileHasher {
    public static let partialChunk = 64 * 1024

    /// SHA-256 of the first and last 64 KB plus the size. Cheap pre-filter for duplicates.
    public static func partialHash(of url: URL, size: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        do {
            if let head = try handle.read(upToCount: partialChunk) { hasher.update(data: head) }
            if size > Int64(partialChunk * 2) {
                try handle.seek(toOffset: UInt64(size) - UInt64(partialChunk))
                if let tail = try handle.read(upToCount: partialChunk) { hasher.update(data: tail) }
            }
        } catch {
            return nil
        }
        return hex(hasher.finalize())
    }

    /// Streaming SHA-256 of the whole file.
    public static func fullHash(of url: URL, isCancelled: () -> Bool = { false }) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while true {
                if isCancelled() { return nil }
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hex(hasher.finalize())
    }

    /// Content fingerprint used as AI cache key: full hash for files up to 32 MB, partial above.
    public static func contentFingerprint(of url: URL, size: Int64) -> String? {
        if size <= 32 * 1024 * 1024 { return fullHash(of: url) }
        return partialHash(of: url, size: size).map { "p:" + $0 }
    }

    public static func sha256(_ string: String) -> String {
        hex(SHA256.hash(data: Data(string.utf8)))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
