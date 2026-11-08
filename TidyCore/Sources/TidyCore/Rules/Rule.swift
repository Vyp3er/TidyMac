import Foundation

public enum RuleField: String, Codable, CaseIterable, Sendable, Hashable {
    case name, fileExtension, kind, sourceDomain, path, isScreenshot, isCameraPhoto, ageDays, sizeMB

    public var displayName: String {
        switch self {
        case .name: return "Dateiname"
        case .fileExtension: return "Dateiendung"
        case .kind: return "Dateiart"
        case .sourceDomain: return "Herkunft (Domain)"
        case .path: return "Pfad"
        case .isScreenshot: return "Ist Bildschirmfoto"
        case .isCameraPhoto: return "Ist Kamerafoto"
        case .ageDays: return "Alter (Tage)"
        case .sizeMB: return "Größe (MB)"
        }
    }

    public var isBoolean: Bool { self == .isScreenshot || self == .isCameraPhoto }
    public var isNumeric: Bool { self == .ageDays || self == .sizeMB }
}

public enum RuleOperator: String, Codable, CaseIterable, Sendable, Hashable {
    case contains, notContains, equals, startsWith, endsWith, matchesRegex, isOneOf, greaterThan, lessThan, isTrue, isFalse

    public var displayName: String {
        switch self {
        case .contains: return "enthält"
        case .notContains: return "enthält nicht"
        case .equals: return "ist"
        case .startsWith: return "beginnt mit"
        case .endsWith: return "endet mit"
        case .matchesRegex: return "passt auf Regex"
        case .isOneOf: return "ist eines von (Komma)"
        case .greaterThan: return "größer als"
        case .lessThan: return "kleiner als"
        case .isTrue: return "ja"
        case .isFalse: return "nein"
        }
    }
}

public struct RuleCondition: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var field: RuleField
    public var op: RuleOperator
    public var value: String

    public init(id: UUID = UUID(), _ field: RuleField, _ op: RuleOperator, _ value: String = "") {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
    }

    enum CodingKeys: String, CodingKey { case id, field, op, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        field = c.value(.field, .name)
        op = c.value(.op, .contains)
        value = c.value(.value, "")
    }

    public func matches(_ item: FileItem, home: HomeContext, now: Date = Date()) -> Bool {
        switch field {
        case .isScreenshot:
            return op == .isFalse ? !item.isScreenshot : item.isScreenshot
        case .isCameraPhoto:
            return op == .isFalse ? !item.looksLikeCameraPhoto : item.looksLikeCameraPhoto
        case .ageDays:
            let days = now.timeIntervalSince(item.referenceDate) / 86_400
            return compareNumber(days)
        case .sizeMB:
            return compareNumber(Double(item.size) / 1_048_576)
        case .name:
            return compareText(item.name)
        case .fileExtension:
            return compareText(item.ext)
        case .kind:
            return compareText(item.kind.rawValue) || compareText(item.kind.displayName)
        case .sourceDomain:
            return compareText(item.sourceDomain ?? "")
        case .path:
            return compareText(home.abbreviate(item.url))
        }
    }

    private func compareNumber(_ number: Double) -> Bool {
        guard let limit = Double(value.replacingOccurrences(of: ",", with: ".")) else { return false }
        switch op {
        case .greaterThan: return number > limit
        case .lessThan: return number < limit
        case .equals: return abs(number - limit) < 0.5
        default: return false
        }
    }

    private func compareText(_ text: String) -> Bool {
        let t = text.lowercased()
        let v = value.lowercased().trimmingCharacters(in: .whitespaces)
        switch op {
        case .contains: return !v.isEmpty && t.contains(v)
        case .notContains: return v.isEmpty || !t.contains(v)
        case .equals: return t == v
        case .startsWith: return !v.isEmpty && t.hasPrefix(v)
        case .endsWith: return !v.isEmpty && t.hasSuffix(v)
        case .isOneOf:
            let options = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            return options.contains(t)
        case .matchesRegex:
            guard let re = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else { return false }
            return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        case .greaterThan, .lessThan, .isTrue, .isFalse:
            return false
        }
    }
}

/// A sorting rule: all conditions must match. The destination is a template such as
/// "~/Documents/Finanzen/Rechnungen/{year}".
public struct SortRule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var isEnabled: Bool
    public var conditions: [RuleCondition]
    public var destination: String
    /// Optional rename template ("" = keep name), e.g. "{date} Rechnung {name}".
    public var renameTemplate: String
    public var confidence: Double
    public var isBuiltIn: Bool

    public init(id: String = UUID().uuidString, name: String, isEnabled: Bool = true, conditions: [RuleCondition],
                destination: String, renameTemplate: String = "", confidence: Double = 0.95, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.conditions = conditions
        self.destination = destination
        self.renameTemplate = renameTemplate
        self.confidence = confidence
        self.isBuiltIn = isBuiltIn
    }

    enum CodingKeys: String, CodingKey { case id, name, isEnabled, conditions, destination, renameTemplate, confidence, isBuiltIn }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID().uuidString)
        name = c.value(.name, "Regel")
        isEnabled = c.value(.isEnabled, true)
        conditions = c.value(.conditions, [])
        destination = c.value(.destination, "")
        renameTemplate = c.value(.renameTemplate, "")
        confidence = c.value(.confidence, 0.95)
        isBuiltIn = c.value(.isBuiltIn, false)
    }

    public func matches(_ item: FileItem, home: HomeContext, now: Date = Date()) -> Bool {
        isEnabled && !conditions.isEmpty && !destination.isEmpty && conditions.allSatisfy { $0.matches(item, home: home, now: now) }
    }
}

/// Replaces {tokens} in rule destinations and rename schemes.
public enum TemplateRenderer {
    public static func render(_ template: String, item: FileItem, extra: [String: String] = [:]) -> String {
        let date = item.referenceDate
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone.current, from: date)
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        let year = String(comps.year ?? 1970)
        var tokens: [String: String] = [
            "year": year,
            "month": two(comps.month),
            "day": two(comps.day),
            "date": "\(year)-\(two(comps.month))-\(two(comps.day))",
            "yearMonth": "\(year)-\(two(comps.month))",
            "time": "\(two(comps.hour)).\(two(comps.minute)).\(two(comps.second))",
            "ext": item.ext,
            "name": item.baseName,
            "original": item.baseName,
            "kind": item.kind.displayName,
            "domain": item.sourceDomain ?? "Unbekannt",
        ]
        for (k, v) in extra { tokens[k] = v }
        var result = template
        for (key, value) in tokens {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }
}
