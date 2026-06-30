import XCTest
@testable import ManifoldEval
import ManifoldInference

/// Data-gated MTEB STS lane tests using the real STS-Benchmark test split
/// (1,379 sentence pairs from `mteb/stsbenchmark-sts`) with a local Ollama
/// embedding model.
///
/// ## Gates
///
/// Tests skip cleanly when data or Ollama is absent. To run:
///
/// 1. Pre-download corpus and start Ollama:
/// ```
/// scripts/fetch-corpora.sh
/// # or: RUN_STSB_DOWNLOAD=1 to download in-test
/// ```
///
/// 2. Run tests:
/// ```
/// RUN_OLLAMA_EMBED=1 swift test --filter MTEBRealCorpusTests
/// ```
///
/// To let the test itself download STS-B on first run:
/// ```
/// RUN_OLLAMA_EMBED=1 RUN_STSB_DOWNLOAD=1 swift test --filter MTEBRealCorpusTests
/// ```
///
/// ## What is verified
///
/// - ``STSBCorpusFetcher`` downloads + caches the real 1,379-pair STS-B test split.
/// - ``MTEBLane/run(pairs:embedder:modelName:)`` scores the full test split.
/// - Spearman and Pearson correlations are measured against real human gold labels.
/// - Thresholds are conservative: Spearman ≥ 0.80 for nomic-embed-text, which is
///   a well-known sentence-embedding model that scores ~0.85 on STS-B in published
///   benchmarks. The test guards the minimum floor, not the exact published figure.
final class MTEBRealCorpusTests: XCTestCase {

    private var isEmbedEnabled: Bool {
        ProcessInfo.processInfo.environment["RUN_OLLAMA_EMBED"] == "1"
    }

    private var allowDownload: Bool {
        ProcessInfo.processInfo.environment["RUN_STSB_DOWNLOAD"] == "1"
    }

    private var modelName: String {
        ProcessInfo.processInfo.environment["OLLAMA_EMBED_MODEL"]
            ?? OllamaEmbeddingDriver.defaultModel
    }

