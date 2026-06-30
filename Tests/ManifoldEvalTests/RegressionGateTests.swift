import XCTest
@testable import ManifoldEval

/// Unit tests for ``RegressionGate`` — pure logic over fixture ``RawRun``s and
/// a ``MockRegressionScorer``.
///
/// No model, no backend, no I/O. The gate is exercised against three verdict
/// classes: ``RegressionVerdict/stable``, ``RegressionVerdict/moved(delta:)``,
/// and ``RegressionVerdict/indeterminate(reason:)``. Each test includes a
/// sabotage comment demonstrating that inverting the assertion flips the
/// outcome — see the inline `// sabotage:` annotations.
///
/// ## What is real vs stubbed
///
/// - **Real:** ``RegressionGate`` verdict logic, the prompt-hash invariant,
///   threshold arithmetic, and the scorer injection seam.
/// - **Test-only:** ``MockRegressionScorer`` returns a fixed score so the gate's
///   arithmetic can be exercised on fixtures. The *runner* that produces real
///   ``RawRun``s (``RegressionRunner``) is tested in `RegressionRunnerTests`; the
///   production scorers in `RegressionScorersTests`.
final class RegressionGateTests: XCTestCase {

    // MARK: - Fixture helpers

    /// Build a minimal ``RawRun`` sufficient for gate tests.
    private func makeRun(
        output: String,
        promptSha256: String = "cafebabe00000000cafebabe00000000cafebabe00000000cafebabe00000000"
    ) -> RawRun {
        RawRun(
            backend: "mock",
            model: "test-model-7b",
            quant: "Q4_K_M",
            promptSha256: promptSha256,
            inputTokenIds: [],
            output: output,
            outputTokenIds: [],
            sampler: .greedy,
            coreCommit: "deadbeef",
            toolingVersions: [:],
            repeatIndex: 0
        )
    }

    // MARK: - stable

    /// Identical output and score → .stable.
    func testIdenticalScoreIsStable() throws {
        let gate = RegressionGate(threshold: 0.05)
        let baseline = makeRun(output: "Paris")
        let reDriven = makeRun(output: "Paris")
        let scorer = MockRegressionScorer(fixedScore: 0.9)

        let verdict = try gate.check(
            baseline: baseline, baselineScore: 0.9,
            reDriven: reDriven, scorer: scorer
        )

        // sabotage: change baselineScore to 0.0 → |delta| = 0.9 > 0.05 → .moved
        XCTAssertEqual(verdict, .stable)
    }

    /// Score delta within threshold → .stable.
    func testScoreMovedWithinThresholdIsStable() throws {
        let gate = RegressionGate(threshold: 0.05)
        let baseline = makeRun(output: "Paris")
        let reDriven = makeRun(output: "Paris (France)")
        // Re-driven score 0.92; delta = 0.92 - 0.90 = 0.02 ≤ 0.05 → stable.
        let scorer = MockRegressionScorer(fixedScore: 0.92)

        let verdict = try gate.check(
            baseline: baseline, baselineScore: 0.90,
            reDriven: reDriven, scorer: scorer
        )

        // sabotage: change scorer to fixedScore 0.96 → delta = 0.06 > 0.05 → .moved
        XCTAssertEqual(verdict, .stable)
    }

    /// Score exactly at threshold boundary → .stable (inclusive).
    func testScoreAtExactThresholdBoundaryIsStable() throws {
        let gate = RegressionGate(threshold: 0.05)
        let baseline = makeRun(output: "Berlin")
        let reDriven = makeRun(output: "Berlin")
        // Re-driven score 0.95; baseline 0.90; delta = 0.05 == threshold → stable.
        let scorer = MockRegressionScorer(fixedScore: 0.95)

        let verdict = try gate.check(
            baseline: baseline, baselineScore: 0.90,
            reDriven: reDriven, scorer: scorer
        )

        // sabotage: change scorer to fixedScore 0.951 → delta slightly > 0.05 → .moved
        XCTAssertEqual(verdict, .stable)
    }

    // MARK: - moved

