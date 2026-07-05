import Foundation
import ManifoldTools

/// The cell identity a baseline is keyed on: `(model × quant × backend × renderer)`
/// — the same coordinates `ConformanceRecord` carries, minus the per-scenario axes
/// (`scenario` / `decoyLevel` / `repeatIndex`). A baseline tracks *cell*-level
/// movement, not individual scenario runs, so one row survives across scenario-set
/// churn.
public struct CellKey: Codable, Sendable, Hashable, Comparable {
    public let model: String
    public let quant: String
    public let backend: String
    public let renderer: String

    public init(model: String, quant: String, backend: String, renderer: String) {
        self.model = model
        self.quant = quant
        self.backend = backend
        self.renderer = renderer
    }

    public init(record: ConformanceRecord) {
        self.init(model: record.model, quant: record.quant, backend: record.backend, renderer: record.renderer)
    }

    /// Stable, delimiter-joined string form — used as the on-disk JSON key so the
    /// baseline file diffs cleanly in a PR (a struct key would serialize as a
    /// nested object whose field order is an encoder implementation detail).
    /// `\u{1F}` (unit separator) is used as the delimiter since none of the four
    /// components is expected to contain a control character, and it can never be
    /// confused with a literal token a model/quant/backend/renderer name would use.
    public var stableKey: String {
        [model, quant, backend, renderer].joined(separator: "\u{1F}")
    }

    public static func < (lhs: CellKey, rhs: CellKey) -> Bool {
        (lhs.model, lhs.quant, lhs.backend, lhs.renderer)
            < (rhs.model, rhs.quant, rhs.backend, rhs.renderer)
    }
}

/// One persisted baseline row for a cell: `{score, bytesHash, divergenceClass,
/// timestamp, coreCommit}` per the issue's schema.
public struct BaselineEntry: Codable, Sendable, Equatable {
    /// The cell's aggregate score for this baseline snapshot — the mean per-record
    /// score across every `.measured` record folded into the cell (see
    /// ``CellObservation`` for how it's derived from `ConformanceRecord`).
    public let score: Double

    /// A content hash over the cell's underlying transcript references, so a
    /// byte-exact replay drift is detectable even when the aggregate score didn't
    /// move (two different failure transcripts can average to the same F1).
    public let bytesHash: String

    /// A coarse outcome classification for the cell, e.g. a `ConformanceScorer
    /// .Verdict` rawValue (`"pass"`/`"partial"`/`"fail"`/`"errored"`) when built
    /// from collated conformance records, or a `Divergence` rawValue when built
    /// from a differential run. `nil` when the source data carries no such
    /// classification.
    public let divergenceClass: String?

    /// When this baseline row was recorded.
    public let timestamp: Date

    /// The ManifoldKit core commit the observation was measured against —
    /// mirrors `ConformanceRecord.coreCommit`; comparability is only valid within
    /// one core binary (see `Collator`'s same guard).
    public let coreCommit: String

    public init(score: Double, bytesHash: String, divergenceClass: String?, timestamp: Date, coreCommit: String) {
        self.score = score
        self.bytesHash = bytesHash
        self.divergenceClass = divergenceClass
        self.timestamp = timestamp
        self.coreCommit = coreCommit
    }
}

/// One `(key, entry)` row in the persisted store. A flat, explicitly-sorted array
/// — not a `[String: BaselineEntry]` dictionary — is the on-disk shape: Swift's
/// `JSONEncoder` only guarantees deterministic dictionary key order with
/// `.sortedKeys`, which is an *encoder* setting a future maintainer could drop
/// without noticing; a pre-sorted array's order is a property of the *value*
/// itself, so a re-write always diffs cleanly regardless of how it's encoded.
public struct BaselineRow: Codable, Sendable, Equatable {
    public let key: CellKey
    public let entry: BaselineEntry

    public init(key: CellKey, entry: BaselineEntry) {
        self.key = key
        self.entry = entry
    }
}

/// The persisted per-cell baseline store.
///
/// Serialization is deterministic by construction: rows are always kept sorted by
/// `key` (see `init(rows:)` and ``updated(with:)``), and encoding uses
/// `.sortedKeys` on top of that so a re-write of the *same* logical content always
/// produces byte-identical JSON — the property the issue's "re-writes diff
/// cleanly" requirement asks for.
public struct BaselineStore: Codable, Sendable, Equatable {
    public let rows: [BaselineRow]

