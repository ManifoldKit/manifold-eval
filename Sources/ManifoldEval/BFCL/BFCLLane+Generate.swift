import Foundation
import ManifoldInference
import ManifoldTools

// MARK: - Full-corpus response generation

/// Backend-agnostic generation loop shared by `manifold-eval bfcl-generate`.
///
/// This is deliberately the mirror image of ``BFCLLane/cliRun(corpusDir:responsesURL:)``:
/// where `cliRun` reads pre-computed ``BFCLResponseEntry`` values and scores
/// them, ``BFCLLane/generateResponses(categories:corpusSource:onProgress:onEntry:emit:)``
/// *produces* them by driving `emit` over every loaded case. Both sides route
/// through ``BFCLLane/loadCases(category:source:)``, so a generate run and a
/// later score run always see identical case ids from identical corpus
/// sources — there is no separate corpus-layout path for the two to drift out
/// of sync on.
public extension BFCLLane {

    /// Aggregate outcome of a generation run.
    struct GenerateResult: Sendable {
        /// One entry per attempted case, in the order cases were generated
        /// (categories in the order passed to `generateResponses`, cases within
        /// a category in corpus order).
        public let entries: [BFCLResponseEntry]
        /// Total cases attempted (categories that failed to load are excluded).
        public let attempted: Int
        /// Cases whose `emit` threw (timeout, backend error). These still get an
        /// entry — with an empty call list — so `attempted == entries.count`.
        public let errored: Int

        public init(entries: [BFCLResponseEntry], attempted: Int, errored: Int) {
            self.entries = entries
            self.attempted = attempted
            self.errored = errored
        }
    }

    /// Drives every case in `categories` through `emit`, one at a time, and
    /// returns one ``BFCLResponseEntry`` per attempted case — the exact schema
    /// ``cliRun(corpusDir:responsesURL:)`` (and the `bfcl` scorer's
    /// ``loadResponses(from:)``) reads. Encoding the returned entries with
    /// `JSONEncoder`, one per line, produces a file the existing `bfcl` command
    /// scores with zero adapters.
    ///
    /// A case whose `emit` throws (timeout, backend error) is recorded with an
    /// EMPTY call list and counted in ``GenerateResult/errored`` — it does NOT
    /// abort the run. This mirrors `BFCLRunner.run`'s policy (ManifoldTools) of
    /// treating a per-case error as "no calls" rather than crashing the whole
    /// batch: a single non-terminating generation must not stall a
    /// 1,000+-case full-corpus run.
    ///
    /// - Parameters:
    ///   - categories: which categories to generate (default: all five
    ///     AST-track categories).
    ///   - corpusSource: how to resolve question/answer files. Use the SAME
    ///     source the eventual scoring run will use (e.g. the same
    ///     `.gorilla(cacheDir:)`) so ids line up by construction.
    ///   - onProgress: sink for human-readable progress lines. The CLI wires
    ///     this to stderr so a long-running full-corpus generation is
    ///     observable rather than a silent multi-hour black box.
    ///   - onEntry: called once per attempted case, in order, immediately after
    ///     its result is known — lets a caller stream-write JSONL to disk as it
    ///     goes, so a multi-hour full-corpus run banks progress incrementally
    ///     instead of losing everything to a crash near the end.
    ///   - emit: async closure that returns the tool calls a model emitted for
    ///     a given case. Call `BFCLRunner.emittedCalls(for:service:timeoutSeconds:)`
    ///     for a live run, or a synthetic closure in tests.
    ///
    /// `@MainActor`-isolated to match `BFCLRunner.emittedCalls` (itself
    /// `@MainActor`, via ManifoldTools' `@MainActor public struct BFCLRunner`)
    /// and so the CLI's `onProgress`/`onEntry` callbacks — typically closing
    /// over MainActor-isolated state like an open `FileHandle` — can be plain,
    /// non-`@Sendable` closures instead of forcing every caller to prove
    /// Sendability for what is, start to finish, a single sequential loop.
    @MainActor
    func generateResponses(
        categories: [BFCLCategory] = BFCLCategory.allCases,
        corpusSource: CorpusSource,
        onProgress: (String) -> Void = { _ in },
        onEntry: (BFCLResponseEntry) -> Void = { _ in },
        emit: @Sendable (BFCLLoadedCase) async throws -> [ToolCall]
    ) async -> GenerateResult {
        var entries: [BFCLResponseEntry] = []
        var attempted = 0
        var errored = 0

        for category in categories {
            let cases: [BFCLLoadedCase]
            do {
                cases = try await loadCases(category: category, source: corpusSource)
            } catch {
                onProgress("[\(category.rawValue)] failed to load corpus (\(error)) — skipping category")
                continue
            }
            onProgress("[\(category.rawValue)] \(cases.count) case(s)")

            for (offset, testCase) in cases.enumerated() {
                attempted += 1
                let calls: [ToolCall]
                do {
                    calls = try await emit(testCase)
                    let summary = calls.first.map { "\($0.toolName)(\($0.arguments))" } ?? "<no tool call>"
                    onProgress("  [\(category.rawValue) \(offset + 1)/\(cases.count)] \(testCase.id): \(summary)")
                } catch {
                    errored += 1
                    calls = []
                    onProgress("  [\(category.rawValue) \(offset + 1)/\(cases.count)] \(testCase.id): ERROR \(error) — recorded empty")
                }

                let entry = BFCLResponseEntry(id: testCase.id, calls: calls)
                entries.append(entry)
                onEntry(entry)
            }
        }

        return GenerateResult(entries: entries, attempted: attempted, errored: errored)
    }
}
