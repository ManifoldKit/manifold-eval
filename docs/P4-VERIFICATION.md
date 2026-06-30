# P4 Replay-Regression Gate — Real-Model Verification

**Date:** 2026-06-30  
**Branch:** `feat/p4-replay-gate-draft` (draft PR #8 — do not merge without human sign-off)  
**Ran on:** Apple Silicon, macOS 26, Ollama 0.30.x, localhost:11434

---

> **Update 2026-06-30 — moat now wired.** This document records the original
> gate-logic verification on a *two-different-models* proxy. The replay-regression
> moat is now a live product feature: the `manifold-eval regress` subcommand drives
> `RegressionRunner` → `RegressionGate` → `RegressionReport`, the inert
> `RecordReDriver` protocol was deleted (the gate needs only a `RawRun` producer),
> and a genuine **same-model Q8-vs-Q4 cross-quant** verification lives in
> `RegressionCrossQuantLiveTests`. The "What this does NOT prove" section below has
> been updated accordingly.

## What was run

Two live Ollama model calls via `OllamaRawDriver` (`raw: true`, `temperature: 0`,
`repeatPenalty: 1.0`) on the prompt `"2 + 2 ="`. The `OllamaRawDriver` outputs are fed
directly to `RegressionGate.check` — the correct proof that the gate logic works
independent of how each `RawRun` is produced.

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

## What this (proxy) run does NOT prove — and where it's now covered

- **Same-model cross-quant parity.** This run used two *different models* (`llama3.1-8b`
  and `gemma3-4b`) as a proxy, so it proves the gate's verdict logic is model/quant-agnostic
  but not that it tracks a real re-quant. **Now covered** by `RegressionCrossQuantLiveTests`,
  which drives two quant tags of the *same* model (e.g. `…q8_0` vs `…q4_K_M`) through the real
  `RegressionRunner`/`OllamaRawDriver` path and asserts the verdict tracks the observed scores.
  Run it with `RUN_OLLAMA_LIVE=1 swift test --filter RegressionCrossQuantLiveTests` against two
  quant tags you have pulled. **The cross-quant credibility VERDICT (did the quants actually
  diverge, and is that drift or a genuine regression?) is the human-in-loop step** — the gate
  surfaces movement; it does not adjudicate it.

- **Byte-deterministic in-core re-drive.** The eval moat re-drives via the separate-process
  backend path (the once-per-process `llama_backend_init` rule forbids linking llama in this
  repo), so it does not exercise — nor need — the in-core `Replayer.runOnce` path. That path
  has its own genuine defects (it never seeds generation, hardcodes `repeatPenalty: 1.1`, and
  `ConfigSnapshot` carries no `topK`), tracked as the decoupled **P4-aux** `fix(fuzz):` work in
  ManifoldKit — independent of this moat.

- **Production scorer quality.** The verification scorers (`SubstringRegressionScorer`,
  `ExactMatchRegressionScorer`) are deterministic binary scorers. A production deployment would
  use a calibrated scorer (AST-match, IFEval verifier, semantic similarity) tuned to the task.

---

---

## Cross-quant verification (same-model Q8 vs Q4) — PASSED 2026-06-30

The genuine moat check the proxy run above could not provide: **two quantisations of
the SAME model** (`qwen2.5:0.5b-instruct-q8_0` vs `-q4_K_M`, pulled from Ollama), greedy
`temp=0`, via the `regress` subcommand. Quant is the only variable.

`RegressionCrossQuantLiveTests` (both tests **PASSED**): same-quant re-drive → `.stable`
(no false positive); the cross-quant verdict tracked the observed scores and was never
`.indeterminate`.

Survey across 15 probes (`regress --scorer contains`): the quants **agreed** on simple
facts/arithmetic (capital of Australia, atomic number of carbon, 23×19) → `.stable`, and
**diverged** on harder recall → `.moved`. The headline case — a real correctness loss from
re-quantising:

| Probe | q8_0 | q4_K_M | Verdict |
|-------|------|--------|---------|
| "The largest moon of Saturn is" (expect `Titan`) | **Titan** ✓ (1.0) | "Rhea … the answer is Saturn" ✗ (0.0) | **`.moved(delta -1.0)`** |
| "The capital of Kazakhstan is" (expect `Astana`) | ✗ (0.0) | ✓ (1.0) | `.moved(+1.0)` |
| "The largest moon of Saturn is" | — | — | exit code **1** |

The `REGRESSION.md` the gate emitted for the Titan case (note the built-in caveat):

```
## Verdict
- verdict: **moved (delta -1.0000)**
> Score moved by -1.0000 beyond threshold. **Movement is not automatically a
> regression** — a re-quant can legitimately shift output. This flags the cell
> for a human to judge quant drift vs genuine correctness loss.

## Baseline  (q8_0, score 1.0000)
- output: ` … it is called Titan. Titan is a moon of Saturn …`
## Re-driven (q4_K_M, score 0.0000)
- output: ` … the largest moon of Saturn is Rhea. … Therefore, the answer is Saturn.`
```

**Credibility verdict: PASSED.** On real same-model cross-quant runs the gate (a) detects a
genuine correctness regression a re-quant introduced, (b) holds `.stable` where the quants
agree, (c) faithfully tracks the scores, and (d) emits a deterministic, human-readable report
that surfaces — not adjudicates — the movement. The moat does what it claims.

Reproduce: `ollama pull qwen2.5:0.5b-instruct-q8_0 qwen2.5:0.5b-instruct-q4_K_M`, then
`RUN_OLLAMA_LIVE=1 swift test --filter RegressionCrossQuantLiveTests`, or drive any probe via
`manifold-eval regress --backend ollama --baseline-model …q8_0 --redriven-model …q4_K_M
--prompt-file P --expected REF`.

---

## How to reproduce (original proxy run)

```bash
# Requires Ollama at localhost:11434 with llama3.1-8b:latest and gemma3-4b:latest pulled.
cd /path/to/manifold-eval  # or the p4-verify worktree
RUN_OLLAMA_LIVE=1 swift test --filter RegressionGateLiveTests
```

Expected output: both tests PASS in ~16 seconds total.
