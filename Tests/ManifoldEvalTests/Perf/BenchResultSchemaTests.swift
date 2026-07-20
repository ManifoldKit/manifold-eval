import XCTest
@testable import ManifoldEval

/// Coverage for the publication-plumbing additions to ``BenchResult``:
/// `schemaVersion`, p90/p99 percentiles, and provenance fields. Fixture-free,
/// same shape as `BenchResultValidationTests`/`PerfCollatorTests`.
final class BenchResultSchemaTests: XCTestCase {

    private let hardware = HardwareSnapshot(chip: "Apple M-test", memoryGB: 32, os: "macOS 26.0")

    private func makeResult(
        ttftMsPerRun: [Double] = [100, 200, 300, 400, 500, 600, 700, 800, 900, 1000],
        tpsPerRun: [Double] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100],
        schemaVersion: Int = BenchResult.currentSchemaVersion,
        engineVersion: String? = nil,
        modelDigest: String? = nil
    ) -> BenchResult {
        BenchResult(
            lane: "ollama",
            transport: .httpOllama,
            engine: "ollama",
            model: "llama3.1-8b",
            quant: "Q4_K_M",
            ttftMsPerRun: ttftMsPerRun,
            tpsPerRun: tpsPerRun,
            tokensPerRun: Array(repeating: 128, count: ttftMsPerRun.count),
            specHash: "hash-a",
            hardware: hardware,
            runAlone: true,
            schemaVersion: schemaVersion,
            engineVersion: engineVersion,
            modelDigest: modelDigest
        )
    }

    // MARK: - schemaVersion

    func testDefaultSchemaVersionIsCurrentSchemaVersion() {
        XCTAssertEqual(makeResult().schemaVersion, BenchResult.currentSchemaVersion)
        XCTAssertEqual(BenchResult.currentSchemaVersion, 1)
    }

    func testSchemaVersionRoundTripsThroughJSON() throws {
        let result = makeResult(schemaVersion: 1, engineVersion: "0.3.14", modelDigest: "sha256:abc123")
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(BenchResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testDecodingRecordWithoutSchemaVersionFieldDefaultsToOne() throws {
        // A record written by the harness BEFORE schemaVersion existed has
        // no such key at all — it must still decode, as version 1, not fail.
        let json = """
        {
          "lane": "ollama", "transport": "http-ollama", "engine": "ollama",
          "model": "llama3.1-8b", "quant": "Q4_K_M",
          "ttftMsPerRun": [166, 170, 164], "tpsPerRun": [22.1, 21.8, 22.4],
          "tokensPerRun": [128, 128, 128],
          "specHash": "hash-a",
          "hardware": {"chip": "Apple M-test", "memoryGB": 32, "os": "macOS 26.0"},
          "runAlone": true
        }
        """
        let decoded = try JSONDecoder().decode(BenchResult.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.engineVersion, nil)
        XCTAssertEqual(decoded.modelDigest, nil)
        // Percentiles/medians also absent from the legacy shape — must be
        // recomputed from the sample arrays, not defaulted to zero.
        XCTAssertEqual(decoded.medianTtftMs, BenchResult.median([166, 170, 164]))
        XCTAssertEqual(decoded.p90TtftMs, BenchResult.percentile([166, 170, 164], 0.90))
    }

    // MARK: - Percentiles

    func testMedianAndPercentilesOnTenSamples() {
        // 10 evenly-spaced samples [100...1000] step 100 — nearest-rank p90
        // is index 8 (0-based) = 900, p99 is index 9 = 1000.
        let result = makeResult()
        XCTAssertEqual(result.medianTtftMs, 550) // avg of 500, 600
        XCTAssertEqual(result.p90TtftMs, 900)
        XCTAssertEqual(result.p99TtftMs, 1000)
        XCTAssertEqual(result.medianTps, 55)
        XCTAssertEqual(result.p90Tps, 90)
        XCTAssertEqual(result.p99Tps, 100)
    }

    func testPercentileOnSingleSampleReturnsThatSample() {
        XCTAssertEqual(BenchResult.percentile([42], 0.90), 42)
        XCTAssertEqual(BenchResult.percentile([42], 0.99), 42)
    }

    func testPercentileOnEmptyArrayReturnsZero() {
        XCTAssertEqual(BenchResult.percentile([], 0.90), 0)
    }

    // MARK: - Provenance

    func testProvenanceFieldsDefaultToNil() {
        let result = makeResult()
        XCTAssertNil(result.engineVersion)
        XCTAssertNil(result.modelDigest)
    }

    func testProvenanceFieldsRoundTripWhenPresent() throws {
        let result = makeResult(engineVersion: "0.3.14", modelDigest: "sha256:abc123")
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(BenchResult.self, from: data)
        XCTAssertEqual(decoded.engineVersion, "0.3.14")
        XCTAssertEqual(decoded.modelDigest, "sha256:abc123")
    }
}
