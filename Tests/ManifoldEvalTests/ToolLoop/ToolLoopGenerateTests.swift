import XCTest
@testable import ManifoldEval
import ManifoldInference

/// Hermetic tests for the generation half of the tool-loop lane: the
/// generate loop's ordering/error policy, the `ScriptedTool` executor, and
/// the full generate → JSONL → score round trip with a synthetic emitter.
final class ToolLoopGenerateTests: XCTestCase {

    // MARK: - ScriptedTool

    func testScriptedToolReturnsFixedResult() async throws {
        let spec = ToolLoopCorpus.builtin
            .first { $0.id == "thread_gate_1" }!.tools[0]
        let tool = ScriptedTool(spec: spec)
        let result = try await tool.execute(arguments: .object(["flight": .string("QF123")]))
        XCTAssertEqual(result.content, #"{"flight":"QF123","status":"delayed","gate":"K97"}"#)
        XCTAssertNil(result.errorKind)
    }

    func testScriptedToolSelectsArgumentKeyedResult() async throws {
        let spec = ToolLoopCorpus.builtin
            .first { $0.id == "multi_quote_1" }!.tools[0]
        let tool = ScriptedTool(spec: spec)

        let nvax = try await tool.execute(arguments: .object(["symbol": .string("NVAX")]))
        XCTAssertTrue(nvax.content.contains("217.44"))

        let blzr = try await tool.execute(arguments: .object(["symbol": .string("BLZR")]))
        XCTAssertTrue(blzr.content.contains("63.02"))

        // Unmatched key value falls back to the fixed result.
        let unknown = try await tool.execute(arguments: .object(["symbol": .string("ZZZZ")]))
        XCTAssertTrue(unknown.content.contains("unknown symbol"))
    }

    func testScriptedToolIsReadOnlyByConstruction() {
        let spec = ToolLoopCorpus.builtin.first!.tools[0]
        let tool = ScriptedTool(spec: spec)
        XCTAssertFalse(tool.requiresApproval)
        XCTAssertTrue(tool.supportsConcurrentDispatch)
    }

    // MARK: - Generate loop

    @MainActor
    func testGenerateProducesCasesTimesRepeatsInOrder() async {
        let cases = Array(ToolLoopCorpus.builtin.prefix(2))
        var streamed: [String] = []
        let result = await ToolLoopLane().generateTranscripts(
            cases: cases,
            repeats: 3,
            onEntry: { streamed.append("\($0.id)#\($0.repeatIndex)") },
            emit: { toolLoopCase, repeatIndex in
                ToolLoopTranscriptEntry(
                    id: toolLoopCase.id, repeatIndex: repeatIndex, events: [], finalText: "x"
                )
            }
        )
        XCTAssertEqual(result.entries.count, 6)
        XCTAssertEqual(result.errored, 0)
        XCTAssertEqual(
            streamed,
            [
                "\(cases[0].id)#0", "\(cases[0].id)#1", "\(cases[0].id)#2",
                "\(cases[1].id)#0", "\(cases[1].id)#1", "\(cases[1].id)#2",
            ],
            "entries must stream in corpus order then repeat order"
        )
    }

    @MainActor
    func testThrowingEmitRecordsErrorMarkedEntryAndContinues() async {
        struct Boom: Error {}
        let cases = Array(ToolLoopCorpus.builtin.prefix(2))
        let result = await ToolLoopLane().generateTranscripts(
            cases: cases,
            repeats: 1,
            emit: { toolLoopCase, repeatIndex in
                if toolLoopCase.id == cases[0].id { throw Boom() }
                return ToolLoopTranscriptEntry(
                    id: toolLoopCase.id, repeatIndex: repeatIndex, events: [], finalText: "ok"
                )
            }
        )
        XCTAssertEqual(result.entries.count, 2, "an errored episode must not abort the run")
        XCTAssertEqual(result.errored, 1)
        XCTAssertNotNil(
            result.entries[0].error,
            "the failure must be recorded ON THE WIRE so the scorer sees a hole, not a miss"
        )
        XCTAssertNil(result.entries[1].error)
        XCTAssertEqual(result.entries[1].finalText, "ok")
    }

    /// The scorer must exclude error-marked entries from measurement: an
    /// infrastructure failure is a hole, never a capability zero.
    func testErroredEntriesAreHolesNotMeasuredMisses() {
        let lane = ToolLoopLane()
        let chainCase = ToolLoopCorpus.builtin.first { $0.id == "chain_account_1" }!
        let clean = ToolLoopTranscriptEntry(
            id: chainCase.id, repeatIndex: 0,
            events: [
                .call(name: "lookup_account", arguments: #"{"email":"sam@example.com"}"#),
                .result(content: #"{"account_id":"ACC-77120"}"#),
                .call(name: "get_balance", arguments: #"{"account_id":"ACC-77120"}"#),
                .result(content: #"{"account_id":"ACC-77120","balance":"482.15","currency":"AUD"}"#),
            ],
            finalText: "Balance: 482.15 AUD"
        )
        let errored = ToolLoopTranscriptEntry(
            id: chainCase.id, repeatIndex: 1, events: [], finalText: "",
            error: "episode timed out after 180s"
        )

        // Clean + errored: the errored repeat neither fails the case nor
        // breaks the determinism comparison.
        let mixed = lane.score(cases: [chainCase], transcripts: [clean, errored])
        XCTAssertTrue(mixed.caseResults[0].passed)
        XCTAssertEqual(mixed.caseResults[0].repeats.count, 1)
        XCTAssertEqual(mixed.caseResults[0].erroredRepeats, 1)

        // Errored only: not measured — a hole, not a fail.
        let holeOnly = lane.score(cases: [chainCase], transcripts: [errored])
        XCTAssertTrue(holeOnly.caseResults[0].missing)
        XCTAssertFalse(holeOnly.caseResults[0].passed)
        XCTAssertEqual(holeOnly.measured, 0)
    }

    // MARK: - Generate → score round trip (synthetic)

    /// The full pipeline with a perfect synthetic model: generate transcripts,
    /// write the JSONL the CLI writes, load it back, score it — every case
    /// passes and repeats are deterministic. Proves writer and reader share
    /// one schema with no adapter.
    @MainActor
    func testGenerateScoreRoundTripWithPerfectSyntheticModel() async throws {
        let cases = ToolLoopCorpus.builtin

        let result = await ToolLoopLane().generateTranscripts(
            cases: cases,
            repeats: 2,
            emit: { toolLoopCase, repeatIndex in
                Self.perfectEpisode(for: toolLoopCase, repeatIndex: repeatIndex)
            }
        )
        XCTAssertEqual(result.entries.count, cases.count * 2)

        let encoder = JSONEncoder()
        let jsonl = try result.entries
            .map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toolloop-roundtrip-\(UUID().uuidString).jsonl")
        try jsonl.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try ToolLoopTranscriptEntry.loadJSONL(from: url)
        let score = ToolLoopLane().score(cases: cases, transcripts: loaded)
        XCTAssertTrue(score.allPassed, "perfect episodes must pass every case")
        XCTAssertEqual(score.variant, 0)
        XCTAssertEqual(score.missing, 0)
    }

    /// Synthesizes the ideal episode for a case: expected first call, scripted
    /// result, expected chained call (when probed), and a final answer
    /// containing every required sentinel — all derived from the case itself.
    private static func perfectEpisode(
        for toolLoopCase: ToolLoopCase,
        repeatIndex: Int
    ) -> ToolLoopTranscriptEntry {
        var events: [ToolLoopTranscriptEntry.Event] = []

        let firstTool = toolLoopCase.expect.firstCall?.toolName ?? toolLoopCase.tools[0].name
        let firstArguments = toolLoopCase.expect.firstCall?.arguments ?? [:]
        let argJSON = "{"
            + firstArguments.map { "\"\($0.key)\":\"\($0.value)\"" }.sorted().joined(separator: ",")
            + "}"
        events.append(.call(name: firstTool, arguments: argJSON))
        events.append(.result(content: scriptedResult(toolLoopCase, tool: firstTool, arguments: firstArguments)))

        if let chained = toolLoopCase.expect.chainedCall {
            let chainedArgs = "{\"\(chained.argumentKey)\":\"\(chained.expectedValue)\"}"
            events.append(.call(name: chained.toolName, arguments: [chained.argumentKey: chained.expectedValue].isEmpty ? "{}" : chainedArgs))
            events.append(.result(content: scriptedResult(
                toolLoopCase, tool: chained.toolName,
                arguments: [chained.argumentKey: chained.expectedValue]
            )))
        }

        // multi_quote_1 needs the second keyed call to surface both sentinels.
        if toolLoopCase.id == "multi_quote_1" {
            events.append(.call(name: "get_stock_quote", arguments: #"{"symbol":"BLZR"}"#))
            events.append(.result(content: scriptedResult(
                toolLoopCase, tool: "get_stock_quote", arguments: ["symbol": "BLZR"]
            )))
        }

        return ToolLoopTranscriptEntry(
            id: toolLoopCase.id,
            repeatIndex: repeatIndex,
            events: events,
            finalText: "Answer: " + toolLoopCase.expect.finalAnswerMustContain.joined(separator: ", ")
        )
    }

    /// Resolves the scripted payload the registry would return for this
    /// invocation — same selection rule as `ScriptedTool`.
    private static func scriptedResult(
        _ toolLoopCase: ToolLoopCase,
        tool: String,
        arguments: [String: String]
    ) -> String {
        guard let spec = toolLoopCase.tools.first(where: { $0.name == tool }) else { return "{}" }
        if let key = spec.script.argumentKey,
           let table = spec.script.resultsByArgument,
           let value = arguments[key],
           let keyed = table[value] {
            return keyed
        }
        return spec.script.result
    }
}