    /// Resolves the STS-B cache file path.
    ///
    /// Priority:
    /// 1. `STSB_DATA` env var (explicit path override)
    /// 2. `~/.cache/manifold-eval/stsb_test.json` (conventional default)
    private func stsbCacheFile() -> URL {
        if let override = ProcessInfo.processInfo.environment["STSB_DATA"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/manifold-eval/stsb_test.json")
    }

    private func makeDriver() throws -> OllamaEmbeddingDriver {
        let baseStr = ProcessInfo.processInfo.environment["OLLAMA_URL"]
            ?? "http://localhost:11434"
        guard let url = URL(string: baseStr) else {
            throw XCTestError(
                .failureWhileWaiting,
                userInfo: [NSLocalizedDescriptionKey: "Invalid OLLAMA_URL: \(baseStr)"]
            )
        }
        return OllamaEmbeddingDriver(baseURL: url, modelName: modelName)
    }

    // MARK: - Full corpus run

    /// Runs the MTEB STS lane on the real STS-B test split (1,379 pairs) and
    /// asserts meaningful Spearman/Pearson correlations.
    ///
    /// nomic-embed-text's published STS-B score is ~0.85 Spearman. The test
    /// gates on ≥ 0.80 — a conservative floor that any well-tuned sentence
    /// embedder should exceed, while leaving room for model version variation.
    func testLaneOnRealSTSBCorpus() async throws {
        try XCTSkipUnless(
            isEmbedEnabled,
            "set RUN_OLLAMA_EMBED=1 to run live Ollama embedding tests"
        )

        let cacheFile = stsbCacheFile()
        let cacheExists = FileManager.default.fileExists(atPath: cacheFile.path)

        guard cacheExists || allowDownload else {
            throw XCTSkip(
                "STS-B corpus not cached at \(cacheFile.path). "
                + "Run `scripts/fetch-corpora.sh` or set RUN_STSB_DOWNLOAD=1."
            )
        }

        let pairs = try await STSBCorpusFetcher.fetch(cacheFile: cacheFile)
        XCTAssertGreaterThanOrEqual(
            pairs.count, 1_370,
            "STS-B test split should contain ≥ 1,370 pairs (known total: 1,379)"
        )

        let driver = try makeDriver()
        let result = try await MTEBLane.run(
            pairs: pairs,
            embedder: driver,
            modelName: modelName
        )

        XCTAssertEqual(result.pairCount, pairs.count)
        XCTAssertFalse(result.spearmanCorrelation.isNaN,
                       "Spearman must be defined for the full STS-B split")
        XCTAssertFalse(result.pearsonCorrelation.isNaN,
                       "Pearson must be defined for the full STS-B split")

        // nomic-embed-text scores ~0.853 Spearman on the official STS-B test
        // split. Gate at 0.80 (conservative floor).
        XCTAssertGreaterThanOrEqual(
            result.spearmanCorrelation, 0.80,
            "nomic-embed-text Spearman on real STS-B should be ≥ 0.80 "
            + "(got \(result.spearmanCorrelation))"
        )

        XCTAssertGreaterThanOrEqual(
            result.pearsonCorrelation, 0.75,
            "nomic-embed-text Pearson on real STS-B should be ≥ 0.75 "
            + "(got \(result.pearsonCorrelation))"
        )

        // Log real numbers for PR body.
        print("""
        [MTEBRealCorpus] model=\(result.modelName) \
        pairs=\(result.pairCount) \
        spearman=\(String(format: "%.4f", result.spearmanCorrelation)) \
        pearson=\(String(format: "%.4f", result.pearsonCorrelation))
        """)
    }

    // MARK: - Cache idempotency

    /// Verifies ``STSBCorpusFetcher`` reuses the cache file without a network
    /// round-trip on the second call. No embedding required.
    func testFetcherCacheIdempotency() async throws {
        let cacheFile = stsbCacheFile()
        guard FileManager.default.fileExists(atPath: cacheFile.path) || allowDownload else {
            throw XCTSkip(
                "STS-B cache absent. Run `scripts/fetch-corpora.sh` or set RUN_STSB_DOWNLOAD=1."
            )
        }

        // First fetch (download or cache hit).
        let first = try await STSBCorpusFetcher.fetch(cacheFile: cacheFile)
        // Second fetch must be a cache hit.
        let second = try await STSBCorpusFetcher.fetch(cacheFile: cacheFile)

        XCTAssertEqual(first.count, second.count,
                       "cache reuse must return the same number of pairs")
        XCTAssertEqual(first.first?.sentence1, second.first?.sentence1,
                       "cache reuse must produce identical first pair")
    }

    // MARK: - Format verification (non-Ollama)

    /// Loads pairs from cache and verifies the ``STSPair`` field structure.
    func testCachedPairsHaveValidFields() async throws {
        let cacheFile = stsbCacheFile()
        guard FileManager.default.fileExists(atPath: cacheFile.path) || allowDownload else {
            throw XCTSkip(
                "STS-B cache absent. Run `scripts/fetch-corpora.sh` or set RUN_STSB_DOWNLOAD=1."
            )
        }

        let pairs = try await STSBCorpusFetcher.fetch(cacheFile: cacheFile)
        XCTAssertGreaterThan(pairs.count, 0, "should have at least one pair")

        for (index, pair) in pairs.prefix(20).enumerated() {
            XCTAssertFalse(pair.sentence1.isEmpty,
                           "pair[\(index)].sentence1 must not be empty")
            XCTAssertFalse(pair.sentence2.isEmpty,
                           "pair[\(index)].sentence2 must not be empty")
            XCTAssertGreaterThanOrEqual(pair.goldScore, 0.0,
                           "pair[\(index)].goldScore must be ≥ 0 (got \(pair.goldScore))")
            XCTAssertLessThanOrEqual(pair.goldScore, 5.0,
                           "pair[\(index)].goldScore must be ≤ 5 (got \(pair.goldScore))")
        }
    }
}
