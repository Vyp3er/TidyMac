import SwiftUI
import TidyCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("TidyMac") {
                    ForEach([SidebarItem.sort, .duplicates, .cleanup, .deletion]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("Übersicht") {
                    Label(SidebarItem.review.title, systemImage: SidebarItem.review.symbol)
                        .badge(model.reviewItems.count)
                        .tag(SidebarItem.review)
                    Label(SidebarItem.protected.title, systemImage: SidebarItem.protected.symbol)
                        .badge(model.scanResult?.protected.count ?? 0)
                        .tag(SidebarItem.protected)
                    Label(SidebarItem.history.title, systemImage: SidebarItem.history.symbol)
                        .tag(SidebarItem.history)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { SidebarStatus() }
        } detail: {
            switch model.selection ?? .sort {
            case .sort: SortView()
            case .duplicates: DuplicatesView()
            case .cleanup: CleanupView()
            case .deletion: DeletionView()
            case .review: ReviewView()
            case .protected: ProtectedView()
            case .history: HistoryView()
            }
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView()
        }
        .alert("Hinweis", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear { model.refreshFullDiskAccess() }
    }
}

struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.fullDiskAccess {
                Button {
                    FullDiskAccess.openSettings()
                } label: {
                    Label("Festplattenvollzugriff fehlt", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("TidyMac funktioniert auch ohne, sieht dann aber manche Ordner nicht.")
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(model.background.isRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(model.background.isRunning ? "Hintergrund-Modus aktiv" : "Hintergrund-Modus aus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small reusable helpers.
struct ConfidenceBadge: View {
    let value: Double

    var color: Color {
        value >= 0.85 ? .green : value >= 0.7 ? .yellow : .orange
    }

    var body: some View {
        Text("\(Int((value * 100).rounded())) %")
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color == .yellow ? Color.primary : color)
            .help("Konfidenz")
    }
}

struct FileIcon: View {
    let url: URL
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: size, height: size)
    }
}

struct WorkingOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(model.workTitle).font(.headline)
            if model.progressCount > 0 {
                Text("\(model.progressCount) Einträge gescannt").font(.callout.monospacedDigit())
            }
            Text(model.progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
            Button("Abbrechen", role: .cancel) { model.cancelWork() }
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct EmptyHint: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(text)
        }
    }
}

extension Int64 {
    var bytesText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
