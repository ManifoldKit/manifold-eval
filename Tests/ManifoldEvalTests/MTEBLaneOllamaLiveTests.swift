import XCTest
@testable import ManifoldEval
import ManifoldInference

/// Live MTEB-STS lane tests against a local Ollama server.
///
/// **Env-gated** (`RUN_OLLAMA_EMBED=1`): CI has no Ollama, so these skip there.
/// Run locally with:
///
///     RUN_OLLAMA_EMBED=1 swift test --filter MTEBLaneOllamaLiveTests
///
/// The model must be present on the local Ollama host (default: nomic-embed-text).
/// Verify with: `ollama list | grep nomic-embed-text`
final class MTEBLaneOllamaLiveTests: XCTestCase {

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["RUN_OLLAMA_EMBED"] == "1"
    }

    private var modelName: String {
        ProcessInfo.processInfo.environment["OLLAMA_EMBED_MODEL"]
            ?? OllamaEmbeddingDriver.defaultModel
    }

    private func makeDriver() throws -> OllamaEmbeddingDriver {
        let baseStr = ProcessInfo.processInfo.environment["OLLAMA_URL"]
            ?? "http://localhost:11434"
        guard let url = URL(string: baseStr) else {
            throw XCTestError(.failureWhileWaiting,
                userInfo: [NSLocalizedDescriptionKey: "Invalid OLLAMA_URL: \(baseStr)"])
        }
        return OllamaEmbeddingDriver(baseURL: url, modelName: modelName)
    }

    // MARK: - Driver unit tests (Ollama-gated)

    func testDriverEmbedReturnsSingleVector() async throws {
        try XCTSkipUnless(isEnabled, "set RUN_OLLAMA_EMBED=1 to run live Ollama embedding tests")
        let driver = try makeDriver()

        let vecs = try await driver.embed(["Hello, world."])
        XCTAssertEqual(vecs.count, 1)
        XCTAssertGreaterThan(vecs[0].count, 0, "embedding should have positive dimension")
        XCTAssertEqual(driver.dimensions, vecs[0].count,
            "reported dimensions should match actual vector length")
    }

    func testDriverEmbedReturnsPairVectors() async throws {
        try XCTSkipUnless(isEnabled, "set RUN_OLLAMA_EMBED=1 to run live Ollama embedding tests")
        let driver = try makeDriver()

        let vecs = try await driver.embed(["A dog runs.", "A cat sleeps."])
        XCTAssertEqual(vecs.count, 2, "embed should return one vector per input")
        XCTAssertEqual(vecs[0].count, vecs[1].count, "both vectors should have the same dimension")
    }

    func testDriverEmptyInputReturnsEmpty() async throws {
        try XCTSkipUnless(isEnabled, "set RUN_OLLAMA_EMBED=1 to run live Ollama embedding tests")
        let driver = try makeDriver()
        let result = try await driver.embed([])
        XCTAssertTrue(result.isEmpty)
    }

    func testDriverIsModelLoadedTrue() throws {
        // isModelLoaded is always true for the Ollama driver (Ollama owns weights).
        // Safe to test without a live Ollama.
        let driver = OllamaEmbeddingDriver()
        XCTAssertTrue(driver.isModelLoaded)
    }

    // MARK: - Cosine sanity (Ollama-gated)

    func testNearSynonymHasHigherCosineThanUnrelatedPair() async throws {
        try XCTSkipUnless(isEnabled, "set RUN_OLLAMA_EMBED=1 to run live Ollama embedding tests")
        let driver = try makeDriver()

        // "A dog ran" / "A dog was running" should rank above "The sun is shining" / "I ate lunch".
        let vecs = try await driver.embed([
            "A dog ran through the field.",
            "A dog was running in the field.",
            "The sun is shining brightly today.",
            "I ate lunch at noon.",
        ])
        XCTAssertEqual(vecs.count, 4)

        let simHigh = CorrelationMath.cosine(vecs[0], vecs[1])
        let simLow = CorrelationMath.cosine(vecs[2], vecs[3])
        XCTAssertFalse(simHigh.isNaN, "near-synonym pair should produce a valid cosine")
        XCTAssertFalse(simLow.isNaN, "unrelated pair should produce a valid cosine")
        XCTAssertGreaterThan(simHigh, simLow,
            "near-synonym cosine (\(simHigh)) should exceed unrelated-pair cosine (\(simLow))")
    }

    // MARK: - Full lane (Ollama-gated)

    func testLaneOnBuiltinFixtureProducesPositiveSpearman() async throws {
        try XCTSkipUnless(isEnabled, "set RUN_OLLAMA_EMBED=1 to run live Ollama embedding tests")
        let driver = try makeDriver()

        let result = try await MTEBLane.run(
            pairs: MTEBLane.builtinFixture,
            embedder: driver,
            modelName: modelName
        )

        XCTAssertEqual(result.pairCount, 15)
        XCTAssertFalse(result.spearmanCorrelation.isNaN, "Spearman should be defined for 15 valid pairs")
        XCTAssertFalse(result.pearsonCorrelation.isNaN, "Pearson should be defined for 15 valid pairs")

        // nomic-embed-text is a quality model. A Spearman ≥ 0.60 on the
        // scaffolded fixture indicates the model's cosine ordering broadly tracks
        // human similarity judgements — a weak threshold that any decent sentence
        // embedder should exceed.
        XCTAssertGreaterThanOrEqual(result.spearmanCorrelation, 0.60,
            "nomic-embed-text Spearman on the STS fixture should be ≥ 0.60 "
            + "(got \(result.spearmanCorrelation))")

        // Log the result so it's visible in `swift test` output for tuning.
        print("""
        [MTEBLane live] model=\(result.modelName) \
        pairs=\(result.pairCount) \
        spearman=\(String(format: "%.4f", result.spearmanCorrelation)) \
        pearson=\(String(format: "%.4f", result.pearsonCorrelation))
        """)
    }

    func testLaneWithCustomPairsViaLoadPairs() async throws {
        try XCTSkipUnless(isEnabled, "set RUN_OLLAMA_EMBED=1 to run live Ollama embedding tests")
        let driver = try makeDriver()

        // A tiny 3-pair subset to exercise the loadPairs → run path end-to-end.
        let subset = Array(MTEBLane.builtinFixture.prefix(3))
        let result = try await MTEBLane.run(pairs: subset, embedder: driver, modelName: modelName)
        XCTAssertEqual(result.pairCount, 3)
        XCTAssertEqual(result.cosines.count, 3)
        for (idx, cosine) in result.cosines.enumerated() {
            XCTAssertFalse(cosine.isNaN, "pair[\(idx)] cosine must not be NaN")
            XCTAssertGreaterThanOrEqual(cosine, -1.0)
            XCTAssertLessThanOrEqual(cosine, 1.0)
        }
    }
}
