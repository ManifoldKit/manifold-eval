import XCTest
@testable import ManifoldEval
@testable import manifold_eval

/// Fixture-driven tests for the pre-triage assistant (#23). No live model — these
/// run on hosted CI. Every assertion targets an exact value (never a looser "is
/// non-nil" check) so a classifier or confidence regression fails loudly.
final class TriageBriefTests: XCTestCase {

    // MARK: builders

    private func run(
        backend: String = "ollama",
        model: String = "m",
        quant: String = "server",
        promptSha: String = "aaa",
        inputTokens: [Int] = [],
        output: String = "hello",
        sampler: SamplerConfig = .greedy,
        repeatIndex: Int = 0
    ) -> RawRun {
        RawRun(
            backend: backend,
            model: model,
            quant: quant,
            promptSha256: promptSha,
            inputTokenIds: inputTokens,
            output: output,
            outputTokenIds: [],
            sampler: sampler,
            coreCommit: "deadbeef",
            toolingVersions: ["ollama": "0.30.11"],
            repeatIndex: repeatIndex
        )
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name).json"
        )
        return try Data(contentsOf: url)
    }

    // MARK: - proposes the correct classification (fixture: known genuine divergence)

    func testFixtureWithKnownDivergenceProposesGenuineDivergence() throws {
        let data = try fixture("triage-genuine-divergence")
        let transcript = try JSONDecoder().decode(TriageTranscript.self, from: data)
        let brief = try TriageBrief.build(legA: transcript.legA, legB: transcript.legB)

        XCTAssertEqual(brief.proposedClassification, .genuineDivergence)
        XCTAssertTrue(brief.sameBytesControlSatisfied)
        XCTAssertTrue(brief.determinismControlSatisfied)
        XCTAssertEqual(brief.confidence, .high)
    }

    func testFixtureDifferingBytesShowExactSegments() throws {
        let data = try fixture("triage-genuine-divergence")
        let transcript = try JSONDecoder().decode(TriageTranscript.self, from: data)
        let brief = try TriageBrief.build(legA: transcript.legA, legB: transcript.legB)

        let diverging = try XCTUnwrap(brief.diverging)
        // "The answer is forty-two." vs "The answer is 42." — common prefix
        // "The answer is ", differing middle, common suffix ".".
        XCTAssertEqual(diverging.aDiffering, "forty-two")
        XCTAssertEqual(diverging.bDiffering, "42")
        XCTAssertEqual(diverging.commonPrefixLength, "The answer is ".utf8.count)
        XCTAssertEqual(diverging.commonSuffixLength, ".".utf8.count)
    }

    func testRenderedBriefContainsDifferingBytesAndAdvisoryBanner() throws {
        let data = try fixture("triage-genuine-divergence")
        let transcript = try JSONDecoder().decode(TriageTranscript.self, from: data)
        let brief = try TriageBrief.build(legA: transcript.legA, legB: transcript.legB)
        let rendered = brief.render()

        XCTAssertTrue(rendered.contains("ADVISORY ONLY"))
        XCTAssertTrue(rendered.contains("forty-two"))
        XCTAssertTrue(rendered.contains("42"))
    }

    // MARK: - verdict stays unset/advisory by default

    func testVerdictUnsetByDefault() throws {
        let brief = try TriageBrief.build(
            legA: [run(promptSha: "same", output: "a")],
            legB: [run(promptSha: "same", output: "b")]
        )
        XCTAssertNil(brief.humanDecision)
        XCTAssertTrue(brief.render().contains("unset — awaiting human"))
    }

    // MARK: - records a human decision when --decide is passed

    func testHumanDecisionRecordedWhenSupplied() throws {
        let brief = try TriageBrief.build(
            legA: [run(promptSha: "same", output: "a")],
            legB: [run(promptSha: "same", output: "b")],
            humanDecision: .genuine
        )
        XCTAssertEqual(brief.humanDecision, .genuine)
        XCTAssertTrue(brief.render().contains("RECORDED: genuine"))
    }

    func testCLIDecideFlagParsesIntoParsedArguments() {
        var diedMessage: String?
        let parsed = TriageCommand.parseArguments(["--transcript", "t.json", "--decide", "benign"]) { message, _ in
            diedMessage = message
            fatalError("die() called unexpectedly with: \(message)")
        }
        XCTAssertNil(diedMessage)
        XCTAssertEqual(parsed.decide, .benign)
        XCTAssertEqual(parsed.transcriptPath, "t.json")
    }

    func testCLIDecideDefaultsToNilWhenOmitted() {
        let parsed = TriageCommand.parseArguments(["--transcript", "t.json"]) { _, _ in
            fatalError("die() should not be called")
        }
        XCTAssertNil(parsed.decide)
    }

    // MARK: - LOW confidence flagged loudly when a control is unmet

    func testLowConfidenceWhenSameBytesControlUnmet() throws {
        // Two repeats on EACH leg (so determinismControlSatisfied is independently
        // true) isolates the same-bytes control as the sole cause of .low —
        // otherwise a single-repeat fixture would pass this assertion for the
        // wrong reason (determinism unmet) even if the same-bytes check were
        // disabled entirely.
        let brief = try TriageBrief.build(
            legA: [
                run(promptSha: "aaa", output: "x", repeatIndex: 0),
                run(promptSha: "aaa", output: "x", repeatIndex: 1),
            ],
            legB: [
                run(promptSha: "bbb", output: "x", repeatIndex: 0),
                run(promptSha: "bbb", output: "x", repeatIndex: 1),
            ]
        )
        XCTAssertEqual(brief.proposedClassification, .promptDivergence)
        XCTAssertFalse(brief.sameBytesControlSatisfied)
        XCTAssertTrue(brief.determinismControlSatisfied)
        XCTAssertEqual(brief.confidence, .low)
        XCTAssertTrue(brief.render().contains("LOW CONFIDENCE"))
    }

    func testLowConfidenceWhenDeterminismControlUnmet() throws {
        // Single repeat on each leg → wasAssessed == false → determinism
        // control unmet, even though outputs happen to differ cleanly.
        let brief = try TriageBrief.build(
            legA: [run(promptSha: "same", output: "a")],
            legB: [run(promptSha: "same", output: "b")]
        )
        XCTAssertFalse(brief.determinismControlSatisfied)
        XCTAssertEqual(brief.confidence, .low)
        XCTAssertTrue(brief.render().contains("LOW CONFIDENCE"))
    }

    func testHighConfidenceWhenBothControlsSatisfiedAndGenuineDivergence() throws {
        let brief = try TriageBrief.build(
            legA: [
                run(promptSha: "same", output: "a", repeatIndex: 0),
                run(promptSha: "same", output: "a", repeatIndex: 1),
            ],
            legB: [
                run(promptSha: "same", output: "b", repeatIndex: 0),
                run(promptSha: "same", output: "b", repeatIndex: 1),
            ]
        )
        XCTAssertTrue(brief.sameBytesControlSatisfied)
        XCTAssertTrue(brief.determinismControlSatisfied)
        XCTAssertEqual(brief.proposedClassification, .genuineDivergence)
        XCTAssertEqual(brief.confidence, .high)
        XCTAssertFalse(brief.render().contains("LOW CONFIDENCE"))
    }

    // MARK: - empty leg is a hard error, never a fabricated brief

    func testEmptyLegThrows() {
        XCTAssertThrowsError(try TriageBrief.build(legA: [], legB: [run()])) { error in
            XCTAssertEqual(error as? TriageError, .emptyLeg)
        }
    }

    // MARK: - identical outputs show no differing segment

    func testIdenticalOutputsHaveNoDivergingSegment() throws {
        let brief = try TriageBrief.build(
            legA: [
                run(promptSha: "same", output: "identical", repeatIndex: 0),
                run(promptSha: "same", output: "identical", repeatIndex: 1),
            ],
            legB: [
                run(promptSha: "same", output: "identical", repeatIndex: 0),
                run(promptSha: "same", output: "identical", repeatIndex: 1),
            ]
        )
        XCTAssertNil(brief.diverging)
        XCTAssertEqual(brief.proposedClassification, .identical)
    }
}
