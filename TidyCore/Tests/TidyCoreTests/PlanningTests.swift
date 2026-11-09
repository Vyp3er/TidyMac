import Foundation
@testable import TidyCore
import XCTest

/// Records what would be sent to the AI and answers with canned suggestions.
final class MockAIProvider: AIProvider, @unchecked Sendable {
    var displayName: String { "Mock" }
    var maxConcurrentRequests: Int { 1 }
    var answer: (AIFileDescriptor) -> AISuggestion?
    var folderAnswer: (AIFolderDescriptor) -> AISuggestion? = { _ in nil }
    private let lock = NSLock()
    private(set) var requests: [AIRequest] = []
    var error: AIError?

    init(answer: @escaping (AIFileDescriptor) -> AISuggestion?) {
        self.answer = answer
    }

    func suggest(_ request: AIRequest) async throws -> AIResponse {
        lock.withLock { requests.append(request) }
        if let error { throw error }
        let items = request.files.compactMap(answer) + request.folders.compactMap(folderAnswer)
        return AIResponse(items: items, inputTokens: 100, outputTokens: 20)
    }

    func checkAvailability() async -> AIAvailability { AIAvailability(isAvailable: true, summary: "ok") }

    var sentFiles: [AIFileDescriptor] { lock.withLock { requests.flatMap(\.files) } }
}

final class RuleEngineTests: XCTestCase {
    func testBuiltInRules() throws {
        let fake = try FakeHome()
        let engine = RuleEngine(home: fake.home, settings: RuleSettings(), resolver: DestinationResolver(home: fake.home))
        let date = ISO8601DateFormatter().date(from: "2023-05-10T10:00:00Z")
        func dest(_ name: String, screenshot: Bool = false) -> String? {
            var item = FileItem(url: fake.url("Downloads/\(name)"), size: 10, created: date, modified: date)
            item.isScreenshot = screenshot
            return engine.match(item).map { fake.home.abbreviate($0.destinationFolder) }
        }
        XCTAssertEqual(dest("Setup.dmg"), "~/Downloads/Installer")
        XCTAssertEqual(dest("Rechnung_Telekom.pdf"), "~/Documents/Finanzen/Rechnungen/2023")
        XCTAssertEqual(dest("Kontoauszug_05.pdf"), "~/Documents/Finanzen/Kontoauszüge/2023")
        XCTAssertEqual(dest("x.png", screenshot: true), "~/Pictures/Bildschirmfotos/2023")
        XCTAssertEqual(dest("Bildschirmfoto 2023-05-10 um 10.00.00.png"), "~/Pictures/Bildschirmfotos/2023")
        XCTAssertEqual(dest("IMG_4831.HEIC"), "~/Pictures/Fotos/2023")
        XCTAssertEqual(dest("buch.epub"), "~/Documents/Bücher")
        XCTAssertNil(dest("Notizen.docx"))
    }

    func testExistingFoldersArePreferred() throws {
        let fake = try FakeHome()
        fake.dir("Pictures/Screenshots")
        fake.dir("Documents/Finances/Invoices")
        let engine = RuleEngine(home: fake.home, settings: RuleSettings(), resolver: DestinationResolver(home: fake.home))
        var shot = FileItem(url: fake.url("Desktop/a.png"), size: 1, created: Date())
        shot.isScreenshot = true
        XCTAssertTrue(engine.match(shot)?.destinationFolder.path.contains("/Pictures/Screenshots/") == true)
        let invoice = FileItem(url: fake.url("Downloads/Rechnung 12.pdf"), size: 1, created: Date())
        XCTAssertTrue(engine.match(invoice)?.destinationFolder.path.contains("/Documents/Finances/Invoices/") == true)
    }

    func testUserRuleWinsAndRenames() throws {
        let fake = try FakeHome()
        var settings = RuleSettings()
        settings.userRules = [SortRule(name: "Steuer", conditions: [RuleCondition(.name, .contains, "steuer")],
                                       destination: "~/Documents/Steuer/{year}", renameTemplate: "{date} {name}", confidence: 0.99)]
        settings.disabledBuiltInRules = ["builtin.installers"]
        let engine = RuleEngine(home: fake.home, settings: settings, resolver: DestinationResolver(home: fake.home))
        let date = ISO8601DateFormatter().date(from: "2024-02-03T10:00:00Z")
        let m = engine.match(FileItem(url: fake.url("Downloads/Steuerbescheid.pdf"), size: 1, created: date))
        XCTAssertEqual(m?.isUserRule, true)
        XCTAssertEqual(m?.newName, "2024-02-03 Steuerbescheid.pdf")
        XCTAssertNil(engine.match(FileItem(url: fake.url("Downloads/a.dmg"), size: 1)), "disabled built-in rule must not match")
    }
}

