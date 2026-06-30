import XCTest
@testable import ManifoldEval
import ManifoldInference

/// Smoke tests for the three CLI lane-runner entry points (ifeval / bfcl / mteb).
///
/// All tests run against committed fixtures and require neither a live model nor
/// network access. The MTEB live path is env-gated (`RUN_OLLAMA_EMBED=1`) and
/// exercises the full `MTEBLane.run` → `renderMarkdown` round-trip.
final class CLILaneRunnerSmokeTests: XCTestCase {

    // MARK: - Helpers

    private func bfclFixtureDir() throws -> URL {
        guard let resourceURL = Bundle.module.resourceURL else {
            throw XCTSkip("Bundle.module.resourceURL unavailable — skipping fixture-based test")
        }
        return resourceURL
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("BFCL")
    }

    private func ifEvalFixtureURL() throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: "ifeval", withExtension: "jsonl", subdirectory: "Fixtures"),
            "Missing Fixtures/ifeval.jsonl from test bundle"
        )
    }

    private func writeTempJSONL(_ content: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("manifold-eval-smoke-\(UUID().uuidString).jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - IFEval

    func testIFEvalSmokeWithSyntheticResponses() throws {
        let corpusURL = try ifEvalFixtureURL()

        // Build responses for the first 5 cases; others score against "".
        let cases = try IFEvalCorpus.load(from: corpusURL)
        XCTAssertGreaterThan(cases.count, 0, "fixture must not be empty")

        let responseLines = cases.prefix(5).map { c in
            #"{"key":"\#(c.key)","response":"no commas here at all"}"#
        }.joined(separator: "\n")
        let responsesURL = try writeTempJSONL(responseLines)
        defer { try? FileManager.default.removeItem(at: responsesURL) }

        let lane = IFEvalLane()
        let result = try lane.cliRun(corpusURL: corpusURL, responsesURL: responsesURL)

        // All corpus cases are covered (missing responses score against "").
        XCTAssertEqual(result.score.totalCases, cases.count,
            "totalCases must equal corpus size; missing responses score as empty string")
        XCTAssertGreaterThanOrEqual(result.score.strictAccuracy, 0.0)
        XCTAssertLessThanOrEqual(result.score.strictAccuracy, 1.0)

        XCTAssert(result.markdown.contains("IFEval Results"),
            "report must have '# IFEval Results' header")
        XCTAssert(result.markdown.contains("Strict Accuracy"),
            "report must contain 'Strict Accuracy' row")
        XCTAssert(result.markdown.contains("Total Cases"),
            "report must contain 'Total Cases' row")
    }

    func testIFEvalResponsesLoaderSkipsBlanks() throws {
        let jsonl = """
        {"key":"1","response":"hello"}

        {"key":"2","response":"world"}

        """
        let url = try writeTempJSONL(jsonl)
        defer { try? FileManager.default.removeItem(at: url) }

        let entries = try IFEvalLane.loadResponses(from: url)
        XCTAssertEqual(entries.count, 2, "blank lines must be skipped")
        XCTAssertEqual(entries[0].key, "1")
        XCTAssertEqual(entries[1].key, "2")
    }

    func testIFEvalMarkdownRendering() {
        let score = IFEvalAggregateScore(
            strictAccuracy: 0.75,
            totalCases: 4,
            passedCases: 3,
            perInstructionAccuracy: ["punctuation:no_comma": 1.0]
        )
        let markdown = IFEvalLane.renderMarkdown(score: score, modelName: "test-model")

        XCTAssert(markdown.contains("IFEval Results"))
        XCTAssert(markdown.contains("test-model"))
        XCTAssert(markdown.contains("75.0%"))
        XCTAssert(markdown.contains("4"))
        XCTAssert(markdown.contains("punctuation:no_comma"))
    }

    // MARK: - BFCL

    func testBFCLSmokeWithEmptyResponses() async throws {
        let corpusDir = try bfclFixtureDir()

        // Empty responses file → all non-irrelevance cases fail, irrelevance passes.
        let responsesURL = try writeTempJSONL("")
        defer { try? FileManager.default.removeItem(at: responsesURL) }

        let lane = BFCLLane()
        let (result, markdown) = try await lane.cliRun(corpusDir: corpusDir, responsesURL: responsesURL)

        XCTAssertFalse(result.categoryResults.isEmpty, "should have at least one category result")
        XCTAssert(markdown.contains("BFCL Results"),
            "report must have '# BFCL Results' header")
        XCTAssert(markdown.contains("Overall:"),
            "report must contain 'Overall:' summary line")

        // Irrelevance cases pass when no calls are emitted.
        if let irr = result.categoryResults.first(where: { $0.category == .irrelevance }),
           !irr.skipped {
            XCTAssertEqual(irr.passed, irr.total,
                "irrelevance category should pass with empty emit")
        }
    }

    func testBFCLSmokeWithPrecomputedResponses() async throws {
        let corpusDir = try bfclFixtureDir()

        // Provide the correct tool call for simple_0 only.
        let responseLines = """
        {"id":"simple_0","calls":[{"id":"1","toolName":"calculate_triangle_area","arguments":"{\\"base\\":10,\\"height\\":5}"}]}
        """
        let responsesURL = try writeTempJSONL(responseLines)
        defer { try? FileManager.default.removeItem(at: responsesURL) }

        let lane = BFCLLane()
        let (result, markdown) = try await lane.cliRun(corpusDir: corpusDir, responsesURL: responsesURL)

        let simple = result.categoryResults.first { $0.category == .simple }
        if let simple, !simple.skipped {
            XCTAssertEqual(simple.passed, 1, "simple_0 should pass with the correct call")
            XCTAssertEqual(simple.total, 3)
        }

        XCTAssert(markdown.contains("simple"), "report must mention 'simple' category")
    }

    func testBFCLResponsesLoaderDecodesToolCalls() throws {
        let jsonl = #"""
        {"id":"test_0","calls":[{"id":"c1","toolName":"add","arguments":"{\"a\":1,\"b\":2}"}]}
        """#
        let url = try writeTempJSONL(jsonl)
        defer { try? FileManager.default.removeItem(at: url) }

        let entries = try BFCLLane.loadResponses(from: url)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, "test_0")
        XCTAssertEqual(entries[0].calls.count, 1)
        XCTAssertEqual(entries[0].calls[0].toolName, "add")
    }

    func testBFCLMarkdownRendering() {
        let catResults: [BFCLLane.CategoryResult] = [
            .init(category: .simple,   total: 3, passed: 3),
            .init(category: .multiple, total: 3, passed: 2),
        ]
        let result = BFCLLane.LaneResult(categoryResults: catResults, fullCorpusSourced: false)
        let markdown = BFCLLane.renderMarkdown(result: result)

        XCTAssert(markdown.contains("BFCL Results"))
        XCTAssert(markdown.contains("simple"))
        XCTAssert(markdown.contains("multiple"))
        XCTAssert(markdown.contains("Overall:"))
        XCTAssert(markdown.contains("Fixture"))
    }

    // MARK: - MTEB (no embedder — tests rendering and dataset loading)

    func testMTEBRenderMarkdownStructure() {
        let syntheticResult = MTEBLaneResult(
            modelName: "nomic-embed-text",
            pairCount: 15,
            spearmanCorrelation: 0.8234,
            pearsonCorrelation: 0.7912,
            cosines: Array(repeating: 0.8, count: 15)
        )
        let markdown = MTEBLane.renderMarkdown(result: syntheticResult)

        XCTAssert(markdown.contains("MTEB-STS Results"),
            "report must have '# MTEB-STS Results' header")
        XCTAssert(markdown.contains("Spearman"), "report must contain Spearman row")
        XCTAssert(markdown.contains("Pearson"),  "report must contain Pearson row")
        XCTAssert(markdown.contains("nomic-embed-text"), "report must include model name")
        XCTAssert(markdown.contains("0.8234"), "report must include Spearman value")
        XCTAssert(markdown.contains("15"),     "report must include pair count")
    }

    func testMTEBLoadBuiltinFixture() throws {
        let (pairs, label) = try MTEBLane.loadPairsOrBuiltin(from: "fixture")
        XCTAssertEqual(pairs.count, 15, "built-in fixture must have 15 pairs")
        XCTAssert(label.lowercased().contains("scaffold") || label.lowercased().contains("built-in"),
            "label should indicate built-in scaffold, got: \(label)")
    }

    func testMTEBLoadNonExistentPathFallsBackToFixture() throws {
        let (pairs, label) = try MTEBLane.loadPairsOrBuiltin(from: "/tmp/does-not-exist-\(UUID()).json")
        XCTAssertEqual(pairs.count, 15, "missing file should fall back to built-in fixture")
        XCTAssert(label.contains("not found"), "label should mention fallback reason")
    }

    func testMTEBLoadPairsOrBuiltinFromValidJSON() throws {
        let samplePairs: [STSPair] = [
            STSPair(sentence1: "A cat sleeps.", sentence2: "A cat naps.", goldScore: 4.5),
            STSPair(sentence1: "Rain falls.", sentence2: "Sun shines.", goldScore: 0.5),
        ]
        let data = try JSONEncoder().encode(samplePairs)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mteb-smoke-\(UUID().uuidString).json")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let (pairs, label) = try MTEBLane.loadPairsOrBuiltin(from: url.path)
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(label, url.lastPathComponent)
    }

    // MARK: - MTEB live (env-gated)

    func testMTEBLiveRunProducesValidReport() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_OLLAMA_EMBED"] == "1",
            "set RUN_OLLAMA_EMBED=1 to run live MTEB CLI smoke test"
        )
        let model = ProcessInfo.processInfo.environment["OLLAMA_EMBED_MODEL"]
            ?? OllamaEmbeddingDriver.defaultModel
        let (pairs, _) = try MTEBLane.loadPairsOrBuiltin(from: "fixture")
        let driver = OllamaEmbeddingDriver(modelName: model)
        let result = try await MTEBLane.run(pairs: pairs, embedder: driver, modelName: model)
        let markdown = MTEBLane.renderMarkdown(result: result)

        XCTAssert(markdown.contains("MTEB-STS Results"))
        XCTAssertFalse(result.spearmanCorrelation.isNaN, "Spearman must not be NaN")
        XCTAssertFalse(result.pearsonCorrelation.isNaN,  "Pearson must not be NaN")
        XCTAssertEqual(result.pairCount, 15)
    }
}
