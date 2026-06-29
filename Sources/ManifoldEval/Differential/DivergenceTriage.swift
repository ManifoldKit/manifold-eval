import Foundation

/// The triage verdict for a pair of runs on the same logical prompt.
///
/// These are mutually exclusive confound-stripping buckets (plan §13b): each
/// state above `genuineDivergence` explains a difference by a *control failure*,
/// so a human's attention is reserved for `genuineDivergence` alone. Order of the
/// cascade is the contract — see ``DivergenceTriage/classify(_:_:aIsDeterministic:bIsDeterministic:bos:)``.
public enum Divergence: String, Sendable, Equatable, Codable {
    /// Same prompt hash, same output — nothing to explain.
    case identical
    /// Prompt hashes differ — the same-bytes control FAILED. The comparison is
    /// invalid (a harness bug, not a model finding). The most important guard: it
    /// catches when same-bytes was never achieved, so a render/BOS slip can never
    /// masquerade as a model divergence.
    case promptDivergence
    /// Same prompt, outputs differ, and a backend is non-reproducible across its
    /// own repeats → the difference is sampler noise, not signal.
    case samplerNondeterminism
    /// Same prompt STRING but the input token streams differ (after BOS
    /// normalisation) → a vocab/tokenisation mismatch fed the model different
    /// inputs. The input control failed at the token level.
    case tokenizerDivergence
    /// Same prompt, both backends reproducible, same input tokens — and the
    /// outputs still differ. The only state worth a human: a genuine
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
    /// 2. **identical** — outputs equal. The strongest "no problem" signal; it
    ///    wins even over a benign token difference (a tokenizer diff that yields
    ///    identical output is not actionable).
    /// 3. **tokenizerDivergence** — outputs differ AND *both* legs report token
    ///    ids AND those streams differ after BOS normalisation. Tokenisation is
    ///    deterministic and not subject to sampler noise, so a token mismatch is a
    ///    real input-control failure regardless of reproducibility — hence it is
    ///    checked before the nondeterminism confound. Skipped (not a divergence)
    ///    when either leg reports an empty token stream: the contract reads empty
    ///    as "tokenizer check unavailable" (the Ollama raw path).
    /// 4. **samplerNondeterminism** — outputs differ, tokens match/unavailable,
    ///    and a leg is non-reproducible over its repeats. The output comparison
    ///    can't be trusted → noise.
    /// 5. **genuineDivergence** — outputs differ, tokens match/unavailable, both
    ///    legs reproducible. Residual signal worth a human.
    ///
    /// - Parameters:
    ///   - aIsDeterministic / bIsDeterministic: whether each leg produced an
    ///     identical output across its own determinism repeats. With fewer than
    ///     two repeats this is vacuously `true`; the caller is responsible for
    ///     running enough repeats (default 3) for the signal to be meaningful.
    public static func classify(
        _ a: RawRun,
        _ b: RawRun,
        aIsDeterministic: Bool,
        bIsDeterministic: Bool,
        bos: BOSNormalization = .autoDetect
    ) -> Divergence {
        // 1. Input-string control. The single most important guard.
        guard a.promptSha256 == b.promptSha256 else { return .promptDivergence }

        // 2. Outputs agree → nothing to triage.
        if a.output == b.output { return .identical }

        // 3. Token-level input control. Only meaningful when BOTH legs expose
        //    tokenisation — an empty stream is "unavailable", never a divergence.
        let tokenCheckAvailable = !a.inputTokenIds.isEmpty && !b.inputTokenIds.isEmpty
        if tokenCheckAvailable,
           !BOSNormalizer.streamsMatch(a.inputTokenIds, b.inputTokenIds, normalization: bos) {
            return .tokenizerDivergence
        }

        // 4. Output-reproducibility confound.
        if !aIsDeterministic || !bIsDeterministic {
            return .samplerNondeterminism
        }

        // 5. Every confound stripped — a genuine divergence.
        return .genuineDivergence
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
            bos: bos
        )
        let detected = BOSNormalizer.detectBOS(repA.inputTokenIds, repB.inputTokenIds)
        return DifferentialRecord(cohort: cohort, a: a, b: b, divergence: divergence, detectedBOS: detected)
    }
}
