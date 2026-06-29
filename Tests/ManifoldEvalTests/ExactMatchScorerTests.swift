import XCTest
@testable import ManifoldEval
import ManifoldInference

/// Unit tests for `ExactMatchScorer`.
///
/// No live model or backend — these are deterministic and run in CI.
/// Coverage: pass/fail verdicts, both normalization axes, and edge cases
/// (empty strings, whitespace-only strings).
final class ExactMatchScorerTests: XCTestCase {

    // MARK: - Helpers

    private func output(_ text: String) -> EvalRunOutput {
        EvalRunOutput(visibleText: text)
    }

    // MARK: - Strict exact match (default options)

    func testExactMatchPass() async {
        let scorer = ExactMatchScorer()
        let result = await scorer.score(output: output("42"), expected: "42")

        XCTAssertEqual(result.value, .bool(true))
        XCTAssertNil(result.explanation, "a pass should carry no explanation")
        XCTAssertEqual(result.answer, "42")
    }

    func testExactMatchFail() async {
        let scorer = ExactMatchScorer()
        let result = await scorer.score(output: output("43"), expected: "42")

        XCTAssertEqual(result.value, .bool(false))
        XCTAssertNotNil(result.explanation, "a fail must explain the mismatch")
        XCTAssertEqual(result.answer, "43", "answer carries the raw model output on failure")
    }

    func testExactMatchCaseSensitiveByDefault() async {
        // The default must not silently elide a casing difference — a model that
        // replies "Yes" when the expected answer is "yes" should score as a miss.
        let scorer = ExactMatchScorer()
        let result = await scorer.score(output: output("Yes"), expected: "yes")

        XCTAssertEqual(result.value, .bool(false))
    }

    func testExactMatchWhitespaceSensitiveByDefault() async {
        // Leading/trailing whitespace is significant by default — a model that
        // pads its answer with a trailing newline should score as a miss.
        let scorer = ExactMatchScorer()
        let result = await scorer.score(output: output("42\n"), expected: "42")

        XCTAssertEqual(result.value, .bool(false))
    }

    // MARK: - Normalization: trimWhitespace

    func testTrimWhitespacePassesWhenOnlyDiffIsLeadingTrailing() async {
        let scorer = ExactMatchScorer(options: .init(trimWhitespace: true))
        let result = await scorer.score(output: output("  hello  "), expected: "hello")

        XCTAssertEqual(result.value, .bool(true))
    }

    func testTrimWhitespacePassesNewlines() async {
        let scorer = ExactMatchScorer(options: .init(trimWhitespace: true))
        let result = await scorer.score(output: output("hello\n"), expected: "hello")

        XCTAssertEqual(result.value, .bool(true))
    }

    func testTrimWhitespaceStillFailsOnContentDifference() async {
        let scorer = ExactMatchScorer(options: .init(trimWhitespace: true))
        let result = await scorer.score(output: output("  hello world  "), expected: "hello")

        XCTAssertEqual(result.value, .bool(false))
    }

    func testTrimWhitespaceDoesNotNormalizeCase() async {
        // Enabling trimWhitespace must not silently enable caseInsensitive.
        let scorer = ExactMatchScorer(options: .init(trimWhitespace: true))
        let result = await scorer.score(output: output("  Hello  "), expected: "hello")

        XCTAssertEqual(result.value, .bool(false))
    }

    // MARK: - Normalization: caseInsensitive

    func testCaseInsensitivePassesUpperVsLower() async {
        let scorer = ExactMatchScorer(options: .init(caseInsensitive: true))
        let result = await scorer.score(output: output("HELLO WORLD"), expected: "hello world")

        XCTAssertEqual(result.value, .bool(true))
    }

    func testCaseInsensitiveMixedCasePass() async {
        let scorer = ExactMatchScorer(options: .init(caseInsensitive: true))
        let result = await scorer.score(output: output("The Answer Is 42"), expected: "the answer is 42")

        XCTAssertEqual(result.value, .bool(true))
    }

    func testCaseInsensitiveDoesNotTrimWhitespace() async {
        // Enabling caseInsensitive must not silently enable trimWhitespace.
        let scorer = ExactMatchScorer(options: .init(caseInsensitive: true))
        let result = await scorer.score(output: output("hello "), expected: "hello")

        XCTAssertEqual(result.value, .bool(false))
    }

    // MARK: - Combined normalization

    func testBothNormalizationsTogetherPass() async {
        let scorer = ExactMatchScorer(options: .init(trimWhitespace: true, caseInsensitive: true))
        let result = await scorer.score(output: output("  Hello World  "), expected: "hello world")

        XCTAssertEqual(result.value, .bool(true))
    }

    func testBothNormalizationsStillFailOnContent() async {
        let scorer = ExactMatchScorer(options: .init(trimWhitespace: true, caseInsensitive: true))
        let result = await scorer.score(output: output("  Wrong Answer  "), expected: "right answer")

        XCTAssertEqual(result.value, .bool(false))
    }

    // MARK: - Empty strings

    func testBothEmptyPass() async {
        let scorer = ExactMatchScorer()
        let result = await scorer.score(output: output(""), expected: "")

        XCTAssertEqual(result.value, .bool(true))
    }

    func testEmptyOutputNonEmptyExpectedFails() async {
        let scorer = ExactMatchScorer()
        let result = await scorer.score(output: output(""), expected: "something")

        XCTAssertEqual(result.value, .bool(false))
    }

    func testNonEmptyOutputEmptyExpectedFails() async {
        let scorer = ExactMatchScorer()
        let result = await scorer.score(output: output("something"), expected: "")

        XCTAssertEqual(result.value, .bool(false))
    }

    func testTrimWhitespaceOnWhitespaceOnlyOutputAndEmptyExpected() async {
        // A model that replies with only whitespace should NOT silently pass
        // against an empty expected after trimming — they both collapse to ""
        // after trim, so this is actually a pass. Documenting this explicitly
        // so the behaviour is deliberate and not a surprise.
        let scorer = ExactMatchScorer(options: .init(trimWhitespace: true))
        let result = await scorer.score(output: output("   "), expected: "")

        XCTAssertEqual(result.value, .bool(true),
            "both strings normalize to empty after trim; that is an intentional pass under trimWhitespace")
    }

    // MARK: - Score shape invariants

    func testAnswerAlwaysCarriesRawModelOutput() async {
        // `answer` must reflect the raw (pre-normalization) model output so the
        // report layer shows what the model actually said.
        let scorer = ExactMatchScorer(options: .init(trimWhitespace: true, caseInsensitive: true))
        let rawOutput = "  HELLO  "
        let result = await scorer.score(output: output(rawOutput), expected: "hello")

        XCTAssertEqual(result.answer, rawOutput)
    }

    func testMetadataScorerKeyPresent() async {
        let scorer = ExactMatchScorer()
        let result = await scorer.score(output: output("x"), expected: "x")

        XCTAssertEqual(result.metadata["scorer"], "ExactMatchScorer")
    }

    func testMetadataReflectsOptions() async {
        let scorer = ExactMatchScorer(options: .init(trimWhitespace: true, caseInsensitive: false))
        let result = await scorer.score(output: output("x"), expected: "x")

        XCTAssertEqual(result.metadata["trimWhitespace"], "true")
        XCTAssertEqual(result.metadata["caseInsensitive"], "false")
    }
}
