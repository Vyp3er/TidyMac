import SwiftUI
import TidyCore

// MARK: - Duplicates

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identische Dateien finden").font(.headline)
                    Text("Vergleich über Größe → Teil-Hash → vollständigen SHA-256. Projektordner, Pakete und geschützte Bereiche werden ignoriert. Ziel: \(model.scope.title).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.findDuplicates()
                } label: {
                    Label("Duplikate suchen", systemImage: "magnifyingglass")
                }
                .disabled(model.isWorking)
                Button {
                    confirm = true
                } label: {
                    Label("\(model.duplicateActions.count) in den Papierkorb …", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.duplicateActions.isEmpty || model.isWorking)
            }
            .padding(14)
            Divider()
            ZStack {
                if model.duplicateGroups.isEmpty {
                    EmptyHint(symbol: "doc.on.doc", title: model.hasSearchedDuplicates ? "Keine Duplikate gefunden" : "Noch nicht gesucht",
                              text: "Das Exemplar im sinnvollsten Ordner mit dem besten Namen bleibt; die anderen gehen nach deiner Bestätigung in den Papierkorb.")
                } else {
                    List {
                        let total = model.duplicateGroups.reduce(Int64(0)) { $0 + $1.wastedBytes }
                        Text("\(model.duplicateGroups.count) \(model.duplicateGroups.count == 1 ? "Gruppe" : "Gruppen") · \(total.bytesText) durch Kopien belegt").foregroundStyle(.secondary)
                        ForEach(model.duplicateGroups) { group in
                            Section {
                                ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                                    DuplicateRow(group: group, index: index, file: file)
                                }
                            } header: {
                                Text("\(group.size.bytesText) × \(group.files.count) – behalten: \(group.keeper.name)  (\(group.keeperReason))")
                            }
                        }
                    }
                    .listStyle(.inset)
                }
                if model.isWorking { WorkingOverlay() }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle("Duplikate")
        .confirmationDialog("\(model.duplicateActions.count) Kopien in den Papierkorb legen?", isPresented: $confirm) {
            Button("In den Papierkorb") { model.trashDuplicates() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Dateien landen im Papierkorb (nicht endgültig gelöscht) und können im Verlauf zurückgeholt werden.")
        }
    }
}