final class PlannerTests: XCTestCase {
    /// The general sorting mechanics without "Downloads → Documents".
    static var legacy: GeneralSettings {
        var g = GeneralSettings()
        g.inboxToDocuments = []
        return g
    }

    func makePlanner(_ fake: FakeHome, provider: AIProvider?, general: GeneralSettings = GeneralSettings(),
                     ai: AISettings = AISettings(), rules: RuleSettings = RuleSettings()) -> (FileScanner, Planner) {
        let policy = fake.policy()
        let scanner = FileScanner(home: fake.home, policy: policy, general: general)
        let engine = RuleEngine(home: fake.home, settings: rules, resolver: DestinationResolver(home: fake.home))
        let planner = Planner(home: fake.home, policy: policy, engine: engine,
                              structure: StructureIndex.build(home: fake.home, policy: policy), provider: provider,
                              cache: nil, general: general, aiSettings: ai)
        return (scanner, planner)
    }

    func testRulesOnlyPlanIsADryRun() async throws {
        let fake = try FakeHome()
        fake.file("Downloads/Rechnung_Strom.pdf")
        fake.file("Downloads/App.dmg")
        fake.file("Downloads/Notizen.docx")
        let (scanner, planner) = makePlanner(fake, provider: nil, general: Self.legacy)
        let before = fake.snapshot()
        let plan = await planner.plan(scan: await scanner.scan(.folders([fake.url("Downloads")])))
        XCTAssertEqual(before, fake.snapshot(), "planning must not change anything")
        let byName = Dictionary(uniqueKeysWithValues: plan.actions.map { ($0.source.lastPathComponent, $0) })
        XCTAssertEqual(byName["App.dmg"]?.kind, .move)
        XCTAssertEqual(byName["App.dmg"]?.isSelected, true)
        XCTAssertNotNil(byName["Rechnung_Strom.pdf"])
        XCTAssertNil(byName["Notizen.docx"])
        XCTAssertTrue(plan.unsorted.contains { $0.name == "Notizen.docx" })
        XCTAssertFalse(plan.newFolders().isEmpty)

        // Default: Downloads is emptied into Documents; the installer stays for "Löschen".
        let (scanner2, planner2) = makePlanner(fake, provider: nil)
        let plan2 = await planner2.plan(scan: await scanner2.scan(.folders([fake.url("Downloads")])))
        XCTAssertEqual(before, fake.snapshot())
        let byName2 = Dictionary(uniqueKeysWithValues: plan2.actions.map { ($0.source.lastPathComponent, $0) })
        XCTAssertNil(byName2["App.dmg"])
        XCTAssertEqual(plan2.disposable.map(\.name), ["App.dmg"])
        XCTAssertEqual(byName2["Notizen.docx"].map { fake.home.abbreviate($0.destinationFolder ?? fake.home.home) }, "~/Documents/Unterlagen")
        XCTAssertTrue(plan2.unsorted.isEmpty)
    }

    func testAIOnlyGetsUnclearFilesAndNoFullContent() async throws {
        let fake = try FakeHome()
        fake.file("Downloads/App.dmg")
        let longText = String(repeating: "Analysis Übungsblatt Integral ", count: 400)
        fake.file("Downloads/Scan_0012.txt", longText)
        fake.file("Downloads/geheim-passwort.txt", "secret")
        fake.dir("Documents/Uni/Mathe")
        let mock = MockAIProvider { d in
            AISuggestion(id: d.id, targetFolder: "~/Documents/Uni/Mathe", description: "Übungsblatt Analysis", confidence: 0.9, reason: "Uni-Inhalt")
        }
        let (scanner, planner) = makePlanner(fake, provider: mock)
        let plan = await planner.plan(scan: await scanner.scan(.folders([fake.url("Downloads")])))

        let sent = mock.sentFiles
        XCTAssertEqual(sent.map(\.name), ["Scan_0012.txt"], "only unclear, privacy-allowed files go to the AI")
        XCTAssertLessThanOrEqual(sent.first?.excerpt?.count ?? 0, 2000)
        XCTAssertFalse(sent.first?.path.contains(fake.root.path) ?? true, "absolute paths (user name) are never sent")
        XCTAssertTrue(mock.requests.first?.existingFolders.contains("~/Documents/Uni/Mathe") ?? false)

        let scan = plan.actions.first { $0.source.lastPathComponent == "Scan_0012.txt" }
        XCTAssertEqual(scan.map { fake.home.abbreviate($0.destinationFolder ?? fake.home.home) }, "~/Documents/Uni/Mathe")
        XCTAssertTrue(scan?.newName?.hasSuffix(" Übungsblatt Analysis.txt") ?? false, "renamed after scheme: \(scan?.newName ?? "nil")")
        XCTAssertEqual(scan?.origin, .ai)
    }

