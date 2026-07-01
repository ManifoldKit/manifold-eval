import XCTest
@testable import ManifoldEval
import ManifoldInference
import ManifoldOllama
import ManifoldTools

/// Live end-to-end smoke test: drive a real local Ollama model through
/// `BFCLLane.generateResponses` over the small committed BFCL fixture (NOT the
/// full Gorilla corpus — that's a manual/overnight operational run, never CI),
/// then score the result through the existing `bfcl` scoring path.
///
/// **Env-gated** (`RUN_OLLAMA_LIVE=1`), consistent with ``OllamaLiveSmokeTests``
/// / ``BFCLRealCorpusTests`` — CI has no Ollama, so this skips there.
///
///     RUN_OLLAMA_LIVE=1 OLLAMA_MODEL=llama3.1-8b:latest \
///       swift test --filter BFCLGenerateLiveTests
///
/// This proves the full generate→score round trip actually works against a
/// live model, not just a synthetic `emit` closure.
final class BFCLGenerateLiveTests: XCTestCase {

    private var isEnabled: Bool { ProcessInfo.processInfo.environment["RUN_OLLAMA_LIVE"] == "1" }
    private var model: String { ProcessInfo.processInfo.environment["OLLAMA_MODEL"] ?? "llama3.1-8b:latest" }
    private var baseURLString: String { ProcessInfo.processInfo.environment["OLLAMA_URL"] ?? "http://localhost:11434" }

    private func bfclFixtureDir() throws -> URL {
        guard let resourceURL = Bundle.module.resourceURL else {
            throw XCTSkip("Bundle.module.resourceURL unavailable — skipping fixture-based test")
        }
        return resourceURL.appendingPathComponent("Fixtures").appendingPathComponent("BFCL")
    }

    @MainActor
    func testGenerateThenScoreRoundTrip_liveOllama() async throws {
        try XCTSkipUnless(isEnabled, "set RUN_OLLAMA_LIVE=1 to run the live bfcl-generate smoke test")

        let dir = try bfclFixtureDir()
        guard let baseURL = URL(string: baseURLString) else {
            throw XCTSkip("invalid OLLAMA_URL '\(baseURLString)'")
        }

        let ollama = OllamaBackend(urlSession: nil)
        ollama.configure(baseURL: baseURL, modelName: model)
        try await ollama.loadModel(from: baseURL, plan: .cloud())
        let service = InferenceService(backend: ollama, name: "ollama", modelName: model, toolRegistry: ToolRegistry())

        let lane = BFCLLane()
        let result = await lane.generateResponses(
            categories: [.simple],
            corpusSource: .localDirectory(dir),
            emit: { testCase in
                try await BFCLRunner.emittedCalls(for: testCase, service: service, timeoutSeconds: 60)
            }
        )

        XCTAssertEqual(result.attempted, 3, "simple fixture has 3 cases")
        XCTAssertEqual(result.entries.count, 3)

        // Write the generated entries to a temp JSONL exactly as the CLI does,
        // then feed straight into the existing scorer — no adapter.
        let encoder = JSONEncoder()
        let jsonl = try result.entries
            .map { try String(decoding: encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
        let responsesURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bfcl-generate-live-\(UUID().uuidString).jsonl")
        try jsonl.write(to: responsesURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: responsesURL) }

        let (scoreResult, markdown) = try await lane.cliRun(corpusDir: dir, responsesURL: responsesURL)
        let simple = try XCTUnwrap(scoreResult.categoryResults.first { $0.category == .simple })
        XCTAssertEqual(simple.total, 3)
        XCTAssertGreaterThanOrEqual(simple.passed, 0)
        XCTAssertLessThanOrEqual(simple.passed, 3)
        XCTAssert(markdown.contains("BFCL Results"))

        print("[BFCLGenerateLiveTests] \(model): \(simple.passed)/\(simple.total) simple cases passed (\(result.errored) errored)")
    }
}
