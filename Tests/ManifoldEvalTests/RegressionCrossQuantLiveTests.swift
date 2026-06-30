import XCTest
@testable import ManifoldEval

/// Live cross-quant verification of the replay-regression moat — the credibility
/// gate the proxy test (`RegressionGateLiveTests`, two *different models*) could
/// not provide. Here both legs are **two quantisations of the SAME model**, so
/// quant is the only variable — the moat's actual premise.
///
/// Driven through the real ``RegressionRunner`` + ``OllamaRawDriver`` path that the
/// `regress` CLI uses (Ollama serves per-quant tags, so this needs no GGUF files
/// or the llama runner — just `ollama pull` of two quant tags of one model).
///
/// **Env-gated** (`RUN_OLLAMA_LIVE=1`); configurable so you can point it at the
/// quant pair you have installed:
///
///     RUN_OLLAMA_LIVE=1 \
///       REGRESS_BASELINE_MODEL=qwen2.5:0.5b-instruct-q8_0 \
///       REGRESS_REDRIVEN_MODEL=qwen2.5:0.5b-instruct-q4_K_M \
///       REGRESS_PROMPT='2 + 2 =' REGRESS_EXPECTED=4 \
///       swift test --filter RegressionCrossQuantLiveTests
///
/// ## What this asserts (real, would fail if the gate broke)
///
/// 1. **No false positive on identical-quant re-drive** — re-driving the SAME
///    quant tag twice yields `.stable`. Deterministic at temp=0; reliably passes.
/// 2. **Verdict faithfully tracks real cross-quant score movement** — for the
///    q8-vs-q4 pair the gate must return a *trustworthy* verdict (never
///    `.indeterminate`: the prompt-hash invariant holds and the scorer always
///    scores), and the verdict must agree with the observed scores (`.moved` iff
///    the two quants scored differently beyond threshold, else `.stable`).
///
/// Whether the two quants *did* diverge is reported for the human-in-loop step —
/// that judgement (quant drift vs genuine correctness loss) is not automated.
final class RegressionCrossQuantLiveTests: XCTestCase {

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["RUN_OLLAMA_LIVE"] == "1"
    }
    private func env(_ key: String, _ fallback: String) -> String {
        ProcessInfo.processInfo.environment[key] ?? fallback
    }
    private func ollamaURL() throws -> URL {
        let raw = env("OLLAMA_URL", "http://localhost:11434")
        guard let url = URL(string: raw) else { throw XCTSkip("invalid OLLAMA_URL: \(raw)") }
        return url
    }

    private var baselineQuant: String { env("REGRESS_BASELINE_MODEL", "qwen2.5:0.5b-instruct-q8_0") }
    private var reDrivenQuant: String { env("REGRESS_REDRIVEN_MODEL", "qwen2.5:0.5b-instruct-q4_K_M") }
    private var prompt: String { env("REGRESS_PROMPT", "2 + 2 =") }
    private var expected: String { env("REGRESS_EXPECTED", "4") }

    // MARK: - 1. No false positive on identical-quant re-drive

    func testSameQuantReDriveIsStable() async throws {
        try XCTSkipUnless(isEnabled, "set RUN_OLLAMA_LIVE=1 to run live cross-quant tests")
        let driver = OllamaRawDriver(baseURL: try ollamaURL(), coreCommit: "live-crossquant")
        let scorer = SubstringRegressionScorer(expected: expected)

        let outcome = try await RegressionRunner.run(
            gate: RegressionGate(threshold: 0.05),
            scorer: scorer,
            captureBaseline: { try await driver.run(model: self.baselineQuant, prompt: self.prompt, sampler: .greedy, repeatIndex: 0) },
            captureReDriven: { try await driver.run(model: self.baselineQuant, prompt: self.prompt, sampler: .greedy, repeatIndex: 1) }
        )

        // sabotage: point captureReDriven at a model that scores differently → .moved
        XCTAssertEqual(
            outcome.verdict, .stable,
            "re-driving the SAME quant at temp=0 must not trip the gate. "
                + "baseline=\(fmt(outcome.baselineScore)) reDriven=\(fmt(outcome.reDrivenScore)) "
                + "out='\(outcome.reDriven.output.prefix(60))'"
        )
    }

    // MARK: - 2. Verdict tracks real cross-quant movement

    func testCrossQuantVerdictTracksScores() async throws {
        try XCTSkipUnless(isEnabled, "set RUN_OLLAMA_LIVE=1 to run live cross-quant tests")
        let driver = OllamaRawDriver(baseURL: try ollamaURL(), coreCommit: "live-crossquant")
        let scorer = SubstringRegressionScorer(expected: expected)
        let gate = RegressionGate(threshold: 0.05)

        let outcome = try await RegressionRunner.run(
            gate: gate,
            scorer: scorer,
            captureBaseline: { try await driver.run(model: self.baselineQuant, prompt: self.prompt, sampler: .greedy, repeatIndex: 0) },
            captureReDriven: { try await driver.run(model: self.reDrivenQuant, prompt: self.prompt, sampler: .greedy, repeatIndex: 0) }
        )

        // The same prompt string ⇒ identical promptSha256 ⇒ the invariant holds; the
        // binary scorer always returns a score ⇒ never nil. So a real cross-quant run
        // must yield a trustworthy verdict, NOT .indeterminate.
        let baselineScore = try XCTUnwrap(outcome.baselineScore)
        let reDrivenScore = try XCTUnwrap(outcome.reDrivenScore)
        let diverged = abs(reDrivenScore - baselineScore) > gate.threshold

        // Human-in-loop signal: report what actually happened across the two quants.
        print("[cross-quant] \(baselineQuant)=\(baselineScore) vs \(reDrivenQuant)=\(reDrivenScore) "
            + "→ \(outcome.verdict) (diverged=\(diverged))")

        switch outcome.verdict {
        case .moved(let delta):
            // sabotage: widen threshold to 1.0 → identical-scoring quants would read .stable
            XCTAssertTrue(diverged, "gate said .moved but scores agree within threshold")
            XCTAssertEqual(delta, reDrivenScore - baselineScore, accuracy: 1e-9)
        case .stable:
            XCTAssertFalse(diverged, "gate said .stable but scores diverged beyond threshold")
        case .indeterminate(let reason):
            XCTFail("cross-quant run must produce a trustworthy verdict, got .indeterminate: \(reason)")
        }
    }

    private func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }
}
