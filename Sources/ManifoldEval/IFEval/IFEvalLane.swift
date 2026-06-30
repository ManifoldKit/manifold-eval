import Foundation
import ManifoldInference

/// A deterministic eval lane that scores model responses against IFEval
/// instruction-following constraints.
///
/// `IFEvalLane` is stateless and Sendable. Call `evaluate(case:response:)` per
/// case, then `aggregate(results:)` to compute strict accuracy and per-instruction
/// breakdowns over a batch.
///
/// The lane is wired into `ManifoldInference.EvalScorer` via a conformance below
/// so it can be used in the shared eval surface.
public struct IFEvalLane: Sendable {

    // MARK: - Verifier registry

    /// All verifiers keyed by instruction ID.
    private let verifiers: [String: any IFEvalVerifier]

    public init() {
        var map: [String: any IFEvalVerifier] = [:]
        let all: [any IFEvalVerifier] = [
            // Length
            WordCountVerifier(),
            SentenceCountVerifier(),
            ParagraphCountVerifier(),
            NthParagraphFirstWordVerifier(),
            // Keywords
            KeywordInclusionVerifier(),
            KeywordExclusionVerifier(),
            KeywordFrequencyVerifier(),
            LetterFrequencyVerifier(),
            // Format
            JSONOutputVerifier(),
            BulletListVerifier(),
            HighlightedSectionsVerifier(),
            TitleVerifier(),
            SectionSeparatorVerifier(),
            PlaceholderCountVerifier(),
            PostscriptVerifier(),
            ConstrainedResponseVerifier(),
            TwoResponsesVerifier(),
            RepeatPromptVerifier(),
            // Case
            AllLowercaseVerifier(),
            AllUppercaseVerifier(),
            CapitalWordFrequencyVerifier(),
            // Start/end/punctuation
            StartsWithVerifier(),
            EndsWithVerifier(),
            NoCommaVerifier(),
            QuotedWrapVerifier(),
            // Language
            ResponseLanguageVerifier(),
        ]
        for v in all {
            map[v.instructionID] = v
        }
        verifiers = map
    }

    // MARK: - Per-case evaluation

    /// Evaluates `response` against all constraints in `evalCase`.
    ///
    /// Returns a result with one Boolean per instruction. An instruction whose
    /// ID has no registered verifier is recorded as `false` (conservative: an
    /// unverifiable constraint is not considered satisfied).
    public func evaluate(case evalCase: IFEvalCase, response: String) -> IFEvalResult {
        let results = zip(evalCase.instructionIDs, evalCase.kwargs).map { id, kw in
            verifiers[id]?.verify(response: response, kwargs: kw) ?? false
        }
        return IFEvalResult(
            key: evalCase.key,
            prompt: evalCase.prompt,
            response: response,
            instructionResults: Array(results)
        )
    }

    // MARK: - Aggregation

    /// Computes strict accuracy and per-instruction accuracy over a batch of results.
    public func aggregate(results: [IFEvalResult], cases: [IFEvalCase]) -> IFEvalAggregateScore {
        guard !results.isEmpty else {
            return IFEvalAggregateScore(
                strictAccuracy: 0,
                totalCases: 0,
                passedCases: 0,
                perInstructionAccuracy: [:]
            )
        }

        let passedCases = results.filter(\.allPassed).count
        let strictAccuracy = Double(passedCases) / Double(results.count)

        // Build per-instruction-ID pass counts.
        var passCount: [String: Int] = [:]
        var totalCount: [String: Int] = [:]

        // Build a key→case lookup to access instructionIDs in parallel with results.
        let casesByKey: [String: IFEvalCase] = Dictionary(cases.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        for result in results {
            guard let evalCase = casesByKey[result.key] else { continue }
            for (idx, id) in evalCase.instructionIDs.enumerated() {
                totalCount[id, default: 0] += 1
                if idx < result.instructionResults.count, result.instructionResults[idx] {
                    passCount[id, default: 0] += 1
                }
            }
        }

        var perInstructionAccuracy: [String: Double] = [:]
        for (id, total) in totalCount {
            let passed = passCount[id] ?? 0
            perInstructionAccuracy[id] = total > 0 ? Double(passed) / Double(total) : 0
        }

        return IFEvalAggregateScore(
            strictAccuracy: strictAccuracy,
            totalCases: results.count,
            passedCases: passedCases,
            perInstructionAccuracy: perInstructionAccuracy
        )
    }
}

// MARK: - EvalScorer conformance

/// Bridges `IFEvalLane` into the `EvalScorer` protocol so it can be used as a
/// standard scorer in the ManifoldInference eval surface.
///
/// The `Expected` type is `IFEvalCase` — the ground-truth instruction list.
/// The output's `visibleText` is the response being scored. The returned
/// `Score` carries `.bool(allPassed)` as the strict-accuracy verdict and
/// encodes per-instruction results in `metadata`.
extension IFEvalLane: EvalScorer {
    public typealias Expected = IFEvalCase

    public func score(output: EvalRunOutput, expected: IFEvalCase) async -> Score {
        let result = evaluate(case: expected, response: output.visibleText)
        var metadata: [String: String] = [:]
        for (id, passed) in zip(expected.instructionIDs, result.instructionResults) {
            metadata[id] = passed ? "pass" : "fail"
        }
        let explanation = result.allPassed
            ? "All \(result.instructionResults.count) instructions passed."
            : "Failed: \(zip(expected.instructionIDs, result.instructionResults).filter { !$0.1 }.map(\.0).joined(separator: ", "))"

        return Score(
            value: .bool(result.allPassed),
            answer: nil,
            explanation: explanation,
            metadata: metadata
        )
    }
}