    /// Rows are sorted on construction so every caller (including `Codable`
    /// decoding of a hand-edited file) gets the deterministic invariant for free.
    public init(rows: [BaselineRow]) {
        self.rows = rows.sorted { $0.key < $1.key }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode([BaselineRow].self)
        self.init(rows: decoded)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rows)
    }

    public static let empty = BaselineStore(rows: [])

    public var byKey: [CellKey: BaselineEntry] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.entry) })
    }

    /// The newest `timestamp` across every row, or `nil` for an empty store (a
    /// store that has never been written has no staleness signal yet — that is
    /// the caller's call to make, not this type's).
    public var newestTimestamp: Date? {
        rows.map(\.entry.timestamp).max()
    }

    /// Returns a new store with `observations` merged in — replacing any existing
    /// row for a key the current run observed, and leaving every other row
    /// (a cell this run didn't touch) untouched. Partial runs must never
    /// silently erase baseline history for cells outside their scope.
    public func updated(with observations: [CellKey: CellObservation], timestamp: Date) -> BaselineStore {
        var byKey = self.byKey
        for (key, observation) in observations {
            byKey[key] = BaselineEntry(
                score: observation.score,
                bytesHash: observation.bytesHash,
                divergenceClass: observation.divergenceClass,
                timestamp: timestamp,
                coreCommit: observation.coreCommit
            )
        }
        return BaselineStore(rows: byKey.map { BaselineRow(key: $0.key, entry: $0.value) })
    }

    // MARK: - Disk I/O

    public enum LoadError: Error, CustomStringConvertible, Equatable {
        case unreadable(path: String, reason: String)
        case undecodable(path: String, reason: String)
        /// The decoded file contains more than one row for the same `CellKey`.
        /// A baseline file is a trust boundary (hand-edited, or the product of a
        /// merge-conflict concatenation), so this must be a handled rejection —
        /// never a silent de-dupe, and never the `Dictionary(uniqueKeysWithValues:)`
        /// trap `byKey` would otherwise hit.
        case duplicateCellKey(CellKey)
        /// The decoded file's rows span more than one `coreCommit`. A single
        /// baseline file is only meaningful as a snapshot of one core binary —
        /// the direct analog of `Collator`'s (and `BaselineCollector.build`'s)
        /// same guard over a *run's* records, applied here to a *loaded file*'s
        /// own internal consistency.
        case mixedCoreCommits(Set<String>)

        public var description: String {
            switch self {
            case .unreadable(let path, let reason):
                return "cannot read baseline file \(path): \(reason)"
            case .undecodable(let path, let reason):
                return "cannot decode \(path) as a BaselineStore: \(reason)"
            case .duplicateCellKey(let key):
                return "baseline file contains duplicate rows for cell "
                    + "\(key.model) / \(key.quant) / \(key.backend) / \(key.renderer) — "
                    + "a baseline row must be unique per cell"
            case .mixedCoreCommits(let commits):
                return "baseline file spans \(commits.count) ManifoldKit core commits "
                    + "(\(commits.sorted().joined(separator: ", "))) — a single baseline file must "
                    + "come from one core binary; a mixed file is not internally comparable"
            }
        }
    }

    /// Loads a store from `path`, or returns `.empty` if the file doesn't exist
    /// yet (the first `--update` run has nothing to merge against).
    public static func load(path: URL) throws -> BaselineStore {
        guard FileManager.default.fileExists(atPath: path.path) else { return .empty }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw LoadError.unreadable(path: path.path, reason: "\(error)")
        }
        let store: BaselineStore
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            store = try decoder.decode(BaselineStore.self, from: data)
        } catch {
            throw LoadError.undecodable(path: path.path, reason: "\(error)")
        }
        try validate(store)
        return store
    }

    /// Validates a decoded store's internal consistency before it is trusted by
    /// any caller — the boundary that keeps `byKey`'s
    /// `Dictionary(uniqueKeysWithValues:)` from ever seeing a duplicate key, and
    /// keeps a mixed-commit file from being silently compared against.
    private static func validate(_ store: BaselineStore) throws {
        var seen: Set<CellKey> = []
        for row in store.rows {
            guard seen.insert(row.key).inserted else {
                throw LoadError.duplicateCellKey(row.key)
            }
        }

        let commits = Set(store.rows.map(\.entry.coreCommit))
        if commits.count > 1 {
            throw LoadError.mixedCoreCommits(commits)
        }
    }

    public enum SaveError: Error, CustomStringConvertible, Equatable {
        case unwritable(path: String, reason: String)

        public var description: String {
            switch self {
            case .unwritable(let path, let reason):
                return "cannot write baseline file \(path): \(reason)"
            }
        }
    }

    public func save(path: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // .sortedKeys guards against a nested-object encoding drifting on encoder
        // internals; the primary determinism guarantee is the pre-sorted `rows`
        // array from `init(rows:)`.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data: Data
        do {
            data = try encoder.encode(self)
        } catch {
            throw SaveError.unwritable(path: path.path, reason: "\(error)")
        }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: path, options: .atomic)
        } catch {
            throw SaveError.unwritable(path: path.path, reason: "\(error)")
        }
    }
}

/// One cell's aggregate observation for the *current* run — the pre-persisted
/// form of a ``BaselineEntry`` (missing only the `timestamp`, which the store
/// stamps at write time).
public struct CellObservation: Sendable, Equatable {
    public let score: Double
    public let bytesHash: String
    public let divergenceClass: String?
    public let coreCommit: String

