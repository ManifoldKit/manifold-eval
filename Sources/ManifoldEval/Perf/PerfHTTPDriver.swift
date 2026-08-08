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

  /// Model-load duration in milliseconds, when the transport reports it
  /// (Ollama `load_duration`, nanoseconds → ms). `nil` on OpenAI-compatible
  /// lanes, which have no load-duration field.
  public let loadDurationMs: Double?
  /// Prefill (prompt-processing) tokens/sec. Native on Ollama
  /// (`prompt_eval_count / prompt_eval_duration`); typically `nil` on
  /// OpenAI-compatible lanes that don't expose prompt-eval timing.
  public let prefillTps: Double?
  /// Decode/generation tokens/sec. Native on Ollama (`eval_count /
  /// eval_duration`); derived on OpenAI-compatible as
  /// `tokens / (wallSeconds − ttftSeconds)` so publication can still
  /// split prefill-included wall TPS from pure decode.
  public let generateTps: Double?

  public init(
    ttftMs: Double,
    tokens: Int,
    wallSeconds: Double,
    loadDurationMs: Double? = nil,
    prefillTps: Double? = nil,
    generateTps: Double? = nil
  ) {
    self.ttftMs = ttftMs
    self.tokens = tokens
    self.wallSeconds = wallSeconds
    self.loadDurationMs = loadDurationMs
    self.prefillTps = prefillTps
    self.generateTps = generateTps
  }

  /// `tokens / wallSeconds` — prefill INCLUDED in the denominator (the wall
  /// clock spans request-send to stream-completion, not decode-only time).
  /// This matches the definition the in-process Swift benches this harness
  /// replaces used, so historical numbers stay comparable. Pair with
  /// ``generateTps`` for the decode-only split.
  public var tps: Double { wallSeconds > 0 ? Double(tokens) / wallSeconds : 0 }
}

/// Best-effort provenance for one lane, fetched once outside the timed
/// measurement window — see ``PerfHTTPDriver/fetchProvenance(lane:)``.
public struct LaneProvenance: Sendable, Equatable {
  public let engineVersion: String?
  public let modelDigest: String?

  public init(engineVersion: String?, modelDigest: String?) {
    self.engineVersion = engineVersion
    self.modelDigest = modelDigest
  }
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
  ///
  /// - Parameter keepAliveSeconds: Ollama-only. When non-`nil`, sent as the
  ///   request's `keep_alive` (seconds). `0` forces unload after the request
  ///   completes — the cold-start path uses this to guarantee the *next*
  ///   request reloads weights. OpenAI-compatible lanes ignore the value.
  public func run(
    lane: BenchSpec.Lane,
    protocolConfig: BenchSpec.GenerationProtocol,
    keepAliveSeconds: Int? = nil
  ) async throws -> SingleRunMeasurement {
    switch lane.transport {
    case .httpOpenAI:
      return try await runOpenAI(lane: lane, protocolConfig: protocolConfig)
    case .httpOllama:
      return try await runOllama(
        lane: lane,
        protocolConfig: protocolConfig,
        keepAliveSeconds: keepAliveSeconds
      )
    default:
      throw PerfDriverError.invalidEndpoint("unsupported transport '\(lane.transport.rawValue)'")
    }
  }

  /// Forces an Ollama model out of memory by issuing a tiny generate with
  /// `keep_alive: 0`. No-op for non-Ollama transports. Errors are swallowed
  /// into a soft failure so a stuck unload never aborts a warm-only suite —
  /// the subsequent cold measurement simply won't be cold if unload failed
  /// (its `load_duration` will tell the truth either way).
  public func unloadOllamaModel(lane: BenchSpec.Lane) async {
    guard lane.transport == .httpOllama else { return }
    // Tiny protocol: one token, discard result. keep_alive: 0 unloads after.
    do {
      let tiny = try BenchSpec.GenerationProtocol(
        prompt: ".",
        temperature: 0,
        maxTokens: 1,
        warmupRuns: 0,
        timedRuns: 1
      )
      _ = try await run(lane: lane, protocolConfig: tiny, keepAliveSeconds: 0)
    } catch {
      // Soft: cold-start measurement still runs; load_duration discloses
      // whether the model was actually unloaded.
    }
  }

