import Foundation
import UniformTypeIdentifiers

/// Where a file sits relative to the scan root. Only `.loose` (and `.nested` when enabled)
/// files are ever sorted individually.
public enum FileContext: String, Codable, Sendable, Hashable {
    /// Directly inside a scan root.
    case loose
    /// Inside a normal sub folder (existing structure).
    case nested
    /// Inside a folder that belongs together (album, photo series, extracted archive ...).
    case inUnit
}

/// Coarse content category, used by rules and shown in the UI.
public enum FileKind: String, Codable, Sendable, CaseIterable, Hashable {
    case image, rawImage, video, audio, pdf, document, spreadsheet, presentation, text
    case archive, installer, diskImage, code, ebook, font, model3D, calendar, contact, torrent, other

    public var displayName: String {
        switch self {
        case .image: return "Bild"
        case .rawImage: return "RAW-Foto"
        case .video: return "Video"
        case .audio: return "Audio"
        case .pdf: return "PDF"
        case .document: return "Dokument"
        case .spreadsheet: return "Tabelle"
        case .presentation: return "Präsentation"
        case .text: return "Text"
        case .archive: return "Archiv"
        case .installer: return "Installer"
        case .diskImage: return "Disk-Image"
        case .code: return "Code"
        case .ebook: return "E-Book"
        case .font: return "Schrift"
        case .model3D: return "3D-Modell"
        case .calendar: return "Kalender"
        case .contact: return "Kontakt"
        case .torrent: return "Torrent"
        case .other: return "Sonstiges"
        }
    }

    private static let byExtension: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ exts: [String]) { for e in exts { map[e] = kind } }
        add(.image, ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "avif", "jxl", "ico", "psd", "afphoto", "pxd", "sketch", "fig", "xcf", "eps", "ai"])
        add(.rawImage, ["cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "dng", "srw", "pef"])
        add(.video, ["mov", "mp4", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg", "3gp", "mts", "m2ts"])
        add(.audio, ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "wma", "alac", "mid", "midi", "m4b"])
        add(.pdf, ["pdf"])
        add(.document, ["doc", "docx", "odt", "rtf", "rtfd", "pages", "wpd", "tex", "dotx"])
        add(.spreadsheet, ["xls", "xlsx", "xlsm", "ods", "numbers", "csv", "tsv"])
        add(.presentation, ["ppt", "pptx", "odp", "key"])
        add(.text, ["txt", "md", "markdown", "log", "nfo", "rst", "org"])
        add(.archive, ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "tbz", "lz", "sit", "sitx"])
        add(.installer, ["pkg", "mpkg"])
        add(.diskImage, ["dmg", "iso", "img", "sparseimage"])
        add(.code, ["swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "c", "h", "cpp", "hpp", "cc", "m", "mm", "rs", "go", "rb", "php", "sh", "zsh", "bash", "pl", "lua", "r", "jl", "scala", "cs", "sql", "html", "htm", "css", "scss", "json", "yaml", "yml", "toml", "xml", "ipynb", "ino"])
        add(.ebook, ["epub", "mobi", "azw", "azw3", "fb2", "djvu", "cbz", "cbr"])
        add(.font, ["ttf", "otf", "woff", "woff2", "ttc", "dfont"])
        add(.model3D, ["stl", "3mf", "obj", "gcode", "step", "stp", "f3d", "blend", "fbx", "usdz", "scad"])
        add(.calendar, ["ics", "vcs"])
        add(.contact, ["vcf"])
        add(.torrent, ["torrent"])
        return map
    }()

    public static func of(extension ext: String, typeIdentifier: String? = nil) -> FileKind {
        if let kind = byExtension[ext.lowercased()] { return kind }
        if let id = typeIdentifier, let type = UTType(id) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .archive) { return .archive }
            if type.conforms(to: .sourceCode) { return .code }
            if type.conforms(to: .plainText) { return .text }
        }
        return .other
    }

    /// Kinds that are plain enough to read a short text excerpt from.
    public var hasReadableText: Bool {
        switch self {
        case .pdf, .document, .spreadsheet, .presentation, .text, .code, .calendar, .contact: return true
        default: return false
        }
    }

    public var isMedia: Bool { self == .image || self == .rawImage || self == .video || self == .audio }
}

/// A single file (or a document package such as .pages that behaves like a file).
public struct FileItem: Sendable, Hashable, Identifiable, Codable {
    public var id: String { url.path }
    public let url: URL
    public let isPackage: Bool
    public let size: Int64
    public let created: Date?
    public let modified: Date?
    public let accessed: Date?
    public let addedToFolder: Date?
    public let typeIdentifier: String?
    public var context: FileContext
    public var whereFroms: [String]
    public var quarantineAgent: String?
    public var isScreenshot: Bool
    public var cameraModel: String?
    public var contentCreated: Date?
    public var lastUsed: Date?
    public var spotlightLoaded: Bool

