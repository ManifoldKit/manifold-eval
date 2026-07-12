import Foundation

/// Drives a full ``BenchSpec`` end to end: every lane, warmup + timed runs,
/// folded into one ``BenchResult`` per lane.
///
/// **Lanes run strictly sequentially — never concurrently.** GPU contention
/// between two locally-running engines corrupts throughput numbers (a lane
/// measured while another lane is mid-generation reports a TPS that reflects
/// shared-resource contention, not the engine's own steady-state throughput).
/// This is enforced structurally: `runSpec` is a plain `for` loop over lanes
/// with `await` on each lane's full run before starting the next, not a
/// `TaskGroup` — there is no concurrency to opt out of. Every emitted
/// ``BenchResult/runAlone`` is `true` for exactly that reason.
public enum PerfRunner {

    /// Runs every lane in `spec` and returns one ``BenchResult`` per lane, in
    /// spec order. Throws on the first lane failure — a partial perf matrix
    /// with a silently-dropped lane is exactly the "hole reads as measured"
    /// defect the conformance-record schema (and this harness) exist to avoid;
    /// callers that want partial results on failure should catch per-lane.
    public static func runSpec(
        _ spec: BenchSpec,
        driver: PerfHTTPDriver = PerfHTTPDriver(),
        hardware: HardwareSnapshot = .current(),
        onProgress: (String) -> Void = { _ in }
    ) async throws -> [BenchResult] {
        var results: [BenchResult] = []
        for lane in spec.lanes {
            onProgress("perf: running lane '\(lane.name)' (\(lane.transport.rawValue))")
            let result = try await runLane(lane, spec: spec, driver: driver, hardware: hardware, onProgress: onProgress)
            results.append(result)
        }
        return results
    }

    /// Runs one lane: `protocol.warmup_runs` discarded runs, then
    /// `protocol.timed_runs` measured runs, folded into a ``BenchResult``.
    static func runLane(
        _ lane: BenchSpec.Lane,
        spec: BenchSpec,
        driver: PerfHTTPDriver,
        hardware: HardwareSnapshot,
        onProgress: (String) -> Void = { _ in }
    ) async throws -> BenchResult {
        let protocolConfig = spec.protocolConfig

        for warmupIndex in 0..<max(0, protocolConfig.warmupRuns) {
            onProgress("perf: lane '\(lane.name)' warmup \(warmupIndex + 1)/\(protocolConfig.warmupRuns) (discarded)")
            _ = try await driver.run(lane: lane, protocolConfig: protocolConfig)
        }

        var ttft: [Double] = []
        var tps: [Double] = []
        var tokens: [Int] = []
        for timedIndex in 0..<max(0, protocolConfig.timedRuns) {
            onProgress("perf: lane '\(lane.name)' timed run \(timedIndex + 1)/\(protocolConfig.timedRuns)")
            let measurement = try await driver.run(lane: lane, protocolConfig: protocolConfig)
            ttft.append(measurement.ttftMs)
            tps.append(measurement.tps)
            tokens.append(measurement.tokens)
        }

        return BenchResult(
            lane: lane.name,
            transport: lane.transport,
            engine: engineName(for: lane.transport),
            model: lane.model,
            quant: lane.quant,
            ttftMsPerRun: ttft,
            tpsPerRun: tps,
            tokensPerRun: tokens,
            specHash: spec.specHash,
            hardware: hardware,
            runAlone: true
        )
    }

    /// Best-effort engine label from the transport — a spec's lane `name` is
    /// free text, so this gives the report a stable grouping dimension
    /// independent of naming convention.
    private static func engineName(for transport: BenchSpec.Transport) -> String {
        switch transport {
        case .httpOllama: return "ollama"
        case .httpOpenAI: return "openai-compatible"
        default: return transport.rawValue
        }
    }
}
