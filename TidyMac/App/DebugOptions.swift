import AppKit
import SwiftUI
import TidyCore

/// Developer options (Debug builds only): run against a test home and save window snapshots.
///   TIDYMAC_HOME=/tmp/x/home  TIDYMAC_SUPPORT=/tmp/x/support  TIDYMAC_SNAPSHOT_DIR=/tmp/shots
enum DebugOptions {
    #if DEBUG
    static let env = ProcessInfo.processInfo.environment
    static var home: HomeContext? { env["TIDYMAC_HOME"].map { HomeContext(home: URL(fileURLWithPath: $0)) } }
    static var supportDirectory: URL? { env["TIDYMAC_SUPPORT"].map { URL(fileURLWithPath: $0) } }
    static var snapshotDirectory: URL? { env["TIDYMAC_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) } }
    /// Simulates the passage of time for "Löschen" (files of a fresh test home count as old).
    static var now: Date { Date().addingTimeInterval((Double(env["TIDYMAC_NOW_OFFSET_DAYS"] ?? "") ?? 0) * 86_400) }
    #else
    static var now: Date { Date() }
    static var home: HomeContext? { nil }
    static var supportDirectory: URL? { nil }
    static var snapshotDirectory: URL? { nil }
    #endif

    /// Saves the content of every visible window as PNG (no screen-recording permission needed).
    @MainActor
    static func snapshot(_ name: String) {
        guard let dir = snapshotDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("\(name)-\(index).png"))
            }
        }
    }

    /// Shows the settings in a plain test window (the Settings scene cannot be opened from code).
    @MainActor
    static func showSettingsSnapshots() {
        let model = AppModel.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 760, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = "Einstellungen (Test)"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView().environment(model))
        window.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            for tab in ["schedule", "rename"] {
                model.settingsTab = tab
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                snapshot("08-settings-\(tab)")
            }
            window.close()
        }
    }

    /// Writes the window's view tree with frames (to diagnose blank snapshots).
    @MainActor
    static func dumpViews(_ name: String) {
        guard let dir = snapshotDirectory else { return }
        var lines: [String] = []
        func walk(_ view: NSView, _ depth: Int) {
            guard depth < 40 else { return }
            lines.append(String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame.integral) hidden=\(view.isHidden) alpha=\(view.alphaValue)")
            for sub in view.subviews { walk(sub, depth + 1) }
        }
        for window in NSApp.windows where window.isVisible && window.frame.width > 300 {
            lines.append("WINDOW \(window.title) \(window.frame.integral)")
            if let content = window.contentView { walk(content, 0) }
        }
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }

    /// Scripted UI tour for visual checks: scan the selected folders, then visit each section.
    @MainActor
    static func runTourIfRequested() {
        guard snapshotDirectory != nil else { return }
        let model = AppModel.shared
        model.showOnboarding = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            snapshot("01-start")
            if ProcessInfo.processInfo.environment["TIDYMAC_TOUR_SETTINGS_ONLY"] == "1" {
                showSettingsSnapshots()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.environment["TIDYMAC_TOUR_DELETION_ONLY"] == "1" {
                model.selection = .deletion
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                snapshot("d1-empty")
                model.scope = .everything
                model.findDeletionCandidates()
                while model.isWorking { try? await Task.sleep(nanoseconds: 300_000_000) }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                snapshot("d2-list")
                dumpViews("d2-views")
                NSApp.terminate(nil)
                return
            }
            model.scope = .selected
            model.startScan()
            while model.isWorking { try? await Task.sleep(nanoseconds: 300_000_000) }
            try? await Task.sleep(nanoseconds: 800_000_000)
            snapshot("02-preview")
            if ProcessInfo.processInfo.environment["TIDYMAC_TOUR_EXECUTE"] == "1" {
                // Only moves/renames (no Trash) so a test run never touches the real Trash.
                for i in model.actions.indices where model.actions[i].kind == .trash || model.actions[i].kind == .archive {
                    model.actions[i].isSelected = false
                }
                model.executeSelected()
                while model.isWorking { try? await Task.sleep(nanoseconds: 300_000_000) }
                try? await Task.sleep(nanoseconds: 800_000_000)
                snapshot("02b-executed")
                if let runID = model.lastResult?.runID {
                    try? "\(model.lastResult?.summary ?? "")".write(to: (snapshotDirectory ?? URL(fileURLWithPath: "/tmp")).appendingPathComponent("executed.txt"), atomically: true, encoding: .utf8)
                    model.undoRun(runID)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            for item in [SidebarItem.protected, .history] {
                model.selection = item
                try? await Task.sleep(nanoseconds: 800_000_000)
                snapshot("03-\(item.rawValue)")
            }
            model.selection = .duplicates
            model.findDuplicates()
            while model.isWorking { try? await Task.sleep(nanoseconds: 300_000_000) }
            try? await Task.sleep(nanoseconds: 800_000_000)
            snapshot("04-duplicates")
            model.selection = .cleanup
            model.findCleanup()
            while model.isWorking { try? await Task.sleep(nanoseconds: 300_000_000) }
            try? await Task.sleep(nanoseconds: 800_000_000)
            snapshot("05-cleanup")

            // "Löschen": check, confirm one suggestion, never execute (that would use the real Trash).
            model.selection = .deletion
            model.scope = .everything
            model.findDeletionCandidates()
            while model.isWorking { try? await Task.sleep(nanoseconds: 300_000_000) }
            try? await Task.sleep(nanoseconds: 800_000_000)
            snapshot("06-deletion")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            snapshot("06-deletion-late")
            if let first = model.deletionSuggestions.first {
                model.deletionConfirmBinding(first.id).wrappedValue = true
                try? await Task.sleep(nanoseconds: 500_000_000)
                snapshot("06b-deletion-confirmed")
            }
            let lines = model.deletionSuggestions.map { "\($0.source.rawValue) \(Int($0.confidence * 100))% \(model.home.abbreviate($0.url)) – \($0.reason)" }
            let report = model.deletionReport.map { "alt: \($0.oldFiles), behalten (KI): \($0.keptByAI), unklar: \($0.unsureByAI), nicht gesendet: \($0.notSent), Fehler: \($0.aiStats.errors)" } ?? "-"
            try? ([report] + lines).joined(separator: "\n").write(to: (snapshotDirectory ?? URL(fileURLWithPath: "/tmp")).appendingPathComponent("deletion.txt"), atomically: true, encoding: .utf8)

            if ProcessInfo.processInfo.environment["TIDYMAC_TOUR_AUTOMATION"] == "1" {
                model.selection = .history
                model.settings.schedule.notify = false   // no real notification from a test run
                model.runAutomation(manual: true)
                while model.isWorking { try? await Task.sleep(nanoseconds: 300_000_000) }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                snapshot("07-automation")
                try? (model.automationSummary ?? "-").write(to: (snapshotDirectory ?? URL(fileURLWithPath: "/tmp")).appendingPathComponent("automation.txt"), atomically: true, encoding: .utf8)
                if let run = model.runs.first, run.source == "schedule" {
                    model.undoRun(run.id)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            showSettingsSnapshots()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            NSApp.terminate(nil)
        }
    }
}
