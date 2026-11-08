import CoreServices
import Foundation

/// Extended attributes written by macOS (download origin, quarantine, screenshot flag).
public enum XAttr {
    public static func data(_ name: String, at url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { buffer -> Int in
                getxattr(path, name, buffer.baseAddress, size, 0, XATTR_NOFOLLOW)
            }
            guard read > 0 else { return nil }
            return data.prefix(read)
        }
    }

    @discardableResult
    public static func set(_ name: String, data: Data, at url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return data.withUnsafeBytes { buffer -> Bool in
                setxattr(path, name, buffer.baseAddress, data.count, 0, XATTR_NOFOLLOW) == 0
            }
        }
    }

    private static func plistValue(_ name: String, at url: URL) -> Any? {
        guard let d = data(name, at: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: d, format: nil)
    }

    /// URLs a file was downloaded from (`kMDItemWhereFroms`).
    public static func whereFroms(_ url: URL) -> [String] {
        (plistValue("com.apple.metadata:kMDItemWhereFroms", at: url) as? [String]) ?? []
    }

    /// Name of the app that downloaded the file (from `com.apple.quarantine`).
    public static func quarantineAgent(_ url: URL) -> String? {
        guard let d = data("com.apple.quarantine", at: url),
              let s = String(data: d, encoding: .utf8) else { return nil }
        let parts = s.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count > 2 else { return nil }
        let agent = parts[2].trimmingCharacters(in: .whitespaces)
        return agent.isEmpty ? nil : agent
    }

    public static func isScreenCapture(_ url: URL) -> Bool {
        let value = plistValue("com.apple.metadata:kMDItemIsScreenCapture", at: url)
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return false
    }
}

/// Spotlight metadata for a single file. All fields are optional; Spotlight may be off.
public struct SpotlightInfo: Sendable, Hashable {
    public var isScreenCapture = false
    public var cameraModel: String?
    public var contentCreated: Date?
    public var lastUsed: Date?

    public static let empty = SpotlightInfo()
}

public enum Spotlight {
    public static func info(for url: URL) -> SpotlightInfo {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return .empty }
        func attribute(_ key: CFString) -> Any? {
            MDItemCopyAttribute(item, key)
        }
        var info = SpotlightInfo()
        info.lastUsed = attribute(kMDItemLastUsedDate) as? Date
        info.contentCreated = attribute(kMDItemContentCreationDate) as? Date
        let make = attribute(kMDItemAcquisitionMake) as? String
        let model = attribute(kMDItemAcquisitionModel) as? String
        if let model { info.cameraModel = [make, model].compactMap { $0 }.joined(separator: " ") }
        if let flag = attribute("kMDItemIsScreenCapture" as CFString) as? NSNumber {
            info.isScreenCapture = flag.boolValue
        }
        return info
    }
}
