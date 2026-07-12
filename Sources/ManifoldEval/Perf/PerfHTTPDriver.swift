import Foundation

/// Failures from driving a lane's HTTP endpoint.
public enum PerfDriverError: Error, CustomStringConvertible, Equatable {
    case invalidEndpoint(String)
    case requestFailed(reason: String)
    case httpStatus(code: Int, body: String)
    case noTokensProduced

    public var description: String {
        switch self {
        case .invalidEndpoint(let endpoint):
            return "invalid lane endpoint: '\(endpoint)'"
        case .requestFailed(let reason):
            return "request failed: \(reason)"
        case .httpStatus(let code, let body):
            return "HTTP \(code): \(body.prefix(500))"
        case .noTokensProduced:
            return "stream completed with zero tokens — cannot compute TTFT/TPS"
        }
    }
}

/// One timed run's raw measurement, before it's folded into a
/// ``BenchResult``'s per-run arrays.
public struct SingleRunMeasurement: Sendable, Equatable {
    public let ttftMs: Double
    public let tokens: Int
    public let wallSeconds: Double

    public init(ttftMs: Double, tokens: Int, wallSeconds: Double) {
        self.ttftMs = ttftMs
        self.tokens = tokens
        self.wallSeconds = wallSeconds
    }

    /// `tokens / wallSeconds` — prefill INCLUDED in the denominator (the wall
    /// clock spans request-send to stream-completion, not decode-only time).
    /// This matches the definition the in-process Swift benches this harness
    /// replaces used, so historical numbers stay comparable.
    public var tps: Double { wallSeconds > 0 ? Double(tokens) / wallSeconds : 0 }
}

