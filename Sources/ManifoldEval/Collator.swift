import Foundation
import ManifoldTools

/// A non-fatal observation about a collated record set. Surfaced rather than
/// swallowed so a cross-runtime comparison is never silently trusted across an
/// environment boundary it isn't valid over.
public struct CollationDiagnostic: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
        case warning
        case error
    }

    public let severity: Severity
    public let message: String

    public init(severity: Severity, message: String) {
        self.severity = severity
        self.message = message
    }
}

/// The merged record corpus plus the diagnostics gathered while folding the
/// separate-process legs together.
public struct CollationResult: Sendable, Equatable {
    public let records: [ConformanceRecord]
    public let diagnostics: [CollationDiagnostic]

    public init(records: [ConformanceRecord], diagnostics: [CollationDiagnostic]) {
        self.records = records
        self.diagnostics = diagnostics
    }

    /// Distinct backend families present, sorted for deterministic output.
    public var backends: [String] { Set(records.map(\.backend)).sorted() }

    /// Distinct ManifoldKit core commits the records were built from, sorted.
    public var coreCommits: [String] { Set(records.map(\.coreCommit)).sorted() }

    public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
}

/// Failures that abort collation outright — distinct from the recoverable
/// `CollationDiagnostic`s. We throw (rather than skip) on a missing or malformed
/// input so a dropped leg can never read as "measured nothing".
public enum CollationError: Error, CustomStringConvertible, Equatable {
    case noInput
    case unreadable(path: String, reason: String)
    case undecodable(path: String, reason: String)

    public var description: String {
        switch self {
        case .noInput:
            return "no record files provided to collate"
        case .unreadable(let path, let reason):
            return "cannot read record file \(path): \(reason)"
        case .undecodable(let path, let reason):
            return "cannot decode \(path) as a ConformanceRecord array: \(reason)"
        }
    }
}

/// Folds the `ConformanceRecord` JSON arrays emitted by the separate-process eval
/// legs (Ollama / llama.cpp / MLX / cloud) into one corpus for the cross-runtime
/// matrix.
///
/// The value this adds over the bash `cat *.json | manifold-tools matrix` step it
/// replaces is the **comparability guard**: records are only comparable across the
/// same ManifoldKit core binary (the `coreCommit` field's own contract — eval
/// drivers share the core binary), and an environment drift must not read as a
/// regression. A mixed-commit or drifted-tooling set is flagged, not silently
/// merged.
public enum Collator {

    /// Collate by reading each file as a `[ConformanceRecord]` JSON array.
    public static func collate(files: [URL]) throws -> CollationResult {
        guard !files.isEmpty else { throw CollationError.noInput }

        var merged: [ConformanceRecord] = []
        let decoder = JSONDecoder()
        for url in files {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw CollationError.unreadable(path: url.path, reason: "\(error)")
            }
            do {
                merged.append(contentsOf: try decoder.decode([ConformanceRecord].self, from: data))
            } catch {
                throw CollationError.undecodable(path: url.path, reason: "\(error)")
            }
        }
        return finalize(merged)
    }

    /// Collate already-loaded JSON array payloads (one per leg). Used by tests and
    /// by callers that have the bytes in hand.
    public static func collate(jsonArrays: [Data]) throws -> CollationResult {
        guard !jsonArrays.isEmpty else { throw CollationError.noInput }

        var merged: [ConformanceRecord] = []
        let decoder = JSONDecoder()
        for (index, data) in jsonArrays.enumerated() {
            do {
                merged.append(contentsOf: try decoder.decode([ConformanceRecord].self, from: data))
            } catch {
                throw CollationError.undecodable(path: "array[\(index)]", reason: "\(error)")
            }
        }
        return finalize(merged)
    }

    // MARK: - Guards

    static func finalize(_ records: [ConformanceRecord]) -> CollationResult {
        guard !records.isEmpty else {
            return CollationResult(
                records: [],
                diagnostics: [.init(severity: .error, message: "collated 0 records — nothing to compare")]
            )
        }

        var diagnostics: [CollationDiagnostic] = []

        // Comparability guard: cross-runtime comparison is only valid within one
        // core binary. A mixed set still renders (the matrix is informative), but
        // the divergence it shows must be treated as suspect — the P2 differential
        // lane will refuse a mixed set outright.
        let commits = Set(records.map(\.coreCommit))
        if commits.count > 1 {
            diagnostics.append(.init(
                severity: .warning,
                message: "records span \(commits.count) ManifoldKit core commits "
                    + "(\(commits.sorted().joined(separator: ", "))) — cross-runtime comparison is "
                    + "only valid within one core binary; treat any divergence as suspect."
            ))
        }

        // Tooling-drift guard: a single backend reporting more than one distinct
        // tooling-version map across the corpus means an environment changed
        // mid-set, which can masquerade as a regression.
        let byBackend = Dictionary(grouping: records, by: \.backend)
        for backend in byBackend.keys.sorted() {
            let versionMaps = Set(byBackend[backend, default: []].map(\.toolingVersions))
            if versionMaps.count > 1 {
                diagnostics.append(.init(
                    severity: .warning,
                    message: "backend '\(backend)' reports \(versionMaps.count) distinct tooling-version "
                        + "sets across the corpus — environment drift may read as a regression."
                ))
            }
        }

        return CollationResult(records: records, diagnostics: diagnostics)
    }
}
