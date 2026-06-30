# Origins — why `manifold-eval` exists

> Heritage record for the independent assurance repo. The *what* and *how* live in the
> [README](../README.md) and in ManifoldKit's `docs/plans/manifold-eval-repo-v2-override.md`.
> This document captures the *why* — the decision history that produced the repo — because the
> most valuable thing to carry across a repo split is the reasoning, and reasoning doesn't survive
> in code.

This repo was not a greenfield decision. It was **earned** over ~3 weeks of work inside
ManifoldKit that built the assurance machinery in-place first, proved it on real model data, had a
dedicated-repo proposal *rejected*, and was split out only once a **governance** rationale — not
convenience — justified the boundary. The arc runs through three rejections and one override. Each
rejection sharpened the design; the override won not by refuting the rejections but by reframing the
question they answered.

---

## 0. The bug that started it

Before any repo was proposed, a concrete defect exposed the gap. A cross-backend tool-call soak
showed the **same Mistral-v0.3 weights producing different verdicts** across Ollama, llama.cpp, and
MLX. That alone is the founding insight: **tool-calling is a property of the
`(model × quant × backend × renderer)` cell, not of the model.** The same weights can pass on one
runtime and emit nothing on another.

Worse: the automated scorer was *wrong*. The llama.cpp Mistral cell dispatched the correct tool on
every scenario yet scored `toolTP=0, toolFP=1, F1=0.000`. A **human had to override the verdict by
hand**, reading the raw JSONL transcript to see the calls were correct. That single fact — *the
grader was wrong and only a human caught it* — became the moral anchor of everything that followed.
It is why this repo's central design value is **divergence triage to focus human attention, not
automatic bug detection**, and why the human transcript spot-check is a permanent design
requirement, never to be automated away.

---

## 1. The dedup play, rejected (#1993)

The first proposal was a pure **deduplication** argument: two downstream apps had each built eval /
replay infrastructure on ManifoldKit backends, and the kit had no eval layer — so extract a shared
`ManifoldEval` companion.

Three adversarial reviewers killed it (2026-06-21):

- **The dedup premise was false.** The two apps' harnesses shared no shape — one scored a live
  object graph at checkpoint time, the other an offline windowed log. A generic
  `EvalScorer(output:expected:)` would be a fake conformance for both. Net cross-app deletion was
  **~71 LOC** — far below the bar for a new module's permanent CI cost. *Revisit at N=3.*
- **Most of the harness already existed** in ManifoldKit (capture / replay / hygiene detectors). The
  only genuinely missing piece was scoring math.

But the rejection **carved out a door**: a *product*-motivated on-device eval opportunity that the
Python-centric incumbents (Inspect AI, promptfoo, OpenAI Evals, lm-eval-harness, HELM) under-serve —
to be pursued on its own merits, *never* on dedup grounds. That became #1997.

---

## 2. The product reframing (#1997)

#1997 reframed eval as a **product** with a defensible moat no cloud-first framework can reproduce.
Every incumbent is cloud-first and non-deterministic by default; ManifoldKit is on-device, Swift,
local-first, and already ships the spine. The genuinely ownable card:

> **Deterministic local-replay regression** — byte-exact re-run of a captured local-model session,
> then assert the score didn't move. A CI gate answering: *"did re-quantizing / upgrading the GGUF
> change correctness?"* No incumbent offers this.

This **replay-regression moat** is the reason a separate repo eventually earned its keep (see §6).

---

## 3. The tool-call tributary — "assess, don't declare" (#2001 → #2005)

