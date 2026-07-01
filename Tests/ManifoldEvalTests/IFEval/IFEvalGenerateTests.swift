import XCTest
@testable import ManifoldEval

/// Tests for `manifold-eval ifeval-generate`'s testable core: CLI argument
/// parsing (``IFEvalGenerateOptions/parse(_:)``) and the bounded-concurrency
/// generation loop (``IFEvalLane/generateResponses(cases:completedKeys:concurrency:onProgress:onEntry:emit:)``).
///
/// All tests use synthetic `emit` closures — no live model or Ollama server is
/// required. A live-gated smoke test against a real Ollama server lives in
/// ``IFEvalGenerateLiveTests``.
final class IFEvalGenerateTests: XCTestCase {

    // MARK: - Fixture helpers

    private func ifEvalFixtureURL() throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: "ifeval", withExtension: "jsonl", subdirectory: "Fixtures"),
            "Missing Fixtures/ifeval.jsonl from test bundle"
        )
    }

    private func loadFixtureCases(_ count: Int) throws -> [IFEvalCase] {
        let all = try IFEvalCorpus.load(from: ifEvalFixtureURL())
        XCTAssertGreaterThanOrEqual(all.count, count, "fixture must have at least \(count) cases")
        return Array(all.prefix(count))
    }

    private func writeTempJSONL(_ content: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ifeval-generate-test-\(UUID().uuidString).jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - IFEvalGenerateOptions.parse

    func testParse_requiredFlagsOnly_appliesDefaults() throws {
        let options = try IFEvalGenerateOptions.parse([
            "--ollama-model", "qwen2.5-0.5b",
            "--corpus", "ifeval.jsonl",
            "--out", "responses.jsonl",
        ])
        XCTAssertEqual(options.ollamaModel, "qwen2.5-0.5b")
        XCTAssertEqual(options.corpusPath, "ifeval.jsonl")
        XCTAssertEqual(options.outPath, "responses.jsonl")
        XCTAssertEqual(options.ollamaURLString, "http://localhost:11434")
        XCTAssertEqual(options.maxTokens, 512, "max-tokens default must match the overnight verified-correct run")
        XCTAssertEqual(options.concurrency, 6, "concurrency default must match the overnight verified-correct run")
        XCTAssertEqual(options.timeoutSeconds, 120)
    }

    func testParse_modelAlias_isEquivalentToOllamaModel() throws {
        let options = try IFEvalGenerateOptions.parse([
            "--model", "llama3.1-8b:latest",
            "--corpus", "c.jsonl",
            "--out", "o.jsonl",
        ])
        XCTAssertEqual(options.ollamaModel, "llama3.1-8b:latest")
    }

    func testParse_allFlagsOverridden() throws {
        let options = try IFEvalGenerateOptions.parse([
            "--ollama-model", "m",
            "--corpus", "c.jsonl",
            "--out", "o.jsonl",
            "--ollama-url", "http://example.test:1234",
            "--max-tokens", "256",
            "--concurrency", "3",
            "--timeout", "60",
        ])
        XCTAssertEqual(options.ollamaURLString, "http://example.test:1234")
        XCTAssertEqual(options.maxTokens, 256)
        XCTAssertEqual(options.concurrency, 3)
        XCTAssertEqual(options.timeoutSeconds, 60)
    }

    func testParse_missingOllamaModel_throws() {
        XCTAssertThrowsError(try IFEvalGenerateOptions.parse(["--corpus", "c.jsonl", "--out", "o.jsonl"])) { error in
            XCTAssertEqual(error as? IFEvalGenerateOptions.ParseError, .missingRequired(flag: "--ollama-model <tag>"))
        }
    }

    func testParse_missingCorpus_throws() {
        XCTAssertThrowsError(try IFEvalGenerateOptions.parse(["--ollama-model", "m", "--out", "o.jsonl"])) { error in
            XCTAssertEqual(error as? IFEvalGenerateOptions.ParseError, .missingRequired(flag: "--corpus <path>"))
        }
    }

    func testParse_missingOut_throws() {
        XCTAssertThrowsError(try IFEvalGenerateOptions.parse(["--ollama-model", "m", "--corpus", "c.jsonl"])) { error in
            XCTAssertEqual(error as? IFEvalGenerateOptions.ParseError, .missingRequired(flag: "--out <responses.jsonl>"))
        }
    }

    func testParse_unknownFlag_throws() {
        XCTAssertThrowsError(try IFEvalGenerateOptions.parse([
            "--ollama-model", "m", "--corpus", "c.jsonl", "--out", "o.jsonl", "--bogus", "x",
        ])) { error in
            XCTAssertEqual(error as? IFEvalGenerateOptions.ParseError, .unknownFlag("--bogus"))
        }
    }

    func testParse_nonPositiveConcurrency_throws() {
        XCTAssertThrowsError(try IFEvalGenerateOptions.parse([
            "--ollama-model", "m", "--corpus", "c.jsonl", "--out", "o.jsonl", "--concurrency", "0",
        ])) { error in
            XCTAssertEqual(error as? IFEvalGenerateOptions.ParseError, .invalidInt(flag: "--concurrency", value: "0"))
        }
    }

    func testParse_missingValueForFlag_throws() {
        XCTAssertThrowsError(try IFEvalGenerateOptions.parse(["--ollama-model"])) { error in
            XCTAssertEqual(error as? IFEvalGenerateOptions.ParseError, .missingValue(flag: "--ollama-model"))
        }
    }

    // MARK: - generateResponses: happy path

    func testGenerateResponses_producesOneEntryPerCase() async throws {
        let cases = try loadFixtureCases(5)

        let result = await IFEvalLane.generateResponses(
            cases: cases,
            emit: { _, testCase in "response for \(testCase.key)" }
        )

        XCTAssertEqual(result.attempted, 5)
        XCTAssertEqual(result.errored, 0)
        XCTAssertEqual(result.entries.count, 5)
        XCTAssertEqual(Set(result.entries.map(\.key)), Set(cases.map(\.key)))
        for entry in result.entries {
            XCTAssertEqual(entry.response, "response for \(entry.key)")
        }
    }

    // MARK: - generateResponses: resume-skip logic

    func testGenerateResponses_completedKeysAreSkipped() async throws {
        let cases = try loadFixtureCases(5)
        let alreadyDone = Set(cases.prefix(2).map(\.key))

        actor RequestLog {
            private(set) var keys: Set<String> = []
            func insert(_ key: String) { keys.insert(key) }
        }
        let log = RequestLog()

        let result = await IFEvalLane.generateResponses(
            cases: cases,
            completedKeys: alreadyDone,
            emit: { _, testCase in
                await log.insert(testCase.key)
                return "generated"
            }
        )

        // Only the 3 NOT-already-done cases should be (re)requested.
        let requestedKeys = await log.keys
        XCTAssertEqual(requestedKeys, Set(cases.suffix(3).map(\.key)))
        XCTAssertEqual(result.attempted, 3, "already-completed cases must not be re-attempted")
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertTrue(result.entries.allSatisfy { !alreadyDone.contains($0.key) })
    }

    func testGenerateResponses_allKeysAlreadyCompleted_generatesNothing() async throws {
        let cases = try loadFixtureCases(3)
        let allDone = Set(cases.map(\.key))

        actor CallFlag {
            private(set) var wasCalled = false
            func mark() { wasCalled = true }
        }
        let flag = CallFlag()

        let result = await IFEvalLane.generateResponses(
            cases: cases,
            completedKeys: allDone,
            emit: { _, _ in
                await flag.mark()
                return "should never run"
            }
        )

        let wasCalled = await flag.wasCalled
        XCTAssertFalse(wasCalled, "emit must not be invoked for any already-completed case")
        XCTAssertEqual(result.attempted, 0)
        XCTAssertEqual(result.entries.count, 0)
        XCTAssertEqual(result.errored, 0)
    }

    // MARK: - generateResponses: error handling (must not abort the batch)

    func testGenerateResponses_erroredCase_recordsEmptyResponseAndContinues() async throws {
        let cases = try loadFixtureCases(5)
        struct FakeTimeout: Error {}

        let result = await IFEvalLane.generateResponses(
            cases: cases,
            concurrency: 1, // deterministic: process in cursor order
            emit: { _, testCase in
                if testCase.key == cases[2].key {
                    throw FakeTimeout()
                }
                return "ok for \(testCase.key)"
            }
        )

        // All 5 cases still get an entry — one case erroring must not abort the run.
        XCTAssertEqual(result.attempted, 5)
        XCTAssertEqual(result.entries.count, 5, "an errored case still produces an entry (with an empty response)")
        XCTAssertEqual(result.errored, 1)

        let erroredEntry = try XCTUnwrap(result.entries.first { $0.key == cases[2].key })
        XCTAssertEqual(erroredEntry.response, "", "an errored case must record an EMPTY response, not crash")

        let okEntries = result.entries.filter { $0.key != cases[2].key }
        XCTAssertEqual(okEntries.count, 4)
        for entry in okEntries {
            XCTAssertEqual(entry.response, "ok for \(entry.key)")
        }
    }

    func testGenerateResponses_multipleErrors_allRecordedIndependently() async throws {
        let cases = try loadFixtureCases(6)
        struct FakeError: Error {}
        let failingKeys = Set([cases[1].key, cases[4].key])

        let result = await IFEvalLane.generateResponses(
            cases: cases,
            emit: { _, testCase in
                if failingKeys.contains(testCase.key) { throw FakeError() }
                return "ok"
            }
        )

        XCTAssertEqual(result.attempted, 6)
        XCTAssertEqual(result.entries.count, 6)
        XCTAssertEqual(result.errored, 2)
        for entry in result.entries where failingKeys.contains(entry.key) {
            XCTAssertEqual(entry.response, "")
        }
    }

    // MARK: - generateResponses: callback behavior

    func testGenerateResponses_onEntryFiresOncePerCase() async throws {
        let cases = try loadFixtureCases(5)
        actor SeenKeys {
            var keys: Set<String> = []
            func insert(_ key: String) { keys.insert(key) }
        }
        let seen = SeenKeys()

        let result = await IFEvalLane.generateResponses(
            cases: cases,
            onEntry: { entry, _ in await seen.insert(entry.key) },
            emit: { _, _ in "x" }
        )

        let seenKeys = await seen.keys
        XCTAssertEqual(seenKeys, Set(cases.map(\.key)), "onEntry must fire exactly once per attempted case")
        XCTAssertEqual(result.entries.count, 5)
    }

    func testGenerateResponses_onEntryReportsIsErrorAccurately() async throws {
        let cases = try loadFixtureCases(4)
        let failingKey = cases[1].key
        struct FakeError: Error {}

        actor ErrorFlags {
            var flagsByKey: [String: Bool] = [:]
            func record(_ key: String, isError: Bool) { flagsByKey[key] = isError }
        }
        let flags = ErrorFlags()

        _ = await IFEvalLane.generateResponses(
            cases: cases,
            onEntry: { entry, isError in await flags.record(entry.key, isError: isError) },
            emit: { _, testCase in
                if testCase.key == failingKey { throw FakeError() }
                return "ok"
            }
        )

        let recorded = await flags.flagsByKey
        XCTAssertEqual(recorded[failingKey], true, "the failing case must report isError: true to onEntry")
        for testCase in cases where testCase.key != failingKey {
            XCTAssertEqual(recorded[testCase.key], false, "a successful case must report isError: false to onEntry")
        }
    }

    /// The load-bearing resumability fix: a CLI caller that (correctly) skips
    /// persisting an errored entry — because `isError` was `true` — must see
    /// that case treated as NOT completed on the next `generateResponses`
    /// call, i.e. it gets retried rather than permanently stuck. This
    /// simulates exactly what `IFEvalGenerateCommand`'s `onEntry` does: only
    /// keys from SUCCESSFUL entries end up in the next run's `completedKeys`.
    func testGenerateResponses_erroredCaseIsRetriedOnNextInvocation_whenOnlySuccessesArePersisted() async throws {
        let cases = try loadFixtureCases(4)
        let flakyKey = cases[2].key
        struct FlakyFailure: Error {}

        // Shared, actor-serialized state simulating what the CLI tracks
        // across a first run and a resumed second run.
        actor RunState {
            var attemptCounts: [String: Int] = [:]
            var persistedKeys: Set<String> = []

            func recordAttempt(_ key: String) -> Int {
                attemptCounts[key, default: 0] += 1
                return attemptCounts[key]!
            }

            func persist(_ key: String, isError: Bool) {
                if !isError { persistedKeys.insert(key) }
            }
        }
        let state = RunState()

        // First "run": the flaky case fails once.
        let firstRun = await IFEvalLane.generateResponses(
            cases: cases,
            concurrency: 1,
            onEntry: { entry, isError in await state.persist(entry.key, isError: isError) },
            emit: { _, testCase in
                let attempt = await state.recordAttempt(testCase.key)
                if testCase.key == flakyKey, attempt == 1 {
                    throw FlakyFailure()
                }
                return "ok on attempt \(attempt)"
            }
        )
        XCTAssertEqual(firstRun.errored, 1)
        var persistedKeys = await state.persistedKeys
        XCTAssertFalse(persistedKeys.contains(flakyKey), "an errored case must not be in the persisted/completed set")
        XCTAssertEqual(persistedKeys.count, 3, "the 3 successful cases from the first run should be persisted")

        // Second "run" (a resume): completedKeys reflects only what was
        // actually persisted (successes) — the flaky case is NOT in it, so it
        // must be re-attempted, and this time it succeeds.
        let secondRun = await IFEvalLane.generateResponses(
            cases: cases,
            completedKeys: persistedKeys,
            concurrency: 1,
            onEntry: { entry, isError in await state.persist(entry.key, isError: isError) },
            emit: { _, testCase in
                let attempt = await state.recordAttempt(testCase.key)
                return "ok on attempt \(attempt)"
            }
        )

        XCTAssertEqual(secondRun.attempted, 1, "only the previously-errored case should be retried")
        XCTAssertEqual(secondRun.errored, 0)
        let retriedEntry = try XCTUnwrap(secondRun.entries.first)
        XCTAssertEqual(retriedEntry.key, flakyKey)
        XCTAssertEqual(retriedEntry.response, "ok on attempt 2", "the retry must actually re-invoke emit, not reuse the failed attempt")
        persistedKeys = await state.persistedKeys
        XCTAssertTrue(persistedKeys.contains(flakyKey), "after the successful retry, the case is now persisted")
    }

    // MARK: - Round trip: generate → JSONL → existing ifeval scorer

    /// The load-bearing claim of this feature: `generateResponses`' output,
    /// JSON-encoded one-per-line, is scoreable by the EXISTING `ifeval`
    /// command's `cliRun` with zero adapters.
    func testGenerateThenScoreRoundTrip() async throws {
        let corpusURL = try ifEvalFixtureURL()
        let cases = try loadFixtureCases(5)

        // Craft a response that satisfies "punctuation:no_comma" (no commas)
        // for every case that requires it, and an arbitrary response otherwise.
        let result = await IFEvalLane.generateResponses(
            cases: cases,
            emit: { _, testCase in
                testCase.instructionIDs.contains("punctuation:no_comma")
                    ? "This response has no commas at all in it."
                    : "arbitrary response, with a comma"
            }
        )
        XCTAssertEqual(result.entries.count, 5)

        let encoder = JSONEncoder()
        let jsonl = try result.entries
            .map { try String(decoding: encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
        let responsesURL = try writeTempJSONL(jsonl)
        defer { try? FileManager.default.removeItem(at: responsesURL) }

        // Confirm the responses loader (used by `ifeval --responses`) round-trips
        // the generated JSONL with no adapter.
        let loadedEntries = try IFEvalLane.loadResponses(from: responsesURL)
        XCTAssertEqual(Set(loadedEntries.map(\.key)), Set(result.entries.map(\.key)))

        // Score it through the existing `ifeval` scorer path. `cliRun` scores the
        // FULL corpus at `corpusURL` (541 cases) — cases outside our 5-case
        // slice score against "" (no response), which is expected: this test
        // proves the generate→JSONL→scorer plumbing, not full-corpus accuracy.
        let fullCorpus = try IFEvalCorpus.load(from: corpusURL)
        let lane = IFEvalLane()
        let runResult = try lane.cliRun(corpusURL: corpusURL, responsesURL: responsesURL)
        XCTAssertEqual(runResult.score.totalCases, fullCorpus.count)
        XCTAssert(runResult.markdown.contains("IFEval Results"))
    }
}
