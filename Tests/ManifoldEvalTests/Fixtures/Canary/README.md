# Core-main canary failure fixture

`incompatible-core.patch` simulates a core API break by making
`ConformanceRecord.coreCommit` internal. Core itself still builds, but eval
reads this property across the package boundary.

On 2026-09-21, the patch applied to ManifoldKit main
`610c6a538da3e991eff88a510a1a804327974bca` in a disposable checkout.
A separate disposable eval checkout at `89764f5` then ran the pinned reusable
workflow's sequence with `./core` set to that patched checkout:

```sh
bash -e -c 'swift package edit manifoldkit --path ./core; swift build; swift test'
```

The command exited **1** during `swift build`. Swift reported
`'coreCommit' is inaccessible due to 'internal' protection level` in
`Sources/ManifoldEval/BaselineStore.swift:349` and `Collator.swift:37,152`.
The build log names `./core/Sources/ManifoldInference/Services/ModelExecutor.swift`,
and SwiftPM's `workspace-state.json` records the local `./core` path, confirming
that the unreleased checkout was selected. The `swift test` command was not
reached after the build failure. The opposite control, with clean core main
at the same SHA, passed `swift build` and all 468 then-current fixture tests.

`inert.yml` and `released-ref.yml` are separate workflow-config fixtures:
the former does no build, while the latter points the reusable canary at a
released tag. `AutomationClaimsTests` rejects both.
