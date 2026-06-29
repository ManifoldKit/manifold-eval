/// The seam between the replay-regression gate and a real re-drive backend.
///
/// A conforming type must replay a captured prompt string under the specified
/// sampler settings and return the raw backend output as a ``RawRun``.
///
/// # Status: scaffold seam — NOT YET WIRED
///
/// No production implementation of this protocol exists yet. Wiring requires:
///
/// 1. **Core extraction** — pull `Replayer.runOnce` out of `ManifoldFuzz`
///    (`ManifoldKit`) as a standalone, injectable function. `Replayer.runOnce`
///    currently calls straight into a captured `InferenceService` handle and
///    does not expose a per-call prompt-plus-sampler entry point that can be
///    driven from outside the fuzzer.
///
/// 2. **Config-lossy plumbing fix** — `Replayer.runOnce` hardcodes
///    `repeatPenalty: 1.1` and never threads the captured run's seed or `topK`
///    back into the re-drive call (plan §8). Until this is fixed, a re-drive
///    under `SamplerConfig.greedy` will not reproduce a run that was originally
///    generated with a different sampler, making score-movement detection
///    unreliable.
///
/// 3. **Cross-quant real-model verification** — the gate is only meaningful
///    when the re-driven run comes from a *different* quantisation of the same
///    model (the regression moat's premise). That requires a manifold-llama
///    lockstep PR (plan §8, P4 manifold-llama side) before any gate verdict
///    can be trusted as real signal.
///
/// Until all three are in place, use `MockRecordReDriver` (test-only) to
/// exercise the gate logic on fixtures.
public protocol RecordReDriver: Sendable {

    /// Re-drive `prompt` under `sampler` and return the raw backend output.
    ///
    /// The `prompt` is the **original prompt string** (not its SHA-256 hash)
    /// that was fed to the baseline run. The caller is responsible for
    /// preserving the original prompt string alongside the captured
    /// ``RawRun`` — the ``RawRun`` itself only stores `promptSha256` for
    /// comparability purposes, not the full string.
    ///
    /// - Parameters:
    ///   - prompt: The exact prompt string that produced the baseline run.
    ///   - sampler: The sampler settings to use for the re-drive. Pass
    ///     ``SamplerConfig/greedy`` to reproduce a deterministic baseline.
    /// - Returns: A ``RawRun`` from the re-drive. The caller passes this to
    ///   ``RegressionGate/check(baseline:baselineScore:reDriven:scorer:)`` for
    ///   verdict computation.
    func reDrive(prompt: String, sampler: SamplerConfig) async throws -> RawRun
}
