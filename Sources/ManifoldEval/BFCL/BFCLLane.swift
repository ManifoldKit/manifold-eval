import Foundation
import ManifoldInference
import ManifoldTools

/// Full-corpus BFCL AST-track evaluation lane.
///
/// Covers the five AST-track categories: `simple`, `multiple`, `parallel`,
/// `parallel_multiple`, and `irrelevance`. The first four use
/// ``ASTMatcher/scoreCase(emittedCalls:groundTruth:)`` (reused from
/// `ManifoldTools` — not re-implemented); `parallel` / `parallel_multiple` use
/// ``ASTMatcher/match(call:against:)`` per pair with injective matching (all
/// ground-truth calls must be satisfied); irrelevance checks that no tool call
/// was emitted.
///
/// ## Corpus sources
/// - ``CorpusSource/localDirectory(_:)``: a directory that contains
///   `<category>_questions.jsonl` and `<category>_answers.jsonl` files. Use
///   from tests by pointing at `Bundle.module`'s resource directory.
/// - ``CorpusSource/gorilla(cacheDir:)``: downloads the Gorilla BFCL v4 corpus
///   from GitHub via ``BFCLCorpusFetcher`` and caches locally. This is the full
///   production corpus path; gate it behind a live-network environment flag when
///   running in CI.
///
/// ## Live use
/// Wire the lane to a real backend via ``BFCLRunner/emittedCalls(for:service:timeoutSeconds:)``:
/// ```swift
/// let lane = BFCLLane()
/// let runner = BFCLRunner()
/// let result = await lane.run(
///     corpusSource: .gorilla(cacheDir: cacheURL),
///     emit: { testCase in
///         try await BFCLRunner.emittedCalls(for: testCase, service: service, timeoutSeconds: 120)
///     }
/// )
/// ```
public struct BFCLLane: Sendable {

    // MARK: - Corpus source

    /// How the lane resolves question / answer corpus files.
    public enum CorpusSource: Sendable {
        /// A local directory containing JSONL fixture files.
        ///
        /// For each ``BFCLCategory``, the lane constructs:
        /// - `directory/<category.rawValue>_questions.jsonl`
        /// - `directory/<category.rawValue>_answers.jsonl`  (skipped for irrelevance)
        case localDirectory(URL)

        /// Downloads the Gorilla BFCL v4 corpus from GitHub, caching in `cacheDir`.
        ///
        /// Categories that fail to download are marked ``CategoryResult/skipped``.
        case gorilla(cacheDir: URL)
    }

    // MARK: - Result types

    /// Per-category scoring result.
    public struct CategoryResult: Sendable {
        /// The category that was scored.
        public let category: BFCLCategory
        /// Number of cases loaded from the corpus.
        public let total: Int
        /// Number of cases scored as correct.
        public let passed: Int
        /// True when the corpus files could not be loaded (e.g. network failure).
        public let skipped: Bool
        /// Human-readable reason when ``skipped`` is true.
        public let skipReason: String?

        public var accuracy: Double {
            total > 0 ? Double(passed) / Double(total) : 0
        }

        public init(
            category: BFCLCategory,
            total: Int,
            passed: Int,
            skipped: Bool = false,
            skipReason: String? = nil
        ) {
            self.category = category
            self.total = total
            self.passed = passed
            self.skipped = skipped
            self.skipReason = skipReason
        }
    }

    /// Full-lane result across all scored categories.
    public struct LaneResult: Sendable {
        /// Per-category results in the order the categories were scored.
        public let categoryResults: [CategoryResult]
        /// True when the corpus was sourced from the Gorilla download path.
        /// False = scaffolded fixture corpus.
        public let fullCorpusSourced: Bool

        /// Total cases across non-skipped categories.
        public var overallTotal: Int {
            categoryResults.filter { !$0.skipped }.reduce(0) { $0 + $1.total }
        }

        /// Total passed cases across non-skipped categories.
        public var overallPassed: Int {
            categoryResults.filter { !$0.skipped }.reduce(0) { $0 + $1.passed }
        }

        /// Aggregate accuracy across non-skipped categories.
        public var overallAccuracy: Double {
            overallTotal > 0 ? Double(overallPassed) / Double(overallTotal) : 0
        }

        public init(categoryResults: [CategoryResult], fullCorpusSourced: Bool) {
            self.categoryResults = categoryResults
            self.fullCorpusSourced = fullCorpusSourced
        }
    }

    // MARK: - Init

    public init() {}

    // MARK: - Run

