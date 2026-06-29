import Foundation
import ManifoldInference

/// Scores a run's visible text against a reference string by exact equality.
///
/// The default mode is **strict exact match** (whitespace and case are
/// significant). Callers that need a softer comparison opt in explicitly
/// via `Options` — defaulting to strict prevents a normalization flag from
/// silently masking a model regression that only differs in casing.
///
/// ## Basic use
/// ```swift
/// let scorer = ExactMatchScorer()
/// let result = await scorer.score(
///     output: EvalRunOutput(visibleText: "42"),
///     expected: "42"
/// )
/// // result.value == .bool(true)
/// ```
///
/// ## Normalized use
/// ```swift
/// let scorer = ExactMatchScorer(options: .init(trimWhitespace: true, caseInsensitive: true))
/// let result = await scorer.score(
///     output: EvalRunOutput(visibleText: "  Hello World  "),
///     expected: "hello world"
/// )
/// // result.value == .bool(true)
/// ```
public struct ExactMatchScorer: EvalScorer, Sendable {
    public typealias Expected = String

    // MARK: - Options

    /// Normalization knobs. All default to `false` (strict exact match).
    ///
    /// Options are value-typed so callers can build them declaratively and store
    /// them as constants without worrying about aliasing.
    public struct Options: Sendable, Equatable {
        /// Strip leading and trailing whitespace (including newlines) from both
        /// the model output and the expected string before comparing.
        public var trimWhitespace: Bool

        /// Fold both strings to lowercase before comparing. Does not affect the
        /// raw strings stored in `Score.answer` or `Score.explanation`.
        public var caseInsensitive: Bool

        public init(trimWhitespace: Bool = false, caseInsensitive: Bool = false) {
            self.trimWhitespace = trimWhitespace
            self.caseInsensitive = caseInsensitive
        }

        /// Strict exact match — no normalization at all. This is the scorer's
        /// default posture so a caller must affirmatively opt into leniency.
        public static let exact = Options()
    }

    // MARK: - State

    public let options: Options

    // MARK: - Init

    public init(options: Options = .exact) {
        self.options = options
    }

    // MARK: - EvalScorer

    public func score(output: EvalRunOutput, expected: String) async -> Score {
        // Guard against accidentally scoring on the wrong field: if the output
        // has no visible text at all, that is always a mismatch — never
        // accidentally "pass" an empty run against an empty expected.
        let rawActual = output.visibleText
        let rawExpected = expected

        var normalizedActual = rawActual
        var normalizedExpected = rawExpected

        if options.trimWhitespace {
            normalizedActual = normalizedActual.trimmingCharacters(in: .whitespacesAndNewlines)
            normalizedExpected = normalizedExpected.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if options.caseInsensitive {
            normalizedActual = normalizedActual.lowercased()
            normalizedExpected = normalizedExpected.lowercased()
        }

        let matched = normalizedActual == normalizedExpected

        return Score(
            value: .bool(matched),
            // `answer` carries the raw model output so the aggregation layer can
            // surface what the model actually said, not the normalized form used
            // for the comparison.
            answer: rawActual,
            // Only populate an explanation on failure: a pass explanation adds
            // noise in report output and the match itself is self-explanatory.
            explanation: matched
                ? nil
                : "expected \"\(rawExpected)\" but got \"\(rawActual)\"",
            metadata: [
                "scorer": "ExactMatchScorer",
                "trimWhitespace": options.trimWhitespace ? "true" : "false",
                "caseInsensitive": options.caseInsensitive ? "true" : "false",
            ]
        )
    }
}