    func testLowConfidenceIsDeselectedAndForbiddenTargetsRejected() async throws {
        let fake = try FakeHome()
        fake.file("Downloads/a.docx")
        fake.file("Downloads/b.docx")
        fake.file("Downloads/c.docx")
        fake.file("Documents/Code/app/.git/HEAD")
        let mock = MockAIProvider { d in
            switch d.name {
            case "a.docx": return AISuggestion(id: d.id, targetFolder: "~/Documents/Briefe", description: "", confidence: 0.4, reason: "unsicher")
            case "b.docx": return AISuggestion(id: d.id, targetFolder: "~/Library/Mail", description: "", confidence: 0.95, reason: "böse")
            default: return AISuggestion(id: d.id, targetFolder: "~/Documents/Code/app/docs", description: "", confidence: 0.95, reason: "Projekt")
            }
        }
        let (scanner, planner) = makePlanner(fake, provider: mock, general: Self.legacy)
        let plan = await planner.plan(scan: await scanner.scan(.folders([fake.url("Downloads")])))
        let a = plan.actions.first { $0.source.lastPathComponent == "a.docx" }
        XCTAssertEqual(a?.isSelected, false, "low confidence must be deselected")
        XCTAssertNil(plan.actions.first { $0.source.lastPathComponent == "b.docx" }, "Library target must be dropped")
        XCTAssertNil(plan.actions.first { $0.source.lastPathComponent == "c.docx" }, "project target must be dropped")
    }

    func testSingleFileDoesNotGetANewAIFolder() async throws {
        let fake = try FakeHome()
        fake.file("Downloads/rezept.docx")
        fake.file("Downloads/brief1.docx")
        fake.file("Downloads/brief2.docx")
        let mock = MockAIProvider { d in
            let folder = d.name == "rezept.docx" ? "~/Documents/Kochen/Rezepte" : "~/Documents/Briefe"
            return AISuggestion(id: d.id, targetFolder: folder, description: "", confidence: 0.9, reason: "")
        }
        let (scanner, planner) = makePlanner(fake, provider: mock, general: Self.legacy)
        let plan = await planner.plan(scan: await scanner.scan(.folders([fake.url("Downloads")])))
        let rezept = plan.actions.first { $0.source.lastPathComponent == "rezept.docx" }
        XCTAssertEqual(rezept.map { fake.home.abbreviate($0.destinationFolder ?? fake.home.home) }, "~/Documents")
        let briefe = plan.actions.filter { $0.source.lastPathComponent.hasPrefix("brief") }
        XCTAssertTrue(briefe.allSatisfy { fake.home.abbreviate($0.destinationFolder ?? fake.home.home) == "~/Documents/Briefe" })
    }

    func testTooDeepNewHierarchyIsCut() async throws {
        let fake = try FakeHome()
        fake.file("Downloads/x1.docx")
        fake.file("Downloads/x2.docx")
        let mock = MockAIProvider { d in
            AISuggestion(id: d.id, targetFolder: "~/Documents/A/B/C/D/E", description: "", confidence: 0.9, reason: "")
        }
        let (scanner, planner) = makePlanner(fake, provider: mock)
        let plan = await planner.plan(scan: await scanner.scan(.folders([fake.url("Downloads")])))
        XCTAssertTrue(plan.actions.allSatisfy { fake.home.abbreviate($0.destinationFolder ?? fake.home.home) == "~/Documents/A/B/C" })
        XCTAssertTrue(plan.actions.allSatisfy { !$0.warnings.isEmpty && !$0.isSelected })
    }

