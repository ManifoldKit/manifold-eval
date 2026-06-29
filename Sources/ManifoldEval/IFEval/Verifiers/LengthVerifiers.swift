import Foundation

// MARK: - Relation helpers

/// Evaluates a count against a relational constraint.
///
/// Supported relation strings match the IFEval dataset: `"at least"`,
/// `"at most"`, `"exactly"`, `"less than"`, `"more than"`, `"around"`.
/// `"around"` passes when the count is within 10 % (or 5 words, whichever is
/// larger) of the target — mirroring the IFEval reference implementation.
func relationHolds(_ count: Int, _ relation: String, _ target: Int) -> Bool {
    switch relation.lowercased() {
    case "at least": return count >= target
    case "at most": return count <= target
    case "exactly": return count == target
    case "less than": return count < target
    case "more than": return count > target
    case "around":
        // Use Int() (floor toward zero), matching Python int() semantics —
        // not Swift's .rounded() which rounds to nearest.
        let tolerance = max(5, Int(Double(target) * 0.1))
        return abs(count - target) <= tolerance
    default: return false
    }
}

// MARK: - Word count

/// Verifies `length_constraints:number_words`.
///
/// Counts tokens separated by any whitespace (spaces, newlines, tabs), matching
/// Python `str.split()` which splits on all whitespace. `relation` must be one
/// of the standard IFEval relation strings (e.g. `"at least"`, `"around"`).
public struct WordCountVerifier: IFEvalVerifier {
    public let instructionID = "length_constraints:number_words"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard
            let relation = kwargs["relation"]?.stringValue,
            let target = kwargs["num_words"]?.intValue
        else { return false }
        // Split on all whitespace (spaces, newlines, tabs) to match Python
        // str.split() — omitEmptySubsequences is true by default, so leading /
        // trailing / consecutive whitespace does not produce empty tokens.
        let count = response.split(whereSeparator: \.isWhitespace).count
        return relationHolds(count, relation, target)
    }
}

// MARK: - Sentence count

/// Verifies `length_constraints:number_sentences`.
///
/// Splits on sentence-terminal punctuation (`.`, `?`, `!`) followed by
/// whitespace and an uppercase letter, or by optional whitespace at end of
/// string. This avoids false splits inside abbreviations (e.g. "U.S.A.") and
/// decimal numbers (e.g. "3.5"), matching the IFEval reference intent.
public struct SentenceCountVerifier: IFEvalVerifier {
    public let instructionID = "length_constraints:number_sentences"

    public init() {}

    /// Compiled once at load time; never recompiled per-call.
    private static let terminalPunctRegex: NSRegularExpression = {
        do {
            // Matches a sentence-terminal character followed by either:
            //   • whitespace + uppercase letter (a new sentence starts), OR
            //   • optional whitespace + end-of-string (final sentence).
            return try NSRegularExpression(pattern: #"[.?!](?=\s+[A-Z]|\s*$)"#)
        } catch {
            fatalError("invalid static regex: \(error)")
        }
    }()

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard
            let relation = kwargs["relation"]?.stringValue,
            let target = kwargs["num_sentences"]?.intValue
        else { return false }
        let count = sentenceCount(response)
        return relationHolds(count, relation, target)
    }

    private func sentenceCount(_ text: String) -> Int {
        // Splitting on the terminal punctuation position (not the following
        // whitespace) keeps punctuation with each sentence segment.
        let parts = text.components(separatedBy: SentenceCountVerifier.terminalPunctRegex)
        return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }
}

// MARK: - Paragraph count

/// Verifies `length_constraints:number_paragraphs`.
///
/// Paragraphs are separated by one or more blank lines (two or more consecutive
/// newlines). An exact count is required (`num_paragraphs` kwarg; no relation).
public struct ParagraphCountVerifier: IFEvalVerifier {
    public let instructionID = "length_constraints:number_paragraphs"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard let target = kwargs["num_paragraphs"]?.intValue else { return false }
        let count = paragraphCount(response)
        return count == target
    }

    /// Compiled once at load time; never recompiled per-call.
    private static let paragraphSeparatorRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: "\n{2,}")
        } catch {
            fatalError("invalid static regex: \(error)")
        }
    }()

    static func paragraphs(in text: String) -> [String] {
        // Split on two or more consecutive newlines.
        let parts = text.components(separatedBy: ParagraphCountVerifier.paragraphSeparatorRegex)
        return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func paragraphCount(_ text: String) -> Int {
        ParagraphCountVerifier.paragraphs(in: text).count
    }
}

// MARK: - Nth paragraph first word

/// Verifies `length_constraints:nth_paragraph_first_word`.
///
/// The `nth_paragraph`-th paragraph (1-based) must begin with `first_word`
/// (case-insensitive). The response must have at least `num_paragraphs`
/// paragraphs total.
public struct NthParagraphFirstWordVerifier: IFEvalVerifier {
    public let instructionID = "length_constraints:nth_paragraph_first_word"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard
            let firstWord = kwargs["first_word"]?.stringValue,
            let nth = kwargs["nth_paragraph"]?.intValue,
            let totalRequired = kwargs["num_paragraphs"]?.intValue
        else { return false }

        let paras = ParagraphCountVerifier.paragraphs(in: response)
        guard paras.count >= totalRequired, nth >= 1, nth <= paras.count else { return false }

        let para = paras[nth - 1]
        let words = para.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = words.first else { return false }

        // Strip leading punctuation before comparing.
        let stripped = first.trimmingCharacters(in: .punctuationCharacters).lowercased()
        return stripped == firstWord.lowercased()
    }
}

// MARK: - NSRegularExpression convenience

private extension String {
    func components(separatedBy regex: NSRegularExpression?) -> [String] {
        guard let regex else { return [self] }
        let nsString = self as NSString
        let range = NSRange(location: 0, length: nsString.length)
        let matches = regex.matches(in: self, range: range)
        var parts: [String] = []
        var lastEnd = 0
        for match in matches {
            parts.append(nsString.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd)))
            lastEnd = match.range.location + match.range.length
        }
        parts.append(nsString.substring(from: lastEnd))
        return parts
    }
}
