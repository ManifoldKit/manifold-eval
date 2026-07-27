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
    ///
    /// - `1` — TTFT/TPS/tokens + median/p90/p99 + engineVersion/modelDigest
    /// - `2` — adds native load/prefill/generate split, min/max, cold-start
    public let schemaVersion: Int

    /// The current schema version — every ``BenchResult`` this harness
    /// constructs carries this value unless a caller overrides it (tests
    /// only; production code should never need to).
    public static let currentSchemaVersion = 2

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
    /// comparable; see PR description). Pair with ``generateTpsPerRun`` for
    /// the decode-only split.
    public let tpsPerRun: [Double]
    /// Output token count per timed run (as reported by the server, or a
    /// client-side count when the wire format doesn't report one).
    public let tokensPerRun: [Int]

    /// Per-run model-load duration (ms). Ollama `load_duration`; empty when
    /// the transport never reported a value (OpenAI-compat). When non-empty,
    /// same length as the timed-run arrays (missing per-run values are
    /// omitted only by leaving the whole array empty — partial coverage is
    /// represented with `nil` slots).
    public let loadDurationMsPerRun: [Double?]
    /// Per-run prefill (prompt-processing) tok/s. Ollama native; empty on
    /// OpenAI-compat.
    public let prefillTpsPerRun: [Double?]
    /// Per-run decode/generation tok/s. Ollama native (`eval_*`); derived on
    /// OpenAI-compat as `tokens / (wall − TTFT)`.
    public let generateTpsPerRun: [Double?]

    public let medianTtftMs: Double
    public let medianTps: Double
    public let minTtftMs: Double
    public let maxTtftMs: Double
    public let minTps: Double
    public let maxTps: Double
    /// Median over non-`nil` load-duration samples; `nil` when none reported.
    public let medianLoadDurationMs: Double?
    /// Median over non-`nil` prefill-TPS samples; `nil` when none reported.
    public let medianPrefillTps: Double?
    /// Median over non-`nil` generate-TPS samples; `nil` when none reported.
    public let medianGenerateTps: Double?

    /// 90th/99th percentile TTFT and TPS across the timed-run samples —
    /// median alone hides tail behavior a publication-grade number needs to
    /// show (a lane with a fast median but a long p99 tail is a materially
    /// different result from one with both tight). Computed via
    /// ``percentile(_:_:)`` (nearest-rank: `sorted[ceil(fraction * n) - 1]`,
    /// no interpolation — see that function's doc comment).
    ///
    /// **Publication policy (issue #2335):** report **median + min/max** at
    /// `n < 20`; publish **p90 only at `n ≥ 20`**; never treat p99 as a real
    /// percentile below `n ≥ 100` (nearest-rank makes p99 == max for every
    /// `n < 100`). Check ``percentilesAreDegenerate`` / ``p90Rank`` /
    /// ``p99Rank`` before printing p90/p99 as independent numbers.
    public let p90TtftMs: Double
    public let p99TtftMs: Double
    public let p90Tps: Double
    public let p99Tps: Double
    /// 1-based nearest-rank index into the sorted timed-run samples that
    /// `p90TtftMs`/`p90Tps` resolved to, for this result's sample count.
    /// Exposed on the record — not just derivable by recomputing — so a
    /// report or downstream consumer can tell whether p90/p99 are distinct
    /// samples WITHOUT re-deriving the rank arithmetic itself.
    public let p90Rank: Int
    /// 1-based nearest-rank index `p99TtftMs`/`p99Tps` resolved to.
    public let p99Rank: Int
    /// `true` when `p90Rank == p99Rank` — i.e. the "p99" figure is not a
    /// distinct tail estimate, it is the exact same sample as "p90" (and, for
    /// `n < 100`, also the sample maximum). A consumer/report MUST check this
    /// before printing p90/p99 as if they were two independent measurements;
    /// see the doc comment on `p90TtftMs` for the exact thresholds.
    public var percentilesAreDegenerate: Bool { p90Rank == p99Rank }

    /// Sample count at which p90 is published as a real percentile (not just
    /// a synonym for a near-max sample under nearest-rank).
    public static let p90PublicationMinimumSamples = 20
    /// Sample count at which p99 stops being exactly the sample maximum
    /// under nearest-rank (`ceil(0.99 * n) < n` first holds at n = 100).
    public static let p99PublicationMinimumSamples = 100

    /// Whether this record's sample count is large enough to publish p90
    /// under the #2335 policy.
    public var publishesP90: Bool { ttftMsPerRun.count >= Self.p90PublicationMinimumSamples }
    /// Whether this record's sample count is large enough to publish p99
    /// under the #2335 policy.
    public var publishesP99: Bool { ttftMsPerRun.count >= Self.p99PublicationMinimumSamples }

    /// Cold-start load duration (ms) when ``BenchSpec/GenerationProtocol/measureCold``
    /// ran an unload + one cold measurement; `nil` otherwise.
    public let coldLoadDurationMs: Double?
    public let coldTtftMs: Double?
    public let coldPrefillTps: Double?
    public let coldGenerateTps: Double?

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
        modelDigest: String? = nil,
        loadDurationMsPerRun: [Double?] = [],
        prefillTpsPerRun: [Double?] = [],
        generateTpsPerRun: [Double?] = [],
        coldLoadDurationMs: Double? = nil,
        coldTtftMs: Double? = nil,
        coldPrefillTps: Double? = nil,
        coldGenerateTps: Double? = nil
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
        self.loadDurationMsPerRun = loadDurationMsPerRun
        self.prefillTpsPerRun = prefillTpsPerRun
        self.generateTpsPerRun = generateTpsPerRun
        self.medianTtftMs = Self.median(ttftMsPerRun)
        self.medianTps = Self.median(tpsPerRun)
        self.minTtftMs = ttftMsPerRun.min() ?? 0
        self.maxTtftMs = ttftMsPerRun.max() ?? 0
        self.minTps = tpsPerRun.min() ?? 0
        self.maxTps = tpsPerRun.max() ?? 0
        self.medianLoadDurationMs = Self.medianOfPresent(loadDurationMsPerRun)
        self.medianPrefillTps = Self.medianOfPresent(prefillTpsPerRun)
        self.medianGenerateTps = Self.medianOfPresent(generateTpsPerRun)
        self.p90TtftMs = Self.percentile(ttftMsPerRun, 0.90)
        self.p99TtftMs = Self.percentile(ttftMsPerRun, 0.99)
        self.p90Tps = Self.percentile(tpsPerRun, 0.90)
        self.p99Tps = Self.percentile(tpsPerRun, 0.99)
        // Ranks are derived from ttftMsPerRun's count; tpsPerRun/tokensPerRun
        // are required (via BenchResult.validate) to carry the same count, so
        // one rank pair describes all four percentile fields above.
        self.p90Rank = Self.rank(for: 0.90, count: ttftMsPerRun.count)
        self.p99Rank = Self.rank(for: 0.99, count: ttftMsPerRun.count)
        self.coldLoadDurationMs = coldLoadDurationMs
        self.coldTtftMs = coldTtftMs
        self.coldPrefillTps = coldPrefillTps
        self.coldGenerateTps = coldGenerateTps
        self.specHash = specHash
        self.hardware = hardware
        self.runAlone = runAlone
        self.engineVersion = engineVersion
        self.modelDigest = modelDigest
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, lane, transport, engine, model, quant
        case ttftMsPerRun, tpsPerRun, tokensPerRun
        case loadDurationMsPerRun, prefillTpsPerRun, generateTpsPerRun
        case medianTtftMs, medianTps, minTtftMs, maxTtftMs, minTps, maxTps
        case medianLoadDurationMs, medianPrefillTps, medianGenerateTps
        case p90TtftMs, p99TtftMs, p90Tps, p99Tps, p90Rank, p99Rank
        case coldLoadDurationMs, coldTtftMs, coldPrefillTps, coldGenerateTps
        case specHash, hardware, runAlone, engineVersion, modelDigest
    }

    /// Custom `Decodable` conformance so a record written before
    /// `schemaVersion` existed (or before the percentile/rank/native-split
    /// fields existed) still decodes: `schemaVersion` defaults to `1`, and
    /// derived fields fall back to recomputing from the per-run sample
    /// arrays rather than failing to decode entirely.
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
        loadDurationMsPerRun = try container.decodeIfPresent([Double?].self, forKey: .loadDurationMsPerRun) ?? []
        prefillTpsPerRun = try container.decodeIfPresent([Double?].self, forKey: .prefillTpsPerRun) ?? []
        generateTpsPerRun = try container.decodeIfPresent([Double?].self, forKey: .generateTpsPerRun) ?? []
        medianTtftMs = try container.decodeIfPresent(Double.self, forKey: .medianTtftMs)
            ?? Self.median(ttftMsPerRun)
        medianTps = try container.decodeIfPresent(Double.self, forKey: .medianTps)
            ?? Self.median(tpsPerRun)
        minTtftMs = try container.decodeIfPresent(Double.self, forKey: .minTtftMs)
            ?? (ttftMsPerRun.min() ?? 0)
        maxTtftMs = try container.decodeIfPresent(Double.self, forKey: .maxTtftMs)
            ?? (ttftMsPerRun.max() ?? 0)
        minTps = try container.decodeIfPresent(Double.self, forKey: .minTps)
            ?? (tpsPerRun.min() ?? 0)
        maxTps = try container.decodeIfPresent(Double.self, forKey: .maxTps)
            ?? (tpsPerRun.max() ?? 0)
        medianLoadDurationMs = try container.decodeIfPresent(Double.self, forKey: .medianLoadDurationMs)
            ?? Self.medianOfPresent(loadDurationMsPerRun)
        medianPrefillTps = try container.decodeIfPresent(Double.self, forKey: .medianPrefillTps)
            ?? Self.medianOfPresent(prefillTpsPerRun)
        medianGenerateTps = try container.decodeIfPresent(Double.self, forKey: .medianGenerateTps)
            ?? Self.medianOfPresent(generateTpsPerRun)
        p90TtftMs = try container.decodeIfPresent(Double.self, forKey: .p90TtftMs)
            ?? Self.percentile(ttftMsPerRun, 0.90)
        p99TtftMs = try container.decodeIfPresent(Double.self, forKey: .p99TtftMs)
            ?? Self.percentile(ttftMsPerRun, 0.99)
        p90Tps = try container.decodeIfPresent(Double.self, forKey: .p90Tps)
            ?? Self.percentile(tpsPerRun, 0.90)
        p99Tps = try container.decodeIfPresent(Double.self, forKey: .p99Tps)
            ?? Self.percentile(tpsPerRun, 0.99)
        p90Rank = try container.decodeIfPresent(Int.self, forKey: .p90Rank)
            ?? Self.rank(for: 0.90, count: ttftMsPerRun.count)
        p99Rank = try container.decodeIfPresent(Int.self, forKey: .p99Rank)
            ?? Self.rank(for: 0.99, count: ttftMsPerRun.count)
        coldLoadDurationMs = try container.decodeIfPresent(Double.self, forKey: .coldLoadDurationMs)
        coldTtftMs = try container.decodeIfPresent(Double.self, forKey: .coldTtftMs)
        coldPrefillTps = try container.decodeIfPresent(Double.self, forKey: .coldPrefillTps)
        coldGenerateTps = try container.decodeIfPresent(Double.self, forKey: .coldGenerateTps)
        specHash = try container.decode(String.self, forKey: .specHash)
        hardware = try container.decode(HardwareSnapshot.self, forKey: .hardware)
        runAlone = try container.decode(Bool.self, forKey: .runAlone)
        engineVersion = try container.decodeIfPresent(String.self, forKey: .engineVersion)
        modelDigest = try container.decodeIfPresent(String.self, forKey: .modelDigest)
    }

    /// Checks that every required per-run sample array on `result` carries
    /// exactly `expectedTimedRuns` entries (the spec's `protocol.timed_runs`).
    /// Optional native-split arrays, when non-empty, must match the same
    /// count. `PerfRunner` calls this on every result it produces before
    /// returning it — mirrors `P044ProfilingContract.validate(report, for:
    /// request)`: a completed measurement is checked against the request that
    /// shaped it, rather than trusted just because it typechecks.
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
        let optionalFields: [(name: String, count: Int)] = [
            ("load_duration_ms_per_run", result.loadDurationMsPerRun.count),
            ("prefill_tps_per_run", result.prefillTpsPerRun.count),
            ("generate_tps_per_run", result.generateTpsPerRun.count),
        ]
        for field in optionalFields where field.count != 0 && field.count != expectedTimedRuns {
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

    /// Median of the non-`nil` entries; `nil` when none present.
    static func medianOfPresent(_ values: [Double?]) -> Double? {
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return median(present)
    }

    /// Nearest-rank percentile: sorts `values` and picks the element at
    /// `rank(for:count:)` (1-based, clamped into range). Simple and
    /// deterministic — no interpolation — which matches this harness's
    /// "advisory, directional number" posture (see `PerfMatrixReport`'s
    /// caveats section) rather than claiming statistical precision the
    /// small timed-run sample sizes (often single-digit `timed_runs`) can't
    /// actually support. Deliberately NOT changed to interpolate between
    /// ranks — that would manufacture a value that was never measured, which
    /// is worse than the current honest-but-blunt "duplicate of the nearest
    /// real sample" behavior. See `percentilesAreDegenerate` for how a
    /// consumer is expected to detect and disclose the small-`n` case where
    /// nearest-rank collapses p90/p99 onto the same sample instead.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[Self.rank(for: fraction, count: sorted.count) - 1]
    }

    /// The 1-based nearest-rank index `ceil(fraction * count)` resolves to,
    /// clamped to `[1, count]` (and `0` for an empty sample). Factored out of
    /// `percentile(_:_:)` so `p90Rank`/`p99Rank` can be exposed on the record
    /// without recomputing percentile values or re-sorting — the rank only
    /// depends on the sample COUNT, not the sample values themselves.
    static func rank(for fraction: Double, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let rank = Int((fraction * Double(count)).rounded(.up))
        return min(max(rank, 1), count)
    }
}