    /// Score degradation beyond threshold → .moved with negative delta.
    func testScoreDegradationBeyondThresholdIsMoved() throws {
        let gate = RegressionGate(threshold: 0.05)
        let baseline = makeRun(output: "Paris")
        let reDriven = makeRun(output: "I dunno")
        // Re-driven score 0.1; baseline 0.9; delta = 0.1 - 0.9 = -0.8.
        let scorer = MockRegressionScorer(fixedScore: 0.1)

        let verdict = try gate.check(
            baseline: baseline, baselineScore: 0.9,
            reDriven: reDriven, scorer: scorer
        )

        switch verdict {
        case .moved(let delta):
            // sabotage: change threshold to 1.0 → |delta| ≤ threshold → .stable
            XCTAssertLessThan(delta, 0, "degradation must have a negative delta")
            XCTAssertGreaterThan(abs(delta), gate.threshold)
            XCTAssertEqual(delta, -0.8, accuracy: 1e-9)
        default:
            XCTFail("expected .moved(delta:), got \(verdict)")
        }
    }

    /// Score improvement beyond threshold → .moved with positive delta.
    func testScoreImprovementBeyondThresholdIsMoved() throws {
        let gate = RegressionGate(threshold: 0.05)
        let baseline = makeRun(output: "I dunno")
        let reDriven = makeRun(output: "Paris, the capital of France")
        // Re-driven score 0.95; baseline 0.1; delta = +0.85.
        let scorer = MockRegressionScorer(fixedScore: 0.95)

        let verdict = try gate.check(
            baseline: baseline, baselineScore: 0.1,
            reDriven: reDriven, scorer: scorer
        )

        switch verdict {
        case .moved(let delta):
            // sabotage: change scorer to fixedScore 0.12 → delta = 0.02 ≤ 0.05 → .stable
            XCTAssertGreaterThan(delta, 0, "improvement must have a positive delta")
            XCTAssertEqual(delta, 0.85, accuracy: 1e-9)
        default:
            XCTFail("expected .moved(delta:), got \(verdict)")
        }
    }

    // MARK: - indeterminate

    /// Prompt hash mismatch → .indeterminate, never a fabricated verdict.
    func testPromptHashMismatchIsIndeterminate() throws {
        let gate = RegressionGate(threshold: 0.05)
        let baseline = makeRun(
            output: "Paris",
            promptSha256: "aabbccdd00000000aabbccdd00000000aabbccdd00000000aabbccdd00000000"
        )
        // Re-driven run has a different prompt hash — the re-drive did not
        // reproduce the same prompt (e.g. the original prompt string was lost).
        let reDriven = makeRun(
            output: "Paris",
            promptSha256: "1122334400000000112233440000000011223344000000001122334400000000"
        )
        let scorer = MockRegressionScorer(fixedScore: 0.9)

        let verdict = try gate.check(
            baseline: baseline, baselineScore: 0.9,
            reDriven: reDriven, scorer: scorer
        )

        // sabotage: use the same promptSha256 for both runs → verdict becomes .stable
        switch verdict {
        case .indeterminate(let reason):
            XCTAssertTrue(
                reason.contains("prompt hash mismatch"),
                "reason must name the invariant that failed; got: \(reason)"
            )
        default:
            XCTFail("expected .indeterminate(reason:), got \(verdict)")
        }
    }

    /// Scorer returning nil → .indeterminate; never guesses a score.
    func testScorerReturningNilIsIndeterminate() throws {
        let gate = RegressionGate(threshold: 0.05)
        let baseline = makeRun(output: "Paris")
        let reDriven = makeRun(output: "Some unscored output")
        // Scorer has no reference answer for this output → returns nil.
        let scorer = MockRegressionScorer(fixedScore: nil)

        let verdict = try gate.check(
            baseline: baseline, baselineScore: 0.9,
            reDriven: reDriven, scorer: scorer
        )

        // sabotage: change scorer to fixedScore 0.9 → verdict becomes .stable
        switch verdict {
        case .indeterminate(let reason):
            XCTAssertTrue(
                reason.contains("scorer returned nil"),
                "reason must describe the nil-scorer condition; got: \(reason)"
            )
        default:
            XCTFail("expected .indeterminate(reason:), got \(verdict)")
        }
    }

}

// MARK: - Test-only fixtures

/// Fixture-only scorer that returns a constant score for every output.
/// Use only in tests.
private struct MockRegressionScorer: RegressionScorer {
    let fixedScore: Double?

    func score(_ output: String) throws -> Double? {
        fixedScore
    }
}
