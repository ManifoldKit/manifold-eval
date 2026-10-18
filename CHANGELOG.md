# Changelog

## [0.1.8](https://github.com/ManifoldKit/manifold-eval/compare/v0.1.7...v0.1.8) (2026-10-18)


### Bug Fixes

* **ci:** sync release notes from tagged changelog ([#86](https://github.com/ManifoldKit/manifold-eval/issues/86)) ([450def0](https://github.com/ManifoldKit/manifold-eval/commit/450def0fe72adce4ec7d44d85262bc1fd4958b96))

## [0.1.7](https://github.com/ManifoldKit/manifold-eval/compare/v0.1.6...v0.1.7) (2026-10-17)

manifold-eval 0.1.7 aligns the assurance harness with ManifoldKit 0.79.1,
protects remote benchmark traffic, and makes live smoke-test failures visible.
This release requires **macOS 26 or later**.

### Highlights

#### Run against ManifoldKit 0.79.1 on macOS 26

The harness now pins ManifoldKit exactly to 0.79.1, replacing the 0.78.0 pin
in 0.1.6. Its deployment floor moves from macOS 15 to macOS 26 to match core;
users who need macOS 15 should stay on manifold-eval 0.1.6 and core 0.78.0
([#81](https://github.com/ManifoldKit/manifold-eval/pull/81),
[#85](https://github.com/ManifoldKit/manifold-eval/pull/85)).

#### Protect remote benchmark traffic

Benchmark endpoints outside the local machine must use HTTPS. Plain HTTP is
accepted only for recognized loopback identities: `localhost`, IPv4
`127.0.0.0/8`, and IPv6 `::1`. Redirects cannot downgrade HTTPS to HTTP, and
cross-origin redirects strip authorization, cookie, proxy-authorization, and
`X-API-*` headers
([#77](https://github.com/ManifoldKit/manifold-eval/pull/77)).

#### Surface failed live tool-loop episodes

The live tool-loop smoke test now fails when generation produces errored
episodes, even if the expected number of transcript entries exists. Errors
include episode diagnostics and remain unmeasured infrastructure failures;
a clean run with no structured tool calls still counts as a measured
capability zero
([#83](https://github.com/ManifoldKit/manifold-eval/pull/83)).

### Validation scope

The default build and test gate exercises deterministic fixtures. It does
not run live models or establish new model-quality or performance results.

## [0.1.6](https://github.com/ManifoldKit/manifold-eval/compare/v0.1.5...v0.1.6) (2026-09-10)


### Highlights

**Run the assurance harness against ManifoldKit 0.78.0.** This requested
compatibility release packages the exact core pin already merged on main.
It adds no eval lanes, scoring changes, or new model-quality claims; fixture
tests verify the harness contracts, not live model behavior.

### Dependencies

- Pin ManifoldKit to exactly 0.78.0, including the published revision in
  Package.resolved ([#75](https://github.com/ManifoldKit/manifold-eval/pull/75)).
- Include the CodeQL action updates merged since 0.1.5
  ([#71](https://github.com/ManifoldKit/manifold-eval/pull/71),
  [#73](https://github.com/ManifoldKit/manifold-eval/pull/73)).

## [0.1.5](https://github.com/ManifoldKit/manifold-eval/compare/v0.1.4...v0.1.5) (2026-08-08)


### Features

* **ci:** supply-chain posture — permissions, CodeQL, dependency review ([#67](https://github.com/ManifoldKit/manifold-eval/issues/67)) ([cb3d1b0](https://github.com/ManifoldKit/manifold-eval/commit/cb3d1b059cfad7bc143442c2ed9c1038ae804bf0))

## [0.1.4](https://github.com/ManifoldKit/manifold-eval/compare/v0.1.3...v0.1.4) (2026-07-29)


### Features

* **perf:** capture Ollama load/prefill/decode split and cold-start ([#56](https://github.com/ManifoldKit/manifold-eval/issues/56)) ([7eb89b7](https://github.com/ManifoldKit/manifold-eval/commit/7eb89b76bf6e8422e2222bfd40069e3229d3469b))


### Bug Fixes

* **ci:** stop path-filtering PRs so the required check can report ([#63](https://github.com/ManifoldKit/manifold-eval/issues/63)) ([12ffae5](https://github.com/ManifoldKit/manifold-eval/commit/12ffae5957f6dca8d8a327da0e246c5ba8d4db7c))
* **perf:** correct specHash workload identity + add publication plumbing ([#53](https://github.com/ManifoldKit/manifold-eval/issues/53)) ([fcda579](https://github.com/ManifoldKit/manifold-eval/commit/fcda579edd4787fa1df0d12d1e7dc47816c7e647))

## [0.1.3](https://github.com/ManifoldKit/manifold-eval/compare/v0.1.2...v0.1.3) (2026-07-20)


### Features

* **perf:** validate bench protocol and result sample counts ([#48](https://github.com/ManifoldKit/manifold-eval/issues/48)) ([1d40b07](https://github.com/ManifoldKit/manifold-eval/commit/1d40b0717b23efc21439d697cec822f16e3bba37))

## [0.1.2](https://github.com/ManifoldKit/manifold-eval/compare/v0.1.1...v0.1.2) (2026-07-13)


### Features

* **perf:** spec-driven local-inference perf harness (HTTP-driver spine) ([#43](https://github.com/ManifoldKit/manifold-eval/issues/43)) ([692c50e](https://github.com/ManifoldKit/manifold-eval/commit/692c50e7b170da21e065e42dbd2ebe0343db559b))

## [0.1.1](https://github.com/ManifoldKit/manifold-eval/compare/v0.1.0...v0.1.1) (2026-07-12)

First release cut by release-please — manifold-eval now versions its own
assurance-surface work (pin bumps to new core versions are release-inert
`chore:` commits from here on).

### Highlights

**Multi-turn tool-loop conformance lane** ([#32](https://github.com/ManifoldKit/manifold-eval/pull/32))
A new `toolloop` lane exercises multi-turn tool-call loops and scores
tool-result threading across turns, shipped with its live driver
(`toolloop-generate`) that runs an Ollama model over the corpus with the
case's scripted tools registered in a real `ToolRegistry`.

**Per-cell baseline store + rot-guard** ([#30](https://github.com/ManifoldKit/manifold-eval/pull/30))
`BaselineStore` persists a deterministically-serialized baseline per cell
(`model × quant × backend × renderer`), so the rot-guard can detect a cell
regressing against its own recorded score/bytes rather than an absolute
threshold.

**Pre-triage assistant for flagged cells** ([#29](https://github.com/ManifoldKit/manifold-eval/pull/29))
A `triage` subcommand reads a flagged cell's raw transcript and emits a
structured pre-triage brief — proposed divergence classification, the exact
differing bytes between legs, and a confidence read — while leaving the
recorded verdict unset until a human rules.

**Dismissals ledger for confirmed by-design divergences** ([#28](https://github.com/ManifoldKit/manifold-eval/pull/28))
Settled `cell + divergence-signature` pairs are suppressed from re-triage
until a re-check expiry lapses, so known by-design divergences stop
resurfacing in every run.

### Fixes

* bump ManifoldKit pin to v0.65.0 ([#18](https://github.com/ManifoldKit/manifold-eval/issues/18)) ([aa04cdd](https://github.com/ManifoldKit/manifold-eval/commit/aa04cddfefbd53f61205c0af3d77c0b3abd83dd3))
* bump ManifoldKit pin to v0.66.0 ([#33](https://github.com/ManifoldKit/manifold-eval/issues/33)) ([348e2e2](https://github.com/ManifoldKit/manifold-eval/commit/348e2e211a30781f3f8f24d39b0bf4999d5563d4))
* bump ManifoldKit pin to v0.67.0 ([#34](https://github.com/ManifoldKit/manifold-eval/issues/34)) ([3fd4a10](https://github.com/ManifoldKit/manifold-eval/commit/3fd4a1000cbd1e6b3d6230462b603c65625784de))
* bump ManifoldKit pin to v0.68.0 ([#36](https://github.com/ManifoldKit/manifold-eval/issues/36)) ([0e458cc](https://github.com/ManifoldKit/manifold-eval/commit/0e458cc7f3de9653e9b578a5df64351b9293e5d9))
* bump ManifoldKit pin to v0.70.0 ([#39](https://github.com/ManifoldKit/manifold-eval/issues/39)) ([deefa04](https://github.com/ManifoldKit/manifold-eval/commit/deefa04c45f1bd915a057582a14c10a3277aa580))
