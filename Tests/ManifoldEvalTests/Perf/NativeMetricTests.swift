import XCTest
@testable import ManifoldEval

/// Unit coverage for native Ollama timing math and OpenAI-derived decode TPS
/// — no network. Complements the env-gated live smoke.
final class NativeMetricTests: XCTestCase {

    func testTokensPerSecondFromNanos() throws {
        // 128 tokens in 2_000_000_000 ns (2s) → 64 tok/s.
        let tps = try XCTUnwrap(
            PerfHTTPDriver.tokensPerSecond(count: 128, durationNanos: 2_000_000_000)
        )
        XCTAssertEqual(tps, 64, accuracy: 0.001)
    }

    func testTokensPerSecondNilOnMissingOrZero() {
        XCTAssertNil(PerfHTTPDriver.tokensPerSecond(count: nil, durationNanos: 1_000_000_000))
        XCTAssertNil(PerfHTTPDriver.tokensPerSecond(count: 10, durationNanos: nil))
        XCTAssertNil(PerfHTTPDriver.tokensPerSecond(count: 0, durationNanos: 1_000_000_000))
        XCTAssertNil(PerfHTTPDriver.tokensPerSecond(count: 10, durationNanos: 0))
    }

    func testWallTpsIsPrefillIncluded() {
        // 64 tokens in 2s wall → 32 tok/s regardless of TTFT.
        let m = SingleRunMeasurement(ttftMs: 500, tokens: 64, wallSeconds: 2.0, generateTps: 64)
        XCTAssertEqual(m.tps, 32, accuracy: 0.001)
        XCTAssertEqual(m.generateTps, 64)
    }

    func testReportIncludesNativeSplitAndPercentilePolicy() throws {
        let hardware = HardwareSnapshot(chip: "Apple M-test", memoryGB: 24, os: "macOS 26.0")
        let result = BenchResult(
            lane: "ollama",
            transport: .httpOllama,
            engine: "ollama",
            model: "llama3.1:8b",
            quant: "Q4_K_M",
            ttftMsPerRun: (1...20).map { Double($0 * 10) },
            tpsPerRun: (1...20).map { Double($0) },
            tokensPerRun: Array(repeating: 16, count: 20),
            specHash: "abc123def456",
            hardware: hardware,
            runAlone: true,
            engineVersion: "0.32.0",
            modelDigest: "46e0c10c039e0191",
            loadDurationMsPerRun: Array(repeating: Optional(12.0), count: 20),
            prefillTpsPerRun: Array(repeating: Optional(400.0), count: 20),
            generateTpsPerRun: Array(repeating: Optional(22.0), count: 20),
            coldLoadDurationMs: 3500,
            coldTtftMs: 3700
        )
        let collated = try PerfCollator.collate([result])
        let md = PerfMatrixReport.render(collated)
        XCTAssertTrue(md.contains("Percentile policy"))
        XCTAssertTrue(md.contains("p90"))
        XCTAssertTrue(md.contains("Native split"))
        XCTAssertTrue(md.contains("prefill included") || md.contains("prefill-included") || md.contains("**prefill included**"))
        XCTAssertTrue(md.contains("3500") || md.contains("3500.0"))
        XCTAssertTrue(md.contains("0.32.0"))
        // n=20 publishes p90 columns
        XCTAssertTrue(result.publishesP90)
        XCTAssertTrue(md.contains("TTFT p90"))
    }

    func testReportOmitsP90ColumnsWhenSampleCountBelowThreshold() throws {
        let hardware = HardwareSnapshot(chip: "Apple M-test", memoryGB: 24, os: "macOS 26.0")
        let result = BenchResult(
            lane: "ollama",
            transport: .httpOllama,
            engine: "ollama",
            model: "llama3.1:8b",
            quant: "Q4_K_M",
            ttftMsPerRun: [100, 110, 120, 130, 140],
            tpsPerRun: [20, 21, 22, 23, 24],
            tokensPerRun: [128, 128, 128, 128, 128],
            specHash: "abc",
            hardware: hardware,
            runAlone: true
        )
        let md = PerfMatrixReport.render(try PerfCollator.collate([result]))
        XCTAssertFalse(result.publishesP90)
        XCTAssertFalse(md.contains("TTFT p90"), "p90 column must not appear for n<20 publication grid")
        XCTAssertTrue(md.contains("min/max"))
    }
}