    func testAIFailureFallsBackToRules() async throws {
        let fake = try FakeHome()
        fake.file("Downloads/bild.png")
        let mock = MockAIProvider { _ in nil }
        mock.error = .quotaExhausted("limit")
        let (scanner, planner) = makePlanner(fake, provider: mock, general: Self.legacy)
        let plan = await planner.plan(scan: await scanner.scan(.folders([fake.url("Downloads")])))
        let bild = plan.actions.first { $0.source.lastPathComponent == "bild.png" }
        XCTAssertEqual(bild.map { fake.home.abbreviate($0.destinationFolder ?? fake.home.home) }, "~/Pictures/Bilder")
        XCTAssertTrue(plan.notes.contains { $0.contains("Nutzungslimit") })
    }

    func testNameConflictsInsidePlanAreResolved() async throws {
        let fake = try FakeHome()
        fake.file("Desktop/Setup.dmg")
        fake.file("Downloads/Setup.dmg")
        fake.file("Downloads/Installer/Setup.dmg")
        let (scanner, planner) = makePlanner(fake, provider: nil, general: Self.legacy)
        let plan = await planner.plan(scan: await scanner.scan(.folders([fake.url("Downloads"), fake.url("Desktop")])))
        let names = plan.actions.map(\.finalName).sorted()
        XCTAssertEqual(names, ["Setup 2.dmg", "Setup 3.dmg"])
    }

    func testRenameOnlyMode() async throws {
        let fake = try FakeHome()
        let date = ISO8601DateFormatter().date(from: "2022-07-01T10:00:00Z")
        fake.file("Documents/Fotos/IMG_1234.jpg", modified: date)
        fake.file("Documents/Fotos/Strand Sonnenuntergang.jpg", modified: date)
        var general = GeneralSettings()
        general.includeSubfolderFiles = true
        let (scanner, planner) = makePlanner(fake, provider: nil, general: general)
        let plan = await planner.plan(scan: await scanner.scan(.folders([fake.url("Documents/Fotos")])), mode: .renameOnly)
        XCTAssertEqual(plan.actions.count, 1)
        XCTAssertEqual(plan.actions.first?.kind, .rename)
        XCTAssertEqual(plan.actions.first?.newName, "2022-07-01 IMG_1234.jpg")
    }

    func testFolderUnitsMoveAsWhole() async throws {
        let fake = try FakeHome()
        for i in 1...6 { fake.file("Downloads/Urlaub 2023/IMG_\(i).jpg") }
        let (scanner, planner) = makePlanner(fake, provider: nil)
        let plan = await planner.plan(scan: await scanner.scan(.folders([fake.url("Downloads")])))
        XCTAssertEqual(plan.actions.count, 1)
        XCTAssertEqual(plan.actions.first?.kind, .moveFolder)
        XCTAssertEqual(plan.actions.first?.source.lastPathComponent, "Urlaub 2023")
        XCTAssertFalse(plan.actions.contains { $0.source.lastPathComponent.hasPrefix("IMG_") }, "unit must not be split")
    }

    func testCacheAvoidsSecondRequest() async throws {
        let fake = try FakeHome()
        fake.file("Downloads/notiz.docx", "Inhalt")
        let mock = MockAIProvider { d in AISuggestion(id: d.id, targetFolder: "~/Documents", description: "", confidence: 0.9, reason: "") }
        let cache = try AICache(url: fake.root.appendingPathComponent("cache.sqlite"))
        let policy = fake.policy()
        func planner() -> Planner {
            Planner(home: fake.home, policy: policy,
                    engine: RuleEngine(home: fake.home, settings: RuleSettings(), resolver: DestinationResolver(home: fake.home)),
                    structure: StructureIndex(folders: []), provider: mock, cache: cache,
                    general: GeneralSettings(), aiSettings: AISettings())
        }
        let scanner = FileScanner(home: fake.home, policy: policy, general: GeneralSettings())
        let scan = await scanner.scan(.folders([fake.url("Downloads")]))
        _ = await planner().plan(scan: scan)
        let second = await planner().plan(scan: scan)
        XCTAssertEqual(mock.requests.count, 1)
        XCTAssertEqual(second.aiStats.cacheHits, 1)
        XCTAssertEqual(second.actions.count, 1)
    }
}

final class AIParsingTests: XCTestCase {
    func testCLIOutputWithStructuredOutput() throws {
        let json = """
        {"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"items":[{"id":"f1","targetFolder":"~/Documents","description":"Brief","confidence":0.8,"reason":"ok"}]},"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100},"total_cost_usd":0.002}
        """
        let r = try ClaudeCLIProvider.parse(ProcessOutput(stdout: Data(json.utf8), stderr: Data(), status: 0))
        XCTAssertEqual(r.items.first?.targetFolder, "~/Documents")
        XCTAssertEqual(r.inputTokens, 110)
    }

