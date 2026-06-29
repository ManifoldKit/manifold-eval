import Foundation

// MARK: - Keyword inclusion

/// Verifies `keywords:existence`.
///
/// All keywords in the `keywords` list must appear in the response
/// (case-insensitive substring match, matching the IFEval reference).
public struct KeywordInclusionVerifier: IFEvalVerifier {
    public let instructionID = "keywords:existence"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard let keywords = kwargs["keywords"]?.stringArrayValue else { return false }
        let lower = response.lowercased()
        return keywords.allSatisfy { lower.contains($0.lowercased()) }
    }
}

// MARK: - Keyword exclusion

/// Verifies `keywords:forbidden_words`.
///
/// None of the forbidden words may appear in the response (case-insensitive).
public struct KeywordExclusionVerifier: IFEvalVerifier {
    public let instructionID = "keywords:forbidden_words"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard let forbidden = kwargs["forbidden_words"]?.stringArrayValue else { return false }
        let lower = response.lowercased()
        return forbidden.allSatisfy { !lower.contains($0.lowercased()) }
    }
}

// MARK: - Keyword frequency

/// Verifies `keywords:frequency`.
///
/// The keyword must appear with the given relational frequency
/// (case-insensitive occurrences of the exact word token).
public struct KeywordFrequencyVerifier: IFEvalVerifier {
    public let instructionID = "keywords:frequency"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard
            let keyword = kwargs["keyword"]?.stringValue,
            let relation = kwargs["relation"]?.stringValue,
            let target = kwargs["frequency"]?.intValue
        else { return false }

        let count = occurrenceCount(of: keyword.lowercased(), in: response.lowercased())
        return relationHolds(count, relation, target)
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, options: .caseInsensitive, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }
}

// MARK: - Letter frequency

/// Verifies `keywords:letter_frequency`.
///
/// The specified character must appear with the given relational frequency in
/// the response (case-insensitive: both `a` and `A` count for letter `a`).
public struct LetterFrequencyVerifier: IFEvalVerifier {
    public let instructionID = "keywords:letter_frequency"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard
            let letter = kwargs["letter"]?.stringValue,
            let relation = kwargs["let_relation"]?.stringValue,
            let target = kwargs["let_frequency"]?.intValue
        else { return false }

        guard let char = letter.lowercased().first else { return false }
        let count = response.lowercased().filter { $0 == char }.count
        return relationHolds(count, relation, target)
    }
}
