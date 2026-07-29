# Concepts — the vocabulary this repo runs on

> The shared terms and invariants every other doc assumes. The *why behind the repo* is in
> [ORIGINS.md](ORIGINS.md); the *command reference* is in the [README](../README.md); the
> *operational loop* is in [EVAL-IMPROVEMENT-LOOP.md](EVAL-IMPROVEMENT-LOOP.md). Read this first if
> any of those use a word you don't recognize.

---

## The cell

The unit of measurement here is **not a model**. It is a cell:

```
model × quant × backend × renderer
```

`mistral-v0.3` is not a thing you can score. `mistral-v0.3 @ Q4_K_M on Ollama with Ollama's chat
template` is. The founding observation of this repo is that the *same weights* produce *different
tool-call verdicts* across Ollama, llama.cpp, and MLX — so capability is a property of the cell, and
a claim about "the model" that doesn't name all four coordinates is not a measurement.

Everything downstream follows from this. Reports are matrices over cells. A pass in one cell says
nothing about its neighbours.

## Assess, don't declare

Whether a model genuinely tool-calls (or follows instructions, or embeds coherently) is
**irreducibly empirical** — knowable only by measurement, never derivable from a static signal. A
base model can ship the identical tool-aware chat template as its instruct sibling; quantization can
degrade a real tool-caller below usable.

So there are no capability flags in this repo. There is a continuously-populated conformance matrix,
and the off-diagonal — *template says yes, soak says no* — is the work backlog.

## Sensor, not fixer

`manifold-eval` emits **evidence**: typed divergences, exit codes, rendered matrices. It never fixes
anything and never declares a bug on its own. A human triage gate decides which signals are real.

This gap is deliberate, not unfinished work. The repo exists because an automated scorer was once
*confidently wrong* — it scored a cell `F1=0.000` when every tool call in the transcript was
correct, and only a human reading the raw JSONL caught it. Anything that closes the gap between
*signal* and *declared bug* removes the step that caught the founding bug.

## Absence ≠ failure

A cell that wasn't measured is `notMeasured` — a first-class state, distinct from a measured zero.
A missing GGUF, an offline backend, an errored episode, a timed-out case: none of these ever render
as `0.000`, and none of them ever reach a backlog.

The failure mode this guards against is phantom regressions. A harness that reports absence as
failure manufactures work that doesn't exist, and — worse — trains its readers to discount real
zeros.

The inverse guard matters too: a *measured* zero is reported as a zero. When `gemma3-4b-tools`
emits no structured tool calls at all, that's a capability zero for the cell, reported as such,
never softened into a harness problem.

## Divergence ≠ bug, without a same-bytes control

Two backends disagreeing proves nothing on its own — in a naive comparison the quant, the
checkpoint, *and* the prompt renderer all differ at once, so the delta is confounded three ways.

A **same-bytes control** removes the confound: render the prompt exactly once, then drive every
backend on *those bytes*. Only then is a difference load-bearing. Divergence is then classified,
and only one class is a bug candidate:

| Classification | Means | Bug candidate? |
|---|---|:---:|
| `identical` | Backends agree byte-for-byte | no |
| `samplerNondeterminism` | Repeats of one backend already disagree | no |
| `promptDivergence` | The backends didn't see the same input | no |
| `tokenizerDivergence` | Same bytes, different tokens | no |
| `genuineDivergence` | Same bytes, same tokens, different output | **yes** |

The three middle rows are the ones that waste a human's time when mistaken for findings. Dispatching
an implementer at a `promptDivergence` cell is noise dressed as work.

The same logic drives `regress` with a different variable held constant: one backend, one prompt,
**two quants of the same model** — so quant is the only thing that moved.

## Determinism, pinned and reported

Every live lane runs greedy (`temperature: 0`), with a fixed seed where the backend supports one,
and repeats N times. Variance across repeats is **reported**, never averaged away.

This is a precondition, not a preference. A gate that can't reproduce its own baseline cries wolf:
if a re-drive with identical config isn't bit-identical, then any "regression" it reports might just
be the sampler. Cross-repeat variance at `temp=0` is itself a finding — reported as `VARIANT`, even
when every repeat passes.

Corollary: **cloud models are a sanity check, never an oracle.** Nondeterministic and over the
network — usable for an absolute score, never admissible in a differential cohort.

## Comparability guards

Two results can only be compared if the things that must be held constant actually were. Each lane
has a guard that turns "you compared apples to oranges" from a silent footgun into a visible error:

| Guard | Where | What it pins |
|---|---|---|
| `coreCommit` | `collate` | Records only merge across the *same* ManifoldKit core binary; a mixed set surfaces as a diagnostic. |
| `promptSha256` | `regress` | Both legs provably saw the same prompt; a mismatch is `indeterminate`, not a verdict. |
| Same rendered bytes | `diff` | The prompt is rendered once and reused, not re-rendered per backend. |
| `specHash` | `perf-bench` | Every lane's result carries its `BenchSpec` hash; the collator *refuses* to render a mixed-hash matrix. |

This is also why the ManifoldKit core dependency is pinned with `exact:` rather than a range: a
`coreCommit` guard is meaningless if the grader itself drifts.

## A read path with no live consumer is dead code

Every surface in this repo ships with something that actually exercises it. A feature that exists
but isn't wired is worse than none — it reads as covered when it isn't. In practice this is why the
generators (`bfcl-generate`, `ifeval-generate`, `toolloop-generate`) exist alongside the scorers:
a scorer with no generator is a read path nobody drives.

## The exit-code grammar

Verdict-shaped exit codes are a shared contract across commands, so a script can branch without
knowing which lane it ran:

| Code | Meaning | What a human does |
|:---:|---|---|
| `0` | Clean — nothing actionable | Nothing |
| `1` | A human should look | Read the raw transcript, then triage |
| `3` | Indeterminate — a control failed or nothing was measured | Rerun (more repeats, fix the setup) — **never** treat as a regression |
| `4` | A known benign artifact | Glance, then usually move on |

Note what `1` does *not* mean: it is never "this is a bug." It is "this cell earned a human's
attention." The adjudication is the human's, every time.

## Tier-1 vs. hardware-gated

| | Tier-1 (hermetic) | Hardware-gated (live) |
|---|---|---|
| Runs | `swift test`, hosted CI, the weekly rot-guard | Opt-in, local, Apple Silicon |
| Needs | Nothing — fixtures only, no models, no network | Ollama / llama.cpp, real GGUFs, fetched corpora |
| Proves | Still compiles, contracts hold, scorers are correct | The models still score what they scored |
| Commands | `collate`, `ifeval`, `bfcl`, `toolloop` | everything ending `-generate`, plus `mteb`, `diff`, `regress`, `perf-bench` |

A green Tier-1 run means "the harness is intact," never "the models are fine." Conflating the two is
how an assurance repo starts reading as a passing grade while measuring nothing.
