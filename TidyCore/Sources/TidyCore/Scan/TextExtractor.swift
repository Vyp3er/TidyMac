import AppKit
import Foundation
import PDFKit

/// Reads a short text excerpt (default ~2,000 characters) from a document. Only this excerpt —
/// never the whole file — may be sent to the AI.
public enum TextExtractor {
    static let plainTextExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "toml", "log", "nfo", "rst", "org",
        "ics", "vcf", "tex", "bib", "swift", "py", "js", "ts", "java", "c", "h", "cpp", "rs", "go", "rb", "php", "sh",
        "sql", "css", "ini", "cfg", "conf", "srt", "vtt",
    ]
    static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]
    static let attributedExtensions: Set<String> = ["rtf", "doc", "docx", "odt", "wordml"]
    static let maxFileSize: Int64 = 60 * 1024 * 1024

    public static func excerpt(for item: FileItem, limit: Int) -> String? {
        guard limit > 0, item.size <= maxFileSize else { return nil }
        let ext = item.ext
        let raw: String?
        if ext == "pdf" {
            raw = pdfText(item.url, limit: limit)
        } else if plainTextExtensions.contains(ext) {
            raw = plainText(item.url, limit: limit)
        } else if htmlExtensions.contains(ext) {
            raw = plainText(item.url, limit: limit * 6).map(stripTags)
        } else if attributedExtensions.contains(ext) {
            raw = attributedText(item.url)
        } else if ext == "xlsx" {
            raw = zipEntryText(item.url, entry: "xl/sharedStrings.xml")
        } else if ext == "pptx" {
            raw = zipEntryText(item.url, entry: "ppt/slides/slide1.xml")
        } else {
            raw = nil
        }
        guard let text = raw.map({ clean($0, limit: limit) }), !text.isEmpty else { return nil }
        return text
    }

    static func clean(_ text: String, limit: Int) -> String {
        let collapsed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(limit))
    }

    static func plainText(_ url: URL, limit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: max(4096, limit * 4)) else { return nil }
        if data.contains(0) { return nil } // binary
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    static func pdfText(_ url: URL, limit: Int) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        if doc.isLocked { return nil }
        var text = ""
        for index in 0..<min(doc.pageCount, 6) {
            if let page = doc.page(at: index), let s = page.string { text += s + "\n" }
            if text.count >= limit { break }
        }
        return text
    }

    static func attributedText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let ext = url.pathExtension.lowercased()
        let type: NSAttributedString.DocumentType
        switch ext {
        case "rtf": type = .rtf
        case "doc": type = .docFormat
        case "docx": type = .officeOpenXML
        case "odt": type = .openDocument
        default: type = .wordML
        }
        let attributed = try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil)
        return attributed?.string
    }

    static func zipEntryText(_ url: URL, entry: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let xml = String(data: data.prefix(200_000), encoding: .utf8) else { return nil }
        return stripTags(xml)
    }

    static func stripTags(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<(script|style)[^>]*>[\s\S]*?</\1>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s
    }
}
