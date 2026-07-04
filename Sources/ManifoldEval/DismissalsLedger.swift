import Foundation
import CryptoKit

/// A stable identity for one flagged divergence: which cell it belongs to and a
/// signature over what actually differed.
///
/// This type is intentionally the ONLY coupling surface to a triage command's own
/// schema. `cell` is any caller-supplied stable string (e.g. a
/// `"model|quant|backend|renderer"` join over `ConformanceRecord`'s cell-identity
/// fields) and `signature` is computed by ``DivergenceSignature`` from the
/// divergence class plus the differing bytes. Keeping this generic — rather than
/// depending on `Divergence` or `ConformanceRecord` directly — means the ledger
/// builds and works standalone, with no edge onto any sibling triage command.
public struct DismissedFinding: Sendable, Equatable, Hashable, Codable {
    /// Stable identity of the (model × quant × backend × renderer) cell, or
    /// whatever coordinate scheme the caller's triage surface uses. Opaque to
    /// this module — never parsed, only compared for equality.
    public let cell: String

    /// A stable hash of `(divergenceClass, differingBytes)` — see
    /// ``DivergenceSignature/compute(divergenceClass:differingBytes:)``. If the
    /// underlying divergence changes shape, this changes too, and a dismissal
    /// keyed on the old signature no longer matches: a changed signature is a NEW
    /// signal that must resurface, never silently absorbed into an old verdict.
    public let signature: String

    public init(cell: String, signature: String) {
        self.cell = cell
        self.signature = signature
    }
}

