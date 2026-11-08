import Foundation

/// Uses the locally installed, unmodified Claude Code CLI in headless mode (`claude -p`).
/// Requests run on the user's own Claude login (Pro/Max subscription) and count against
/// that plan's usage limits. No API credits are used: API-key variables are removed from
/// the child environment so the CLI cannot silently switch to API billing.
public final class ClaudeCLIProvider: AIProvider, @unchecked Sendable {
    public let executable: URL
    public let model: String
    public let effort: String
    public let timeout: TimeInterval

    public var displayName: String { "Claude (Pro-Abo über Claude Code)" }
    public var maxConcurrentRequests: Int { 2 }

    public init(executable: URL, model: String = "", effort: String = "low", timeout: TimeInterval = 240) {
        self.executable = executable
        self.model = model.trimmingCharacters(in: .whitespaces)
        self.effort = effort.trimmingCharacters(in: .whitespaces)
        self.timeout = timeout
    }

    // MARK: Locating the CLI

    public static func locate(customPath: String) -> URL? {
        let fm = FileManager.default
        let realHome = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        let custom = (customPath as NSString).expandingTildeInPath
        if !custom.isEmpty { candidates.append(custom) }
        candidates += [
            "\(realHome)/.local/bin/claude", "\(realHome)/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", "\(realHome)/.npm-global/bin/claude", "\(realHome)/.bun/bin/claude",
            "\(realHome)/.volta/bin/claude", "\(realHome)/bin/claude",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Ask a login shell (GUI apps do not inherit the terminal's PATH).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !path.isEmpty && fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    // MARK: Invocation

    /// Arguments for the sorting task (kept for tests and diagnostics).
    var arguments: [String] {
        arguments(schemaJSON: PromptBuilder.outputSchemaJSON, systemPrompt: PromptBuilder.systemPrompt)
    }

    func arguments(schemaJSON: String, systemPrompt: String) -> [String] {
        var args = [
            "-p",
            "--output-format", "json",
            "--json-schema", schemaJSON,
            "--system-prompt", systemPrompt,
            "--tools", "",                  // no file, shell or web tools: Claude only sees what we send
            "--strict-mcp-config",          // no MCP servers
            "--safe-mode",                  // no CLAUDE.md, hooks, plugins, skills
            "--disable-slash-commands",
            "--no-session-persistence",     // nothing is stored as a resumable session
            "--permission-mode", "dontAsk",
        ]
        if !effort.isEmpty { args += ["--effort", effort] }
        if !model.isEmpty { args += ["--model", model] }
        return args
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Make sure the subscription login is used, never API billing or another provider.
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK",
                    "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_SIMPLE", "CLAUDECODE",
                    "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SAFE_MODE"] {
            env.removeValue(forKey: key)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (current + extra.filter { !current.contains($0) }).joined(separator: ":")
        env["DISABLE_AUTOUPDATER"] = "1"
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        return env
    }

    /// Empty working directory: even if a tool slipped through, there is nothing to read.
    static func workingDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TidyMac-claude-empty", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func perform(_ task: AITask) async throws -> AIRawResult {
        let output = try await ProcessRunner.run(executable: executable,
                                                 arguments: arguments(schemaJSON: task.schemaJSON, systemPrompt: task.systemPrompt),
                                                 input: task.userMessage, environment: Self.environment,
                                                 workingDirectory: Self.workingDirectory(), timeout: timeout)
        return try Self.parseRaw(output)
    }

    /// Sorting answer (used by tests).
    static func parse(_ output: ProcessOutput) throws -> AIResponse {
        let raw = try parseRaw(output)
        return AIResponse(items: try AIResponseParser.items(AISuggestion.self, from: raw.json),
                          inputTokens: raw.inputTokens, outputTokens: raw.outputTokens, costUSD: raw.costUSD)
    }

    static func parseRaw(_ output: ProcessOutput) throws -> AIRawResult {
        let stdout = String(data: output.stdout, encoding: .utf8) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: output.stdout)) as? [String: Any]
            ?? lastJSONLine(stdout)
        guard let json else {
            let err = String(data: output.stderr, encoding: .utf8) ?? ""
            throw classify(message: (err + stdout).trimmingCharacters(in: .whitespacesAndNewlines), status: output.status)
        }
        let isError = (json["is_error"] as? Bool) ?? false
        let resultText = json["result"] as? String ?? ""
        if isError || output.status != 0 {
            throw classify(message: resultText.isEmpty ? (json["subtype"] as? String ?? "Fehler") : resultText, status: output.status)
        }
        let data: Data
        if let structured = json["structured_output"], JSONSerialization.isValidJSONObject(structured) {
            data = try JSONSerialization.data(withJSONObject: structured)
        } else {
            data = try AIResponseParser.jsonData(fromText: resultText)
        }
        let usage = json["usage"] as? [String: Any] ?? [:]
        let input = (usage["input_tokens"] as? Int ?? 0) + (usage["cache_read_input_tokens"] as? Int ?? 0)
            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
        return AIRawResult(json: data, inputTokens: input, outputTokens: usage["output_tokens"] as? Int ?? 0,
                           costUSD: json["total_cost_usd"] as? Double ?? 0)
    }

