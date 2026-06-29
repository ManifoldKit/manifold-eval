import Foundation

/// How to reconcile the leading-BOS asymmetry when comparing two input-token
/// streams.
///
/// The wrinkle (plan §14.2, verified 2026-06-29): Ollama `raw:true` adds **no**
/// special tokens, while a llama runner tokenises with `addBos: true`. So the same
/// prompt string yields token streams that differ only by a single leading BOS —
/// a false positive for `tokenizerDivergence` unless normalised. The BOS id is
/// **never hardcoded**: `autoDetect` infers it from the one-token length
/// asymmetry, and `explicit` is offered when the id is known (e.g. Llama-3.1's
/// `128000`).
public enum BOSNormalization: Sendable, Equatable {
    /// Compare streams verbatim — any difference (including a leading BOS) counts.
    case none
    /// Strip a single leading token equal to `bosID` from *either* side before
    /// comparing. Safe and unambiguous when the id is known.
    case explicit(bosID: Int)
    /// Infer the BOS from a single-token leading-length asymmetry, without knowing
    /// the id. See ``BOSNormalizer/streamsMatch(_:_:normalization:)`` for the rule
    /// and its false-positive caveat.
    case autoDetect
}

/// Compares two `inputTokenIds` streams modulo a single leading BOS.
public enum BOSNormalizer {

    /// `true` when the two streams are equal once the leading-BOS asymmetry is
    /// accounted for under `normalization`.
    ///
    /// - `none`: exact equality.
    /// - `explicit(bos)`: drop one leading `bos` from each side (if present), then
    ///   compare. This normalises both legs to "no BOS", so it also handles the
    ///   case where *both* sides carry a BOS.
    /// - `autoDetect`: equal streams match; otherwise, iff the lengths differ by
    ///   exactly one and dropping the extra leading token from the longer side
    ///   makes them equal, they match (that extra token is treated as the BOS).
    ///   Caveat: this cannot distinguish a true BOS from a coincidental one-token
    ///   prefix difference — prefer `explicit` when the id is known.
    public static func streamsMatch(
        _ a: [Int],
        _ b: [Int],
        normalization: BOSNormalization
    ) -> Bool {
        switch normalization {
        case .none:
            return a == b
        case .explicit(let bos):
            return strippingLeading(bos, from: a) == strippingLeading(bos, from: b)
        case .autoDetect:
            if a == b { return true }
            guard abs(a.count - b.count) == 1 else { return false }
            let (longer, shorter) = a.count > b.count ? (a, b) : (b, a)
            return Array(longer.dropFirst()) == shorter
        }
    }

    /// The BOS id inferred from a single-token leading-length asymmetry, or `nil`
    /// when the streams don't exhibit that shape. Useful for *reporting* which id
    /// the auto-detect treated as the BOS, so a human can sanity-check it.
    public static func detectBOS(_ a: [Int], _ b: [Int]) -> Int? {
        guard abs(a.count - b.count) == 1 else { return nil }
        let (longer, shorter) = a.count > b.count ? (a, b) : (b, a)
        guard Array(longer.dropFirst()) == shorter, let first = longer.first else { return nil }
        return first
    }

    private static func strippingLeading(_ token: Int, from stream: [Int]) -> [Int] {
        guard stream.first == token else { return stream }
        return Array(stream.dropFirst())
    }
}
