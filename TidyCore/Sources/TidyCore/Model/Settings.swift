import Foundation

// All settings decode tolerantly: missing keys fall back to defaults, so adding a setting in a
// later version never wipes the user's existing rules or exclusions.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

public struct GeneralSettings: Codable, Sendable, Hashable {
    public var selectedFolders: [String] = ["~/Downloads", "~/Desktop"]
    public var includeSubfolderFiles = false
    public var maxSubfolderDepth = 2
    public var renameEnabled = true
    public var renameScheme = "{date} {description}"
    public var renameMediaWithDate = true
    public var certainThreshold = 0.85
    public var selectThreshold = 0.7
    public var minFilesForNewFolder = 2
    public var maxNewFolderDepth = 3
    public var startHidden = false
    public var onboardingDone = false
    /// Inbox folders that are emptied completely: every file gets a place under `documentsRoot`
    /// (category folders are created as needed). Disposable files stay for "Löschen".
    public var inboxToDocuments: [String] = ["~/Downloads"]
    public var documentsRoot = "~/Documents"

    public init() {}

    enum CodingKeys: String, CodingKey {
        case selectedFolders, includeSubfolderFiles, maxSubfolderDepth, renameEnabled, renameScheme,
             renameMediaWithDate, certainThreshold, selectThreshold, minFilesForNewFolder, maxNewFolderDepth,
             startHidden, onboardingDone, inboxToDocuments, documentsRoot
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GeneralSettings()
        selectedFolders = c.value(.selectedFolders, d.selectedFolders)
        includeSubfolderFiles = c.value(.includeSubfolderFiles, d.includeSubfolderFiles)
        maxSubfolderDepth = c.value(.maxSubfolderDepth, d.maxSubfolderDepth)
        renameEnabled = c.value(.renameEnabled, d.renameEnabled)
        renameScheme = c.value(.renameScheme, d.renameScheme)
        renameMediaWithDate = c.value(.renameMediaWithDate, d.renameMediaWithDate)
        certainThreshold = c.value(.certainThreshold, d.certainThreshold)
        selectThreshold = c.value(.selectThreshold, d.selectThreshold)
        minFilesForNewFolder = c.value(.minFilesForNewFolder, d.minFilesForNewFolder)
        maxNewFolderDepth = c.value(.maxNewFolderDepth, d.maxNewFolderDepth)
        startHidden = c.value(.startHidden, d.startHidden)
        onboardingDone = c.value(.onboardingDone, d.onboardingDone)
        inboxToDocuments = c.value(.inboxToDocuments, d.inboxToDocuments)
        documentsRoot = c.value(.documentsRoot, d.documentsRoot)
    }
}

public struct ProtectionSettings: Codable, Sendable, Hashable {
    /// Folders ("~/..." or absolute) that are never touched.
    public var excludedPaths: [String] = []
    /// Glob patterns on names ("*.psd") or paths ("~/Documents/Steuer/*").
    public var excludedPatterns: [String] = []
    /// Cloud folders the user explicitly released for sorting.
    public var allowedCloudPaths: [String] = []
    public var allowMovingProjectFolders = false
    public var allowMovingReferencedFolders = false
    public var extraProjectMarkers: [String] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case excludedPaths, excludedPatterns, allowedCloudPaths, allowMovingProjectFolders,
             allowMovingReferencedFolders, extraProjectMarkers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProtectionSettings()
        excludedPaths = c.value(.excludedPaths, d.excludedPaths)
        excludedPatterns = c.value(.excludedPatterns, d.excludedPatterns)
        allowedCloudPaths = c.value(.allowedCloudPaths, d.allowedCloudPaths)
        allowMovingProjectFolders = c.value(.allowMovingProjectFolders, d.allowMovingProjectFolders)
        allowMovingReferencedFolders = c.value(.allowMovingReferencedFolders, d.allowMovingReferencedFolders)
        extraProjectMarkers = c.value(.extraProjectMarkers, d.extraProjectMarkers)
    }
}

public struct RuleSettings: Codable, Sendable, Hashable {
    public var userRules: [SortRule] = []
    public var disabledBuiltInRules: [String] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case userRules, disabledBuiltInRules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userRules = c.value(.userRules, [])
        disabledBuiltInRules = c.value(.disabledBuiltInRules, [])
    }
}