    static func lastJSONLine(_ text: String) -> [String: Any]? {
        for line in text.split(separator: "\n").reversed() {
            if let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }
        return nil
    }

    static func classify(message: String, status: Int32) -> AIError {
        let lower = message.lowercased()
        if lower.contains("limit") && (lower.contains("usage") || lower.contains("reached") || lower.contains("nutzung")) {
            return .quotaExhausted(String(message.prefix(300)))
        }
        if lower.contains("login") || lower.contains("log in") || lower.contains("authenticat") || lower.contains("oauth")
            || lower.contains("not logged") {
            return .notLoggedIn(String(message.prefix(300)))
        }
        return .processFailed(message.isEmpty ? "Exit-Status \(status)" : String(message.prefix(500)))
    }

    // MARK: Status

    public func checkAvailability() async -> AIAvailability {
        do {
            let output = try await ProcessRunner.run(executable: executable, arguments: ["auth", "status"], input: "",
                                                     environment: Self.environment, workingDirectory: Self.workingDirectory(),
                                                     timeout: 30)
            guard let json = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any] else {
                return AIAvailability(isAvailable: false, summary: "Status unbekannt",
                                      detail: String(data: output.stdout + output.stderr, encoding: .utf8) ?? "")
            }
            let loggedIn = json["loggedIn"] as? Bool ?? false
            let method = json["authMethod"] as? String ?? "?"
            let plan = json["subscriptionType"] as? String ?? ""
            guard loggedIn else {
                return AIAvailability(isAvailable: false, summary: "Nicht angemeldet",
                                      detail: "Im Terminal `claude` starten und mit dem Claude-Konto anmelden (/login).")
            }
            if method != "claude.ai" {
                return AIAvailability(isAvailable: true, summary: "Angemeldet, aber nicht über das Abo (\(method))",
                                      detail: "Claude Code nutzt keinen claude.ai-Login. Anfragen könnten als API-Nutzung abgerechnet werden.")
            }
            let planText = plan.isEmpty ? "" : ", Plan: \(plan.capitalized)"
            return AIAvailability(isAvailable: true, summary: "Angemeldet über claude.ai\(planText)",
                                  detail: "Anfragen zählen zum Nutzungskontingent deines Abos (5-Stunden- und Wochenlimit, geteilt mit claude.ai).")
        } catch {
            return AIAvailability(isAvailable: false, summary: "Claude Code nicht ausführbar",
                                  detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

public struct ProcessOutput: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let status: Int32
}

public enum ProcessRunner {
    public static func run(executable: URL, arguments: [String], input: String, environment: [String: String],
                           workingDirectory: URL, timeout: TimeInterval) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = environment
                process.currentDirectoryURL = workingDirectory
                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: AIError.processFailed("Start fehlgeschlagen: \(error.localizedDescription)"))
                    return
                }
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { outData = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { errData = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                if let data = input.data(using: .utf8), !data.isEmpty {
                    try? stdin.fileHandleForWriting.write(contentsOf: data)
                }
                try? stdin.fileHandleForWriting.close()

                if finished.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    _ = finished.wait(timeout: .now() + 5)
                    continuation.resume(throwing: AIError.timeout)
                    return
                }
                group.wait()
                continuation.resume(returning: ProcessOutput(stdout: outData, stderr: errData, status: process.terminationStatus))
            }
        }
    }
}
