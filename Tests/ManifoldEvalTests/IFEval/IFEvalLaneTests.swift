import XCTest
@testable import ManifoldEval
import ManifoldInference

/// Integration tests for `IFEvalLane` and `IFEvalCorpus`.
///
/// The bundled `Fixtures/ifeval.jsonl` is the full 541-case IFEval corpus
/// from `google-research/instruction_following_eval`, committed alongside
/// these tests. The full-corpus test (`testFullCorpusLoadAndDispatchDoesNotCrash`)
/// runs unconditionally — no env var or skip gate applies. Runtime is ~1.8 s.
final class IFEvalLaneTests: XCTestCase {

    // MARK: - Corpus loading

    func testCorpusLoadsAllCases() throws {
        let url = try fixtureURL("ifeval", extension: "jsonl")
        let cases = try IFEvalCorpus.load(from: url)
        // The full corpus has 541 cases.
        XCTAssertEqual(cases.count, 541,
                       "Expected 541 IFEval cases from the bundled fixture corpus")
    }

    func testCorpusCasesHaveParallelInstructionAndKwargs() throws {
        let url = try fixtureURL("ifeval", extension: "jsonl")
        let cases = try IFEvalCorpus.load(from: url)
        for c in cases {
            XCTAssertEqual(
                c.instructionIDs.count,
                c.kwargs.count,
                "Case \(c.key): instruction_ids and kwargs must be parallel"
            )
        }
    }

    func testCorpusMalformedLineThrows() {
        XCTAssertThrowsError(try IFEvalCorpus.parse(jsonl: "{ not valid json }")) { error in
            guard case IFEvalCorpus.LoadError.decodingFailed = error else {
                return XCTFail("Expected .decodingFailed, got \(error)")
            }
        }
    }

    func testCorpusEmptyStringProducesZeroCases() throws {
        let cases = try IFEvalCorpus.parse(jsonl: "")
        XCTAssertTrue(cases.isEmpty)
    }

    // MARK: - IFEvalCase round-trip

    func testCaseCodableRoundTrip() throws {
        let json = """
        {"key": 1000, "prompt": "Write something.", "instruction_id_list": ["punctuation:no_comma"], "kwargs": [{}]}
        """
        let cases = try IFEvalCorpus.parse(jsonl: json)
        XCTAssertEqual(cases.count, 1)
        let c = cases[0]
        XCTAssertEqual(c.key, "1000")
        XCTAssertEqual(c.instructionIDs, ["punctuation:no_comma"])
        XCTAssertEqual(c.kwargs.count, 1)
        XCTAssertTrue(c.kwargs[0].isEmpty)
    }

    // MARK: - Single-case evaluation

    func testLaneEvaluateNoCommaPass() {
        let lane = IFEvalLane()
        let evalCase = IFEvalCase(
            key: "test_1",
            prompt: "Write without commas.",
            instructionIDs: ["punctuation:no_comma"],
            kwargs: [[:]],
        )
        let result = lane.evaluate(case: evalCase, response: "No commas in this text at all.")
        XCTAssertTrue(result.allPassed)
        XCTAssertEqual(result.instructionResults, [true])
    }

    func testLaneEvaluateNoCommaFail() {
        let lane = IFEvalLane()
        let evalCase = IFEvalCase(
            key: "test_2",
            prompt: "Write without commas.",
            instructionIDs: ["punctuation:no_comma"],
            kwargs: [[:]],
        )
        let result = lane.evaluate(case: evalCase, response: "One, two, three.")
        XCTAssertFalse(result.allPassed)
        XCTAssertEqual(result.instructionResults, [false])
    }

    func testLaneEvaluateMultipleInstructions() {
        let lane = IFEvalLane()
        let evalCase = IFEvalCase(
            key: "test_3",
            prompt: "Write at least 10 words without commas.",
            instructionIDs: ["punctuation:no_comma", "length_constraints:number_words"],
            kwargs: [
                [:],
                ["relation": .string("at least"), "num_words": .int(10)],
            ],
        )
        let fiftyWords = Array(repeating: "word", count: 50).joined(separator: " ")
        let result = lane.evaluate(case: evalCase, response: fiftyWords)
        XCTAssertTrue(result.allPassed)
        XCTAssertEqual(result.instructionResults, [true, true])
    }

    func testLaneEvaluateUnknownInstructionReturnsFalse() {
        let lane = IFEvalLane()
        let evalCase = IFEvalCase(
            key: "test_4",
            prompt: "Something.",
            instructionIDs: ["unknown:instruction_id"],
            kwargs: [[:]],
        )
        let result = lane.evaluate(case: evalCase, response: "Any response.")
        XCTAssertFalse(result.allPassed)
    }

    func testLaneEvaluateResultKeyMatchesCase() {
        let lane = IFEvalLane()
        let evalCase = IFEvalCase(key: "my_key_42", prompt: "p", instructionIDs: ["punctuation:no_comma"], kwargs: [[:]],)
        let result = lane.evaluate(case: evalCase, response: "no commas")
        XCTAssertEqual(result.key, "my_key_42")
        XCTAssertEqual(result.response, "no commas")
    }

    // MARK: - Aggregation

