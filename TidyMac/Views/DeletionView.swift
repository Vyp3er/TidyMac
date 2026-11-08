import SwiftUI
import TidyCore

/// "Löschen": very old files that are probably no longer needed. Every file has to be confirmed
/// on its own (there is deliberately no "select all"), and deleting always means the Trash.
struct DeletionView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Löschvorschläge").font(.headline)
                    Text("Dateien, die du seit \(ageText) weder geöffnet noch geändert hast. Claude schätzt ein, ob du sie noch brauchst. Jede Datei bestätigst du einzeln; gelöscht heißt: in den Papierkorb, rückgängig im Verlauf.")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3)
                    Picker("Bereich", selection: $model.scope) {
                        ForEach(ScanScope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 320)
                    .padding(.top, 4)
                }
                Spacer()
                Button {
                    model.findDeletionCandidates()
                } label: {
                    Label("Alte Dateien prüfen", systemImage: "sparkle.magnifyingglass")
                }
                .disabled(model.isWorking)
                Button(role: .destructive) {
                    confirm = true
                } label: {
                    Label(model.confirmedDeletions.isEmpty ? "Löschen …" : "\(model.confirmedDeletions.count) löschen …",
                          systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.confirmedDeletions.isEmpty || model.isWorking)
            }
            .padding(14)
            Divider()
            if let result = model.lastResult, model.lastResultTitle.hasPrefix("Gelöscht") {
                ResultBanner(result: result)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                Divider()
            }
            ZStack {
                if model.deletionSuggestions.isEmpty {
                    EmptyHint(symbol: "trash",
                              title: model.hasSearchedDeletion ? "Keine Löschvorschläge" : "Noch nicht geprüft",
                              text: model.hasSearchedDeletion
                                ? "Unter den alten Dateien ist nichts, was sicher weg kann."
                                : "„Alte Dateien prüfen“ sucht im gewählten Bereich. Projektordner, Fotoserien, Alben und geschützte Bereiche bleiben außen vor.")
                } else {
                    List {
                        ForEach(model.deletionSuggestions) { suggestion in
                            DeletionRow(suggestion: suggestion)
                        }
                    }
                    .listStyle(.inset)
                }
                if model.isWorking { WorkingOverlay() }
            }
            .frame(maxHeight: .infinity)
            if let report = model.deletionReport {
                Divider()
                DeletionFooter(report: report)
            }
        }
        .navigationTitle("Löschen")
        .confirmationDialog(confirmTitle, isPresented: $confirm) {
            Button("In den Papierkorb", role: .destructive) { model.deleteConfirmed() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var ageText: String {
        let days = model.settings.deletion.minAgeDays
        if days % 365 == 0 { return days == 365 ? "über einem Jahr" : "über \(days / 365) Jahren" }
        if days % 30 == 0 { return "über \(days / 30) Monaten" }
        return "über \(days) Tagen"
    }

    private var confirmTitle: String {
        let n = model.confirmedDeletions.count
        return "\(n) Datei\(n == 1 ? "" : "en") (\(model.confirmedDeletionBytes.bytesText)) in den Papierkorb legen?"
    }

    private var confirmMessage: String {
        let names = model.confirmedDeletions.prefix(6).map { "• " + $0.url.lastPathComponent }
        let more = model.confirmedDeletions.count > 6 ? "\n… und \(model.confirmedDeletions.count - 6) weitere" : ""
        return names.joined(separator: "\n") + more
            + "\n\nNichts wird endgültig gelöscht. Im Verlauf kannst du das rückgängig machen."
    }
}

struct DeletionRow: View {
    @Environment(AppModel.self) private var model
    let suggestion: DeletionSuggestion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Löschen", isOn: model.deletionConfirmBinding(suggestion.id))
                .toggleStyle(.checkbox)
                .help("Diese Datei zum Löschen (Papierkorb) bestätigen")
                .frame(width: 80, alignment: .leading)
            FileIcon(url: suggestion.url, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(suggestion.url.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    ConfidenceBadge(value: suggestion.confidence)
                    Text(suggestion.source.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background((suggestion.source == .ai ? Color.purple : Color.blue).opacity(0.15), in: Capsule())
                }
                Text(model.home.abbreviate(suggestion.url.deletingLastPathComponent()))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(suggestion.reason).font(.callout).lineLimit(3)
                Text(detailText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Button("Behalten") { model.keepDeletionSuggestion(suggestion.id) }
                    .help("Nicht löschen und nicht mehr vorschlagen, solange die Datei unverändert bleibt")
                HStack(spacing: 4) {
                    Button {
                        NSWorkspace.shared.open(suggestion.url)
                    } label: { Image(systemName: "eye") }
                    .help("Öffnen")
                    Button {
                        Finder.reveal(suggestion.url)
                    } label: { Image(systemName: "folder") }
                    .help("Im Finder zeigen")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Öffnen") { NSWorkspace.shared.open(suggestion.url) }
            Button("Im Finder zeigen") { Finder.reveal(suggestion.url) }
            Button("Behalten") { model.keepDeletionSuggestion(suggestion.id) }
        }
    }

    private var detailText: String {
        var parts = [suggestion.size.bytesText]
        let years = suggestion.daysUnused / 365
        parts.append(years >= 1 ? "seit über \(years) Jahr\(years == 1 ? "" : "en") unbenutzt" : "seit \(suggestion.daysUnused) Tagen unbenutzt")
        if let last = suggestion.lastActivity {
            parts.append("zuletzt " + last.formatted(.dateTime.day().month(.twoDigits).year()))
        }
        return parts.joined(separator: " · ")
    }
}

struct DeletionFooter: View {
    @Environment(AppModel.self) private var model
    let report: DeletionReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary).font(.caption)
            if report.aiUsed && !report.aiStats.provider.isEmpty {
                let s = report.aiStats
                Label("\(s.provider): \(s.filesSent) Dateien in \(s.batches) Anfragen, \(s.cacheHits) aus dem Cache · \(s.inputTokens + s.outputTokens) Tokens"
                      + (s.costUSD > 0 && model.settings.ai.provider == .anthropicAPI ? String(format: " · ca. %.3f $", s.costUSD) : ""),
                      systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(report.notes + report.aiStats.errors, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var summary: String {
        var parts = ["\(report.oldFiles) alte Datei\(report.oldFiles == 1 ? "" : "en") gefunden",
                     "\(report.suggestions.count) Vorschl\(report.suggestions.count == 1 ? "ag" : "äge")"]
        if report.keptByAI > 0 { parts.append("\(report.keptByAI) behält Claude") }
        if report.unsureByAI > 0 { parts.append("\(report.unsureByAI) unklar (bleiben)") }
        if report.keptByUser > 0 { parts.append("\(report.keptByUser) von dir behalten") }
        if report.notSent > 0 { parts.append("\(report.notSent) nicht an die KI (Datenschutz)") }
        if report.overLimit > 0 { parts.append("\(report.overLimit) über dem KI-Limit") }
        return parts.joined(separator: " · ")
    }
}
