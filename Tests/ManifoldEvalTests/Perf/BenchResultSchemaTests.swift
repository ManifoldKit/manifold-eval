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
        XCTAssertEqual(BenchResult.currentSchemaVersion, 2)
    }

    func testSchemaVersionRoundTripsThroughJSON() throws {
        let result = makeResult(schemaVersion: 2, engineVersion: "0.3.14", modelDigest: "sha256:abc123")
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

    // MARK: - Percentile degeneracy disclosure (nearest-rank collapses at small n)

    func testDegeneracyFlaggedAtFiveSamples() {
        // n=5: ceil(0.90*5) == ceil(0.99*5) == 5 — p90 and p99 both resolve
        // to the single slowest sample. This is the exact repo-example
        // fixture shape (perf-llama31-8b.json has timed_runs: 5) and MUST be
        // flagged so a report never presents max(samples) twice under two
        // statistical-sounding labels.
        let result = makeResult(
            ttftMsPerRun: [100, 200, 300, 400, 500],
            tpsPerRun: [10, 20, 30, 40, 50]
        )
        XCTAssertEqual(result.p90Rank, 5)
        XCTAssertEqual(result.p99Rank, 5)
        XCTAssertTrue(result.percentilesAreDegenerate)
        XCTAssertEqual(result.p90TtftMs, result.p99TtftMs)
        XCTAssertEqual(result.p90TtftMs, 500, "p90 at n=5 is exactly the sample maximum")
    }

    func testDegeneracyNotFlaggedAtOneHundredSamples() {
        // n=100 is the first sample size where p99 stops being a synonym for
        // the maximum (ceil(0.99*100) == 99, not 100) and p90/p99 resolve to
        // genuinely distinct ranks.
        let samples = (1...100).map { Double($0) }
        let result = makeResult(ttftMsPerRun: samples, tpsPerRun: samples)
        XCTAssertEqual(result.p90Rank, 90)
        XCTAssertEqual(result.p99Rank, 99)
        XCTAssertFalse(result.percentilesAreDegenerate)
        XCTAssertNotEqual(result.p90TtftMs, result.p99TtftMs)
        XCTAssertNotEqual(result.p99TtftMs, samples.max())
    }

    func testDegeneracyAtThirtySamplesMatchesTonightsPlannedRepCount() {
        // The orchestrator's planned campaign uses timed_runs: 30 — p90
        // becomes a genuine distinct rank (27 of 30) but p99 is STILL the
        // sample maximum (rank 30 of 30) at this n. A report reading this
        // record must still disclose that p99 == max here, even though p90
        // is no longer degenerate.
        let samples = (1...30).map { Double($0) }
        let result = makeResult(ttftMsPerRun: samples, tpsPerRun: samples)
        XCTAssertEqual(result.p90Rank, 27)
        XCTAssertEqual(result.p99Rank, 30)
        XCTAssertFalse(result.percentilesAreDegenerate, "p90 and p99 are distinct ranks at n=30")
        XCTAssertEqual(result.p99TtftMs, samples.max(), "p99 is still exactly the maximum at n=30")
    }

    func testRankFieldsRoundTripThroughJSONAndLegacyRecordsRecompute() throws {
        let result = makeResult(
            ttftMsPerRun: [100, 200, 300, 400, 500],
            tpsPerRun: [10, 20, 30, 40, 50]
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(BenchResult.self, from: data)
        XCTAssertEqual(decoded.p90Rank, result.p90Rank)
        XCTAssertEqual(decoded.p99Rank, result.p99Rank)

        // A record predating p90Rank/p99Rank (no such keys at all) must
        // still decode, recomputing the ranks from the sample arrays rather
        // than failing or silently reporting a wrong/degenerate default.
        let json = """
        {
          "lane": "ollama", "transport": "http-ollama", "engine": "ollama",
          "model": "llama3.1-8b", "quant": "Q4_K_M",
          "ttftMsPerRun": [100, 200, 300, 400, 500],
          "tpsPerRun": [10, 20, 30, 40, 50],
          "tokensPerRun": [128, 128, 128, 128, 128],
          "specHash": "hash-a",
          "hardware": {"chip": "Apple M-test", "memoryGB": 32, "os": "macOS 26.0"},
          "runAlone": true
        }
        """
        let legacy = try JSONDecoder().decode(BenchResult.self, from: Data(json.utf8))
        XCTAssertEqual(legacy.p90Rank, 5)
        XCTAssertEqual(legacy.p99Rank, 5)
        XCTAssertTrue(legacy.percentilesAreDegenerate)
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

    // MARK: - Native split + min/max + cold (schema v2)

    func testMinMaxComputedFromSamples() {
        let result = makeResult(
            ttftMsPerRun: [100, 200, 300, 400, 500],
            tpsPerRun: [10, 20, 30, 40, 50]
        )
        XCTAssertEqual(result.minTtftMs, 100)
        XCTAssertEqual(result.maxTtftMs, 500)
        XCTAssertEqual(result.minTps, 10)
        XCTAssertEqual(result.maxTps, 50)
    }

    func testNativeSplitMediansIgnoreNils() {
        let result = BenchResult(
            lane: "ollama",
            transport: .httpOllama,
            engine: "ollama",
            model: "llama3.1:8b",
            quant: "Q4_K_M",
            ttftMsPerRun: [100, 200, 300],
            tpsPerRun: [10, 20, 30],
            tokensPerRun: [8, 8, 8],
            specHash: "hash-a",
            hardware: hardware,
            runAlone: true,
            loadDurationMsPerRun: [50, nil, 70],
            prefillTpsPerRun: [100, 200, nil],
            generateTpsPerRun: [20, 30, 40],
            coldLoadDurationMs: 3500,
            coldTtftMs: 3800,
            coldPrefillTps: 90,
            coldGenerateTps: 22
        )
        XCTAssertEqual(result.medianLoadDurationMs, 60) // median of [50, 70]
        XCTAssertEqual(result.medianPrefillTps, 150) // median of [100, 200]
        XCTAssertEqual(result.medianGenerateTps, 30)
        XCTAssertEqual(result.coldLoadDurationMs, 3500)
        XCTAssertEqual(result.coldTtftMs, 3800)
    }

    func testNativeSplitAndColdRoundTripThroughJSON() throws {
        let result = BenchResult(
            lane: "ollama",
            transport: .httpOllama,
            engine: "ollama",
            model: "llama3.1:8b",
            quant: "Q4_K_M",
            ttftMsPerRun: [100, 200],
            tpsPerRun: [10, 20],
            tokensPerRun: [8, 8],
            specHash: "hash-a",
            hardware: hardware,
            runAlone: true,
            loadDurationMsPerRun: [12.5, 11.0],
            prefillTpsPerRun: [400, 420],
            generateTpsPerRun: [22, 23],
            coldLoadDurationMs: 3000,
            coldTtftMs: 3200
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(BenchResult.self, from: data)
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.schemaVersion, 2)
    }

    func testLegacyRecordDecodesWithoutNativeFields() throws {
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
        XCTAssertEqual(decoded.loadDurationMsPerRun, [])
        XCTAssertNil(decoded.medianLoadDurationMs)
        XCTAssertNil(decoded.coldTtftMs)
        XCTAssertEqual(decoded.minTtftMs, 164)
        XCTAssertEqual(decoded.maxTtftMs, 170)
    }

    func testPublicationThresholds() {
        XCTAssertFalse(makeResult(ttftMsPerRun: Array(repeating: 1, count: 5), tpsPerRun: Array(repeating: 1, count: 5)).publishesP90)
        XCTAssertTrue(makeResult(ttftMsPerRun: Array(repeating: 1, count: 20), tpsPerRun: Array(repeating: 1, count: 20)).publishesP90)
        XCTAssertFalse(makeResult(ttftMsPerRun: Array(repeating: 1, count: 30), tpsPerRun: Array(repeating: 1, count: 30)).publishesP99)
        XCTAssertTrue(makeResult(ttftMsPerRun: Array(repeating: 1, count: 100), tpsPerRun: Array(repeating: 1, count: 100)).publishesP99)
    }
}
