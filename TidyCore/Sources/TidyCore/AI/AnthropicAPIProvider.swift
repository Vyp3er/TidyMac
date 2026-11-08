import Foundation

/// Optional: direct Messages API with an Anthropic API key (billed per token to that key).
public final class AnthropicAPIProvider: AIProvider, @unchecked Sendable {
    public let apiKey: String
    public let model: String
    let session: URLSession
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")
    static let apiVersion = "2026-10-21"

    public var displayName: String { "Anthropic API (\(model))" }
    public var maxConcurrentRequests: Int { 4 }

    public static let models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]

    /// USD per million tokens (input, output), for the cost estimate in the UI.
    static let prices: [String: (Double, Double)] = [
        "claude-opus-5-5": (4, 20), "claude-sonnet-5-5": (2, 10), "claude-haiku-5-5": (0.10, 0.50),
    ]

    public init(apiKey: String, model: String = "claude-opus-5-5", session: URLSession = .shared) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.isEmpty ? "claude-opus-5-5" : model
        self.session = session
    }

    /// Server-side refusal fallback is available for these models on the Claude API.
    var supportsFallback: Bool {
        ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-opus-5"].contains(model)
    }

    func makeRequest(_ request: AIRequest) throws -> URLRequest {
        guard let endpoint = Self.endpoint else { throw AIError.notConfigured("Ungültige API-URL") }
        guard !apiKey.isEmpty else { throw AIError.notConfigured("Kein API-Key hinterlegt") }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": PromptBuilder.systemPrompt,
            "messages": [["role": "user", "content": PromptBuilder.userMessage(for: request)]],
            "output_config": [
                "format": ["type": "json_schema", "schema": PromptBuilder.outputSchema],
                "effort": "low",
            ],
        ]
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if supportsFallback {
            body["fallbacks"] = "default"
            urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    public func suggest(_ request: AIRequest) async throws -> AIResponse {
        let urlRequest = try makeRequest(request)
        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse("keine HTTP-Antwort") }
            if http.statusCode == 200 { return try parse(data) }
            let retryable = http.statusCode == 429 || http.statusCode == 529 || http.statusCode >= 500
            if retryable && attempt < 4 {
                let retryAfter = Double(http.value(forHTTPHeaderField: "retry-after") ?? "") ?? pow(2, Double(attempt))
                try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 30) * 1_000_000_000))
                continue
            }
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw AIError.http(http.statusCode, message)
        }
    }

    func parse(_ data: Data) throws -> AIResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse("kein JSON")
        }
        let stop = json["stop_reason"] as? String
        if stop == "refusal" { throw AIError.refused }
        if stop == "max_tokens" { throw AIError.invalidResponse("Antwort abgeschnitten (max_tokens)") }
        let content = json["content"] as? [[String: Any]] ?? []
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        let items = try AIResponseParser.parse(text: text)
        let usage = json["usage"] as? [String: Any] ?? [:]
        let input = (usage["input_tokens"] as? Int ?? 0) + (usage["cache_read_input_tokens"] as? Int ?? 0)
            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
        let output = usage["output_tokens"] as? Int ?? 0
        let price = Self.prices[json["model"] as? String ?? model] ?? Self.prices[model] ?? (0, 0)
        let cost = Double(input) / 1_000_000 * price.0 + Double(output) / 1_000_000 * price.1
        return AIResponse(items: items, inputTokens: input, outputTokens: output, costUSD: cost)
    }

    public func checkAvailability() async -> AIAvailability {
        guard !apiKey.isEmpty else { return AIAvailability(isAvailable: false, summary: "Kein API-Key hinterlegt") }
        guard let url = URL(string: "https://api.anthropic.com/v1/models/\(model)") else {
            return AIAvailability(isAvailable: false, summary: "Ungültiges Modell")
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return AIAvailability(isAvailable: true, summary: "API-Key gültig (\(model))", detail: "Abrechnung pro Token über die Anthropic Console.") }
            return AIAvailability(isAvailable: false, summary: "API antwortet mit Status \(code)")
        } catch {
            return AIAvailability(isAvailable: false, summary: "API nicht erreichbar", detail: error.localizedDescription)
        }
    }
}
