import XCTest

@testable import ManifoldEval

/// Live integration test that verifies ``RegressionGate`` detects real score
/// movement using actual Ollama model outputs, fed directly to the gate via
/// ``OllamaRawDriver`` (the same producer path ``RegressionRunner`` uses).
///
/// This exercises the gate logic on a *different-models* pair whose score
/// difference was observed in the historical verification run. It is a live
/// assertion, not a universal claim about either model. The genuine same-model
/// **cross-quant** verification lives in
/// `RegressionCrossQuantLiveTests`.
///
/// **Env-gated** (`RUN_OLLAMA_LIVE=1`): CI has no Ollama, so these skip there.
/// Run locally with:
///
///     RUN_OLLAMA_LIVE=1 \
///       REGRESSION_GATE_BASELINE_MODEL=llama3.1:8b \
///       REGRESSION_GATE_REDRIVEN_MODEL=gemma3:4b \
///       REGRESSION_GATE_STABLE_MODEL=gemma3:4b \
///       swift test --filter RegressionGateLiveTests
///
/// ## What this proves
///
/// 1. **Gate detects movement** (`testMovedPairDetectsRealModelDifference`):
///    In the 2026-06-30 observation, `llama3.1-8b:latest` (baseline) produced
///    output containing "4" for "2 + 2 =" in raw mode (score=1.0), while
///    `gemma3-4b:latest` (re-driven) entered question-listing mode and produced
///    "?\n\nWhat is the capital of France?..." (score=0.0). The gate returns
///    `.moved(delta: -1.0)` when that measured score difference still holds.
///
/// 2. **No false positive** (`testStablePairProducesNoFalsePositive`):
///    The same configured model runs both legs at temp=0. The assertion requires
///    both measured outputs to receive the same score → `.stable`.
///
/// ## What this does NOT prove
///
/// - Cross-quant parity: this test uses two *different models* as a proxy, so it
///   proves the gate's verdict logic is model/quant-agnostic but not that it tracks
///   a real re-quant. The same-model Q8-vs-Q4 cross-quant case is covered by
///   `RegressionCrossQuantLiveTests`.
///
/// See `docs/P4-VERIFICATION.md` for the full run record and analysis.
final class RegressionGateLiveTests: XCTestCase {

  private var isEnabled: Bool {
    ProcessInfo.processInfo.environment["RUN_OLLAMA_LIVE"] == "1"
  }

  private var configuration: RegressionGateLiveConfiguration {
    get throws {
      try RegressionGateLiveConfiguration(environment: ProcessInfo.processInfo.environment)
    }
  }

  private func ollamaURL() throws -> URL {
    let raw = ProcessInfo.processInfo.environment["OLLAMA_URL"] ?? "http://localhost:11434"
    guard let url = URL(string: raw) else {
      throw RegressionGateLiveConfigurationError.invalidOllamaURL(raw)
    }
    return url
  }

  private func preflightModels(
    _ roles: [(role: String, model: String)],
    at url: URL
  ) async throws {
    let evidence: [OllamaModelEvidence]
    do {
      evidence = try await OllamaModelPreflight.fetch(
        requiredModels: roles.map { $0.model }, baseURL: url)
    } catch let error as OllamaModelPreflightError {
      if case .missingModels = error {
        throw XCTSkip(error.localizedDescription)
      }
      throw error
    }

    let byName = Dictionary(uniqueKeysWithValues: evidence.map { ($0.name, $0) })
    for item in roles {
      guard let model = byName[item.model] else { continue }
      print(
        "[regression-gate model] role=\(item.role) name=\(model.name) "
          + "digest=\(model.digest) quant=\(model.quantizationLevel ?? "<unreported>")")
    }
  }

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

    let liveConfiguration = try configuration
    let url = try ollamaURL()
    try await preflightModels(
      [
        ("baseline", liveConfiguration.baselineModel),
        ("re-driven", liveConfiguration.reDrivenModel),
      ],
      at: url)
    let driver = OllamaRawDriver(baseURL: url, coreCommit: "live-p4-verify")
    let scorer = ContainsRegressionScorer(expected: "4")

    // --- Baseline run (llama3.1-8b) ---
    let baseline = try await driver.run(
      model: liveConfiguration.baselineModel,
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
      model: liveConfiguration.reDrivenModel,
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
      // sabotage: change the re-driven model to the baseline model → it also
      // contains "4" → delta=0 → .stable
      XCTAssertLessThan(
        delta, 0,
        "configured moved pair must retain the observed negative delta; got \(delta). "
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
  /// - Both legs use the exact `REGRESSION_GATE_STABLE_MODEL` tag.
  /// - The live assertion requires both measured outputs to receive the same score.
  /// - Equal scores produce delta 0.0, which is ≤ the 0.05 threshold.
  func testStablePairProducesNoFalsePositive() async throws {
    try XCTSkipUnless(isEnabled, "set RUN_OLLAMA_LIVE=1 to run live regression gate tests")

    let liveConfiguration = try configuration
    let url = try ollamaURL()
    try await preflightModels(
      [
        ("stable-baseline", liveConfiguration.stableModel),
        ("stable-re-driven", liveConfiguration.stableModel),
      ],
      at: url)
    let driver = OllamaRawDriver(baseURL: url, coreCommit: "live-p4-verify")
    let scorer = ContainsRegressionScorer(expected: "4")

    // --- Baseline run ---
    let baseline = try await driver.run(
      model: liveConfiguration.stableModel,
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
      model: liveConfiguration.stableModel,
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

    // sabotage: replace the stable model in the re-driven run with a model that
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
/// Designed for the historical "2 + 2 =" observation: the configured baseline
/// included "4" while the configured re-driven model did not. A live run must
/// measure that difference again; the scorer does not assume it universally.
///
/// The binary scoring produces an unambiguous delta of 1.0 between the two
/// models when the observation holds, keeping the delta far from the threshold.
///
/// **Test-only.** Not for production use — a production scorer would live in
/// `Sources/ManifoldEval` with proper documentation and benchmarking.
private struct ContainsRegressionScorer: RegressionScorer {
  let expected: String

  func score(_ output: String) throws -> Double? {
    output.contains(expected) ? 1.0 : 0.0
  }
}
