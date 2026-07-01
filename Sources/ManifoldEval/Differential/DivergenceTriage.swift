import Foundation

/// The triage verdict for a pair of runs on the same logical prompt.
///
/// These are mutually exclusive confound-stripping buckets (plan §13b): each
/// state above `genuineDivergence` explains a difference by a *control failure*,
/// so a human's attention is reserved for `genuineDivergence` alone. Order of the
/// cascade is the contract — see ``DivergenceTriage/classify(_:_:aIsDeterministic:bIsDeterministic:bos:)``.
public enum Divergence: String, Sendable, Equatable, Codable {
    /// Same prompt hash, same output, BOTH legs reproducible — nothing to explain.
    case identical
    /// Prompt hashes differ — the same-bytes control FAILED. The comparison is
    /// invalid (a harness bug, not a model finding). The most important guard: it
    /// catches when same-bytes was never achieved, so a render/BOS slip can never
    /// masquerade as a model divergence.
    case promptDivergence
    /// Same prompt STRING but the input token streams differ (after BOS
    /// normalisation) → a vocab/tokenisation mismatch fed the model different
    /// inputs. The input control failed at the token level.
    case tokenizerDivergence
    /// Same prompt, same input tokens, but the two legs ran under DIFFERENT sampler
    /// settings (the determinism-relevant fields: temperature, topK, repeatPenalty).
    /// The output difference is explained by an unequal sampler, not the model — the
    /// sampler-equality control failed.
    case samplerMismatch
    /// Same prompt, outputs differ, and a backend is non-reproducible across its
    /// own repeats → the difference is sampler noise, not signal.
    case samplerNondeterminism
    /// Outputs differ (or match by luck) but a leg's determinism was never assessed
    /// — fewer than two repeats, so reproducibility is unknown. NOT a clean pass and
    /// NOT a confirmed divergence: rerun with more `--repeats` to resolve it.
    case indeterminate
    /// Same prompt, both backends reproducible, same input tokens, same sampler,
    /// outputs differ — but both outputs are each a degenerate repetition of the
    /// exact same short unit, differing only in how many times it repeated
    /// before each backend's own stopping criterion fired (see
    /// ``DegenerateRepetition``). Proven overnight (2026-06-30): the same GGUF
    /// produced the identical repeating line on Ollama and llama.cpp — 8 reps vs
    /// 3. A stopping-length artifact, not a content difference: real, but a
    /// distinct (lesser) alarm than ``genuineDivergence``.
    case degenerateRepetitionLengthMismatch
    /// Same prompt, both backends reproducible, same input tokens, same sampler —
    /// and the outputs still differ, and they are NOT the same repeating unit at
    /// different lengths. The only state worth a human: a genuine
    /// runtime/renderer/model difference, every confound stripped.
    case genuineDivergence
}

/// Classifies why (or whether) two runs for the same logical prompt diverge.
///
/// Pure and total — no I/O, no throwing. The within-backend determinism signal is
/// passed in (computed by ``DeterminismHarness``) rather than recomputed here, so
/// the classifier stays a pure function of its inputs and is exhaustively
/// fixture-testable.
public enum DivergenceTriage {

