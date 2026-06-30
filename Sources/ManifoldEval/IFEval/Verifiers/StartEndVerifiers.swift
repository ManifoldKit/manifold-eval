import Foundation

// MARK: - Starts with

/// Verifies a response starts with a given phrase.
///
/// Used as a helper; the IFEval dataset does not have a `startend:start_checker`
/// instruction, but `startend:end_checker` and `startend:quotation` share this
/// pattern.
public struct StartsWithVerifier: IFEvalVerifier {
    public let instructionID = "startend:start_checker"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard let phrase = kwargs["start_phrase"]?.stringValue else { return false }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix(phrase.lowercased())
    }
}

// MARK: - Ends with

/// Verifies `startend:end_checker`.
///
/// The response must end with `end_phrase` (case-insensitive, trailing
/// whitespace stripped).
public struct EndsWithVerifier: IFEvalVerifier {
    public let instructionID = "startend:end_checker"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard let phrase = kwargs["end_phrase"]?.stringValue else { return false }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasSuffix(phrase.lowercased())
    }
}

// MARK: - No comma

/// Verifies `punctuation:no_comma`.
///
/// The response must contain no comma characters (`,`).
public struct NoCommaVerifier: IFEvalVerifier {
    public let instructionID = "punctuation:no_comma"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        !response.contains(",")
    }
}

// MARK: - Quoted wrap

/// Verifies `startend:quotation`.
///
/// The entire response must be wrapped in double quote characters: it must
/// start with `"` and end with `"` (after stripping surrounding whitespace).
public struct QuotedWrapVerifier: IFEvalVerifier {
    public let instructionID = "startend:quotation"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2
    }
}
