import XCTest
@testable import ManifoldEval

/// Unit tests for the production ``RegressionScorer`` conformances used by the
/// `regress` subcommand. Each scoring branch has a sabotage note.
final class RegressionScorersTests: XCTestCase {

    // MARK: - ExactMatch

    func testExactMatchTrimsAndMatches() throws {
        let scorer = ExactMatchRegressionScorer(expected: "Paris")
        // sabotage: change "  Paris\n" to "Paris, France" → 0.0
        XCTAssertEqual(try scorer.score("  Paris\n"), 1.0)
        XCTAssertEqual(try scorer.score("Paris, France"), 0.0)
    }

    func testExactMatchCaseSensitiveByDefault() throws {
        let scorer = ExactMatchRegressionScorer(expected: "Paris")
        XCTAssertEqual(try scorer.score("paris"), 0.0)
    }

    func testExactMatchIgnoreCase() throws {
        let scorer = ExactMatchRegressionScorer(expected: "Paris", caseSensitive: false)
        // sabotage: flip caseSensitive back to true → 0.0
        XCTAssertEqual(try scorer.score("PARIS"), 1.0)
    }

    func testExactMatchNoTrimWhenDisabled() throws {
        let scorer = ExactMatchRegressionScorer(expected: "Paris", trimWhitespace: false)
        XCTAssertEqual(try scorer.score(" Paris "), 0.0, "whitespace must matter when trim is off")
        XCTAssertEqual(try scorer.score("Paris"), 1.0)
    }

    // MARK: - Substring

    func testSubstringContains() throws {
        let scorer = SubstringRegressionScorer(expected: "4")
        // sabotage: change "the answer is 4" to "the answer is four" → 0.0
        XCTAssertEqual(try scorer.score("the answer is 4"), 1.0)
        XCTAssertEqual(try scorer.score("the answer is four"), 0.0)
    }

    func testSubstringCaseInsensitive() throws {
        let scorer = SubstringRegressionScorer(expected: "Paris", caseSensitive: false)
        XCTAssertEqual(try scorer.score("the capital is paris"), 1.0)
    }

    /// Scores live in [0, 1] — the contract ``RegressionGate`` relies on.
    func testScoresAreInUnitInterval() throws {
        for output in ["4", "nope", "Paris", ""] {
            for s: any RegressionScorer in [
                ExactMatchRegressionScorer(expected: "Paris"),
                SubstringRegressionScorer(expected: "4"),
            ] {
                let v = try XCTUnwrap(try s.score(output))
                XCTAssertTrue((0...1).contains(v), "score \(v) for '\(output)' out of [0,1]")
            }
        }
    }
}
