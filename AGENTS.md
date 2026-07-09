# manifold-eval — independent assurance harness for the ManifoldKit family

This repo is the independent assurance/eval harness for the
[ManifoldKit](https://github.com/ManifoldKit/ManifoldKit) family
(ManifoldKit core, `manifold-mlx`, `manifold-llama`, and their app consumer
`fireside`). Its founding constraint, mirrored in `Package.swift`'s own
comments: **the grader stays outside the graded repos.** This repo depends
only *downward* on ManifoldKit's published `ManifoldTools` /
`ManifoldInference` / `ManifoldModelCatalog` / `ManifoldOllama` products —
the same public surface any external consumer would use — and must never
gain a dependency the graded repos would need to accommodate. It is exempt
from the portfolio's "evals required" rule because it *is* the evals. Done
here means: a reproducible, deterministic, adversarial verdict on
`model × quant × backend × renderer` behavior, with divergence surfaced to a
human rather than silently auto-adjudicated (see `docs/ORIGINS.md` for the
incident that shaped this design).

## Build & test

```sh
swift build --build-tests   # build, including test targets
swift test                  # fixture-driven; no models, no network — hosted-CI safe
```

This is the exact sequence `ci.yml` and the weekly `rot-guard.yml` run — it
is the full-suite / merge-gate command, not a filtered subset. `swift build`
alone (no test targets) is a faster sanity check during iteration;
`swift run manifold-eval` with no arguments prints the eight-subcommand
usage. Executed locally for this change: `swift build` completes clean in
~45s (some deprecation warnings from `OllamaBackend` direct construction,
pre-existing, not from this change).

Live, hardware-gated eval lanes (`bfcl-generate`, `ifeval-generate`, `mteb`,
`diff`, `regress` — anything touching Ollama/llama.cpp on Apple Silicon) are
opt-in only and never run in hosted CI. `scripts/fetch-corpora.sh` pulls the
BFCL/MTEB corpora into `~/.cache/manifold-eval` for those local runs.

## Constraints & gotchas

- **Dependency direction is the whole point.** `Package.swift` pins
  ManifoldKit with `exact:`, not a range — an assurance repo whose premise
  is comparability against one specific core binary must not float that
  pin. Never add a dependency on `manifold-mlx` or `manifold-llama` as a
  library: they're invoked as separate processes (one collates their JSON
  `ConformanceRecord` output) because `llama_backend_init` is
  once-per-process and MLX needs serialized in-process Metal — see
  ManifoldKit #982 and the plan doc referenced in `Package.swift`.
- `core-bump.yml` auto-rewrites the exact pin on a ManifoldKit release
  (`repository_dispatch`), rebuilds/tests, and opens+admin-merges a `fix:`
  PR — gated on `RELEASE_AUTOMERGE_TOKEN`; if that secret is absent it just
  leaves the PR open. The org-move dispatch PAT is currently broken per
  ManifoldKit's own notes, so `workflow_dispatch` is the operative trigger
  for now — dispatch by hand.
- CI (`ci.yml`) skips draft PRs by design (draft = zero-CI staging area);
  it only runs on ready-for-review PRs or pushes to `main`.
- A dirty stray worktree, `~/Repos/manifold-eval-overnight` (modified
  `Package.swift`/`Package.resolved`, untracked `.overnight-runs/`), exists
  outside the normal worktree container — do not touch it; it is tracked
  separately in the estate contract as unresolved, not this repo's concern.

## Conventions

- Estate-wide rules apply (worktrees, secrets via `op run --env-file .env.tpl`,
  conventional commits) — see `~/Repos/estate/estate.yaml` `conventions:`.
- This repo's own worktree container is `manifold-eval-worktrees/`.
