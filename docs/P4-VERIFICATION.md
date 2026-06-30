# P4 Replay-Regression Gate — Real-Model Verification

**Date:** 2026-06-30  
**Branch:** `feat/p4-replay-gate-draft` (draft PR #3 — do not merge without human sign-off)  
**Ran on:** Apple Silicon, macOS 26, Ollama 0.30.x, localhost:11434

---

## What was run

Two live Ollama model calls via `OllamaRawDriver` (`raw: true`, `temperature: 0`,
`repeatPenalty: 1.0`) on the prompt `"2 + 2 ="`. The `RecordReDriver` seam is bypassed
intentionally — `OllamaRawDriver` outputs are fed directly to `RegressionGate.check`, which
is the correct proof that the gate logic works independent of the re-driver plumbing.

Scorer: `ContainsRegressionScorer(expected: "4")` — returns `1.0` if the output contains
the string `"4"`, else `0.0`. Binary scoring makes threshold-boundary false verdicts
impossible (delta is always 0.0 or ±1.0, far outside the 0.05 threshold).

---

## Moved pair — gate detects movement

| Leg | Model | Raw output (prefix, 80 chars) | Score |
|-----|-------|-------------------------------|-------|
| Baseline | `llama3.1-8b:latest` | ` 4. This is a basic arithmetic equation…` OR ` ? (Answer: 4)…` | **1.0** |
| Re-driven | `gemma3-4b:latest` | ` ?\n\nWhat is the capital of France?\n\nWhich planet is known as…` | **0.0** |

- `baselineScore` = **1.0** (llama3.1 reliably includes "4" across all observed variants)
- `reDrivenScore` = **0.0** (gemma3-4b enters question-listing mode in raw completion)
- `delta` = 0.0 − 1.0 = **−1.0**
- `threshold` = 0.05
- **Verdict: `.moved(delta: -1.0)`** ✓

**Test result (2026-06-30):** `testMovedPairDetectsRealModelDifference` **PASSED** (10.05 s)

---

## Stable pair — no false positive

| Leg | Model | Raw output (prefix, 80 chars) | Score |
|-----|-------|-------------------------------|-------|
| Baseline | `gemma3-4b:latest` | ` ?\n\nWhat is the capital of France?\n\nWhich planet is known as…` | **0.0** |
| Re-driven | `gemma3-4b:latest` | ` ?\n\nWhat is the capital of France?\n\nWhich planet is known as…` | **0.0** |

- `baselineScore` = **0.0**
- `reDrivenScore` = **0.0**
- `delta` = **0.0**
- `threshold` = 0.05
- **Verdict: `.stable`** ✓

`gemma3-4b:latest` is byte-identical at `temperature=0` — confirmed across three
consecutive runs before writing this test. The stable pair exploits this property:
using the same deterministic model for both legs guarantees identical scores.

**Test result (2026-06-30):** `testStablePairProducesNoFalsePositive` **PASSED** (6.03 s)

---

## What this proves

1. **Gate detects movement:** `RegressionGate.check` returns `.moved(delta: -1.0)` when the
   re-driven run comes from a different model whose output quality is measurably lower under
   the scorer. The gate's threshold arithmetic, delta computation, and scorer-injection seam
   all work correctly on real (not mocked) model outputs.

2. **No false positive on stable:** when the same deterministic model is re-run on the same
   prompt, the gate returns `.stable`. The prompt-hash invariant holds (both runs hash to the
   same `promptSha256` because the prompt string is identical), and the score is stable.

3. **Prompt-hash invariant enforced:** the test explicitly asserts `baseline.promptSha256 ==
   reDriven.promptSha256` before calling the gate, confirming the gate's load-bearing guarantee
   is satisfied by the OllamaRawDriver's `PromptHash.sha256Hex` path.

---

## What this does NOT prove

- **True byte-deterministic cross-quant re-drive.** `RecordReDriver` is intentionally stubbed.
  No production `RecordReDriver` implementation exists. Wiring requires:
  1. Extracting `Replayer.runOnce` from ManifoldFuzz as an injectable function.
  2. Fixing config-lossy plumbing (`repeatPenalty`, `seed`, `topK` not threaded through).
  3. A manifold-llama lockstep PR exposing the re-drive entry point.
  See `Sources/ManifoldEval/Replay/RecordReDriver.swift` for the full unblocking checklist.

- **Cross-quant parity.** No two quants of the same model were available in Ollama. Two
  different models (`llama3.1-8b` and `gemma3-4b`) served as a proxy for the cross-quant
  scenario. The gate logic is model/quant-agnostic — the proof of gate-logic correctness
  is sound regardless of the source of the score difference.

- **Production scorer quality.** `ContainsRegressionScorer` is a verification-only binary
  scorer. A production deployment would use a calibrated scorer (exact-match, AST-match,
  IFEval verifier, etc.) tuned to the evaluation task.

---

## How to reproduce

```bash
# Requires Ollama at localhost:11434 with llama3.1-8b:latest and gemma3-4b:latest pulled.
cd /path/to/manifold-eval  # or the p4-verify worktree
RUN_OLLAMA_LIVE=1 swift test --filter RegressionGateLiveTests
```

Expected output: both tests PASS in ~16 seconds total.