    /// Runs the BFCL AST-track lane for the given categories.
    ///
    /// Each case is scored using the category's ``BFCLCategory/semantics``:
    /// - `disjunction` (simple / multiple): ``ASTMatcher/scoreCase`` — pass if any
    ///   emitted call matches any ground-truth alternative.
    /// - `conjunction` (parallel / parallel_multiple): injective match via
    ///   ``ASTMatcher/match(call:against:)`` — pass if every ground-truth call has
    ///   a distinct matching emitted call.
    /// - `noCallExpected` (irrelevance): pass if no tool call was emitted.
    ///
    /// A case that errors (the `emit` closure throws) is counted as failed, not
    /// skipped, matching ``BFCLRunner``'s policy.
    ///
    /// - Parameters:
    ///   - categories: which categories to score (default: all five AST-track categories).
    ///   - corpusSource: how to resolve question/answer files.
    ///   - emit: async closure that returns the tool calls a model emitted for a
    ///     given case. Suitable for both live runs (call `BFCLRunner.emittedCalls`)
    ///     and unit tests (return a synthetic list).
    /// - Returns: per-category and aggregate results.
    public func run(
        categories: [BFCLCategory] = BFCLCategory.allCases,
        corpusSource: CorpusSource,
        emit: @Sendable (BFCLLoadedCase) async throws -> [ToolCall]
    ) async -> LaneResult {
        let isFullCorpus: Bool
        switch corpusSource {
        case .localDirectory: isFullCorpus = false
        case .gorilla: isFullCorpus = true
        }

        var results: [CategoryResult] = []
        for category in categories {
            let result = await scoreCategory(category, source: corpusSource, emit: emit)
            results.append(result)
        }

        return LaneResult(categoryResults: results, fullCorpusSourced: isFullCorpus)
    }

    // MARK: - Private: category-level scoring

    private func scoreCategory(
        _ category: BFCLCategory,
        source: CorpusSource,
        emit: @Sendable (BFCLLoadedCase) async throws -> [ToolCall]
    ) async -> CategoryResult {
        let cases: [BFCLLoadedCase]
        do {
            cases = try await loadCases(category: category, source: source)
        } catch {
            return CategoryResult(
                category: category, total: 0, passed: 0,
                skipped: true, skipReason: "\(error)"
            )
        }

        var passed = 0
        for bfclCase in cases {
            let emittedCalls: [ToolCall]
            do {
                emittedCalls = try await emit(bfclCase)
            } catch {
                // Count errored cases as failed (mirrors BFCLRunner policy).
                continue
            }

            if scoreCase(emittedCalls: emittedCalls, groundTruth: bfclCase.groundTruth, semantics: category.semantics) {
                passed += 1
            }
        }

        return CategoryResult(category: category, total: cases.count, passed: passed)
    }

    // MARK: - Private: case-level scoring (reuses ASTMatcher)

    private func scoreCase(
        emittedCalls: [ToolCall],
        groundTruth: [BFCLExpectedCall],
        semantics: BFCLCategory.ScoringSemantics
    ) -> Bool {
        switch semantics {
        case .noCallExpected:
            return emittedCalls.isEmpty

        case .disjunction:
            // Delegate to ManifoldTools' ASTMatcher.scoreCase — do NOT re-implement.
            return ASTMatcher.scoreCase(emittedCalls: emittedCalls, groundTruth: groundTruth).matched

        case .conjunction:
            // parallel / parallel_multiple: every ground-truth call must be matched
            // by a distinct emitted call. Use ASTMatcher.match per pair — still
            // the ManifoldTools matcher, not a fork.
            return injectiveMatch(emittedCalls: emittedCalls, groundTruth: groundTruth)
        }
    }

    /// Greedy injective matching: finds an injective mapping from ground-truth
    /// calls to emitted calls such that every ground-truth call has a distinct
    /// match. Returns true iff such a mapping exists.
    ///
    /// Uses ``ASTMatcher/match(call:against:)`` as the per-pair predicate — the
    /// matching logic is not re-implemented here.
    private func injectiveMatch(
        emittedCalls: [ToolCall],
        groundTruth: [BFCLExpectedCall]
    ) -> Bool {
        guard !groundTruth.isEmpty else { return true }
        guard emittedCalls.count >= groundTruth.count else { return false }

        var usedIndices = Set<Int>()
        for expected in groundTruth {
            guard let matchIdx = emittedCalls.indices.first(where: { idx in
                !usedIndices.contains(idx) &&
                ASTMatcher.match(call: emittedCalls[idx], against: expected).matched
            }) else {
                return false
            }
            usedIndices.insert(matchIdx)
        }
        return true
    }

    // MARK: - Private: corpus loading

