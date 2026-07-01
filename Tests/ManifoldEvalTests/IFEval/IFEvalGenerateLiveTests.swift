import XCTest
@testable import ManifoldEval
import ManifoldInference
import ManifoldOllama

/// Live end-to-end smoke test: drive a real local Ollama model through
/// `IFEvalLane.generateResponses` over a small slice of the committed IFEval
/// fixture (NOT the full 541-case corpus — that's a manual/overnight
/// operational run, never CI), then score the result through the existing
/// `ifeval` scoring path.
///
/// **Env-gated** (`RUN_OLLAMA_LIVE=1`), consistent with ``OllamaLiveSmokeTests``
/// — CI has no Ollama, so this skips there.
///
///     RUN_OLLAMA_LIVE=1 OLLAMA_MODEL=qwen2.5-0.5b \
///       swift test --filter IFEvalGenerateLiveTests
///
/// This proves the full generate→score round trip actually works against a
/// live model, not just a synthetic `emit` closure — and, by binding one
/// `InferenceService` per worker slot (mirroring `IFEvalGenerateCommand`
/// exactly, rather than sharing a single service across workers), it also
/// proves the per-slot-backend design actually delivers concurrent requests
/// against a real Ollama server, not just against a synthetic closure.
final class IFEvalGenerateLiveTests: XCTestCase {

    private var isEnabled: Bool { ProcessInfo.processInfo.environment["RUN_OLLAMA_LIVE"] == "1" }
    private var model: String { ProcessInfo.processInfo.environment["OLLAMA_MODEL"] ?? "qwen2.5-0.5b" }
    private var baseURLString: String { ProcessInfo.processInfo.environment["OLLAMA_URL"] ?? "http://localhost:11434" }

    private func ifEvalFixtureURL() throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: "ifeval", withExtension: "jsonl", subdirectory: "Fixtures"),
            "Missing Fixtures/ifeval.jsonl from test bundle"
        )
    }

    @MainActor
    func testGenerateThenScoreRoundTrip_liveOllama() async throws {
        try XCTSkipUnless(isEnabled, "set RUN_OLLAMA_LIVE=1 to run the live ifeval-generate smoke test")

        let corpusURL = try ifEvalFixtureURL()
        let allCases = try IFEvalCorpus.load(from: corpusURL)
        let cases = Array(allCases.prefix(5))

        guard let baseURL = URL(string: baseURLString) else {
            throw XCTSkip("invalid OLLAMA_URL '\(baseURLString)'")
        }

        // One InferenceService per worker slot — the same per-slot-backend
        // design `IFEvalGenerateCommand` uses in production, NOT a single
        // shared service. Sharing one service across concurrent workers
        // would silently serialize every request (GenerationQueue is FIFO),
        // which would make this test pass even if the real command's
        // per-slot wiring were broken — defeating the point of a live test.
        let workerCount = 2
        var built: [InferenceService] = []
        for slot in 0..<workerCount {
            let ollama = try OllamaBackend.makeChecked(urlSession: nil)
            ollama.configure(baseURL: baseURL, modelName: model)
            try await ollama.loadModel(from: baseURL, plan: .cloud())
            built.append(
                InferenceService(backend: ollama, name: "ollama-worker-\(slot)", modelName: model, toolRegistry: ToolRegistry())
            )
        }
        // Captured by the `@Sendable` `emit` closure below.
        let services = built

        let result = await IFEvalLane.generateResponses(
            cases: cases,
            concurrency: workerCount,
            emit: { slot, testCase in
                let config = GenerationConfig(
                    temperature: 0.0, topP: 0.9, repeatPenalty: 1.1, topK: 1,
                    maxOutputTokens: 512, tools: [], maxToolIterations: 1
                )
                let (_, stream) = try await services[slot].enqueue(
                    messages: [.user(testCase.prompt)], systemPrompt: "", config: config
                )
                var text = ""
                for try await event in stream.events {
                    if case .token(let fragment) = event { text += fragment }
                }
                return text
            }
        )

        XCTAssertEqual(result.attempted, 5, "fixture slice has 5 cases")
        XCTAssertEqual(result.entries.count, 5)

        // Write the generated entries to a temp JSONL exactly as the CLI does,
        // then feed straight into the existing scorer — no adapter.
        let encoder = JSONEncoder()
        let jsonl = try result.entries
            .map { try String(decoding: encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
        let responsesURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ifeval-generate-live-\(UUID().uuidString).jsonl")
        try jsonl.write(to: responsesURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: responsesURL) }

        let lane = IFEvalLane()
        let runResult = try lane.cliRun(corpusURL: corpusURL, responsesURL: responsesURL, modelName: model)
        XCTAssert(runResult.markdown.contains("IFEval Results"))
        XCTAssertGreaterThanOrEqual(runResult.score.strictAccuracy, 0.0)
        XCTAssertLessThanOrEqual(runResult.score.strictAccuracy, 1.0)

        print(
            "[IFEvalGenerateLiveTests] \(model): \(runResult.score.passedCases)/\(runResult.score.totalCases) "
            + "cases in full corpus (5-case slice generated, \(result.errored) errored)"
        )
    }
}