  // MARK: - http-openai (SSE /v1/chat/completions)

  private func runOpenAI(lane: BenchSpec.Lane, protocolConfig: BenchSpec.GenerationProtocol)
    async throws -> SingleRunMeasurement
  {
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
      guard let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data) else {
        continue
      }
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

    // Decode-only TPS: wall after first token. Prefill split and load
    // duration aren't available on the OpenAI-compat wire; leave nil.
    let decodeSeconds = wallSeconds - (ttftMs / 1_000.0)
    let generateTps: Double? = decodeSeconds > 0 ? Double(tokens) / decodeSeconds : nil

    return SingleRunMeasurement(
      ttftMs: ttftMs,
      tokens: tokens,
      wallSeconds: wallSeconds,
      loadDurationMs: nil,
      prefillTps: nil,
      generateTps: generateTps
    )
  }

  // MARK: - http-ollama (NDJSON /api/generate)

  private func runOllama(
    lane: BenchSpec.Lane,
    protocolConfig: BenchSpec.GenerationProtocol,
    keepAliveSeconds: Int?
  ) async throws -> SingleRunMeasurement {
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
      keepAlive: keepAliveSeconds,
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
    var finalChunk: OllamaGenerateChunk?

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
      guard let chunk = try? JSONDecoder().decode(OllamaGenerateChunk.self, from: data) else {
        continue
      }
      if !chunk.response.isEmpty {
        if firstTokenTime == nil { firstTokenTime = .now() }
        chunkTokenCount += 1
      }
      if chunk.done == true {
        finalChunk = chunk
      }
    }
    let end = DispatchTime.now()

    guard let firstTokenTime else { throw PerfDriverError.noTokensProduced }
    let ttftMs = millis(from: start, to: firstTokenTime)
    let wallSeconds = seconds(from: start, to: end)
    // Ollama's final NDJSON line reports the exact `eval_count` (server-side
    // token counter) — prefer it over the client-side chunk count.
    let tokens = finalChunk?.evalCount ?? chunkTokenCount
    guard tokens > 0 else { throw PerfDriverError.noTokensProduced }

    // Native Ollama timing fields (nanoseconds on the wire). Present on
    // the final `done: true` chunk; earlier partial chunks omit them.
    let loadDurationMs = finalChunk?.loadDuration.map { Double($0) / 1_000_000 }
    let prefillTps = Self.tokensPerSecond(
      count: finalChunk?.promptEvalCount,
      durationNanos: finalChunk?.promptEvalDuration
    )
    let generateTps = Self.tokensPerSecond(
      count: finalChunk?.evalCount,
      durationNanos: finalChunk?.evalDuration
    )

    return SingleRunMeasurement(
      ttftMs: ttftMs,
      tokens: tokens,
      wallSeconds: wallSeconds,
      loadDurationMs: loadDurationMs,
      prefillTps: prefillTps,
      generateTps: generateTps
    )
  }

  /// `count / (durationNanos / 1e9)` — returns `nil` when either side is
  /// missing or non-positive so a caller never publishes a fabricated rate.
  static func tokensPerSecond(count: Int?, durationNanos: Int64?) -> Double? {
    guard let count, count > 0, let durationNanos, durationNanos > 0 else { return nil }
    let seconds = Double(durationNanos) / 1_000_000_000
    return Double(count) / seconds
  }

  // MARK: - Provenance (best-effort, outside the timed window)

  /// Best-effort engine version + model digest for `lane`, fetched once per
  /// lane (never per timed run — a provenance probe must not perturb the
  /// measurement it's describing). Never throws: a probe failure yields
  /// `nil` fields rather than aborting the bench run, since provenance is
  /// descriptive metadata, not a load-bearing measurement.
  public func fetchProvenance(lane: BenchSpec.Lane) async -> LaneProvenance {
    switch lane.transport {
    case .httpOllama:
      async let version = fetchOllamaVersion(lane: lane)
      async let digest = fetchOllamaModelDigest(lane: lane)
      return await LaneProvenance(engineVersion: version, modelDigest: digest)
    default:
      // Generic OpenAI-compatible servers standardize neither a version
      // endpoint nor a weights-digest field — `system_fingerprint` is
      // the closest analog but isn't guaranteed present or stable
      // across implementations, so we deliberately don't fabricate a
      // value here rather than guess.
      return LaneProvenance(engineVersion: nil, modelDigest: nil)
    }
  }

  private func fetchOllamaVersion(lane: BenchSpec.Lane) async -> String? {
    guard let base = URL(string: lane.endpoint) else { return nil }
    let url = base.appendingPathComponent("api/version")
    struct VersionResponse: Decodable { let version: String }
    do {
      let (data, response) = try await session.data(from: url)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        return nil
      }
      return try JSONDecoder().decode(VersionResponse.self, from: data).version
    } catch {
      return nil
    }
  }

  private func fetchOllamaModelDigest(lane: BenchSpec.Lane) async -> String? {
    guard let base = URL(string: lane.endpoint) else { return nil }
    let url = base.appendingPathComponent("api/tags")
    struct TagsResponse: Decodable {
      struct ModelEntry: Decodable {
        let name: String
        let digest: String?
      }
      let models: [ModelEntry]
    }
    do {
      let (data, response) = try await session.data(from: url)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        return nil
      }
      let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
      // Tags may list either the exact lane model or a bare/alias form
      // (e.g. "llama3.1:8b" vs "llama3.1:8b-instruct-q4_K_M"). Exact
      // match first, then a prefix match on the tag before ':'.
      if let exact = decoded.models.first(where: { $0.name == lane.model })?.digest {
        return exact
      }
      return decoded.models.first { $0.name.hasPrefix(lane.model) }?.digest
    } catch {
      return nil
    }
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

    struct Message: Encodable {
      let role: String
      let content: String
    }
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
    /// Seconds. `0` unloads after the request. Omitted when `nil` so the
    /// server uses its default (typically 5 minutes).
    let keepAlive: Int?
    let options: Options

    struct Options: Encodable {
      let temperature: Double
      let numPredict: Int
      enum CodingKeys: String, CodingKey {
        case temperature
        case numPredict = "num_predict"
      }
    }

    enum CodingKeys: String, CodingKey {
      case model, prompt, stream, options
      case keepAlive = "keep_alive"
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(model, forKey: .model)
      try container.encode(prompt, forKey: .prompt)
      try container.encode(stream, forKey: .stream)
      try container.encode(options, forKey: .options)
      // Encode only when set — Ollama's default keep_alive must remain
      // the server default when the harness isn't forcing unload.
      try container.encodeIfPresent(keepAlive, forKey: .keepAlive)
    }
  }

  /// Final (and partial) NDJSON chunks from `/api/generate`. Timing fields
  /// are only populated on the terminal `done: true` chunk.
  struct OllamaGenerateChunk: Decodable {
    let response: String
    let done: Bool?
    let evalCount: Int?
    let evalDuration: Int64?
    let promptEvalCount: Int?
    let promptEvalDuration: Int64?
    let loadDuration: Int64?
    let totalDuration: Int64?

    enum CodingKeys: String, CodingKey {
      case response, done
      case evalCount = "eval_count"
      case evalDuration = "eval_duration"
      case promptEvalCount = "prompt_eval_count"
      case promptEvalDuration = "prompt_eval_duration"
      case loadDuration = "load_duration"
      case totalDuration = "total_duration"
    }
  }
}
