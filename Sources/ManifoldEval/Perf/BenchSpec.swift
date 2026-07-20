import Foundation

/// Errors thrown by ``BenchSpec/GenerationProtocol``'s validated initializer
/// — the perf twin of leet-llm P044's `ProfilingError`: a warmup/timed-run
/// count that can't be run at all is a construction-time error, not a
/// convention a spec author has to remember to honor. Caught here instead of
/// at `PerfRunner`'s `for 0..<count` loop, which would otherwise just run
/// zero timed iterations and report a median of an empty array in silence.
public enum BenchSpecValidationError: Error, CustomStringConvertible, Equatable {
    case invalidWarmupRuns(Int)
    case invalidTimedRuns(Int)

    public var description: String {
        switch self {
        case let .invalidWarmupRuns(value):
            return "warmup_runs must be nonnegative; received \(value)"
        case let .invalidTimedRuns(value):
            return "timed_runs must be positive; received \(value)"
        }
    }
}

/// The declarative unit the perf harness drives: ONE model family measured
/// under ONE generation protocol across N HTTP lanes.
///
/// This is the structural fix for the defect that motivated the harness: three
/// separate Swift bench targets (core, manifold-mlx, manifold-llama) each
/// measured whatever model happened to be loaded locally, so a "core vs MLX"
/// comparison was routinely a 0.5B-vs-4B comparison in disguise. Pinning
/// `modelFamily` + `protocol` once at the spec level, with every lane required
/// to claim the same pin, makes that mistake a collation-time error instead
/// of a silent footgun — see ``BenchResult/specHash`` and ``PerfCollator``'s
/// hard guard.
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

        /// Validates `warmupRuns`/`timedRuns` before storing them — every
        /// `GenerationProtocol` in memory is therefore already known-runnable;
        /// there is no separate "call validate() before use" step to forget.
        public init(
            prompt: String, temperature: Double, maxTokens: Int, warmupRuns: Int, timedRuns: Int
        ) throws {
            try Self.validate(warmupRuns: warmupRuns, timedRuns: timedRuns)
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

        /// Custom `Decodable` conformance (rather than the synthesized one)
        /// so a spec JSON fixture is routed through the same validation as
        /// in-code construction — a hand-edited `perf-spec.json` with
        /// `"timed_runs": 0` fails to decode instead of silently producing
        /// an empty-sample report.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                prompt: try container.decode(String.self, forKey: .prompt),
                temperature: try container.decode(Double.self, forKey: .temperature),
                maxTokens: try container.decode(Int.self, forKey: .maxTokens),
                warmupRuns: try container.decode(Int.self, forKey: .warmupRuns),
                timedRuns: try container.decode(Int.self, forKey: .timedRuns)
            )
        }

        private static func validate(warmupRuns: Int, timedRuns: Int) throws {
            guard warmupRuns >= 0 else {
                throw BenchSpecValidationError.invalidWarmupRuns(warmupRuns)
            }
            guard timedRuns > 0 else {
                throw BenchSpecValidationError.invalidTimedRuns(timedRuns)
            }
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
    /// defines "same **workload**": model family + the generation parameters
    /// that change what gets measured (prompt, temperature, max_tokens).
    /// Deliberately hand-built (not `JSONEncoder`'s output) so key order and
    /// float formatting can never silently vary hash bytes across Foundation
    /// versions.
    ///
    /// `warmupRuns`/`timedRuns` are deliberately EXCLUDED. They are sampling
    /// parameters — how many times the identical workload is measured — not
    /// part of the workload's identity. Hashing them was a landmine: bumping
    /// `timed_runs` from 5 to 10 reps of the exact same prompt/model/protocol
    /// changed `specHash`, so ``PerfCollator``'s hard guard would refuse to
    /// compare the two runs even though they measure the same thing, and any
    /// increase in rep count silently orphaned every prior record. Two specs
    /// differing only in `warmupRuns`/`timedRuns` MUST share a `specHash` —
    /// see `BenchSpecTests.testSpecHashIsStableAcrossRepCounts`.
    public var canonicalHashInput: String {
        [
            "model_family=\(modelFamily)",
            "prompt=\(protocolConfig.prompt)",
            "temperature=\(protocolConfig.temperature)",
            "max_tokens=\(protocolConfig.maxTokens)",
        ].joined(separator: "\n")
    }

    /// Stable hash of `canonicalHashInput` — the value every ``BenchResult``
    /// produced from this spec carries, so a collator can prove a set of
    /// records all came from the same **workload** (model + prompt +
    /// temperature + max_tokens) without re-parsing specs. Two results with
    /// the same `specHash` but different rep counts (`warmupRuns`/`timedRuns`)
    /// are still comparable — see `canonicalHashInput`'s doc comment.
    public var specHash: String { PromptHash.sha256Hex(of: canonicalHashInput) }
}
