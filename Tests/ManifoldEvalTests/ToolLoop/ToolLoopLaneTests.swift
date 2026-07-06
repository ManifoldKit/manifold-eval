import XCTest
@testable import ManifoldEval
import ManifoldInference

/// Hermetic tests for the multi-turn tool-loop lane: scoring semantics
/// (including the after-first-result ordering rule that makes the chained
/// probe honest), argument canonicalization, corpus loading, wire-schema
/// round trips, and report determinism. No model, no network.
final class ToolLoopLaneTests: XCTestCase {

    private let lane = ToolLoopLane()

    // MARK: - Helpers

    /// A chained-probe case: lookup_account's scripted result carries the
    /// ACC-77120 sentinel; get_balance must be called with it afterwards.
    private var chainCase: ToolLoopCase {
        ToolLoopCorpus.builtin.first { $0.id == "chain_account_1" }!
    }

    private func entry(
        id: String = "chain_account_1",
        repeatIndex: Int = 0,
        events: [ToolLoopTranscriptEntry.Event],
        finalText: String
    ) -> ToolLoopTranscriptEntry {
        ToolLoopTranscriptEntry(
            id: id, repeatIndex: repeatIndex, events: events, finalText: finalText
        )
    }

    /// The canonical fully-correct episode for `chain_account_1`.
    private var passingEvents: [ToolLoopTranscriptEntry.Event] {
        [
            .call(name: "lookup_account", arguments: #"{"email":"sam@example.com"}"#),
            .result(content: #"{"account_id":"ACC-77120"}"#),
            .call(name: "get_balance", arguments: #"{"account_id":"ACC-77120"}"#),
            .result(content: #"{"account_id":"ACC-77120","balance":"482.15","currency":"AUD"}"#),
        ]
    }

    // MARK: - Scoring: all three axes

    func testFullyCorrectEpisodePassesAllAxes() {
        let result = lane.score(
            cases: [chainCase],
            transcripts: [entry(events: passingEvents, finalText: "The balance is 482.15 AUD.")]
        )
        let caseResult = result.caseResults[0]
        XCTAssertTrue(caseResult.passed)
        XCTAssertEqual(caseResult.repeats[0].firstCallOK, true)
        XCTAssertEqual(caseResult.repeats[0].chainedOK, true)
        XCTAssertEqual(caseResult.repeats[0].answerOK, true)
    }

    func testWrongFirstToolFailsFirstCallAxisOnly() {
        var events = passingEvents
        events[0] = .call(name: "get_balance", arguments: #"{"account_id":"ACC-77120"}"#)
        let result = lane.score(
            cases: [chainCase],
            transcripts: [entry(events: events, finalText: "The balance is 482.15 AUD.")]
        )
        XCTAssertEqual(result.caseResults[0].repeats[0].firstCallOK, false)
        XCTAssertFalse(result.caseResults[0].passed)
    }

    func testWrongFirstCallArgumentFails() {
        var events = passingEvents
        events[0] = .call(name: "lookup_account", arguments: #"{"email":"wrong@example.com"}"#)
        let result = lane.score(
            cases: [chainCase],
            transcripts: [entry(events: events, finalText: "The balance is 482.15 AUD.")]
        )
        XCTAssertEqual(result.caseResults[0].repeats[0].firstCallOK, false)
    }

    func testWrongChainedValueFailsChainedAxis() {
        var events = passingEvents
        events[2] = .call(name: "get_balance", arguments: #"{"account_id":"ACC-99999"}"#)
        let result = lane.score(
            cases: [chainCase],
            transcripts: [entry(events: events, finalText: "The balance is 482.15 AUD.")]
        )
        XCTAssertEqual(result.caseResults[0].repeats[0].chainedOK, false)
    }

    func testMissingSentinelInAnswerFailsAnswerAxis() {
        let result = lane.score(
            cases: [chainCase],
            transcripts: [entry(events: passingEvents, finalText: "I found the balance for you.")]
        )
        XCTAssertEqual(result.caseResults[0].repeats[0].answerOK, false)
        XCTAssertFalse(result.caseResults[0].passed)
    }

    // MARK: - The ordering rule

    /// A chained-looking call emitted BEFORE any tool result cannot have
    /// read the sentinel from the result — it must score as a miss even
    /// though name, key, and value all match.
    func testChainedCallBeforeAnyResultIsAMiss() {
        let events: [ToolLoopTranscriptEntry.Event] = [
            .call(name: "lookup_account", arguments: #"{"email":"sam@example.com"}"#),
            .call(name: "get_balance", arguments: #"{"account_id":"ACC-77120"}"#),
            .result(content: #"{"account_id":"ACC-77120"}"#),
        ]
        let result = lane.score(
            cases: [chainCase],
            transcripts: [entry(events: events, finalText: "The balance is 482.15 AUD.")]
        )
        XCTAssertEqual(
            result.caseResults[0].repeats[0].chainedOK, false,
            "a pre-result sentinel match is a lucky hallucination, not threading"
        )
    }

    func testEpisodeWithNoEventsFailsAllSpecifiedAxes() {
        let result = lane.score(
            cases: [chainCase],
            transcripts: [entry(events: [], finalText: "")]
        )
        let score = result.caseResults[0].repeats[0]
        XCTAssertEqual(score.firstCallOK, false)
        XCTAssertEqual(score.chainedOK, false)
        XCTAssertEqual(score.answerOK, false)
    }

    // MARK: - Axis absence ≠ failure

    func testUnspecifiedAxesScoreNilAndDoNotFailTheCase() {
        // multi_quote_1 has no chained expectation — its chained axis must
        // read "not probed", never pass or fail.
        let multiCase = ToolLoopCorpus.builtin.first { $0.id == "multi_quote_1" }!
        let events: [ToolLoopTranscriptEntry.Event] = [
            .call(name: "get_stock_quote", arguments: #"{"symbol":"NVAX"}"#),
            .result(content: #"{"symbol":"NVAX","price":"217.44"}"#),
            .call(name: "get_stock_quote", arguments: #"{"symbol":"BLZR"}"#),
            .result(content: #"{"symbol":"BLZR","price":"63.02"}"#),
        ]
        let result = lane.score(
            cases: [multiCase],
            transcripts: [
                entry(id: "multi_quote_1", events: events, finalText: "NVAX: 217.44, BLZR: 63.02")
            ]
        )
        let score = result.caseResults[0].repeats[0]
        XCTAssertNil(score.chainedOK)
        XCTAssertTrue(result.caseResults[0].passed)
    }

    // MARK: - Missing transcripts and strict repeat policy

    func testCaseWithNoTranscriptIsMissingNotFailed() {
        let result = lane.score(cases: [chainCase], transcripts: [])
        XCTAssertTrue(result.caseResults[0].missing)
        XCTAssertFalse(result.caseResults[0].passed)
        XCTAssertEqual(result.missing, 1)
    }

    func testOnePassingOneFailingRepeatFailsTheCase() {
        let good = entry(repeatIndex: 0, events: passingEvents, finalText: "Balance: 482.15 AUD")
        let bad = entry(repeatIndex: 1, events: passingEvents, finalText: "I could not find it.")
        let result = lane.score(cases: [chainCase], transcripts: [good, bad])
        let caseResult = result.caseResults[0]
        XCTAssertEqual(caseResult.passedRepeats, 1)
        XCTAssertFalse(caseResult.passed, "2-of-3 style partial passes must not read as a pass")
    }

    // MARK: - Determinism control

    func testIdenticalRepeatsAreDeterministic() {
        let a = entry(repeatIndex: 0, events: passingEvents, finalText: "Balance: 482.15 AUD")
        let b = entry(repeatIndex: 1, events: passingEvents, finalText: "Balance: 482.15 AUD")
        let result = lane.score(cases: [chainCase], transcripts: [a, b])
        XCTAssertTrue(result.caseResults[0].deterministic)
        XCTAssertEqual(result.variant, 0)
    }

    func testDivergentRepeatsAreVariantEvenWhenBothPass() {
        let a = entry(repeatIndex: 0, events: passingEvents, finalText: "Balance: 482.15 AUD")
        let b = entry(repeatIndex: 1, events: passingEvents, finalText: "The balance is 482.15.")
        let result = lane.score(cases: [chainCase], transcripts: [a, b])
        XCTAssertTrue(result.caseResults[0].passed, "both repeats individually pass")
        XCTAssertFalse(result.caseResults[0].deterministic)
        XCTAssertEqual(result.variant, 1, "temp=0 divergence is a finding even without a failure")
    }

    // MARK: - Argument canonicalization

    func testCanonicalizationNormalizesNumbersAndBools() {
        let canonical = ToolLoopArguments.canonicalized(
            #"{"order_id":884213,"flag":true,"ratio":2.5,"name":"x"}"#
        )
        XCTAssertEqual(canonical?["order_id"], "884213")
        XCTAssertEqual(canonical?["flag"], "true")
        XCTAssertEqual(canonical?["ratio"], "2.5")
        XCTAssertEqual(canonical?["name"], "x")
    }

    func testNumericArgumentMatchesStringExpectation() {
        // thread_carrier_1 expects order_id == "884213"; a backend emitting
        // the JSON number 884213 must still match.
        let carrierCase = ToolLoopCorpus.builtin.first { $0.id == "thread_carrier_1" }!
        let events: [ToolLoopTranscriptEntry.Event] = [
            .call(name: "get_order", arguments: #"{"order_id":884213}"#),
            .result(content: #"{"order_id":"884213","carrier":"Skyfreight","eta_days":"9"}"#),
        ]
        let result = lane.score(
            cases: [carrierCase],
            transcripts: [entry(id: "thread_carrier_1", events: events, finalText: "Carrier: Skyfreight")]
        )
        XCTAssertTrue(result.caseResults[0].passed)
    }

    func testMalformedArgumentJSONScoresAsMissNotCrash() {
        var events = passingEvents
        events[0] = .call(name: "lookup_account", arguments: "not json at all")
        let result = lane.score(
            cases: [chainCase],
            transcripts: [entry(events: events, finalText: "Balance: 482.15 AUD")]
        )
        XCTAssertEqual(result.caseResults[0].repeats[0].firstCallOK, false)
    }

    // MARK: - Corpus

    func testBuiltinCorpusHasUniqueIDsAndWellFormedExpectations() throws {
        let cases = try ToolLoopCorpus.load(path: nil)
        XCTAssertEqual(cases.count, 8)
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count, "case ids must be unique")
        for toolLoopCase in cases {
            XCTAssertFalse(toolLoopCase.tools.isEmpty, "\(toolLoopCase.id): no tools")
            // Every expectation must reference a tool the case actually ships.
            let toolNames = Set(toolLoopCase.tools.map(\.name))
            if let first = toolLoopCase.expect.firstCall {
                XCTAssertTrue(toolNames.contains(first.toolName), "\(toolLoopCase.id): firstCall references unknown tool")
            }
            if let chained = toolLoopCase.expect.chainedCall {
                XCTAssertTrue(toolNames.contains(chained.toolName), "\(toolLoopCase.id): chainedCall references unknown tool")
                // The chained sentinel must exist in SOME scripted payload —
                // otherwise the probe is unsatisfiable by construction.
                let allPayloads = toolLoopCase.tools.flatMap {
                    [$0.script.result] + Array(($0.script.resultsByArgument ?? [:]).values)
                }
                XCTAssertTrue(
                    allPayloads.contains { $0.contains(chained.expectedValue) },
                    "\(toolLoopCase.id): chained sentinel '\(chained.expectedValue)' not in any scripted result"
                )
            }
        }
    }

    /// The chained probe is only sound if the sentinel CANNOT leak from the
    /// target tool itself: the target's fallback payload must not contain
    /// the sentinel, and any argument-keyed payload that does contain it
    /// must be reachable only BY the sentinel. Otherwise an episode that
    /// never called the source tool can obtain — and "thread" — the sentinel
    /// from the target's own response (the review's false-pass scenario).
    /// Same closure for the answer axis: on chained cases the required
    /// answer values must not be reachable without the sentinel argument,
    /// or a broken chain still produces a correct-looking answer.
    func testChainedCaseTargetToolsCannotLeakSentinelsOrAnswers() {
        for toolLoopCase in ToolLoopCorpus.builtin {
            guard let chained = toolLoopCase.expect.chainedCall else { continue }
            let target = toolLoopCase.tools.first { $0.name == chained.toolName }!
            let sentinel = chained.expectedValue

            XCTAssertFalse(
                target.script.result.contains(sentinel),
                "\(toolLoopCase.id): target fallback payload leaks the sentinel"
            )
            for answer in toolLoopCase.expect.finalAnswerMustContain {
                XCTAssertFalse(
                    target.script.result.contains(answer),
                    "\(toolLoopCase.id): target fallback payload leaks required answer '\(answer)'"
                )
            }
            for (key, payload) in target.script.resultsByArgument ?? [:] where key != sentinel {
                XCTAssertFalse(
                    payload.contains(sentinel),
                    "\(toolLoopCase.id): payload for '\(key)' leaks the sentinel"
                )
                for answer in toolLoopCase.expect.finalAnswerMustContain {
                    XCTAssertFalse(
                        payload.contains(answer),
                        "\(toolLoopCase.id): payload for '\(key)' leaks required answer '\(answer)'"
                    )
                }
            }
        }
    }

    func testEveryBuiltinCaseSpecifiesAtLeastOneAxis() {
        for toolLoopCase in ToolLoopCorpus.builtin {
            XCTAssertTrue(
                toolLoopCase.expect.firstCall != nil
                    || toolLoopCase.expect.chainedCall != nil
                    || !toolLoopCase.expect.finalAnswerMustContain.isEmpty,
                "\(toolLoopCase.id): no expectation axis — would pass vacuously"
            )
        }
    }

    func testExpectationLessFileCaseIsRejectedAtLoad() throws {
        let json = #"{"id":"vacuous","userPrompt":"p","tools":[{"name":"t","description":"d","parameters":{"type":"object"},"script":{"result":"{}"}}],"expect":{"finalAnswerMustContain":[]}}"#
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toolloop-vacuous-\(UUID().uuidString).jsonl")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ToolLoopCorpus.load(path: url.path)) { error in
            guard case ToolLoopError.invalidCase = error else {
                return XCTFail("expected invalidCase, got \(error)")
            }
        }
    }

    func testCorpusFileOverrideRoundTripsThroughJSONL() throws {
        // Encode the builtin corpus to JSONL, load it back through the file
        // path, and require equality — proves the documented file format is
        // exactly the builtin schema (no drift between the two sources).
        let encoder = JSONEncoder()
        let jsonl = try ToolLoopCorpus.builtin
            .map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toolloop-corpus-\(UUID().uuidString).jsonl")
        try jsonl.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try ToolLoopCorpus.load(path: url.path)
        XCTAssertEqual(loaded, ToolLoopCorpus.builtin)
    }

    func testUnreadableCorpusFileThrowsCorpusUnreadable() {
        XCTAssertThrowsError(
            try ToolLoopCorpus.load(path: "/nonexistent/toolloop-cases.jsonl")
        ) { error in
            guard case ToolLoopError.corpusUnreadable = error else {
                return XCTFail("expected corpusUnreadable, got \(error)")
            }
        }
    }

    // MARK: - Transcript wire schema

    func testTranscriptEntryJSONLRoundTrip() throws {
        let original = entry(events: passingEvents, finalText: "Balance: 482.15 AUD")
        let encoder = JSONEncoder()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toolloop-transcript-\(UUID().uuidString).jsonl")
        let line = String(decoding: try encoder.encode(original), as: UTF8.self)
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try ToolLoopTranscriptEntry.loadJSONL(from: url)
        XCTAssertEqual(loaded, [original])
    }

    func testUnknownEventKindFailsDecodeLoudly() {
        let json = #"{"id":"x","repeatIndex":0,"events":[{"kind":"mystery"}],"finalText":""}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ToolLoopTranscriptEntry.self, from: Data(json.utf8))
        )
    }

    // MARK: - Report

    func testReportIsDeterministicAndSurfacesHolesAndVariance() {
        let good = entry(repeatIndex: 0, events: passingEvents, finalText: "Balance: 482.15 AUD")
        let variant = entry(repeatIndex: 1, events: passingEvents, finalText: "It is 482.15 AUD.")
        // Score two cases: one measured-with-variance, one missing entirely.
        let carrierCase = ToolLoopCorpus.builtin.first { $0.id == "thread_carrier_1" }!
        let result = lane.score(cases: [chainCase, carrierCase], transcripts: [good, variant])

        let render = { ToolLoopReport.render(result: result, title: "t", corpusLabel: "c") }
        XCTAssertEqual(render(), render(), "identical input must render identical bytes")
        XCTAssertTrue(render().contains("**VARIANT**"))
        XCTAssertTrue(render().contains("not measured"))
        XCTAssertTrue(render().contains("`chain_account_1`"))
    }
}
