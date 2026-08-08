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
| CI | `ci.yml` | `push` (main), `pull_request` | every push to main **except** changelog/manifest-only; **every** PR, drafts included (a draft gets a deliberate red — see below) |
| Rot-guard | `rot-guard.yml` | `schedule` `0 8 * * 1`, `workflow_dispatch` | weekly, Mondays 08:00 UTC |
| Core pin bump | `core-bump.yml` | `repository_dispatch`, `workflow_dispatch` | every ManifoldKit release |
| Release | `release-please.yml` | `push` (main), `workflow_dispatch` | every merge to main |
| CodeQL | `codeql.yml` | `push` (main), `pull_request` (main), `schedule` `0 6 * * 1` | every push/PR to main, plus a weekly baseline scan Mondays 06:00 UTC. Scans the `actions` language only — no Python in this repo today (contrast manifold-mlx, which also scans `python`). Swift is not analyzed: CodeQL's Swift tracer wraps every `swiftc` invocation, and on ManifoldKit/ManifoldKit that pushed build times past a 30-minute timeout — see that repo's `codeql.yml` for the full story. |
| Dependency review | `dependency-review.yml` | `pull_request` | every PR that touches a dependency manifest |

**Note:** `codeql.yml` and `dependency-review.yml` are added by estate#49 and are not yet covered by
`AutomationClaimsTests` — `workflowFiles` there is a hardcoded four-file list
(`ci.yml`/`rot-guard.yml`/`core-bump.yml`/`release-please.yml`) rather than a directory scan, so these
two rows are hand-maintained for now, exactly the kind of drift this doc exists to prevent. Filed as
a follow-up to extend the guard rather than fixed here.

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

### Release-PR checks — *resolved 2026-07-29, and it took both halves*

**Release PRs now run CI and merge through the gate.** 0.1.4 (#54) was the first: required check
`build-test / build-and-test` reported `SUCCESS`, `mergeStateStatus` went `CLEAN`, and it merged with
no admin bypass. 0.1.1/0.1.2/0.1.3 had each merged with an empty `statusCheckRollup`.

There were **two** blockers stacked, which is why the first fix alone looked inert:

1. **The path filter** (`ci.yml` path-ignored exactly the two files a release PR touches). A
   path-skipped workflow never reports a required check, so no run existed at all —
   `actions/runs?branch=release-please--branches--main` returned `total_count: 0`. Removed from
   `pull_request` in #63.
2. **The approval gate.** With the filter gone a run *is* created, but it lands `action_required`
   (held pending approval) because release-please posts as `app/github-actions`. Held runs produce no
   check runs, so the PR still reads as having none.

Fixing only (1) moves the symptom from "no run" to "run held" — identical from the PR's point of
view. That is what ManifoldKit core shows: its release PRs are not path-excluded, yet still report
zero checks because their runs sit `action_required`.

**The release flow, until the approval gate is removed:**

```sh
# 1. find the held run for the release PR's head
gh run list --branch release-please--branches--main --limit 3 \
   --json databaseId,headSha,status,conclusion
# 2. approve it — a normal maintainer action, NOT a branch-protection bypass
gh api -X POST repos/ManifoldKit/manifold-eval/actions/runs/<id>/approve
# 3. wait for green, then merge normally
gh pr merge <n> --squash
```

Removing step 2 entirely would need release-please to post under an App/PAT identity rather than the
default `GITHUB_TOKEN` — that lives in `ManifoldKit/.github`'s `companion-release-please.yml`, is
shared with manifold-mlx and manifold-llama, and touches agent identity, so it is not a per-repo fix.

**manifold-mlx and manifold-llama deliberately still carry the path filter** — their `ci.yml` records
why (release Highlights are hand-edited, so a manual merge is already the flow). That divergence is
intentional, not drift.

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