struct DuplicateRow: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup
    let index: Int
    let file: FileItem

    var body: some View {
        let isKeeper = index == group.keeperIndex
        HStack(spacing: 10) {
            Button {
                model.setKeeper(groupID: group.id, index: index)
            } label: {
                Image(systemName: isKeeper ? "largecircle.fill.circle" : "circle")
            }
            .buttonStyle(.plain)
            .help("Dieses Exemplar behalten")
            FileIcon(url: file.url, size: 20)
            VStack(alignment: .leading) {
                Text(file.name)
                Text(model.home.abbreviate(file.parent)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let date = file.created {
                Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            if isKeeper {
                Text("bleibt").font(.caption.bold()).foregroundStyle(.green)
            } else if file.context == .inUnit {
                Text("gehört zu einem Ordner – bleibt").font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Papierkorb", isOn: Binding(
                    get: { model.duplicateSelection.contains(file.url.path) },
                    set: { if $0 { model.duplicateSelection.insert(file.url.path) } else { model.duplicateSelection.remove(file.url.path) } }))
                    .toggleStyle(.checkbox)
            }
            Button {
                Finder.reveal(file.url)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Clean-up suggestions

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aufräum-Vorschläge").font(.headline)
                    Text("Große, alte oder lange nicht geöffnete Dateien, alte Installer, leere Ordner, Reste. Nichts passiert automatisch – du entscheidest pro Eintrag.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.findCleanup()
                } label: {
                    Label("Vorschläge erstellen", systemImage: "sparkle.magnifyingglass")
                }
                .disabled(model.isWorking)
                Button {
                    confirm = true
                } label: {
                    Label("\(model.cleanupActions.count) umsetzen …", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.cleanupActions.isEmpty || model.isWorking)
            }
            .padding(14)
            Divider()
            ZStack {
                if model.cleanupSuggestions.isEmpty {
                    EmptyHint(symbol: "trash.slash", title: model.hasSearchedCleanup ? "Keine Vorschläge" : "Noch keine Vorschläge",
                              text: "Archivieren packt ein ZIP nach \(model.settings.cleanup.archiveFolder) und legt das Original in den Papierkorb.")
                } else {
                    Table(model.cleanupSuggestions) {
                        TableColumn("Datei") { s in
                            HStack {
                                FileIcon(url: s.url, size: 16)
                                VStack(alignment: .leading) {
                                    Text(s.url.lastPathComponent)
                                    Text(model.home.abbreviate(s.url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .contextMenu { Button("Im Finder zeigen") { Finder.reveal(s.url) } }
                        }
                        .width(min: 240, ideal: 340)
                        TableColumn("Kategorie") { s in
                            VStack(alignment: .leading) {
                                Text(s.category.displayName)
                                Text(s.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .width(min: 160, ideal: 220)
                        TableColumn("Größe") { s in Text(s.size.bytesText).monospacedDigit() }
                            .width(80)
                        TableColumn("Letzter Zugriff") { s in
                            if let d = s.lastUsed { Text(d, format: .dateTime.day().month(.twoDigits).year()) } else { Text("–") }
                        }
                        .width(110)
                        TableColumn("Aktion") { s in
                            Picker("", selection: model.cleanupChoiceBinding(s.id)) {
                                Text(CleanupChoice.keep.displayName).tag(CleanupChoice.keep)
                                Text(CleanupChoice.trash.displayName).tag(CleanupChoice.trash)
                                if s.allowsArchive { Text(CleanupChoice.archive.displayName).tag(CleanupChoice.archive) }
                            }
                            .labelsHidden()
                        }
                        .width(140)
                    }
                }
                if model.isWorking { WorkingOverlay() }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle("Aufräum-Vorschläge")
        .confirmationDialog("\(model.cleanupActions.count) Vorschläge umsetzen?", isPresented: $confirm) {
            Button("Umsetzen") { model.executeCleanup() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Papierkorb heißt Papierkorb – nichts wird endgültig gelöscht. Alles lässt sich im Verlauf rückgängig machen.")
        }
    }
}

// MARK: - Review queue

struct ReviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.reviewItems.isEmpty {
                EmptyHint(symbol: "tray", title: "Nichts zu prüfen",
                          text: "Hier landen neue Dateien aus dem Hintergrund-Modus, die nicht sicher genug für eine automatische Einsortierung waren.")
            } else {
                List(model.reviewItems) { item in
                    let url = URL(fileURLWithPath: item.path)
                    HStack(spacing: 10) {
                        FileIcon(url: url, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).fontWeight(.medium)
                            Text(model.home.abbreviate(url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary)
                            if let folder = item.suggestedFolder {
                                Label("Vorschlag: \(folder)" + (item.suggestedName.map { " als „\($0)“" } ?? ""), systemImage: "arrow.turn.down.right")
                                    .font(.callout)
                            }
                            Text(item.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.confidence > 0 { ConfidenceBadge(value: item.confidence) }
                        Button("Übernehmen") { model.acceptReview(item) }
                            .disabled(item.suggestedFolder == nil && item.suggestedName == nil)
                        Button("Ziel wählen …") {
                            if let folder = Finder.chooseFolders(multiple: false, start: model.home.documents, prompt: "Hierhin").first {
                                model.acceptReview(item, folder: folder)
                            }
                        }
                        Button("Ignorieren") { model.dismissReview(item) }
                        Button {
                            Finder.reveal(url)
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Zur Prüfung")
        .toolbar {
            Button {
                model.refreshReview()
            } label: {
                Label("Aktualisieren", systemImage: "arrow.clockwise")
            }
        }
        .onAppear { model.refreshReview() }
    }
}

// MARK: - Protected

struct ProtectedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let scan = model.scanResult, !scan.protected.isEmpty {
                let groups = Dictionary(grouping: scan.protected, by: { $0.reason.category })
                List {
                    Text("Diese Einträge wurden beim letzten Scan erkannt und werden weder verschoben noch verändert.")
                        .foregroundStyle(.secondary)
                    ForEach(groups.keys.sorted(), id: \.self) { key in
                        Section("\(key) (\(groups[key]?.count ?? 0))") {
                            ForEach(groups[key] ?? []) { entry in
                                HStack {
                                    Image(systemName: entry.isDirectory ? "folder.badge.minus" : "lock.doc")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading) {
                                        Text(model.home.abbreviate(entry.url))
                                        Text(entry.reason.description).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button {
                                        Finder.reveal(entry.url)
                                    } label: {
                                        Image(systemName: "magnifyingglass")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                EmptyHint(symbol: "lock.shield", title: "Noch kein Scan",
                          text: "Nach einem Scan siehst du hier alle erkannten Projektordner, Tabu-Bereiche, Cloud-Ordner, Links und App-Daten.")
            }
        }
        .navigationTitle("Geschützt")
    }
}

// MARK: - History

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedRun: String?
    @State private var confirmUndo: RunRecord?

    var body: some View {
        HSplitView {
            List(model.runs, selection: $selectedRun) { run in
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title).fontWeight(.medium).lineLimit(1)
                    HStack {
                        Text(run.started, format: .dateTime.day().month().year().hour().minute())
                        Text("· \(run.done) erledigt" + (run.undone > 0 ? ", \(run.undone) rückgängig" : ""))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if run.source == "background" {
                        Text("Hintergrund").font(.caption2).foregroundStyle(.purple)
                    }
                }
                .tag(run.id)
            }
            .frame(minWidth: 260, idealWidth: 300)

            if let id = selectedRun, let run = model.runs.first(where: { $0.id == id }) {
                RunDetail(run: run) { confirmUndo = run }
            } else {
                EmptyHint(symbol: "clock.arrow.circlepath", title: "Verlauf",
                          text: "Wähle einen Lauf, um einzelne Aktionen oder den ganzen Lauf rückgängig zu machen.")
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Verlauf")
        .onAppear { model.refreshHistory() }
        .confirmationDialog("Ganzen Lauf rückgängig machen?", isPresented: Binding(get: { confirmUndo != nil }, set: { if !$0 { confirmUndo = nil } })) {
            Button("Rückgängig machen") {
                if let run = confirmUndo { model.undoRun(run.id) }
                confirmUndo = nil
            }
            Button("Abbrechen", role: .cancel) { confirmUndo = nil }
        } message: {
            Text("Alle erledigten Aktionen werden in umgekehrter Reihenfolge zurückgenommen. Belegte Originalnamen werden nicht überschrieben.")
        }
    }
}

struct RunDetail: View {
    @Environment(AppModel.self) private var model
    let run: RunRecord
    let onUndoAll: () -> Void

    var body: some View {
        let entries = model.entries(for: run.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(run.title).font(.headline)
                    Text("\(run.total) Aktionen · Status: \(run.status)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Ganzen Lauf rückgängig …", action: onUndoAll)
                    .disabled(!entries.contains { $0.status == .done })
            }
            .padding(12)
            Divider()
            List(entries) { entry in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.kind.displayName): \(URL(fileURLWithPath: entry.sourcePath).lastPathComponent)")
                        Text(model.home.abbreviate(URL(fileURLWithPath: entry.sourcePath)) + " → " + (entry.destPath.map { model.home.abbreviate(URL(fileURLWithPath: $0)) } ?? (entry.trashPath != nil ? "Papierkorb" : "–")))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        if let error = entry.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    Text(entry.status.displayName).font(.caption)
                        .foregroundStyle(entry.status == .done ? .green : entry.status == .undone ? .secondary : .orange)
                    if entry.status == .done {
                        Button("Rückgängig") { model.undoEntry(entry.id) }
                    }
                }
            }
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }
}
