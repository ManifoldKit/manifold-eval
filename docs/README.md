# Docs index

Four documents, four different questions. Start wherever your question is.

| If you're asking… | Read |
|---|---|
| *What do these words mean?* — the cell, same-bytes control, absence ≠ failure, exit codes | [CONCEPTS.md](CONCEPTS.md) |
| *Why does this repo exist at all, separate from ManifoldKit?* | [ORIGINS.md](ORIGINS.md) |
| *I have eval output — now what?* | [EVAL-IMPROVEMENT-LOOP.md](EVAL-IMPROVEMENT-LOOP.md) |
| *What runs automatically, and what doesn't?* | [AUTOMATION-STATUS.md](AUTOMATION-STATUS.md) |
| *Does the regression gate actually work on real models?* | [P4-VERIFICATION.md](P4-VERIFICATION.md) |
| *How do I run a specific command?* | the [README](../README.md) |
| *How do I work on this repo?* | [AGENTS.md](../AGENTS.md) |

**Suggested reading order for a newcomer:** README (intro + "How the suite fits together") →
CONCEPTS → EVAL-IMPROVEMENT-LOOP → ORIGINS when you want the full decision history.

A note on genre: **CONCEPTS**, **EVAL-IMPROVEMENT-LOOP**, and **AUTOMATION-STATUS** are living
documents — they describe how things work now. **ORIGINS** is a heritage record, and
**P4-VERIFICATION** is a dated evidence record of one verification run. The latter two are
deliberately not kept current; they're what was true and why, at the time.

**AUTOMATION-STATUS is the single source of truth for what runs automatically.** Nothing else in the
repo should state a schedule or trigger — a test enforces it. That rule exists because four
hand-written copies of that status drifted apart, two of them into claiming the opposite of reality.
