import SwiftUI
import TidyCore
import UniformTypeIdentifiers

/// Scan → preview → execute.
struct SortView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            TargetBar(isDropTargeted: $isDropTargeted)
            Divider()
            ZStack {
                if let result = model.lastResult {
                    ResultBanner(result: result)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .zIndex(1)
                }
                if model.plan != nil {
                    PreviewView()
                } else if !model.isWorking {
                    EmptyHint(symbol: "wand.and.stars", title: "Bereit zum Aufräumen",
                              text: "Wähle „Alles“ oder Ordner (auch per Drag & Drop) und klicke auf „Scannen & Vorschau“. Es wird nichts verändert, bevor du die Vorschau bestätigst.")
                }
                if model.isWorking { WorkingOverlay() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(PathUtil.isDirectory)
            model.addFolders(folders)
            return !folders.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .navigationTitle("Aufräumen")
    }
}

struct TargetBar: View {
    @Environment(AppModel.self) private var model
    @Binding var isDropTargeted: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Picker("Ziel", selection: $model.scope) {
                    ForEach(ScanScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)
                Picker("Modus", selection: $model.planMode) {
                    ForEach(PlanMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .frame(width: 260)
                Spacer()
                AIStatusPill()
                Button {
                    model.startScan()
                } label: {
                    Label("Scannen & Vorschau", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
            }
            if model.scope == .selected {
                HStack(alignment: .center, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.settings.general.selectedFolders, id: \.self) { path in
                                HStack(spacing: 4) {
                                    FileIcon(url: model.home.expand(path), size: 14)
                                    Text(path).font(.callout)
                                    Button {
                                        model.removeFolder(path)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                            if model.settings.general.selectedFolders.isEmpty {
                                Text("Noch keine Ordner – hinzufügen oder hierher ziehen")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button {
                        model.addFolders(Finder.chooseFolders(start: model.home.home))
                    } label: {
                        Label("Ordner hinzufügen …", systemImage: "plus")
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isDropTargeted ? Color.accentColor : Color.clear, style: StrokeStyle(lineWidth: 2, dash: [5])))
            } else {
                Text("Home-Ordner ohne Tabu-Bereiche: lose Dateien im Home, Schreibtisch, Downloads und Dokumente werden sortiert; alle anderen Ordner nur für Duplikate und Vorschläge gelesen. Library, versteckte Dateien, Projekte, Apps und Cloud-Ordner bleiben unberührt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}

struct AIStatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let provider = model.settings.ai.provider
        HStack(spacing: 6) {
            Image(systemName: provider == .off ? "bolt.slash" : "sparkles")
            Text(provider == .off ? "Nur Regeln" : provider == .claudeCLI ? "Claude (Abo)" : "Claude (API)")
            if let status = model.aiStatus {
                Circle().fill(status.isAvailable ? Color.green : Color.red).frame(width: 7, height: 7)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .help(model.aiStatus.map { "\($0.summary)\n\($0.detail)" } ?? "KI-Status in den Einstellungen prüfen")
        .onAppear { if model.aiStatus == nil && provider != .off { model.checkAI() } }
    }
}

struct ResultBanner: View {
    @Environment(AppModel.self) private var model
    let result: ExecutionResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(result.failed == 0 ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.lastResultTitle).font(.headline)
                Text(result.summary).font(.callout)
                if !result.messages.isEmpty {
                    Text(result.messages.prefix(3).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("Rückgängig") { model.undoRun(result.runID) }
            Button("Verlauf") { model.selection = .history }
            Button {
                model.lastResult = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(12)
        .shadow(radius: 4, y: 2)
    }
}
