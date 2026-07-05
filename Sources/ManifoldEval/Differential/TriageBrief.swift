import Foundation

/// The raw material the `triage` subcommand reads for one flagged cell: the
/// repeat batches of `RawRun`s for each leg, exactly as ``DeterminismHarness``
/// would have collected them. `RawRun` is already the fixed cross-backend
/// contract (see its doc comment — an external runner emits this shape
/// verbatim), so a JSON file containing two such arrays is the natural
/// "transcript" a `diff` run (or a hand-assembled repro) can hand to `triage`.
public struct TriageTranscript: Codable, Sendable, Equatable {
    /// Leg A's repeat batch (order = repeat index).
    public var legA: [RawRun]
    /// Leg B's repeat batch (order = repeat index).
    public var legB: [RawRun]
    /// BOS reconciliation mode: `"autoDetect"` (default when omitted), `"none"`,
    /// or a decimal token id string (`"128000"`) for `.explicit`.
    public var bos: String?

    public init(legA: [RawRun], legB: [RawRun], bos: String? = nil) {
        self.legA = legA
        self.legB = legB
        self.bos = bos
    }

    /// Resolves ``bos`` to a ``BOSNormalization``, defaulting to `.autoDetect`
    /// when unset (matching `diff`'s own default).
    public func resolvedBOS() throws -> BOSNormalization {
        try Self.resolveBOS(bos)
    }

    /// Free-standing resolver so a CLI-supplied `--bos` override (which may not
    /// come from a decoded transcript at all) can share the same parsing rule.
    public static func resolveBOS(_ raw: String?) throws -> BOSNormalization {
        guard let raw, !raw.isEmpty else { return .autoDetect }
        switch raw {
        case "autoDetect": return .autoDetect
        case "none": return .none
        default:
            guard let id = Int(raw) else { throw TriageError.invalidBOS(raw) }
            return .explicit(bosID: id)
        }
    }
}

/// A human's confirm/override of a ``TriageBrief``'s proposed classification.
/// Recording this is the ONLY way a brief's verdict becomes non-`nil` — the
/// assistant itself never sets it (ORIGINS #7: propose, never adjudicate).
public enum HumanDecision: String, Sendable, Equatable, Codable {
    case genuine
    case benign
}

/// How much weight a human should put on ``TriageBrief/proposedClassification``.
/// Deliberately conservative: any unmet control forces `.low`, never averaged
/// away — a low-confidence brief must read as "look harder here", not as a
/// softened verdict (issue #23 / ORIGINS #7).
public enum TriageConfidence: String, Sendable, Equatable, Codable {
    case low
    case medium
    case high
}

/// The exact differing region between two legs' representative outputs, computed
/// over raw UTF-8 bytes (not characters/lines) so "the exact differing bytes" is
/// literal, not an approximation. Byte-exact prefix/suffix stripping can split a
/// multi-byte codepoint at the boundary; the displayed segments decode losslessly
/// in the common case (ASCII/ASCII-adjacent divergences) and fall back to the
/// Unicode replacement character only in that rare split case — the byte COUNTS
/// reported alongside are always exact regardless.
public struct DivergingSegment: Sendable, Equatable {
    public let commonPrefixLength: Int
    public let commonSuffixLength: Int
    public let aDiffering: String
    public let bDiffering: String
}

/// A structured, human-actionable brief for one flagged cell: a PROPOSED
/// classification, never a verdict. See ``render()`` for the exact wording that
/// keeps this explicit.
///
/// Mirrors the same-bytes / determinism controls ``DivergenceTriage`` already
/// enforces (this type never re-derives the classification — it reuses
/// ``DivergenceTriage/classify(_:_:aIsDeterministic:bIsDeterministic:aWasAssessed:bWasAssessed:bos:)``
/// via ``DifferentialRecord/compare`` and layers a confidence read + differing-bytes
/// extraction + human-decision slot on top).
public struct TriageBrief: Sendable, Equatable {
    public let cohort: Cohort
    public let proposedClassification: Divergence
    public let confidence: TriageConfidence
    public let confidenceReasons: [String]
    public let sameBytesControlSatisfied: Bool
    public let determinismControlSatisfied: Bool
    public let aReproducible: Bool
    public let bReproducible: Bool
    public let diverging: DivergingSegment?
    public let detectedBOS: Int?
    /// The gate. `nil` until a human passes `--decide genuine|benign` — the
    /// assistant never populates this itself.
    public var humanDecision: HumanDecision?

