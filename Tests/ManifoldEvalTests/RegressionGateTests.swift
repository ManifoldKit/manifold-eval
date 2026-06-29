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
/// - **Stubbed:** ``MockRecordReDriver`` (test-only) and
///   ``MockRegressionScorer`` (test-only). Neither is wired to a backend.
///   A production ``RecordReDriver`` requires the `Replayer.runOnce`
///   extraction from ManifoldFuzz and the config-lossy plumbing fix — both
///   deferred (see ``RecordReDriver`` doc comment for details).
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
            promptSha256: "11223344000000001122334400000000112233440000000011223344000000000"
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

    // MARK: - MockRecordReDriver demonstration

    /// Demonstrates the ``RecordReDriver`` seam: a mock re-driver returning a
    /// fixture run produces the expected verdict when passed through the gate.
    ///
    /// This test is the "wiring skeleton" that a real re-driver will satisfy
    /// once ``RecordReDriver`` has a production implementation.
    func testMockReDriverProducesExpectedVerdict() async throws {
        let baselineRun = makeRun(output: "Paris")
        let reDrivenRun = makeRun(output: "Berlin") // different output → score drop

        // MockRecordReDriver returns the pre-baked reDrivenRun regardless of
        // what prompt or sampler is passed — it is a fixture stand-in only.
        let reDriver = MockRecordReDriver(fixedRun: reDrivenRun)
        let reDriven = try await reDriver.reDrive(prompt: "What is the capital of France?", sampler: .greedy)

        let gate = RegressionGate(threshold: 0.05)
        // Scorer assigns 0.0 for "Berlin" (wrong answer), 0.9 for anything else.
        let scorer = MockRegressionScorer(fixedScore: 0.0)

        let verdict = try gate.check(
            baseline: baselineRun, baselineScore: 0.9,
            reDriven: reDriven, scorer: scorer
        )

        switch verdict {
        case .moved(let delta):
            XCTAssertLessThan(delta, 0, "wrong answer should degrade the score")
        default:
            XCTFail("expected .moved(delta:), got \(verdict)")
        }
    }
}

// MARK: - Test-only fixtures

/// Fixture-only re-driver that returns a pre-baked ``RawRun`` regardless of
/// the prompt or sampler it receives. Use only in tests.
///
/// NOT a production implementation. A real ``RecordReDriver`` requires the
/// `Replayer.runOnce` extraction from ManifoldFuzz (deferred — see
/// ``RecordReDriver`` doc comment for the full unblocking checklist).
private struct MockRecordReDriver: RecordReDriver {
    let fixedRun: RawRun

    func reDrive(prompt: String, sampler: SamplerConfig) async throws -> RawRun {
        fixedRun
    }
}

/// Fixture-only scorer that returns a constant score for every output.
/// Use only in tests.
private struct MockRegressionScorer: RegressionScorer {
    let fixedScore: Double?

    func score(_ output: String) throws -> Double? {
        fixedScore
    }
}
