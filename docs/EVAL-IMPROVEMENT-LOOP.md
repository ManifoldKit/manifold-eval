# The eval-driven improvement loop

> Operational one-pager for the continuous improvement loop the maintainer runs for the ManifoldKit
> family. The *why* lives in [ORIGINS.md](ORIGINS.md); the *vocabulary* in [CONCEPTS.md](CONCEPTS.md);
> the *CLI reference* in the [README](../README.md) — which also explains
> [how the commands relate as a suite](../README.md#how-the-suite-fits-together). This is the *loop*
> — how the evals feed a continuous improvement pipeline.

**Purpose:** turn cross-runtime eval evidence into green-CI-verified fixes in the core, cycle after
cycle, back-to-back and clock-agnostic.

**Mental model:** `manifold-eval` is a **sensor** — it emits evidence (typed divergences, regression
exit codes, a cross-runtime matrix) and **never fixes anything, never declares a bug on its own.** A
**human triage gate** is the adjudicator: it decides which signals are real. A scout→implement→review→merge
**pipeline** in the ManifoldKit / companion repos is the engine that turns triaged findings into PRs.
The gap between *signal* and *declared bug* is deliberate — it is the seam where a human caught the
founding scorer bug (F1=0.000 on a correct cell), and it must never be automated away.

---

## The loop

```
   ┌────────────────────────────────────────────────────────────────────────────┐
   │  SENSOR — manifold-eval (separate-process orchestrator, opt-in, never CI)   │
   │                                                                             │
   │   bfcl-generate  ifeval-generate  mteb   ──▶  per-backend ConformanceRecords │
   │        diff (same-bytes cross-backend)   ──▶  typed divergence + exit code   │
   │        regress (two-quant replay)        ──▶  stable/moved exit code         │
   │        collate                           ──▶  MATRIX.md (cross-runtime)      │
   └───────────────────────────────────┬────────────────────────────────────────┘
                                        │ evidence only
                                        ▼
   ┌────────────────────────────────────────────────────────────────────────────┐
   │  HUMAN TRIAGE GATE  (permanent — never automated away)                       │
   │                                                                             │
   │   genuineDivergence ─────────────────────────────▶  BUG CANDIDATE → backlog  │
   │   real regression (moved, not quant-drift) ──────▶  BUG CANDIDATE → backlog  │
   │   notMeasured / samplerNondeterminism /                                       │
   │   promptDivergence / tokenizerDivergence ────────▶  NOT backlog (discard)     │
   └───────────────────────────────────┬────────────────────────────────────────┘
                                        │ triaged backlog
                                        ▼
   ┌────────────────────────────────────────────────────────────────────────────┐
   │  ENGINE — improvement pipeline (ManifoldKit / companion repos, worktrees)    │
   │                                                                             │
   │   Preflight → Scout(backlog = eval findings) ∥ Soak(eval lanes = live obs.)  │
   │            → Implement (parallel git worktrees) → skeptical Review           │
   │            → Merge-gate (serial, green-CI-only) → Retro                       │
   └───────────────────────────────────┬────────────────────────────────────────┘
                                        │ merged fix changes the CORE binary
                                        ▼
                    core-bump.yml bumps manifold-eval's exact core pin
                                        │
                                        ▼
        next cycle re-runs the SAME lanes ──▶ did the cell move? ──┐
                                        ▲                          │
                                        └──────────────────────────┘
                        (this feedback edge is what makes it a LOOP, not a report)
```

---

## Per-cycle checklist

Lanes drive **local models on Apple Silicon** (real GGUFs / Ollama) — opt-in, never hosted CI.

1. **Drive the sensor lanes.**
   ```sh
   swift run manifold-eval bfcl-generate  --ollama-model <tool-model>   ...   # → bfcl record
   swift run manifold-eval ifeval-generate --ollama-model <model>       ...   # → ifeval record
   swift run manifold-eval mteb            --ollama-model <embed-model>  ...   # → MTEB.md
   swift run manifold-eval diff    --model <model> --prompt-file p.txt   ...   # same-bytes cross-backend
   swift run manifold-eval regress --backend <b> --baseline-model <q8> --redriven-model <q4> ...  # two-quant replay
   ```
2. **Fold + read the output.**
   - `swift run manifold-eval collate a.json b.json c.json --out MATRIX.md` renders the cross-runtime matrix.
   - `diff` exit codes: `0` = no actionable divergence (identical / sampler-nondeterminism); `1` = a
     control failure or genuine divergence a human should inspect.
   - `regress` exit codes: `0` = stable; `1` = moved (human judges quant-drift vs. genuine regression;
     `--threshold` defaults to `0.05`); `3` = indeterminate (a control failed).
3. **HUMAN triage.** Read the raw transcript for any flagged cell. Promote **only** a `genuineDivergence`
   or a real regression to backlog. This step is permanent — it must never be automated away.
4. **Hand the triaged backlog to the engine.** Scout file-disjoint candidates, implement in parallel
   worktrees, skeptical review, then serial **green-CI-only** merge.
5. **Confirm the loop closed.** After merge, `core-bump.yml` bumps the eval's exact core pin to the new
   release; re-run the **same lanes** next cycle and check the cell moved.

---

## The load-bearing joints (why the loop is trustworthy)

| Joint | Rule |
|-------|------|
| **Sensor, not fixer** | Signal → backlog, never signal → fix. The founding bug: the scorer was confidently wrong (F1=0.000 on a correct cell); only a human transcript read caught it. |
| **Comparability pinned** | `collate` rejects mixed-`coreCommit` sets; `diff` drives backends on the *same rendered bytes*; determinism = `temp=0` / fixed seed / variance reported over N repeats. |
| **Absence ≠ failure** | A model missing at run time is `notMeasured` — never reads as a regression, never manufactures phantom backlog. |
| **The pin closes the loop** | merged fix → core-bump → next cycle measures against the new core. This feedback edge is what makes it a loop, not a nightly report. |
| **Process compounds, not just PRs** | The compounding product is the *pipeline* — each cycle's retro folds lessons back into the spine + memory + run-log. |

---

## Failure modes / guardrails

- **Sensor with no scheduler = the fuzz-cadence collapse** (per-PR → nightly → weekly → hand-run →
  silence). The weekly CI rot-guard defends the *Tier-1* half of this; the model-bearing half has no
  scheduler yet (see [AUTOMATION-STATUS.md](AUTOMATION-STATUS.md)) and is therefore the half that
  can still collapse.
- **Divergence ≠ backlog.** The biggest waste is dispatching an implementer at a `promptDivergence` /
  `samplerNondeterminism` / `notMeasured` cell — noise dressed as work.
- **Green eval ≠ shipped-behavior good.** The lanes score `(model × quant × backend × renderer)` cells,
  **not** the app path — that's ManifoldKit-side DX / live walkthroughs.

---

## Status caveat — the loop is only half automated

**What runs on a schedule, and what doesn't, is stated once in
[AUTOMATION-STATUS.md](AUTOMATION-STATUS.md)** — don't restate it here. The short version, and the
part that bears on *this* document:

The rot-guard covers the **Tier-1** half (does it still compile, do the fixture contracts hold). The
**model-bearing** half — live BFCL / IFEval / MTEB and cross-quant `regress`, the lanes that carry
the credibility numbers — has **no scheduled cadence at all.** It runs on demand, locally.

So for the signal that actually matters to this loop — *did the cells move?* — the maintainer is
still the scheduler and the staleness check. That half is **human-cadenced, not CI-cadenced**, and
the feedback edge that makes this a loop rather than a report only closes when a human chooses to
close it.

Why that is load-bearing rather than a to-do: **stale assurance reads as a passing grade.** An eval
repo that lags the implementation is worse than none, because a green badge invites the reader to
conclude something the automation never measured. See
[ORIGINS principle #8](ORIGINS.md#principles-inherited-from-this-history-binding) — *no owner, no
repo* — which is explicitly recorded as **not yet fully satisfied**.
