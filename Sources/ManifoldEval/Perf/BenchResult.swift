import Foundation

/// Thrown by ``BenchResult/validate(_:expectedTimedRuns:)`` — the perf twin
/// of leet-llm P044's `ProfilingError.unexpectedSampleCount`: a per-run
/// sample array whose length doesn't match the spec's `timed_runs` means a
/// lane silently dropped (or duplicated) a measured run somewhere in the
/// driver, and a median computed over the wrong sample count is worse than
/// no number at all.
public enum BenchResultValidationError: Error, CustomStringConvertible, Equatable {
    case sampleCountMismatch(field: String, expected: Int, actual: Int)

    public var description: String {
        switch self {
        case let .sampleCountMismatch(field, expected, actual):
            return "\(field) expected \(expected) sample(s) (timed_runs); received \(actual)"
        }
    }
}

/// One lane's measured outcome for a ``BenchSpec`` run — the perf twin of
/// `ManifoldTools.ConformanceRecord`. It is a *separate* type, not a reuse of
/// `ConformanceRecord`: that schema's fields (scenario, decoyLevel, verdict,
/// toolSelection) are tool-calling-conformance-shaped and don't carry a
/// latency/throughput measurement at all. What IS reused from the
/// `ConformanceRecord`/`Collator`/`MatrixRenderer` precedent is the
/// *architecture*: a comparability-guard collator plus a diagnostics-banner
/// renderer (see ``PerfCollator`` and ``PerfMatrixReport``).
public struct BenchResult: Codable, Sendable, Equatable {

    /// Schema version of this record's on-disk/wire shape. Bump whenever a
    /// field is added, removed, or changes meaning, so a published corpus of
    /// JSON records (see `--json-out`) can be read back knowing which shape
    /// produced it, instead of guessing from field presence. Records
    /// produced before this field existed decode as version `1` (the
    /// original shape) via ``init(from:)``'s `decodeIfPresent` fallback.
    public let schemaVersion: Int

    /// The current schema version — every ``BenchResult`` this harness
    /// constructs carries this value unless a caller overrides it (tests
    /// only; production code should never need to).
    public static let currentSchemaVersion = 1

    /// The spec lane name this result measures, e.g. `"ollama"`, `"omlx"`.
    public let lane: String
    public let transport: BenchSpec.Transport
    /// Engine identity, e.g. `"ollama"`, `"mlx"` — distinct from `lane` (the
    /// spec's own label for the endpoint) so a report can group by engine
    /// even when a spec names its lanes something else.
    public let engine: String
    public let model: String
    public let quant: String

    /// Time-to-first-token, one entry per timed run (warmup excluded), in
    /// milliseconds. Wall-clock from request-send to the first streamed token.
    public let ttftMsPerRun: [Double]
    /// Tokens-per-second, one entry per timed run. `tokens / total_wall_seconds`
    /// — prefill INCLUDED in the denominator, matching the in-process Swift
    /// benches' definition this harness replaces (so historical numbers stay
    /// comparable; see PR description).
    public let tpsPerRun: [Double]
    /// Output token count per timed run (as reported by the server, or a
    /// client-side count when the wire format doesn't report one).
    public let tokensPerRun: [Int]

    public let medianTtftMs: Double
    public let medianTps: Double
    /// 90th/99th percentile TTFT and TPS across the timed-run samples —
    /// median alone hides tail behavior a publication-grade number needs to
    /// show (a lane with a fast median but a long p99 tail is a materially
    /// different result from one with both tight). Computed via
    /// ``percentile(_:_:)`` (nearest-rank), same sample arrays as the median.
    public let p90TtftMs: Double
    public let p99TtftMs: Double
    public let p90Tps: Double
    public let p99Tps: Double

    /// ``BenchSpec/specHash`` of the spec this result was produced from — the
    /// load-bearing field the collator's hard guard checks before comparing
    /// any two results.
    public let specHash: String
    public let hardware: HardwareSnapshot

    /// Whether this lane ran serialized (no other lane concurrently active).
    /// GPU contention between concurrently-running lanes corrupts throughput
    /// numbers, so the runner always sets this `true` — carried on the record
    /// itself (rather than trusted only at runner call-sites) so a report
    /// reader — or a future record produced by a different driver — can see
    /// the guarantee held, not just assume it did.
    public let runAlone: Bool

    /// Best-effort engine/server version string (e.g. Ollama's `/api/version`
    /// response), fetched once per lane outside the timed measurement window.
    /// `nil` when the transport exposes no reliable version endpoint (generic
    /// OpenAI-compatible servers don't standardize one) or the probe failed —
    /// this is provenance, not a load-bearing measurement, so a probe failure
    /// must never fail the bench run itself.
    public let engineVersion: String?
    /// Best-effort model weights digest, when the transport exposes one
    /// (Ollama's `/api/tags` entries carry a content digest). `nil` for
    /// transports with no equivalent, or on probe failure.
    public let modelDigest: String?