public enum AIProviderKind: String, Codable, Sendable, CaseIterable, Hashable {
    case off
    case claudeCLI
    case anthropicAPI

    public var displayName: String {
        switch self {
        case .off: return "Aus (nur Regeln)"
        case .claudeCLI: return "Claude Code CLI (Pro-Abo)"
        case .anthropicAPI: return "Anthropic API-Key"
        }
    }
}

public struct AISettings: Codable, Sendable, Hashable {
    public var provider: AIProviderKind = .claudeCLI
    /// Empty = find `claude` automatically.
    public var cliPath = ""
    /// Empty = Claude Code's own default model.
    public var cliModel = ""
    public var cliEffort = "low"
    public var apiModel = "claude-opus-5-5"
    public var batchSize = 20
    public var maxConcurrentBatches = 2
    public var sendExcerpts = true
    public var excerptLength = 2000
    public var excludedPaths: [String] = []
    public var excludedExtensions: [String] = AISettings.defaultExcludedExtensions
    public var excludedPatterns: [String] = AISettings.defaultExcludedPatterns
    public var useInBackground = false
    /// Upper bound of files per run that go to the AI (protects the usage quota).
    public var maxFilesPerRun = 300

    public static let defaultExcludedExtensions = [
        "kdbx", "kdb", "keychain", "keychain-db", "pem", "key", "p12", "pfx", "gpg", "pgp", "asc",
        "ovpn", "env", "1pif", "opvault", "agilekeychain", "psafe3", "sig",
    ]
    public static let defaultExcludedPatterns = [
        "*passw*", "*kennwort*", "*secret*", "*geheim*", "*.env*", "id_rsa*", "id_ed25519*", "*private*key*",
        "*recovery*code*", "*wiederherstellung*",
    ]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case provider, cliPath, cliModel, cliEffort, apiModel, batchSize, maxConcurrentBatches, sendExcerpts,
             excerptLength, excludedPaths, excludedExtensions, excludedPatterns, useInBackground, maxFilesPerRun
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AISettings()
        provider = c.value(.provider, d.provider)
        cliPath = c.value(.cliPath, d.cliPath)
        cliModel = c.value(.cliModel, d.cliModel)
        cliEffort = c.value(.cliEffort, d.cliEffort)
        apiModel = c.value(.apiModel, d.apiModel)
        batchSize = c.value(.batchSize, d.batchSize)
        maxConcurrentBatches = c.value(.maxConcurrentBatches, d.maxConcurrentBatches)
        sendExcerpts = c.value(.sendExcerpts, d.sendExcerpts)
        excerptLength = c.value(.excerptLength, d.excerptLength)
        excludedPaths = c.value(.excludedPaths, d.excludedPaths)
        excludedExtensions = c.value(.excludedExtensions, d.excludedExtensions)
        excludedPatterns = c.value(.excludedPatterns, d.excludedPatterns)
        useInBackground = c.value(.useInBackground, d.useInBackground)
        maxFilesPerRun = c.value(.maxFilesPerRun, d.maxFilesPerRun)
    }
}

public struct BackgroundSettings: Codable, Sendable, Hashable {
    public var enabled = false
    public var watchedFolders: [String] = ["~/Downloads", "~/Desktop"]
    public var settleSeconds = 60
    public var autoThreshold = 0.9
    public var notify = true

    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, watchedFolders, settleSeconds, autoThreshold, notify }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BackgroundSettings()
        enabled = c.value(.enabled, d.enabled)
        watchedFolders = c.value(.watchedFolders, d.watchedFolders)
        settleSeconds = c.value(.settleSeconds, d.settleSeconds)
        autoThreshold = c.value(.autoThreshold, d.autoThreshold)
        notify = c.value(.notify, d.notify)
    }
}

public struct CleanupSettings: Codable, Sendable, Hashable {
    public var largeFileMB = 500
    public var unusedDays = 365
    public var minSizeForUnusedMB = 10
    public var installerAgeDays = 30
    public var archiveFolder = "~/Documents/Archiv"

