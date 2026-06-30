import Foundation

// MARK: - All lowercase

/// Verifies `change_case:english_lowercase`.
///
/// All alphabetic characters in the response must be lowercase.
/// Punctuation and digits are ignored.
public struct AllLowercaseVerifier: IFEvalVerifier {
    public let instructionID = "change_case:english_lowercase"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        response.filter(\.isLetter).allSatisfy(\.isLowercase)
    }
}

// MARK: - All uppercase

/// Verifies `change_case:english_capital`.
///
/// All alphabetic characters in the response must be uppercase.
public struct AllUppercaseVerifier: IFEvalVerifier {
    public let instructionID = "change_case:english_capital"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        response.filter(\.isLetter).allSatisfy(\.isUppercase)
    }
}

// MARK: - Capital word frequency

/// Verifies `change_case:capital_word_frequency`.
///
/// Counts words (whitespace-separated) that start with an uppercase letter.
/// The count is compared against `capital_frequency` using `capital_relation`.
public struct CapitalWordFrequencyVerifier: IFEvalVerifier {
    public let instructionID = "change_case:capital_word_frequency"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard
            let relation = kwargs["capital_relation"]?.stringValue,
            let target = kwargs["capital_frequency"]?.intValue
        else { return false }

        let words = response.split(whereSeparator: \.isWhitespace)
        let count = words.filter { word in
            guard let first = word.first else { return false }
            return first.isUppercase
        }.count
        return relationHolds(count, relation, target)
    }
}
