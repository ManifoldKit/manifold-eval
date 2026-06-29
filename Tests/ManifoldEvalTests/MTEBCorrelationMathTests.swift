import XCTest
import ManifoldInference
@testable import ManifoldEval

/// Pure-math tests for ``CorrelationMath``. No embedder, no network, no env gate —
/// these run unconditionally in CI.
final class MTEBCorrelationMathTests: XCTestCase {

    // MARK: - cosine

    func testCosineParallel() {
        // Two identical vectors: cosine == 1.0
        let v: [Float] = [1, 2, 3, 4]
        let result = CorrelationMath.cosine(v, v)
        XCTAssertEqual(result, 1.0, accuracy: 1e-6)
    }

    func testCosineOrthogonal() {
        // Orthogonal vectors: cosine == 0.0
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        XCTAssertEqual(CorrelationMath.cosine(a, b), 0.0, accuracy: 1e-6)
    }

    func testCosineAntiparallel() {
        // Anti-parallel vectors: cosine == -1.0
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [-1, -2, -3]
        XCTAssertEqual(CorrelationMath.cosine(a, b), -1.0, accuracy: 1e-6)
    }

    func testCosineKnownValue() {
        // a = (1, 0), b = (1, 1) / sqrt(2): cosine = 1/sqrt(2) ≈ 0.7071
        let a: [Float] = [1, 0]
        let b: [Float] = [1, 1]
        let expected = 1.0 / Double(2.0.squareRoot())
        XCTAssertEqual(CorrelationMath.cosine(a, b), expected, accuracy: 1e-6)
    }

    func testCosineZeroVectorIsNaN() {
        let zero: [Float] = [0, 0, 0]
        let v: [Float] = [1, 2, 3]
        XCTAssertTrue(CorrelationMath.cosine(zero, v).isNaN)
        XCTAssertTrue(CorrelationMath.cosine(v, zero).isNaN)
    }

    func testCosineEmptyIsNaN() {
        XCTAssertTrue(CorrelationMath.cosine([], []).isNaN)
    }

    func testCosineLengthMismatchIsNaN() {
        XCTAssertTrue(CorrelationMath.cosine([1, 2], [1, 2, 3]).isNaN)
    }

    // MARK: - pearson

    func testPearsonPerfectPositiveCorrelation() {
        // y = 2x + 1 → Pearson must be exactly 1.
        let x = [1.0, 2.0, 3.0, 4.0, 5.0]
        let y = x.map { 2 * $0 + 1 }
        XCTAssertEqual(CorrelationMath.pearson(x, y), 1.0, accuracy: 1e-10)
    }

    func testPearsonPerfectNegativeCorrelation() {
        let x = [1.0, 2.0, 3.0, 4.0, 5.0]
        let y = x.map { -$0 + 6 }
        XCTAssertEqual(CorrelationMath.pearson(x, y), -1.0, accuracy: 1e-10)
    }

    func testPearsonUncorrelated() {
        // A constant array has zero variance → Pearson is undefined (.nan).
        let x = [1.0, 2.0, 3.0]
        let constant = [5.0, 5.0, 5.0]
        XCTAssertTrue(CorrelationMath.pearson(x, constant).isNaN)
    }

    func testPearsonTooShortIsNaN() {
        XCTAssertTrue(CorrelationMath.pearson([1.0], [2.0]).isNaN)
    }

    func testPearsonLengthMismatchIsNaN() {
        XCTAssertTrue(CorrelationMath.pearson([1.0, 2.0], [1.0, 2.0, 3.0]).isNaN)
    }

    // MARK: - spearman

    func testSpearmanPerfectMonotoneTiedRanks() {
        // x and y have the same rank order → Spearman == 1.
        let x = [10.0, 20.0, 30.0, 40.0, 50.0]
        let y = [1.0, 4.0, 9.0, 16.0, 25.0]  // monotone increasing, not linear
        XCTAssertEqual(CorrelationMath.spearman(x, y), 1.0, accuracy: 1e-10)
    }

    func testSpearmanPerfectNegativeMonotone() {
        let x = [1.0, 2.0, 3.0, 4.0, 5.0]
        let y = [5.0, 4.0, 3.0, 2.0, 1.0]
        XCTAssertEqual(CorrelationMath.spearman(x, y), -1.0, accuracy: 1e-10)
    }

    func testSpearmanTiedValuesAverageRank() {
        // x has ties at positions 1 and 2 (both 2.0); their average rank is 1.5.
        // y is perfectly monotone → Spearman should still be 1.0 since the
        // y-ranks match the x-ranks despite ties.
        let x = [1.0, 2.0, 2.0, 3.0]
        let y = [10.0, 20.0, 20.0, 30.0]
        XCTAssertEqual(CorrelationMath.spearman(x, y), 1.0, accuracy: 1e-10)
    }

    // MARK: - ranks helper

    func testRanksNoTies() {
        let ranks = CorrelationMath.ranks([30.0, 10.0, 20.0])
        // 10 → rank 1, 20 → rank 2, 30 → rank 3
        XCTAssertEqual(ranks[0], 3.0, accuracy: 1e-10)  // 30 is the largest
        XCTAssertEqual(ranks[1], 1.0, accuracy: 1e-10)  // 10 is the smallest
        XCTAssertEqual(ranks[2], 2.0, accuracy: 1e-10)  // 20 is in the middle
    }