    private func loadCases(
        category: BFCLCategory,
        source: CorpusSource
    ) async throws -> [BFCLLoadedCase] {
        switch source {
        case .localDirectory(let dir):
            return try loadFromDirectory(category: category, directory: dir)

        case .gorilla(let cacheDir):
            let (questionsURL, answersURL) = try await BFCLCorpusFetcher.fetch(
                category: category, cacheDir: cacheDir
            )
            return try loadFromFiles(
                category: category,
                questionsURL: questionsURL,
                answersURL: answersURL
            )
        }
    }

    private func loadFromDirectory(
        category: BFCLCategory,
        directory: URL
    ) throws -> [BFCLLoadedCase] {
        let questionsURL = directory
            .appendingPathComponent("\(category.rawValue)_questions.jsonl")
        let answersURL: URL?
        if let stem = category.localAnswersStem {
            answersURL = directory.appendingPathComponent("\(stem).jsonl")
        } else {
            answersURL = nil
        }
        return try loadFromFiles(
            category: category,
            questionsURL: questionsURL,
            answersURL: answersURL
        )
    }

    private func loadFromFiles(
        category: BFCLCategory,
        questionsURL: URL,
        answersURL: URL?
    ) throws -> [BFCLLoadedCase] {
        if category.hasGroundTruth {
            guard let answersURL else {
                throw BFCLCaseLoader.LoadError.resourceMissing(
                    "\(category.rawValue) answers file"
                )
            }
            return try BFCLCaseLoader.load(
                questionsFile: questionsURL,
                answersFile: answersURL
            )
        } else {
            return try loadIrrelevanceCases(questionsURL: questionsURL)
        }
    }

    /// Loads irrelevance questions without a ground-truth file.
    ///
    /// `BFCLCaseLoader.load(questionsFile:answersFile:)` requires an answers file.
    /// Irrelevance has none — the ground truth is the absence of tool calls, not a
    /// specific call. So we decode the questions ourselves and build ``BFCLLoadedCase``
    /// values with an empty ``BFCLLoadedCase/groundTruth``.
    ///
    /// Note: `BFCLQuestionRecord` and `BFCLFunctionSchema` are `internal` to
    /// `ManifoldTools`, so this file mirrors only the wire-format decoding needed
    /// here. The matching code (``ASTMatcher``) is still the ManifoldTools type.
    private func loadIrrelevanceCases(questionsURL: URL) throws -> [BFCLLoadedCase] {
        let data: Data
        do {
            data = try Data(contentsOf: questionsURL)
        } catch {
            throw BFCLCaseLoader.LoadError.fileUnreadable(questionsURL, underlying: error)
        }

        let text = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()
        var cases: [BFCLLoadedCase] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }

            let record = try decoder.decode(IrrelevanceQuestionRecord.self, from: lineData)
            let tools = record.function.map { $0.toToolDefinition() }
            let prompt = record.flattenedPrompt()

            cases.append(BFCLLoadedCase(
                id: record.id,
                prompt: prompt,
                tools: tools,
                groundTruth: []   // irrelevance: no expected call
            ))
        }
        return cases.sorted { $0.id < $1.id }
    }
}

// MARK: - Irrelevance wire models

/// Minimal wire-format decoder for BFCL question records used by the
/// irrelevance loader. `BFCLQuestionRecord` in ManifoldTools carries the same
/// shape but is `internal`; this mirrors only what ``BFCLLane`` needs.
private struct IrrelevanceQuestionRecord: Decodable {
    let id: String
    let question: [[Turn]]
    let function: [FunctionRecord]

    struct Turn: Decodable {
        let role: String
        let content: String
    }

    func flattenedPrompt() -> String {
        let turns = question.flatMap { $0 }
        let userContent = turns.filter { $0.role == "user" }.map(\.content)
        let chosen = userContent.isEmpty ? turns.map(\.content) : userContent
        return chosen.joined(separator: "\n")
    }
}

/// Wire-format function schema decoder. Mirrors `BFCLFunctionSchema` from
/// ManifoldTools (internal) for the irrelevance question-loader path.
private struct FunctionRecord: Decodable {
    let name: String
    let description: String
    let parameters: JSONSchemaValue

    func toToolDefinition() -> ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            parameters: normalizeDictType(parameters)
        )
    }

    /// Rewrites `{"type":"dict"}` → `{"type":"object"}` recursively.
    /// BFCL uses Python vocabulary; backends expect standard JSON-Schema.
    private func normalizeDictType(_ value: JSONSchemaValue) -> JSONSchemaValue {
        switch value {
        case .object(let dict):
            var rewritten: [String: JSONSchemaValue] = [:]
            for (key, child) in dict {
                if key == "type", case .string("dict") = child {
                    rewritten[key] = .string("object")
                } else {
                    rewritten[key] = normalizeDictType(child)
                }
            }
            return .object(rewritten)
        case .array(let items):
            return .array(items.map(normalizeDictType))
        default:
            return value
        }
    }
}
