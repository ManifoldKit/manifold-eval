import Foundation

/// Renders a ``DifferentialOutcome`` to a deterministic `DIVERGENCE.md`.
///
/// Deterministic for a given outcome (no timestamps, no map iteration without a
/// sort) so the report is diffable across runs — a changed report means changed
/// behaviour, not changed wall-clock.
public enum DivergenceReport {

    public static func render(_ outcome: DifferentialOutcome, title: String = "Differential Eval — DIVERGENCE") -> String {
        var out = "# \(title)\n\n"
        out += "Prompt SHA-256: `\(outcome.promptSha256)`\n\n"

        out += renderDeterminism(outcome.ollama, legName: "Ollama")
        if let llama = outcome.llama {
            out += renderDeterminism(llama, legName: "External runner")
        }

        if let comparison = outcome.comparison {
            out += renderComparison(comparison)
        } else {
            out += "## Comparison\n\n"
            out += "_No second leg — Ollama-only run. This is a determinism control; "
            out += "cross-backend triage requires an external `--llama-runner`._\n\n"
        }

        return out
    }

    private static func renderDeterminism(_ report: DeterminismReport, legName: String) -> String {
        var out = "## \(legName) determinism\n\n"
        let backend = report.backend ?? "?"
        let model = report.representative?.model ?? "?"
        out += "- backend: `\(backend)`  model: `\(model)`\n"
        out += "- repeats: \(report.repeatCount)\n"
        if !report.wasAssessed {
            out += "- determinism: **not assessed** (need >= 2 repeats)\n"
        } else if report.isDeterministic {
            out += "- determinism: **stable** (all \(report.repeatCount) repeats identical)\n"
        } else {
            out += "- determinism: **VARIANT** — \(report.distinctOutputs.count) distinct outputs across "
            out += "\(report.repeatCount) repeats (sampler nondeterminism / cold-load outlier)\n"
        }
        // Show each distinct output so a human can eyeball the variance — the
        // transcript spot-check the plan insists stays in the loop (§9).
        for (index, output) in report.distinctOutputs.enumerated() {
            out += "  - output #\(index): \(fence(output))\n"
        }
        out += "\n"
        return out
    }

    private static func renderComparison(_ record: DifferentialRecord) -> String {
        var out = "## Comparison\n\n"
        out += "- cohort: **\(record.cohort.rawValue)**\n"
        out += "- verdict: **\(record.divergence.rawValue)**\n"
        if let bos = record.detectedBOS {
            out += "- detected BOS id (token-stream asymmetry): `\(bos)`\n"
        }
        out += "\n> \(verdictGloss(record.divergence))\n\n"
        return out
    }

    private static func verdictGloss(_ divergence: Divergence) -> String {
        switch divergence {
        case .identical:
            return "Same prompt, same output — no divergence."
        case .promptDivergence:
            return "**Prompt hashes differ — the same-bytes control FAILED.** The comparison is "
                + "invalid (harness/render bug, not a model finding). Fix the control before trusting any verdict."
        case .samplerNondeterminism:
            return "Outputs differ but a backend is non-reproducible across its own repeats — the "
                + "difference is sampler noise, not signal."
        case .tokenizerDivergence:
            return "Same prompt string, but the input token streams differ after BOS normalisation — a "
                + "vocab/tokenisation mismatch fed the model different inputs."
        case .genuineDivergence:
            return "Same prompt, both backends reproducible, same input tokens — outputs still differ. "
                + "**Genuine divergence: worth a human.**"
        }
    }

    /// Render output text safely inside the report — single-line as inline code,
    /// multi-line as a fenced block, so newlines don't corrupt the Markdown.
    private static func fence(_ text: String) -> String {
        if text.contains("\n") {
            return "\n```\n\(text)\n```"
        }
        return "`\(text)`"
    }
}
