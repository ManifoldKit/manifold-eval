# manifold-eval

Independent **assurance** harness for the [ManifoldKit](https://github.com/ManifoldKit/ManifoldKit)
family. Where ManifoldKit (and the `manifold-mlx` / `manifold-llama` companions) optimize for
*developer utility*, this repo optimizes for *assurance*: reproducible, deterministic, adversarial
verdicts on `model × quant × backend × renderer` behavior.

The repo boundary **is** the governance boundary between implementation and assurance — the same
pattern used by `test262`, `web-platform-tests`, the Khronos Vulkan CTS, and SQLite TH3. The grader
must not be shipped by the team it grades.

> **Why a separate repo?** A cross-backend soak once found the *same* Mistral-v0.3 weights producing
> *different* tool-call verdicts across Ollama, llama.cpp, and MLX — and the automatic scorer was
> wrong, scoring a correct cell `F1=0.000` until a human read the raw transcript. That single fact
> anchors the design: **surface divergence to focus human attention; never claim to adjudicate it
> automatically.** The full decision history is in [docs/ORIGINS.md](docs/ORIGINS.md).

---

## How the suite fits together

The ten subcommands are not ten independent tools. They are **four families**, and the relationships
between them are where the design lives.

### 1. Capture → score (the corpus lanes)

Three corpora — BFCL (tool calls), IFEval (instruction following), and the tool-loop scaffold
(multi-turn threading) — each split into a **live generator** and an **offline scorer**:

```
   ┌─ live, opt-in, needs a model ───────┐        ┌─ hermetic, CI-safe, no model ──┐
   │                                     │        │                                │
   │   bfcl-generate      ──┐            │        │  ──▶  bfcl                     │
   │   ifeval-generate    ──┼─▶ responses.jsonl ──┼──▶  ifeval        ──▶ report.md │
   │   toolloop-generate  ──┘            │        │  ──▶  toolloop                 │
   └─────────────────────────────────────┘        └────────────────────────────────┘
              drives the model                         judges what was captured
```

The split is the point. **Generation is expensive, nondeterministic-ish, and hardware-gated; scoring
is cheap, deterministic, and reproducible by anyone.** Separating them means a captured run can be
re-scored forever — after a scorer bug fix, against a new rubric, by someone with no Apple Silicon —
without re-driving a single token.

Each pair shares one corpus loader and one on-disk schema, so a generate → score round-trip needs no
adapter or reshape step. That is not a convenience: a hand-rolled full-corpus run once reported a
misleading **8.0%** by scoring a 25-case bundled-slice generation against the full 199-case corpus.
The honest number was **64%**. Shared loaders make that class of mistake unrepresentable.

### 2. Differential (the lanes that hold one variable)

Two commands answer "did something change?" by holding everything constant except one variable:

| Command | Holds constant | Varies | Question |
|---|---|---|---|
| `diff` | the rendered prompt **bytes** | the backend | Do Ollama and llama.cpp agree on identical input? |
| `regress` | backend, prompt, sampler | the **quant** | Did re-quantizing this model break it? |

Both exist because a naive comparison is confounded — quant *and* checkpoint *and* renderer all
differ at once, so a raw cross-backend delta means nothing. See
[the same-bytes control](docs/CONCEPTS.md#divergence--bug-without-a-same-bytes-control).

### 3. The fold

`collate` is the aggregator. The backends can't be linked into one process (`llama_backend_init` is
once-per-process; MLX needs serialized in-process Metal), so each runs **separately** and emits
`ConformanceRecord` JSON. `collate` folds those into one cross-runtime matrix — refusing to merge
records from different core binaries.

### 4. Performance

`perf-bench` is its own axis: not *is it correct* but *is it fast*, measured comparably across
serving lanes via one HTTP driver and one pinned spec.

### Which lane answers which question?

| Your question | Run | Live models? |
|---|---|:---:|
| Does this model call the right tools, with the right arguments? | `bfcl-generate` → `bfcl` | capture only |
| …and does the tool *result* thread into the next turn? | `toolloop-generate` → `toolloop` | capture only |
| Does it follow explicit formatting instructions? | `ifeval-generate` → `ifeval` | capture only |
| Is this embedding model coherent? | `mteb` | yes |
| Do two backends agree on the *identical* prompt bytes? | `diff` | yes |
| Did re-quantizing break correctness? | `regress` | yes |
| How do all measured cells compare, in one view? | `collate` | no |
| Which serving lane is faster, measured comparably? | `perf-bench` | yes |

### What to do with the output

Nothing here fixes anything or declares a bug. These commands are a **sensor**; a human triage gate
is the adjudicator. The full cycle — sensor → triage → fix pipeline → core pin bump → re-measure —
is documented in **[docs/EVAL-IMPROVEMENT-LOOP.md](docs/EVAL-IMPROVEMENT-LOOP.md)**. Read that
before acting on any report this repo emits.

### The exit-code grammar

Exit codes are verdict-shaped and mean the same thing across commands, so a script can branch
without knowing which lane it ran:

| Code | Meaning | What a human does |
|:---:|---|---|
| `0` | Clean — nothing actionable | Nothing |
| `1` | A human should look | Read the raw transcript, then triage |
| `3` | Indeterminate — a control failed, or nothing was measured | Rerun; **never** treat as a regression |
| `4` | A known benign artifact (`diff` only) | Glance, then usually move on |

`1` never means "this is a bug." It means "this cell earned a human's attention." Per-command
sections below note only where a command specializes this grammar.

---

## Quick start

```sh
swift build
swift test          # fixture-driven; no models, no network — hosted-CI safe
```

The CLI is a single executable; run it with no arguments for the full usage list:

```sh
swift run manifold-eval
```

Real, hardware-gated eval lanes (Ollama / llama.cpp on Apple Silicon) are **opt-in** and never run
in hosted CI — see [Running real eval lanes](#running-real-eval-lanes).

New to the repo? [docs/CONCEPTS.md](docs/CONCEPTS.md) defines the vocabulary the rest of this file
assumes — the cell, the same-bytes control, absence ≠ failure, determinism pinning.

## Commands

| Command | What it does | Needs models? |
|---------|--------------|:-------------:|
| [`collate`](#collate) | Fold per-backend `ConformanceRecord` JSON into one cross-runtime matrix | no |
| [`ifeval`](#ifeval--bfcl-offline-scorers) | Score pre-computed responses against the IFEval corpus | no |
| [`ifeval-generate`](#ifeval-generate) | Drive a live Ollama model over an IFEval corpus and write the `ifeval` responses file | **yes** |
| [`bfcl`](#ifeval--bfcl-offline-scorers) | Score pre-computed tool-calls against the BFCL (Gorilla v4) corpus | no |
| [`bfcl-generate`](#bfcl-generate) | Drive a live Ollama model over the full BFCL corpus and write the `bfcl` responses file | **yes** |
| [`mteb`](#mteb) | Run the MTEB-STS embedding-correlation lane against an Ollama model | **yes** |
| [`diff`](#diff) | Render a prompt once, drive backends on the *same bytes*, triage divergence | **yes** |
| [`regress`](#regress) | Replay one prompt across two quants of a model and gate on score movement | **yes** |
| [`toolloop`](#toolloop--toolloop-generate) | Score recorded multi-turn tool-loop transcripts for tool-result threading | no |
| [`toolloop-generate`](#toolloop--toolloop-generate) | Drive a live Ollama model through real multi-turn tool dispatch and record transcripts | **yes** |
| [`perf-bench`](#perf-bench) | Drive one spec-pinned model across HTTP lanes (Ollama / OpenAI-compatible) and render a TTFT/TPS matrix | **yes** |

Each command writes a deterministic Markdown report to stdout, or to a file with `--out`.
**Diagnostics and progress always go to stderr**, so `--out` (or a stdout redirect) captures a clean
report.

---

### `collate`

Folds the per-leg `[ConformanceRecord]` JSON arrays — each emitted by `manifold-tools score
--emit-records` in its own backend repo/process — into one corpus and renders the cross-runtime
matrix.

**Why it exists.** Its **comparability guard** is what `cat *.json | matrix` never had: records are
only comparable across the *same* ManifoldKit core binary, so a mixed-`coreCommit` set or tooling
drift is surfaced as a diagnostic rather than silently merged.

```sh
swift run manifold-eval collate ollama.json llama.json mlx.json \
    --out XRUNTIME_MATRIX.md --title "Mistral-v0.3 cross-runtime"
```

**Exit codes.** `0` normally — mixed-commit / tooling-drift warnings are advisory and still render;
`1` only on an error-severity diagnostic (e.g. an empty corpus).

---

### `ifeval` / `bfcl` (offline scorers)

Both score *already-generated* model output against a corpus — no model is invoked, so they run
anywhere. You generate responses elsewhere (any backend), dump them to JSONL, and score here.

```sh
# IFEval — instruction-following, strict verifiers
swift run manifold-eval ifeval --corpus ifeval.jsonl --responses responses.jsonl --out IFEVAL.md
#   responses line: {"key":"<case-key>","response":"<model output>"}

# BFCL — tool-call accuracy via ManifoldTools' AST matcher (flat fixture layout)
swift run manifold-eval bfcl --corpus path/to/bfcl/data --responses calls.jsonl --out BFCL.md
#   calls line: {"id":"<case-id>","calls":[{"id":"...","toolName":"...","arguments":"..."}]}

# BFCL — same corpus a `bfcl-generate` run used (Gorilla v4 cache layout)
swift run manifold-eval bfcl --gorilla-cache-dir ~/.cache/manifold-eval/bfcl --responses calls.jsonl --out BFCL.md
```

**Two corpus layouts, pick exactly one.** `--corpus <dir>` expects the flat
`<category>_questions.jsonl` / `<category>_answers.jsonl` layout (fixtures, or a hand-reshaped
corpus). `--gorilla-cache-dir <dir>` is the alternative for a Gorilla v4 cache directory as
`bfcl-generate --cache-dir` (or `scripts/fetch-corpora.sh`) produces it.

**Missing cases.** Cases absent from the responses file are scored as empty. For BFCL, the
`irrelevance` category *passes* on an empty call list; every other category counts as a miss. With
`--out`, a one-line accuracy summary also prints to stdout.

---

### `bfcl-generate`

The full-corpus BFCL *generator* — the piece `bfcl` above doesn't have. Drives a live Ollama model
over every case in the requested categories, one at a time, and writes one `BFCLResponseEntry` JSON
object per line: the exact schema `bfcl --responses` reads, so a generate → score round-trip needs
no adapter or reshape step.

```sh
swift run manifold-eval bfcl-generate --ollama-model mistral:7b-instruct-tools-q4_K_M \
    --category multiple --out multiple-responses.jsonl
#   --category:   simple|multiple|parallel|parallel_multiple|irrelevance (comma-separated), or `all`
#                 (default: multiple)
#   --ollama-url: default http://localhost:11434
#   --cache-dir:  Gorilla v4 download/cache dir (default ~/.cache/manifold-eval/bfcl)
#   --timeout:    per-case generation deadline in seconds (default 120)

# Then score exactly what was generated — note --gorilla-cache-dir, not --corpus
# (the Gorilla cache layout differs from the flat fixture layout `--corpus` expects):
swift run manifold-eval bfcl --gorilla-cache-dir ~/.cache/manifold-eval/bfcl \
    --responses multiple-responses.jsonl --out BFCL.md
```

**Why one shared loader.** Both commands load cases through the same `BFCLLane` corpus loader, so
ids and corpus layout always match — no manual reshape, and no risk of scoring against a different
id-namespace than what was generated. This is not hypothetical: a hand-rolled full-corpus run once
reported a misleading **8.0%** by scoring a 25-case bundled-slice generation against the full
199-case `multiple` corpus. The honest slice number was **64%**.

**Capture, never dispatch.** The tool registry is empty, so the model's first tool call is recorded,
never executed.

**Incremental.** Progress streams to stderr per-case, and each response is written to `--out` as
soon as it's generated, so a multi-hour full-corpus run banks progress incrementally instead of
risking it all on one process that runs to completion.

**Gotcha — read the per-category table, not the Overall aggregate.** Scoring a `bfcl-generate
--category multiple` run reports the `multiple` row honestly (every case in that category was
attempted), but categories you didn't generate still show up at their correct 0%. When your
responses file doesn't cover every category, the "Overall" number is misleading by construction.

---

### `ifeval-generate`

The IFEval *generator* — the piece `ifeval` above doesn't have. Drives a live Ollama model over
every case in an IFEval corpus and writes one `IFEvalResponseEntry` JSON object per line: the exact
schema `ifeval --responses` reads, so a generate → score round-trip needs no adapter.

```sh
swift run manifold-eval ifeval-generate --ollama-model qwen2.5-0.5b \
    --corpus ifeval.jsonl --out responses.jsonl
#   --ollama-url:  default http://localhost:11434
#   --max-tokens:  per-case generation cap (default 512 — matches the run that verified
#                  qwen2.5-0.5b's 22.9% strict-accuracy number; changing it changes what
#                  "verified" means, so it's not a casual knob)
#   --concurrency: cases in flight at once (default 6 — same provenance as --max-tokens)
#   --timeout:     per-case generation deadline in seconds (default 120)

# Then score exactly what was generated:
swift run manifold-eval ifeval --corpus ifeval.jsonl --responses responses.jsonl --out IFEVAL.md
```

**Why this one is concurrent** (and `bfcl-generate` isn't). IFEval cases are independent single-turn
text generations with no shared state, so this fans out up to `--concurrency` cases at once, each
against its **own** `InferenceService`/`OllamaBackend` pair — a single shared service's generation
queue is FIFO, so sharing one across workers would silently serialize them and defeat
`--concurrency`. Greedy/deterministic (`temperature: 0`), no tools.

**Resumable.** If `--out` already exists, keys already present are read and skipped, and new entries
are appended (not overwritten) — a crash or Ctrl-C partway through a multi-hour full-corpus run
loses nothing already generated, because each *successful* case is written to disk (through a single
actor that serializes concurrent workers' writes) as soon as it finishes, not batched at the end.

A case that errors or times out is deliberately **not** written to `--out`. Writing an empty
placeholder would make that key permanently "present" and never eligible for retry; leaving it
absent instead means the next invocation retries it automatically — and `ifeval`'s scorer already
treats a missing key as "score against empty string," so a still-failing case scores identically
either way.

---

### `mteb`

Runs the MTEB STS-Benchmark lane: embeds sentence pairs through an Ollama embedding model and
reports Spearman / Pearson correlation against the gold scores.

```sh
swift run manifold-eval mteb --dataset fixture --ollama-model nomic-embed-text --out MTEB.md
#   --dataset: a JSON file of [{"sentence1","sentence2","goldScore"}], or the literal `fixture`
#              for the built-in 15-pair scaffold.
```

Requires Ollama at `localhost:11434` with the embedding model pulled. Omitting `--ollama-model`
prints setup instructions and exits `0` — a **skip, not an error** (absence ≠ failure).

---

### `diff`

The divergence-triage lane. Renders a prompt **once** (from raw text, or from chat messages via a
GGUF's embedded `chat_template`), drives Ollama N times as a determinism control, optionally shells
an external `--llama-runner` against the **same prompt bytes**, triages the result, and emits
`DIVERGENCE.md`.

**Why the same-bytes control.** Without it, a cross-backend comparison varies quant, checkpoint, and
renderer simultaneously — the delta is confounded three ways and proves nothing. Rendering once and
reusing the bytes is what makes a difference load-bearing.

```sh
swift run manifold-eval diff --model mistral:7b-instruct \
    --prompt-file probe.txt --repeats 3 --temperature 0 --out DIVERGENCE.md

# chat-templated, cross-backend against the same rendered bytes:
swift run manifold-eval diff --model mistral:7b-instruct \
    --messages-file chat.json --template-gguf ./mistral.gguf \
    --llama-runner "./llama-run --model ./mistral.gguf" --out DIVERGENCE.md

# force-match both legs' sampler when debugging a divergence (defaults: top-k
# disabled, repeat-penalty a no-op — both legs already agree on these unless
# overridden). Both flags reach the Ollama leg AND, when --llama-runner is
# passed, the external runner's own --top-k/--repeat-penalty flags:
swift run manifold-eval diff --model mistral:7b-instruct \
    --prompt-file probe.txt --top-k 0 --repeat-penalty 1.0 --out DIVERGENCE.md
```

**Exit codes.** `0` = no actionable divergence (identical / sampler-nondeterminism); `1` = a control
failure or genuine divergence a human should inspect (prompt / tokenizer / sampler-mismatch /
genuine, or an Ollama-only determinism control that came back VARIANT); `3` = indeterminate — rerun
with more `--repeats`; `4` = both outputs are the same short repeating unit at different lengths (a
stopping-length artifact, not a content difference) — worth a look, but distinct from a genuine
divergence.

Only `genuineDivergence` is a bug candidate. The other classifications are the ones that waste a
human's time when mistaken for findings — see
[the divergence table](docs/CONCEPTS.md#divergence--bug-without-a-same-bytes-control).

---

### `regress`

The replay-regression moat — the check core can't run on itself. Replays one prompt across **two
quants of the same model** on one backend (so quant is the only variable), scores both legs, and
runs them through `RegressionGate`, emitting a deterministic `REGRESSION.md`. Greedy / `temp=0` by
default — the only sampler the differential trusts.

**Why core can't do this.** An in-core regression test is *green by construction*: deterministic
replay ⇒ identical bytes ⇒ a stability assertion is tautological. The scorer only earns its keep
when the bytes actually *differ*, which only happens across repos, across quants.

```sh
swift run manifold-eval regress --backend ollama \
    --baseline-model qwen2.5:0.5b-instruct-q8_0 \
    --redriven-model qwen2.5:0.5b-instruct-q4_K_M \
    --prompt-file probe.txt --expected "Titan" --scorer contains --out REGRESSION.md
```

`--scorer contains|exact` (add `--ignore-case`); `--threshold` defaults to `0.05`. For llama.cpp,
pass `--backend llama --llama-runner "<cmd>"` with GGUF paths as the model args.

**Exit codes.** `0` = stable (no movement); `1` = moved; `3` = indeterminate (a control failed, e.g.
prompt-hash mismatch or unscorable output).

**`1` is not a regression verdict.** A re-quant can legitimately shift output. The gate flags
movement for a human to judge quant-drift vs. genuine correctness loss; it does not adjudicate.
[docs/P4-VERIFICATION.md](docs/P4-VERIFICATION.md) records the live same-model cross-quant run where
this found a real Q4 correctness loss (q8 answered "Titan"; q4 answered "Rhea").

---

### `toolloop` / `toolloop-generate`

The multi-turn tool-loop conformance lane (issue #27). Where `bfcl` scores "did the model call the
right function" on one shot, this lane scores what happens *after* the call comes back — did the
tool result **thread** into the next call's arguments and into the final answer?

**Why it exists.** A cell can pass single-turn AST scoring and still mis-thread a result on turn 2.
Single-turn scoring reads that cell as healthy. This lane is the instrument that sees the break.

`toolloop-generate` (the live consumer) drives an Ollama model over the corpus with each case's
**scripted tools registered in a real `ToolRegistry`** — the production dispatch loop executes the
tools and threads results across turns; only the tool *payloads* are canned (deterministic sentinel
values like `"K97"` that don't exist in model priors, so a pass proves the model read the threaded
result). `toolloop` then scores the recorded transcripts offline — no model, hosted-CI safe.

```sh
# Generate: 8-case built-in scaffold × 3 repeats (the determinism control)
swift run manifold-eval toolloop-generate --ollama-model mistral-7b-tools:latest \
    --out transcripts.jsonl
#   --corpus:              corpus JSONL override (one ToolLoopCase per line); default: built-in scaffold
#   --repeats:             episodes per case (default 3)
#   --max-tool-iterations: dispatch-loop turn budget per episode (default 4)
#   --timeout:             per-episode deadline in seconds (default 180)

# Score exactly what was generated:
swift run manifold-eval toolloop --responses transcripts.jsonl --out TOOLLOOP.md
```

**Three probe axes per case**, each optional (`—` = not probed, never a fake pass/fail):

- **first call** — turn-1 correctness (the BFCL overlap).
- **chained arg** — a later call must carry a sentinel that exists only in an earlier tool result,
  *and* must occur after that result. A matching call emitted before any result couldn't have read
  it, and scores as a miss.
- **final answer** — result sentinels surface in the answer.

Chaining cases' target tools are **sentinel-gated**: any argument other than the sentinel gets an
error payload, exactly as a real API would — so the sentinel cannot leak to an episode that never
threaded it, and a broken chain produces a visibly broken answer.

A case passes only when **every repeat passes every specified axis**; cross-repeat variance at
`temp=0` is reported as `VARIANT` even when all repeats pass. Episodes that error or time out are
recorded with an error marker and reported as *not measured* holes — never as capability zeros.

**What it catches, concretely.** `mistral-7b-tools` (q4_K_M, Ollama) passes all four result→answer
cases and the multi-call case 3/3 repeats bit-identically — and fails all three chaining cases the
same way, emitting both calls in one pre-result batch with *placeholder arguments*
(`get_balance(account_id: "$result.account_id")`). Turn-1 scoring on those same episodes is clean,
so a single-turn lane reads the cell as healthy while the turn-2 chain is broken. `gemma3-4b-tools`
emits zero structured tool calls on this path (a ```` ```tool_code ```` text block instead) and then
*hallucinates the tool result* — a measured capability zero for the cell, reported as such, never as
a harness failure.

**Exit codes.** `0` = every case measured, passed, and repeated deterministically; `1` = a measured
threading failure or a `temp=0` VARIANT a human should inspect; `3` = indeterminate — nothing
matched the corpus, or some cases have only missing/errored episodes (holes gate as reruns, not
regressions).

---

### `perf-bench`

The local-inference performance harness's spine: **one HTTP driver** measures both `http-openai`
(SSE `/v1/chat/completions`) and `http-ollama` (NDJSON `/api/generate`) lanes with the same
instrumentation points, so TTFT and TPS mean the same thing across transports.

**Why it exists.** It replaces an ad-hoc predecessor — three separate in-process Swift bench targets
(core, `manifold-mlx`, `manifold-llama`) that each measured whatever model happened to be loaded
locally, producing non-comparable numbers. A "core vs MLX" delta was routinely a 0.5B-vs-4B delta in
disguise.

**The guard.** A `BenchSpec` pins **one** `model_family` + generation protocol across every lane;
every result carries that pin's hash (`specHash`), and `perf-bench`'s collator **refuses** to render
a matrix whose results don't all share one hash — the apples-to-oranges mistake becomes a
collation-time error, not a silent footgun.

```sh
swift run manifold-eval perf-bench --spec perf-spec.json \
    --out PERF-MATRIX.md --json-out results.json
```

```json
{
  "model_family": "llama-3.1-8b-instruct",
  "protocol": {
    "prompt": "...",
    "temperature": 0.0,
    "max_tokens": 128,
    "warmup_runs": 1,
    "timed_runs": 5,
    "measure_cold": true
  },
  "lanes": [
    { "name": "ollama", "transport": "http-ollama", "endpoint": "http://localhost:11434", "model": "llama3.1:8b", "quant": "Q4_K_M" },
    { "name": "omlx", "transport": "http-openai", "endpoint": "http://127.0.0.1:8000", "model": "Meta-Llama-3.1-8B-Instruct-4bit", "quant": "4bit", "api_key_env": "OMLX_API_KEY" }
  ]
}
```

**Strictly sequential, by construction.** Each lane runs an optional cold-start pass
(`measure_cold`: Ollama unload via `keep_alive: 0` + one measured reload), then 1 warmup (discarded)
+ N timed warm runs. Lanes **never** run concurrently — GPU contention between two locally-running
engines corrupts throughput numbers, so `PerfRunner` has no concurrent code path to opt out of.

**Sample counts are enforced, not assumed.** `BenchSpec`'s protocol rejects a nonpositive
`timed_runs` (and a negative `warmup_runs`) at construction/decode time, and `PerfRunner` checks
every produced `BenchResult`'s per-run sample counts against it — a lane that silently drops or
duplicates a timed run fails loud instead of quietly shipping a median over the wrong sample count.

**Native metrics (schema v2).** Ollama's final chunk already carries `load_duration`,
`prompt_eval_count`/`prompt_eval_duration`, and `eval_count`/`eval_duration` — the driver records
them as per-run `loadDurationMs` / `prefillTps` / `generateTps`. OpenAI-compatible lanes derive
decode tok/s as `tokens / (wall − TTFT)`. Wall TPS remains **prefill-included** for continuity with
retired in-process benches; the report's native-split table carries the decode-only figure.

**Percentile policy.** Publish median + min/max always; p90 only at `timed_runs ≥ 20`; p99 only at
`timed_runs ≥ 100`. Prefer a *latency* spec (20+ reps, tiny `max_tokens`) and a *throughput* spec
(5 reps, 256+ tokens) rather than one undersampled run that pretends to publish p99.

**Secrets and output.** `api_key_env` names an environment variable holding a bearer token (e.g.
OMLX's `Authorization: Bearer <key>`) — specs are checked into the repo and never carry a secret
value directly. `--json-out` writes the raw per-lane `BenchResult` array (pretty JSON, sorted keys)
for publication under a consumer repo's `docs/perf/`.

**Before you run it against real hardware, write down your prediction** for the TTFT/TPS delta you
expect. A number that only confirms what you already assumed teaches you nothing about whether the
harness — or the engine — is actually behaving as understood.

**Scope today.** This spine measures HTTP-fronted lanes only. Peak/steady-state memory and
cancellation latency need process ownership / in-process cancel (gated on ManifoldKit #2245
companion server hosts and a core E2E suite). Companion server hosts
(`manifold-server-mlx`/`manifold-server-llama`) and in-process control lanes are follow-ups, not yet
wired into this matrix.

---

## Running real eval lanes

The model-driven lanes (`mteb`, `diff`, `regress`, `bfcl-generate`, `ifeval-generate`,
`toolloop-generate`) and the corpus-gated tests need local models and are gated behind env vars so
`swift test` stays hermetic. Fetch the real corpora first:

```sh
scripts/fetch-corpora.sh                 # BFCL Gorilla v4 + MTEB STS-B (cached under ~/.cache/manifold-eval)
scripts/fetch-corpora.sh --bfcl-only     # or just one
```

Then enable the gated tests (each prints its own invocation after fetch):

```sh
BFCL_GORILLA_CACHE=~/.cache/manifold-eval/bfcl swift test --filter BFCLRealCorpusTests
RUN_OLLAMA_EMBED=1 STSB_DATA=~/.cache/manifold-eval/stsb_test.json swift test --filter MTEBRealCorpusTests
RUN_OLLAMA_LIVE=1 swift test --filter RegressionCrossQuantLiveTests   # needs two quant tags pulled
RUN_OLLAMA_LIVE=1 OLLAMA_MODEL=qwen2.5-0.5b swift test --filter IFEvalGenerateLiveTests
RUN_OLLAMA_LIVE=1 OLLAMA_MODEL=mistral-7b-tools:latest swift test --filter ToolLoopGenerateLiveTests
RUN_PERF_LIVE=1 swift test --filter PerfHTTPDriverLiveTests   # needs a local Ollama + OpenAI-compatible server
```

A green hermetic run means *the harness is intact* — never *the models still score the same*. Those
are [two different tiers](docs/CONCEPTS.md#tier-1-vs-hardware-gated), and conflating them is how an
assurance repo starts reading as a passing grade while measuring nothing.

## Architecture

`manifold-eval` sits at the **top** of the dependency graph and depends only downward: it consumes
ManifoldKit's published `ManifoldTools` / `ManifoldInference` / `ManifoldModelCatalog` surface and
**owns nothing** the kit or its companions consume — no edge inversion, no package cycle. The core
dependency is pinned to an **exact** version (not a range): an assurance repo whose premise is
comparability against a specific core binary must not float its own core (the `coreCommit` guard is
meaningless if the consumer drifts). `core-bump.yml` bumps that exact pin on each core release.

The MLX / llama.cpp companions are deliberately **not linked**. They run as **separate processes**
whose `ConformanceRecord` JSON this repo collates — because `llama_backend_init` is once-per-process
and MLX needs serialized in-process Metal. One process linking all backends is unbuildable;
collation over separate-process records is the design.

```
Sources/
  manifold-eval/      CLI dispatch + per-subcommand argv parsing
  ManifoldEval/       library — the assurance logic, no argv:
    Collator, CrossRuntimeMatrix      collate
    IFEval/, BFCL/, MTEB/             corpus lanes
    Differential/                     diff — prompt rendering, drivers, triage
    Replay/                           regress — RegressionRunner / Gate / Report
    Perf/                             perf-bench — BenchSpec/Result, HTTP driver, collator, report
```

## Documentation

| Doc | Answers |
|---|---|
| [docs/CONCEPTS.md](docs/CONCEPTS.md) | What the vocabulary means — the cell, same-bytes control, absence ≠ failure, exit codes |
| [docs/ORIGINS.md](docs/ORIGINS.md) | Why this repo exists separately from ManifoldKit (three rejections and one override) |
| [docs/EVAL-IMPROVEMENT-LOOP.md](docs/EVAL-IMPROVEMENT-LOOP.md) | What to do with eval output — sensor → triage → fix → re-measure |
| [docs/AUTOMATION-STATUS.md](docs/AUTOMATION-STATUS.md) | What runs automatically and what doesn't — the single source of truth, guarded by a test |
| [docs/P4-VERIFICATION.md](docs/P4-VERIFICATION.md) | Evidence that the regression gate works on real models |
| [AGENTS.md](AGENTS.md) | How to work on this repo (build, test, constraints) |

## Roadmap

| Phase | Deliverable | Status |
|-------|-------------|--------|
| **P1** | Collator + cross-runtime matrix | ✅ shipped |
| **P2** | Differential comparator + same-bytes Cohort A + determinism pinning | ✅ shipped |
| **P3** | BFCL-full + IFEval + MTEB lanes | ✅ shipped |
| **P4** | `regress` — replay-regression gate over same-model cross-quant runs | ✅ shipped & verified |
| **P5** | `core-bump.yml` lockstep automation | ✅ shipped |
| — | Weekly Tier-1 CI rot-guard (`rot-guard.yml`) | ✅ shipped 2026-07-04 |
| — | Scheduled cadence for the **model-bearing** sweep (live BFCL / IFEval / MTEB, cross-quant `regress`) | ⬜ **open** — on-demand local runs only |

What each automation is triggered by, and what it does and doesn't prove, is stated once in
[docs/AUTOMATION-STATUS.md](docs/AUTOMATION-STATUS.md) — and guarded by a test against the workflow
files, so it can't quietly drift out of date the way this table's earlier wording did.
| **P6** | `perf-bench` — spec-driven local-inference perf harness spine (HTTP driver over Ollama/OpenAI-compatible lanes) | ✅ spine shipped; server-host MLX/llama lanes follow once ManifoldKit's `ServerBackendProvider` seam lands |

Design and phasing live in ManifoldKit's `docs/plans/manifold-eval-repo-v2-override.md`.

## License

See [LICENSE](LICENSE).
