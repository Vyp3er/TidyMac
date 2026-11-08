import Foundation

public struct EntryInfo: Sendable, Hashable {
    public let name: String
    public let isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// Recognises folders whose content belongs together. Such folders are only ever moved
/// as a whole, never taken apart.
public enum CohesionDetector {
    static let archiveExtensions = ["zip", "rar", "7z", "tar", "tgz", "tar.gz", "tar.bz2", "tar.xz", "gz", "xz", "dmg", "sit"]

    static let submissionPattern = try? NSRegularExpression(
        pattern: #"(abgabe|submission|hausarbeit|seminararbeit|bachelorarbeit|masterarbeit|diplomarbeit|thesis|assignment|übung|uebung|blatt[ _-]?\d|praktikum|projektarbeit|hand[ -]?in|deliverable|portfolio|bewerbung|application)"#,
        options: [.caseInsensitive])

    public static func kind(folderName: String, entries: [EntryInfo], siblingNames: Set<String>) -> FolderKind? {
        let visible = entries.filter { !$0.name.hasPrefix(".") && $0.name != "Icon\r" }
        guard !visible.isEmpty else { return nil }

        // Extracted archive: "Foo.zip" lies next to "Foo/", or macOS archive metadata inside.
        let lowerSiblings = Set(siblingNames.map { $0.lowercased() })
        let lowerName = folderName.lowercased()
        if archiveExtensions.contains(where: { lowerSiblings.contains(lowerName + "." + $0) }) { return .extractedArchive }
        if visible.contains(where: { $0.name == "__MACOSX" }) { return .extractedArchive }

        let files = visible.filter { !$0.isDirectory }
        let dirNames = Set(visible.filter(\.isDirectory).map { $0.name.lowercased() })
        let kinds = files.map { FileKind.of(extension: FileNameTools.split($0.name).ext) }

        // Website with relative links.
        let htmlCount = files.filter { ["html", "htm", "xhtml"].contains(FileNameTools.split($0.name).ext.lowercased()) }.count
        let hasIndex = files.contains { ["index.html", "index.htm", "index.php"].contains($0.name.lowercased()) }
        let webDirs: Set<String> = ["css", "js", "scripts", "styles", "assets", "images", "img", "static", "fonts"]
        if hasIndex || htmlCount >= 2 || (htmlCount >= 1 && !dirNames.isDisjoint(with: webDirs)) { return .website }

        // Music album.
        let ignorable: Set<FileKind> = [.text, .image]
        let audio = kinds.filter { $0 == .audio }.count
        let relevant = max(1, kinds.filter { !ignorable.contains($0) }.count)
        if audio >= 3 && Double(audio) / Double(relevant) >= 0.6 { return .musicAlbum }

        // Photo series (images, RAWs, short clips).
        let media = kinds.filter { $0 == .image || $0 == .rawImage || $0 == .video }.count
        if media >= 5 && Double(media) / Double(max(1, files.count)) >= 0.8 { return .photoSeries }

        // Projektabgabe / Bewerbung etc. by name.
        if let re = submissionPattern,
           re.firstMatch(in: folderName, range: NSRange(folderName.startIndex..., in: folderName)) != nil {
            return .submission
        }
        return nil
    }

    /// Names in a folder listing that form a saved web page ("Foo.html" + "Foo_files").
    public static func savedWebPageNames(in names: [String]) -> Set<String> {
        let set = Set(names)
        var result = Set<String>()
        for name in names {
            let (base, ext) = FileNameTools.split(name)
            guard ["html", "htm", "xhtml"].contains(ext.lowercased()) else { continue }
            for suffix in ["_files", "-Dateien", "_Dateien", "-files", " Dateien"] where set.contains(base + suffix) {
                result.insert(name)
                result.insert(base + suffix)
            }
        }
        return result
    }
}
