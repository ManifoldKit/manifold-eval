import XCTest
@testable import ManifoldEval

/// Fixture-driven tests for the differential harness. No live model — these run on
/// hosted CI (no Ollama). Every triage state is asserted to an EXACT enum case, so
/// a classifier that mislabels a state fails the test (sabotage-resistant by
/// construction: there is no looser assertion to pass through).
final class DifferentialTriageTests: XCTestCase {

    // MARK: builders

    private func run(
        backend: String = "ollama",
        model: String = "m",
        quant: String = "server",
        promptSha: String = "aaa",
        inputTokens: [Int] = [],
        output: String = "hello",
        sampler: SamplerConfig = .greedy,
        repeatIndex: Int = 0
    ) -> RawRun {
        RawRun(
            backend: backend,
            model: model,
            quant: quant,
            promptSha256: promptSha,
            inputTokenIds: inputTokens,
            output: output,
            outputTokenIds: [],
            sampler: sampler,
            coreCommit: "deadbeef",
            toolingVersions: ["ollama": "0.30.11"],
            repeatIndex: repeatIndex
        )
    }

    // MARK: - RawRun contract shape

    func testRawRunCodableRoundTrip() throws {
        let original = run(backend: "llama.cpp", quant: "Q4_K_M", inputTokens: [128000, 1, 2, 3], output: "hi")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RawRun.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testRawRunJSONUsesContractKeys() throws {
        let data = try JSONEncoder().encode(run())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // The frozen contract keys (camelCase, no CodingKeys remapping).
        for key in ["promptSha256", "inputTokenIds", "outputTokenIds", "coreCommit",
                    "toolingVersions", "repeatIndex", "temperature", "topK", "repeatPenalty", "maxTokens"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "RawRun JSON must carry contract key '\(key)'")
        }
    }

    func testRawRunDecodesFromContractFixture() throws {
        // Exactly the shape an external runner emits on stdout.
        let fixture = """
        { "backend":"llama.cpp","model":"x.gguf","quant":"Q4_K_M",
          "promptSha256":"abc123","inputTokenIds":[128000,9906],
          "output":"Hello","outputTokenIds":[15339],
          "sampler":{"temperature":0.0,"seed":42,"topK":0,"repeatPenalty":1.0,"maxTokens":64},
          "coreCommit":"4461529f","toolingVersions":{"llama.cpp":"b8772"},"repeatIndex":2 }
        """
        let decoded = try JSONDecoder().decode(RawRun.self, from: Data(fixture.utf8))
        XCTAssertEqual(decoded.backend, "llama.cpp")
        XCTAssertEqual(decoded.inputTokenIds, [128000, 9906])
        XCTAssertEqual(decoded.sampler.seed, 42)
        XCTAssertEqual(decoded.repeatIndex, 2)
    }

    // MARK: - BOS normalization

    func testBOSExplicitStripsLeadingBOSOnly() {
        // BOS-only difference (the Ollama-no-BOS vs llama-addBos asymmetry).
        XCTAssertTrue(BOSNormalizer.streamsMatch([128000, 1, 2, 3], [1, 2, 3], normalization: .explicit(bosID: 128000)))
        // Both carry a BOS → still matches (both normalised to no-BOS).
        XCTAssertTrue(BOSNormalizer.streamsMatch([128000, 1, 2, 3], [128000, 1, 2, 3], normalization: .explicit(bosID: 128000)))
    }

    func testBOSExplicitRealDifferenceIsNotStripped() {
        // A genuine token mismatch beyond the BOS must NOT be masked.
        XCTAssertFalse(BOSNormalizer.streamsMatch([128000, 1, 2, 99], [1, 2, 3], normalization: .explicit(bosID: 128000)))
    }

    func testBOSAutoDetectMatchesBOSOnlyDifference() {
        XCTAssertTrue(BOSNormalizer.streamsMatch([128000, 1, 2, 3], [1, 2, 3], normalization: .autoDetect))
        XCTAssertEqual(BOSNormalizer.detectBOS([128000, 1, 2, 3], [1, 2, 3]), 128000)
    }

