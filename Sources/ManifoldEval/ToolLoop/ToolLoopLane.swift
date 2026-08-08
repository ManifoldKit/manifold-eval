import Foundation

/// Multi-turn tool-loop conformance lane: scores tool-result **threading**
/// across turns from recorded episode transcripts.
///
/// Where `BFCLLane` asks "did the model call the right function with the
/// right arguments" on one shot, this lane asks what happens *after* the
/// call comes back: did the tool result thread into the next call's
/// arguments (``ToolLoopChainedCall``) and into the final answer
/// (``ToolLoopExpectations/finalAnswerMustContain``)? A cell can pass
/// single-turn AST scoring and still mis-thread a result on turn 2 — this
/// lane is the instrument that makes that failure mode visible.
///
/// The lane is backend-agnostic by the same seam discipline as `BFCLLane`:
/// it scores ``ToolLoopTranscriptEntry`` values from ANY producer. The live
/// producer in this repo is `toolloop-generate` (Ollama through the real
/// `InferenceService` + `ToolRegistry` dispatch loop); tests use synthetic
/// transcripts.
///
/// ## Pass policy
/// A case passes only when **every repeat** passes **every specified axis**
/// — at `temp=0` a threading behavior that holds on 2 of 3 repeats is a
/// determinism finding, not a pass. Per-axis per-repeat counts are always
/// reported so a human can see *which* axis moved (ORIGINS #4: report
/// variance, never means-only; #7: the verdict focuses human attention, it
/// does not adjudicate).
public struct ToolLoopLane: Sendable {

  public init() {}

  // MARK: - Result types

  /// One repeat's axis-by-axis outcome. An axis is `nil` when the case does
  /// not specify it — "not probed" must never read as "passed" or "failed"
  /// (the absence ≠ failure discipline, ORIGINS #3).
  public struct RepeatScore: Sendable, Equatable {
    public let repeatIndex: Int
    public let firstCallOK: Bool?
    public let chainedOK: Bool?
    public let answerOK: Bool?

    /// True when every *specified* axis held for this repeat.
    public var pass: Bool {
      firstCallOK != false && chainedOK != false && answerOK != false
    }

    public init(repeatIndex: Int, firstCallOK: Bool?, chainedOK: Bool?, answerOK: Bool?) {
      self.repeatIndex = repeatIndex
      self.firstCallOK = firstCallOK
      self.chainedOK = chainedOK
      self.answerOK = answerOK
    }
  }

  /// One case's outcome across its repeats.
  public struct CaseResult: Sendable, Equatable {
    public let caseID: String
    /// Per-repeat scores over MEASURED episodes only (entries whose
    /// `error` is nil), ordered by repeat index. Empty when nothing for
    /// this case was measured.
    public let repeats: [RepeatScore]
    /// Episodes excluded from measurement because they carried an error
    /// marker (timeout, backend failure) — infrastructure holes, never
    /// capability zeros.
    public let erroredRepeats: Int
    /// True when all measured repeats produced bit-identical transcripts
    /// (same event sequence, same final text). Meaningful only with 2+
    /// measured repeats.
    public let deterministic: Bool

    /// Nothing was measured for this case — no transcript at all, or
    /// only errored episodes. Surfaced distinctly; never a measured zero.
    public var missing: Bool { repeats.isEmpty }
    /// The strict pass verdict: at least one measured repeat, and every
    /// measured repeat passed.
    public var passed: Bool { !repeats.isEmpty && repeats.allSatisfy(\.pass) }
    public var passedRepeats: Int { repeats.filter(\.pass).count }

    public init(
      caseID: String,
      repeats: [RepeatScore],
      erroredRepeats: Int = 0,
      deterministic: Bool
    ) {
      self.caseID = caseID
      self.repeats = repeats
      self.erroredRepeats = erroredRepeats
      self.deterministic = deterministic
    }
  }

  /// Whole-lane outcome, in corpus order.
  public struct LaneResult: Sendable, Equatable {
    public let caseResults: [CaseResult]