/// A single Swift HTTP client that drives BOTH `http-openai` and `http-ollama`
/// lanes with the same instrumentation points (request-send timestamp,
/// first-content-byte timestamp, stream-completion timestamp).
///
/// Why one client for both transports rather than reusing `ManifoldOllama`'s
/// `OllamaBackend` for the ollama lane: TTFT is only comparable across lanes if
/// it's measured at the same point in each transport's plumbing. Driving the
/// ollama lane through a different abstraction (`InferenceService` + its
/// generation-queue/tool-dispatch machinery) than the openai lane would put
/// unrelated overhead into one leg's TTFT and not the other's — undermining
/// the apples-to-apples goal that is this harness's entire premise. A thin,
/// symmetric client with no intermediate queueing is the simplest way to keep
/// both legs' timestamps meaning the same thing.
public struct PerfHTTPDriver: Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Runs one request against `lane` under `protocolConfig` and returns its
    /// timing. Callers are responsible for serializing lane runs — see
    /// ``PerfRunner`` — this method does no waiting/locking of its own.
    public func run(lane: BenchSpec.Lane, protocolConfig: BenchSpec.GenerationProtocol) async throws -> SingleRunMeasurement {
        switch lane.transport {
        case .httpOpenAI:
            return try await runOpenAI(lane: lane, protocolConfig: protocolConfig)
        case .httpOllama:
            return try await runOllama(lane: lane, protocolConfig: protocolConfig)
        default:
            throw PerfDriverError.invalidEndpoint("unsupported transport '\(lane.transport.rawValue)'")
        }
    }

    // MARK: - http-openai (SSE /v1/chat/completions)

    private func runOpenAI(lane: BenchSpec.Lane, protocolConfig: BenchSpec.GenerationProtocol) async throws -> SingleRunMeasurement {
        guard let base = URL(string: lane.endpoint) else {
            throw PerfDriverError.invalidEndpoint(lane.endpoint)
        }
        let url = base.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKeyEnv = lane.apiKeyEnv, let key = ProcessInfo.processInfo.environment[apiKeyEnv] {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let body = ChatCompletionRequest(
            model: lane.model,
            messages: [.init(role: "user", content: protocolConfig.prompt)],
            temperature: protocolConfig.temperature,
            maxTokens: protocolConfig.maxTokens,
            stream: true,
            streamOptions: .init(includeUsage: true)
        )
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw PerfDriverError.requestFailed(reason: "encoding request: \(error)")
        }

        let start = DispatchTime.now()
        var firstTokenTime: DispatchTime?
        var chunkTokenCount = 0
        var usageCompletionTokens: Int?

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw PerfDriverError.requestFailed(reason: "\(error)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw PerfDriverError.httpStatus(code: http.statusCode, body: body)
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            guard let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data) else { continue }
            if let usage = chunk.usage?.completionTokens {
                usageCompletionTokens = usage
            }
            if let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty {
                if firstTokenTime == nil { firstTokenTime = .now() }
                chunkTokenCount += 1
            }
        }
        let end = DispatchTime.now()

        guard let firstTokenTime else { throw PerfDriverError.noTokensProduced }
        let ttftMs = millis(from: start, to: firstTokenTime)
        let wallSeconds = seconds(from: start, to: end)
        // Prefer the server-reported completion-token count (exact) when the
        // endpoint honored `stream_options.include_usage`; otherwise fall back
        // to counting non-empty delta chunks (an approximation — documented in
        // the report caveats, since some servers may batch >1 token per chunk).
        let tokens = usageCompletionTokens ?? chunkTokenCount
        guard tokens > 0 else { throw PerfDriverError.noTokensProduced }
        return SingleRunMeasurement(ttftMs: ttftMs, tokens: tokens, wallSeconds: wallSeconds)
    }

    // MARK: - http-ollama (NDJSON /api/generate)

    private func runOllama(lane: BenchSpec.Lane, protocolConfig: BenchSpec.GenerationProtocol) async throws -> SingleRunMeasurement {
        guard let base = URL(string: lane.endpoint) else {
            throw PerfDriverError.invalidEndpoint(lane.endpoint)
        }
        let url = base.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKeyEnv = lane.apiKeyEnv, let key = ProcessInfo.processInfo.environment[apiKeyEnv] {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let body = OllamaGenerateRequest(
            model: lane.model,
            prompt: protocolConfig.prompt,
            stream: true,
            options: .init(temperature: protocolConfig.temperature, numPredict: protocolConfig.maxTokens)
        )
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw PerfDriverError.requestFailed(reason: "encoding request: \(error)")
        }

        let start = DispatchTime.now()
        var firstTokenTime: DispatchTime?
        var chunkTokenCount = 0
        var evalCount: Int?

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw PerfDriverError.requestFailed(reason: "\(error)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw PerfDriverError.httpStatus(code: http.statusCode, body: body)
        }

        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8) else { continue }
            guard let chunk = try? JSONDecoder().decode(OllamaGenerateChunk.self, from: data) else { continue }
            if !chunk.response.isEmpty {
                if firstTokenTime == nil { firstTokenTime = .now() }
                chunkTokenCount += 1
            }
            if chunk.done == true {
                evalCount = chunk.evalCount
            }
        }
        let end = DispatchTime.now()

        guard let firstTokenTime else { throw PerfDriverError.noTokensProduced }
        let ttftMs = millis(from: start, to: firstTokenTime)
        let wallSeconds = seconds(from: start, to: end)
        // Ollama's final NDJSON line reports the exact `eval_count` (server-side
        // token counter) — prefer it over the client-side chunk count.
        let tokens = evalCount ?? chunkTokenCount
        guard tokens > 0 else { throw PerfDriverError.noTokensProduced }
        return SingleRunMeasurement(ttftMs: ttftMs, tokens: tokens, wallSeconds: wallSeconds)
    }

    // MARK: - Timing helpers

    private func millis(from start: DispatchTime, to end: DispatchTime) -> Double {
        Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private func seconds(from start: DispatchTime, to end: DispatchTime) -> Double {
        Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: - Wire types (OpenAI-compatible)

    struct ChatCompletionRequest: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int
        let stream: Bool
        let streamOptions: StreamOptions

        struct Message: Encodable { let role: String; let content: String }
        struct StreamOptions: Encodable {
            let includeUsage: Bool
            enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
        }

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case maxTokens = "max_tokens"
            case streamOptions = "stream_options"
        }
    }

    struct ChatCompletionChunk: Decodable {
        let choices: [Choice]?
        let usage: Usage?

        struct Choice: Decodable { let delta: Delta? }
        struct Delta: Decodable { let content: String? }
        struct Usage: Decodable {
            let completionTokens: Int?
            enum CodingKeys: String, CodingKey { case completionTokens = "completion_tokens" }
        }
    }

    // MARK: - Wire types (Ollama)

    struct OllamaGenerateRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
        let options: Options

        struct Options: Encodable {
            let temperature: Double
            let numPredict: Int
            enum CodingKeys: String, CodingKey {
                case temperature
                case numPredict = "num_predict"
            }
        }
    }

    struct OllamaGenerateChunk: Decodable {
        let response: String
        let done: Bool?
        let evalCount: Int?
        enum CodingKeys: String, CodingKey {
            case response, done
            case evalCount = "eval_count"
        }
    }
}
