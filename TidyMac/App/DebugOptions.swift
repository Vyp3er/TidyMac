import AppKit
import TidyCore

/// Developer options (Debug builds only): run against a test home and save window snapshots.
///   TIDYMAC_HOME=/tmp/x/home  TIDYMAC_SUPPORT=/tmp/x/support  TIDYMAC_SNAPSHOT_DIR=/tmp/shots
enum DebugOptions {
    #if DEBUG
    static let env = ProcessInfo.processInfo.environment
    static var home: HomeContext? { env["TIDYMAC_HOME"].map { HomeContext(home: URL(fileURLWithPath: $0)) } }
    static var supportDirectory: URL? { env["TIDYMAC_SUPPORT"].map { URL(fileURLWithPath: $0) } }
    static var snapshotDirectory: URL? { env["TIDYMAC_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) } }
    #else
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

    /// Scripted UI tour for visual checks: scan the selected folders, then visit each section.
    @MainActor
    static func runTourIfRequested() {
        guard snapshotDirectory != nil else { return }
        let model = AppModel.shared
        model.showOnboarding = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            snapshot("01-start")
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
            NSApp.terminate(nil)
        }
    }
}
