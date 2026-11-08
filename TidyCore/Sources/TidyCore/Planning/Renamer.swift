import Foundation

/// Proposes consistent names for files with meaningless names, following a scheme such as
/// "{date} {description}". Files with a sensible name are never renamed.
public struct Renamer: Sendable {
    public let scheme: String
    public let mediaWithDate: Bool

    public init(scheme: String, mediaWithDate: Bool) {
        let trimmed = scheme.trimmingCharacters(in: .whitespaces)
        self.scheme = trimmed.isEmpty ? "{date} {description}" : trimmed
        self.mediaWithDate = mediaWithDate
    }

    public func needsName(_ item: FileItem) -> Bool {
        NameAnalyzer.isMeaningless(item.name)
    }

    /// New file name, or nil if the file keeps its name.
    public func proposal(for item: FileItem, description: String?) -> String? {
        guard needsName(item) else { return nil }
        let desc = FileNameTools.sanitize(description ?? "", maxLength: 80)
        let template: String
        if !desc.isEmpty {
            template = scheme
        } else if item.kind.isMedia && mediaWithDate {
            template = "{date} {original}"
        } else {
            return nil
        }
        var base = TemplateRenderer.render(template, item: item, extra: ["description": desc])
        base = FileNameTools.sanitize(base)
        guard !base.isEmpty else { return nil }
        let originalExt = FileNameTools.split(item.name).ext
        let name = FileNameTools.join(base, originalExt)
        return name == item.name ? nil : name
    }
}
