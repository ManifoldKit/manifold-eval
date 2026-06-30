import Foundation

/// Renders a ``RegressionOutcome`` to a deterministic `REGRESSION.md`.
///
/// Deterministic for a given outcome (no timestamps, no unsorted map iteration)
/// so the report is diffable across runs — a changed report means a changed
/// verdict, not a changed wall-clock. Mirrors ``DivergenceReport``'s shape.
public enum RegressionReport {

    public static func render(
        _ outcome: RegressionOutcome,
        title: String = "Replay-Regression — REGRESSION"
    ) -> String {
        var out = "# \(title)\n\n"
        out += "Prompt SHA-256: `\(outcome.baseline.promptSha256)`\n\n"

        out += "## Verdict\n\n"
        out += "- verdict: **\(verdictLabel(outcome.verdict))**\n"
        out += "\n> \(verdictGloss(outcome.verdict))\n\n"

        out += renderLeg("Baseline", run: outcome.baseline, score: outcome.baselineScore)
        out += renderLeg("Re-driven", run: outcome.reDriven, score: outcome.reDrivenScore)

        return out
    }

    private static func renderLeg(_ name: String, run: RawRun, score: Double?) -> String {
        var out = "## \(name)\n\n"
        out += "- backend: `\(run.backend)`  model: `\(run.model)`  quant: `\(run.quant)`\n"
        out += "- score: \(score.map { String(format: "%.4f", $0) } ?? "**unscorable**")\n"
        for (key, value) in run.toolingVersions.sorted(by: { $0.key < $1.key }) {
            out += "- tooling `\(key)`: `\(value)`\n"
        }
        out += "- core commit: `\(run.coreCommit)`\n"
        out += "- output: \(fence(run.output))\n\n"
        return out
    }

    private static func verdictLabel(_ verdict: RegressionVerdict) -> String {
        switch verdict {
        case .stable: return "stable"
        case .moved(let delta): return String(format: "moved (delta %+.4f)", delta)
        case .indeterminate: return "indeterminate"
        }
    }

    private static func verdictGloss(_ verdict: RegressionVerdict) -> String {
        switch verdict {
        case .stable:
            return "Scores agree within threshold — the re-quant/re-build did not move the score."
        case .moved(let delta):
            return "Score moved by \(String(format: "%+.4f", delta)) beyond threshold. **Movement is "
                + "not automatically a regression** — a re-quant can legitimately shift output. This "
                + "flags the cell for a human to judge quant drift vs genuine correctness loss."
        case .indeterminate(let reason):
            return "No trustworthy verdict: \(reason). The comparison is invalid until the named "
                + "invariant is satisfied (e.g. the re-drive must reproduce the same prompt bytes)."
        }
    }

    /// Single-line output as inline code; multi-line as a fenced block, so
    /// newlines don't corrupt the Markdown.
    private static func fence(_ text: String) -> String {
        if text.contains("\n") {
            return "\n```\n\(text)\n```"
        }
        return "`\(text)`"
    }
}
