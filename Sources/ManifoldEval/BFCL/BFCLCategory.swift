import Foundation

/// The BFCL AST-track categories supported by ``BFCLLane``.
///
/// simple / multiple / parallel / parallel_multiple all carry both question and
/// answer files; their correctness is measured by ``ASTMatcher/scoreCase``.
/// irrelevance carries questions only; correctness = no tool call emitted.
public enum BFCLCategory: String, CaseIterable, Sendable {
    case simple
    case multiple
    case parallel
    case parallelMultiple = "parallel_multiple"
    case irrelevance

    /// Whether this category has a ground-truth answer file.
    /// Categories without one are scored by absence of tool calls.
    public var hasGroundTruth: Bool {
        switch self {
        case .simple, .multiple, .parallel, .parallelMultiple: return true
        case .irrelevance: return false
        }
    }

    /// The scoring semantics for this category.
    ///
    /// `simple` and `multiple` use disjunction: a case passes when any emitted
    /// call matches any ground-truth alternative. `parallel` and
    /// `parallel_multiple` use conjunction: a case passes when every ground-truth
    /// call has a matching emitted call (one-to-one).
    public var semantics: ScoringSemantics {
        switch self {
        case .simple, .multiple: return .disjunction
        case .parallel, .parallelMultiple: return .conjunction
        case .irrelevance: return .noCallExpected
        }
    }

    public enum ScoringSemantics: Sendable {
        /// Any one emitted call matching any one ground-truth alternative → pass.
        case disjunction
        /// Every ground-truth call must be matched by a distinct emitted call → pass.
        case conjunction
        /// No tool calls should be emitted → pass.
        case noCallExpected
    }

    /// The question-file stem used for the ``BFCLLane/CorpusSource/localDirectory(_:)``
    /// source. E.g. `parallel_multiple` → `parallel_multiple_questions.jsonl`.
    public var localQuestionsStem: String { rawValue + "_questions" }

    /// The answers-file stem for the local source (nil for irrelevance).
    public var localAnswersStem: String? { hasGroundTruth ? rawValue + "_answers" : nil }

    /// Gorilla BFCL v4 questions-file stem, used by ``BFCLCorpusFetcher``.
    public var gorillaQuestionsStem: String {
        switch self {
        case .simple: return "BFCL_v4_simple_python"
        case .multiple: return "BFCL_v4_multiple"
        case .parallel: return "BFCL_v4_parallel"
        case .parallelMultiple: return "BFCL_v4_parallel_multiple"
        case .irrelevance: return "BFCL_v4_irrelevance"
        }
    }

    /// Gorilla BFCL v4 answers-file stem (nil for irrelevance, which has no
    /// possible_answer file in the Gorilla corpus).
    ///
    /// - Note: Gorilla v4 stores answers in `possible_answer/<stem>.json` — same
    ///   stem as questions, different directory. The identical stem is intentional;
    ///   ``BFCLCorpusFetcher`` handles the directory difference.
    public var gorillaAnswersStem: String? { hasGroundTruth ? gorillaQuestionsStem : nil }

    // MARK: - CLI category-list parsing

    /// Thrown by ``parseList(_:)`` when a `--category` token doesn't match any
    /// ``BFCLCategory`` raw value (and isn't the `all` keyword).
    public enum ParseError: Error, CustomStringConvertible, Sendable, Equatable {
        case unknownCategory(String)

        public var description: String {
            switch self {
            case .unknownCategory(let name):
                let known = BFCLCategory.allCases.map(\.rawValue).joined(separator: ", ")
                return "unknown BFCL category '\(name)' (expected one of: \(known), or 'all')"
            }
        }
    }

    /// Parses a `--category` CLI value into the categories it selects.
    ///
    /// Accepts a single category (`"multiple"`), a comma-separated list
    /// (`"simple,multiple"`), or the literal `"all"` (case-insensitive), which
    /// expands to ``allCases``. Whitespace around tokens is trimmed. An unknown
    /// token throws ``ParseError/unknownCategory(_:)`` rather than silently
    /// dropping it — a typo'd category name must fail loudly, not quietly score
    /// zero cases.
    public static func parseList(_ raw: String) throws -> [BFCLCategory] {
        let tokens = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if tokens.count == 1, tokens[0].lowercased() == "all" {
            return BFCLCategory.allCases
        }

        return try tokens.map { token in
            guard let category = BFCLCategory(rawValue: token) else {
                throw ParseError.unknownCategory(token)
            }
            return category
        }
    }
}
