import XCTest
@testable import ManifoldEval

/// `BenchSpec` decode + `specHash` determinism — no network, hosted-CI safe.
final class BenchSpecTests: XCTestCase {

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name).json"
        )
    }

    private func makeSpec(
        modelFamily: String = "llama-3.1-8b-instruct",
        prompt: String = "2 + 2 =",
        temperature: Double = 0.0,
        maxTokens: Int = 128,
        warmupRuns: Int = 1,
        timedRuns: Int = 5
    ) -> BenchSpec {
        BenchSpec(
            modelFamily: modelFamily,
            protocolConfig: .init(
                prompt: prompt,
                temperature: temperature,
                maxTokens: maxTokens,
                warmupRuns: warmupRuns,
                timedRuns: timedRuns
            ),
            lanes: [
                .init(name: "ollama", transport: .httpOllama, endpoint: "http://localhost:11434", model: "llama3.1-8b", quant: "Q4_K_M"),
                .init(name: "omlx", transport: .httpOpenAI, endpoint: "http://127.0.0.1:8000", model: "Meta-Llama-3.1-8B-Instruct-4bit", quant: "4bit", apiKeyEnv: "OMLX_API_KEY"),
            ]
        )
    }

    func testDecodesFixtureSpec() throws {
        let data = try Data(contentsOf: fixture("perf-llama31-8b"))
        let spec = try JSONDecoder().decode(BenchSpec.self, from: data)
        XCTAssertEqual(spec.modelFamily, "llama-3.1-8b-instruct")
        XCTAssertEqual(spec.lanes.count, 2)
        XCTAssertEqual(spec.lanes.map(\.transport), [.httpOllama, .httpOpenAI])
    }

    func testSpecHashIsDeterministicForSameInput() {
        XCTAssertEqual(makeSpec().specHash, makeSpec().specHash)
    }

    func testSpecHashIgnoresLaneIdentity() {
        // Two specs differing ONLY in their lanes (same model_family + protocol)
        // must hash identically — spec_hash asserts "same model, same protocol",
        // not "same lane set". This is what lets two independently-launched
        // lane runs (different endpoints) still collate as comparable.
        let a = makeSpec()
        var differentLanesSpec = a
        differentLanesSpec = BenchSpec(
            modelFamily: a.modelFamily,
            protocolConfig: a.protocolConfig,
            lanes: [.init(name: "solo-lane", transport: .httpOllama, endpoint: "http://elsewhere:1234", model: "x", quant: "y")]
        )
        XCTAssertEqual(a.specHash, differentLanesSpec.specHash)
    }

    func testSpecHashChangesWithPrompt() {
        XCTAssertNotEqual(makeSpec(prompt: "2 + 2 =").specHash, makeSpec(prompt: "3 + 3 =").specHash)
    }

    func testSpecHashChangesWithModelFamily() {
        XCTAssertNotEqual(
            makeSpec(modelFamily: "llama-3.1-8b-instruct").specHash,
            makeSpec(modelFamily: "qwen2.5-7b-instruct").specHash
        )
    }

    func testSpecHashChangesWithProtocolKnobs() {
        let base = makeSpec()
        XCTAssertNotEqual(base.specHash, makeSpec(temperature: 0.8).specHash)
        XCTAssertNotEqual(base.specHash, makeSpec(maxTokens: 256).specHash)
        XCTAssertNotEqual(base.specHash, makeSpec(warmupRuns: 2).specHash)
        XCTAssertNotEqual(base.specHash, makeSpec(timedRuns: 10).specHash)
    }
}
