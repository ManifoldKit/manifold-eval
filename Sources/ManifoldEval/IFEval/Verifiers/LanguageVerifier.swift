import Foundation
import NaturalLanguage

/// Verifies `language:response_language`.
///
/// Uses `NLLanguageRecognizer` (available macOS 10.14+; the package floor is
/// macOS 15, so this is always available) to identify the dominant language of
/// the response and compare it against the expected BCP-47 code.
///
/// For non-Latin scripts (Arabic, Devanagari, CJK, Cyrillic, Thai, etc.) a
/// Unicode-script fraction check is applied first as a fast path; NL recognizer
/// is the fallback for Latin-script languages and for any code not in the
/// fast-path map.
public struct ResponseLanguageVerifier: IFEvalVerifier {
    public let instructionID = "language:response_language"

    public init() {}

    public func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool {
        guard let language = kwargs["language"]?.stringValue else { return false }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Fast path: non-Latin scripts have distinctive Unicode blocks.
        if let block = scriptBlock(for: language) {
            let scalars = trimmed.unicodeScalars.filter { !$0.properties.isWhitespace }
            guard !scalars.isEmpty else { return false }
            let fraction = Double(scalars.filter { block.contains($0.value) }.count) / Double(scalars.count)
            return fraction >= 0.15
        }

        // NLLanguageRecognizer path for Latin-script and other languages.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let dominant = recognizer.dominantLanguage else { return false }
        return dominant.rawValue == language
    }

    // MARK: -

    /// Maps a BCP-47 language code to its primary Unicode scalar block, when
    /// the script is distinctive enough for a fraction check.
    private func scriptBlock(for code: String) -> ClosedRange<UInt32>? {
        switch code.lowercased() {
        case "ar", "fa", "ur": return 0x0600...0x06FF  // Arabic
        case "ru", "bg": return 0x0400...0x04FF         // Cyrillic
        case "hi", "mr", "ne": return 0x0900...0x097F   // Devanagari
        case "bn": return 0x0980...0x09FF               // Bengali
        case "pa": return 0x0A00...0x0A7F               // Gurmukhi
        case "gu": return 0x0A80...0x0AFF               // Gujarati
        case "ta": return 0x0B80...0x0BFF               // Tamil
        case "te": return 0x0C00...0x0C7F               // Telugu
        case "kn": return 0x0C80...0x0CFF               // Kannada
        case "th": return 0x0E00...0x0E7F               // Thai
        case "ko": return 0xAC00...0xD7AF               // Hangul
        default: return nil
        }
    }
}
