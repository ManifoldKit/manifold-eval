import Foundation

/// A backend leg that produces one ``RawRun`` per (prompt, repeat-index). The
/// abstraction the differential harness drives for its "raw" leg, so the harness
/// can be exercised against a fake producer in tests without a live Ollama.
public protocol RawRunProducer: Sendable {
    func run(
        model: String,
        prompt: String,
        sampler: SamplerConfig,
        repeatIndex: Int
    ) async throws -> RawRun
}

/// Drives Ollama's raw-prompt completion path and emits a ``RawRun``.
///
/// `raw: true` bypasses Ollama's own template (verified 2026-06-29, Ollama
/// 0.30.11): the prompt string is fed to the model unmodified and with **no**
/// special tokens added. That is the half of the same-bytes control Ollama owns —
/// the harness renders the prompt once and injects it here, so Ollama's Go
/// `Modelfile` Jinja engine never gets a vote.
///
/// **`raw: true` does NOT bypass a model-baked `PARAMETER stop`.** Verified live
/// 2026-07-01 (Ollama 0.30.11): a model created with `PARAMETER stop "France"`
/// truncated a `raw: true` generation to a single token even though templating
/// was skipped — `raw` only elides the Jinja template, not the `stop` generation
/// parameter baked into the model's Modelfile. A GGUF imported via a bare
/// `ollama create <name> -f <(echo "FROM <gguf>")` CAN come out with an
/// auto-populated stop list depending on how Ollama parses the GGUF's embedded
/// chat template. So every request explicitly sends `"stop": []`, which
/// confirmed-empirically neutralises a baked stop list — no model-implicit
/// stop sequence can silently truncate one leg relative to the other.
///
/// Ollama's `/api/generate` returns no token ids (only a `prompt_eval_count`), so
/// `inputTokenIds` / `outputTokenIds` are `[]` — which the triage reads as
/// "tokenizer check unavailable", never a divergence.
public struct OllamaRawDriver: RawRunProducer, Sendable {
    public let baseURL: URL
    public let session: URLSession
    public let coreCommit: String
    public let toolingVersions: [String: String]

    /// - Parameters:
    ///   - baseURL: e.g. `http://localhost:11434`. No default — the URL is built
    ///     by the caller so a malformed string is handled there, not force-unwrapped.
    public init(
        baseURL: URL,
        session: URLSession = .shared,
        coreCommit: String = "unknown",
        toolingVersions: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.session = session
        self.coreCommit = coreCommit
        self.toolingVersions = toolingVersions
    }

    /// One raw completion → one ``RawRun``.
    ///
    /// `repeatPenalty` is sent explicitly so the recorded sampler is *truthful*:
    /// Ollama's own default is 1.1, so omitting it would record a value the run
    /// didn't use. `topK` is likewise **always** sent explicitly — verified live
    /// against Ollama 0.30.11 (2026-07-01): omitting `top_k` from the request
    /// body is NOT equivalent to sending `0`. Omitted, the server falls back to
    /// its own undocumented default (empirically ~40, a real restriction);
    /// explicit `0` genuinely disables top-k filtering (confirmed at temp=0.8 —
    /// omitted vs `0` produced different completions from the same seed, and
    /// explicit `1` forced near-greedy output as expected). The previous code
    /// (`topK: sampler.topK > 0 ? sampler.topK : nil`) omitted the field whenever
    /// `sampler.topK <= 0`, so the *recorded* `SamplerConfig.topK == 0` silently
    /// lied about the wire behaviour — the harness recorded "matching, disabled
    /// top-k" on both legs while Ollama was actually sampling under its own
    /// default restriction. At `temperature == 0` (the only mode this
    /// differential currently trusts) top-k is moot either way — greedy argmax
    /// is invariant to top-k for any k >= 1 — so this specific bug does not
    /// explain a temp=0 divergence, but it is a real confound the moment a
    /// caller runs at temp > 0 or explicitly requests `--top-k 0` to force-match
    /// the llama.cpp leg's genuinely-disabled top-k. `temperature` / `seed` /
    /// `num_predict` follow the contract's documented options.
    public func run(
        model: String,
        prompt: String,
        sampler: SamplerConfig,
        repeatIndex: Int
    ) async throws -> RawRun {
        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let options = Self.makeOptions(from: sampler)
        let payload = GenerateRequest(model: model, prompt: prompt, raw: true, stream: false, options: options)
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw DifferentialError.ollamaRequestFailed(reason: "encoding request: \(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DifferentialError.ollamaRequestFailed(reason: "\(error)")
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw DifferentialError.ollamaHTTPStatus(code: http.statusCode, body: body)
        }

        let decoded: GenerateResponse
        do {
            decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        } catch {
            throw DifferentialError.ollamaDecodeFailed(reason: "\(error)")
        }

        return RawRun(
            backend: "ollama",
            model: model,
            quant: "server",
            promptSha256: PromptHash.sha256Hex(of: prompt),
            inputTokenIds: [],
            output: decoded.response,
            outputTokenIds: [],
            sampler: sampler,
            coreCommit: coreCommit,
            toolingVersions: toolingVersions,
            repeatIndex: repeatIndex
        )
    }

    /// The Ollama server version (for `toolingVersions`), via `/api/version`.
    public func serverVersion() async throws -> String {
        let url = baseURL.appendingPathComponent("api/version")
        let data: Data
        do {
            (data, _) = try await session.data(from: url)
        } catch {
            throw DifferentialError.ollamaRequestFailed(reason: "version: \(error)")
        }
        struct VersionResponse: Decodable { let version: String }
        do {
            return try JSONDecoder().decode(VersionResponse.self, from: data).version
        } catch {
            throw DifferentialError.ollamaDecodeFailed(reason: "version: \(error)")
        }
    }

    // MARK: - Wire building (pure, unit-testable without a live Ollama)

    /// Builds the request `options` from a ``SamplerConfig``. Extracted from
    /// ``run(model:prompt:sampler:repeatIndex:)`` so the always-explicit wire
    /// encoding (never omitting `topK`, always zeroing `stop`) is directly
    /// unit-testable — greedy temp=0 makes seed/topK moot for the argmax, but
    /// repeat_penalty still shifts logits so it stays in play, and topK/stop
    /// both matter the moment a caller runs at temp > 0 (see the doc comments
    /// above the type and `run`).
    static func makeOptions(from sampler: SamplerConfig) -> GenerateRequest.Options {
        GenerateRequest.Options(
            temperature: sampler.temperature,
            seed: sampler.seed,
            numPredict: sampler.maxTokens,
            repeatPenalty: sampler.repeatPenalty,
            topK: sampler.topK,
            stop: []
        )
    }

    // MARK: - Wire types

    struct GenerateRequest: Encodable {
        let model: String
        let prompt: String
        let raw: Bool
        let stream: Bool
        let options: Options

        struct Options: Encodable, Equatable {
            let temperature: Double
            let seed: Int
            let numPredict: Int
            let repeatPenalty: Double
            let topK: Int
            let stop: [String]

            enum CodingKeys: String, CodingKey {
                case temperature
                case seed
                case numPredict = "num_predict"
                case repeatPenalty = "repeat_penalty"
                case topK = "top_k"
                case stop
            }
        }
    }

    struct GenerateResponse: Decodable {
        let response: String
    }
}
