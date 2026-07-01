import Foundation

/// The sampler configuration a backend ran under. Recorded on every ``RawRun`` so
/// a cross-backend comparison can prove the two legs sampled under the *same*
/// settings — an unequal sampler is itself a confound the triage must be able to
/// see, not a hidden variable.
///
/// The field set is the fixed P2 contract (plan §13b component 1). The
/// external-runner flag surface plumbs all five fields — `temperature` / `seed` /
/// `maxTokens` (`--temperature` / `--seed` / `--max-tokens`) from P2.1, and as of
/// a PR #13 follow-up, `topK` / `repeatPenalty` (`--top-k` / `--repeat-penalty`)
/// too, forwarded to the external runner in lockstep with the corresponding
/// manifold-llama-side `manifold-llama-eval` change — see `LlamaRunnerDriver`
/// for the invocation contract. See `OllamaRawDriver` for how the Ollama leg
/// keeps its own recorded value truthful on the wire.
public struct SamplerConfig: Codable, Sendable, Equatable {
    public var temperature: Double
    public var seed: Int
    public var topK: Int
    public var repeatPenalty: Double
    public var maxTokens: Int

    public init(
        temperature: Double = 0,
        seed: Int = 0,
        topK: Int = 0,
        repeatPenalty: Double = 1.0,
        maxTokens: Int = 128
    ) {
        self.temperature = temperature
        self.seed = seed
        self.topK = topK
        self.repeatPenalty = repeatPenalty
        self.maxTokens = maxTokens
    }

    /// Greedy / deterministic-pinned default: `temperature == 0`, no repeat
    /// penalty. This is the only sampler the differential cohort trusts (plan §7
    /// control 2) — it sidesteps Ollama's unreliable seed plumbing by removing the
    /// stochastic step entirely.
    public static let greedy = SamplerConfig()
}

/// The raw output of one backend leg for one prompt, at one repeat index.
///
/// This is the fixed contract every leg emits — the Ollama driver produces it
/// directly; an external runner (manifold-llama, P2.2) emits the identical JSON on
/// stdout. The shape is deliberately frozen: the differential harness only ever
/// reasons over `RawRun`s, never over a backend-specific type, so a new backend
/// joins the comparison by emitting this and nothing else.
///
/// Codable uses the property names verbatim as JSON keys (camelCase) — the keys
/// `promptSha256`, `inputTokenIds`, `outputTokenIds`, `coreCommit`,
/// `toolingVersions`, `repeatIndex`, and the nested `sampler` fields match the
/// contract one-to-one, so no `CodingKeys` mapping is needed.
public struct RawRun: Codable, Sendable, Equatable {
    /// Backend family identity, e.g. `"ollama"` or `"llama.cpp"`.
    public var backend: String
    /// Model identity as the backend names it (Ollama tag, or a GGUF path).
    public var model: String
    /// Quantisation tag, e.g. `"Q4_K_M"` or `"server"` when the backend hides it.
    public var quant: String
    /// SHA-256 (lowercase hex) of the exact prompt STRING bytes fed to the model.
    /// The same-bytes control hinges on this: two legs are only comparable when
    /// these match (plan §7 control 3 — never silent).
    public var promptSha256: String
    /// Token ids as *this backend* tokenised the prompt. Empty (`[]`) means the
    /// backend does not expose tokenisation (the Ollama raw path), which the
    /// triage reads as "tokenizer check unavailable", never as a divergence.
    public var inputTokenIds: [Int]
    /// The generated text.
    public var output: String
    /// Token ids of the generation, when the backend exposes them; else `[]`.
    public var outputTokenIds: [Int]
    public var sampler: SamplerConfig
    /// The ManifoldKit core commit the run was produced against (comparability is
    /// only valid within one core binary — the `Collator`'s guard, reused here).
    public var coreCommit: String
    /// Backend/tooling versions, e.g. `["ollama": "0.30.11"]` — an environment
    /// drift across these can masquerade as a model regression.
    public var toolingVersions: [String: String]
    /// 0-based index within a determinism repeat batch.
    public var repeatIndex: Int

    public init(
        backend: String,
        model: String,
        quant: String,
        promptSha256: String,
        inputTokenIds: [Int],
        output: String,
        outputTokenIds: [Int],
        sampler: SamplerConfig,
        coreCommit: String,
        toolingVersions: [String: String],
        repeatIndex: Int
    ) {
        self.backend = backend
        self.model = model
        self.quant = quant
        self.promptSha256 = promptSha256
        self.inputTokenIds = inputTokenIds
        self.output = output
        self.outputTokenIds = outputTokenIds
        self.sampler = sampler
        self.coreCommit = coreCommit
        self.toolingVersions = toolingVersions
        self.repeatIndex = repeatIndex
    }
}
