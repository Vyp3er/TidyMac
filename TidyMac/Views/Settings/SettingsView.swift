import SwiftUI
import TidyCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab().tabItem { Label("Allgemein", systemImage: "gearshape") }
            RulesSettingsTab().tabItem { Label("Regeln", systemImage: "list.bullet.rectangle") }
            ProtectionSettingsTab().tabItem { Label("Schutz", systemImage: "lock.shield") }
            AISettingsTab().tabItem { Label("KI", systemImage: "sparkles") }
            BackgroundSettingsTab().tabItem { Label("Hintergrund", systemImage: "eye") }
            RenameCleanupSettingsTab().tabItem { Label("Umbenennen & Aufräumen", systemImage: "textformat") }
        }
        .frame(width: 720, height: 560)
    }
}

/// Editable list of "~/..." paths or patterns.
struct PathListEditor: View {
    let title: String
    @Binding var items: [String]
    var allowFolders = true
    var placeholder = "Muster, z. B. *.psd"

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            VStack(spacing: 0) {
                ForEach(items, id: \.self) { item in
                    HStack {
                        Text(item).font(.callout.monospaced()).lineLimit(1)
                        Spacer()
                        Button {
                            items.removeAll { $0 == item }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
                if items.isEmpty { Text("– keine –").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            }
            HStack {
                TextField(placeholder, text: $draft, onCommit: addDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Hinzufügen", action: addDraft).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if allowFolders {
                    Button("Ordner …") {
                        let home = HomeContext.current
                        for url in Finder.chooseFolders(start: home.home) {
                            let path = home.abbreviate(url)
                            if !items.contains(path) { items.append(path) }
                        }
                    }
                }
            }
        }
    }

    private func addDraft() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !items.contains(value) else { return }
        items.append(value)
        draft = ""
    }
}

struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var loginError: String?
    @State private var loginStatus = LoginItem.statusText

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Start") {
                Toggle("Beim Anmelden starten", isOn: Binding(
                    get: { LoginItem.isEnabled },
                    set: { value in
                        do { try LoginItem.set(value) } catch { loginError = error.localizedDescription }
                        loginStatus = LoginItem.statusText
                    }))
                Text("Status: \(loginStatus)").font(.caption).foregroundStyle(.secondary)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                Toggle("Beim Anmelden ohne Fenster starten (nur Menüleiste)", isOn: $model.settings.general.startHidden)
            }
            Section("Berechtigungen") {
                HStack {
                    Label(model.fullDiskAccess ? "Festplattenvollzugriff erteilt" : "Festplattenvollzugriff fehlt",
                          systemImage: model.fullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(model.fullDiskAccess ? .green : .orange)
                    Spacer()
                    Button("Systemeinstellungen öffnen") { FullDiskAccess.openSettings() }
                    Button("Prüfen") { model.refreshFullDiskAccess() }
                }
            }
            Section("Ausgewählte Ordner (für „Ausgewählte Ordner aufräumen“)") {
                PathListEditor(title: "Ordner", items: $model.settings.general.selectedFolders, placeholder: "~/Pfad")
            }
            Section("Sortierung") {
                Toggle("Auch Dateien in Unterordnern ausgewählter Ordner sortieren", isOn: $model.settings.general.includeSubfolderFiles)
                Stepper("Maximale Tiefe: \(model.settings.general.maxSubfolderDepth)", value: $model.settings.general.maxSubfolderDepth, in: 1...6)
                    .disabled(!model.settings.general.includeSubfolderFiles)
                Stepper("Neue Ordner erst ab \(model.settings.general.minFilesForNewFolder) passenden Dateien",
                        value: $model.settings.general.minFilesForNewFolder, in: 1...10)
                Stepper("Höchstens \(model.settings.general.maxNewFolderDepth) neue Ordnerebenen",
                        value: $model.settings.general.maxNewFolderDepth, in: 1...5)
                VStack(alignment: .leading) {
                    Slider(value: $model.settings.general.selectThreshold, in: 0.5...0.95, step: 0.05) {
                        Text("Vorauswahl ab \(Int(model.settings.general.selectThreshold * 100)) % Konfidenz")
                    }
                    Slider(value: $model.settings.general.certainThreshold, in: 0.7...0.99, step: 0.01) {
                        Text("Regel gilt als sicher ab \(Int(model.settings.general.certainThreshold * 100)) % (sonst KI fragen)")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct RulesSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var selectedRule: String?

    var body: some View {
        @Bindable var model = model
        HSplitView {
            List(selection: $selectedRule) {
                Section("Eigene Regeln (haben Vorrang)") {
                    ForEach(model.settings.rules.userRules) { rule in
                        HStack {
                            Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle").foregroundStyle(rule.isEnabled ? .green : .secondary)
                            Text(rule.name)
                        }
                        .tag(rule.id)
                    }
                }
                Section("Eingebaute Regeln") {
                    ForEach(BuiltInRules.all) { rule in
                        Toggle(isOn: Binding(
                            get: { !model.settings.rules.disabledBuiltInRules.contains(rule.id) },
                            set: { on in
                                if on { model.settings.rules.disabledBuiltInRules.removeAll { $0 == rule.id } }
                                else { model.settings.rules.disabledBuiltInRules.append(rule.id) }
                            })) {
                            VStack(alignment: .leading) {
                                Text(rule.name)
                                Text("→ \(rule.destination) · \(Int(rule.confidence * 100)) %").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 260)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        let rule = SortRule(name: "Neue Regel",
                                            conditions: [RuleCondition(.fileExtension, .isOneOf, "pdf"), RuleCondition(.name, .contains, "Rechnung")],
                                            destination: "~/Documents/Finanzen/Rechnungen/{year}", confidence: 0.95)
                        model.settings.rules.userRules.append(rule)
                        selectedRule = rule.id
                    } label: {
                        Label("Regel hinzufügen", systemImage: "plus")
                    }
                    if let id = selectedRule, model.settings.rules.userRules.contains(where: { $0.id == id }) {
                        Button(role: .destructive) {
                            model.settings.rules.userRules.removeAll { $0.id == id }
                            selectedRule = nil
                        } label: {
                            Label("Löschen", systemImage: "minus")
                        }
                    }
                    Spacer()
                }
                .padding(8)
            }

            if let id = selectedRule, let rule = model.settings.rules.userRules.first(where: { $0.id == id }) {
                RuleEditor(rule: model.ruleBinding(id, fallback: rule))
                    .id(id)
            } else {
                EmptyHint(symbol: "list.bullet.rectangle", title: "Regeln",
                          text: "Eigene Regeln werden vor den eingebauten geprüft. Beispiel: PDFs mit „Rechnung“ im Namen → ~/Documents/Finanzen/Rechnungen/{year}")
                    .frame(minWidth: 380)
            }
        }
    }
}

struct RuleEditor: View {
    @Binding var rule: SortRule

    var body: some View {
        Form {
            Section("Regel") {
                TextField("Name", text: $rule.name)
                Toggle("Aktiv", isOn: $rule.isEnabled)
            }
            Section("Wenn alle Bedingungen zutreffen") {
                ForEach($rule.conditions) { $condition in
                    HStack {
                        Picker("", selection: $condition.field) {
                            ForEach(RuleField.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        Picker("", selection: $condition.op) {
                            ForEach(operators(for: condition.field), id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        if !condition.field.isBoolean {
                            TextField(condition.field == .kind ? "pdf, image, …" : "Wert", text: $condition.value)
                        }
                        Button {
                            rule.conditions.removeAll { $0.id == condition.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Bedingung hinzufügen") { rule.conditions.append(RuleCondition(.name, .contains, "")) }
            }
            Section("Dann") {
                TextField("Zielordner", text: $rule.destination)
                TextField("Umbenennen (optional)", text: $rule.renameTemplate)
                Text("Platzhalter: {year} {month} {day} {date} {yearMonth} {name} {ext} {kind} {domain}")
                    .font(.caption).foregroundStyle(.secondary)
                Slider(value: $rule.confidence, in: 0.5...1, step: 0.01) {
                    Text("Konfidenz \(Int(rule.confidence * 100)) %")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400)
    }

    private func operators(for field: RuleField) -> [RuleOperator] {
        if field.isBoolean { return [.isTrue, .isFalse] }
        if field.isNumeric { return [.greaterThan, .lessThan, .equals] }
        return [.contains, .notContains, .equals, .startsWith, .endsWith, .isOneOf, .matchesRegex]
    }
}

struct ProtectionSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Text("Immer geschützt: ~/Library, versteckte Dateien, Systemordner, /Programme, App-Bundles und Pakete, Symlinks und Aliasse, geöffnete Dateien, Projektordner (Git, Xcode, Node, Python, Rust, Go, Java, LaTeX …), Ordner mit App-Datenbanken und Cloud-Ordner.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Eigene Ausschlüsse") {
                PathListEditor(title: "Ordner, die nie angefasst werden", items: $model.settings.protection.excludedPaths, placeholder: "~/Pfad")
                PathListEditor(title: "Muster (Name oder Pfad)", items: $model.settings.protection.excludedPatterns, allowFolders: false,
                               placeholder: "*.psd  oder  ~/Documents/Steuer/*")
            }
            Section("Cloud-Ordner") {
                PathListEditor(title: "Ausdrücklich freigegebene Cloud-Ordner (iCloud, Dropbox, OneDrive …)",
                               items: $model.settings.protection.allowedCloudPaths, placeholder: "~/Dropbox")
            }
            Section("Projekte & Verweise") {
                Toggle("Projektordner dürfen als Ganzes verschoben werden", isOn: $model.settings.protection.allowMovingProjectFolders)
                Text("Inhalte von Projektordnern werden in keinem Fall angefasst.").font(.caption).foregroundStyle(.secondary)
                PathListEditor(title: "Zusätzliche Projekt-Marker (Datei- oder Ordnernamen)",
                               items: $model.settings.protection.extraProjectMarkers, allowFolders: false, placeholder: "z. B. .myproject")
            }
        }
        .formStyle(.grouped)
    }
}

struct AISettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var keyDraft = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Anbindung") {
                Picker("KI", selection: $model.settings.ai.provider) {
                    ForEach(AIProviderKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                HStack {
                    Button("Status prüfen") { model.checkAI() }
                    if model.isCheckingAI { ProgressView().controlSize(.small) }
                    if let status = model.aiStatus {
                        VStack(alignment: .leading) {
                            Label(status.summary, systemImage: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(status.isAvailable ? .green : .orange)
                            if !status.detail.isEmpty { Text(status.detail).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if model.settings.ai.provider == .claudeCLI {
                Section("Claude Code CLI (Pro-Abo)") {
                    Text("Ruft dein lokal installiertes, mit claude.ai angemeldetes `claude` im Headless-Modus auf (`claude -p --output-format json`). Werkzeuge, MCP-Server, Plugins und Sitzungsspeicher sind dabei abgeschaltet; API-Key-Variablen werden entfernt, damit nichts als API-Nutzung abgerechnet wird. Die Anfragen zählen zum Kontingent deines Abos (5-Stunden- und Wochenlimit, geteilt mit claude.ai).")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Pfad zu claude (leer = automatisch)", text: $model.settings.ai.cliPath)
                    TextField("Modell (leer = Claude-Code-Standard, z. B. sonnet, opus, haiku)", text: $model.settings.ai.cliModel)
                    Picker("Aufwand (effort)", selection: $model.settings.ai.cliEffort) {
                        ForEach(["low", "medium", "high"], id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            if model.settings.ai.provider == .anthropicAPI {
                Section("Anthropic API") {
                    Text("Wird pro Token über die Anthropic Console abgerechnet – unabhängig vom Pro-Abo. Der Schlüssel liegt im Schlüsselbund.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        SecureField(model.apiKey.isEmpty ? "API-Key (sk-ant-…)" : "Gespeichert – zum Ersetzen neu eingeben", text: $keyDraft)
                        Button("Speichern") { model.apiKey = keyDraft; keyDraft = "" }.disabled(keyDraft.isEmpty)
                        if !model.apiKey.isEmpty { Button("Entfernen") { model.apiKey = "" } }
                    }
                    Picker("Modell", selection: $model.settings.ai.apiModel) {
                        ForEach(AnthropicAPIProvider.models, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            Section("Datenschutz") {
                Toggle("Kurze Textauszüge mitsenden", isOn: $model.settings.ai.sendExcerpts)
                Stepper("Höchstens \(model.settings.ai.excerptLength) Zeichen pro Datei", value: $model.settings.ai.excerptLength, in: 200...4000, step: 100)
                    .disabled(!model.settings.ai.sendExcerpts)
                PathListEditor(title: "Ordner, die nie an die KI gehen", items: $model.settings.ai.excludedPaths, placeholder: "~/Documents/Privat")
                PathListEditor(title: "Dateiendungen, die nie an die KI gehen", items: $model.settings.ai.excludedExtensions, allowFolders: false, placeholder: "kdbx")
                PathListEditor(title: "Namensmuster, die nie an die KI gehen", items: $model.settings.ai.excludedPatterns, allowFolders: false, placeholder: "*vertraulich*")
            }
            Section("Effizienz") {
                Stepper("\(model.settings.ai.batchSize) Dateien pro Anfrage", value: $model.settings.ai.batchSize, in: 5...50, step: 5)
                Stepper("Höchstens \(model.settings.ai.maxFilesPerRun) Dateien pro Lauf an die KI", value: $model.settings.ai.maxFilesPerRun, in: 20...2000, step: 20)
                Toggle("KI auch im Hintergrund-Modus nutzen", isOn: $model.settings.ai.useInBackground)
                HStack {
                    Text("Cache: \(model.cacheCount) bewertete Dateien")
                    Spacer()
                    Button("Cache leeren") { model.clearAICache() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.cacheCount = model.environment.makeCache()?.count() ?? 0 }
    }
}

struct BackgroundSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Hintergrund-Modus aktiv", isOn: $model.settings.background.enabled)
                Text("Neue Dateien in den beobachteten Ordnern werden nach der Wartezeit – Download fertig, Größe stabil, Datei nicht geöffnet – nur bei sicheren Regeln automatisch einsortiert. Alles andere landet unter „Zur Prüfung“. Ordner werden nie automatisch verschoben.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Beobachtete Ordner") {
                PathListEditor(title: "Ordner", items: $model.settings.background.watchedFolders, placeholder: "~/Downloads")
            }
            Section("Verhalten") {
                Stepper("Wartezeit: \(model.settings.background.settleSeconds) Sekunden", value: $model.settings.background.settleSeconds, in: 10...900, step: 10)
                Slider(value: $model.settings.background.autoThreshold, in: 0.8...1, step: 0.01) {
                    Text("Automatisch ab \(Int(model.settings.background.autoThreshold * 100)) % Konfidenz")
                }
                Toggle("Mitteilung mit Zusammenfassung und „Rückgängig“", isOn: $model.settings.background.notify)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.settings.background.enabled) { _, enabled in
            if enabled && model.settings.background.notify { NotificationManager.shared.requestAuthorization() }
        }
    }
}

struct RenameCleanupSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Einheitlich umbenennen") {
                Toggle("Nichtssagende Namen umbenennen (IMG_4831, Scan_0012, Dokument (3) …)", isOn: $model.settings.general.renameEnabled)
                TextField("Schema", text: $model.settings.general.renameScheme)
                Text("Platzhalter: {date} {year} {month} {day} {time} {description} {original}. Beispiel: „{date} {description}“ → „2025-03-14 Rechnung Telekom.pdf“. Dateien mit sinnvollem Namen bleiben unverändert.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Fotos/Videos ohne Beschreibung als „{date} {original}“", isOn: $model.settings.general.renameMediaWithDate)
            }
            Section("Aufräum-Vorschläge") {
                Stepper("Große Dateien ab \(model.settings.cleanup.largeFileMB) MB", value: $model.settings.cleanup.largeFileMB, in: 50...10_000, step: 50)
                Stepper("Lange nicht geöffnet: \(model.settings.cleanup.unusedDays) Tage", value: $model.settings.cleanup.unusedDays, in: 30...3650, step: 30)
                Stepper("… und mindestens \(model.settings.cleanup.minSizeForUnusedMB) MB", value: $model.settings.cleanup.minSizeForUnusedMB, in: 0...1000, step: 5)
                Stepper("Alte Installer ab \(model.settings.cleanup.installerAgeDays) Tagen", value: $model.settings.cleanup.installerAgeDays, in: 1...365)
                TextField("Archiv-Ordner", text: $model.settings.cleanup.archiveFolder)
            }
        }
        .formStyle(.grouped)
    }
}
