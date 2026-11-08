import AppKit
import Foundation
import Security
import ServiceManagement
import TidyCore
import UserNotifications

/// API key storage in the login keychain (never in the settings file).
enum Keychain {
    static let service = "de.vincent-schmitt.TidyMac"
    static let account = "anthropic-api-key"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Launch at login via SMAppService (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "Aktiv"
        case .notRegistered: return "Aus"
        case .requiresApproval: return "Wartet auf Freigabe in Systemeinstellungen → Allgemein → Anmeldeobjekte"
        case .notFound: return "Nicht verfügbar (App liegt nicht in /Programme?)"
        @unknown default: return "Unbekannt"
        }
    }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Full Disk Access cannot be queried directly; reading a TCC-protected file tells us.
enum FullDiskAccess {
    static var isGranted: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = ["Library/Application Support/com.apple.TCC/TCC.db", "Library/Safari/Bookmarks.plist", "Library/Mail"]
        for probe in probes {
            let url = home.appendingPathComponent(probe)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if PathUtil.isDirectory(url) {
                if (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil { return true }
            } else if let handle = try? FileHandle(forReadingFrom: url) {
                try? handle.close()
                return true
            }
            return false
        }
        return false
    }

    static func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}

/// Notifications with an "Undo" button.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationManager()
    static let runCategory = "TIDY_RUN"
    static let undoAction = "TIDY_UNDO"
    static let reviewAction = "TIDY_REVIEW"

    var onUndo: (@MainActor (String) -> Void)?
    var onOpenReview: (@MainActor () -> Void)?

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let undo = UNNotificationAction(identifier: Self.undoAction, title: "Rückgängig", options: [])
        let review = UNNotificationAction(identifier: Self.reviewAction, title: "Zur Prüfung öffnen", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.runCategory, actions: [undo, review],
                                                                 intentIdentifiers: [], options: [])])
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, runID: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.runCategory
        if let runID { content.userInfo = ["runID": runID] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let runID = response.notification.request.content.userInfo["runID"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            if action == Self.undoAction, let runID { self.onUndo?(runID) }
            if action == Self.reviewAction || action == UNNotificationDefaultActionIdentifier { self.onOpenReview?() }
            completionHandler()
        }
    }
}

/// Background mode: FSEvents watcher + settle logic + periodic processing.
@MainActor
final class BackgroundService {
    private var watcher: FolderWatcher?
    private var organizer: BackgroundOrganizer?
    private var timer: Timer?
    private(set) var watchedFolders: [URL] = []

    var isRunning: Bool { watcher != nil }

    func configure(settings: TidySettings, environment: TidyEnvironment, journal: Journal?,
                   onOutcome: @escaping @MainActor (BackgroundOutcome) -> Void) {
        stop()
        guard settings.background.enabled, let journal else { return }
        let folders = settings.background.watchedFolders.map { environment.home.expand($0) }.filter(PathUtil.isDirectory)
        guard !folders.isEmpty else { return }
        let useAI = settings.ai.useInBackground
        let organizer = BackgroundOrganizer(
            home: environment.home, watchedFolders: folders,
            settleSeconds: TimeInterval(settings.background.settleSeconds),
            autoThreshold: settings.background.autoThreshold, journal: journal,
            makePolicy: { environment.makePolicy() },
            makePlanner: { policy in environment.makePlanner(policy: policy, provider: useAI ? environment.makeProvider() : nil) },
            executor: { policy in Executor(home: environment.home, policy: policy, journal: journal) })
        let watcher = FolderWatcher(folders: folders) { paths in organizer.note(paths: paths) }
        watcher.start()
        self.organizer = organizer
        self.watcher = watcher
        self.watchedFolders = folders
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task.detached(priority: .utility) {
                if let outcome = await organizer.tick() {
                    await MainActor.run { onOutcome(outcome) }
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
        organizer = nil
        watchedFolders = []
    }
}

enum Finder {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    static func chooseFolders(multiple: Bool = true, start: URL? = nil, prompt: String = "Auswählen") -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = multiple
        panel.prompt = prompt
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.urls : []
    }

    @MainActor
    static func chooseFile(start: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Thread-safe cancel flag shared with background work.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
    func reset() { lock.withLock { value = false } }
}