    public var total: Int { caseResults.count }
    public var passed: Int { caseResults.filter(\.passed).count }
    public var missing: Int { caseResults.filter(\.missing).count }
    /// Cases that were actually measured — the honest pass-rate
    /// denominator (holes are reported beside it, never inside it).
    public var measured: Int { total - missing }
    /// Cases whose repeats disagreed — a determinism-control failure at
    /// temp=0 regardless of whether the majority passed.
    public var variant: Int {
      caseResults.filter { !$0.deterministic && $0.repeats.count > 1 }.count
    }
    public var allPassed: Bool { passed == total }

    public init(caseResults: [CaseResult]) {
      self.caseResults = caseResults
    }
  }

  // MARK: - Scoring

  /// Scores `transcripts` against `cases`. Transcript entries whose `id`
  /// matches no case are ignored (and surfaced by the CLI as a warning);
  /// cases with no entries score as ``CaseResult/missing``.
  public func score(
    cases: [ToolLoopCase],
    transcripts: [ToolLoopTranscriptEntry]
  ) -> LaneResult {
    let byCase = Dictionary(grouping: transcripts, by: \.id)
    let results = cases.map { toolLoopCase -> CaseResult in
      // Stable order: repeat index, then input position — Swift's sort
      // is not guaranteed stable, and duplicate repeat indices (e.g.
      // concatenated runs) must not make the report input-order-luck.
      let all = (byCase[toolLoopCase.id] ?? [])
        .enumerated()
        .sorted { ($0.element.repeatIndex, $0.offset) < ($1.element.repeatIndex, $1.offset) }
        .map(\.element)
      // Errored episodes are holes, not measurements — score only the
      // clean ones (absence ≠ failure, ORIGINS #3).
      let entries = all.filter { $0.error == nil }
      let repeats = entries.map { score(entry: $0, against: toolLoopCase.expect) }
      let deterministic = entries.allSatisfy {
        $0.events == entries[0].events && $0.finalText == entries[0].finalText
      }
      return CaseResult(
        caseID: toolLoopCase.id,
        repeats: repeats,
        erroredRepeats: all.count - entries.count,
        deterministic: deterministic
      )
    }
    return LaneResult(caseResults: results)
  }

  /// Scores one recorded episode against one case's expectations.
  func score(
    entry: ToolLoopTranscriptEntry,
    against expect: ToolLoopExpectations
  ) -> RepeatScore {
    RepeatScore(
      repeatIndex: entry.repeatIndex,
      firstCallOK: expect.firstCall.map { scoreFirstCall($0, entry: entry) },
      chainedOK: expect.chainedCall.map { scoreChainedCall($0, entry: entry) },
      answerOK: expect.finalAnswerMustContain.isEmpty
        ? nil
        : expect.finalAnswerMustContain.allSatisfy { entry.finalText.contains($0) }
    )
  }

  /// Turn-1 correctness: the episode's FIRST call is the expected tool,
  /// and every expected argument matches canonically. A malformed-JSON
  /// argument payload scores as a miss, never a crash.
  private func scoreFirstCall(
    _ expected: ToolLoopExpectedCall,
    entry: ToolLoopTranscriptEntry
  ) -> Bool {
    guard let first = entry.calls.first, first.name == expected.toolName else {
      return false
    }
    guard let expectedArguments = expected.arguments else { return true }
    guard let canonical = ToolLoopArguments.canonicalized(first.arguments) else {
      return false
    }
    return expectedArguments.allSatisfy { key, value in canonical[key] == value }
  }

  /// The threading probe. Two conditions, both load-bearing:
  ///
  /// 1. Some call invokes the expected tool with the sentinel value under
  ///    the expected argument key.
  /// 2. That call occurs AFTER the episode's first tool result. The
  ///    sentinel exists only inside a scripted result — a matching call
  ///    emitted *before* any result (e.g. both calls guessed in one
  ///    parallel batch) could not have read it, so a pre-result match is a
  ///    lucky hallucination and must score as a miss.
  private func scoreChainedCall(
    _ expected: ToolLoopChainedCall,
    entry: ToolLoopTranscriptEntry
  ) -> Bool {
    guard let firstResultIndex = entry.firstResultIndex else { return false }
    for (index, event) in entry.events.enumerated() {
      guard index > firstResultIndex,
        case .call(let name, let arguments) = event,
        name == expected.toolName,
        let canonical = ToolLoopArguments.canonicalized(arguments),
        canonical[expected.argumentKey] == expected.expectedValue
      else {
        continue
      }
      return true
    }
    return false
  }
}