    public init(
        cohort: Cohort,
        proposedClassification: Divergence,
        confidence: TriageConfidence,
        confidenceReasons: [String],
        sameBytesControlSatisfied: Bool,
        determinismControlSatisfied: Bool,
        aReproducible: Bool,
        bReproducible: Bool,
        diverging: DivergingSegment?,
        detectedBOS: Int?,
        humanDecision: HumanDecision? = nil
    ) {
        self.cohort = cohort
        self.proposedClassification = proposedClassification
        self.confidence = confidence
        self.confidenceReasons = confidenceReasons
        self.sameBytesControlSatisfied = sameBytesControlSatisfied
        self.determinismControlSatisfied = determinismControlSatisfied
        self.aReproducible = aReproducible
        self.bReproducible = bReproducible
        self.diverging = diverging
        self.detectedBOS = detectedBOS
        self.humanDecision = humanDecision
    }

    /// Builds a brief from two repeat batches. Throws ``TriageError/emptyLeg``
    /// when either leg has no runs — there is nothing to triage, and fabricating
    /// a brief over absent data would hide that fact from the human.
    public static func build(
        legA: [RawRun],
        legB: [RawRun],
        bos: BOSNormalization = .autoDetect,
        cohortOverride: Cohort? = nil,
        cloudBackends: Set<String> = Cohort.defaultCloudBackends,
        humanDecision: HumanDecision? = nil
    ) throws -> TriageBrief {
        guard !legA.isEmpty, !legB.isEmpty else { throw TriageError.emptyLeg }

        let reportA = DeterminismReport(runs: legA)
        let reportB = DeterminismReport(runs: legB)
        guard
            let record = DifferentialRecord.compare(
                reportA, reportB, bos: bos, cohortOverride: cohortOverride, cloudBackends: cloudBackends
            ),
            let repA = reportA.representative,
            let repB = reportB.representative
        else {
            throw TriageError.emptyLeg
        }

        let sameBytesOK = repA.promptSha256 == repB.promptSha256
        let determinismOK = reportA.wasAssessed && reportB.wasAssessed
        let aReproducible = reportA.wasAssessed && reportA.isDeterministic
        let bReproducible = reportB.wasAssessed && reportB.isDeterministic
        let diverging = divergingSegment(repA.output, repB.output)
        let (confidence, reasons) = confidenceAssessment(
            divergence: record.divergence,
            sameBytesOK: sameBytesOK,
            determinismOK: determinismOK
        )

        return TriageBrief(
            cohort: record.cohort,
            proposedClassification: record.divergence,
            confidence: confidence,
            confidenceReasons: reasons,
            sameBytesControlSatisfied: sameBytesOK,
            determinismControlSatisfied: determinismOK,
            aReproducible: aReproducible,
            bReproducible: bReproducible,
            diverging: diverging,
            detectedBOS: record.detectedBOS,
            humanDecision: humanDecision
        )
    }

    /// Byte-exact common-prefix/common-suffix diff. `nil` when the two outputs
    /// are byte-identical (nothing to show).
    static func divergingSegment(_ a: String, _ b: String) -> DivergingSegment? {
        guard a != b else { return nil }
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)

        var prefix = 0
        let maxPrefix = min(aBytes.count, bBytes.count)
        while prefix < maxPrefix, aBytes[prefix] == bBytes[prefix] {
            prefix += 1
        }

        var suffix = 0
        let maxSuffix = maxPrefix - prefix
        while suffix < maxSuffix, aBytes[aBytes.count - 1 - suffix] == bBytes[bBytes.count - 1 - suffix] {
            suffix += 1
        }

