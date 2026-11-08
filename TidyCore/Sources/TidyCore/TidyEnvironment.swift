import Foundation

/// Wires the core components together from the settings. Used by the app and `tidyctl`.
public struct TidyEnvironment: Sendable {
    public let home: HomeContext
    public let settings: TidySettings
    public let supportDirectory: URL
    public let apiKey: String?

    public init(home: HomeContext = .current, settings: TidySettings, supportDirectory: URL? = nil, apiKey: String? = nil) {
        self.home = home
        self.settings = settings
        self.supportDirectory = supportDirectory ?? Self.defaultSupportDirectory
        self.apiKey = apiKey
    }

    public static var defaultSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("TidyMac", isDirectory: true)
    }

    public var settingsURL: URL { supportDirectory.appendingPathComponent("settings.json") }
    public var journalURL: URL { supportDirectory.appendingPathComponent("journal.sqlite") }
    public var cacheURL: URL { supportDirectory.appendingPathComponent("ai-cache.sqlite") }

    public func makePolicy(extraRoots: [URL] = []) -> ProtectionPolicy {
        ProtectionPolicy(home: home, settings: settings.protection, references: ReferenceIndex.load(home: home),
                         extraAllowedRoots: extraRoots)
    }

    public func makeScanner(policy: ProtectionPolicy) -> FileScanner {
        FileScanner(home: home, policy: policy, general: settings.general)
    }

    public func makeResolver() -> DestinationResolver {
        DestinationResolver(home: home, screenshotLocation: DestinationResolver.systemScreenshotLocation(home: home))
    }

    public func makeEngine() -> RuleEngine {
        RuleEngine(home: home, settings: settings.rules, resolver: makeResolver())
    }

    public func makeProvider() -> AIProvider? {
        switch settings.ai.provider {
        case .off:
            return nil
        case .claudeCLI:
            guard let exe = ClaudeCLIProvider.locate(customPath: settings.ai.cliPath) else { return nil }
            return ClaudeCLIProvider(executable: exe, model: settings.ai.cliModel, effort: settings.ai.cliEffort)
        case .anthropicAPI:
            guard let key = apiKey, !key.isEmpty else { return nil }
            return AnthropicAPIProvider(apiKey: key, model: settings.ai.apiModel)
        }
    }

    public func makeCache() -> AICache? {
        try? AICache(url: cacheURL)
    }

    public func makeJournal() throws -> Journal {
        try Journal(url: journalURL)
    }

    public func makePlanner(policy: ProtectionPolicy, structure: StructureIndex? = nil, provider: AIProvider?) -> Planner {
        Planner(home: home, policy: policy, engine: makeEngine(),
                structure: structure ?? StructureIndex.build(home: home, policy: policy),
                provider: provider, cache: provider == nil ? nil : makeCache(), general: settings.general,
                aiSettings: settings.ai)
    }
}
