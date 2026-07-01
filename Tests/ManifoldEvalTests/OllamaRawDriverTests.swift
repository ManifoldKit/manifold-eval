import XCTest
@testable import ManifoldEval

/// Unit tests for the Ollama wire-encoding built by
/// ``OllamaRawDriver/makeOptions(from:)`` — the pure builder extracted from
/// `run(model:prompt:sampler:repeatIndex:)` so the always-explicit encoding is
/// testable without a live Ollama or a mocked `URLSession`.
///
/// These pin down two honesty bugs fixed alongside the `diff` triage fix:
///   1. `top_k` must never be omitted from the request body — omitting it is
///      NOT equivalent to sending `0` (verified live against Ollama 0.30.11:
///      omitted falls back to Ollama's own undocumented default, ~40; explicit
///      `0` genuinely disables top-k).
///   2. `stop` must always be sent as an explicit empty array — `raw: true`
///      does not bypass a model-baked `PARAMETER stop` (verified live: a model
///      with `PARAMETER stop "France"` truncated a raw generation to a single
///      token; `stop: []` neutralises it).
final class OllamaRawDriverTests: XCTestCase {

    private func encodedJSON(_ options: OllamaRawDriver.GenerateRequest.Options) throws -> [String: Any] {
        let data = try JSONEncoder().encode(options)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object
    }

    // MARK: - topK: always explicit, never omitted

    func testTopKIsPresentInWireJSONWhenZero() throws {
        // The concrete bug: SamplerConfig's default is topK == 0. The old code
        // (`sampler.topK > 0 ? sampler.topK : nil`) omitted the key here.
        let options = OllamaRawDriver.makeOptions(from: SamplerConfig(topK: 0))
        let json = try encodedJSON(options)
        XCTAssertNotNil(json["top_k"], "top_k must never be omitted from the wire request, even at 0")
        XCTAssertEqual(json["top_k"] as? Int, 0)
    }

    func testTopKIsPresentInWireJSONWhenPositive() throws {
        let options = OllamaRawDriver.makeOptions(from: SamplerConfig(topK: 40))
        let json = try encodedJSON(options)
        XCTAssertEqual(json["top_k"] as? Int, 40)
    }

    func testMakeOptionsNeverOptionalizesTopK() {
        // Type-level guard: Options.topK is a plain Int (not Int?) so the
        // "omit when <= 0" ternary can never be reintroduced without a
        // compile error at the call site.
        let options = OllamaRawDriver.makeOptions(from: .greedy)
        let topK: Int = options.topK
        XCTAssertEqual(topK, 0)
    }

    // MARK: - stop: always explicit empty

    func testStopIsAlwaysSentAsExplicitEmptyArray() throws {
        let options = OllamaRawDriver.makeOptions(from: .greedy)
        let json = try encodedJSON(options)
        let stop = try XCTUnwrap(json["stop"] as? [String], "stop must be present in the wire request")
        XCTAssertTrue(stop.isEmpty, "stop must be explicitly empty so no model-baked PARAMETER stop applies")
    }

    func testStopIsEmptyRegardlessOfSamplerConfig() throws {
        // SamplerConfig has no stop-sequence field — stop:[] is a driver-level
        // decision independent of the sampler the caller requested.
        let options = OllamaRawDriver.makeOptions(
            from: SamplerConfig(temperature: 0.7, seed: 3, topK: 20, repeatPenalty: 1.3, maxTokens: 256)
        )
        XCTAssertEqual(options.stop, [])
    }

    // MARK: - Every other field passes through the sampler untouched

    func testOtherOptionsFieldsPassThroughFromSampler() {
        let sampler = SamplerConfig(temperature: 0.5, seed: 7, topK: 12, repeatPenalty: 1.2, maxTokens: 99)
        let options = OllamaRawDriver.makeOptions(from: sampler)
        XCTAssertEqual(options.temperature, 0.5)
        XCTAssertEqual(options.seed, 7)
        XCTAssertEqual(options.topK, 12)
        XCTAssertEqual(options.repeatPenalty, 1.2)
        XCTAssertEqual(options.numPredict, 99)
    }
}
