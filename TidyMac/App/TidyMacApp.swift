import AppKit
import SwiftUI
import TidyCore

@main
struct TidyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("TidyMac", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Aufräumen") {
                Button("Scannen & Vorschau") { model.startScan() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.isWorking)
                Button("Downloads aufräumen") { model.startScan(.folders([model.home.downloads])) }
                    .disabled(model.isWorking)
                Divider()
                Button("Ausgewählte Aktionen ausführen …") { model.selection = .sort }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.selectedActionCount == 0)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra("TidyMac", systemImage: "wand.and.stars") {
            MenuBarView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Login items are launched with the "launched as login item" Apple Event property.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAtLogin = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.setUp()
        // Started at login with "start hidden": only the menu bar icon, no window.
        if launchedAtLogin && AppModel.shared.settings.general.startHidden {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.isVisible && window.canBecomeMain { window.close() }
            }
        }
        DebugOptions.runTourIfRequested()
        if AppModel.shared.settings.background.enabled && AppModel.shared.settings.background.notify {
            NotificationManager.shared.requestAuthorization()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keeps running in the menu bar (background mode)
    }
}
