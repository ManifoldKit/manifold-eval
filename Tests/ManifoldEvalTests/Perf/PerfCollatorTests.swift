import XCTest
@testable import ManifoldEval

/// Fixture-free (in-code) tests for the perf collator's comparability guards.
/// Unlike `ConformanceRecord`, a `BenchResult` never crosses a process
/// boundary as JSON — the runner produces it in-process — so there's no
/// separate-process JSON fixture to load; hand-built values are the fixture.
final class PerfCollatorTests: XCTestCase {

    private let hardware = HardwareSnapshot(chip: "Apple M-test", memoryGB: 32, os: "macOS 26.0")

    private func makeResult(
        lane: String = "ollama",
        specHash: String = "hash-a",
        quant: String = "Q4_K_M",
        runAlone: Bool = true
    ) -> BenchResult {
        BenchResult(
            lane: lane,
            transport: .httpOllama,
            engine: "ollama",
            model: "llama3.1-8b",
            quant: quant,
            ttftMsPerRun: [166, 170, 164],
            tpsPerRun: [22.1, 21.8, 22.4],
            tokensPerRun: [128, 128, 128],
            specHash: specHash,
            hardware: hardware,
            runAlone: runAlone
        )
    }

    // MARK: - The hard guard (kills the apples-to-oranges trap)

    func testMatchingSpecHashesCollateCleanly() throws {
        let result = try PerfCollator.collate([
            makeResult(lane: "ollama", specHash: "same"),
            makeResult(lane: "omlx", specHash: "same"),
        ])
        XCTAssertEqual(result.results.count, 2)
        XCTAssertTrue(result.diagnostics.isEmpty, "same spec_hash, same quant camp, both run alone — no diagnostics")
    }

    func testMismatchedSpecHashesAreRefused() {
        // This is the load-bearing guard: two results measuring DIFFERENT
        // model_family/protocol pins must never silently collate into one
        // comparable matrix — that's the exact 0.5B-vs-4B apples-to-oranges
        // mistake the harness exists to structurally prevent.
        XCTAssertThrowsError(
            try PerfCollator.collate([
                makeResult(lane: "ollama", specHash: "hash-a"),
                makeResult(lane: "omlx", specHash: "hash-b"),
            ])
        ) { error in
            guard case PerfCollationError.specHashMismatch(let hashes) = error else {
                return XCTFail("expected .specHashMismatch, got \(error)")
            }
            XCTAssertEqual(hashes, ["hash-a", "hash-b"])
        }
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try PerfCollator.collate([])) { error in
            XCTAssertEqual(error as? PerfCollationError, .noInput)
        }
    }

    // MARK: - Quant-camp advisory

    func testCrossQuantCampFlagsAdvisoryWarning() throws {
        let result = try PerfCollator.collate([
            makeResult(lane: "ollama", specHash: "same", quant: "Q4_K_M"),
            makeResult(lane: "omlx", specHash: "same", quant: "4bit"),
        ])
        XCTAssertFalse(result.hasErrors, "a quant mismatch is advisory, not fatal")
        XCTAssertEqual(result.quantCamps, ["4bit", "Q4_K_M"])
        XCTAssertTrue(result.diagnostics.contains {
            $0.severity == .warning && $0.message.contains("quant camp")
        })
    }

    // MARK: - run_alone guard

    func testContendedRunFlagsErrorDiagnostic() throws {
        let result = try PerfCollator.collate([
            makeResult(lane: "ollama", specHash: "same", runAlone: true),
            makeResult(lane: "omlx", specHash: "same", runAlone: false),
        ])
        XCTAssertTrue(result.hasErrors, "a result not run alone must flag as an error, not a warning")
        XCTAssertTrue(result.diagnostics.contains {
            $0.severity == .error && $0.message.contains("run alone")
        })
    }

    // MARK: - Render smoke (deterministic, no live server)

    func testRenderIsDeterministicAndNamesBothLanes() throws {
        let result = try PerfCollator.collate([
            makeResult(lane: "ollama", specHash: "same"),
            makeResult(lane: "omlx", specHash: "same"),
        ])
        let markdown = PerfMatrixReport.render(result)
        XCTAssertTrue(markdown.contains("ollama"))
        XCTAssertTrue(markdown.contains("omlx"))
        XCTAssertEqual(markdown, PerfMatrixReport.render(result))
    }
}
