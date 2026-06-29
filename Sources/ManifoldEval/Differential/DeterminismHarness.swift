import Foundation

/// The result of running one backend on one prompt N times at `temperature == 0`:
/// the runs and whether the backend reproduced its own output.
///
/// "Report variance, not means-only" (plan §7 control 2): we keep every run so the
/// caller can see *which* repeat diverged — the warmup/cold-load outlier is real
/// (observed 2026-06-29: Ollama's first request after model load can differ from
/// the steady state), and hiding it behind an average would launder a confound.
public struct DeterminismReport: Sendable, Equatable {
    public let runs: [RawRun]

    public init(runs: [RawRun]) {
        self.runs = runs
    }

    /// The first run, used as the representative for cross-backend comparison.
    public var representative: RawRun? { runs.first }

    public var backend: String? { runs.first?.backend }

    public var repeatCount: Int { runs.count }

    /// Distinct outputs in first-seen order — `count == 1` is a clean
    /// deterministic batch; `> 1` quantifies the variance.
    public var distinctOutputs: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for run in runs where !seen.contains(run.output) {
            seen.insert(run.output)
            ordered.append(run.output)
        }
        return ordered
    }

    /// `true` when every run produced the same output. Vacuously `true` for an
    /// empty or single-run batch — determinism cannot be *observed* with fewer
    /// than two samples, so the caller must run enough repeats (default 3) for
    /// this to carry weight. ``wasAssessed`` distinguishes the two.
    public var isDeterministic: Bool { distinctOutputs.count <= 1 }

    /// `true` once at least two repeats exist, i.e. determinism was actually
    /// observed rather than assumed.
    public var wasAssessed: Bool { runs.count >= 2 }
}

/// Drives a backend N times for a determinism control.
public enum DeterminismHarness {

    /// Run `produce` `repeats` times (0-based repeat index passed in) and collect
    /// the runs into a ``DeterminismReport``.
    ///
    /// Sequential by design — repeats are *not* parallelised: a single backend
    /// (Ollama) must not be hit concurrently, and sequential ordering is what lets
    /// the report surface a cold-load outlier as the first run.
    public static func measure(
        repeats: Int,
        produce: (Int) async throws -> RawRun
    ) async throws -> DeterminismReport {
        guard repeats >= 1 else { throw DifferentialError.invalidRepeats(repeats) }
        var runs: [RawRun] = []
        runs.reserveCapacity(repeats)
        for index in 0..<repeats {
            runs.append(try await produce(index))
        }
        return DeterminismReport(runs: runs)
    }
}