        let aMiddle = Array(aBytes[prefix..<(aBytes.count - suffix)])
        let bMiddle = Array(bBytes[prefix..<(bBytes.count - suffix)])
        return DivergingSegment(
            commonPrefixLength: prefix,
            commonSuffixLength: suffix,
            aDiffering: String(decoding: aMiddle, as: UTF8.self),
            bDiffering: String(decoding: bMiddle, as: UTF8.self)
        )
    }

    /// Confidence is conservative by construction: an unmet control forces
    /// `.low` outright (never blended with the classification's own certainty),
    /// because a control failure means the comparison itself can't be trusted —
    /// see ``DivergenceTriage``'s cascade doc for why these are checked first.
    static func confidenceAssessment(
        divergence: Divergence,
        sameBytesOK: Bool,
        determinismOK: Bool
    ) -> (TriageConfidence, [String]) {
        if !sameBytesOK {
            return (.low, ["same-bytes control UNMET — prompt hashes differ; the comparison itself may be invalid"])
        }
        if !determinismOK {
            return (.low, ["determinism control UNMET — a leg had fewer than 2 repeats, so its reproducibility is unknown"])
        }
        switch divergence {
        case .samplerNondeterminism:
            return (.medium, ["a leg was observed non-reproducible across its own repeats — the output comparison is noisy"])
        case .degenerateRepetitionLengthMismatch:
            return (.medium, ["outputs reduce to the same repeating unit at different lengths — a stopping-length artifact, not necessarily a content difference"])
        case .identical, .promptDivergence, .tokenizerDivergence, .samplerMismatch, .indeterminate, .genuineDivergence:
            return (.high, ["both the same-bytes and determinism controls are satisfied; the verdict rests on deterministic evidence"])
        }
    }

    /// Renders the brief as Markdown a human can act on in seconds. The
    /// "ADVISORY ONLY" banner and unset-by-default verdict line are the load
    /// -bearing text that keeps this a proposal, never an auto-adjudication.
    public func render() -> String {
        var out = "# Pre-Triage Brief — ADVISORY ONLY\n\n"
        out += "> This is a PROPOSED classification, not a verdict. The human triage gate "
        out += "remains the decision-of-record (ORIGINS #7 — \"keep the human in the loop\"). "
        out += "Confirm or override it; do not act on this brief alone.\n\n"

        out += "## Proposed classification\n\n"
        out += "- classification: **\(proposedClassification.rawValue)**\n"
        out += "- cohort: **\(cohort.rawValue)**\n"
        out += "- confidence: **\(confidence.rawValue.uppercased())**\n"
        for reason in confidenceReasons {
            out += "  - \(reason)\n"
        }
        if confidence == .low {
            out += "\n> **LOW CONFIDENCE** — a control is unmet below. Read the transcript "
            out += "yourself before trusting this label; do not take it at face value.\n"
        }
        out += "\n"

        out += "## Controls\n\n"
        out += "- same-bytes control: \(sameBytesControlSatisfied ? "SATISFIED" : "**UNSATISFIED**")\n"
        out += "- determinism control: \(determinismControlSatisfied ? "SATISFIED" : "**UNSATISFIED**")"
        out += " (leg A reproducible: \(aReproducible), leg B reproducible: \(bReproducible))\n"
        if let detectedBOS {
            out += "- detected BOS id (token-stream asymmetry): `\(detectedBOS)`\n"
        }
        out += "\n"

        out += "## Differing bytes\n\n"
        if let diverging {
            out += "- common prefix: \(diverging.commonPrefixLength) bytes, common suffix: \(diverging.commonSuffixLength) bytes\n"
            out += "- leg A differing segment (\(diverging.aDiffering.utf8.count) bytes): \(fence(diverging.aDiffering))\n"
            out += "- leg B differing segment (\(diverging.bDiffering.utf8.count) bytes): \(fence(diverging.bDiffering))\n"
        } else {
            out += "_outputs are byte-identical — no differing segment._\n"
        }
        out += "\n"

        out += "## Human decision (the gate)\n\n"
        if let humanDecision {
            out += "- **RECORDED: \(humanDecision.rawValue)** — human-confirmed via `--decide`.\n"
        } else {
            out += "- **unset — awaiting human.** The assistant never adjudicates; pass "
            out += "`--decide genuine|benign` once you've reviewed this brief to record your decision.\n"
        }

        return out
    }

    private func fence(_ text: String) -> String {
        if text.isEmpty {
            return "_(empty)_"
        }
        if text.contains("\n") {
            return "\n```\n\(text)\n```"
        }
        return "`\(text)`"
    }
}
