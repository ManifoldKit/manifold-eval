import XCTest
@testable import ManifoldEval

/// Live smoke test against a local Ollama. **Env-gated** (`RUN_OLLAMA_LIVE=1`):
/// CI has no Ollama, so this skips there. Run locally with:
///
///     RUN_OLLAMA_LIVE=1 OLLAMA_MODEL=llama3.1-8b:latest \
///       swift test --filter OllamaLiveSmokeTests
///
/// It proves P2.1's live milestones (a) determinism control and (c) Ollama-vs-Ollama
/// triage end-to-end through the real driver — never as an unconditional CI test.
final class OllamaLiveSmokeTests: XCTestCase {

    private var isEnabled: Bool { ProcessInfo.processInfo.environment["RUN_OLLAMA_LIVE"] == "1" }
    private var model: String { ProcessInfo.processInfo.environment["OLLAMA_MODEL"] ?? "llama3.1-8b:latest" }

    private func makeDriver() throws -> OllamaRawDriver {
        let base = ProcessInfo.processInfo.environment["OLLAMA_URL"] ?? "http://localhost:11434"
        let url = try XCTUnwrap(URL(string: base))
        return OllamaRawDriver(baseURL: url, coreCommit: "live-smoke")
    }

    func testDeterminismAtTempZero() async throws {
        try XCTSkipUnless(isEnabled, "set RUN_OLLAMA_LIVE=1 to run the live Ollama smoke")
        let driver = try makeDriver()
        // A warmup run absorbs the cold-load outlier observed 2026-06-29, so the
        // measured batch reflects steady-state determinism.
        _ = try await driver.run(model: model, prompt: "2 + 2 =", sampler: .greedy, repeatIndex: -1)

        let report = try await DeterminismHarness.measure(repeats: 3) { index in
            try await driver.run(model: model, prompt: "2 + 2 =", sampler: .greedy, repeatIndex: index)
        }
        XCTAssertTrue(report.wasAssessed)
        // Observed steady-state behaviour: temp=0 is reproducible after warmup. If
        // this fails, the determinism premise (and any cross-backend delta) is
        // suspect — exactly the signal the harness exists to surface.
        XCTAssertTrue(
            report.isDeterministic,
            "temp=0 should be reproducible post-warmup; got \(report.distinctOutputs.count) distinct outputs"
        )
    }

    func testTriageClassifiesGenuineDivergenceLive() async throws {
        try XCTSkipUnless(isEnabled, "set RUN_OLLAMA_LIVE=1 to run the live Ollama smoke")
        let driver = try makeDriver()
        // Two different prompts (same hash space, different bytes) must trip the
        // input-string control: a real promptDivergence verdict.
        let a = try await driver.run(model: model, prompt: "Say apple.", sampler: .greedy, repeatIndex: 0)
        let b = try await driver.run(model: model, prompt: "Say orange.", sampler: .greedy, repeatIndex: 0)
        let verdict = DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true)
        XCTAssertEqual(verdict, .promptDivergence, "different prompt bytes → control fails (promptDivergence)")
    }
}
