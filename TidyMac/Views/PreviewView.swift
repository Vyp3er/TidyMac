import SwiftUI
import TidyCore

enum PreviewMode: String, CaseIterable, Identifiable {
    case list, tree
    var id: String { rawValue }
    var title: String { self == .list ? "Liste" : "Vorher / Nachher" }
}

struct PreviewView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: PreviewMode = .list
    @State private var confirm = false
    @State private var showUnsorted = false

    var visibleActions: [PlannedAction] {
        model.actions.filter { a in
            switch model.filter {
            case .all: return true
            case .selected: return a.isSelected
            case .lowConfidence: return a.confidence < model.settings.general.selectThreshold
            case .warnings: return !a.warnings.isEmpty
            case .ai: return a.origin.isAI
            }
        }
    }

    var groups: [(String, [PlannedAction])] {
        let grouped = Dictionary(grouping: visibleActions) { $0.group }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Ansicht", selection: $mode) {
                    ForEach(PreviewMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .labelsHidden()
                if mode == .list {
                    Picker("Filter", selection: $model.filter) {
                        ForEach(ActionFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(width: 170)
                }
                Menu("Auswahl") {
                    Button("Alle auswählen") { setAll(true) }
                    Button("Keine auswählen") { setAll(false) }
                    Button("Nur sichere (≥ 85 %)") {
                        for i in model.actions.indices {
                            model.actions[i].isSelected = model.actions[i].confidence >= 0.85 && model.actions[i].warnings.isEmpty
                        }
                    }
                }
                .frame(width: 110)
                Spacer()
                summary
                Button {
                    confirm = true
                } label: {
                    Label("\(model.selectedActionCount) Aktionen ausführen …", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedActionCount == 0 || model.isWorking)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if model.actions.isEmpty {
                EmptyHint(symbol: "checkmark.seal", title: "Nichts zu tun",
                          text: "Alles ist schon ordentlich – oder es gab nur Dateien, die TidyMac nicht sicher zuordnen konnte (siehe unten).")
                    .frame(maxHeight: .infinity)
            } else if mode == .list {
                actionList
            } else {
                TreeComparisonView()
            }
            footer
        }
        .confirmationDialog("\(model.selectedActionCount) Aktionen ausführen?", isPresented: $confirm) {
            Button("Ausführen") { model.executeSelected() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Jede Aktion wird im Verlauf protokolliert und kann rückgängig gemacht werden. Es wird nichts überschrieben und nichts endgültig gelöscht.")
        }
    }

    private func setAll(_ value: Bool) {
        model.setSelected(visibleActions.map(\.id), value)
    }

    private var summary: some View {
        let folders = model.plan.map { _ in
            Plan(actions: model.actions).newFolders().count
        } ?? 0
        return Text("\(model.actions.count) Vorschläge · \(folders) neue Ordner")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var actionList: some View {
        @Bindable var model = model
        return List {
            let newFolders = Plan(actions: model.actions).newFolders()
            if !newFolders.isEmpty {
                Section("Neue Ordner (werden nur für ausgewählte Aktionen angelegt)") {
                    ForEach(newFolders.keys.sorted { $0.path < $1.path }, id: \.self) { url in
                        HStack {
                            Image(systemName: "folder.badge.plus").foregroundStyle(Color.accentColor)
                            Text(model.home.abbreviate(url))
                            Spacer()
                            Text((newFolders[url] ?? 0) == 1 ? "1 Eintrag" : "\(newFolders[url] ?? 0) Einträge").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }
            }
            ForEach(groups, id: \.0) { group, items in
                Section {
                    ForEach(items) { item in
                        ActionRow(action: model.actionBinding(item.id, fallback: item))
                    }
                } header: {
                    GroupHeader(title: group, ids: items.map(\.id))
                }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let plan = model.plan {
                if !plan.unsorted.isEmpty {
                    DisclosureGroup("\(plan.unsorted.count) Dateien ohne sicheren Vorschlag – bleiben liegen", isExpanded: $showUnsorted) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(plan.unsorted) { item in
                                    HStack {
                                        FileIcon(url: item.url, size: 14)
                                        Text(model.home.abbreviate(item.url)).font(.caption)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }
                ForEach(plan.notes.prefix(4), id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                if !plan.aiStats.provider.isEmpty {
                    let s = plan.aiStats
                    Label("\(s.provider): \(s.filesSent) Dateien und \(s.foldersSent) Ordner in \(s.batches) Anfragen, \(s.cacheHits) aus dem Cache · \(s.inputTokens + s.outputTokens) Tokens" + (s.costUSD > 0 && model.settings.ai.provider == .anthropicAPI ? String(format: " · ca. %.3f $", s.costUSD) : ""),
                          systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

struct GroupHeader: View {
    @Environment(AppModel.self) private var model
    let title: String
    let ids: [UUID]

    var body: some View {
        let idSet = Set(ids)
        let selected = model.actions.filter { idSet.contains($0.id) && $0.isSelected }.count
        HStack {
            Toggle(isOn: Binding(
                get: { selected == ids.count && !ids.isEmpty },
                set: { value in model.setSelected(ids, value) })) {
                Text(title).font(.headline)
            }
            .toggleStyle(.checkbox)
            Text("\(selected)/\(ids.count)").foregroundStyle(.secondary).font(.caption)
            Spacer()
        }
    }
}

struct ActionRow: View {
    @Environment(AppModel.self) private var model
    @Binding var action: PlannedAction
    @State private var editingName = false
    @State private var nameDraft = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $action.isSelected).toggleStyle(.checkbox).labelsHidden()
            FileIcon(url: action.source, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(action.source.lastPathComponent).fontWeight(.medium).lineLimit(1)
                    if action.isRename {
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        if editingName {
                            TextField("Neuer Name", text: $nameDraft, onCommit: commitName)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 220)
                        } else {
                            Text(action.finalName).foregroundStyle(Color.accentColor).lineLimit(1)
                        }
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(.secondary).font(.caption)
                    Text(destinationText).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text(action.origin.displayName)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((action.origin.isAI ? Color.purple : Color.blue).opacity(0.15), in: Capsule())
                    Text(action.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                ForEach(action.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            ConfidenceBadge(value: action.confidence)
            Menu {
                if action.kind == .move || action.kind == .rename || action.kind == .moveFolder {
                    Button("Ziel ändern …", action: chooseDestination)
                }
                if action.kind != .trash && action.kind != .archive && action.kind != .moveFolder {
                    Button(action.isRename ? "Namen bearbeiten" : "Umbenennen …") {
                        nameDraft = action.finalName
                        editingName = true
                    }
                    if action.isRename && action.kind == .move {
                        Button("Namen beibehalten") { action.newName = nil }
                    }
                }
                Divider()
                Button("Im Finder zeigen") { Finder.reveal(action.source) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.vertical, 3)
        .opacity(action.isSelected ? 1 : 0.6)
    }

    private var icon: String {
        switch action.kind {
        case .move: return "arrow.turn.down.right"
        case .moveFolder: return "folder"
        case .rename: return "pencil"
        case .trash: return "trash"
        case .archive: return "archivebox"
        }
    }

    private var destinationText: String {
        switch action.kind {
        case .rename: return "bleibt in \(model.home.abbreviate(action.source.deletingLastPathComponent()))"
        case .trash: return "Papierkorb"
        default: return action.destinationFolder.map { model.home.abbreviate($0) } ?? "?"
        }
    }

    private func commitName() {
        let ext = FileNameTools.split(action.source.lastPathComponent).ext
        var name = FileNameTools.sanitize(nameDraft)
        if !ext.isEmpty && FileNameTools.split(name).ext.lowercased() != ext.lowercased() { name = FileNameTools.join(name, ext) }
        editingName = false
        guard !name.isEmpty else { return }
        action.newName = name == action.source.lastPathComponent ? nil : name
        action.origin = .manual
        action.isSelected = action.kind != .rename || action.newName != nil
    }

    private func chooseDestination() {
        guard let url = Finder.chooseFolders(multiple: false, start: action.destinationFolder ?? model.home.documents,
                                             prompt: "Hierhin").first else { return }
        let policy = model.environment.makePolicy()
        if let problem = policy.destinationProtection(for: url) {
            model.errorMessage = "Dieser Ordner ist geschützt: \(problem.description)"
            return
        }
        action.destinationFolder = url
        if action.kind == .rename && !PathUtil.isSame(url, action.source.deletingLastPathComponent()) { action.kind = .move }
        action.group = model.home.abbreviate(url)
        action.origin = .manual
        action.confidence = 1
        action.isSelected = true
    }
}

// MARK: - Before / after tree

struct TreeNode: Identifiable, Hashable {
    let id: String
    let name: String
    var isFolder: Bool
    var isNew: Bool
    var children: [TreeNode]?
}

enum TreeBuilder {
    /// Builds a tree from "~/a/b/c" style paths.
    static func build(_ paths: [(path: String, isFolderLeaf: Bool)], newFolders: Set<String>) -> [TreeNode] {
        final class Box {
            var children: [String: Box] = [:]
            var isFolder = false
        }
        let root = Box()
        for (path, folderLeaf) in paths {
            let parts = path.split(separator: "/").map(String.init)
            var node = root
            for (i, part) in parts.enumerated() {
                let child = node.children[part] ?? Box()
                if i < parts.count - 1 || folderLeaf { child.isFolder = true }
                node.children[part] = child
                node = child
            }
        }
        func convert(_ box: Box, prefix: String) -> [TreeNode] {
            box.children.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { key in
                guard let child = box.children[key] else { return nil }
                let id = prefix.isEmpty ? key : prefix + "/" + key
                let kids = convert(child, prefix: id)
                return TreeNode(id: id, name: key, isFolder: child.isFolder, isNew: newFolders.contains(id),
                                children: kids.isEmpty ? nil : kids)
            }
        }
        return convert(root, prefix: "")
    }
}

struct TreeComparisonView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selected = model.actions.filter(\.isSelected)
        let newFolders = Set(Plan(actions: model.actions).newFolders().keys.map { model.home.abbreviate($0) })
        let before = TreeBuilder.build(selected.map { (model.home.abbreviate($0.source), $0.kind == .moveFolder) }, newFolders: [])
        let after = TreeBuilder.build(selected.compactMap { a in
            a.destinationURL.map { (model.home.abbreviate($0), a.kind == .moveFolder) } ?? ("Papierkorb/" + a.source.lastPathComponent, false)
        }, newFolders: newFolders)
        HSplitView {
            treeColumn(title: "Vorher", nodes: before)
            treeColumn(title: "Nachher", nodes: after)
        }
    }

    private func treeColumn(title: String, nodes: [TreeNode]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(10)
            List(nodes, children: \.children) { node in
                HStack(spacing: 6) {
                    Image(systemName: node.isFolder || node.children != nil ? "folder" : "doc")
                        .foregroundStyle(node.isNew ? Color.accentColor : .secondary)
                    Text(node.name)
                    if node.isNew {
                        Text("neu").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 5).background(Color.accentColor, in: Capsule())
                    }
                }
            }
        }
        .frame(minWidth: 280)
    }
}
