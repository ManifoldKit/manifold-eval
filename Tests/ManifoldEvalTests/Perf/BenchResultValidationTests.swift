import XCTest

@testable import ManifoldEval

/// ``BenchResult/validate(_:expectedTimedRuns:)`` — the sample-count integrity
/// guard `PerfRunner` runs on every result it produces. Fixture-free (in-code
/// hand-built results), same shape as `PerfCollatorTests`.
final class BenchResultValidationTests: XCTestCase {

  private let hardware = HardwareSnapshot(chip: "Apple M-test", memoryGB: 32, os: "macOS 26.0")

  private func makeResult(
    ttftMsPerRun: [Double] = [166, 170, 164],
    tpsPerRun: [Double] = [22.1, 21.8, 22.4],
    tokensPerRun: [Int] = [128, 128, 128]
  ) -> BenchResult {
    BenchResult(
      lane: "ollama",
      transport: .httpOllama,
      engine: "ollama",
      model: "llama3.1-8b",
      quant: "Q4_K_M",
      ttftMsPerRun: ttftMsPerRun,
      tpsPerRun: tpsPerRun,
      tokensPerRun: tokensPerRun,
      specHash: "hash-a",
      hardware: hardware,
      runAlone: true
    )
  }

  func testMatchingSampleCountValidatesCleanly() throws {
    // Control: a result whose arrays all match timed_runs must pass.
    XCTAssertNoThrow(try BenchResult.validate(makeResult(), expectedTimedRuns: 3))
  }

  func testShortTtftArrayThrows() {
    // The exact failure mode this guard exists for: a lane that silently
    // dropped a timed run partway through would otherwise typecheck fine
    // and report a median over the wrong sample count.
    let result = makeResult(ttftMsPerRun: [166, 170])
    XCTAssertThrowsError(try BenchResult.validate(result, expectedTimedRuns: 3)) { error in
      XCTAssertEqual(
        error as? BenchResultValidationError,
        .sampleCountMismatch(field: "ttft_ms_per_run", expected: 3, actual: 2)
      )
    }
  }

  func testLongTpsArrayThrows() {
    // A duplicated/leaked sample is just as much a bug as a dropped one.
    let result = makeResult(tpsPerRun: [22.1, 21.8, 22.4, 22.0])
    XCTAssertThrowsError(try BenchResult.validate(result, expectedTimedRuns: 3)) { error in
      XCTAssertEqual(
        error as? BenchResultValidationError,
        .sampleCountMismatch(field: "tps_per_run", expected: 3, actual: 4)
      )
    }
  }

  func testMismatchedTokensArrayThrows() {
    let result = makeResult(tokensPerRun: [128])
    XCTAssertThrowsError(try BenchResult.validate(result, expectedTimedRuns: 3)) { error in
      XCTAssertEqual(
        error as? BenchResultValidationError,
        .sampleCountMismatch(field: "tokens_per_run", expected: 3, actual: 1)
      )
    }
  }

  func testEmptyNativeArraysValidateCleanly() throws {
    // OpenAI-compat (or pre-v2) records leave native arrays empty — that
    // is valid and must not be treated as a sample-count mismatch.
    XCTAssertNoThrow(try BenchResult.validate(makeResult(), expectedTimedRuns: 3))
  }

  func testMismatchedNativeArrayThrows() {
    let result = BenchResult(
      lane: "ollama",
      transport: .httpOllama,
      engine: "ollama",
      model: "llama3.1:8b",
      quant: "Q4_K_M",
      ttftMsPerRun: [166, 170, 164],
      tpsPerRun: [22.1, 21.8, 22.4],
      tokensPerRun: [128, 128, 128],
      specHash: "hash-a",
      hardware: hardware,
      runAlone: true,
      loadDurationMsPerRun: [10, 11]  // length 2 ≠ timed_runs 3
    )
    XCTAssertThrowsError(try BenchResult.validate(result, expectedTimedRuns: 3)) { error in
      XCTAssertEqual(
        error as? BenchResultValidationError,
        .sampleCountMismatch(field: "load_duration_ms_per_run", expected: 3, actual: 2)
      )
    }
  }
}
