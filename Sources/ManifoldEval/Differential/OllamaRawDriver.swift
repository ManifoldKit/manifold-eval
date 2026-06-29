import Foundation

/// Drives Ollama's raw-prompt completion path and emits a ``RawRun``.
///
/// `raw: true` bypasses Ollama's own template (verified 2026-06-29, Ollama
/// 0.30.11): the prompt string is fed to the model unmodified and with **no**
/// special tokens added. That is the half of the same-bytes control Ollama owns —
/// the harness renders the prompt once and injects it here, so Ollama's Go
/// `Modelfile` Jinja engine never gets a vote.
///
/// Ollama's `/api/generate` returns no token ids (only a `prompt_eval_count`), so
/// `inputTokenIds` / `outputTokenIds` are `[]` — which the triage reads as
/// "tokenizer check unavailable", never a divergence.
public struct OllamaRawDriver: Sendable {
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
    /// didn't use. `topK` is sent only when positive (Ollama treats 0 as "off",
    /// which differs from "unset"). `temperature` / `seed` / `num_predict` follow
    /// the contract's documented options.
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

        // Greedy temp=0 makes seed/topK moot for the argmax, but repeat_penalty
        // still shifts logits, so it stays in play — hence recorded + sent.
        let options = GenerateRequest.Options(
            temperature: sampler.temperature,
            seed: sampler.seed,
            numPredict: sampler.maxTokens,
            repeatPenalty: sampler.repeatPenalty,
            topK: sampler.topK > 0 ? sampler.topK : nil
        )
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

    // MARK: - Wire types

    struct GenerateRequest: Encodable {
        let model: String
        let prompt: String
        let raw: Bool
        let stream: Bool
        let options: Options

        struct Options: Encodable {
            let temperature: Double
            let seed: Int
            let numPredict: Int
            let repeatPenalty: Double
            let topK: Int?

            enum CodingKeys: String, CodingKey {
                case temperature
                case seed
                case numPredict = "num_predict"
                case repeatPenalty = "repeat_penalty"
                case topK = "top_k"
            }
        }
    }

    struct GenerateResponse: Decodable {
        let response: String
    }
}
