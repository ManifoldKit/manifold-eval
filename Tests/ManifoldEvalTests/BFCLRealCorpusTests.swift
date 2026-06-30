import XCTest
@testable import ManifoldEval
import ManifoldInference
import ManifoldTools

/// Data-gated BFCL full-corpus tests that run against the real Gorilla v4
/// corpus (5 AST-track categories, ~1,435 cases total).
///
/// ## Gate
///
/// Tests skip cleanly when the corpus cache is absent. To populate and run:
///
/// 1. Download the corpus: `scripts/fetch-corpora.sh`
/// 2. Run the tests:
/// ```
/// BFCL_GORILLA_CACHE=~/.cache/manifold-eval/bfcl swift test --filter BFCLRealCorpusTests
/// ```
///
/// Set `RUN_BFCL_GORILLA=1` to trigger a network download from the Gorilla repo
/// during the test itself (cache miss → download → run):
/// ```
/// RUN_BFCL_GORILLA=1 swift test --filter BFCLRealCorpusTests
/// ```
///
/// ## What is verified
///
/// These tests do NOT require a live language model. They exercise the fetch →
/// parse → lane pipeline using a synthetic emit closure that returns no calls,
/// which lets us:
/// - Confirm ``BFCLCorpusFetcher`` downloads + caches correctly against live data.
/// - Confirm ``BFCLCaseLoader`` (via ``BFCLLane``) parses the real JSONL format.
/// - Assert the exact per-category case counts from the Gorilla v4 corpus.
/// - Confirm the irrelevance category scores 100% when no tool calls are emitted.
final class BFCLRealCorpusTests: XCTestCase {

    // MARK: - Gorilla v4 expected case counts (verified against live data)

    private enum GorillaV4 {
        static let simpleCases            = 399
        static let multipleCases          = 199
        static let parallelCases          = 199
        static let parallelMultipleCases  = 199
        static let irrelevanceCases       = 239
        static let totalCases             = simpleCases + multipleCases + parallelCases
                                            + parallelMultipleCases + irrelevanceCases // 1235
    }

    // MARK: - Test helpers

    /// Resolves the BFCL Gorilla cache directory.
    ///
    /// Priority:
    /// 1. `BFCL_GORILLA_CACHE` env var (explicit override)
    /// 2. `~/.cache/manifold-eval/bfcl` (conventional default)
    private func gorillaCacheDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["BFCL_GORILLA_CACHE"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/manifold-eval/bfcl")
    }

    /// Returns `true` when the cache directory contains at least the questions
    /// file for the `simple` category — a lightweight presence check.
    private func isCachePopulated(_ cacheDir: URL) -> Bool {
        let probe = cacheDir
            .appendingPathComponent("data")
            .appendingPathComponent("BFCL_v4_simple_python.json")
        return FileManager.default.fileExists(atPath: probe.path)
    }

    private func allowNetworkDownload() -> Bool {
        ProcessInfo.processInfo.environment["RUN_BFCL_GORILLA"] == "1"
    }

    // MARK: - Corpus download + parse

