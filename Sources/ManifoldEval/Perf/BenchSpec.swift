import Foundation

/// The declarative unit the perf harness drives: ONE model family measured
/// under ONE generation protocol across N HTTP lanes.
///
/// This is the structural fix for the defect that motivated the harness: three
/// separate Swift bench targets (core, manifold-mlx, manifold-llama) each
/// measured whatever model happened to be loaded locally, so a "core vs MLX"
/// comparison was routinely a 0.5B-vs-4B comparison in disguise. Pinning
/// `modelFamily` + `protocol` once at the spec level, with every lane required
/// to claim the same pin, makes that mistake a decode-time/collation-time
/// error instead of a silent footgun — see ``BenchResult/specHash`` and
/// ``PerfCollator``'s hard guard.
public struct BenchSpec: Codable, Sendable, Equatable {

    /// Logical model identity the spec pins, e.g. `"llama-3.1-8b-instruct"`.
    /// Distinct from each lane's `model` (the lane's own tag/path for that
    /// family) and `quant` (the lane's weight format) — `modelFamily` is what
    /// asserts "these lanes are supposed to be measuring the same model".
    public let modelFamily: String

    public let protocolConfig: GenerationProtocol
    public let lanes: [Lane]

    public init(modelFamily: String, protocolConfig: GenerationProtocol, lanes: [Lane]) {
        self.modelFamily = modelFamily
        self.protocolConfig = protocolConfig
        self.lanes = lanes
    }

    private enum CodingKeys: String, CodingKey {
        case modelFamily = "model_family"
        case protocolConfig = "protocol"
        case lanes
    }

    /// The generation protocol every lane in the spec is measured under.
    /// `Codable` and `Equatable` so it round-trips through the JSON fixture and
    /// feeds ``BenchSpec/canonicalHashInput`` deterministically.
    public struct GenerationProtocol: Codable, Sendable, Equatable {
        public let prompt: String
        public let temperature: Double
        public let maxTokens: Int
        public let warmupRuns: Int
        public let timedRuns: Int

        public init(prompt: String, temperature: Double, maxTokens: Int, warmupRuns: Int, timedRuns: Int) {
            self.prompt = prompt
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.warmupRuns = warmupRuns
            self.timedRuns = timedRuns
        }

        private enum CodingKeys: String, CodingKey {
            case prompt
            case temperature
            case maxTokens = "max_tokens"
            case warmupRuns = "warmup_runs"
            case timedRuns = "timed_runs"
        }
    }

    /// The transports the HTTP driver understands. `RawRepresentable` (not a
    /// closed Swift enum with wire cases beyond these) keeps room for a future
    /// transport without a source break — mirrors `BackendName`'s
    /// extensible-identity precedent in ManifoldKit core.
    public struct Transport: RawRepresentable, Codable, Sendable, Equatable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let httpOpenAI = Transport(rawValue: "http-openai")
        public static let httpOllama = Transport(rawValue: "http-ollama")
    }

    /// One HTTP endpoint to drive: an engine/quant pair reachable at `endpoint`.
    public struct Lane: Codable, Sendable, Equatable {
        public let name: String
        public let transport: Transport
        public let endpoint: String
        public let model: String
        public let quant: String

        /// Name of an environment variable holding a bearer API key, if the
        /// endpoint requires one (e.g. OMLX's `Authorization: Bearer <key>`).
        /// The key itself is never embedded in the spec — specs are checked
        /// into the repo and must never carry a secret value, only a pointer
        /// to where to find one at run time.
        public let apiKeyEnv: String?

        public init(
            name: String,
            transport: Transport,
            endpoint: String,
            model: String,
            quant: String,
            apiKeyEnv: String? = nil
        ) {
            self.name = name
            self.transport = transport
            self.endpoint = endpoint
            self.model = model
            self.quant = quant
            self.apiKeyEnv = apiKeyEnv
        }

        private enum CodingKeys: String, CodingKey {
            case name, transport, endpoint, model, quant
            case apiKeyEnv = "api_key_env"
        }
    }

    /// Canonical string the spec hash is computed over — every field that
    /// defines "same model, same protocol", nothing lane-specific. Deliberately
    /// hand-built (not `JSONEncoder`'s output) so key order and float formatting
    /// can never silently vary hash bytes across Foundation versions.
    public var canonicalHashInput: String {
        [
            "model_family=\(modelFamily)",
            "prompt=\(protocolConfig.prompt)",
            "temperature=\(protocolConfig.temperature)",
            "max_tokens=\(protocolConfig.maxTokens)",
            "warmup_runs=\(protocolConfig.warmupRuns)",
            "timed_runs=\(protocolConfig.timedRuns)",
        ].joined(separator: "\n")
    }

    /// Stable hash of `canonicalHashInput` — the value every ``BenchResult``
    /// produced from this spec carries, so a collator can prove a set of
    /// records all came from the same model+protocol without re-parsing specs.
    public var specHash: String { PromptHash.sha256Hex(of: canonicalHashInput) }
}