    public init(score: Double, bytesHash: String, divergenceClass: String?, coreCommit: String) {
        self.score = score
        self.bytesHash = bytesHash
        self.divergenceClass = divergenceClass
        self.coreCommit = coreCommit
    }
}

/// The result of folding a run's `[ConformanceRecord]` into per-cell
/// observations: the observations themselves (only for cells with at least one
/// `.measured` record — a cell whose every record is `notMeasured`/`loadFail`
/// /`renderFail` has nothing to score, per "absence ≠ failure") plus the full
/// **manifest** of cell keys the run's input actually named (measured or not).
///
/// The manifest/observation split is what makes the rot-guard's shrink check
/// correct: a cell that regressed to `notMeasured` this run is still *in the
/// manifest* (so it is never reported as having "disappeared" / shrunk), it is
/// simply excluded from movement scoring (there is no new score to compare).
/// Only a cell absent from the manifest entirely — never named in the current
/// run's input at all — counts as shrink.
public struct RunManifest: Sendable, Equatable {
    public let observations: [CellKey: CellObservation]
    public let manifestKeys: Set<CellKey>

    public init(observations: [CellKey: CellObservation], manifestKeys: Set<CellKey>) {
        self.observations = observations
        self.manifestKeys = manifestKeys
    }
}

/// Builds per-cell observations from a collated `[ConformanceRecord]` set — the
/// same input shape `collate` consumes, so `baseline` is a `collate`-adjacent
/// subcommand per the issue.
public enum BaselineCollector {

    public enum BuildError: Error, CustomStringConvertible, Equatable {
        /// The current run's own records span more than one `coreCommit` —
        /// rejected outright (not merely a warning), mirroring `Collator`'s
        /// comparability guard: a baseline diff is meaningless if the "current"
        /// side isn't itself from one core binary.
        case mixedCoreCommits(Set<String>)

        public var description: String {
            switch self {
            case .mixedCoreCommits(let commits):
                return "current records span \(commits.count) ManifoldKit core commits "
                    + "(\(commits.sorted().joined(separator: ", "))) — a baseline diff requires "
                    + "the current run to come from a single core binary"
            }
        }
    }

    /// Derives a numeric score for one measured record. `nil` for a non-measured
    /// record — the caller must never let that read as a `0.0` score, which would
    /// masquerade as a real (bad) measurement.
    static func score(for record: ConformanceRecord) -> Double? {
        guard record.status == .measured else { return nil }
        if let f1 = record.toolSelection?.f1 { return f1 }
        switch record.verdict {
        case .pass: return 1.0
        case .partial: return 0.5
        case .fail, .errored: return 0.0
        case nil: return nil
        }
    }

    /// Folds `records` into a ``RunManifest``.
    ///
    /// - Throws: ``BuildError/mixedCoreCommits(_:)`` if the input spans more than
    ///   one core commit.
    public static func build(from records: [ConformanceRecord]) throws -> RunManifest {
        let commits = Set(records.map(\.coreCommit))
        if commits.count > 1 {
            throw BuildError.mixedCoreCommits(commits)
        }

        var manifestKeys: Set<CellKey> = []
        var byKey: [CellKey: [ConformanceRecord]] = [:]
        for record in records {
            let key = CellKey(record: record)
            manifestKeys.insert(key)
            byKey[key, default: []].append(record)
        }

        var observations: [CellKey: CellObservation] = [:]
        for (key, group) in byKey {
            let scored = group.compactMap { record in score(for: record).map { (record, $0) } }
            guard !scored.isEmpty else { continue } // every record in this cell is non-measured

            let meanScore = scored.map(\.1).reduce(0, +) / Double(scored.count)

            // Sorted for determinism — record ordering in the input JSON is not a
            // guaranteed-stable signal, only the transcript refs' content is.
            let transcriptRefs = group.map(\.transcriptRef).sorted()
            let bytesHash = PromptHash.sha256Hex(of: transcriptRefs.joined(separator: "\n"))

            // Cell-level classification: the dominant verdict rawValue among the
            // measured records in this cell (mode; ties broken by rawValue for
            // determinism). `nil` if none carried a verdict.
            let verdictCounts = Dictionary(grouping: scored.map(\.0).compactMap(\.verdict), by: { $0 })
                .mapValues(\.count)
            let divergenceClass = verdictCounts
                .sorted { lhs, rhs in
                    lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key.rawValue < rhs.key.rawValue
                }
                .first?.key.rawValue

            observations[key] = CellObservation(
                score: meanScore,
                bytesHash: bytesHash,
                divergenceClass: divergenceClass,
                coreCommit: commits.first ?? "unknown"
            )
        }

        return RunManifest(observations: observations, manifestKeys: manifestKeys)
    }
}