A parallel thread forged the epistemics the eval rests on. A host app wanted to steer users toward
models that actually tool-call, and asked for a **static capability flag** on the model-info type
(#2001). That was rejected and superseded (#2005) on a principle that is now load-bearing here:

> Whether a model genuinely tool-calls is **irreducibly empirical** — a property of weights, knowable
> only by *measurement*, not derivable from any static signal. (A base model can ship the identical
> tool-aware template as its instruct sibling; quantization can degrade a real tool-caller below
> usable.) So you build a **continuously-populated conformance matrix**, and the off-diagonal —
> *template says yes, soak says no* — **is the work backlog.**

"Assess, don't declare" is the same discipline the differential oracle now rests on. BFCL AST-track
conformance later became the first live consumer of the eval scorer surface (§5).

---

## 4. The in-place consolidation — the foundation (#2041–#2047)

Here a dedicated `manifold-eval` repo was first **proposed and rejected** by three reviewers
(architecture / methodology / pragmatism). The rejection grounds matter, because the override later
had to answer every one:

1. **Package cycle.** Both companions already depend on the published `ManifoldTools` library;
   lifting the corpus/scorer up into a new repo would invert that edge into a cycle.
2. **"One process importing all backends" is unbuildable.** `llama_backend_init` is once-per-process,
   MLX needs serialized in-process Metal, and there is a known dual-engine hazard. Collation must be
   over **separate-process** records.
3. **A repo with no owner rots.** The documented fuzz-cadence collapse (per-PR → nightly → weekly →
   hand-run → silence) is the precedent.
4. **Methodology.** A cross-backend divergence is confounded without a **same-bytes control** (quant
   *and* checkpoint *and* renderer all differ at once); auto-rendering the matrix removes the human
   read that caught the scorer bug; there was no determinism pinning.

Verdict: *"the consolidation is worth doing; a 4th repo is the wrong unit and the headline
justifications are false."* It shipped as **six in-place PRs** — the machinery this repo now imports:

| PR | Shipped | Why it matters here |
|----|---------|---------------------|
| **#2041** | `ConformanceRecord` + `CellStatus` schema | `notMeasured` made a **first-class state** — a missing GGUF / offline backend never reads as a measured `fail`. *Absence ≠ regression.* |
| **#2042** | Corpus loads from `Bundle.module`, not CWD | Kills companion vendoring-drift. |
| **#2043** | **Scorer TP-attribution bug fix** | The headline defect: the recovery matched only backtick-quoted required-tool tokens, so a correct call scored as a false positive. The cell a human had hand-corrected now scores correctly through the automated pipeline (F1 0.000 → 0.810). |
| **#2045** | `ConformanceScorer.records(...)` public API | Absence-aware: unreadable → `loadFail`, empty → `notMeasured`. Never a dropped row or a measured zero. |
| **#2046** | `MatrixRenderer` + `matrix` CLI | The matrix becomes a deterministic rendered query over records. Holes render as distinct reasons, never a fake `0.000`; the cross-runtime view **explicitly labels** that a verdict difference is *not, on its own, a backend bug*. |
| **#2047** | Verdict bands on aggregate F1, not dominant failure subtype | A 0.750-F1 cell had been mislabeled by its most-common *failure* subtype, eroding matrix trust. |

The validation headline (#2048): the exact transcript the overnight run wrongly reported as
**F1=0.000 now scores F1=0.810** through the automated path — no human JSONL read needed. Within-run
repeats were bit-identical, proving the earlier ~0.1 F1 swings were **cross-environment drift, not
per-call noise** — the first concrete win for determinism discipline. A later cleanup
(net **+575 / −14,978 lines**) established the convention that **the rendered `MATRIX.md` *is* the
artifact** — raw scratch never returns to git.

Then **BFCL argument-level scoring** (#2057) expanded the mission from "did it call the right
*function*" to "did it pass the right *arguments*" — and proved cross-backend differential signal is
real: the same model scored **92% name-only vs 32% AST**, and **32% (Ollama) vs 64% (llama.cpp)** on
tool-call handling alone.

---

## 5. The on-device scorer surface, and the #2064 lesson (#2067)

The scorer surface (`Score` / `ScoreValue` / `EvalScorer` / `SemanticSimilarityScorer`) was built
**in-core first** so this repo would *consume* it, never fork it. It shipped with **BFCL adoption as
its live in-repo consumer** — and that was deliberate, applying the **#2064 lesson**:

> **A read path with no writer is dead code.** A feature that exists but isn't wired is worse than
> none: it reads as covered when it isn't.

So every `ScoreValue` case shipped with a live consumer; the surface is provably not inert
scaffolding. Two principled refusals came with it: the replay-regression moat was **moved out** to a
cross-repo follow-up (an in-core regression test is *green by construction* — deterministic replay ⇒
identical bytes ⇒ a stability assertion is tautological; the scorer only earns its keep when bytes
*differ*, which only happens cross-repo), and the existing set-valued conformance scorer was **left
as-is** rather than forced into one `ScoreValue` (that would be a fake conformance).

---

## 6. The override — governance, not convenience

The maintainer overrode the in-place verdict (2026-06-29) — **not by disputing its technical
findings** (the six in-place PRs stay shipped and are this repo's foundation) but by introducing a
rationale the original review never weighed:

> **Separation of implementation from assurance.** ManifoldKit is optimized for *developer utility*
> — fast iteration, ergonomic surface. The eval repo is optimized for *assurance* — reproducible,
> deterministic, adversarial verdicts. These are different optimization targets, and the repo
> boundary is deliberately made the **governance boundary** between them. "Inline is technically
> simpler" is true and beside the point.

Two pillars:

1. **Independence reduces self-grading bias.** The rejection's sharpest worry was rubber-stamping —
   auto-verdicts removing the human who caught the scorer bug. An assurance authority with its own
   owner and an adversarial mandate is structurally less prone to bless its own code than evals
   living beside it. *Separation improves verdict credibility; it isn't only tidiness.*
2. **Precedented.** Independent conformance suites are how trusted ecosystems do it — `test262`,
   `web-platform-tests`, the Khronos Vulkan CTS, SQLite's separate TH3. All sit outside the
   implementation repo on purpose. What's distinctive here is applying the pattern to a Swift
   **on-device** LLM kit, not the pattern itself.

The override **answers each original rejection reason** as a hard design constraint rather than
waving it away:

- **Cycle** → dissolved by an *ownership rule*: this repo is strictly top-of-graph (a DAG diamond)
  and **owns nothing** companions consume. The corpus, `ConformanceScorer`, `ConformanceRecord`,
  `MatrixRenderer`, and `ASTMatcher` **stay in `ManifoldTools`** and are imported, never moved.
- **One-process** → accepted in full; the repo is a *separate-process orchestrator + collator*.
- **Rot** → answered by a named owner + a fixed Apple-Silicon cadence + a CI **rot-guard** that fails
  if the last successful run is stale or the evaluated cell-manifest shrank. Staleness becomes a red
  check, not silence. *This is a dependency, not an escape: an assurance repo that lags the
  implementation is worse than none, because stale assurance reads as a passing grade.*

The split then executed fast, gated on a **falsifiable credibility test**: if the same-bytes
differential didn't produce a trustworthy signal, *stop* and fall back to the in-place path. It
passed — the **same Qwen3-0.6B GGUF on Ollama and llama.cpp produced byte-identical deterministic
output, classified `identical`** — proving the differential oracle works before any further build-out.

---

## Principles inherited from this history (binding)

These were forged in the arc above and should survive in every line of this repo:

1. **Assess, don't declare.** Capability is empirical — measured per `(model × quant × backend ×
   renderer)` cell, never asserted from a static flag. (#2005)
2. **Divergence ≠ bug without a same-bytes control.** Hold quant + checkpoint constant (identical
   GGUF on both runtimes) before any cross-backend delta is load-bearing. Classify every divergence
   (`identical` / `promptDivergence` / `samplerNondeterminism` / `tokenizerDivergence` /
   `genuineDivergence`); only the last is a bug candidate. The triage exists to **focus human
   attention**, not to auto-detect bugs.
3. **Absence ≠ failure.** A missing model is `notMeasured`, guarded against ever reading as a
   regression. (#2041)
4. **Determinism, pinned and reported.** Greedy / `temp=0`, fixed seed where supported; report
   variance over N repeats, never means-only. A re-drive that isn't bit-identical for identical
   config makes any regression gate cry wolf.
5. **Cloud is a sanity check, never an oracle.** Nondeterministic and over the network — absolute
   score only, never in a differential cohort.
6. **A read path with no live consumer is dead code.** Every surface ships with a real consumer that
   exercises it. (#2064)
7. **Keep the human in the loop.** The transcript spot-check caught the founding scorer bug; auto-
   rendering must never remove it.
8. **No owner, no repo.** Independence only improves credibility with a committed owner + cadence +
   rot-guard. Without them, this is the fuzz outcome with extra steps.

---

## The through-line

Every artifact this repo depends on was built, bug-fixed, and proven **in-place inside ManifoldKit
first** — the normalized record, the corpus loader, the corrected scorer, the public scoring API,
the matrix renderer, the BFCL AST scorer, and the on-device scorer surface. The repo was split out
only after (a) the data shapes were stable and shared via a published library, (b) a real
cross-backend differential signal was demonstrated, and (c) a **governance** rationale — assurance
independence, to reduce self-grading bias, in the lineage of test262 / Vulkan CTS / SQLite TH3 —
superseded the original "stay in-place" verdict.

The recurring discipline across all of it: **absence ≠ failure, divergence ≠ bug without a same-bytes
control, and a read path with no live consumer is dead code.**

### Source records

- ManifoldKit `docs/plans/1993-eval-surface.md` — the dedup play + field survey (rejected)
- ManifoldKit `docs/plans/1997-on-device-eval.md` — the product reframing + replay-moat reasoning
- ManifoldKit `docs/plans/manifold-eval-repo.md` — the dedicated-repo rejection + the six in-place PRs
- ManifoldKit `docs/plans/manifold-eval-repo-v2-override.md` — the override + phasing (system-of-record)
- In-place PRs: #2027 #2030 #2033 #2034 (conformance spine) · #2041–#2047 (consolidation) · #2057 (BFCL) · #2067 (scorer surface)
- Issues: #1993 (dedup, rejected) · #1997 (product reframing) · #2001 → #2005 (assess-don't-declare)
