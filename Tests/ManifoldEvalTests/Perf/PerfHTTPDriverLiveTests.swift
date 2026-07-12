import XCTest
@testable import ManifoldEval

/// Live smoke test against the two local servers this harness was built to
/// unify: a plain Ollama server and an OpenAI-compatible local server (OMLX).
/// **Env-gated** (`RUN_PERF_LIVE=1`): CI has neither server, so this skips
/// there. Run locally with:
///
///     RUN_PERF_LIVE=1 swift test --filter PerfHTTPDriverLiveTests
///
/// This is the harness's own "is it live" proof (per AGENTS.md principle
/// #10): it drives the real spec → runner → collator → renderer pipeline
/// against real servers and asserts the numbers land in the ballpark measured
/// by hand when this harness was designed (~22 tok/s / ~166ms TTFT for
/// ollama; ~21 tok/s / ~376ms TTFT for OMLX). A wide tolerance band absorbs
/// normal run-to-run variance — the point is proving the pipeline measures
/// something real, not pinning an exact throughput regression gate.
final class PerfHTTPDriverLiveTests: XCTestCase {

    private var isEnabled: Bool { ProcessInfo.processInfo.environment["RUN_PERF_LIVE"] == "1" }

    func testFullPipelineAgainstLocalServers() async throws {
        try XCTSkipUnless(isEnabled, "set RUN_PERF_LIVE=1 to run the live perf-harness smoke")

        let data = try Data(contentsOf: XCTUnwrap(
            Bundle.module.url(forResource: "perf-llama31-8b", withExtension: "json", subdirectory: "Fixtures")
        ))
        var spec = try JSONDecoder().decode(BenchSpec.self, from: data)
        // Keep the live smoke fast: fewer timed runs than a real report would use.
        spec = BenchSpec(
            modelFamily: spec.modelFamily,
            protocolConfig: .init(
                prompt: spec.protocolConfig.prompt,
                temperature: spec.protocolConfig.temperature,
                maxTokens: 64,
                warmupRuns: 1,
                timedRuns: 3
            ),
            lanes: spec.lanes
        )

        let results = try await PerfRunner.runSpec(spec, onProgress: { print($0) })
        XCTAssertEqual(results.count, 2)
        for result in results {
            XCTAssertTrue(result.runAlone, "lanes must be serialized")
            XCTAssertEqual(result.tpsPerRun.count, 3)
        }

        let collated = try PerfCollator.collate(results)
        XCTAssertFalse(collated.hasErrors)
        let markdown = PerfMatrixReport.render(collated)
        XCTAssertTrue(markdown.contains("ollama"))
        XCTAssertTrue(markdown.contains("omlx"))

        let ollama = try XCTUnwrap(results.first { $0.lane == "ollama" })
        let omlx = try XCTUnwrap(results.first { $0.lane == "omlx" })

        // Wide bands: this proves the pipeline measures something in the
        // right ballpark, not an exact perf regression gate.
        XCTAssertGreaterThan(ollama.medianTps, 5, "ollama TPS implausibly low — pipeline likely broken")
        XCTAssertLessThan(ollama.medianTtftMs, 2000, "ollama TTFT implausibly high")
        XCTAssertGreaterThan(omlx.medianTps, 5, "OMLX TPS implausibly low — pipeline likely broken")
        XCTAssertLessThan(omlx.medianTtftMs, 3000, "OMLX TTFT implausibly high")

        print(markdown)
    }
}
