import Foundation

public enum BuiltInRules {
    private static func c(_ field: RuleField, _ op: RuleOperator, _ value: String = "") -> RuleCondition {
        RuleCondition(field, op, value)
    }

    /// Built-in rules for unambiguous cases. Order matters: the first match wins.
    public static let all: [SortRule] = [
        SortRule(id: "builtin.screenshots", name: "Bildschirmfotos",
                 conditions: [c(.isScreenshot, .isTrue)],
                 destination: "{screenshots}/{year}", confidence: 0.96, isBuiltIn: true),
        SortRule(id: "builtin.screenshot-names", name: "Bildschirmfotos (Name)",
                 conditions: [c(.kind, .equals, "image"), c(.name, .matchesRegex, #"^(Bildschirmfoto|Screenshot|Screen Shot|CleanShot) \d{4}-\d{2}-\d{2}"#)],
                 destination: "{screenshots}/{year}", confidence: 0.95, isBuiltIn: true),
        SortRule(id: "builtin.screen-recordings", name: "Bildschirmaufnahmen",
                 conditions: [c(.kind, .equals, "video"), c(.name, .matchesRegex, #"^(Bildschirmaufnahme|Screen Recording|Bildschirmaufzeichnung)"#)],
                 destination: "~/Movies/Bildschirmaufnahmen/{year}", confidence: 0.95, isBuiltIn: true),
        SortRule(id: "builtin.installers", name: "Installer",
                 conditions: [c(.fileExtension, .isOneOf, "dmg, pkg, mpkg")],
                 destination: "~/Downloads/Installer", confidence: 0.95, isBuiltIn: true),
        SortRule(id: "builtin.invoices", name: "Rechnungen",
                 conditions: [c(.kind, .isOneOf, "pdf, document, image"), c(.name, .matchesRegex, #"(rechnung|invoice|quittung|receipt|kassenbon|zahlungsbeleg|faktura)"#)],
                 destination: "~/Documents/Finanzen/Rechnungen/{year}", confidence: 0.92, isBuiltIn: true),
        SortRule(id: "builtin.statements", name: "Kontoauszüge",
                 conditions: [c(.kind, .isOneOf, "pdf, spreadsheet"), c(.name, .matchesRegex, #"(kontoauszug|kontoauszuege|account.?statement|bank.?statement|depotauszug|kreditkartenabrechnung)"#)],
                 destination: "~/Documents/Finanzen/Kontoauszüge/{year}", confidence: 0.92, isBuiltIn: true),
        SortRule(id: "builtin.payslips", name: "Gehaltsabrechnungen",
                 conditions: [c(.kind, .equals, "pdf"), c(.name, .matchesRegex, #"(lohnabrechnung|gehaltsabrechnung|entgeltabrechnung|payslip|pay.?stub|verdienstabrechnung)"#)],
                 destination: "~/Documents/Finanzen/Gehalt/{year}", confidence: 0.92, isBuiltIn: true),
        SortRule(id: "builtin.ebooks", name: "E-Books",
                 conditions: [c(.kind, .equals, "ebook")],
                 destination: "~/Documents/Bücher", confidence: 0.9, isBuiltIn: true),
        SortRule(id: "builtin.fonts", name: "Schriften",
                 conditions: [c(.kind, .equals, "font")],
                 destination: "~/Documents/Schriften", confidence: 0.88, isBuiltIn: true),
        SortRule(id: "builtin.camera", name: "Kamerafotos",
                 conditions: [c(.isCameraPhoto, .isTrue)],
                 destination: "~/Pictures/Fotos/{year}", confidence: 0.88, isBuiltIn: true),
        SortRule(id: "builtin.3d", name: "3D-Modelle",
                 conditions: [c(.kind, .equals, "model3D")],
                 destination: "~/Documents/3D-Modelle", confidence: 0.85, isBuiltIn: true),
        SortRule(id: "builtin.images", name: "Bilder",
                 conditions: [c(.kind, .isOneOf, "image, rawImage")],
                 destination: "~/Pictures/Bilder", confidence: 0.7, isBuiltIn: true),
        SortRule(id: "builtin.videos", name: "Videos",
                 conditions: [c(.kind, .equals, "video")],
                 destination: "~/Movies/{year}", confidence: 0.72, isBuiltIn: true),
        SortRule(id: "builtin.audio", name: "Audio",
                 conditions: [c(.kind, .equals, "audio")],
                 destination: "~/Music/Audio", confidence: 0.72, isBuiltIn: true),
        SortRule(id: "builtin.archives", name: "Archive",
                 conditions: [c(.kind, .equals, "archive")],
                 destination: "~/Downloads/Archive", confidence: 0.6, isBuiltIn: true),
        SortRule(id: "builtin.code", name: "Code-Schnipsel",
                 conditions: [c(.kind, .equals, "code")],
                 destination: "~/Documents/Code-Schnipsel", confidence: 0.6, isBuiltIn: true),
    ]
}

public struct RuleMatch: Sendable, Hashable {
    public let rule: SortRule
    public let destinationFolder: URL
    public let newName: String?
    public let confidence: Double
    public let isUserRule: Bool
}

/// Applies user rules first, then the built-in rules. Destinations are mapped onto the
/// user's existing folders where possible (e.g. "Screenshots" instead of a new "Bildschirmfotos").
public struct RuleEngine: Sendable {
    public let home: HomeContext
    public let rules: [SortRule]
    public let resolver: DestinationResolver

    public init(home: HomeContext, settings: RuleSettings, resolver: DestinationResolver) {
        self.home = home
        let disabled = Set(settings.disabledBuiltInRules)
        let builtIns = BuiltInRules.all.map { rule -> SortRule in
            var r = rule
            r.isEnabled = !disabled.contains(rule.id)
            return r
        }
        self.rules = settings.userRules.map { var r = $0; r.isBuiltIn = false; return r } + builtIns
        self.resolver = resolver
    }

    public func match(_ item: FileItem, now: Date = Date()) -> RuleMatch? {
        for rule in rules where rule.matches(item, home: home, now: now) {
            let rendered = TemplateRenderer.render(rule.destination, item: item,
                                                   extra: ["screenshots": resolver.screenshotFolderTemplate])
            let folder = resolver.resolve(home.expand(rendered))
            var newName: String?
            if !rule.renameTemplate.isEmpty {
                let base = FileNameTools.sanitize(TemplateRenderer.render(rule.renameTemplate, item: item))
                if !base.isEmpty { newName = FileNameTools.join(base, item.ext.isEmpty ? "" : FileNameTools.split(item.name).ext) }
            }
            return RuleMatch(rule: rule, destinationFolder: folder, newName: newName,
                             confidence: max(0, min(1, rule.confidence)), isUserRule: !rule.isBuiltIn)
        }
        return nil
    }
}

/// Maps planned destination paths onto existing folders with equivalent names.
public struct DestinationResolver: Sendable {
    public let home: HomeContext
    /// Template for the screenshot folder ("~/Pictures/Bildschirmfotos" unless the user
    /// configured another screenshot location or already has a "Screenshots" folder).
    public let screenshotFolderTemplate: String

    static let synonymGroups: [[String]] = [
        ["Bildschirmfotos", "Screenshots", "Screen Shots", "Bildschirmfoto", "Bildschirmaufnahmen-Fotos"],
        ["Bildschirmaufnahmen", "Screen Recordings", "Bildschirmvideos"],
        ["Rechnungen", "Invoices", "Belege", "Quittungen", "Receipts"],
        ["Finanzen", "Finances", "Finance", "Finanzielles", "Geld", "Banking"],
        ["Kontoauszüge", "Kontoauszuege", "Bank", "Statements", "Bankauszüge"],
        ["Gehalt", "Lohn", "Gehaltsabrechnungen", "Lohnabrechnungen", "Payslips"],
        ["Installer", "Installers", "Installationsdateien", "Setup"],
        ["Fotos", "Photos", "Kamera", "Camera"],
        ["Bilder", "Images", "Grafiken", "Graphics"],
        ["Bücher", "Buecher", "Books", "E-Books", "eBooks", "Ebooks"],
        ["Schriften", "Fonts", "Schriftarten"],
        ["Archive", "Archiv", "Archives", "Zips"],
        ["3D-Modelle", "3D", "3D Models", "3D-Druck"],
        ["Code-Schnipsel", "Snippets", "Code"],
        ["Audio", "Audiodateien", "Sounds"],
        ["Videos", "Filme", "Movies", "Video"],
        ["Unterlagen", "Dokumente", "PDFs"],
        ["Tabellen", "Spreadsheets", "Excel"],
        ["Präsentationen", "Praesentationen", "Presentations", "Folien", "Slides"],
        ["Sonstiges", "Diverses", "Misc", "Other", "Andere"],
    ]

    public init(home: HomeContext, screenshotLocation: URL? = nil) {
        self.home = home
        if let loc = screenshotLocation, !PathUtil.isSame(loc, home.desktop), home.contains(loc) {
            screenshotFolderTemplate = home.abbreviate(loc)
        } else {
            screenshotFolderTemplate = "~/Pictures/Bildschirmfotos"
        }
    }

    /// Reads the user's screenshot location (`defaults read com.apple.screencapture location`).
    public static func systemScreenshotLocation(home: HomeContext) -> URL? {
        let plist = home.library.appendingPathComponent("Preferences/com.apple.screencapture.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let location = dict["location"] as? String, !location.isEmpty else { return nil }
        return home.expand((location as NSString).expandingTildeInPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Walks the path from home downwards; for each component that does not exist yet, an
    /// existing sibling with an equivalent name is used instead.
    public func resolve(_ url: URL) -> URL {
        guard let rel = PathUtil.relativePath(of: url, to: home.home), !rel.isEmpty else { return url }
        var current = home.home
        for component in rel.split(separator: "/").map(String.init) {
            let direct = current.appendingPathComponent(component, isDirectory: true)
            if PathUtil.isDirectory(direct) { current = direct; continue }
            if let existing = equivalent(of: component, in: current) {
                current = existing
            } else {
                current = direct
            }
        }
        return current
    }

    private func equivalent(of name: String, in folder: URL) -> URL? {
        guard PathUtil.isDirectory(folder),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let wanted = Self.normalize(name)
        let candidates = Self.synonymGroups.first { group in group.contains { Self.normalize($0) == wanted } }
            .map { $0.map(Self.normalize) } ?? [wanted]
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let url = folder.appendingPathComponent(entry, isDirectory: true)
            guard PathUtil.isDirectory(url), !PathUtil.isSymlink(url) else { continue }
            if candidates.contains(Self.normalize(entry)) { return url }
        }
        return nil
    }
}
