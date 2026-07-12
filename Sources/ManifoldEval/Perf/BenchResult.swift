import Foundation

/// One lane's measured outcome for a ``BenchSpec`` run — the perf twin of
/// `ManifoldTools.ConformanceRecord`. It is a *separate* type, not a reuse of
/// `ConformanceRecord`: that schema's fields (scenario, decoyLevel, verdict,
/// toolSelection) are tool-calling-conformance-shaped and don't carry a
/// latency/throughput measurement at all. What IS reused from the
/// `ConformanceRecord`/`Collator`/`MatrixRenderer` precedent is the
/// *architecture*: a comparability-guard collator plus a diagnostics-banner
/// renderer (see ``PerfCollator`` and ``PerfMatrixReport``).
public struct BenchResult: Codable, Sendable, Equatable {

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
        runAlone: Bool
    ) {
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
        self.specHash = specHash
        self.hardware = hardware
        self.runAlone = runAlone
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
}
