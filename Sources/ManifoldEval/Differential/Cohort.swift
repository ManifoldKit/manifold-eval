import Foundation

/// Which differential cohort a pair of runs belongs to. The cohort determines how
/// load-bearing a divergence is (plan §7) — only same-weights divergence is a
/// strong oracle; the others are weaker signals or none at all.
public enum Cohort: String, Sendable, Equatable, Codable {
    /// Identical GGUF pinned to both backends (Ollama `FROM ./x.gguf` + the same
    /// file in manifold-llama). Quant + checkpoint are held constant, so residual
    /// divergence is renderer / sampler / runtime → investigable. The only strong
    /// oracle.
    case sameWeights
    /// Same model family, different runtime/quant (GGUF vs MLX 4-bit). Compare
    /// *trends within a backend over time*, never absolute cross-backend deltas.
    case sameFamily
    /// A cloud / network backend. Absolute score only — nondeterministic and over
    /// the wire, never a differential oracle.
    case cloud
}

extension Cohort {
    /// Backends treated as cloud (absolute-only). Lowercased substring match so
    /// `"anthropic-claude"` / `"openai-responses"` etc. all classify. Conservative
    /// and overridable — a backend not listed is assumed local.
    public static let defaultCloudBackends: Set<String> = [
        "anthropic", "openai", "claude", "gpt", "gemini", "xai", "groq",
        "mistral-api", "openrouter", "cloud", "saas", "anylanguagemodel",
    ]

    /// Classify a pair of runs into a cohort.
    ///
    /// This is a *heuristic over what the runs report*, not a guarantee: actually
    /// pinning the identical GGUF to both backends is the harness operator's job
    /// (the Cohort-A setup). `.sameWeights` requires BOTH the model identity AND the
    /// quant to match — equal quant *alone* is far too weak, because Ollama hides its
    /// quant behind the constant `"server"`, so two unrelated Ollama models would
    /// otherwise both report `quant == "server"` and be falsely fused into the only
    /// strong oracle. Differing quant (or model) drops the pair to same-family
    /// (trend-only); a cloud backend on either side forces `.cloud`.
    ///
    /// Known consequence: because Ollama reports `model` as a tag and a llama runner
    /// reports it as a GGUF path, a *real* Ollama-vs-llama same-GGUF pair (Cohort A)
    /// will NOT match on `model` here and reads as `.sameFamily`, *under*-claiming.
    /// That is intentional — over-claiming `.sameWeights` is the dangerous error. The
    /// operator declares the cohort explicitly (`cohortOverride`) when they know the
    /// weights are pinned; this classifier is only the fallback when they don't.
    public static func classify(
        _ a: RawRun,
        _ b: RawRun,
        cloudBackends: Set<String> = defaultCloudBackends
    ) -> Cohort {
        func isCloud(_ backend: String) -> Bool {
            let lowered = backend.lowercased()
            return cloudBackends.contains { lowered.contains($0) }
        }
        if isCloud(a.backend) || isCloud(b.backend) {
            return .cloud
        }
        // Same model AND same quant ⇒ presumed same checkpoint. Both required:
        // quant alone over-claims (Ollama's "server" sentinel). Case-insensitive so
        // "q4_k_m" / "Q4_K_M" and tag-case differences match.
        let sameModel = a.model.lowercased() == b.model.lowercased()
        let sameQuant = a.quant.lowercased() == b.quant.lowercased()
        if sameModel && sameQuant {
            return .sameWeights
        }
        return .sameFamily
    }
}
