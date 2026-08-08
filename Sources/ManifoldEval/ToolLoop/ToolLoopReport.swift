import Foundation

/// Deterministic Markdown rendering for a tool-loop lane result — same
/// conventions as the other lanes: byte-stable output for identical input,
/// holes and determinism failures rendered as first-class diagnostics rather
/// than folded into an aggregate.
public enum ToolLoopReport {

  public static func render(
    result: ToolLoopLane.LaneResult,
    title: String,
    corpusLabel: String
  ) -> String {
    var lines: [String] = []
    lines.append("# Tool-Loop Conformance — \(title)")
    lines.append("")
    lines.append("Corpus: \(corpusLabel) (\(result.total) case(s))")
    lines.append("")
    lines.append(
      "Scores tool-result **threading** across turns: `first call` = turn-1 tool/argument"
        + " correctness, `chained arg` = a later call carries a sentinel that exists only in an"
        + " earlier tool result, `final answer` = result sentinels surface in the answer text."
        + " A case passes only when every repeat passes every specified axis; `—` = axis not"
        + " probed by that case."
    )
    lines.append("")
    lines.append(
      "| Case | First call | Chained arg | Final answer | Repeats | Determinism | Verdict |")
    lines.append(
      "|------|-----------|-------------|--------------|---------|-------------|---------|")

    for caseResult in result.caseResults {
      let erroredSuffix =
        caseResult.erroredRepeats > 0
        ? " (+\(caseResult.erroredRepeats) errored)"
        : ""
      if caseResult.missing {
        lines.append(
          "| `\(caseResult.caseID)` | — | — | — | 0\(erroredSuffix) | — | ⚠ not measured |"
        )
        continue
      }
      let repeats = caseResult.repeats
      let determinism =
        repeats.count > 1
        ? (caseResult.deterministic ? "identical" : "**VARIANT**")
        : "n/a (1 repeat)"
      lines.append(
        "| `\(caseResult.caseID)` "
          + "| \(axisCell(repeats.map(\.firstCallOK))) "
          + "| \(axisCell(repeats.map(\.chainedOK))) "
          + "| \(axisCell(repeats.map(\.answerOK))) "
          + "| \(repeats.count)\(erroredSuffix) "
          + "| \(determinism) "
          + "| \(caseResult.passed ? "✓ pass" : "✗ fail") |"
      )
    }

    lines.append("")
    lines.append("## Summary")
    lines.append("")
    // The denominator is MEASURED cases: a hole beside the rate, never
    // inside it.
    lines.append("- Passed: **\(result.passed)/\(result.measured)** measured case(s)")
    if result.missing > 0 {
      lines.append(
        "- ⚠ \(result.missing) of \(result.total) case(s) not measured (no transcript, or"
          + " errored/timed-out episodes only) — excluded from the pass rate, never a measured"
          + " zero."
      )
    }
    if result.variant > 0 {
      lines.append(
        "- ⚠ \(result.variant) case(s) produced non-identical transcripts across repeats at"
          + " `temp=0` — a determinism-control failure worth a human read regardless of verdict."
      )
    }
    lines.append("")
    lines.append(
      "> Scaffold corpus: threading signal per cell, not a leaderboard-comparable benchmark."
        + " A ✗ focuses human attention on the transcript; it does not adjudicate a backend bug"
        + " on its own."
    )
    lines.append("")
    return lines.joined(separator: "\n")
  }

  /// Renders one axis across repeats: `—` (not probed), `✓ 3/3`, or `✗ 1/3`.
  private static func axisCell(_ outcomes: [Bool?]) -> String {
    let probed = outcomes.compactMap { $0 }
    guard !probed.isEmpty else { return "—" }
    let ok = probed.filter { $0 }.count
    let mark = ok == probed.count ? "✓" : "✗"
    return "\(mark) \(ok)/\(probed.count)"
  }
}
