import SwiftUI
import TidyCore

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Downloads aufräumen …") {
            show(.sort)
            model.startScan(.folders([model.home.downloads]))
        }
        .disabled(model.isWorking)
        Button("Ausgewählte Ordner aufräumen …") {
            show(.sort)
            model.scope = .selected
            model.startScan(.folders(model.selectedFolders))
        }
        .disabled(model.isWorking || model.settings.general.selectedFolders.isEmpty)
        Divider()
        Button("Zur Prüfung (\(model.reviewItems.count))") { show(.review) }
        if let last = model.runs.first, last.done > 0, last.undone < last.done {
            Button("Letzten Lauf rückgängig: \(last.title)") { model.undoRun(last.id) }
        }
        Divider()
        Toggle("Hintergrund-Modus", isOn: Binding(
            get: { model.settings.background.enabled },
            set: { value in
                model.settings.background.enabled = value
                if value && model.settings.background.notify { NotificationManager.shared.requestAuthorization() }
            }))
        Divider()
        Button("TidyMac öffnen") { show(model.selection ?? .sort) }
        SettingsLink { Text("Einstellungen …") }
        Divider()
        Button("Beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ item: SidebarItem) {
        model.selection = item
        openWindow(id: "main")
        NSApp.activate()
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: diskAccess
                case 2: ai
                default: background
                }
            }
            .frame(width: 560, height: 360, alignment: .topLeading)
            .padding(28)
            Divider()
            HStack {
                if page > 0 { Button("Zurück") { page -= 1 } }
                Spacer()
                Text("\(page + 1) / 4").foregroundStyle(.secondary).font(.caption)
                Spacer()
                if page < 3 {
                    Button("Weiter") { page += 1 }.buttonStyle(.borderedProminent)
                } else {
                    Button("Los geht’s") { model.finishOnboarding() }.buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Willkommen bei TidyMac", systemImage: "wand.and.stars").font(.title.bold())
            Text("TidyMac räumt deinen Home-Ordner oder ausgewählte Ordner auf: sortieren, Ordner anlegen, verschieben, umbenennen.")
            VStack(alignment: .leading, spacing: 8) {
                Label("Erst Vorschau, dann nur nach deiner Bestätigung ausführen", systemImage: "eye")
                Label("Projektordner (Git, Xcode, Node, Python, LaTeX …) bleiben unangetastet", systemImage: "hammer")
                Label("Library, versteckte Dateien, Apps, Cloud-Ordner und Links sind tabu", systemImage: "lock.shield")
                Label("Nichts wird überschrieben, Löschen heißt immer Papierkorb", systemImage: "trash")
                Label("Jeder Lauf kann vollständig rückgängig gemacht werden", systemImage: "arrow.uturn.backward")
            }
            .font(.callout)
        }
    }

    private var diskAccess: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Festplattenvollzugriff", systemImage: "externaldrive.badge.checkmark").font(.title2.bold())
            Text("Damit TidyMac alle deine Ordner sehen und Projektordner, Dock-Einträge und Finder-Favoriten zuverlässig erkennen kann, braucht es den Festplattenvollzugriff. TidyMac liest nur Metadaten und – wenn du die KI nutzt – kurze Textauszüge. Ohne die Freigabe funktioniert die App eingeschränkt; macOS fragt dann einzeln nach Schreibtisch, Dokumenten und Downloads.")
                .fixedSize(horizontal: false, vertical: true)
            Text("So geht’s: Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff → TidyMac aktivieren (ggf. mit „+“ hinzufügen) und die App neu starten.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Systemeinstellungen öffnen") { FullDiskAccess.openSettings() }
                Button("Erneut prüfen") { model.refreshFullDiskAccess() }
                Label(model.fullDiskAccess ? "Freigegeben" : "Noch nicht freigegeben",
                      systemImage: model.fullDiskAccess ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(model.fullDiskAccess ? .green : .orange)
            }
        }
    }

    private var ai: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            Label("Claude als Sortierhilfe", systemImage: "sparkles").font(.title2.bold())
            Text("Eindeutige Fälle erledigen schnelle Regeln. Nur unklare Dateien gehen an Claude – über deine lokal installierte Claude-Code-CLI, angemeldet mit deinem Claude-Pro-Abo. Das nutzt das Kontingent deines Abos (geteilt mit claude.ai), kein API-Guthaben.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Gesendet werden nur Dateiname, „~/“-Pfad, Metadaten und höchstens ~2.000 Zeichen Textauszug – nie ganze Dateien. Ordner und Dateitypen, die nie an die KI gehen sollen, legst du in den Einstellungen fest.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("KI-Anbindung", selection: $model.settings.ai.provider) {
                ForEach(AIProviderKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .frame(width: 380)
            HStack {
                Button("Status prüfen") { model.checkAI() }
                if model.isCheckingAI { ProgressView().controlSize(.small) }
                if let status = model.aiStatus {
                    Label(status.summary, systemImage: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(status.isAvailable ? .green : .orange)
                }
            }
        }
    }

    private var background: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            Label("Hintergrund-Modus (optional)", systemImage: "menubar.arrow.up.rectangle").font(.title2.bold())
            Text("TidyMac kann Downloads und Schreibtisch beobachten. Neue Dateien werden nach einer Wartezeit nur dann automatisch einsortiert, wenn eine sichere Regel greift. Alles andere landet unter „Zur Prüfung“. Du bekommst eine Mitteilung mit „Rückgängig“-Knopf.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Hintergrund-Modus aktivieren", isOn: $model.settings.background.enabled)
            Toggle("Beim Anmelden starten", isOn: Binding(
                get: { LoginItem.isEnabled },
                set: { try? LoginItem.set($0) }))
            Text("Das Menüleisten-Symbol bietet Schnellaktionen wie „Downloads aufräumen“.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onChange(of: model.settings.background.enabled) { _, enabled in
            if enabled { NotificationManager.shared.requestAuthorization() }
        }
    }
}