    func testRanksTied() {
        let ranks = CorrelationMath.ranks([1.0, 1.0, 3.0])
        // 1.0 occupies positions 1 and 2 → average rank 1.5; 3.0 occupies position 3.
        XCTAssertEqual(ranks[0], 1.5, accuracy: 1e-10)
        XCTAssertEqual(ranks[1], 1.5, accuracy: 1e-10)
        XCTAssertEqual(ranks[2], 3.0, accuracy: 1e-10)
    }

    // MARK: - MTEBLane correlation on synthetic data

    /// A crafted set where cosines are strictly monotone with gold scores → both
    /// correlations must be 1.0. This proves the full lane math path end-to-end on
    /// synthetic data, with no embedder involved.
    func testLaneResultCorrelationWithPerfectOrdering() {
        let cosines = [0.1, 0.3, 0.5, 0.7, 0.9]
        let goldScores = [0.5, 1.5, 2.5, 3.5, 4.5]
        XCTAssertEqual(CorrelationMath.spearman(cosines, goldScores), 1.0, accuracy: 1e-10)
        XCTAssertEqual(CorrelationMath.pearson(cosines, goldScores), 1.0, accuracy: 1e-10)
    }

    /// A set with reversed ordering → both correlations must be -1.0.
    func testLaneResultCorrelationWithReverseOrdering() {
        let cosines = [0.9, 0.7, 0.5, 0.3, 0.1]
        let goldScores = [0.5, 1.5, 2.5, 3.5, 4.5]
        XCTAssertEqual(CorrelationMath.spearman(cosines, goldScores), -1.0, accuracy: 1e-10)
        XCTAssertEqual(CorrelationMath.pearson(cosines, goldScores), -1.0, accuracy: 1e-10)
    }

    // MARK: - MTEBLane.builtinFixture sanity

    func testBuiltinFixtureHas15Pairs() {
        XCTAssertEqual(MTEBLane.builtinFixture.count, 15)
    }

    func testBuiltinFixtureGoldScoresInRange() {
        for pair in MTEBLane.builtinFixture {
            XCTAssertGreaterThanOrEqual(pair.goldScore, 0)
            XCTAssertLessThanOrEqual(pair.goldScore, 5)
        }
    }

    func testBuiltinFixtureGoldScoreSpread() {
        let scores = MTEBLane.builtinFixture.map(\.goldScore)
        let min = scores.min() ?? 0
        let max = scores.max() ?? 0
        // The fixture should cover a reasonable spread — at least 4 units out of 5.
        XCTAssertGreaterThanOrEqual(max - min, 4.0,
            "fixture gold scores should span at least 4 points for useful correlation signal")
    }

    // MARK: - MTEBLaneError

    func testMTEBLaneErrorNoPairsAsync() async throws {
        // MTEBLane.run must throw .noPairs for an empty array.
        // A mock backend is not needed — the guard fires before any embed call.
        let embedder = AlwaysFailEmbedder()
        do {
            _ = try await MTEBLane.run(pairs: [], embedder: embedder, modelName: "test")
            XCTFail("Expected MTEBLaneError.noPairs to be thrown")
        } catch MTEBLaneError.noPairs {
            // expected
        }
    }

    // MARK: - loadPairs

    func testLoadPairsReturnsNilForMissingFile() throws {
        let missing = URL(fileURLWithPath: "/tmp/nonexistent-sts-\(UUID().uuidString).json")
        let result = try MTEBLane.loadPairs(from: missing)
        XCTAssertNil(result, "loadPairs should return nil when the file does not exist")
    }

    func testLoadPairsDecodesValidJSON() throws {
        let json = """
        [
          {"sentence1": "A", "sentence2": "B", "goldScore": 2.5},
          {"sentence1": "C", "sentence2": "D", "goldScore": 4.0}
        ]
        """.data(using: .utf8)!
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sts-test-\(UUID().uuidString).json")
        try json.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let pairs = try MTEBLane.loadPairs(from: tempURL)
        let unwrapped = try XCTUnwrap(pairs)
        XCTAssertEqual(unwrapped.count, 2)
        XCTAssertEqual(unwrapped[0].sentence1, "A")
        XCTAssertEqual(unwrapped[1].goldScore, 4.0, accuracy: 1e-10)
    }

    func testLoadPairsThrowsOnMalformedJSON() throws {
        let badJSON = "{ not an array }".data(using: .utf8)!
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sts-bad-\(UUID().uuidString).json")
        try badJSON.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        XCTAssertThrowsError(try MTEBLane.loadPairs(from: tempURL)) { error in
            guard case MTEBLaneError.datasetDecodeFailed = error else {
                return XCTFail("expected .datasetDecodeFailed, got \(error)")
            }
        }
    }
}

// MARK: - Test doubles

/// A minimal EmbeddingBackend that always throws, used to verify pre-condition guards
/// that fire before any embed call (e.g. the .noPairs guard).
private final class AlwaysFailEmbedder: EmbeddingBackend, @unchecked Sendable {
    var isModelLoaded: Bool { true }
    var dimensions: Int { 0 }
    func loadModel(from url: URL) async throws {}
    func unloadModel() {}
    func embed(_ texts: [String]) async throws -> [[Float]] {
        throw EmbeddingError.modelNotLoaded
    }
}
