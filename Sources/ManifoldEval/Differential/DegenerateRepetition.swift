import Foundation

/// Detects the "same repeating unit, different repeat count" shape of output
/// pair — a stopping-length artifact, not a content difference.
///
/// Proven overnight (2026-06-30): the same Qwen3-0.6B GGUF, same prompt tokens,
/// both legs internally deterministic, produced the *exact same* repeating line
/// (`" The answer is in French.\n"`) on Ollama and llama.cpp — Ollama repeated it
/// 8 times, llama.cpp 3 times, before each backend's own stopping criterion
/// fired. `DivergenceTriage` reported that as `genuineDivergence`, its single
/// "worth a human" alarm, lumped in with real model/output differences. This
/// type is the pure, total detector the triage cascade consults to split that
/// bucket: same repeating content at different lengths is a distinct, less
/// alarming signal than two backends producing genuinely different content.
public enum DegenerateRepetition {

    /// The shortest unit (as a substring) that `text` is entirely built from by
    /// repetition — i.e. `text[i] == text[i % period]` for every index, for the
    /// smallest `period` that repeats at least twice within `text`. The final
    /// repeat may be a partial prefix of the unit (a generation cut short
    /// mid-unit by a token/length cap still counts as periodic).
    ///
    /// Returns `nil` when `text` has no such structure — a normal, non-repeating
    /// completion — or is too short to exhibit two repeats.
    ///
    /// - Parameter maxUnitLength: caps the candidate period length searched, so
    ///   this stays cheap on long outputs. A unit longer than this is not
    ///   considered "degenerate repetition" (it would read as legitimate
    ///   structured content, not a stuck decoding loop).
    static func repeatingUnit(of text: String, maxUnitLength: Int = 200) -> String? {
        let chars = Array(text)
        guard chars.count > 1 else { return nil }
        let maxPeriod = min(maxUnitLength, chars.count / 2)
        guard maxPeriod >= 1 else { return nil }

        for period in 1...maxPeriod {
            if isFullyPeriodic(chars, period: period) {
                return String(chars[0..<period])
            }
        }
        return nil
    }

    private static func isFullyPeriodic(_ chars: [Character], period: Int) -> Bool {
        guard period < chars.count else { return false }
        for i in period..<chars.count where chars[i] != chars[i % period] {
            return false
        }
        return true
    }

    /// Whether two *differing* outputs are each a degenerate repetition of the
    /// exact same unit — i.e. they differ only in how many times the identical
    /// repeating content was emitted before each backend stopped, not in what
    /// was said.
    ///
    /// Both `a` and `b` must independently reduce to a repeating unit, and that
    /// unit must match verbatim across both — a deliberately strict, exact
    /// comparison so a real content difference is never masked as a stopping-
    /// length artifact. Callers are expected to have already established
    /// `a != b` (this only refines *why* they differ, it does not itself gate on
    /// equality).
    public static func isRepetitionLengthMismatch(_ a: String, _ b: String) -> Bool {
        guard let unitA = repeatingUnit(of: a), let unitB = repeatingUnit(of: b) else { return false }
        return unitA == unitB
    }
}