    public init(url: URL, isPackage: Bool = false, size: Int64, created: Date? = nil, modified: Date? = nil,
                accessed: Date? = nil, addedToFolder: Date? = nil, typeIdentifier: String? = nil,
                context: FileContext = .loose, whereFroms: [String] = [], quarantineAgent: String? = nil,
                isScreenshot: Bool = false, cameraModel: String? = nil, contentCreated: Date? = nil,
                lastUsed: Date? = nil, spotlightLoaded: Bool = false) {
        self.url = url
        self.isPackage = isPackage
        self.size = size
        self.created = created
        self.modified = modified
        self.accessed = accessed
        self.addedToFolder = addedToFolder
        self.typeIdentifier = typeIdentifier
        self.context = context
        self.whereFroms = whereFroms
        self.quarantineAgent = quarantineAgent
        self.isScreenshot = isScreenshot
        self.cameraModel = cameraModel
        self.contentCreated = contentCreated
        self.lastUsed = lastUsed
        self.spotlightLoaded = spotlightLoaded
    }

    public var name: String { url.lastPathComponent }
    public var ext: String { FileNameTools.split(name).ext.lowercased() }
    public var baseName: String { FileNameTools.split(name).base }
    public var kind: FileKind { FileKind.of(extension: ext, typeIdentifier: typeIdentifier) }
    public var parent: URL { url.deletingLastPathComponent() }

    /// Best guess for "when is this file from": photo capture date, a date in the name
    /// ("Bildschirmfoto 2025-02-14 …", "PXL_20240101_…", "Rechnung 03.2024"), creation, modification.
    public var referenceDate: Date {
        dateFromName ?? contentCreated ?? created ?? modified ?? Date()
    }

    public var dateFromName: Date? { Self.parseDate(in: baseName) }

    private static let datePatterns: [(NSRegularExpression, [Int])] = [
        (#"(?<!\d)(20\d{2}|19\d{2})[-_.](\d{1,2})[-_.](\d{1,2})(?!\d)"#, [1, 2, 3]),
        (#"(?<!\d)(20\d{2})(\d{2})(\d{2})(?!\d)"#, [1, 2, 3]),
        (#"(?<!\d)(20\d{2})(\d{2})(\d{2})[_-]\d{6}"#, [1, 2, 3]),
        (#"(?<!\d)(\d{1,2})\.(\d{1,2})\.(20\d{2})(?!\d)"#, [3, 2, 1]),
        (#"(?<!\d)(\d{1,2})[-_.](20\d{2})(?!\d)"#, [2, 1, 0]),
    ].compactMap { pattern, order in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, order) }
    }

    static func parseDate(in text: String) -> Date? {
        let range = NSRange(text.startIndex..., in: text)
        for (re, order) in datePatterns {
            guard let m = re.firstMatch(in: text, range: range) else { continue }
            func part(_ i: Int) -> Int? {
                guard i > 0, let r = Range(m.range(at: i), in: text) else { return nil }
                return Int(text[r])
            }
            guard let year = part(order[0]), let month = part(order[1]), (1...12).contains(month) else { continue }
            let day = order[2] == 0 ? 1 : (part(order[2]) ?? 1)
            guard (1...31).contains(day), year <= Calendar.current.component(.year, from: Date()) + 1 else { continue }
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = day
            comps.hour = 12
            if let date = Calendar(identifier: .gregorian).date(from: comps) { return date }
        }
        return nil
    }

    /// Last time the user opened it (Spotlight), falling back to modification date.
    public var lastActivity: Date? {
        lastUsed ?? modified ?? created
    }

    public var sourceDomain: String? {
        for entry in whereFroms {
            if let host = URL(string: entry)?.host, !host.isEmpty {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
        }
        return nil
    }

    public var looksLikeCameraPhoto: Bool {
        guard kind == .image || kind == .rawImage || kind == .video else { return false }
        if cameraModel != nil { return true }
        return Self.cameraNamePattern?.firstMatch(in: baseName, range: NSRange(baseName.startIndex..., in: baseName)) != nil
    }

    private static let cameraNamePattern = try? NSRegularExpression(
        pattern: #"^(IMG|DSC|DSCN|DSCF|PXL|MVI|GOPR|GH\d\d|GX\d\d|DJI|P\d{7}|IMG-\d{8}-WA)[_-]?\d+"#,
        options: [.caseInsensitive])
}

/// Folder that can only be handled as a whole (moved, archived or trashed — never split).
public enum FolderKind: String, Codable, Sendable, Hashable {
    case photoSeries, musicAlbum, submission, extractedArchive, website, project, generic

    public var displayName: String {
        switch self {
        case .photoSeries: return "Fotoserie"
        case .musicAlbum: return "Musikalbum"
        case .submission: return "Projektabgabe"
        case .extractedArchive: return "Entpacktes Archiv"
        case .website: return "Website"
        case .project: return "Projektordner"
        case .generic: return "Ordner"
        }
    }
}

public struct FolderItem: Sendable, Hashable, Identifiable, Codable {
    public var id: String { url.path }
    public let url: URL
    public var kind: FolderKind
    public var size: Int64
    public var fileCount: Int
    public var modified: Date?
    public var sampleNames: [String]
    /// Set when the folder may never move (e.g. it contains a project).
    public var blockedReason: String?
    /// Movable, but only after a look (e.g. contains a project): never pre-selected.
    public var warning: String?

    public init(url: URL, kind: FolderKind, size: Int64 = 0, fileCount: Int = 0, modified: Date? = nil,
                sampleNames: [String] = [], blockedReason: String? = nil, warning: String? = nil) {
        self.warning = warning
        self.url = url
        self.kind = kind
        self.size = size
        self.fileCount = fileCount
        self.modified = modified
        self.sampleNames = sampleNames
        self.blockedReason = blockedReason
    }

    public var name: String { url.lastPathComponent }
}
