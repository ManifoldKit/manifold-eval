import Foundation

/// The result of one regression run: the gate verdict plus both legs and their
/// scores, so a report can show *why* the verdict came out the way it did.
public struct RegressionOutcome: Sendable {
    public let verdict: RegressionVerdict
    public let baseline: RawRun
    public let baselineScore: Double?
    /// `nil` when the re-drive was never run — i.e. the baseline was unscorable so
    /// the runner short-circuited before driving the second leg. A non-nil value is
    /// a re-drive that actually happened.
    public let reDriven: RawRun?
    /// `nil` when the re-drive did not run, or ran but produced unscorable output
    /// (the gate then reads `.indeterminate`). Recorded for the report regardless.
    public let reDrivenScore: Double?

    public init(
        verdict: RegressionVerdict,
        baseline: RawRun,
        baselineScore: Double?,
        reDriven: RawRun?,
        reDrivenScore: Double?
    ) {
        self.verdict = verdict
        self.baseline = baseline
        self.baselineScore = baselineScore
        self.reDriven = reDriven
        self.reDrivenScore = reDrivenScore
    }
}

/// Orchestrates a replay-regression run end to end: capture a baseline ``RawRun``,
/// capture a re-driven ``RawRun`` (typically the same prompt against a *different
/// quant* of the same model), score both, and run them through ``RegressionGate``.
///
/// The two captures are injected as async thunks rather than a backend protocol,
/// so the runner is agnostic to *how* each leg is produced — the `regress`
/// command builds the thunks from ``LlamaRunnerDriver`` (separate-process GGUF)
/// or ``OllamaRawDriver`` (HTTP), and tests inject fixture thunks. This is the
/// real seam that the (now-removed) `RecordReDriver` protocol only stubbed: a
/// `RawRun` producer is all the gate ever needs.
public enum RegressionRunner {

    /// - Parameters:
    ///   - gate: The configured gate (threshold).
    ///   - scorer: Scores both legs' `output`. The *same* scorer (same reference
    ///     answer) must score both, or the delta is meaningless.
    ///   - captureBaseline: Produces the baseline ``RawRun``.
    ///   - captureReDriven: Produces the re-driven ``RawRun`` (different quant /
    ///     build, same prompt).
    /// - Returns: A ``RegressionOutcome`` carrying the verdict and both legs.
    /// - Throws: Rethrows capture errors (a backend that failed to produce a run)
    ///   and scorer errors. A *missing baseline score* is not thrown — it is a
    ///   first-class `.indeterminate` verdict, because an unscorable baseline is
    ///   an honest "no signal", not a crash.
    public static func run(
        gate: RegressionGate,
        scorer: some RegressionScorer,
        captureBaseline: () async throws -> RawRun,
        captureReDriven: () async throws -> RawRun
    ) async throws -> RegressionOutcome {
        let baseline = try await captureBaseline()

        // Score the baseline first. If it is unscorable the gate can render no
        // meaningful delta, so short-circuit to .indeterminate WITHOUT driving the
        // re-drive — re-driving a model we can't even baseline wastes a backend run.
        guard let baselineScore = try scorer.score(baseline.output) else {
            // The re-drive never ran — reDriven is nil, not an alias of the baseline.
            return RegressionOutcome(
                verdict: .indeterminate(reason: "scorer returned nil for the baseline output"),
                baseline: baseline,
                baselineScore: nil,
                reDriven: nil,
                reDrivenScore: nil
            )
        }

        let reDriven = try await captureReDriven()
        let verdict = try gate.check(
            baseline: baseline,
            baselineScore: baselineScore,
            reDriven: reDriven,
            scorer: scorer
        )
        // Re-score the re-driven leg for the report (the gate computed it
        // internally but does not surface it). A nil here is consistent with the
        // gate's own .indeterminate path.
        let reDrivenScore = try scorer.score(reDriven.output)

        return RegressionOutcome(
            verdict: verdict,
            baseline: baseline,
            baselineScore: baselineScore,
            reDriven: reDriven,
            reDrivenScore: reDrivenScore
        )
    }
}