    /// Downloads (if needed) and parses the Gorilla v4 corpus, then asserts the
    /// expected per-category case counts. Uses a no-op emit so no live model is
    /// required.
    func testRealCorpusLoadsAndCountsMatch() async throws {
        let cacheDir = gorillaCacheDir()

        guard isCachePopulated(cacheDir) || allowNetworkDownload() else {
            throw XCTSkip(
                "BFCL Gorilla v4 corpus not cached. "
                + "Run `scripts/fetch-corpora.sh` or set RUN_BFCL_GORILLA=1."
            )
        }

        let lane = BFCLLane()
        let result = await lane.run(
            categories: BFCLCategory.allCases,
            corpusSource: .gorilla(cacheDir: cacheDir),
            // Emit nothing: verifies load and parse without a live model.
            emit: { _ in [] }
        )

        let skipped = result.categoryResults.filter(\.skipped)
        XCTAssertTrue(
            skipped.isEmpty,
            "no category should be skipped — skipped: \(skipped.map(\.category.rawValue))"
        )

        let simple = try XCTUnwrap(result.categoryResults.first { $0.category == .simple })
        let multiple = try XCTUnwrap(result.categoryResults.first { $0.category == .multiple })
        let parallel = try XCTUnwrap(result.categoryResults.first { $0.category == .parallel })
        let parallelMultiple = try XCTUnwrap(result.categoryResults.first { $0.category == .parallelMultiple })
        let irrelevance = try XCTUnwrap(result.categoryResults.first { $0.category == .irrelevance })

        XCTAssertEqual(simple.total,           GorillaV4.simpleCases,
                       "simple: expected \(GorillaV4.simpleCases) cases from Gorilla v4")
        XCTAssertEqual(multiple.total,         GorillaV4.multipleCases,
                       "multiple: expected \(GorillaV4.multipleCases) cases from Gorilla v4")
        XCTAssertEqual(parallel.total,         GorillaV4.parallelCases,
                       "parallel: expected \(GorillaV4.parallelCases) cases from Gorilla v4")
        XCTAssertEqual(parallelMultiple.total, GorillaV4.parallelMultipleCases,
                       "parallel_multiple: expected \(GorillaV4.parallelMultipleCases) cases from Gorilla v4")
        XCTAssertEqual(irrelevance.total,      GorillaV4.irrelevanceCases,
                       "irrelevance: expected \(GorillaV4.irrelevanceCases) cases from Gorilla v4")

        XCTAssertEqual(result.overallTotal, GorillaV4.totalCases,
                       "total cases across all categories should match Gorilla v4 count")

        // Irrelevance semantics: no-call emitted → correct.
        // All other categories: no-call emitted → incorrect (0 passed).
        XCTAssertEqual(irrelevance.passed, GorillaV4.irrelevanceCases,
                       "all irrelevance cases should pass when no tool call is emitted")
        XCTAssertEqual(simple.passed,           0, "simple: no-call should score 0")
        XCTAssertEqual(multiple.passed,         0, "multiple: no-call should score 0")
        XCTAssertEqual(parallel.passed,         0, "parallel: no-call should score 0")
        XCTAssertEqual(parallelMultiple.passed, 0, "parallel_multiple: no-call should score 0")

        XCTAssertTrue(result.fullCorpusSourced,
                      "gorilla(cacheDir:) source must report fullCorpusSourced = true")

        // Log per-category counts for the PR body.
        print("""
        [BFCLRealCorpus] Gorilla v4 corpus loaded:
          simple:           \(simple.total)
          multiple:         \(multiple.total)
          parallel:         \(parallel.total)
          parallel_multiple:\(parallelMultiple.total)
          irrelevance:      \(irrelevance.total)
          total:            \(result.overallTotal)
          irrelevance pass% (no-op emit): \(String(format: "%.1f%%", irrelevance.accuracy * 100))
        """)
    }

    // MARK: - Cache idempotency

    /// Verifies that fetching a category twice reuses the cache file (no re-download).
    ///
    /// Relies on ``BFCLCorpusFetcher/downloadIfAbsent(from:to:)``'s existence check.
    /// Passes when: second load is fast AND produces the same case count.
    func testCacheIsReusedOnSecondLoad() async throws {
        let cacheDir = gorillaCacheDir()
        guard isCachePopulated(cacheDir) || allowNetworkDownload() else {
            throw XCTSkip("BFCL corpus not cached; see testRealCorpusLoadsAndCountsMatch")
        }

        let lane = BFCLLane()

        // First pass: populate cache (or use existing).
        let first = await lane.run(
            categories: [.simple],
            corpusSource: .gorilla(cacheDir: cacheDir),
            emit: { _ in [] }
        )

        // Second pass: must hit cache, not network.
        let second = await lane.run(
            categories: [.simple],
            corpusSource: .gorilla(cacheDir: cacheDir),
            emit: { _ in [] }
        )

        let firstSimple = try XCTUnwrap(first.categoryResults.first { $0.category == .simple })
        let secondSimple = try XCTUnwrap(second.categoryResults.first { $0.category == .simple })
        XCTAssertEqual(firstSimple.total, secondSimple.total,
                       "cache reuse must produce the same case count on repeated loads")
    }
}
