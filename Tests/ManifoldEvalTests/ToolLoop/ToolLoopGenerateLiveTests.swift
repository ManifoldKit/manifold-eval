import ManifoldInference
import ManifoldOllama
import XCTest

@testable import ManifoldEval

/// Live end-to-end verification of the tool-loop lane: drives a real local
/// Ollama model over the built-in corpus with the case's ``ScriptedTool``s
/// registered in a real `ToolRegistry` — the production dispatch loop
/// executes the tools and threads their results across turns. This is the
/// lane's live-consumer proof (ORIGINS #6): the strongest evidence the lane
/// measures the real turn loop, not a synthetic emit closure.
///
/// **Env-gated** (`RUN_OLLAMA_LIVE=1`), consistent with the other live
/// suites — CI has no Ollama, so this skips there.
///
///     RUN_OLLAMA_LIVE=1 OLLAMA_MODEL=mistral-7b-tools:latest \
///       swift test --filter ToolLoopGenerateLiveTests
///
/// The default model is tool-capable `mistral-7b-tools:latest` (the lane is
/// meaningless on a model that cannot tool-call at all).
final class ToolLoopGenerateLiveTests: XCTestCase {

  private var isEnabled: Bool { ProcessInfo.processInfo.environment["RUN_OLLAMA_LIVE"] == "1" }
  private var model: String {
    ProcessInfo.processInfo.environment["OLLAMA_MODEL"] ?? "mistral-7b-tools:latest"
  }
  private var baseURLString: String {
    ProcessInfo.processInfo.environment["OLLAMA_URL"] ?? "http://localhost:11434"
  }

  @MainActor
  func testGenerateThenScoreRoundTrip_liveOllama() async throws {
    try XCTSkipUnless(isEnabled, "set RUN_OLLAMA_LIVE=1 to run the live tool-loop smoke test")
    guard let baseURL = URL(string: baseURLString) else {
      throw XCTSkip("invalid OLLAMA_URL '\(baseURLString)'")
    }

    let ollama = OllamaBackend(urlSession: nil)
    ollama.configure(baseURL: baseURL, modelName: model)
    try await ollama.loadModel(from: baseURL, plan: .cloud())

    let cases = ToolLoopCorpus.builtin
    let modelName = model

    // 1 repeat keeps the smoke test bounded (~8 episodes); the 3-repeat
    // determinism control is the CLI run's job, not CI-adjacent smoke.
    let result = await ToolLoopLane().generateTranscripts(
      cases: cases,
      repeats: 1,
      emit: { toolLoopCase, repeatIndex in
        let registry = ToolRegistry(
          tools: toolLoopCase.tools.map { ScriptedTool(spec: $0) }
        )
        let service = InferenceService(
          backend: ollama, name: "ollama", modelName: modelName, toolRegistry: registry
        )
        return await ToolLoopEpisodeDriver.recordEpisode(
          for: toolLoopCase,
          repeatIndex: repeatIndex,
          service: service,
          timeoutSeconds: 120
        )
      }
    )

    XCTAssertEqual(result.entries.count, cases.count, "one episode per case")

    // An errored episode is an infrastructure hole, not a measured capability
    // zero (CONCEPTS: absence != failure). This smoke test is specifically a
    // live-consumer health check, so fail closed rather than letting a run
    // whose episodes all failed look green merely because it produced one
    // entry per case. Keep the entry-level diagnostics in the failure: the
    // caller needs the actual timeout/backend error to repair the setup.
    XCTAssertNil(Self.generationHealthFailure(for: result))

    // Wiring proof, separated from model capability (assess, don't
    // declare): a model that emits NO structured tool calls at all is a
    // legitimate measured zero — gemma3-4b-tools does exactly this,
    // emitting a ```tool_code``` text block and then HALLUCINATING the
    // tool's result — and must not read as a harness failure. What IS a
    // harness failure is a structured call that never produced a result:
    // the model did its part and the dispatch loop didn't run.
    let measuredEntries = Self.measuredEntries(for: result)
    if measuredEntries.isEmpty {
      print(
        "[ToolLoopGenerateLiveTests] \(modelName): no clean episodes were measured; "
          + "\(result.errored) episode(s) errored, so this is unmeasured rather than a capability zero"
      )
    } else if measuredEntries.allSatisfy({ $0.calls.isEmpty }) {
      print(
        "[ToolLoopGenerateLiveTests] \(modelName): emitted ZERO structured tool calls — "
          + "a measured capability zero for this cell, not a wiring failure"
      )
    } else {
      let episodesWithDispatch = measuredEntries.filter { entry in
        guard !entry.calls.isEmpty else { return false }
        return entry.events.contains { if case .result = $0 { return true } else { return false } }
      }
      XCTAssertFalse(
        episodesWithDispatch.isEmpty,
        "structured tool calls were emitted but no result was ever dispatched — wiring is broken"
      )
    }

    // Score exactly what was generated and print the human-readable rows.
    let score = ToolLoopLane().score(cases: cases, transcripts: result.entries)
    for caseResult in score.caseResults {
      let repeatScore = caseResult.repeats.first
      print(
        "[ToolLoopGenerateLiveTests] \(modelName) \(caseResult.caseID): "
          + "first=\(mark(repeatScore?.firstCallOK)) "
          + "chained=\(mark(repeatScore?.chainedOK)) "
          + "answer=\(mark(repeatScore?.answerOK))"
      )
    }
    print(
      "[ToolLoopGenerateLiveTests] \(modelName): \(score.passed)/\(score.total) passed, "
        + "\(result.errored) errored"
    )
  }

  private func mark(_ outcome: Bool??) -> String {
    switch outcome {
    case .some(.some(true)): return "✓"
    case .some(.some(false)): return "✗"
    default: return "—"
    }
  }

  /// Returns the live smoke-test failure for errored episodes, if any.
  ///
  /// The scorer still treats error-marked entries as holes. The live test has
  /// a different concern: whether the generation run itself was healthy
  /// enough to provide its live-consumer proof. Keeping this decision pure
  /// lets the hermetic suite prove both its red and measured-zero paths.
  static func generationHealthFailure(for result: ToolLoopLane.GenerateResult) -> String? {
    guard result.errored > 0 else { return nil }

    let details = result.entries.compactMap { entry -> String? in
      guard let error = entry.error else { return nil }
      return "\(entry.id)#\(entry.repeatIndex): \(error)"
    }
    let detailText =
      details.isEmpty ? "No entry.error details were recorded." : details.joined(separator: "; ")
    return
      "live tool-loop generation had \(result.errored) errored episode(s); "
      + "these are unmeasured infrastructure failures, not capability zeros. "
      + detailText
  }

  /// Entries without an on-wire error are the only ones that count as live
  /// measurement. Error-marked entries are infrastructure holes, even if
  /// they happen to contain partial events.
  static func measuredEntries(for result: ToolLoopLane.GenerateResult) -> [ToolLoopTranscriptEntry] {
    result.entries.filter { $0.error == nil }
  }
}
