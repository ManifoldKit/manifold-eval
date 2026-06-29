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
    /// (the Cohort-A setup). Given that, equal quant is the signal that the same
    /// checkpoint is in play; differing quant drops the pair to same-family
    /// (trend-only); a cloud backend on either side forces `.cloud`.
    ///
    /// Known blind spot: Ollama hides the quant behind `"server"`, so an
    /// Ollama-vs-llama same-GGUF pair (the real Cohort A) reads here as
    /// `.sameFamily`, *under*-claiming. The operator therefore declares the cohort
    /// explicitly on the harness config when they know the weights are pinned;
    /// this classifier is only the fallback when they don't.
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
        // Same quant ⇒ presumed same checkpoint (the operator pinned one GGUF to
        // both). Case-insensitive so "q4_k_m" and "Q4_K_M" match.
        if a.quant.lowercased() == b.quant.lowercased() {
            return .sameWeights
        }
        return .sameFamily
    }
}