    func testCLIOutputFallsBackToResultText() throws {
        let json = #"{"type":"result","is_error":false,"result":"```json\n{\"items\":[{\"id\":\"f2\",\"targetFolder\":\"\",\"description\":\"\",\"confidence\":0.2,\"reason\":\"?\"}]}\n```"}"#
        let r = try ClaudeCLIProvider.parse(ProcessOutput(stdout: Data(json.utf8), stderr: Data(), status: 0))
        XCTAssertEqual(r.items.first?.id, "f2")
    }

    func testCLIErrorsAreClassified() {
        let limit = #"{"type":"result","is_error":true,"result":"Claude usage limit reached. Your limit will reset at 5pm"}"#
        XCTAssertThrowsError(try ClaudeCLIProvider.parse(ProcessOutput(stdout: Data(limit.utf8), stderr: Data(), status: 1))) { error in
            guard case .quotaExhausted = error as? AIError else { return XCTFail("\(error)") }
        }
        let login = #"{"type":"result","is_error":true,"result":"Invalid API key · Please run /login"}"#
        XCTAssertThrowsError(try ClaudeCLIProvider.parse(ProcessOutput(stdout: Data(login.utf8), stderr: Data(), status: 1))) { error in
            guard case .notLoggedIn = error as? AIError else { return XCTFail("\(error)") }
        }
    }

    func testCLIArgumentsDisableToolsAndEnvironmentDropsAPIKey() {
        let provider = ClaudeCLIProvider(executable: URL(fileURLWithPath: "/usr/bin/true"), model: "sonnet")
        let args = provider.arguments
        XCTAssertTrue(args.contains("-p"))
        if let i = args.firstIndex(of: "--tools") { XCTAssertEqual(args[i + 1], "") } else { XCTFail("--tools missing") }
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertTrue(args.contains("--json-schema"))
        XCTAssertFalse(args.contains("--bare"), "--bare would ignore the subscription login")
        setenv("ANTHROPIC_API_KEY", "sk-test", 1)
        XCTAssertNil(ClaudeCLIProvider.environment["ANTHROPIC_API_KEY"])
        unsetenv("ANTHROPIC_API_KEY")
    }

    func testAPIRequestShape() throws {
        let provider = AnthropicAPIProvider(apiKey: "sk-test", model: "claude-opus-5-5")
        let request = try provider.makeRequest(AIRequest(today: "2026-01-01", existingFolders: [], files: [], folders: []))
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        let body = try XCTUnwrap(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let config = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual((config["format"] as? [String: Any])?["type"] as? String, "json_schema")
        XCTAssertNil(body["temperature"])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
    }

    func testAPIResponseParsing() throws {
        let provider = AnthropicAPIProvider(apiKey: "k", model: "claude-haiku-5-5")
        let json = #"{"model":"claude-haiku-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"{\"items\":[{\"id\":\"f1\",\"targetFolder\":\"~/Music\",\"description\":\"\",\"confidence\":0.7,\"reason\":\"Audio\"}]}"}],"usage":{"input_tokens":1000000,"output_tokens":0}}"#
        let r = try provider.parse(Data(json.utf8))
        XCTAssertEqual(r.items.count, 1)
        XCTAssertEqual(r.costUSD, 0.10, accuracy: 0.0001)
        let refusal = #"{"stop_reason":"refusal","content":[]}"#
        XCTAssertThrowsError(try provider.parse(Data(refusal.utf8)))
    }

    func testPrivacyFilter() throws {
        let fake = try FakeHome()
        var settings = AISettings()
        settings.excludedPaths = ["~/Documents/Privat"]
        let filter = PrivacyFilter(home: fake.home, settings: settings)
        XCTAssertFalse(filter.allows(fake.url("Documents/Privat/tagebuch.txt")))
        XCTAssertFalse(filter.allows(fake.url("Downloads/vault.kdbx")))
        XCTAssertFalse(filter.allows(fake.url("Downloads/Passwörter.txt")) && filter.allows(fake.url("Downloads/passwort.txt")))
        XCTAssertTrue(filter.allows(fake.url("Downloads/Rezept.pdf")))
    }
}