    func testBOSAutoDetectRejectsRealDifference() {
        // Length differs by one, but dropping the lead doesn't reconcile → mismatch.
        XCTAssertFalse(BOSNormalizer.streamsMatch([128000, 1, 2, 99], [1, 2, 3], normalization: .autoDetect))
        // Length differs by two → never a single-BOS asymmetry.
        XCTAssertFalse(BOSNormalizer.streamsMatch([1, 2, 3, 4], [1, 2], normalization: .autoDetect))
    }

    func testBOSNoneIsExact() {
        XCTAssertTrue(BOSNormalizer.streamsMatch([1, 2, 3], [1, 2, 3], normalization: .none))
        XCTAssertFalse(BOSNormalizer.streamsMatch([128000, 1, 2, 3], [1, 2, 3], normalization: .none))
    }

    // MARK: - DivergenceTriage: every state

    func testIdentical() {
        let a = run(promptSha: "p", output: "same")
        let b = run(promptSha: "p", output: "same")
        XCTAssertEqual(DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true), .identical)
    }

    func testPromptDivergence() {
        let a = run(promptSha: "p1", output: "x")
        let b = run(promptSha: "p2", output: "y")
        XCTAssertEqual(DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true), .promptDivergence)
    }

    func testPromptDivergenceWinsOverEveryOtherConfound() {
        // Different prompt + nondeterministic + differing tokens → still promptDivergence:
        // a failed input-string control invalidates the whole comparison.
        let a = run(promptSha: "p1", inputTokens: [1, 2], output: "x")
        let b = run(promptSha: "p2", inputTokens: [9, 9], output: "y")
        XCTAssertEqual(DivergenceTriage.classify(a, b, aIsDeterministic: false, bIsDeterministic: false), .promptDivergence)
    }

    func testSamplerNondeterminism() {
        // Same prompt, outputs differ, tokens unavailable, one leg non-reproducible.
        let a = run(promptSha: "p", output: "x")
        let b = run(promptSha: "p", output: "y")
        XCTAssertEqual(DivergenceTriage.classify(a, b, aIsDeterministic: false, bIsDeterministic: true), .samplerNondeterminism)
    }

    func testTokenizerDivergence() {
        // Same prompt string, both deterministic, both report tokens, tokens differ
        // beyond a single BOS → tokenizer mismatch.
        let a = run(backend: "llama.cpp", promptSha: "p", inputTokens: [128000, 1, 2, 99], output: "x")
        let b = run(backend: "llama2.cpp", promptSha: "p", inputTokens: [128000, 1, 2, 3], output: "y")
        XCTAssertEqual(DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true), .tokenizerDivergence)
    }

    func testTokenizerDivergenceTakesPrecedenceOverNondeterminism() {
        // Tokenisation is not subject to sampler noise, so a token mismatch is
        // flagged even when a leg is non-reproducible.
        let a = run(backend: "llama.cpp", promptSha: "p", inputTokens: [1, 2, 99], output: "x")
        let b = run(backend: "llama2.cpp", promptSha: "p", inputTokens: [1, 2, 3], output: "y")
        XCTAssertEqual(DivergenceTriage.classify(a, b, aIsDeterministic: false, bIsDeterministic: true), .tokenizerDivergence)
    }

    func testBOSOnlyTokenDiffIsNotTokenizerDivergence() {
        // The control wrinkle: Ollama-no-BOS vs llama-addBos must NOT read as a
        // tokenizer divergence. Outputs differ + both deterministic + tokens match
        // post-BOS → genuine, not tokenizer.
        let a = run(backend: "llama.cpp", promptSha: "p", inputTokens: [128000, 1, 2, 3], output: "x")
        let b = run(backend: "ollama-raw", promptSha: "p", inputTokens: [1, 2, 3], output: "y")
        XCTAssertEqual(DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true), .genuineDivergence)
    }

    func testTokenizerCheckUnavailableWhenOneLegEmpty() {
        // Ollama reports no tokens. A differing-output deterministic pair where one
        // side has no token stream → tokenizer check unavailable → genuine, never
        // a (false) tokenizer divergence.
        let a = run(backend: "ollama", promptSha: "p", inputTokens: [], output: "x")
        let b = run(backend: "llama.cpp", promptSha: "p", inputTokens: [1, 2, 3], output: "y")
        XCTAssertEqual(DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true), .genuineDivergence)
    }

    func testGenuineDivergence() {
        // Same prompt, both deterministic, no token confound, outputs still differ.
        let a = run(promptSha: "p", output: "x")
        let b = run(promptSha: "p", output: "y")
        XCTAssertEqual(DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true), .genuineDivergence)
    }

    // MARK: - S7: degenerate repetition length mismatch (overnight 2026-06-30 repro)

    func testDegenerateRepetitionLengthMismatch() {
        // The concrete overnight false positive: same GGUF, both backends
        // deterministic, identical repeating line, only the repeat COUNT
        // differs (Ollama 8x, llama.cpp 3x). Must NOT read as genuineDivergence.
        let unit = " The answer is in French.\n"
        let a = run(backend: "ollama", promptSha: "p", output: String(repeating: unit, count: 8))
        let b = run(backend: "llama.cpp", promptSha: "p", output: String(repeating: unit, count: 3))
        XCTAssertEqual(
            DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true),
            .degenerateRepetitionLengthMismatch
        )
    }

    func testDegenerateRepetitionToleratesPartialFinalRepeat() {
        // A generation cut short mid-unit by a token/length cap still counts as
        // the same repeating pattern.
        let unit = "Paris. "
        let a = run(promptSha: "p", output: String(repeating: unit, count: 5))
        let b = run(promptSha: "p", output: String(repeating: unit, count: 2) + "Par")
        XCTAssertEqual(
            DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true),
            .degenerateRepetitionLengthMismatch
        )
    }

    func testDifferentRepeatingUnitsAreStillGenuineDivergence() {
        // Both outputs are degenerate repetitions, but of DIFFERENT content — a
        // real content difference, not merely a stopping-length artifact.
        let a = run(promptSha: "p", output: String(repeating: "apple ", count: 5))
        let b = run(promptSha: "p", output: String(repeating: "orange ", count: 5))
        XCTAssertEqual(
            DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true),
            .genuineDivergence
        )
    }

    func testNonRepeatingOutputsAreStillGenuineDivergence() {
        // Neither output is degenerate at all — must fall through to the
        // ordinary genuineDivergence bucket, unaffected by the new check.
        let a = run(promptSha: "p", output: "The capital of France is Paris.")
        let b = run(promptSha: "p", output: "The capital of France is Lyon, actually.")
        XCTAssertEqual(
            DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true),
            .genuineDivergence
        )
    }

    func testPromptDivergenceOutranksDegenerateRepetitionShape() {
        // Cascade ordering: even when both outputs share a repeating unit, a
        // failed same-bytes control must still win — the comparison itself is
        // invalid, so no downstream refinement (including this one) applies.
        let unit = "loop "
        let a = run(promptSha: "p1", output: String(repeating: unit, count: 8))
        let b = run(promptSha: "p2", output: String(repeating: unit, count: 3))
        XCTAssertEqual(
            DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true),
            .promptDivergence
        )
    }

    func testSamplerMismatchOutranksDegenerateRepetitionShape() {
        // Cascade ordering: an unequal sampler still explains the difference
        // before the repetition-shape refinement is ever consulted.
        let unit = "loop "
        let a = run(promptSha: "p", output: String(repeating: unit, count: 8), sampler: SamplerConfig(temperature: 0.0))
        let b = run(promptSha: "p", output: String(repeating: unit, count: 3), sampler: SamplerConfig(temperature: 0.7))
        XCTAssertEqual(
            DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true),
            .samplerMismatch
        )
    }

    func testIndeterminateOutranksDegenerateRepetitionShape() {
        // Cascade ordering: an unassessed leg still yields indeterminate before
        // the repetition-shape refinement is consulted.
        let unit = "loop "
        let a = run(promptSha: "p", output: String(repeating: unit, count: 8))
        let b = run(promptSha: "p", output: String(repeating: unit, count: 3))
        XCTAssertEqual(
            DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true,
                                      aWasAssessed: false, bWasAssessed: true),
            .indeterminate
        )
    }

    // MARK: - DegenerateRepetition (unit-level)

    func testRepeatingUnitFindsShortestPeriod() {
        XCTAssertEqual(DegenerateRepetition.repeatingUnit(of: "abcabcabc"), "abc")
        XCTAssertEqual(DegenerateRepetition.repeatingUnit(of: "aaaaaa"), "a")
    }

    func testRepeatingUnitAllowsPartialFinalRepeat() {
        XCTAssertEqual(DegenerateRepetition.repeatingUnit(of: "abcabcab"), "abc")
    }

    func testRepeatingUnitNilForNonRepeatingText() {
        XCTAssertNil(DegenerateRepetition.repeatingUnit(of: "The capital of France is Paris."))
        XCTAssertNil(DegenerateRepetition.repeatingUnit(of: "AAAB"))
    }

    func testRepeatingUnitNilForTextTooShortToRepeatTwice() {
        XCTAssertNil(DegenerateRepetition.repeatingUnit(of: ""))
        XCTAssertNil(DegenerateRepetition.repeatingUnit(of: "x"))
        XCTAssertNil(DegenerateRepetition.repeatingUnit(of: "ab"), "a period must repeat at least twice")
    }

    func testIsRepetitionLengthMismatchRequiresIdenticalUnit() {
        XCTAssertTrue(DegenerateRepetition.isRepetitionLengthMismatch(
            String(repeating: "ab", count: 5), String(repeating: "ab", count: 2)
        ))
        XCTAssertFalse(DegenerateRepetition.isRepetitionLengthMismatch(
            String(repeating: "ab", count: 5), String(repeating: "cd", count: 5)
        ))
        XCTAssertFalse(DegenerateRepetition.isRepetitionLengthMismatch(
            "The capital of France is Paris.", "The capital of France is Lyon."
        ))
    }

    // MARK: - S2/S3: indeterminate + identical-gating

    func testIndeterminateWhenOutputsDifferAndLegUnassessed() {
        // S2: outputs differ but a leg was never assessed (< 2 repeats) → its
        // reproducibility is unknown, so this is NOT a confirmed genuineDivergence.
        let a = run(promptSha: "p", output: "x")
        let b = run(promptSha: "p", output: "y")
        XCTAssertEqual(
            DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true,
                                      aWasAssessed: false, bWasAssessed: true),
            .indeterminate
        )
    }

    func testIndeterminateWhenOutputsMatchButLegUnassessed() {
        // S3: matching outputs are only "identical" when both legs are
        // assessed-reproducible. An unassessed leg → indeterminate, not a false pass.
        let a = run(promptSha: "p", output: "same")
        let b = run(promptSha: "p", output: "same")
        XCTAssertEqual(
            DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true,
                                      aWasAssessed: true, bWasAssessed: false),
            .indeterminate
        )
    }

    func testIdenticalRequiresBothLegsReproducible() {
        // S3: matching outputs while a leg is observed non-reproducible is luck, not
        // a clean pass → samplerNondeterminism, never identical.
        let a = run(promptSha: "p", output: "same")
        let b = run(promptSha: "p", output: "same")
        XCTAssertEqual(
            DivergenceTriage.classify(a, b, aIsDeterministic: false, bIsDeterministic: true),
            .samplerNondeterminism
        )
    }

    func testCompareSingleRepeatDifferingOutputsIsIndeterminate() {
        // The concrete S2 bug: --repeats 1 makes isDeterministic vacuously true, so
        // a single-repeat pair whose outputs differ must NOT yield genuineDivergence.
        let ollama = DeterminismReport(runs: [run(backend: "ollama", promptSha: "p", output: "x")])
        let llama = DeterminismReport(runs: [run(backend: "llama.cpp", promptSha: "p", output: "y")])
        let record = DifferentialRecord.compare(ollama, llama)
        XCTAssertEqual(record?.divergence, .indeterminate, "single-repeat differing outputs → indeterminate, not genuine")
    }

    // MARK: - S6: sampler-mismatch confound

    func testSamplerMismatchWhenSamplersDiffer() {
        // Outputs differ, tokens unavailable, both reproducible — but the legs ran
        // under different temperatures → the difference is config, not the model.
        let a = run(promptSha: "p", output: "x", sampler: SamplerConfig(temperature: 0.0))
        let b = run(promptSha: "p", output: "y", sampler: SamplerConfig(temperature: 0.7))
        XCTAssertEqual(
            DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true),
            .samplerMismatch
        )
    }

    func testSamplerMismatchDoesNotFireWhenOutputsMatch() {
        // Equal outputs are not actionable regardless of sampler — identical wins.
        let a = run(promptSha: "p", output: "same", sampler: SamplerConfig(temperature: 0.0))
        let b = run(promptSha: "p", output: "same", sampler: SamplerConfig(temperature: 0.7))
        XCTAssertEqual(
            DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true),
            .identical
        )
    }

    func testGenuineDivergenceRequiresSamplerAgreement() {
        // Same sampler on both legs is a precondition for genuineDivergence.
        let a = run(promptSha: "p", output: "x", sampler: SamplerConfig(temperature: 0.0, repeatPenalty: 1.1))
        let b = run(promptSha: "p", output: "y", sampler: SamplerConfig(temperature: 0.0, repeatPenalty: 1.1))
        XCTAssertEqual(
            DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true),
            .genuineDivergence
        )
    }

    func testIdenticalWinsOverBenignTokenDifference() {
        // Outputs match but token streams differ → identical (a tokenizer diff that
        // produces identical output is not actionable).
        let a = run(backend: "llama.cpp", promptSha: "p", inputTokens: [1, 2, 99], output: "same")
        let b = run(backend: "llama2.cpp", promptSha: "p", inputTokens: [1, 2, 3], output: "same")
        XCTAssertEqual(DivergenceTriage.classify(a, b, aIsDeterministic: true, bIsDeterministic: true), .identical)
    }

    // MARK: - DeterminismReport

    func testDeterminismStable() {
        let report = DeterminismReport(runs: [run(output: "x"), run(output: "x"), run(output: "x")])
        XCTAssertTrue(report.isDeterministic)
        XCTAssertTrue(report.wasAssessed)
        XCTAssertEqual(report.distinctOutputs, ["x"])
        XCTAssertEqual(report.repeatCount, 3)
    }

    func testDeterminismVariant() {
        // First-run cold-load outlier then steady state — variance surfaced, ordered.
        let report = DeterminismReport(runs: [run(output: "cold"), run(output: "warm"), run(output: "warm")])
        XCTAssertFalse(report.isDeterministic)
        XCTAssertEqual(report.distinctOutputs, ["cold", "warm"])
    }

    func testRepresentativeIsModalNotColdFirstRun() {
        // S1: a cold-load outlier as the first run must NOT become the
        // representative — the steady-state (modal) output wins, so a stable-warm
        // leg isn't downgraded by its cold run.
        let report = DeterminismReport(runs: [run(output: "cold"), run(output: "warm"), run(output: "warm")])
        XCTAssertEqual(report.representative?.output, "warm")
    }

    func testRepresentativeFallsBackToFirstWhenAllDistinct() {
        let report = DeterminismReport(runs: [run(output: "a"), run(output: "b"), run(output: "c")])
        XCTAssertEqual(report.representative?.output, "a", "all-distinct ties resolve to the earliest run")
    }

    func testDeterminismNotAssessedWithOneRun() {
        let report = DeterminismReport(runs: [run(output: "x")])
        XCTAssertTrue(report.isDeterministic, "vacuously true with one sample")
        XCTAssertFalse(report.wasAssessed, "one sample cannot observe determinism")
    }

    func testDeterminismHarnessCollectsRuns() async throws {
        let report = try await DeterminismHarness.measure(repeats: 3) { index in
            self.run(output: "out", repeatIndex: index)
        }
        XCTAssertEqual(report.runs.map(\.repeatIndex), [0, 1, 2])
    }

    func testDeterminismHarnessRejectsZeroRepeats() async {
        do {
            _ = try await DeterminismHarness.measure(repeats: 0) { _ in self.run() }
            XCTFail("expected invalidRepeats")
        } catch {
            XCTAssertEqual(error as? DifferentialError, .invalidRepeats(0))
        }
    }

    // MARK: - Cohort

    func testCohortSameWeightsOnEqualModelAndQuant() {
        // Same model identity ("m" for both, via the builder default) AND equal quant
        // (case-insensitive) → sameWeights.
        let a = run(backend: "ollama", model: "m", quant: "Q4_K_M")
        let b = run(backend: "llama.cpp", model: "m", quant: "q4_k_m")  // case-insensitive
        XCTAssertEqual(Cohort.classify(a, b), .sameWeights)
    }

    func testCohortDifferentModelSameQuantIsNotSameWeights() {
        // S4: equal quant alone must NOT claim sameWeights — two unrelated Ollama
        // models both report quant "server", which would falsely fuse them into the
        // only strong oracle. Differing model drops the pair to sameFamily.
        let a = run(backend: "ollama", model: "llama3.1-8b:latest", quant: "server")
        let b = run(backend: "ollama", model: "qwen2.5-7b:latest", quant: "server")
        XCTAssertEqual(Cohort.classify(a, b), .sameFamily)
    }

    func testCohortSameFamilyOnDifferentQuant() {
        let a = run(backend: "llama.cpp", model: "m", quant: "Q4_K_M")
        let b = run(backend: "mlx", model: "m", quant: "4bit")
        XCTAssertEqual(Cohort.classify(a, b), .sameFamily)
    }

    func testCohortCloudWhenEitherBackendIsCloud() {
        let a = run(backend: "anthropic-claude", quant: "Q4_K_M")
        let b = run(backend: "ollama", quant: "Q4_K_M")
        XCTAssertEqual(Cohort.classify(a, b), .cloud)
    }

    // MARK: - DifferentialRecord

    func testCompareBuildsRecordWithTriageAndCohort() {
        // Two assessed (>= 2), reproducible legs with the same model + quant but
        // differing output → a genuine cross-backend divergence in the sameWeights
        // cohort.
        let ollama = DeterminismReport(runs: [
            run(backend: "ollama", quant: "server", promptSha: "p", output: "x"),
            run(backend: "ollama", quant: "server", promptSha: "p", output: "x"),
        ])
        let llama = DeterminismReport(runs: [
            run(backend: "llama.cpp", quant: "server", promptSha: "p", output: "y"),
            run(backend: "llama.cpp", quant: "server", promptSha: "p", output: "y"),
        ])
        let record = DifferentialRecord.compare(ollama, llama)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.divergence, .genuineDivergence)
        XCTAssertEqual(record?.cohort, .sameWeights, "equal model + quant → sameWeights")
    }

    func testCompareHonorsCohortOverride() {
        let ollama = DeterminismReport(runs: [run(backend: "ollama", quant: "server", promptSha: "p", output: "x")])
        let llama = DeterminismReport(runs: [run(backend: "llama.cpp", quant: "Q4_K_M", promptSha: "p", output: "x")])
        // Quant differs (Ollama hides it) → heuristic says sameFamily, but operator
        // pinned the same GGUF, so they declare sameWeights.
        let record = DifferentialRecord.compare(ollama, llama, cohortOverride: .sameWeights)
        XCTAssertEqual(record?.cohort, .sameWeights)
    }

    func testCompareReturnsNilOnEmptyBatch() {
        let empty = DeterminismReport(runs: [])
        let nonEmpty = DeterminismReport(runs: [run()])
        XCTAssertNil(DifferentialRecord.compare(empty, nonEmpty), "no data → no fabricated verdict")
    }

    // MARK: - Report rendering

    func testReportIsDeterministicAndCarriesVerdict() {
        let ollama = DeterminismReport(runs: [
            run(backend: "ollama", promptSha: "p", output: "x"),
            run(backend: "ollama", promptSha: "p", output: "x"),
        ])
        let llama = DeterminismReport(runs: [
            run(backend: "llama.cpp", promptSha: "p", output: "y"),
            run(backend: "llama.cpp", promptSha: "p", output: "y"),
        ])
        let record = DifferentialRecord.compare(ollama, llama)
        let outcome = DifferentialOutcome(promptSha256: "p", ollama: ollama, llama: llama, comparison: record)
        let first = DivergenceReport.render(outcome)
        let second = DivergenceReport.render(outcome)
        XCTAssertEqual(first, second, "report must be deterministic for a given outcome")
        XCTAssertTrue(first.contains("genuineDivergence"))
        XCTAssertTrue(first.contains("Prompt SHA-256"))
    }

    func testReportFlagsOllamaOnlyAsControl() {
        let ollama = DeterminismReport(runs: [run(output: "x"), run(output: "x")])
        let outcome = DifferentialOutcome(promptSha256: "p", ollama: ollama, llama: nil, comparison: nil)
        let report = DivergenceReport.render(outcome)
        XCTAssertTrue(report.contains("determinism control"), "Ollama-only run is a control, not a comparison")
    }
}
