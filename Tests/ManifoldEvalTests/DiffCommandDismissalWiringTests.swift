import XCTest

@testable import ManifoldEval
@testable import manifold_eval

/// End-to-end coverage for the `diff` <-> `DismissalsLedger` wiring
/// (`DiffCommand.evaluate`). This is the load-bearing suite for #25's actual
/// acceptance criterion — a "dismissed" divergence must be genuinely suppressed
/// by the triage surface, not just readable/writable in isolation. Exercises
/// `evaluate` directly (the exit-code logic extracted from `run`, mirroring
/// `parseArguments`) rather than `run` itself, since `run` calls `exit()` and
/// would tear down the test process.
final class DiffCommandDismissalWiringTests: XCTestCase {

  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("diffcommand-dismissal-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
  }

  // MARK: - fixture builders

  private func rawRun(
    backend: String,
    model: String,
    promptSha: String,
    output: String,
    inputTokens: [Int],
    repeatIndex: Int
  ) -> RawRun {
    RawRun(
      backend: backend,
      model: model,
      quant: "server",
      promptSha256: promptSha,
      inputTokenIds: inputTokens,
      output: output,
      outputTokenIds: [],
      sampler: .greedy,
      coreCommit: "deadbeef",
      toolingVersions: [:],
      repeatIndex: repeatIndex
    )
  }

