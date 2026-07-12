# Changelog

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
