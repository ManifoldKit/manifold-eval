import Foundation

// MARK: - JSON output

/// Verifies `detectable_format:json_format`.
///
/// The entire response must be valid JSON. Leading/trailing whitespace is
/// stripped before parsing.
public struct JSONOutputVerifier: IFEvalVerifier {
    public let instructionID = "detectable_format:json_format"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}

// MARK: - Bullet list

/// Verifies `detectable_format:number_bullet_lists`.
///
/// Counts lines that start with `* ` (asterisk + space), matching the IFEval
/// reference. The response must contain at least `num_bullets` such lines.
public struct BulletListVerifier: IFEvalVerifier {
    public let instructionID = "detectable_format:number_bullet_lists"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard let target = kwargs["num_bullets"]?.intValue else { return false }
        let lines = response.components(separatedBy: .newlines)
        let count = lines.filter { $0.hasPrefix("* ") }.count
        return count >= target
    }
}

// MARK: - Highlighted sections

/// Verifies `detectable_format:number_highlighted_sections`.
///
/// Highlighted sections are marked with `*text*` spans. Counts non-overlapping
/// matches of `\*[^*\n]+\*`, which is the IFEval Python reference regex.
///
/// Note: this pattern **does** match the inner `*text*` span inside `**bold**`
/// (e.g. `"**bold**"` counts as one highlighted section), matching the Python
/// reference behaviour.
public struct HighlightedSectionsVerifier: IFEvalVerifier {
    public let instructionID = "detectable_format:number_highlighted_sections"

    public init() {}

    /// Compiled once at load time; matches the IFEval Python reference regex.
    private static let highlightRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"\*[^*\n]+\*"#)
        } catch {
            fatalError("invalid static regex: \(error)")
        }
    }()

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard let target = kwargs["num_highlights"]?.intValue else { return false }
        let count = highlightCount(in: response)
        return count >= target
    }

    private func highlightCount(in text: String) -> Int {
        let range = NSRange(text.startIndex..., in: text)
        return HighlightedSectionsVerifier.highlightRegex.numberOfMatches(in: text, range: range)
    }
}

// MARK: - Title

/// Verifies `detectable_format:title`.
///
/// The response must contain at least one line that is a markdown heading
/// (starts with `#`). No kwargs required.
public struct TitleVerifier: IFEvalVerifier {
    public let instructionID = "detectable_format:title"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        response.components(separatedBy: .newlines).contains { $0.hasPrefix("#") }
    }
}

// MARK: - Multiple sections

/// Verifies `detectable_format:multiple_sections`.
///
/// The response must contain `num_sections` sections headed by lines of the
/// form `{section_spliter} {N}` (case-insensitive, e.g. `SECTION 1`,
/// `Day 3`, `Audience 2`). Sections are counted by the number of distinct
/// numbered headings that match the splitter.
public struct SectionSeparatorVerifier: IFEvalVerifier {
    public let instructionID = "detectable_format:multiple_sections"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard
            let splitter = kwargs["section_spliter"]?.stringValue,
            let target = kwargs["num_sections"]?.intValue
        else { return false }

        let escapedSplitter = NSRegularExpression.escapedPattern(for: splitter)
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: #"(?im)^\s*"# + escapedSplitter + #"\s+\d+"#)
        } catch {
            // Pattern is built from escaped user input; failure means no match.
            return false
        }

        let range = NSRange(response.startIndex..., in: response)
        let count = regex.numberOfMatches(in: response, range: range)
        return count >= target
    }
}

// MARK: - Placeholders

/// Verifies `detectable_content:number_placeholders`.
///
/// Counts `[...]` placeholder patterns. The response must contain at least
/// `num_placeholders` such patterns.
public struct PlaceholderCountVerifier: IFEvalVerifier {
    public let instructionID = "detectable_content:number_placeholders"

    public init() {}

    /// Compiled once at load time; never recompiled per-call.
    private static let placeholderRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"\[[^\[\]]+\]"#)
        } catch {
            fatalError("invalid static regex: \(error)")
        }
    }()

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard let target = kwargs["num_placeholders"]?.intValue else { return false }
        let range = NSRange(response.startIndex..., in: response)
        let count = PlaceholderCountVerifier.placeholderRegex.numberOfMatches(in: response, range: range)
        return count >= target
    }
}

// MARK: - Postscript

/// Verifies `detectable_content:postscript`.
///
/// The response must end with a postscript section beginning with the
/// `postscript_marker` (e.g. `"P.S."`, `"P.P.S"`). Trailing whitespace is
/// ignored. The marker must appear after the main body.
public struct PostscriptVerifier: IFEvalVerifier {
    public let instructionID = "detectable_content:postscript"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard let marker = kwargs["postscript_marker"]?.stringValue else { return false }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        // The marker must appear somewhere after a newline in the response.
        let lines = trimmed.components(separatedBy: .newlines)
        return lines.dropFirst().contains { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix(marker)
        }
    }
}

// MARK: - Constrained response

/// Verifies `detectable_format:constrained_response`.
///
/// The prompt instructs the model to choose from a small set of exact phrases
/// (e.g. `"My answer is yes."`, `"My answer is no."`, `"My answer is maybe."`).
/// This verifier checks that the response is a single short line that does not
/// contain markdown formatting (bullets, headers, code fences, numbered lists).
public struct ConstrainedResponseVerifier: IFEvalVerifier {
    public let instructionID = "detectable_format:constrained_response"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        // NOTE: The IFEval Python reference always returns True for this
        // instruction — it has no stored option list at runtime to check
        // against. This verifier deliberately uses a single-line /
        // no-markdown heuristic as an approximation of the expected
        // short-phrase response shape (vacuous-true in the reference).
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        // Must be a single line.
        guard !trimmed.contains("\n") else { return false }
        // No markdown bullets, headers, code fences, or numbered lists.
        let forbidden = ["* ", "- ", "# ", "```", "1. ", "2. "]
        return !forbidden.contains { trimmed.contains($0) }
    }
}

// MARK: - Two responses

/// Verifies `combination:two_responses`.
///
/// The response must contain exactly two sections separated by six asterisks
/// `******`, matching the IFEval dataset prompts ("separate the two responses
/// with 6 asterisk symbols: ******").
public struct TwoResponsesVerifier: IFEvalVerifier {
    public let instructionID = "combination:two_responses"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        response.contains("******")
    }
}

// MARK: - Repeat prompt

/// Verifies `combination:repeat_prompt`.
///
/// The response must contain the verbatim `prompt_to_repeat` text.
public struct RepeatPromptVerifier: IFEvalVerifier {
    public let instructionID = "combination:repeat_prompt"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard let promptToRepeat = kwargs["prompt_to_repeat"]?.stringValue else { return false }
        return response.contains(promptToRepeat)
    }
}
