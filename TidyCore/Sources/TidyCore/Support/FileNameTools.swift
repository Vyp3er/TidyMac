import Foundation

public enum Glob {
    /// Shell-style pattern match (`*`, `?`, `[...]`), case-insensitive.
    public static func matches(_ pattern: String, _ string: String) -> Bool {
        fnmatch(pattern.lowercased(), string.lowercased(), 0) == 0
    }

    /// Matches a pattern against the file name, and — if the pattern contains "/" —
    /// against the "~/..." path as well.
    public static func matches(_ pattern: String, name: String, displayPath: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return false }
        if p.contains("/") { return matches(p, displayPath) || matches(p + "/*", displayPath) }
        return matches(p, name)
    }
}

public enum FileNameTools {
    static let copySuffix = try? NSRegularExpression(
        pattern: #"(\s\(\d+\)|\s(kopie|copy)(\s\d+)?|\s-\s(kopie|copy)|\s\d{1,2})$"#,
        options: [.caseInsensitive])

    /// Splits "name.ext" into ("name", "ext"). Dot-files and names without extension keep ext "".
    public static func split(_ fileName: String) -> (base: String, ext: String) {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else {
            return (fileName, "")
        }
        let ext = String(fileName[fileName.index(after: dot)...])
        // "Version 1.2 final" is not an extension; real extensions are short and have no spaces.
        guard !ext.isEmpty, ext.count <= 24, !ext.contains(" ") else { return (fileName, "") }
        return (String(fileName[..<dot]), ext)
    }

    public static func join(_ base: String, _ ext: String) -> String {
        ext.isEmpty ? base : base + "." + ext
    }

    public static func hasCopySuffix(_ base: String) -> Bool {
        guard let re = copySuffix else { return false }
        return re.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) != nil
    }

    /// "Rechnung (1)" → "Rechnung", "Foto Kopie 2" → "Foto".
    public static func removingCopySuffix(_ base: String) -> String {
        guard let re = copySuffix else { return base }
        return re.stringByReplacingMatches(in: base, range: NSRange(base.startIndex..., in: base), withTemplate: "")
    }

    /// Makes a string safe as macOS file name: no "/" or ":", no control characters,
    /// no leading dots, collapsed whitespace, max. 150 characters.
    public static func sanitize(_ raw: String, maxLength: Int = 150) -> String {
        var s = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines))
        if s.count > maxLength {
            s = String(s.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// Finder-style unique name inside `folder`: "Name.ext", "Name 2.ext", "Name 3.ext" ...
    /// `reserved` holds names already claimed by other planned actions.
    public static func uniqueName(for name: String, in folder: URL, reserved: Set<String> = []) -> String {
        let lowerReserved = Set(reserved.map { $0.lowercased() })
        func taken(_ candidate: String) -> Bool {
            lowerReserved.contains(candidate.lowercased()) || PathUtil.exists(folder.appendingPathComponent(candidate))
        }
        if !taken(name) { return name }
        let (base, ext) = split(name)
        var n = 2
        while n < 10_000 {
            let candidate = join("\(base) \(n)", ext)
            if !taken(candidate) { return candidate }
            n += 1
        }
        return join("\(base) \(UUID().uuidString.prefix(8))", ext)
    }
}

/// Recognises names that say nothing about the content ("IMG_4831", "Scan_0012", "Dokument (3)").
public enum NameAnalyzer {
    private static let patterns: [NSRegularExpression] = [
        // Camera and phone names
        #"^(img|dsc|dscn|dscf|dcim|pxl|mvi|vid|mov|gopr|gh\d{2}|gx\d{2}|dji|wp|pict|sam|cimg|imag|photo|p\d{3,})[_ -]?\d{2,}([_ -]\d+)*([_ -]?(edited|bearbeitet|hdr|portrait|burst\w*|mp))?$"#,
        // Scanner / generic document names
        #"^(scan|scanned|scanner|scan_?doc|img|image|bild|foto|photo|picture|pic|document|dokument|doc|untitled|unbenannt|ohne titel|neues dokument|new document|neue datei|new file|file|datei|download|downloads|attachment|anhang|export|output|print|druck|test|tmp|temp|neu|new)([ _-]*(\(\d+\)|\d+|kopie|copy))*$"#,
        // Pure numbers, dates with numbers only, separators
        #"^[\d _.\-()]+$"#,
        // UUIDs and long random IDs
        #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
        #"^(?=.*\d)(?=.*[a-z])[a-z0-9]{20,}$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    public static func isMeaningless(_ fileName: String) -> Bool {
        let base = FileNameTools.split(fileName).base.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return true }
        let range = NSRange(base.startIndex..., in: base)
        return patterns.contains { $0.firstMatch(in: base, range: range) != nil }
    }
}
