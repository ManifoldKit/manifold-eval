import Foundation

// MARK: - Full-corpus response generation

/// Backend-agnostic, bounded-concurrency generation loop shared by
/// `manifold-eval ifeval-generate`.
///
/// This is the mirror image of ``IFEvalLane/cliRun(corpusURL:responsesURL:modelName:)``:
/// where `cliRun` reads pre-computed ``IFEvalResponseEntry`` values and scores
/// them, ``IFEvalLane/generateResponses(cases:completedKeys:concurrency:onProgress:onEntry:emit:)``
/// *produces* them by driving `emit` over every case not already present in
/// `completedKeys`. Both sides read/write the identical `IFEvalResponseEntry`
/// schema, so a generate run and a later score run never drift out of sync.
///
/// IFEval cases are plain single-turn text generations with no shared mutable
/// state between cases (unlike a tool-calling eval, where cases can share a
/// tool registry / backend session) — so this fans out up to `concurrency`
/// cases at once. The 541-case full IFEval corpus at up to two minutes/case
/// would otherwise take hours run serially.
public extension IFEvalLane {

    /// Aggregate outcome of a generation run.
    struct GenerateResult: Sendable {
        /// One entry per attempted case (cases already in `completedKeys` are
        /// excluded, not re-attempted). Order is NOT guaranteed to match corpus
        /// order — cases complete out of order under concurrent fan-out; write
        /// order should be treated as arrival order, not corpus order.
        public let entries: [IFEvalResponseEntry]
        /// Total cases attempted this run (already-completed cases excluded).
        public let attempted: Int
        /// Cases whose `emit` threw (timeout, backend error). These still get
        /// an entry — with an EMPTY response — so `attempted == entries.count`.
        public let errored: Int

        public init(entries: [IFEvalResponseEntry], attempted: Int, errored: Int) {
            self.entries = entries
            self.attempted = attempted
            self.errored = errored
        }
    }

    /// Drives every case in `cases` NOT already present in `completedKeys`
    /// through `emit`, bounded to at most `concurrency` cases in flight at
    /// once, and returns one ``IFEvalResponseEntry`` per attempted case.
    ///
    /// A case whose `emit` throws (timeout, backend error) is recorded in
    /// ``GenerateResult/entries`` with an EMPTY response and counted in
    /// ``GenerateResult/errored`` — it does NOT abort the run; a single
    /// non-terminating generation must not stall a full-corpus run.
    ///
    /// - Parameters:
    ///   - cases: the full loaded IFEval corpus (typically `IFEvalCorpus.load(from:)`).
    ///   - completedKeys: keys to skip — the resumability seam. Pass the set of
    ///     keys already present in a prior `--out` file (via
    ///     ``IFEvalLane/loadResponses(from:)``) so a relaunch after a crash or
    ///     Ctrl-C converges instead of re-generating everything.
    ///   - concurrency: max cases in flight at once. Bounded to
    ///     `max(1, min(concurrency, remaining.count))` worker tasks, each
    ///     pulling the next case from a shared cursor as it finishes its
    ///     current one (work-stealing, not fixed batches) so a slow case
    ///     doesn't stall an otherwise-idle worker.
    ///   - onProgress: sink for human-readable progress lines. The CLI wires
    ///     this to stderr so a long-running full-corpus generation is
    ///     observable rather than a silent black box.
    ///   - onEntry: called once per attempted case, as soon as its result is
    ///     known, with whether that case errored. `async` because entries
    ///     arrive concurrently from multiple workers — the CLI's
    ///     implementation serializes disk writes through an actor here, so
    ///     concurrent completions never interleave/corrupt the output file.
    ///     **The `isError` flag matters for resumability**: the CLI does NOT
    ///     persist an errored case's empty-response entry to `--out` — if it
    ///     did, that key would be permanently "present" in the file and a
    ///     later resume run (which skips keys already in `--out`) would never
    ///     retry a transient timeout/network error. Omitting it instead means
    ///     the key is simply absent, which `ifeval`'s scorer already treats as
    ///     "score against empty string" (the same verdict), while leaving the
    ///     case eligible for automatic retry on the next invocation.
    ///   - emit: async closure that returns the model's response text for a
    ///     given case. The `Int` is a stable worker-slot index in
    ///     `0..<workerCount`, letting a live caller bind one backend instance
    ///     per slot (avoiding contention on a single backend's FIFO queue). A
    ///     synthetic closure in tests can simply ignore it.
    static func generateResponses(
        cases: [IFEvalCase],
        completedKeys: Set<String> = [],
        concurrency: Int = 6,
        onProgress: @escaping @Sendable (String) -> Void = { _ in },
        onEntry: @escaping @Sendable (_ entry: IFEvalResponseEntry, _ isError: Bool) async -> Void = { _, _ in },
        emit: @escaping @Sendable (_ workerSlot: Int, _ testCase: IFEvalCase) async throws -> String
    ) async -> GenerateResult {
        let remaining = cases.filter { !completedKeys.contains($0.key) }
        guard !remaining.isEmpty else {
            onProgress(
                "ifeval-generate: nothing to do — all \(cases.count) case(s) already present in --out"
            )
            return GenerateResult(entries: [], attempted: 0, errored: 0)
        }

        let workerCount = max(1, min(concurrency, remaining.count))
        onProgress(
            "ifeval-generate: \(remaining.count) case(s) remaining "
            + "(\(cases.count - remaining.count) already done), \(workerCount) worker(s)"
        )

        // Work-stealing cursor: each worker pulls the next unclaimed case as
        // soon as it finishes its current one, rather than fixed batches — so
        // one slow case only stalls its own worker, not the whole run.
        actor Cursor {
            private var next = 0
            private let items: [IFEvalCase]
            init(items: [IFEvalCase]) { self.items = items }
            func take() -> (Int, IFEvalCase)? {
                guard next < items.count else { return nil }
                let index = next
                next += 1
                return (index, items[index])
            }
        }
        let cursor = Cursor(items: remaining)

        // Accumulates entries/errors from concurrently-completing workers.
        actor Collector {
            private(set) var entries: [IFEvalResponseEntry] = []
            private(set) var errored = 0
            func record(_ entry: IFEvalResponseEntry, isError: Bool) {
                entries.append(entry)
                if isError { errored += 1 }
            }
        }
        let collector = Collector()

        await withTaskGroup(of: Void.self) { group in
            for slot in 0..<workerCount {
                group.addTask {
                    while let (index, testCase) = await cursor.take() {
                        let entry: IFEvalResponseEntry
                        var isError = false
                        do {
                            let response = try await emit(slot, testCase)
                            entry = IFEvalResponseEntry(key: testCase.key, response: response)
                            onProgress(
                                "  [\(index + 1)/\(remaining.count)] \(testCase.key): "
                                + "ok (\(response.count) chars)"
                            )
                        } catch {
                            isError = true
                            entry = IFEvalResponseEntry(key: testCase.key, response: "")
                            onProgress(
                                "  [\(index + 1)/\(remaining.count)] \(testCase.key): "
                                + "ERROR \(error) — not persisted, eligible for retry on next run"
                            )
                        }
                        await collector.record(entry, isError: isError)
                        await onEntry(entry, isError)
                    }
                }
            }
        }

        let entries = await collector.entries
        let errored = await collector.errored
        return GenerateResult(entries: entries, attempted: remaining.count, errored: errored)
    }
}
