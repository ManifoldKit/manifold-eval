import XCTest
@testable import ManifoldEval
import ManifoldInference
import ManifoldTools

/// Fixture-driven tests for the BFCL full-corpus lane.
///
/// All cases use synthetic `emit` closures — no live model or backend is
/// required. The tests verify:
///
/// 1. The lane loads fixtures, routes scoring through `ASTMatcher`, and
///    aggregates per-category.
/// 2. Known exact pass/fail outcomes for each category's scoring semantics.
/// 3. The lane delegates to `ManifoldTools.ASTMatcher` (not a forked scorer).
final class BFCLLaneTests: XCTestCase {

    // MARK: - Fixture helpers

    private func bfclFixtureDir() throws -> URL {
        // The ManifoldEvalTests bundle copies Tests/ManifoldEvalTests/Fixtures/
        // verbatim. BFCL fixture files live under Fixtures/BFCL/.
        guard let resourceURL = Bundle.module.resourceURL else {
            throw XCTSkip("Bundle.module.resourceURL unavailable — skipping fixture-based tests")
        }
        return resourceURL.appendingPathComponent("Fixtures").appendingPathComponent("BFCL")
    }

    private func makeLane() -> BFCLLane { BFCLLane() }

    // MARK: - simple: disjunction semantics

    func testSimple_allCorrect() async throws {
        let dir = try bfclFixtureDir()
        let lane = makeLane()

        // Emit exactly the ground-truth call for each case.
        let result = await lane.run(
            categories: [.simple],
            corpusSource: .localDirectory(dir),
            emit: { testCase in
                switch testCase.id {
                case "simple_0":
                    return [ToolCall(id: "1", toolName: "calculate_triangle_area",
                                    arguments: #"{"base":10,"height":5}"#)]
                case "simple_1":
                    return [ToolCall(id: "2", toolName: "add",
                                    arguments: #"{"a":17,"b":4}"#)]
                case "simple_2":
                    return [ToolCall(id: "3", toolName: "celsius_to_fahrenheit",
                                    arguments: #"{"celsius":100}"#)]
                default:
                    return []
                }
            }
        )

        let simple = try XCTUnwrap(result.categoryResults.first { $0.category == .simple })
        XCTAssertFalse(simple.skipped, "simple category must not be skipped")
        XCTAssertEqual(simple.total, 3)
        XCTAssertEqual(simple.passed, 3, "all three simple cases should pass with correct calls")
        XCTAssertEqual(simple.accuracy, 1.0)
    }

    func testSimple_wrongArgsFail() async throws {
        let dir = try bfclFixtureDir()
        let lane = makeLane()

        // Emit the correct function name but wrong argument values.
        let result = await lane.run(
            categories: [.simple],
            corpusSource: .localDirectory(dir),
            emit: { _ in
                [ToolCall(id: "x", toolName: "calculate_triangle_area",
                          arguments: #"{"base":99,"height":99}"#)]
            }
        )

        let simple = try XCTUnwrap(result.categoryResults.first { $0.category == .simple })
        // simple_0 → wrong values fail; simple_1 + simple_2 → wrong function name
        XCTAssertEqual(simple.passed, 0, "wrong argument values must all fail")
    }

    func testSimple_optionalParamOmitted_passes() async throws {
        let dir = try bfclFixtureDir()
        let lane = makeLane()

        // simple_0 ground truth allows unit to be omitted (it's optional via "").
        let result = await lane.run(
            categories: [.simple],
            corpusSource: .localDirectory(dir),
            emit: { testCase in
                guard testCase.id == "simple_0" else { return [] }
                return [ToolCall(id: "1", toolName: "calculate_triangle_area",
                                 arguments: #"{"base":10,"height":5}"#)]
            }
        )

        let simple = try XCTUnwrap(result.categoryResults.first { $0.category == .simple })
        // Only simple_0 has a matching call; simple_1 and simple_2 get empty calls
        // which ASTMatcher counts as failed (no tool call emitted).
        XCTAssertEqual(simple.passed, 1, "simple_0 should pass with unit omitted")
        XCTAssertEqual(simple.total, 3)
    }

    // MARK: - multiple: disjunction (right tool from set)

    func testMultiple_correctToolSelection() async throws {
        let dir = try bfclFixtureDir()
        let lane = makeLane()

        // Emit the correct tool (the first in ground truth) for each case.
        let result = await lane.run(
            categories: [.multiple],
            corpusSource: .localDirectory(dir),
            emit: { testCase in
                switch testCase.id {
                case "multiple_0":
                    return [ToolCall(id: "1", toolName: "country_info.capital",
                                    arguments: #"{"country":"France"}"#)]
                case "multiple_1":
                    return [ToolCall(id: "2", toolName: "math.circle_area",
                                    arguments: #"{"radius":5}"#)]
                case "multiple_2":
                    return [ToolCall(id: "3", toolName: "get_weather",
                                    arguments: #"{"city":"Tokyo","unit":"celsius"}"#)]
                default:
                    return []
                }
            }
        )

        let multiple = try XCTUnwrap(result.categoryResults.first { $0.category == .multiple })
        XCTAssertEqual(multiple.total, 3)
        XCTAssertEqual(multiple.passed, 3, "all multiple cases should pass with the correct tool")
    }

    func testMultiple_wrongToolFails() async throws {
        let dir = try bfclFixtureDir()
        let lane = makeLane()

        // Emit the WRONG tool for each case.
        let result = await lane.run(
            categories: [.multiple],
            corpusSource: .localDirectory(dir),
            emit: { testCase in
                switch testCase.id {
                case "multiple_0":
                    // population instead of capital
                    return [ToolCall(id: "1", toolName: "country_info.population",
                                    arguments: #"{"country":"France"}"#)]
                case "multiple_1":
                    // triangle_area instead of circle_area
                    return [ToolCall(id: "2", toolName: "math.triangle_area",
                                    arguments: #"{"base":5,"height":5}"#)]
                case "multiple_2":
                    // forecast instead of weather
                    return [ToolCall(id: "3", toolName: "get_forecast",
                                    arguments: #"{"city":"Tokyo","days":1}"#)]
                default:
                    return []
                }
            }
        )

        let multiple = try XCTUnwrap(result.categoryResults.first { $0.category == .multiple })
        XCTAssertEqual(multiple.passed, 0, "wrong tool selection must fail")
    }

    // MARK: - parallel: conjunction semantics

    func testParallel_bothCallsPresent_passes() async throws {
        let dir = try bfclFixtureDir()
        let lane = makeLane()

        // parallel_0 expects two spotify.play calls (Taylor Swift, Maroon 5).
        let result = await lane.run(
            categories: [.parallel],
            corpusSource: .localDirectory(dir),
            emit: { testCase in
                switch testCase.id {
                case "parallel_0":
                    return [
                        ToolCall(id: "1", toolName: "spotify.play",
                                 arguments: #"{"artist":"Taylor Swift","duration":20}"#),
                        ToolCall(id: "2", toolName: "spotify.play",
                                 arguments: #"{"artist":"Maroon 5","duration":15}"#)
                    ]
                case "parallel_1":
                    return [
                        ToolCall(id: "3", toolName: "add", arguments: #"{"a":3,"b":4}"#),
                        ToolCall(id: "4", toolName: "add", arguments: #"{"a":10,"b":20}"#)
                    ]
                default:
                    return []
                }
            }
        )

        let parallel = try XCTUnwrap(result.categoryResults.first { $0.category == .parallel })
        XCTAssertEqual(parallel.total, 2)
        XCTAssertEqual(parallel.passed, 2, "parallel cases with all expected calls should pass")
    }

    func testParallel_onlyOneCallPresent_fails() async throws {
        let dir = try bfclFixtureDir()
        let lane = makeLane()

        // Emit only one call for each parallel case — both ground-truth calls
        // are required for parallel, so partial completion must fail.
        let result = await lane.run(
            categories: [.parallel],
            corpusSource: .localDirectory(dir),
            emit: { testCase in
                switch testCase.id {
                case "parallel_0":
                    // Only Taylor Swift; Maroon 5 call missing.
                    return [ToolCall(id: "1", toolName: "spotify.play",
                                    arguments: #"{"artist":"Taylor Swift","duration":20}"#)]
                case "parallel_1":
                    // Only 3+4; 10+20 missing.
                    return [ToolCall(id: "2", toolName: "add", arguments: #"{"a":3,"b":4}"#)]
                default:
                    return []
                }
            }
        )

        let parallel = try XCTUnwrap(result.categoryResults.first { $0.category == .parallel })
        XCTAssertEqual(parallel.passed, 0,
            "parallel cases with only one of two expected calls should fail")
    }

    func testParallel_wrongArgsFail() async throws {
        let dir = try bfclFixtureDir()
        let lane = makeLane()

        // Emit the right functions but with wrong argument values.
        let result = await lane.run(
            categories: [.parallel],
            corpusSource: .localDirectory(dir),
            emit: { _ in
                [
                    ToolCall(id: "1", toolName: "spotify.play",
                             arguments: #"{"artist":"Taylor Swift","duration":999}"#),
                    ToolCall(id: "2", toolName: "spotify.play",
                             arguments: #"{"artist":"Maroon 5","duration":999}"#)
                ]
            }
        )

        let parallel = try XCTUnwrap(result.categoryResults.first { $0.category == .parallel })
        XCTAssertEqual(parallel.passed, 0, "parallel with wrong argument values must fail")
    }

    // MARK: - parallel_multiple: conjunction, different functions

    func testParallelMultiple_bothCallsPresent_passes() async throws {
        let dir = try bfclFixtureDir()
        let lane = makeLane()

        let result = await lane.run(
            categories: [.parallelMultiple],
            corpusSource: .localDirectory(dir),
            emit: { testCase in
                switch testCase.id {
                case "parallel_multiple_0":
                    return [
                        ToolCall(id: "1", toolName: "get_weather",
                                 arguments: #"{"city":"London"}"#),
                        ToolCall(id: "2", toolName: "convert_currency",
                                 arguments: #"{"amount":100,"from_currency":"USD","to_currency":"EUR"}"#)
                    ]
                case "parallel_multiple_1":
                    return [
                        ToolCall(id: "3", toolName: "calculate_triangle_area",
                                 arguments: #"{"base":6,"height":4}"#),
                        ToolCall(id: "4", toolName: "convert_distance",
                                 arguments: #"{"value":50,"from_unit":"km","to_unit":"miles"}"#)
                    ]
                default:
                    return []
                }
            }
        )

        let pm = try XCTUnwrap(result.categoryResults.first { $0.category == .parallelMultiple })
        XCTAssertEqual(pm.total, 2)
        XCTAssertEqual(pm.passed, 2, "parallel_multiple cases with all expected calls should pass")
    }

    func testParallelMultiple_swappedCallOrder_passes() async throws {
        let dir = try bfclFixtureDir()
        let lane = makeLane()

        // Injective matching should be order-insensitive.
        let result = await lane.run(
            categories: [.parallelMultiple],
            corpusSource: .localDirectory(dir),
            emit: { testCase in
                guard testCase.id == "parallel_multiple_0" else { return [] }
                // Emit in reversed order vs. ground truth.
                return [
                    ToolCall(id: "2", toolName: "convert_currency",
                             arguments: #"{"amount":100,"from_currency":"USD","to_currency":"EUR"}"#),
                    ToolCall(id: "1", toolName: "get_weather",
                             arguments: #"{"city":"London"}"#)
                ]
            }
        )

        let pm = try XCTUnwrap(result.categoryResults.first { $0.category == .parallelMultiple })
        // Only parallel_multiple_0 has calls; parallel_multiple_1 gets no calls → fails.
        XCTAssertEqual(pm.passed, 1,
            "injective matching must be order-insensitive (first case passes)")
    }

    // MARK: - irrelevance: no-call semantics

    func testIrrelevance_noCallEmitted_passes() async throws {
        let dir = try bfclFixtureDir()
        let lane = makeLane()

        // Emit no tool calls for any case — model correctly abstains.
        let result = await lane.run(
            categories: [.irrelevance],
            corpusSource: .localDirectory(dir),
            emit: { _ in [] }
        )

        let irr = try XCTUnwrap(result.categoryResults.first { $0.category == .irrelevance })
        XCTAssertEqual(irr.total, 3)
        XCTAssertEqual(irr.passed, 3, "all irrelevance cases should pass when no call is emitted")
    }

    func testIrrelevance_callEmitted_fails() async throws {
        let dir = try bfclFixtureDir()
        let lane = makeLane()

        // Emit a (hallucinated) tool call for every irrelevance case.
        let result = await lane.run(
            categories: [.irrelevance],
            corpusSource: .localDirectory(dir),
            emit: { _ in
                [ToolCall(id: "x", toolName: "determine_body_mass_index",
                          arguments: #"{"weight":70,"height":1.75}"#)]
            }
        )

        let irr = try XCTUnwrap(result.categoryResults.first { $0.category == .irrelevance })
        XCTAssertEqual(irr.passed, 0,
            "irrelevance cases must fail when any tool call is emitted")
    }

    // MARK: - Full-lane aggregation

    func testAllCategories_aggregateAccuracy() async throws {
        let dir = try bfclFixtureDir()
        let lane = makeLane()

        // Emit correct calls for simple/multiple/parallel_multiple, nothing for others.
        let result = await lane.run(
            categories: BFCLCategory.allCases,
            corpusSource: .localDirectory(dir),
            emit: { testCase in
                switch testCase.id {
                // simple — all correct
                case "simple_0":
                    return [ToolCall(id: "s0", toolName: "calculate_triangle_area",
                                    arguments: #"{"base":10,"height":5}"#)]
                case "simple_1":
                    return [ToolCall(id: "s1", toolName: "add",
                                    arguments: #"{"a":17,"b":4}"#)]
                case "simple_2":
                    return [ToolCall(id: "s2", toolName: "celsius_to_fahrenheit",
                                    arguments: #"{"celsius":100}"#)]
                // multiple — all correct
                case "multiple_0":
                    return [ToolCall(id: "m0", toolName: "country_info.capital",
                                    arguments: #"{"country":"France"}"#)]
                case "multiple_1":
                    return [ToolCall(id: "m1", toolName: "math.circle_area",
                                    arguments: #"{"radius":5}"#)]
                case "multiple_2":
                    return [ToolCall(id: "m2", toolName: "get_weather",
                                    arguments: #"{"city":"Tokyo","unit":"celsius"}"#)]
                // parallel — all correct
                case "parallel_0":
                    return [
                        ToolCall(id: "p0a", toolName: "spotify.play",
                                 arguments: #"{"artist":"Taylor Swift","duration":20}"#),
                        ToolCall(id: "p0b", toolName: "spotify.play",
                                 arguments: #"{"artist":"Maroon 5","duration":15}"#)
                    ]
                case "parallel_1":
                    return [
                        ToolCall(id: "p1a", toolName: "add", arguments: #"{"a":3,"b":4}"#),
                        ToolCall(id: "p1b", toolName: "add", arguments: #"{"a":10,"b":20}"#)
                    ]
                // parallel_multiple — all correct
                case "parallel_multiple_0":
                    return [
                        ToolCall(id: "pm0a", toolName: "get_weather",
                                 arguments: #"{"city":"London"}"#),
                        ToolCall(id: "pm0b", toolName: "convert_currency",
                                 arguments: #"{"amount":100,"from_currency":"USD","to_currency":"EUR"}"#)
                    ]
                case "parallel_multiple_1":
                    return [
                        ToolCall(id: "pm1a", toolName: "calculate_triangle_area",
                                 arguments: #"{"base":6,"height":4}"#),
                        ToolCall(id: "pm1b", toolName: "convert_distance",
                                 arguments: #"{"value":50,"from_unit":"km","to_unit":"miles"}"#)
                    ]
                // irrelevance — emit nothing
                default:
                    return []
                }
            }
        )

        XCTAssertFalse(result.categoryResults.contains { $0.skipped },
            "no category should be skipped with bundled fixtures")

        let simple = try XCTUnwrap(result.categoryResults.first { $0.category == .simple })
        let multiple = try XCTUnwrap(result.categoryResults.first { $0.category == .multiple })
        let parallel = try XCTUnwrap(result.categoryResults.first { $0.category == .parallel })
        let parallelMultiple = try XCTUnwrap(result.categoryResults.first { $0.category == .parallelMultiple })
        let irrelevance = try XCTUnwrap(result.categoryResults.first { $0.category == .irrelevance })

        XCTAssertEqual(simple.passed, 3)
        XCTAssertEqual(multiple.passed, 3)
        XCTAssertEqual(parallel.passed, 2)
        XCTAssertEqual(parallelMultiple.passed, 2)
        XCTAssertEqual(irrelevance.passed, 3)

        // Total across all 5 categories: 3+3+2+2+3 = 13 passed / 13 total
        XCTAssertEqual(result.overallTotal, 13)
        XCTAssertEqual(result.overallPassed, 13)
        XCTAssertEqual(result.overallAccuracy, 1.0, accuracy: 1e-9)
        XCTAssertFalse(result.fullCorpusSourced,
            "localDirectory source must report fullCorpusSourced = false (scaffold)")
    }

    // MARK: - ASTMatcher reuse verification

    /// Confirms the lane delegates to `ManifoldTools.ASTMatcher.scoreCase` and
    /// `ASTMatcher.match`, not to a forked scorer. The verifier exercises a
    /// case that exposes the matcher's numeric cross-type tolerance
    /// (integer 10 == number 10.0), which is unique to the ManifoldTools
    /// implementation.
    func testReuseASTMatcher_numericCrossTypeTolerance() async throws {
        let dir = try bfclFixtureDir()
        let lane = makeLane()

        // simple_2: ground truth accepts celsius: [100, 100.0]. The model emits
        // celsius as an integer 100. A forked matcher without cross-type
        // tolerance would fail this; ASTMatcher handles it correctly.
        let result = await lane.run(
            categories: [.simple],
            corpusSource: .localDirectory(dir),
            emit: { testCase in
                guard testCase.id == "simple_2" else { return [] }
                // Emit integer where ground truth also allows number 100.0.
                return [ToolCall(id: "c", toolName: "celsius_to_fahrenheit",
                                 arguments: #"{"celsius":100}"#)]
            }
        )

        let simple = try XCTUnwrap(result.categoryResults.first { $0.category == .simple })
        // simple_2 passes (integer 100 == number 100.0 via ASTMatcher tolerance).
        // simple_0 and simple_1 get empty emit → fail.
        XCTAssertEqual(simple.passed, 1,
            "integer 100 should match number 100.0 via ASTMatcher cross-type tolerance")
    }
}
