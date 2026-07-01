import XCTest
@testable import ManifoldEval
import ManifoldInference
import ManifoldTools

/// Tests for `manifold-eval bfcl-generate`'s testable core: category-list
/// parsing and the per-case generation loop (``BFCLLane/generateResponses``).
///
/// All tests use synthetic `emit` closures — no live model or Ollama server is
/// required (mirrors ``BFCLLaneTests``'s convention). A live-gated smoke test
/// against a real Ollama server lives in ``BFCLGenerateLiveTests``.
final class BFCLGenerateTests: XCTestCase {

    // MARK: - Fixture helpers

    private func bfclFixtureDir() throws -> URL {
        guard let resourceURL = Bundle.module.resourceURL else {
            throw XCTSkip("Bundle.module.resourceURL unavailable — skipping fixture-based tests")
        }
        return resourceURL.appendingPathComponent("Fixtures").appendingPathComponent("BFCL")
    }

    private func writeTempJSONL(_ content: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bfcl-generate-test-\(UUID().uuidString).jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - BFCLCategory.parseList

    func testParseList_singleCategory() throws {
        XCTAssertEqual(try BFCLCategory.parseList("multiple"), [.multiple])
    }

    func testParseList_commaSeparatedList_preservesOrder() throws {
        XCTAssertEqual(
            try BFCLCategory.parseList("simple, multiple,irrelevance"),
            [.simple, .multiple, .irrelevance]
        )
    }

    func testParseList_all_expandsToAllCases() throws {
        XCTAssertEqual(try BFCLCategory.parseList("all"), BFCLCategory.allCases)
        // Case-insensitive.
        XCTAssertEqual(try BFCLCategory.parseList("ALL"), BFCLCategory.allCases)
    }

    func testParseList_unknownCategory_throws() {
        XCTAssertThrowsError(try BFCLCategory.parseList("bogus")) { error in
            guard let parseError = error as? BFCLCategory.ParseError else {
                return XCTFail("expected BFCLCategory.ParseError, got \(error)")
            }
            XCTAssertEqual(parseError, .unknownCategory("bogus"))
        }
    }

    func testParseList_unknownCategoryAmongValid_throwsOnTheBadOne() {
        // A typo anywhere in the list must fail loudly, not silently drop the
        // bad token and proceed with the rest.
        XCTAssertThrowsError(try BFCLCategory.parseList("simple,bogus,multiple")) { error in
            guard let parseError = error as? BFCLCategory.ParseError else {
                return XCTFail("expected BFCLCategory.ParseError, got \(error)")
            }
            XCTAssertEqual(parseError, .unknownCategory("bogus"))
        }
    }

    // MARK: - generateResponses: happy path

    func testGenerateResponses_producesOneEntryPerCase() async throws {
        let dir = try bfclFixtureDir()
        let lane = BFCLLane()

        let result = await lane.generateResponses(
            categories: [.simple],
            corpusSource: .localDirectory(dir),
            emit: { testCase in
                [ToolCall(id: "1", toolName: "whatever-\(testCase.id)", arguments: "{}")]
            }
        )

        XCTAssertEqual(result.attempted, 3, "simple fixture has 3 cases")
        XCTAssertEqual(result.errored, 0)
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertEqual(Set(result.entries.map(\.id)), ["simple_0", "simple_1", "simple_2"])
        // Each entry's call reflects the per-case emit — not a shared/stale value.
        for entry in result.entries {
            XCTAssertEqual(entry.calls.first?.toolName, "whatever-\(entry.id)")
        }
    }

    func testGenerateResponses_multipleCategories_coversAll() async throws {
        let dir = try bfclFixtureDir()
        let lane = BFCLLane()

        let result = await lane.generateResponses(
            categories: [.simple, .multiple, .irrelevance],
            corpusSource: .localDirectory(dir),
            emit: { _ in [] }
        )

        // 3 simple + 3 multiple + 3 irrelevance = 9.
        XCTAssertEqual(result.attempted, 9)
        XCTAssertEqual(result.entries.count, 9)
        XCTAssertEqual(result.errored, 0)
    }

    // MARK: - generateResponses: error handling (must not abort the batch)

    func testGenerateResponses_erroredCase_recordsEmptyCallsAndContinues() async throws {
        let dir = try bfclFixtureDir()
        let lane = BFCLLane()

        struct FakeTimeout: Error {}

        let result = await lane.generateResponses(
            categories: [.simple],
            corpusSource: .localDirectory(dir),
            emit: { testCase in
                if testCase.id == "simple_1" {
                    throw FakeTimeout()
                }
                return [ToolCall(id: "1", toolName: "ok", arguments: "{}")]
            }
        )

        // All 3 cases still get an entry — one case erroring must not abort the run.
        XCTAssertEqual(result.attempted, 3)
        XCTAssertEqual(result.entries.count, 3, "an errored case still produces an entry (with empty calls)")
        XCTAssertEqual(result.errored, 1)

        let erroredEntry = try XCTUnwrap(result.entries.first { $0.id == "simple_1" })
        XCTAssertTrue(erroredEntry.calls.isEmpty, "an errored case must record an EMPTY call list, not crash")

        let okEntries = result.entries.filter { $0.id != "simple_1" }
        XCTAssertTrue(okEntries.allSatisfy { $0.calls.first?.toolName == "ok" })
    }

    func testGenerateResponses_categoryLoadFailure_skipsCategoryButContinues() async throws {
        // Point at a directory with no BFCL fixture files at all — every
        // category's loadCases(...) will throw. The run must not crash; it
        // should report zero attempted/entries and surface progress about the
        // skip via onProgress.
        let emptyDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bfcl-generate-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let lane = BFCLLane()
        var progressLines: [String] = []

        let result = await lane.generateResponses(
            categories: [.simple, .multiple],
            corpusSource: .localDirectory(emptyDir),
            onProgress: { progressLines.append($0) },
            emit: { _ in [] }
        )

        XCTAssertEqual(result.attempted, 0)
        XCTAssertEqual(result.entries.count, 0)
        XCTAssertEqual(result.errored, 0, "a category load failure is not a per-case error")
        XCTAssertTrue(
            progressLines.contains { $0.contains("simple") && $0.contains("failed to load") },
            "missing-corpus category should be reported via onProgress, got: \(progressLines)"
        )
    }

    // MARK: - generateResponses: callback ordering

    func testGenerateResponses_onEntryFiresOncePerCaseInOrder() async throws {
        let dir = try bfclFixtureDir()
        let lane = BFCLLane()

        var seenIDs: [String] = []
        let result = await lane.generateResponses(
            categories: [.simple],
            corpusSource: .localDirectory(dir),
            onEntry: { seenIDs.append($0.id) },
            emit: { _ in [] }
        )

        XCTAssertEqual(seenIDs, result.entries.map(\.id), "onEntry must fire once per case, in emission order")
        XCTAssertEqual(seenIDs.count, 3)
    }

    // MARK: - Round trip: generate → JSONL → existing bfcl scorer

    /// The load-bearing claim of this feature: `generateResponses`' output,
    /// JSON-encoded one-per-line, is scoreable by the EXISTING `bfcl` command's
    /// `cliRun` with zero adapters — because both read/write `BFCLResponseEntry`
    /// and both load cases via the same `BFCLLane.loadCases`.
    func testGenerateThenScoreRoundTrip_matchesExpectedAccuracy() async throws {
        let dir = try bfclFixtureDir()
        let lane = BFCLLane()

        // Emit the correct ground-truth call for simple_0 and simple_1 only;
        // simple_2 gets no call (an intentional miss).
        let result = await lane.generateResponses(
            categories: [.simple],
            corpusSource: .localDirectory(dir),
            emit: { testCase in
                switch testCase.id {
                case "simple_0":
                    return [ToolCall(id: "1", toolName: "calculate_triangle_area",
                                    arguments: #"{"base":10,"height":5}"#)]
                case "simple_1":
                    return [ToolCall(id: "2", toolName: "add", arguments: #"{"a":17,"b":4}"#)]
                default:
                    return []
                }
            }
        )
        XCTAssertEqual(result.entries.count, 3)

        // Encode exactly as the CLI does: JSONEncoder, one entry per line.
        let encoder = JSONEncoder()
        let jsonl = try result.entries
            .map { try String(decoding: encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
        let responsesURL = try writeTempJSONL(jsonl)
        defer { try? FileManager.default.removeItem(at: responsesURL) }

        // Confirm the responses loader (used by `bfcl --responses`) round-trips
        // the generated JSONL with no adapter.
        let loadedEntries = try BFCLLane.loadResponses(from: responsesURL)
        XCTAssertEqual(Set(loadedEntries.map(\.id)), Set(result.entries.map(\.id)))

        // Score it through the existing `bfcl` scorer path.
        let (scoreResult, markdown) = try await lane.cliRun(corpusDir: dir, responsesURL: responsesURL)
        let simple = try XCTUnwrap(scoreResult.categoryResults.first { $0.category == .simple })
        XCTAssertEqual(simple.total, 3)
        XCTAssertEqual(simple.passed, 2, "simple_0 and simple_1 should score correct; simple_2 was an intentional miss")
        XCTAssert(markdown.contains("simple"))
    }
}
