import Foundation

struct PlaygroundCompletionResult {
    let content: String
    let model: String
    let baseURL: String
}

struct PlaygroundInferenceConfig {
    let baseURL: URL
    let apiKey: String
    let model: String
}

enum PlaygroundInferenceError: LocalizedError {
    case missingEndpoint
    case missingAPIKey
    case invalidEndpoint(String)
    case badHTTPStatus(Int, String)
    case emptyCompletion

    var errorDescription: String? {
        switch self {
        case .missingEndpoint:
            return "Set OPENAI_BASE_URL in the MIL .env file, or run zenith up so .zenith-deploy/state.json contains openai_base_url."
        case .missingAPIKey:
            return "Set OPENAI_API_KEY, RUNPOD_ENDPOINT_API_KEY, or MIL_API_KEYS in the MIL .env file."
        case .invalidEndpoint(let value):
            return "Invalid OpenAI base URL: \(value)"
        case .badHTTPStatus(let status, let body):
            return "OpenAI-compatible request failed with HTTP \(status): \(body)"
        case .emptyCompletion:
            return "The model returned no completion text."
        }
    }
}

final class PlaygroundInferenceClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 660
        self.session = URLSession(configuration: configuration)
    }

    func complete(
        prompt: String,
        systemPrompt: String = "You are ZenithOS. Answer directly and keep the response useful.",
        maxTokens: Int = 768,
        temperature: Double = 0.7
    ) async throws -> PlaygroundCompletionResult {
        let config = try PlaygroundInferenceConfigResolver.resolve()
        var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: config.model,
                messages: [
                    ChatMessage(role: "system", content: systemPrompt),
                    ChatMessage(role: "user", content: prompt)
                ],
                maxTokens: maxTokens,
                temperature: temperature
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlaygroundInferenceError.badHTTPStatus(-1, "No HTTP response")
        }

        guard (200..<300).contains(http.statusCode) else {
            throw PlaygroundInferenceError.badHTTPStatus(http.statusCode, sanitizedErrorBody(data, statusCode: http.statusCode))
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw PlaygroundInferenceError.emptyCompletion
        }

        return PlaygroundCompletionResult(
            content: content,
            model: config.model,
            baseURL: config.baseURL.absoluteString
        )
    }

    private func sanitizedErrorBody(_ data: Data, statusCode: Int) -> String {
        if let payload = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data),
           let message = payload.error.message {
            return message
        }
        let raw = String(data: data, encoding: .utf8) ?? "unreadable response body"
        let lowercased = raw.lowercased()
        if statusCode == 502, lowercased.contains("bad gateway") {
            return "RunPod proxy returned 502 Bad Gateway. The pod is running, but vLLM is not reachable behind the exposed port yet. Wait for RunPod Logs to show Ready=1, or open the Pod logs to inspect the vLLM startup error."
        }
        if lowercased.contains("<html") || lowercased.contains("<!doctype") {
            return stripHTML(raw)
        }
        return String(raw.prefix(600))
    }

    private func stripHTML(_ raw: String) -> String {
        let withoutScripts = raw.replacingOccurrences(
            of: "(?is)<(script|style).*?</\\1>",
            with: " ",
            options: .regularExpression
        )
        let withoutTags = withoutScripts.replacingOccurrences(
            of: "(?is)<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let collapsed = withoutTags
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((collapsed.isEmpty ? raw : collapsed).prefix(600))
    }
}

private enum PlaygroundInferenceConfigResolver {
    static func resolve() throws -> PlaygroundInferenceConfig {
        let processEnv = ProcessInfo.processInfo.environment
        let repoRoot = findRepoRoot(processEnv)
        var env = repoRoot.flatMap { loadEnv(processEnv: processEnv, repoRoot: $0) } ?? [:]
        env.merge(processEnv.filter { !$0.value.isEmpty }) { _, processValue in processValue }

        let state = repoRoot.flatMap(loadState)
        let baseURLValue = firstNonEmpty(
            env["OPENAI_BASE_URL"],
            env["ZENITH_OPENAI_BASE_URL"],
            state?.openaiBaseURL,
            endpointBaseURL(from: env["ZENITH_SERVERLESS_ENDPOINT_ID"]),
            endpointBaseURL(from: state?.endpointID)
        )
        guard let baseURLValue else {
            throw PlaygroundInferenceError.missingEndpoint
        }
        guard let baseURL = URL(string: baseURLValue) else {
            throw PlaygroundInferenceError.invalidEndpoint(baseURLValue)
        }

        guard let apiKey = firstNonEmpty(env["OPENAI_API_KEY"], env["RUNPOD_ENDPOINT_API_KEY"], firstCSVValue(env["MIL_API_KEYS"]), env["RUNPOD_API_KEY"]) else {
            throw PlaygroundInferenceError.missingAPIKey
        }

        let model = firstNonEmpty(
            env["OPENAI_MODEL"],
            env["OPENAI_SERVED_MODEL_NAME_OVERRIDE"],
            state?.servedModelName,
            env["INITIAL_SERVED_MODEL_NAME"],
            env["MODEL_NAME"]
        ) ?? "gpt-oss-120b"

        return PlaygroundInferenceConfig(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model
        )
    }

    private static func loadEnv(processEnv: [String: String], repoRoot: URL) -> [String: String] {
        let envPath = processEnv["ZENITH_ENV_FILE"].flatMap(expandedURL) ?? repoRoot.appendingPathComponent(".env")
        return EnvFile.load(at: envPath.path)
    }

    private static func findRepoRoot(_ env: [String: String]) -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            env["ZENITH_REPO_ROOT"].flatMap(expandedURL),
            URL(fileURLWithPath: "repos/zenith-inference/multi-model-inference-layer", relativeTo: home).standardizedFileURL,
            URL(fileURLWithPath: "claude-hub/repos/workspace/zenith-inference/multi-model-inference-layer", relativeTo: home).standardizedFileURL,
            URL(fileURLWithPath: "zenith-inference/multi-model-inference-layer", relativeTo: home).standardizedFileURL
        ].compactMap { $0 }

        return candidates.first { candidate in
            fileManager.fileExists(atPath: candidate.appendingPathComponent(".env").path)
                || fileManager.fileExists(atPath: candidate.appendingPathComponent(".zenith-deploy/state.json").path)
                || fileManager.isExecutableFile(atPath: candidate.appendingPathComponent(".venv/bin/zenith").path)
        }
    }

    private static func loadState(repoRoot: URL) -> ZenithDeploymentState? {
        let stateURL = repoRoot.appendingPathComponent(".zenith-deploy/state.json")
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(ZenithDeploymentState.self, from: data)
    }

    private static func expandedURL(_ value: String) -> URL? {
        let path = NSString(string: value).expandingTildeInPath
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }

    private static func firstCSVValue(_ value: String?) -> String? {
        value?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func endpointBaseURL(from endpointID: String?) -> String? {
        guard let endpointID = firstNonEmpty(endpointID) else { return nil }
        return "https://api.runpod.ai/v2/\(endpointID)/openai/v1"
    }
}

private struct ZenithDeploymentState: Decodable {
    let endpointID: String?
    let openaiBaseURL: String?
    let servedModelName: String?

    enum CodingKeys: String, CodingKey {
        case endpointID = "endpoint_id"
        case openaiBaseURL = "openai_base_url"
        case servedModelName = "served_model_name"
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let maxTokens: Int
    let temperature: Double

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case temperature
    }
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct OpenAIErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError
}
