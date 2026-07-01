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

## Quick start

```sh
swift build
swift test          # fixture-driven; no models, no network — hosted-CI safe
```

The CLI is a single executable with six subcommands. Run it with no arguments for usage:

```sh
swift run manifold-eval
```

Real, hardware-gated eval lanes (Ollama / llama.cpp on Apple Silicon) are **opt-in** and never run
in hosted CI — see [Running real eval lanes](#running-real-eval-lanes).

## Commands

| Command | What it does | Needs models? |
|---------|--------------|:-------------:|
| [`collate`](#collate) | Fold per-backend `ConformanceRecord` JSON into one cross-runtime matrix | no |
| [`ifeval`](#ifeval--bfcl-offline-scorers) | Score pre-computed responses against the IFEval corpus | no |
| [`bfcl`](#ifeval--bfcl-offline-scorers) | Score pre-computed tool-calls against the BFCL (Gorilla v4) corpus | no |
| [`mteb`](#mteb) | Run the MTEB-STS embedding-correlation lane against an Ollama model | **yes** |
| [`diff`](#diff) | Render a prompt once, drive backends on the *same bytes*, triage divergence | **yes** |
| [`regress`](#regress) | Replay one prompt across two quants of a model and gate on score movement | **yes** |

Each command writes a deterministic Markdown report to stdout, or to a file with `--out`.
**Diagnostics and progress always go to stderr**, so `--out` (or a stdout redirect) captures a clean
report. Exit codes are verdict-shaped so CI and scripts can branch on them (see each command).

### `collate`

Folds the per-leg `[ConformanceRecord]` JSON arrays — each emitted by `manifold-tools score
--emit-records` in its own backend repo/process — into one corpus and renders the cross-runtime
matrix. Its **comparability guard** is what `cat *.json | matrix` never had: records are only
comparable across the *same* ManifoldKit core binary, so a mixed-`coreCommit` set or tooling drift
is surfaced as a diagnostic rather than silently merged.

```sh
swift run manifold-eval collate ollama.json llama.json mlx.json \
    --out XRUNTIME_MATRIX.md --title "Mistral-v0.3 cross-runtime"
```

Exit code: `0` normally (mixed-commit / tooling-drift warnings are advisory and still render);
`1` only on an error-severity diagnostic (e.g. an empty corpus).

### `ifeval` / `bfcl` (offline scorers)

Both score *already-generated* model output against a corpus — no model is invoked, so they run
anywhere. You generate responses elsewhere (any backend), dump them to JSONL, and score here.

```sh
# IFEval — instruction-following, strict verifiers
swift run manifold-eval ifeval --corpus ifeval.jsonl --responses responses.jsonl --out IFEVAL.md
#   responses line: {"key":"<case-key>","response":"<model output>"}

# BFCL — tool-call accuracy via ManifoldTools' AST matcher
swift run manifold-eval bfcl --corpus path/to/bfcl/data --responses calls.jsonl --out BFCL.md
#   calls line: {"id":"<case-id>","calls":[{"id":"...","toolName":"...","arguments":"..."}]}
```

Cases missing from the responses file are scored as empty (for BFCL, the `irrelevance` category
passes on an empty call list; every other category counts as a miss). With `--out`, a one-line
accuracy summary also prints to stdout.

### `mteb`

Runs the MTEB STS-Benchmark lane: embeds sentence pairs through an Ollama embedding model and reports
Spearman / Pearson correlation against the gold scores.

```sh
swift run manifold-eval mteb --dataset fixture --ollama-model nomic-embed-text --out MTEB.md
#   --dataset: a JSON file of [{"sentence1","sentence2","goldScore"}], or the literal `fixture`
#              for the built-in 15-pair scaffold.
```

Requires Ollama at `localhost:11434` with the embedding model pulled. Omitting `--ollama-model`
prints setup instructions and exits `0` (a skip, not an error).

### `diff`

The divergence-triage lane. Renders a prompt **once** (from raw text, or from chat messages via a
GGUF's embedded `chat_template`), drives Ollama N times as a determinism control, optionally shells
an external `--llama-runner` against the **same prompt bytes**, triages the result, and emits
`DIVERGENCE.md`.

```sh
swift run manifold-eval diff --model mistral:7b-instruct \
    --prompt-file probe.txt --repeats 3 --temperature 0 --out DIVERGENCE.md

# chat-templated, cross-backend against the same rendered bytes:
swift run manifold-eval diff --model mistral:7b-instruct \
    --messages-file chat.json --template-gguf ./mistral.gguf \
    --llama-runner "./llama-run --model ./mistral.gguf" --out DIVERGENCE.md

# force-match both legs' sampler when debugging a divergence (defaults: top-k
# disabled, repeat-penalty a no-op — both legs already agree on these unless
# overridden):
swift run manifold-eval diff --model mistral:7b-instruct \
    --prompt-file probe.txt --top-k 0 --repeat-penalty 1.0 --out DIVERGENCE.md
```

Exit codes: `0` = no actionable divergence (identical / sampler-nondeterminism); `1` = a control
failure or genuine divergence a human should inspect (prompt / tokenizer / sampler-mismatch /
genuine, or an Ollama-only determinism control that came back VARIANT); `3` = indeterminate — rerun
with more `--repeats`; `4` = both outputs are the same short repeating unit at different lengths (a
stopping-length artifact, not a content difference) — worth a look, but distinct from a genuine
divergence.

### `regress`

The replay-regression moat — the check core can't run on itself. Replays one prompt across **two
quants of the same model** on one backend (so quant is the only variable), scores both legs, and runs
them through `RegressionGate`, emitting a deterministic `REGRESSION.md`. Greedy / `temp=0` by
default — the only sampler the differential trusts.

```sh
swift run manifold-eval regress --backend ollama \
    --baseline-model qwen2.5:0.5b-instruct-q8_0 \
    --redriven-model qwen2.5:0.5b-instruct-q4_K_M \
    --prompt-file probe.txt --expected "Titan" --scorer contains --out REGRESSION.md
```

`--scorer contains|exact` (add `--ignore-case`); `--threshold` defaults to `0.05`. For llama.cpp,
pass `--backend llama --llama-runner "<cmd>"` with GGUF paths as the model args.

Exit codes: `0` = stable (no movement); `1` = moved (a human judges quant-drift vs. genuine
regression — the gate flags, it does not adjudicate); `3` = indeterminate (a control failed, e.g.
prompt-hash mismatch or unscorable output). See [docs/P4-VERIFICATION.md](docs/P4-VERIFICATION.md)
for the live same-model cross-quant verification that found a real Q4 correctness loss.

## Running real eval lanes

The model-driven lanes (`mteb`, `diff`, `regress`) and the corpus-gated tests need local models and
are gated behind env vars so `swift test` stays hermetic. Fetch the real corpora first:

```sh
scripts/fetch-corpora.sh                 # BFCL Gorilla v4 + MTEB STS-B (cached under ~/.cache/manifold-eval)
scripts/fetch-corpora.sh --bfcl-only     # or just one
```

Then enable the gated tests (each prints its own invocation after fetch):

```sh
BFCL_GORILLA_CACHE=~/.cache/manifold-eval/bfcl swift test --filter BFCLRealCorpusTests
RUN_OLLAMA_EMBED=1 STSB_DATA=~/.cache/manifold-eval/stsb_test.json swift test --filter MTEBRealCorpusTests
RUN_OLLAMA_LIVE=1 swift test --filter RegressionCrossQuantLiveTests   # needs two quant tags pulled
```

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
```

## Roadmap

| Phase | Deliverable | Status |
|-------|-------------|--------|
| **P1** | Collator + cross-runtime matrix | ✅ shipped |
| **P2** | Differential comparator + same-bytes Cohort A + determinism pinning | ✅ shipped |
| **P3** | BFCL-full + IFEval + MTEB lanes | ✅ shipped |
| **P4** | `regress` — replay-regression gate over same-model cross-quant runs | ✅ shipped & verified |
| **P5** | `core-bump.yml` lockstep + on-demand cadence (nightly + rot-guard deferred) | planned |

Design and phasing live in ManifoldKit's `docs/plans/manifold-eval-repo-v2-override.md`.

## License

See [LICENSE](LICENSE).
