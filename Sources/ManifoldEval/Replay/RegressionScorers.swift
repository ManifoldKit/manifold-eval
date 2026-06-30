import Foundation

/// Production ``RegressionScorer`` conformances for the `regress` subcommand.
///
/// Both carry a reference answer and score a model output in `[0, 1]` against
/// it. They are deliberately simple and deterministic — the regression moat
/// detects whether a *score moved* across a re-quant, so the scorer only has to
/// be stable and honest, not sophisticated. A richer scorer (BFCL AST, semantic
/// similarity) can conform to ``RegressionScorer`` the same way when needed.

/// Scores `1.0` when the output equals `expected` after normalisation, else `0.0`.
///
/// Normalisation (both sides): optional surrounding-whitespace trim and optional
/// case-fold. Exact-match is the right scorer for short-answer / closed-form
/// tasks where any drift is a real movement.
public struct ExactMatchRegressionScorer: RegressionScorer {

    public let expected: String
    public let caseSensitive: Bool
    public let trimWhitespace: Bool

    public init(expected: String, caseSensitive: Bool = true, trimWhitespace: Bool = true) {
        self.expected = expected
        self.caseSensitive = caseSensitive
        self.trimWhitespace = trimWhitespace
    }

    public func score(_ output: String) throws -> Double? {
        normalise(output) == normalise(expected) ? 1.0 : 0.0
    }

    private func normalise(_ s: String) -> String {
        var v = s
        if trimWhitespace { v = v.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Locale-independent fold: a locale-aware lowercase can map differently
        // across the user's region (the Turkish-i trap), which would make the
        // score non-reproducible across machines — exactly what an assurance
        // scorer must avoid.
        if !caseSensitive { v = v.lowercased() }
        return v
    }
}

/// Scores `1.0` when the output contains `expected` as a substring, else `0.0`.
///
/// A lenient screening scorer for free-form generations where the reference
/// answer should *appear* somewhere (e.g. the digit "4" in a "2 + 2 =" probe)
/// without requiring an exact match. Use exact-match for closed-form tasks.
public struct SubstringRegressionScorer: RegressionScorer {

    public let expected: String
    public let caseSensitive: Bool

    public init(expected: String, caseSensitive: Bool = true) {
        self.expected = expected
        self.caseSensitive = caseSensitive
    }

    public func score(_ output: String) throws -> Double? {
        if caseSensitive {
            return output.contains(expected) ? 1.0 : 0.0
        }
        return output.lowercased().contains(expected.lowercased()) ? 1.0 : 0.0
    }
}