    /// Classify the divergence between `a` and `b`.
    ///
    /// The cascade (precedence matters — earlier wins):
    /// 1. **promptDivergence** — `promptSha256` differ. Input-string control
    ///    failed; everything downstream is moot.
    /// 2. **outputs equal** — the strongest "no problem" signal, BUT only trustworthy
    ///    when both legs were assessed and reproducible: a match drawn from a
    ///    non-reproducible leg is luck (`samplerNondeterminism`), and a match where a
    ///    leg's determinism is unknown is `indeterminate` (S3). Wins over a benign
    ///    token difference when it is trustworthy (a tokenizer diff that yields
    ///    identical output is not actionable).
    /// 3. **tokenizerDivergence** — outputs differ AND *both* legs report token
    ///    ids AND those streams differ after BOS normalisation. Tokenisation is
    ///    deterministic and not subject to sampler noise *or* repeat count, so a
    ///    token mismatch is a real input-control failure regardless of
    ///    reproducibility/assessment — hence it is checked before those confounds.
    ///    Skipped (not a divergence) when either leg reports an empty token stream:
    ///    the contract reads empty as "tokenizer check unavailable" (Ollama raw).
    /// 4. **samplerMismatch** — outputs differ, tokens match/unavailable, but the two
    ///    legs ran under different determinism-relevant sampler settings. The
    ///    sampler-equality control failed; the difference is config, not model.
    /// 5. **samplerNondeterminism** — outputs differ, tokens + sampler agree, and a
    ///    leg was *observed* non-reproducible over its repeats. The output comparison
    ///    can't be trusted → noise. (Observed noise outranks unknown assessment.)
    /// 6. **indeterminate** — outputs differ (or match), tokens + sampler agree, no
    ///    observed nondeterminism, but a leg's determinism was never assessed (< 2
    ///    repeats). Neither pass nor finding — rerun with more repeats.
    /// 7. **degenerateRepetitionLengthMismatch** — every confound above stripped,
    ///    outputs still differ, BUT both outputs independently reduce to the same
    ///    short repeating unit (``DegenerateRepetition``) — they differ only in
    ///    repeat count, not in repeated content. A stopping-length artifact, not
    ///    a model/output difference; checked before (and instead of) 8 so it
    ///    never gets diluted into the single "worth a human" bucket.
    /// 8. **genuineDivergence** — outputs differ, every confound stripped, both
    ///    legs assessed-reproducible, and NOT a same-unit repetition-length
    ///    mismatch. Residual signal worth a human.
    ///
    /// - Parameters:
    ///   - aIsDeterministic / bIsDeterministic: whether each leg produced an
    ///     identical output across its own determinism repeats. Vacuously `true`
    ///     with fewer than two repeats — pair with `aWasAssessed`/`bWasAssessed`.
    ///   - aWasAssessed / bWasAssessed: whether each leg actually had >= 2 repeats,
    ///     so `*IsDeterministic` carries real evidence rather than a vacuous default.
    public static func classify(
        _ a: RawRun,
        _ b: RawRun,
        aIsDeterministic: Bool,
        bIsDeterministic: Bool,
        aWasAssessed: Bool = true,
        bWasAssessed: Bool = true,
        bos: BOSNormalization = .autoDetect
    ) -> Divergence {
        // 1. Input-string control. The single most important guard.
        guard a.promptSha256 == b.promptSha256 else { return .promptDivergence }

        // Reproducibility evidence: a leg is only trustworthy-reproducible when its
        // determinism was actually observed (assessed) AND held.
        let aReproducible = aWasAssessed && aIsDeterministic
        let bReproducible = bWasAssessed && bIsDeterministic
        let bothReproducible = aReproducible && bReproducible
        // Positive evidence of noise (assessed and NOT deterministic) on either leg.
        let observedNondeterminism = (aWasAssessed && !aIsDeterministic) || (bWasAssessed && !bIsDeterministic)
        // A leg whose determinism we simply never measured.
        let eitherUnassessed = !aWasAssessed || !bWasAssessed

        // 2. Outputs agree → strongest "no problem" signal, but only when trustworthy.
        if a.output == b.output {
            if bothReproducible { return .identical }
            if observedNondeterminism { return .samplerNondeterminism }
            return .indeterminate
        }

        // 3. Token-level input control. Only meaningful when BOTH legs expose
        //    tokenisation — an empty stream is "unavailable", never a divergence.
        let tokenCheckAvailable = !a.inputTokenIds.isEmpty && !b.inputTokenIds.isEmpty
        if tokenCheckAvailable,
           !BOSNormalizer.streamsMatch(a.inputTokenIds, b.inputTokenIds, normalization: bos) {
            return .tokenizerDivergence
        }

        // 4. Sampler-equality control: an unequal sampler explains the output diff.
        if !samplersAgree(a.sampler, b.sampler) {
            return .samplerMismatch
        }

        // 5. Observed nondeterminism — the output comparison can't be trusted.
        if observedNondeterminism {
            return .samplerNondeterminism
        }

        // 6. Determinism never assessed on a leg — neither pass nor finding.
        if eitherUnassessed {
            return .indeterminate
        }

        // 7. Every confound stripped, outputs still differ — but if both sides
        //    are the same short unit repeated a different number of times, it's
        //    a stopping-length artifact, not a content difference (S7 — the
        //    overnight 2026-06-30 false-positive repro: Ollama vs llama.cpp,
        //    identical repeating line, 8 reps vs 3).
        if DegenerateRepetition.isRepetitionLengthMismatch(a.output, b.output) {
            return .degenerateRepetitionLengthMismatch
        }

        // 8. Every confound stripped — a genuine divergence.
        return .genuineDivergence
    }

    /// Whether two samplers agree on the fields that actually shift the output
    /// distribution at compare time (temperature, topK, repeatPenalty). `seed` and
    /// `maxTokens` are intentionally excluded: at temp=0 the seed is moot, and a
    /// differing maxTokens is a length cap, not a sampling-distribution confound.
    private static func samplersAgree(_ a: SamplerConfig, _ b: SamplerConfig) -> Bool {
        a.temperature == b.temperature
            && a.topK == b.topK
            && a.repeatPenalty == b.repeatPenalty
    }
}

/// A compared pair built from two backends' determinism batches for one logical
/// prompt: the cohort, the per-leg determinism reports, and the triage verdict.
public struct DifferentialRecord: Sendable, Equatable {
    public let cohort: Cohort
    public let a: DeterminismReport
    public let b: DeterminismReport
    public let divergence: Divergence
    /// The BOS id auto-detected while comparing token streams, when applicable —
    /// surfaced so a human can sanity-check what the auto-detect treated as BOS.
    public let detectedBOS: Int?

    public init(
        cohort: Cohort,
        a: DeterminismReport,
        b: DeterminismReport,
        divergence: Divergence,
        detectedBOS: Int?
    ) {
        self.cohort = cohort
        self.a = a
        self.b = b
        self.divergence = divergence
        self.detectedBOS = detectedBOS
    }

    /// Build a record by comparing two determinism batches. Uses each batch's
    /// representative (first) run for the prompt/output/token comparison and each
    /// batch's observed reproducibility for the nondeterminism confound.
    ///
    /// Returns `nil` only when a batch is empty — there is nothing to compare, and
    /// a fabricated verdict over no data would be a lie.
    public static func compare(
        _ a: DeterminismReport,
        _ b: DeterminismReport,
        bos: BOSNormalization = .autoDetect,
        cohortOverride: Cohort? = nil,
        cloudBackends: Set<String> = Cohort.defaultCloudBackends
    ) -> DifferentialRecord? {
        guard let repA = a.representative, let repB = b.representative else { return nil }
        let cohort = cohortOverride ?? Cohort.classify(repA, repB, cloudBackends: cloudBackends)
        let divergence = DivergenceTriage.classify(
            repA, repB,
            aIsDeterministic: a.isDeterministic,
            bIsDeterministic: b.isDeterministic,
            aWasAssessed: a.wasAssessed,
            bWasAssessed: b.wasAssessed,
            bos: bos
        )
        let detected = BOSNormalizer.detectBOS(repA.inputTokenIds, repB.inputTokenIds)
        return DifferentialRecord(cohort: cohort, a: a, b: b, divergence: divergence, detectedBOS: detected)
    }
}
