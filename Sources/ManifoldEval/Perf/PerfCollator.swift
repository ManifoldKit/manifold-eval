import Foundation

/// Failures that abort perf collation outright.
public enum PerfCollationError: Error, CustomStringConvertible, Equatable {
    case noInput
    /// The hard guard: two or more results in the same collation carry a
    /// different ``BenchSpec/specHash``, meaning they were not measured under
    /// the same model_family + protocol. This is the structural fix for the
    /// exact defect that motivated the harness (three bench targets quietly
    /// comparing different-sized models) — a mismatched set is refused, not
    /// merged-with-a-warning, so a future run can never silently compare
    /// unlike models.
    case specHashMismatch(hashes: [String])

    public var description: String {
        switch self {
        case .noInput:
            return "no bench results provided to collate"
        case .specHashMismatch(let hashes):
            return "results span \(hashes.count) distinct spec hashes (\(hashes.joined(separator: ", "))) "
                + "— collation refused: results must share one model_family + protocol to be comparable"
        }
    }
}

/// The collated result set plus non-fatal diagnostics gathered while folding
/// per-lane results together.
public struct PerfCollationResult: Sendable, Equatable {
    public let results: [BenchResult]
    public let diagnostics: [CollationDiagnostic]

    public init(results: [BenchResult], diagnostics: [CollationDiagnostic]) {
        self.results = results
        self.diagnostics = diagnostics
    }

    /// Distinct quant labels present, sorted for deterministic output.
    public var quantCamps: [String] { Set(results.map(\.quant)).sorted() }

    public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
}

/// Folds per-lane ``BenchResult``s into one comparable corpus for
/// ``PerfMatrixReport``. The perf twin of ``Collator``: same shape (a hard
/// guard plus advisory diagnostics), different comparability axis (spec hash
/// instead of core commit — a perf comparison's validity hinges on "same
/// model, same protocol", not "same ManifoldKit build").
public enum PerfCollator {

    /// Collates already-produced results (in-process — no JSON round-trip
    /// needed since the perf harness runs its lanes in one process).
    public static func collate(_ results: [BenchResult]) throws -> PerfCollationResult {
        guard !results.isEmpty else { throw PerfCollationError.noInput }

        let hashes = Set(results.map(\.specHash))
        guard hashes.count == 1 else {
            throw PerfCollationError.specHashMismatch(hashes: hashes.sorted())
        }

        var diagnostics: [CollationDiagnostic] = []

        // Quant-camp guard: results still render together even when quant
        // labels differ (e.g. Q4_K_M vs 4bit), because the spec-hash guard
        // above already proved they share a model family + protocol — but a
        // reader must not read a cross-camp delta as a bit-identical-weights
        // comparison.
        let camps = Set(results.map(\.quant))
        if camps.count > 1 {
            diagnostics.append(.init(
                severity: .warning,
                message: "results span \(camps.count) quant camps (\(camps.sorted().joined(separator: ", "))) "
                    + "— cross-camp comparison is NOT bit-identical; treat TTFT/TPS deltas as directional, "
                    + "not an exact apples-to-apples measurement."
            ))
        }

        // run_alone guard: a result produced by a driver that didn't serialize
        // lanes has a corrupted throughput number by construction (GPU
        // contention). Surface it loudly rather than silently trust the number.
        let contended = results.filter { !$0.runAlone }
        if !contended.isEmpty {
            diagnostics.append(.init(
                severity: .error,
                message: "\(contended.count) result(s) were NOT run alone (lane: "
                    + "\(contended.map(\.lane).joined(separator: ", "))) — throughput numbers are suspect "
                    + "under concurrent GPU contention and should not be trusted."
            ))
        }

        return PerfCollationResult(results: results, diagnostics: diagnostics)
    }
}