/// Computes the stable divergence-signature a dismissal is keyed against.
public enum DivergenceSignature {
    /// SHA-256 hex of `divergenceClass` + the differing bytes, joined by a byte
    /// that cannot appear in a divergence-class label (`0x00`) so the two
    /// components can never collide into an ambiguous concatenation.
    ///
    /// CryptoKit (a macOS system framework at this repo's v15 floor) mirrors
    /// ``PromptHash`` rather than pulling swift-crypto as a direct dependency.
    public static func compute(divergenceClass: String, differingBytes: Data) -> String {
        var payload = Data(divergenceClass.utf8)
        payload.append(0x00)
        payload.append(differingBytes)
        let digest = SHA256.hash(data: payload)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Convenience overload over a differing-bytes STRING (e.g. a rendered diff
    /// of the two outputs), UTF-8 encoded before hashing.
    public static func compute(divergenceClass: String, differingText: String) -> String {
        compute(divergenceClass: divergenceClass, differingBytes: Data(differingText.utf8))
    }
}

/// One recorded human verdict: a confirmed by-design divergence, suppressed from
/// re-triage until `expiresAt` — the eval-side analog of the improvement
/// pipeline's holds-reverify pattern (a hold suppresses noise for a bounded
/// window, then forces a fresh look).
public struct DismissalEntry: Sendable, Equatable, Codable {
    public let finding: DismissedFinding
    /// Free-text human justification — required so a dismissal always carries a
    /// reason a later reader can audit, never a bare suppression.
    public let reason: String
    public let recordedAt: Date
    public let expiresAt: Date

    public init(finding: DismissedFinding, reason: String, recordedAt: Date, expiresAt: Date) {
        self.finding = finding
        self.reason = reason
        self.recordedAt = recordedAt
        self.expiresAt = expiresAt
    }

    /// Whether this dismissal is still live (suppressing) as of `now`. Expiry is
    /// exclusive of the boundary instant so `now == expiresAt` already reads as
    /// expired — never permanently suppressing on a boundary tie.
    public func isLive(asOf now: Date) -> Bool {
        now < expiresAt
    }
}

/// Failures reading/writing the ledger's JSON store.
public enum DismissalsLedgerError: Error, CustomStringConvertible, Equatable {
    case unreadable(path: String, reason: String)
    case undecodable(path: String, reason: String)
    case unwritable(path: String, reason: String)

    public var description: String {
        switch self {
        case .unreadable(let path, let reason):
            return "cannot read dismissals ledger \(path): \(reason)"
        case .undecodable(let path, let reason):
            return "cannot decode dismissals ledger \(path): \(reason)"
        case .unwritable(let path, let reason):
            return "cannot write dismissals ledger \(path): \(reason)"
        }
    }
}

/// A deterministic JSON-backed store of confirmed by-design divergence
/// dismissals, keyed by `cell + divergence-signature`.
///
/// Generic over the caller's own cell/signature scheme (see
/// ``DismissedFinding``) so this ledger has no dependency on any sibling triage
/// command's schema — it builds and works standalone.
public struct DismissalsLedger: Sendable, Equatable {
    /// Keyed by `finding` for O(1) lookup; kept as a dictionary in memory but
    /// always serialized sorted (by cell, then signature) for a stable, diffable
    /// JSON file — see ``encode()``.
    private var entriesByFinding: [DismissedFinding: DismissalEntry]

    public init(entries: [DismissalEntry] = []) {
        var byFinding: [DismissedFinding: DismissalEntry] = [:]
        for entry in entries {
            byFinding[entry.finding] = entry
        }
        self.entriesByFinding = byFinding
    }

    /// All entries, sorted deterministically (cell, then signature).
    public var entries: [DismissalEntry] {
        entriesByFinding.values.sorted {
            ($0.finding.cell, $0.finding.signature) < ($1.finding.cell, $1.finding.signature)
        }
    }

    public var count: Int { entriesByFinding.count }

    /// Records (or replaces) a dismissal for `finding`. Replacing is intentional:
    /// a human re-dismissing the same exact signature just refreshes the reason
    /// and expiry rather than accumulating duplicate history.
    public mutating func record(_ finding: DismissedFinding, reason: String, recordedAt: Date, ttl: TimeInterval) {
        let entry = DismissalEntry(
            finding: finding,
            reason: reason,
            recordedAt: recordedAt,
            expiresAt: recordedAt.addingTimeInterval(ttl)
        )
        entriesByFinding[finding] = entry
    }

    /// Removes every entry expired as of `now`. Returns the removed entries (for
    /// reporting what was pruned).
    @discardableResult
    public mutating func prune(asOf now: Date) -> [DismissalEntry] {
        var removed: [DismissalEntry] = []
        for (finding, entry) in entriesByFinding where !entry.isLive(asOf: now) {
            removed.append(entry)
            entriesByFinding.removeValue(forKey: finding)
        }
        return removed
    }

    /// Filters `flagged` down to the findings that should still surface for a
    /// human: those with NO dismissal, or a dismissal that has expired.
    /// Non-expired ("live") dismissals are suppressed. A changed divergence
    /// signature for an otherwise-dismissed cell is a DIFFERENT `DismissedFinding`
    /// (different `signature`), so it is never suppressed — new signal always
    /// resurfaces, by construction of the lookup key.
    public func suppress(_ flagged: [DismissedFinding], asOf now: Date) -> [DismissedFinding] {
        flagged.filter { finding in
            guard let entry = entriesByFinding[finding] else { return true }
            return !entry.isLive(asOf: now)
        }
    }

    /// The live (non-expired) dismissal for `finding`, if any.
    public func liveEntry(for finding: DismissedFinding, asOf now: Date) -> DismissalEntry? {
        guard let entry = entriesByFinding[finding], entry.isLive(asOf: now) else { return nil }
        return entry
    }

    // MARK: - Persistence

    /// Deterministic JSON: sorted keys + stable ISO-8601 dates, and entries
    /// written in the same sorted order as ``entries`` — so a re-saved ledger
    /// with no semantic change produces byte-identical output (diffable in a
    /// review, and round-trips stably in tests).
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encodes the ledger to deterministic JSON bytes.
    public func encode() throws -> Data {
        try Self.makeEncoder().encode(entries)
    }

    /// Loads a ledger from `url`. A missing file is treated as an empty ledger
    /// (the natural "no dismissals recorded yet" state) rather than an error —
    /// only a present-but-malformed file is a hard failure.
    public static func load(from url: URL) throws -> DismissalsLedger {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DismissalsLedger()
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DismissalsLedgerError.unreadable(path: url.path, reason: "\(error)")
        }
        do {
            let decoded = try Self.makeDecoder().decode([DismissalEntry].self, from: data)
            return DismissalsLedger(entries: decoded)
        } catch {
            throw DismissalsLedgerError.undecodable(path: url.path, reason: "\(error)")
        }
    }

    /// Writes the ledger to `url` as deterministic JSON.
    public func save(to url: URL) throws {
        let data: Data
        do {
            data = try encode()
        } catch {
            throw DismissalsLedgerError.unwritable(path: url.path, reason: "\(error)")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DismissalsLedgerError.unwritable(path: url.path, reason: "\(error)")
        }
    }
}
