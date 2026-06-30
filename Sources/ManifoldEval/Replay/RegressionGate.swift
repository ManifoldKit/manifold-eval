/// The verdict returned by ``RegressionGate`` after comparing a baseline run
/// to a freshly re-driven run.
public enum RegressionVerdict: Sendable, Equatable {

    /// Scores agree within the configured threshold — no regression detected.
    case stable

    /// Score moved by `delta` (re-driven score − baseline score). Positive
    /// means improvement; negative means degradation. `abs(delta)` exceeds the
    /// configured threshold.
    case moved(delta: Double)

    /// Insufficient data to render a verdict. The `reason` string describes
    /// which invariant failed (e.g. prompt hash mismatch, scorer returned nil).
    case indeterminate(reason: String)
}

/// Scores a model output string in `[0, 1]` for one specific prompt.
///
/// Callers inject a concrete scorer into ``RegressionGate`` — for example an
/// exact-match scorer, an AST-match scorer (BFCL), or any custom logic. The
/// scorer is responsible for carrying its own reference answer; the gate only
/// calls ``score(_:)`` and interprets the returned value.
///
/// Return `nil` when no score can be produced — for example because a
/// reference answer is missing or the output type is unscorable. The gate will
/// treat a `nil` return as ``.indeterminate``.
public protocol RegressionScorer: Sendable {

    /// Score `output`. Returns a value in `[0, 1]`, or `nil` when the scorer
    /// cannot produce a score.
    func score(_ output: String) throws -> Double?
}

/// Detects score movement between a captured baseline ``RawRun`` and a freshly
/// re-driven ``RawRun``.
///
/// # What this does
///
/// The regression moat (plan §8) works by re-driving a captured prompt against
/// a *new* GGUF (different quantisation or model upgrade) and comparing the
/// score of the new output to the baseline score. If the score moved beyond a
/// threshold, the gate flags it for human review.
///
/// ``check(baseline:baselineScore:reDriven:scorer:)`` is **pure logic** over
/// two ``RawRun``s and a ``RegressionScorer``. It performs no I/O and has no
/// backend dependency, making it fully unit-testable on fixtures.
///
/// # Prompt-hash invariant
///
/// The gate's load-bearing guarantee is that the re-drive reproduced the
/// *same prompt* as the baseline run. If `baseline.promptSha256 !=
/// reDriven.promptSha256`, the score comparison would attribute a task
/// mismatch to a model change — the gate returns ``.indeterminate`` instead
/// of a false verdict.
///
/// # Producing the `reDriven` argument
///
/// The re-driven ``RawRun`` comes from re-driving the captured prompt against a
/// *different-quant* GGUF (or a different runtime) — the same separate-process
/// machinery the differential harness already uses (``LlamaRunnerDriver`` /
/// ``OllamaRawDriver``). ``RegressionRunner`` orchestrates the two captures and
/// this gate; the `regress` CLI subcommand is the end-to-end entry point. The
/// gate itself stays pure: it only reads `reDriven.output` and `promptSha256`,
/// so any producer of a ``RawRun`` for the same prompt satisfies it.
public struct RegressionGate: Sendable {

    /// The minimum |delta| that constitutes a detectable score movement.
    /// A delta at or below this value yields ``.stable``.
    public let threshold: Double

    /// - Parameter threshold: Minimum |re-driven score − baseline score| to
    ///   report as `.moved`. Defaults to `0.05` (5 pp).
    public init(threshold: Double = 0.05) {
        self.threshold = threshold
    }

    /// Compare a captured baseline run to a freshly re-driven run.
    ///
    /// - Parameters:
    ///   - baseline: The captured baseline ``RawRun``.
    ///   - baselineScore: The already-computed score for the baseline output.
    ///     Pre-computing the baseline score (rather than re-scoring it here)
    ///     keeps the baseline value stable across successive re-drives against
    ///     new builds — the baseline is ground truth, not re-derived each time.
    ///   - reDriven: The freshly re-driven ``RawRun`` (from ``RegressionRunner``
    ///     driving a real backend, or a fixture ``RawRun`` in tests).
    ///   - scorer: Applied to `reDriven.output` to produce the re-driven score.
    ///     Injected so the gate is not coupled to any specific scoring strategy.
    /// - Returns: ``.stable``, ``.moved(delta:)``, or ``.indeterminate(reason:)``.
    /// - Throws: Rethrows any error from `scorer`.
    public func check(
        baseline: RawRun,
        baselineScore: Double,
        reDriven: RawRun,
        scorer: some RegressionScorer
    ) throws -> RegressionVerdict {
        // Reject misconfiguration as .indeterminate rather than trapping or
        // fabricating a verdict: a negative threshold makes |delta| <= threshold
        // permanently false (every run reads as moved), and a baselineScore outside
        // the [0,1] the RegressionScorer contract promises inflates delta silently.
        guard threshold >= 0 else {
            return .indeterminate(reason: "threshold \(threshold) is negative; must be non-negative")
        }
        guard (0...1).contains(baselineScore) else {
            return .indeterminate(reason: "baselineScore \(baselineScore) outside [0, 1]")
        }

        // Prompt-hash invariant: a score difference attributable to a different
        // task is not a model regression. Return .indeterminate rather than a
        // fabricated verdict — the caller must ensure prompt string fidelity.
        guard baseline.promptSha256 == reDriven.promptSha256 else {
            return .indeterminate(
                reason: "prompt hash mismatch — baseline \(baseline.promptSha256), "
                    + "re-driven \(reDriven.promptSha256); "
                    + "the re-drive did not reproduce the same prompt"
            )
        }

        guard let reDrivenScore = try scorer.score(reDriven.output) else {
            return .indeterminate(reason: "scorer returned nil for re-driven output")
        }

        let delta = reDrivenScore - baselineScore
        return abs(delta) <= threshold ? .stable : .moved(delta: delta)
    }
}