  /// Builds a `DifferentialOutcome` whose comparison classifies as
  /// `.genuineDivergence`: same prompt hash, same input tokens, same sampler,
  /// both legs reproducible over 2 repeats, and differing outputs.
  private func genuineDivergenceOutcome(
    ollamaModel: String = "modelA",
    promptSha: String = "deadbeef00",
    ollamaOutput: String,
    llamaOutput: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> DifferentialOutcome {
    let tokens = [128000, 1, 2, 3]
    let ollamaRuns = (0..<2).map {
      rawRun(
        backend: "ollama", model: ollamaModel, promptSha: promptSha, output: ollamaOutput,
        inputTokens: tokens, repeatIndex: $0)
    }
    let llamaRuns = (0..<2).map {
      rawRun(
        backend: "llama.cpp", model: "\(ollamaModel).gguf", promptSha: promptSha,
        output: llamaOutput, inputTokens: tokens, repeatIndex: $0)
    }
    let ollamaReport = DeterminismReport(runs: ollamaRuns)
    let llamaReport = DeterminismReport(runs: llamaRuns)
    let comparison = try XCTUnwrap(
      DifferentialRecord.compare(ollamaReport, llamaReport),
      "expected a comparison record — both batches are non-empty",
      file: file, line: line
    )
    XCTAssertEqual(
      comparison.divergence, .genuineDivergence, "fixture must produce the state under test",
      file: file, line: line)
    return DifferentialOutcome(
      promptSha256: promptSha, ollama: ollamaReport, llama: llamaReport, comparison: comparison)
  }

  /// Pulls a `- <name>: \`value\`` field back out of a rendered report — the
  /// exact copy/paste surface a human (or this test) would use to feed
  /// `manifold-eval dismiss`.
  private func extractField(
    _ name: String, from report: String, file: StaticString = #filePath, line: UInt = #line
  ) throws -> String {
    let marker = "- \(name): `"
    guard let start = report.range(of: marker) else {
      XCTFail("report did not contain a '\(name)' field:\n\(report)", file: file, line: line)
      throw XCTSkip("missing field")
    }
    let rest = report[start.upperBound...]
    guard let end = rest.firstIndex(of: "`") else {
      XCTFail("unterminated '\(name)' field:\n\(report)", file: file, line: line)
      throw XCTSkip("malformed field")
    }
    return String(rest[..<end])
  }

  private func ledgerURL() -> URL {
    scratch.appendingPathComponent("dismissals-\(UUID().uuidString).json")
  }

  // MARK: - the key end-to-end test

  func testLiveDismissalSuppressesGenuineDivergenceFromDiff() throws {
    let outcome = try genuineDivergenceOutcome(
      ollamaOutput: "The answer is 4.", llamaOutput: "The answer is five.")

    // Baseline: no --dismissals flag at all -> unchanged, flagged.
    let noFlag = DiffCommand.evaluate(
      outcome: outcome, ollamaModel: "modelA", dismissalsPath: nil, warn: { _ in })
    XCTAssertEqual(noFlag.exitCode, 1)
    XCTAssertTrue(
      noFlag.report.contains("not checked"), "absent --dismissals must not consult any ledger")

    // Round 1 with an empty ledger at the path: still surfaces (exit 1), but
    // the report must expose a copyable cell + signature.
    let url = ledgerURL()
    let empty = DiffCommand.evaluate(
      outcome: outcome, ollamaModel: "modelA", dismissalsPath: url.path, warn: { _ in })
    XCTAssertEqual(empty.exitCode, 1, "no ledger entry yet -> unchanged behavior")
    let cell = try extractField("cell", from: empty.report)
    let signature = try extractField("signature", from: empty.report)
    XCTAssertFalse(cell.isEmpty)
    XCTAssertFalse(signature.isEmpty)

    // Record a live dismissal for exactly that (cell, signature) and persist it.
    var ledger = DismissalsLedger()
    let finding = DismissedFinding(cell: cell, signature: signature)
    ledger.record(
      finding, reason: "confirmed by-design: renderer wording", recordedAt: Date(), ttl: 3600)
    try ledger.save(to: url)

    // Round 2: the SAME divergence must now be suppressed.
    let suppressed = DiffCommand.evaluate(
      outcome: outcome, ollamaModel: "modelA", dismissalsPath: url.path, warn: { _ in })
    XCTAssertEqual(
      suppressed.exitCode, 0,
      "a live dismissal for this exact (cell, signature) must suppress genuineDivergence")
    XCTAssertTrue(
      suppressed.report.contains("SUPPRESSED"), "the report must be annotated as suppressed")

    // The SAME divergence with NO matching dismissal (different model/cell)
    // must still surface — proves this isn't suppressing everything.
    let differentCell = DiffCommand.evaluate(
      outcome: outcome, ollamaModel: "modelB-unrelated", dismissalsPath: url.path, warn: { _ in })
    XCTAssertEqual(
      differentCell.exitCode, 1,
      "a dismissal recorded under a different cell must not suppress this one")
  }

  func testExpiredDismissalResurfacesThroughDiff() throws {
    let outcome = try genuineDivergenceOutcome(ollamaOutput: "one", llamaOutput: "two")
    let url = ledgerURL()

    let baseline = DiffCommand.evaluate(
      outcome: outcome, ollamaModel: "modelA", dismissalsPath: url.path, warn: { _ in })
    let cell = try extractField("cell", from: baseline.report)
    let signature = try extractField("signature", from: baseline.report)

    var ledger = DismissalsLedger()
    let finding = DismissedFinding(cell: cell, signature: signature)
    // Recorded well in the past with a short TTL -> already expired "now".
    ledger.record(
      finding, reason: "temporary", recordedAt: Date().addingTimeInterval(-3600), ttl: 60)
    try ledger.save(to: url)

    let evaluation = DiffCommand.evaluate(
      outcome: outcome, ollamaModel: "modelA", dismissalsPath: url.path, warn: { _ in })
    XCTAssertEqual(evaluation.exitCode, 1, "an expired dismissal must resurface the divergence")
    XCTAssertFalse(evaluation.report.contains("SUPPRESSED"))
  }

  func testChangedOutputsChangeSignatureAndAreNotSuppressed() throws {
    let outcomeOriginal = try genuineDivergenceOutcome(ollamaOutput: "one", llamaOutput: "two")
    let url = ledgerURL()

    let baseline = DiffCommand.evaluate(
      outcome: outcomeOriginal, ollamaModel: "modelA", dismissalsPath: url.path, warn: { _ in })
    let cell = try extractField("cell", from: baseline.report)
    let signature = try extractField("signature", from: baseline.report)

    var ledger = DismissalsLedger()
    ledger.record(
      DismissedFinding(cell: cell, signature: signature), reason: "confirmed", recordedAt: Date(),
      ttl: 3600)
    try ledger.save(to: url)

    // Sanity: the original divergence is indeed suppressed now.
    let suppressedOriginal = DiffCommand.evaluate(
      outcome: outcomeOriginal, ollamaModel: "modelA", dismissalsPath: url.path, warn: { _ in })
    XCTAssertEqual(suppressedOriginal.exitCode, 0)

    // Same cell (same model), but the differing bytes changed -> new signature -> must resurface.
    let outcomeChanged = try genuineDivergenceOutcome(
      ollamaOutput: "one", llamaOutput: "a totally different completion")
    let changed = DiffCommand.evaluate(
      outcome: outcomeChanged, ollamaModel: "modelA", dismissalsPath: url.path, warn: { _ in })
    XCTAssertEqual(
      changed.exitCode, 1,
      "a changed divergence signature must never be silently absorbed into an old dismissal")
    XCTAssertFalse(changed.report.contains("SUPPRESSED"))
  }

  // MARK: - regression guard: non-genuineDivergence verdicts are unaffected

  func testIdenticalOutcomeExitsZeroRegardlessOfDismissalsFlag() {
    let tokens = [1, 2, 3]
    let runs = (0..<2).map {
      rawRun(
        backend: "ollama", model: "m", promptSha: "x", output: "same", inputTokens: tokens,
        repeatIndex: $0)
    }
    let llamaRuns = (0..<2).map {
      rawRun(
        backend: "llama.cpp", model: "m.gguf", promptSha: "x", output: "same", inputTokens: tokens,
        repeatIndex: $0)
    }
    let report = DeterminismReport(runs: runs)
    let llamaReport = DeterminismReport(runs: llamaRuns)
    guard let comparison = DifferentialRecord.compare(report, llamaReport) else {
      return XCTFail("expected a comparison")
    }
    XCTAssertEqual(comparison.divergence, .identical)
    let identicalOutcome = DifferentialOutcome(
      promptSha256: "x", ollama: report, llama: llamaReport, comparison: comparison)

    let evaluation = DiffCommand.evaluate(
      outcome: identicalOutcome, ollamaModel: "m", dismissalsPath: ledgerURL().path, warn: { _ in })
    XCTAssertEqual(evaluation.exitCode, 0)
    XCTAssertFalse(
      evaluation.report.contains("Dismissal"),
      "the dismissal section is only relevant to genuineDivergence")
  }
}
