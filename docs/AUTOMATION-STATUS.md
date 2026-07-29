# Automation status — the single source of truth

> **This is the only place in the repo that states what the automation currently does.** README,
> AGENTS.md, and [EVAL-IMPROVEMENT-LOOP.md](EVAL-IMPROVEMENT-LOOP.md) link here rather than
> restating it. If you are about to write "the X workflow currently…" in another file, put it here
> instead and link.
>
> Why the rule exists: this doc replaced four separate hand-written status claims that had drifted
> out of sync with reality and with each other. Two of them asserted the opposite of what the run
> history showed. Scattered status prose has no owner and no expiry, so it rots silently.

## Derived facts — guarded by a test

Everything in this section is **derivable from the workflow files themselves**, and
`AutomationClaimsTests` asserts this doc agrees with them. Change a workflow without updating this
table and `swift test` goes red.

| Automation | File | Triggers | Cadence |
|---|---|---|---|
| CI | `ci.yml` | `push` (main), `pull_request` | every push to main; **every** PR, drafts included (a draft gets a deliberate red — see below) |
| Rot-guard | `rot-guard.yml` | `schedule` `0 8 * * 1`, `workflow_dispatch` | weekly, Mondays 08:00 UTC |
| Core pin bump | `core-bump.yml` | `repository_dispatch`, `workflow_dispatch` | every ManifoldKit release |
| Release | `release-please.yml` | `push` (main), `workflow_dispatch` | every merge to main |

Three further guarded facts:

- **`ci.yml` has no path filter on `pull_request`** — it path-ignores `CHANGELOG.md` /
  `.release-please-manifest.json` on **`push` only**. The asymmetry is deliberate:
  `build-test / build-and-test` is a *required* check on main, and a workflow skipped by path
  filtering never reports it — the check sits pending and the PR is blocked. **Do not re-add a
  `paths-ignore` under `pull_request`**; a test fails if you do. (What this guard does *not* assert
  is that CI actually runs on release PRs — see *Release-PR checks* below.)
- **Core-bump commits `chore:`** — deliberately release-inert, so a pin bump does not open a patch
  release PR. Releases here cut only from this repo's own `feat:` / `fix:` work.
- **The rot-guard is Tier-1 only** — `swift build --build-tests` + `swift test`, no models, no
  hardware. A green rot-guard badge means *the surface still compiles and its fixture contracts
  hold*. It does **not** mean the models still score the same. See
  [CONCEPTS.md](CONCEPTS.md#tier-1-vs-hardware-gated).

## Not derivable from files

These depend on run history, org configuration, or human commitment. They cannot be guarded, so each
one carries an **as-of date and its evidence** — treat any of them older than a few months as
unverified.

### Dispatch PAT liveness — *as of 2026-07-29: working*

The `repository_dispatch` PAT was broken by the 2026-07 org move and re-scoped around 2026-07-03.
Evidence at time of writing (`gh run list --workflow=core-bump.yml`):

```
2026-07-28  repository_dispatch  success     <- 11 consecutive dispatch-driven runs
...                                             (one failure, 2026-07-11)
2026-07-03  repository_dispatch  success
2026-07-03  workflow_dispatch    success     <- last manual run
```

So no hand-dispatch is needed. `workflow_dispatch` remains available for catch-up runs. Re-check with
the command above; if the newest runs are `workflow_dispatch`, the PAT has regressed again.

### Release-PR checks — *unresolved as of 2026-07-29*

**Release-please PRs report no checks at all, and it is not yet proven why.** Releases 0.1.1, 0.1.2
and 0.1.3 each merged with an empty `statusCheckRollup` (admin bypass; `enforce_admins` is `false`),
and **0.1.4 (#54) is open and `BLOCKED` right now**. The four most recent releases in each of
manifold-mlx and manifold-llama look the same.

One cause is certain: `ci.yml` used to path-ignore exactly the two files a release PR touches, and a
path-skipped workflow never reports a required check. That filter is now removed from `pull_request`.

What is **not** established is whether that was the *only* blocker:

```sh
gh api "repos/ManifoldKit/manifold-eval/actions/runs?branch=release-please--branches--main"
#   → total_count: 0
```

Zero runs fits two explanations equally — the filter excluded them, *or* no workflow run is created
for these PRs at all (release-please posts as `app/github-actions` using the default `GITHUB_TOKEN`,
and `companion-release-please.yml` passes no `token:`). ManifoldKit core is evidence for the second,
and the case is exact rather than general: core's most recent release PR, **#2414**, happens to touch
`Sources/ManifoldMCP/ManifoldMCP.docc/Articles/MCPGettingStarted.md`, which matches core's `paths:`
allow-list — so it is *not* path-excluded. It still reports zero checks: its runs on that head all sit
`action_required`. (A changelog-only diff would miss core's allow-list too, which is why the specific
PR matters — pick a currently-passing one if re-checking.)

**How to settle it:** on the next release PR, re-run the command above. Runs present and green ⇒ the
path filter was the whole story. Still empty, or `action_required` ⇒ the remedy is a token that
triggers workflows for release-please (an App or PAT), not a path change. Core's
`ci-required-test-shim.yml` is the estate's other pattern for this, but it is itself
`pull_request`-triggered, so it cannot help if no run is created.

Until then, expect release PRs to still need a manual merge.

### Draft PRs — *red on purpose, as of 2026-07-29*

**A draft PR gets a deliberately FAILING `build-test / build-and-test` check.** It is not skipped and
it is not green. Verified 2026-07-29 on this repo's own PR #63: `conclusion: FAILURE` while
`isDraft: true`.

This is upstream behavior in `ManifoldKit/.github/.github/workflows/swift-ci.yml`, not something this
repo controls, and it is deliberate — the workflow's own comment records why the old
skip-on-draft guard was removed: **a *skipped* required check counts as PASSING for branch
protection**, so a draft could satisfy the gate without ever building, and stay satisfied after being
marked ready. manifold-llama#153 merged that way on 2026-07-20 — a `feat!:` breaking change, gate
never built it. Now the job always runs and fails fast on a draft, so the check can only be green if
a real build happened.

Cost is still near zero: drafts are routed to `ubuntu-latest` and run only `exit 1`, so no macOS
minutes burn. The practical effect is unchanged — a draft is still a staging area, `gh pr ready` is
still the deliberate trigger for the real gate — but expect red, not absent, and don't treat a red
draft check as a problem to fix.

The caller-side `pull_request: types:` list **must** keep `ready_for_review` — without it, a PR
opened as draft never fires an event this workflow subscribes to when marked ready, so the real gate
would never run and the check would stay red forever.

### Model-bearing sweep cadence — *open, no owner*

The lanes that carry the credibility numbers — live BFCL / IFEval / MTEB, cross-quant `regress` —
have **no scheduled cadence**. They run on demand, locally, on Apple Silicon. Nothing automated
measures whether the cells moved.

This is the honest gap, and it is the half that matters. The rot-guard covers the Tier-1 half only;
a green badge invites a reader to conclude something the rot-guard never measured. Recorded in
[ORIGINS principle #8](ORIGINS.md#principles-inherited-from-this-history-binding) — *no owner, no
repo* — as explicitly **not yet satisfied**. Don't let that note be deleted until a committed owner
and a fixed cadence exist.

## Adding a new automation

1. Add the workflow.
2. Add its row to the derived-facts table above.
3. Run `swift test` — `AutomationClaimsTests` will tell you if the row disagrees with the file.
4. Link here from anywhere that needs to mention it. **Do not restate its schedule or triggers**
   elsewhere; the test also asserts no other doc hard-codes a cron expression.
