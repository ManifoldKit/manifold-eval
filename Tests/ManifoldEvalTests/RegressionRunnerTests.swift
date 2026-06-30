import XCTest
@testable import ManifoldEval

/// Unit tests for ``RegressionRunner`` — the real orchestration seam that
/// replaced the (removed) inert `RecordReDriver` protocol. The two captures are
/// injected as fixture thunks, so the runner's wiring is exercised end-to-end
/// without a backend: capture → score → gate → outcome.
final class RegressionRunnerTests: XCTestCase {

    private func makeRun(
        output: String,
        model: String = "test-7b",
        quant: String = "Q4_K_M",
        promptSha256: String = "cafebabe00000000cafebabe00000000cafebabe00000000cafebabe00000000"
    ) -> RawRun {
        RawRun(
            backend: "mock", model: model, quant: quant, promptSha256: promptSha256,
            inputTokenIds: [], output: output, outputTokenIds: [],
            sampler: .greedy, coreCommit: "deadbeef", toolingVersions: [:], repeatIndex: 0
        )
    }

    /// Capture counter to prove the runner drives each leg exactly once and in
    /// order (baseline before re-driven).
    private actor CaptureLog {
        private(set) var order: [String] = []
        func record(_ name: String) { order.append(name) }
    }

    /// A genuine score drop across the two legs → `.moved`, and BOTH thunks ran.
    func testMovedAcrossLegs() async throws {
        let log = CaptureLog()
        let scorer = SubstringRegressionScorer(expected: "4")
        let outcome = try await RegressionRunner.run(
            gate: RegressionGate(threshold: 0.05),
            scorer: scorer,
            captureBaseline: { await log.record("baseline"); return self.makeRun(output: "the answer is 4") },
            captureReDriven: { await log.record("redriven"); return self.makeRun(output: "I'm not sure") }
        )

        switch outcome.verdict {
        case .moved(let delta):
            // sabotage: make the re-driven output also contain "4" → delta 0 → .stable
            XCTAssertEqual(delta, -1.0, accuracy: 1e-9)
        default:
            XCTFail("expected .moved, got \(outcome.verdict)")
        }
        XCTAssertEqual(outcome.baselineScore, 1.0)
        XCTAssertEqual(outcome.reDrivenScore, 0.0)
        let order = await log.order
        XCTAssertEqual(order, ["baseline", "redriven"], "baseline must be captured before the re-drive")
    }

    /// Identical scored output → `.stable`.
    func testStableAcrossLegs() async throws {
        let outcome = try await RegressionRunner.run(
            gate: RegressionGate(threshold: 0.05),
            scorer: SubstringRegressionScorer(expected: "4"),
            captureBaseline: { self.makeRun(output: "4") },
            captureReDriven: { self.makeRun(output: "4 indeed") }
        )
        XCTAssertEqual(outcome.verdict, .stable)
    }

    /// An unscorable baseline short-circuits to `.indeterminate` and must NOT
    /// drive the re-drive (re-driving a model we can't baseline wastes a run).
    func testUnscorableBaselineShortCircuitsWithoutReDrive() async throws {
        let log = CaptureLog()
        // Scorer that returns nil for everything (no reference match possible).
        let outcome = try await RegressionRunner.run(
            gate: RegressionGate(threshold: 0.05),
            scorer: AlwaysNilScorer(),
            captureBaseline: { await log.record("baseline"); return self.makeRun(output: "anything") },
            captureReDriven: { await log.record("redriven"); return self.makeRun(output: "anything") }
        )

        switch outcome.verdict {
        case .indeterminate(let reason):
            XCTAssertTrue(reason.contains("baseline"), "reason should name the baseline; got \(reason)")
        default:
            XCTFail("expected .indeterminate, got \(outcome.verdict)")
        }
        XCTAssertNil(outcome.baselineScore)
        let order = await log.order
        // sabotage: if the runner drove the re-drive anyway, order would contain "redriven"
        XCTAssertEqual(order, ["baseline"], "re-drive must be skipped when the baseline is unscorable")
    }

    /// Prompt-hash mismatch between the two legs → `.indeterminate` (the gate's
    /// same-bytes invariant, surfaced through the runner).
    func testPromptMismatchIsIndeterminate() async throws {
        let outcome = try await RegressionRunner.run(
            gate: RegressionGate(threshold: 0.05),
            scorer: SubstringRegressionScorer(expected: "4"),
            captureBaseline: { self.makeRun(output: "4", promptSha256: String(repeating: "a", count: 64)) },
            captureReDriven: { self.makeRun(output: "4", promptSha256: String(repeating: "b", count: 64)) }
        )
        switch outcome.verdict {
        case .indeterminate(let reason):
            XCTAssertTrue(reason.contains("prompt hash mismatch"), "got \(reason)")
        default:
            XCTFail("expected .indeterminate, got \(outcome.verdict)")
        }
    }

    /// A capture that throws propagates (a backend failure is not swallowed).
    func testCaptureErrorPropagates() async throws {
        struct Boom: Error {}
        do {
            _ = try await RegressionRunner.run(
                gate: RegressionGate(),
                scorer: SubstringRegressionScorer(expected: "x"),
                captureBaseline: { throw Boom() },
                captureReDriven: { self.makeRun(output: "x") }
            )
            XCTFail("expected the baseline capture error to propagate")
        } catch is Boom {
            // expected
        }
    }
}

private struct AlwaysNilScorer: RegressionScorer {
    func score(_ output: String) throws -> Double? { nil }
}
