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

## Session bootstrap (any harness)

1. Read `~/Repos/roryford/estate/policies/DIGEST.md` — the standing policies,
   compiled to one page.
2. Read this repo's known-issues buffer — solved non-obvious failures.
   **Check it before diagnosing**, and append to it when you solve one.
   Which file:
   - `.agents/known-issues.md` if present; otherwise `.claude/known-issues.md`
     (the older path, still in use in most repos). "Present" means it has
     content — a file that is empty, or only newlines and spaces, does not
     count. (Claude's hook prefers the committed copy on the default branch
     when *choosing* which file to read, then injects the **union** of that
     copy and yours — so an entry you wrote locally and have not pushed is
     normally still shown. Not always: if the union cannot be computed — a
     buffer with no entry markers, an unbalanced code fence, awk missing — the
     hook says so and withholds your local-only entries. A `NOTE` mentioning
     either is the hook refusing to guess, not a bug. Read the file yourself
     and you are never subject to any of this.)
   - **Append to the one that exists; never create the other.** Two files means
     half the entries stop being injected.
   - If **both** exist the buffer is already forked — **report it, don't repair
     it here.** Which half is dark depends on the machine's hook, so the repair
     has a per-machine precondition: see
     `~/Repos/roryford/estate/policies/knowledge-capture.md`, "Both files
     present".
   - If **neither** exists, create `.agents/known-issues.md` — the neutral
     path. (You are reading this section, so you will find it next time
     regardless of what any harness hook does.)
3. Then follow this file's Docs / Build & test / Constraints & gotchas /
   Conventions.

**If you are not Claude Code, none of the above happens for you automatically —
just do steps 1-3.** Claude Code *may* have injected 1 and 2 already via its
own SessionStart hook, but that hook is installed per machine and does not run
for Grok, Codex, Cursor or OpenCode whatever is on the box. Reading the files
yourself is always correct and never wrong, which is why the steps say "read".

Pointers only — this section never restates DIGEST content.

## Docs — read before changing behavior

`docs/README.md` is the index. Do not re-derive the vocabulary from source
comments; it is written down:

- **`docs/CONCEPTS.md`** — the terms this repo's code and comments assume:
  the `model × quant × backend × renderer` cell, the same-bytes control and
  the five divergence classifications, *absence ≠ failure*, determinism
  pinning, the four comparability guards, and the shared exit-code grammar
  (`0` clean / `1` a human should look / `3` indeterminate / `4` artifact).
  Source comments reference ORIGINS principles by number (`ORIGINS #3`,
  `#7`) — those numbers are stable and point at
  `docs/ORIGINS.md#principles-inherited-from-this-history-binding`.
- **`docs/EVAL-IMPROVEMENT-LOOP.md`** — how the lanes feed triage and fixes,
  plus the honest status of what is and isn't automated today.
- **`README.md` → "How the suite fits together"** — why the corpus lanes
  split into generator/scorer pairs, and which lane answers which question.

Two invariants worth stating here because breaking them is easy and silent:
**this repo emits evidence, never verdicts a human didn't make**, and a
*measured* zero must stay a zero while an *unmeasured* cell must never
render as one.

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
- **Automation status is stated in exactly one place:
  `docs/AUTOMATION-STATUS.md`** — triggers, cadence, and what each workflow
  does and doesn't prove. Don't restate any of it here or in the README;
  `AutomationClaimsTests` derives those facts from the workflow files and
  fails when a doc disagrees, and it also fails if another doc hard-codes a
  cron. Add a new workflow ⇒ add its row there.
- `core-bump.yml` auto-rewrites the exact pin on a ManifoldKit release,
  rebuilds/tests, and opens+admin-merges a release-inert PR (a pin bump must
  not trip release-please; releases here cut only from eval's own `feat:`/
  `fix:` work). Gated on `RELEASE_AUTOMERGE_TOKEN`; if that secret is absent
  it just leaves the PR open.
- **A draft PR shows a deliberately RED check** — expected, not a problem to
  fix, and **upstream behavior in the org reusable workflow, not ours to
  change locally**; don't try to "fix" it by editing `ci.yml`. `gh pr ready`
  triggers the real gate. Why, and the current state of release-PR checks:
  `docs/AUTOMATION-STATUS.md`.
- Keep `ready_for_review` in `ci.yml`'s `pull_request: types:` list — without
  it a PR opened as draft never fires an event this workflow subscribes to
  when marked ready, so the real gate would never run.
- A dirty stray worktree, `~/Repos/manifold-eval-overnight` (modified
  `Package.swift`/`Package.resolved`, untracked `.overnight-runs/`), exists
  outside the normal worktree container — do not touch it; it is tracked
  separately in the estate contract as unresolved, not this repo's concern.

## Conventions

- Estate-wide rules apply (worktrees, secrets via `op run --env-file .env.tpl`,
  conventional commits) — see `~/Repos/estate/estate.yaml` `conventions:`.
- This repo's own worktree container is `manifold-eval-worktrees/`.
