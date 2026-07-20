import XCTest
@testable import ManifoldEval

/// `BenchSpec` decode + `specHash` determinism — no network, hosted-CI safe.
final class BenchSpecTests: XCTestCase {

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name).json"
        )
    }

    private func makeSpec(
        modelFamily: String = "llama-3.1-8b-instruct",
        prompt: String = "2 + 2 =",
        temperature: Double = 0.0,
        maxTokens: Int = 128,
        warmupRuns: Int = 1,
        timedRuns: Int = 5
    ) throws -> BenchSpec {
        BenchSpec(
            modelFamily: modelFamily,
            protocolConfig: try .init(
                prompt: prompt,
                temperature: temperature,
                maxTokens: maxTokens,
                warmupRuns: warmupRuns,
                timedRuns: timedRuns
            ),
            lanes: [
                .init(name: "ollama", transport: .httpOllama, endpoint: "http://localhost:11434", model: "llama3.1-8b", quant: "Q4_K_M"),
                .init(name: "omlx", transport: .httpOpenAI, endpoint: "http://127.0.0.1:8000", model: "Meta-Llama-3.1-8B-Instruct-4bit", quant: "4bit", apiKeyEnv: "OMLX_API_KEY"),
            ]
        )
    }

    func testDecodesFixtureSpec() throws {
        let data = try Data(contentsOf: fixture("perf-llama31-8b"))
        let spec = try JSONDecoder().decode(BenchSpec.self, from: data)
        XCTAssertEqual(spec.modelFamily, "llama-3.1-8b-instruct")
        XCTAssertEqual(spec.lanes.count, 2)
        XCTAssertEqual(spec.lanes.map(\.transport), [.httpOllama, .httpOpenAI])
    }

    func testSpecHashIsDeterministicForSameInput() throws {
        XCTAssertEqual(try makeSpec().specHash, try makeSpec().specHash)
    }

    func testSpecHashIgnoresLaneIdentity() throws {
        // Two specs differing ONLY in their lanes (same model_family + protocol)
        // must hash identically — spec_hash asserts "same model, same protocol",
        // not "same lane set". This is what lets two independently-launched
        // lane runs (different endpoints) still collate as comparable.
        let a = try makeSpec()
        let differentLanesSpec = BenchSpec(
            modelFamily: a.modelFamily,
            protocolConfig: a.protocolConfig,
            lanes: [.init(name: "solo-lane", transport: .httpOllama, endpoint: "http://elsewhere:1234", model: "x", quant: "y")]
        )
        XCTAssertEqual(a.specHash, differentLanesSpec.specHash)
    }

    func testSpecHashChangesWithPrompt() throws {
        XCTAssertNotEqual(try makeSpec(prompt: "2 + 2 =").specHash, try makeSpec(prompt: "3 + 3 =").specHash)
    }

    func testSpecHashChangesWithModelFamily() throws {
        XCTAssertNotEqual(
            try makeSpec(modelFamily: "llama-3.1-8b-instruct").specHash,
            try makeSpec(modelFamily: "qwen2.5-7b-instruct").specHash
        )
    }

    func testSpecHashChangesWithProtocolKnobs() throws {
        // Only the knobs that change what's being MEASURED (temperature,
        // max_tokens) are part of workload identity — see
        // `testSpecHashIsStableAcrossRepCounts` for the sampling-parameter
        // counter-case.
        let base = try makeSpec()
        XCTAssertNotEqual(base.specHash, try makeSpec(temperature: 0.8).specHash)
        XCTAssertNotEqual(base.specHash, try makeSpec(maxTokens: 256).specHash)
    }

    func testSpecHashIsStableAcrossRepCounts() throws {
        // Regression test for the specHash landmine: warmup_runs/timed_runs
        // are SAMPLING parameters, not workload identity. Two specs that
        // differ only in how many times the identical workload is measured
        // must share a specHash — otherwise increasing timed_runs on an
        // established spec orphans every historical record measured under
        // the old rep count (they'd stop collating as comparable), which
        // defeats the entire point of publishing repeatable numbers.
        let base = try makeSpec(warmupRuns: 1, timedRuns: 5)
        XCTAssertEqual(base.specHash, try makeSpec(warmupRuns: 1, timedRuns: 10).specHash)
        XCTAssertEqual(base.specHash, try makeSpec(warmupRuns: 3, timedRuns: 5).specHash)
        XCTAssertEqual(base.specHash, try makeSpec(warmupRuns: 0, timedRuns: 1).specHash)
    }

    // MARK: - Protocol validation (P044-style: reject at construction/decode time)

    func testValidProtocolConstructsCleanly() throws {
        // Control: the exact fixture shape every other test in this file
        // relies on must itself construct without throwing.
        let spec = try makeSpec(warmupRuns: 1, timedRuns: 5)
        XCTAssertEqual(spec.protocolConfig.warmupRuns, 1)
        XCTAssertEqual(spec.protocolConfig.timedRuns, 5)
    }

    func testZeroWarmupRunsIsValid() throws {
        // Zero warmups is a legitimate (if inadvisable) choice — only a
        // NEGATIVE count is nonsensical. Only `timedRuns` must be positive.
        let spec = try makeSpec(warmupRuns: 0, timedRuns: 1)
        XCTAssertEqual(spec.protocolConfig.warmupRuns, 0)
    }

    func testNegativeWarmupRunsThrows() {
        XCTAssertThrowsError(try makeSpec(warmupRuns: -1, timedRuns: 5)) { error in
            XCTAssertEqual(error as? BenchSpecValidationError, .invalidWarmupRuns(-1))
        }
    }

    func testZeroTimedRunsThrows() {
        // The exact failure mode this guard exists for: a spec with
        // `timed_runs: 0` would otherwise run zero measured iterations and
        // silently report a median of an empty array.
        XCTAssertThrowsError(try makeSpec(warmupRuns: 1, timedRuns: 0)) { error in
            XCTAssertEqual(error as? BenchSpecValidationError, .invalidTimedRuns(0))
        }
    }

    func testNegativeTimedRunsThrows() {
        XCTAssertThrowsError(try makeSpec(warmupRuns: 1, timedRuns: -3)) { error in
            XCTAssertEqual(error as? BenchSpecValidationError, .invalidTimedRuns(-3))
        }
    }

    func testDecodingSpecWithZeroTimedRunsThrows() throws {
        // The same guard must fire on the JSON decode path, not just the
        // in-code initializer — a hand-edited fixture is just as capable of
        // shipping an unrunnable protocol as in-code construction.
        let json = """
        {
          "model_family": "llama-3.1-8b-instruct",
          "protocol": { "prompt": "2 + 2 =", "temperature": 0.0, "max_tokens": 128, "warmup_runs": 1, "timed_runs": 0 },
          "lanes": [
            { "name": "ollama", "transport": "http-ollama", "endpoint": "http://localhost:11434", "model": "llama3.1-8b", "quant": "Q4_K_M" }
          ]
        }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(BenchSpec.self, from: Data(json.utf8))
        )
    }
}