    public init() {}

    enum CodingKeys: String, CodingKey { case largeFileMB, unusedDays, minSizeForUnusedMB, installerAgeDays, archiveFolder }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CleanupSettings()
        largeFileMB = c.value(.largeFileMB, d.largeFileMB)
        unusedDays = c.value(.unusedDays, d.unusedDays)
        minSizeForUnusedMB = c.value(.minSizeForUnusedMB, d.minSizeForUnusedMB)
        installerAgeDays = c.value(.installerAgeDays, d.installerAgeDays)
        archiveFolder = c.value(.archiveFolder, d.archiveFolder)
    }
}

/// "Löschen": old files that are probably no longer needed. Nothing is ever pre-selected;
/// every suggestion has to be confirmed on its own, and deleting always means the Trash.
public struct DeletionSettings: Codable, Sendable, Hashable {
    /// A file counts as old when it was neither opened nor changed for this many days.
    public var minAgeDays = 365
    /// In Downloads (a place for temporary things) files count as old much earlier.
    public var downloadsMinAgeDays = 90
    /// Installers of apps that are not (recognizably) installed are suggested after this many days.
    public var installerAgeDays = 7
    /// Claude's verdict must be at least this sure before a file is suggested.
    public var minConfidence = 0.6

    public init() {}

    enum CodingKeys: String, CodingKey { case minAgeDays, downloadsMinAgeDays, installerAgeDays, minConfidence }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeletionSettings()
        minAgeDays = c.value(.minAgeDays, d.minAgeDays)
        downloadsMinAgeDays = c.value(.downloadsMinAgeDays, d.downloadsMinAgeDays)
        installerAgeDays = c.value(.installerAgeDays, d.installerAgeDays)
        minConfidence = c.value(.minConfidence, d.minConfidence)
    }
}

/// "Automatik": scan and sort a few folders once a day at a fixed time.
public struct ScheduleSettings: Codable, Sendable, Hashable {
    public var enabled = false
    public var hour = 10
    public var minute = 0
    public var folders: [String] = ["~/Downloads", "~/Desktop"]
    /// Ask Claude about files no rule can place (counts against the usage limit).
    public var useAI = true
    /// Only actions at least this sure run automatically; the rest goes to "Zur Prüfung".
    public var autoThreshold = 0.9
    /// Also apply the renaming scheme automatically.
    public var allowRenames = true
    public var notify = true

    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, hour, minute, folders, useAI, autoThreshold, allowRenames, notify }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScheduleSettings()
        enabled = c.value(.enabled, d.enabled)
        hour = min(max(c.value(.hour, d.hour), 0), 23)
        minute = min(max(c.value(.minute, d.minute), 0), 59)
        folders = c.value(.folders, d.folders)
        useAI = c.value(.useAI, d.useAI)
        autoThreshold = c.value(.autoThreshold, d.autoThreshold)
        allowRenames = c.value(.allowRenames, d.allowRenames)
        notify = c.value(.notify, d.notify)
    }

    /// "10:00"
    public var timeText: String { String(format: "%02d:%02d", hour, minute) }
}

public struct TidySettings: Codable, Sendable, Hashable {
    public var general = GeneralSettings()
    public var protection = ProtectionSettings()
    public var rules = RuleSettings()
    public var ai = AISettings()
    public var background = BackgroundSettings()
    public var cleanup = CleanupSettings()
    public var deletion = DeletionSettings()
    public var schedule = ScheduleSettings()

    public init() {}

    enum CodingKeys: String, CodingKey { case general, protection, rules, ai, background, cleanup, deletion, schedule }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        general = c.value(.general, GeneralSettings())
        protection = c.value(.protection, ProtectionSettings())
        rules = c.value(.rules, RuleSettings())
        ai = c.value(.ai, AISettings())
        background = c.value(.background, BackgroundSettings())
        cleanup = c.value(.cleanup, CleanupSettings())
        deletion = c.value(.deletion, DeletionSettings())
        schedule = c.value(.schedule, ScheduleSettings())
    }

    public static func load(from url: URL) -> TidySettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(TidySettings.self, from: data) else { return TidySettings() }
        return settings
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