    public init(
        lane: String,
        transport: BenchSpec.Transport,
        engine: String,
        model: String,
        quant: String,
        ttftMsPerRun: [Double],
        tpsPerRun: [Double],
        tokensPerRun: [Int],
        specHash: String,
        hardware: HardwareSnapshot,
        runAlone: Bool,
        schemaVersion: Int = BenchResult.currentSchemaVersion,
        engineVersion: String? = nil,
        modelDigest: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.lane = lane
        self.transport = transport
        self.engine = engine
        self.model = model
        self.quant = quant
        self.ttftMsPerRun = ttftMsPerRun
        self.tpsPerRun = tpsPerRun
        self.tokensPerRun = tokensPerRun
        self.medianTtftMs = Self.median(ttftMsPerRun)
        self.medianTps = Self.median(tpsPerRun)
        self.p90TtftMs = Self.percentile(ttftMsPerRun, 0.90)
        self.p99TtftMs = Self.percentile(ttftMsPerRun, 0.99)
        self.p90Tps = Self.percentile(tpsPerRun, 0.90)
        self.p99Tps = Self.percentile(tpsPerRun, 0.99)
        self.specHash = specHash
        self.hardware = hardware
        self.runAlone = runAlone
        self.engineVersion = engineVersion
        self.modelDigest = modelDigest
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, lane, transport, engine, model, quant
        case ttftMsPerRun, tpsPerRun, tokensPerRun
        case medianTtftMs, medianTps, p90TtftMs, p99TtftMs, p90Tps, p99Tps
        case specHash, hardware, runAlone, engineVersion, modelDigest
    }

    /// Custom `Decodable` conformance so a record written before
    /// `schemaVersion` existed (or before the percentile fields existed)
    /// still decodes: `schemaVersion` defaults to `1`, and the percentiles
    /// fall back to recomputing from the per-run sample arrays rather than
    /// failing to decode entirely.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        lane = try container.decode(String.self, forKey: .lane)
        transport = try container.decode(BenchSpec.Transport.self, forKey: .transport)
        engine = try container.decode(String.self, forKey: .engine)
        model = try container.decode(String.self, forKey: .model)
        quant = try container.decode(String.self, forKey: .quant)
        ttftMsPerRun = try container.decode([Double].self, forKey: .ttftMsPerRun)
        tpsPerRun = try container.decode([Double].self, forKey: .tpsPerRun)
        tokensPerRun = try container.decode([Int].self, forKey: .tokensPerRun)
        medianTtftMs = try container.decodeIfPresent(Double.self, forKey: .medianTtftMs)
            ?? Self.median(ttftMsPerRun)
        medianTps = try container.decodeIfPresent(Double.self, forKey: .medianTps)
            ?? Self.median(tpsPerRun)
        p90TtftMs = try container.decodeIfPresent(Double.self, forKey: .p90TtftMs)
            ?? Self.percentile(ttftMsPerRun, 0.90)
        p99TtftMs = try container.decodeIfPresent(Double.self, forKey: .p99TtftMs)
            ?? Self.percentile(ttftMsPerRun, 0.99)
        p90Tps = try container.decodeIfPresent(Double.self, forKey: .p90Tps)
            ?? Self.percentile(tpsPerRun, 0.90)
        p99Tps = try container.decodeIfPresent(Double.self, forKey: .p99Tps)
            ?? Self.percentile(tpsPerRun, 0.99)
        specHash = try container.decode(String.self, forKey: .specHash)
        hardware = try container.decode(HardwareSnapshot.self, forKey: .hardware)
        runAlone = try container.decode(Bool.self, forKey: .runAlone)
        engineVersion = try container.decodeIfPresent(String.self, forKey: .engineVersion)
        modelDigest = try container.decodeIfPresent(String.self, forKey: .modelDigest)
    }

    /// Checks that every per-run sample array on `result` carries exactly
    /// `expectedTimedRuns` entries (the spec's `protocol.timed_runs`).
    /// `PerfRunner` calls this on every result it produces before returning
    /// it — mirrors `P044ProfilingContract.validate(report, for: request)`:
    /// a completed measurement is checked against the request that shaped
    /// it, rather than trusted just because it typechecks.
    public static func validate(_ result: BenchResult, expectedTimedRuns: Int) throws {
        let fields: [(name: String, count: Int)] = [
            ("ttft_ms_per_run", result.ttftMsPerRun.count),
            ("tps_per_run", result.tpsPerRun.count),
            ("tokens_per_run", result.tokensPerRun.count),
        ]
        for field in fields where field.count != expectedTimedRuns {
            throw BenchResultValidationError.sampleCountMismatch(
                field: field.name, expected: expectedTimedRuns, actual: field.count)
        }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Nearest-rank percentile: sorts `values` and picks the element at
    /// `ceil(fraction * n)` (clamped into range). Simple and deterministic —
    /// no interpolation — which matches this harness's "advisory, directional
    /// number" posture (see `PerfMatrixReport`'s caveats section) rather than
    /// claiming statistical precision the small timed-run sample sizes (often
    /// single-digit `timed_runs`) can't actually support.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        let index = min(max(rank - 1, 0), sorted.count - 1)
        return sorted[index]
    }
}
