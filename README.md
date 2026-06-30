# manifold-eval

Independent **assurance** repo for the [ManifoldKit](https://github.com/ManifoldKit/ManifoldKit)
family. ManifoldKit (and the `manifold-mlx` / `manifold-llama` companions) are optimized for
*developer utility*; this repo is optimized for *assurance* — reproducible, deterministic,
adversarial verdicts on model × quant × backend × renderer behavior. The repo boundary **is** the
governance boundary between implementation and assurance (the pattern used by `test262`,
`web-platform-tests`, the Khronos Vulkan CTS, SQLite TH3).

Design and phasing live in ManifoldKit `docs/plans/manifold-eval-repo-v2-override.md`.

## Architecture

`manifold-eval` sits at the **top** of the dependency graph and depends only downward — it consumes
ManifoldKit's published `ManifoldTools` surface and **owns nothing** the kit or its companions
consume (no edge inversion, no cycle). The MLX / llama.cpp companions are **not linked**; they run as
**separate processes** whose `ConformanceRecord` JSON this repo collates, because `llama_backend_init`
is once-per-process and MLX needs serialized in-process Metal. One process linking all backends is
unbuildable — collation over separate-process records is the design.

## P1 (this scaffold)

The typed, tested replacement for the sweep's hand-assembled cross-runtime matrix step:

- **`Collator`** folds the per-leg `[ConformanceRecord]` JSON arrays into one corpus, with a
  **comparability guard** the old `cat *.json | matrix` had no equivalent for: records are only
  comparable across the same ManifoldKit core binary, so a mixed-`coreCommit` set or tooling drift is
  surfaced as a diagnostic, not silently merged.
- **`CrossRuntimeMatrix`** renders the corpus via `ManifoldTools.MatrixRenderer` with a diagnostics
  banner.
- **`manifold-eval` CLI**: `collate`.

```sh
manifold-eval collate ollama.json llama.json mlx.json --out XRUNTIME_MATRIX.md
```

Each input is a `[ConformanceRecord]` array as emitted by `manifold-tools score --emit-records` in the
respective backend's repo/process.

## Roadmap

| Phase | Deliverable |
|-------|-------------|
| **P1** | Collator + cross-runtime matrix (this scaffold) |
| **P2** | Differential comparator + same-bytes Cohort A + determinism pinning (verified feasible 2026-06-29) |
| **P3** | BFCL-full + IFEval + MTEB lanes |
| **P4** | `regress` subcommand — replay-regression gate over same-model cross-quant runs (`RegressionRunner`/`RegressionGate`) |
| **P5** | `core-bump.yml` lockstep + on-demand cadence (nightly + rot-guard deferred) |

## Build & test

```sh
swift build
swift test          # fixture-driven; no models, hosted-CI safe
```

Real, hardware-gated eval lanes run on local/self-hosted Apple Silicon (not hosted CI).