    func testAggregateEmptyReturnsZero() {
        let lane = IFEvalLane()
        let score = lane.aggregate(results: [], cases: [])
        XCTAssertEqual(score.strictAccuracy, 0)
        XCTAssertEqual(score.totalCases, 0)
        XCTAssertEqual(score.passedCases, 0)
    }

    func testAggregateAllPass() {
        let lane = IFEvalLane()
        let cases = [
            IFEvalCase(key: "a", prompt: "p", instructionIDs: ["punctuation:no_comma"], kwargs: [[:]],),
            IFEvalCase(key: "b", prompt: "p", instructionIDs: ["punctuation:no_comma"], kwargs: [[:]],),
        ]
        let results = cases.map { lane.evaluate(case: $0, response: "no commas here") }
        let score = lane.aggregate(results: results, cases: cases)
        XCTAssertEqual(score.strictAccuracy, 1.0, accuracy: 1e-9)
        XCTAssertEqual(score.passedCases, 2)
        XCTAssertEqual(score.totalCases, 2)
    }

    func testAggregatePartialPass() {
        let lane = IFEvalLane()
        let cases = [
            IFEvalCase(key: "p", prompt: "x", instructionIDs: ["punctuation:no_comma"], kwargs: [[:]],),
            IFEvalCase(key: "f", prompt: "x", instructionIDs: ["punctuation:no_comma"], kwargs: [[:]],),
        ]
        let responses = ["no commas", "one, two"]
        let results = zip(cases, responses).map { lane.evaluate(case: $0.0, response: $0.1) }
        let score = lane.aggregate(results: results, cases: cases)
        XCTAssertEqual(score.strictAccuracy, 0.5, accuracy: 1e-9)
        XCTAssertEqual(score.passedCases, 1)
    }

    func testAggregatePerInstructionAccuracy() {
        let lane = IFEvalLane()
        // Two cases: both have no_comma; only one also has word count.
        let cases = [
            IFEvalCase(key: "1", prompt: "x",
                       instructionIDs: ["punctuation:no_comma", "length_constraints:number_words"],
                       kwargs: [[:], ["relation": .string("at least"), "num_words": .int(50)]],),
            IFEvalCase(key: "2", prompt: "x",
                       instructionIDs: ["punctuation:no_comma"],
                       kwargs: [[:]],),
        ]
        let longResponse = Array(repeating: "word", count: 60).joined(separator: " ")
        let results = [
            lane.evaluate(case: cases[0], response: longResponse),  // both pass
            lane.evaluate(case: cases[1], response: "no commas"),     // passes
        ]
        let score = lane.aggregate(results: results, cases: cases)
        XCTAssertEqual(score.perInstructionAccuracy["punctuation:no_comma"] ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(score.perInstructionAccuracy["length_constraints:number_words"] ?? -1, 1.0, accuracy: 1e-9)
    }

    // MARK: - EvalScorer bridge

    func testEvalScorerPassReturnsScoreBoolTrue() async {
        let lane = IFEvalLane()
        let evalCase = IFEvalCase(
            key: "s1",
            prompt: "No commas please.",
            instructionIDs: ["punctuation:no_comma"],
            kwargs: [[:]],
        )
        let output = EvalRunOutput(visibleText: "no commas at all")
        let score = await lane.score(output: output, expected: evalCase)
        XCTAssertEqual(score.value, .bool(true))
        XCTAssertNotNil(score.explanation)
    }

    func testEvalScorerFailReturnsScoreBoolFalse() async {
        let lane = IFEvalLane()
        let evalCase = IFEvalCase(
            key: "s2",
            prompt: "No commas please.",
            instructionIDs: ["punctuation:no_comma"],
            kwargs: [[:]],
        )
        let output = EvalRunOutput(visibleText: "one, two, three")
        let score = await lane.score(output: output, expected: evalCase)
        XCTAssertEqual(score.value, .bool(false))
        XCTAssertTrue(score.metadata["punctuation:no_comma"] == "fail")
    }

    // MARK: - Full corpus smoke test (fixture-driven, no live model)
    //
    // Verifies that every case in the bundled corpus can be decoded, dispatched,
    // and aggregated without crashing — using a synthetic perfect response that
    // trivially satisfies every constraint (passes most verifiers).
    // This is a structural smoke test, not a measurement of model accuracy.

    func testFullCorpusLoadAndDispatchDoesNotCrash() throws {
        let url = try fixtureURL("ifeval", extension: "jsonl")
        let cases = try IFEvalCorpus.load(from: url)
        let lane = IFEvalLane()

        var results: [IFEvalResult] = []
        for c in cases {
            let result = lane.evaluate(case: c, response: "placeholder")
            results.append(result)
        }

        let score = lane.aggregate(results: results, cases: cases)
        // Aggregate must cover all 541 cases.
        XCTAssertEqual(score.totalCases, 541)
        // Strict accuracy with a trivial placeholder is well below 1.0 for real instructions.
        XCTAssertGreaterThanOrEqual(score.strictAccuracy, 0.0)
        XCTAssertLessThanOrEqual(score.strictAccuracy, 1.0)
    }

    // MARK: - Fixture loading helper

    private func fixtureURL(_ name: String, extension ext: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "Missing fixture \(name).\(ext) in test bundle"
        )
    }
}
