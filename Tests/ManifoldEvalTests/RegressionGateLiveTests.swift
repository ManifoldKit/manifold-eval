import XCTest
@testable import ManifoldEval

/// Live integration test that verifies ``RegressionGate`` detects real score
/// movement using actual Ollama model outputs — bypassing the stubbed
/// ``RecordReDriver`` seam by feeding ``OllamaRawDriver`` outputs directly to
/// the gate.
///
/// **Env-gated** (`RUN_OLLAMA_LIVE=1`): CI has no Ollama, so these skip there.
/// Run locally with:
///
///     RUN_OLLAMA_LIVE=1 swift test --filter RegressionGateLiveTests
///
/// ## What this proves
///
/// 1. **Gate detects movement** (`testMovedPairDetectsRealModelDifference`):
///    `llama3.1-8b:latest` (baseline) reliably produces output containing "4"
///    for "2 + 2 =" in raw mode (score=1.0); `gemma3-4b:latest` (re-driven)
///    reliably does not — it enters question-listing mode and produces
///    "?\n\nWhat is the capital of France?..." (score=0.0). The gate returns
///    `.moved(delta: -1.0)`, proving it detects a real quality regression.
///
/// 2. **No false positive** (`testStablePairProducesNoFalsePositive`):
///    `gemma3-4b:latest` is byte-identical at temp=0. Running it twice against
///    the same prompt produces the same score both times → `.stable`.
///
/// ## What this does NOT prove
///
/// - True byte-deterministic cross-quant re-drive: ``RecordReDriver`` is still
///   stubbed. These tests feed ``RawRun``s from ``OllamaRawDriver`` directly,
///   bypassing the ``RecordReDriver`` seam intentionally. A production
///   implementation requires the `Replayer.runOnce` extraction from ManifoldFuzz
///   — deferred; see ``RecordReDriver`` for the full unblocking checklist.
///
/// - Cross-quant parity: no two quants of the same model were used here.
///   Two different models serve as a proxy. The gate logic is model/quant-agnostic
///   — the proof holds regardless of whether the score difference arose from
///   a quant change or a model swap.
///
/// See `docs/P4-VERIFICATION.md` for the full run record and analysis.
final class RegressionGateLiveTests: XCTestCase {

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["RUN_OLLAMA_LIVE"] == "1"
    }

    private func ollamaURL() throws -> URL {
        let raw = ProcessInfo.processInfo.environment["OLLAMA_URL"] ?? "http://localhost:11434"
        guard let url = URL(string: raw) else {
            throw XCTSkip("invalid OLLAMA_URL: \(raw)")
        }
        return url
    }

    // MARK: - Models under test

    /// Baseline model for the moved-pair test.
    ///
    /// `llama3.1-8b:latest` reliably produces output containing "4" for the
    /// prompt "2 + 2 =" in raw mode (confirmed across multiple runs 2026-06-30).
    /// Both variants observed ("4. This is a basic..." and "? (Answer: 4)...")
    /// contain the digit, so `ContainsRegressionScorer(expected: "4")` gives 1.0
    /// regardless of which variant appears.
    private let baselineModel = "llama3.1-8b:latest"

    /// Re-driven model for the moved-pair test.
    ///
    /// `gemma3-4b:latest` consistently produces " ?\n\nWhat is the capital of
    /// France?\n\nWhich planet is known as..." in raw mode for "2 + 2 =" — it
    /// never mentions "4", so the scorer gives 0.0. The delta is -1.0, far
    /// exceeding the 0.05 threshold.
    private let reDrivenModel = "gemma3-4b:latest"

    /// Model used for both legs of the stable-pair test.
    ///
    /// `gemma3-4b:latest` is byte-identical at temp=0 — confirmed across three
    /// consecutive runs 2026-06-30. Using it for both legs guarantees identical
    /// scores and a `.stable` verdict with no false positive.
    private let stableModel = "gemma3-4b:latest"

    // MARK: - Probe prompt

    /// The prompt fed to both models in raw mode.
    ///
    /// Raw mode (`raw: true` in `OllamaRawDriver`) bypasses Ollama's chat
    /// template — the string is sent directly to the model for completion. This
    /// is the same prompt used in the determinism smoke tests, chosen because the
    /// two models exhibit clearly divergent behaviour on it.
    private let probe = "2 + 2 ="

    // MARK: - Moved pair test

    /// The gate must return `.moved` when baseline and re-driven runs come from
    /// different models that score differently against the same scorer.
    ///
    /// **Expected verdict:** `.moved(delta: -1.0)`
    /// - baselineScore = 1.0 (llama3.1 mentions "4")
    /// - reDrivenScore = 0.0 (gemma3-4b does not)
    /// - delta = -1.0, threshold = 0.05 → moved
    func testMovedPairDetectsRealModelDifference() async throws {
        try XCTSkipUnless(isEnabled, "set RUN_OLLAMA_LIVE=1 to run live regression gate tests")

        let url = try ollamaURL()
        let driver = OllamaRawDriver(baseURL: url, coreCommit: "live-p4-verify")
        let scorer = ContainsRegressionScorer(expected: "4")

        // --- Baseline run (llama3.1-8b) ---
        let baseline = try await driver.run(
            model: baselineModel,
            prompt: probe,
            sampler: .greedy,
            repeatIndex: 0
        )
        // Score the baseline output now — this is the stored baseline score the
        // gate would read from its persistence layer in production.
        let baselineScore = try XCTUnwrap(
            try scorer.score(baseline.output),
            "ContainsRegressionScorer must always return a score; got nil for '\(baseline.output)'"
        )

        // --- Re-driven run (gemma3-4b — proxy for a model change) ---
        let reDriven = try await driver.run(
            model: reDrivenModel,
            prompt: probe,
            sampler: .greedy,
            repeatIndex: 0
        )

        // Prompt-hash invariant: same prompt string → same SHA-256. The gate
        // would return .indeterminate if these differ — verify it won't.
        XCTAssertEqual(
            baseline.promptSha256, reDriven.promptSha256,
            "both runs used the same prompt string; SHA-256 must match"
        )

        // --- Gate verdict ---
        let gate = RegressionGate(threshold: 0.05)
        let verdict = try gate.check(
            baseline: baseline,
            baselineScore: baselineScore,
            reDriven: reDriven,
            scorer: scorer
        )

        switch verdict {
        case .moved(let delta):
            // sabotage: change reDrivenModel to baselineModel → reDriven also
            // contains "4" → delta=0 → .stable
            XCTAssertLessThan(
                delta, 0,
                "gemma3-4b degraded relative to llama3.1 — expected negative delta; got \(delta). "
                    + "baselineOutput='\(baseline.output.prefix(60))' "
                    + "reDrivenOutput='\(reDriven.output.prefix(60))'"
            )
            XCTAssertGreaterThan(
                abs(delta), gate.threshold,
                "delta \(delta) must exceed threshold \(gate.threshold)"
            )
        case .stable:
            XCTFail(
                ".stable verdict on a different-model pair — scorer gave same score to both. "
                    + "baselineOutput='\(baseline.output.prefix(80))' (score \(baselineScore)) "
                    + "reDrivenOutput='\(reDriven.output.prefix(80))'"
            )
        case .indeterminate(let reason):
            XCTFail("unexpected .indeterminate: \(reason)")
        }
    }

    // MARK: - Stable pair test

    /// The gate must return `.stable` when the same deterministic model is used
    /// for both the baseline and the re-driven run.
    ///
    /// **Expected verdict:** `.stable`
    /// - Both legs: gemma3-4b (byte-identical at temp=0)
    /// - Both score 0.0 (neither contains "4")
    /// - delta = 0.0, which is ≤ 0.05 threshold → stable
    func testStablePairProducesNoFalsePositive() async throws {
        try XCTSkipUnless(isEnabled, "set RUN_OLLAMA_LIVE=1 to run live regression gate tests")

        let url = try ollamaURL()
        let driver = OllamaRawDriver(baseURL: url, coreCommit: "live-p4-verify")
        let scorer = ContainsRegressionScorer(expected: "4")

        // --- Baseline run ---
        let baseline = try await driver.run(
            model: stableModel,
            prompt: probe,
            sampler: .greedy,
            repeatIndex: 0
        )
        let baselineScore = try XCTUnwrap(
            try scorer.score(baseline.output),
            "ContainsRegressionScorer must always return a score; got nil for '\(baseline.output)'"
        )

        // --- Re-driven run (same model, same prompt, repeatIndex 1) ---
        let reDriven = try await driver.run(
            model: stableModel,
            prompt: probe,
            sampler: .greedy,
            repeatIndex: 1
        )

        let gate = RegressionGate(threshold: 0.05)
        let verdict = try gate.check(
            baseline: baseline,
            baselineScore: baselineScore,
            reDriven: reDriven,
            scorer: scorer
        )

        // sabotage: replace stableModel in the re-driven run with a model that
        // mentions "4" → reDrivenScore=1.0, delta=1.0 > threshold → .moved
        XCTAssertEqual(
            verdict, .stable,
            "same deterministic model must not trip the gate. "
                + "baselineOutput='\(baseline.output.prefix(80))' (score \(baselineScore)) "
                + "reDrivenOutput='\(reDriven.output.prefix(80))'"
        )
    }
}

// MARK: - ContainsRegressionScorer

/// Scores a model output `1.0` if it contains `expected`, else `0.0`.
///
/// Designed for the "2 + 2 =" probe:
/// - `llama3.1-8b:latest` in raw mode reliably includes "4" → 1.0.
/// - `gemma3-4b:latest` in raw mode enters question-listing and never includes
///   "4" → 0.0.
///
/// The binary scoring produces an unambiguous delta of 1.0 between the two
/// models, making threshold-boundary false verdicts impossible. The scorer is
/// invariant to minor llama3.1 output variation (all observed variants contain
/// "4") — confirming it is an honest probe for this comparison.
///
/// **Test-only.** Not for production use — a production scorer would live in
/// `Sources/ManifoldEval` with proper documentation and benchmarking.
private struct ContainsRegressionScorer: RegressionScorer {
    let expected: String

    func score(_ output: String) throws -> Double? {
        output.contains(expected) ? 1.0 : 0.0
    }
}
