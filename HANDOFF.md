# Handoff — Simulation Service (Slot 195)

## What happened this session

Phase 1 shipped — 5 modules, 112 tests, 8 commits. The core simulation framework is code-complete: SPI contracts, four strategy implementations, in-memory corpus, annotation processor, and AgentProvider backend adapter.

Consumer feedback from a banking platform evaluation surfaced a key insight: flat interfaces are a prerequisite for decorator-based simulation (captured as garden entry GE-20260915-0a4009). The user guide was written but identified as too mechanism-focused — needs domain scenarios and named patterns.

Phase 2 planned as epic #331 with 14 issues covering docs rewrite, YAML config, corpus builders, verification API, nearest-match strategy, event simulation, and more. Six new issues filed (#325-#332).

## Decisions

- **Config-driven scan for platform-api SPIs** (#320) — `@SimulationEligible` lives in simulation-api, so platform-api SPIs can't use it. Solution: generator reads `META-INF/simulation-eligible.txt` alongside annotation scan.
- **Guide structure** — must lead with domain scenarios (simulate a payment gateway, replace a judge LLM, replay a ticker stream), not mechanism. Named patterns cross-referenced to tutorial tests.
- **Corpus population** is the adoption bottleneck — hand-constructing InvocationRecords doesn't scale. Filed #328 (corpus builders) and #330 (domain data generation).

## References

| Artifact | Path |
|----------|------|
| Design spec | `wksp/specs/feat-294-simulation-service/2026-09-15-simulation-service-design.md` |
| Implementation plan | `wksp/plans/2026-09-15-simulation-service.md` |
| User guide | `proj/docs/guides/simulation-guide.md` |
| Design journal | `wksp/JOURNAL.md` |
| Diary entry | `wksp/blog/2026-09-15-mdp01-the-simulation-gap.md` |
| Phase 2 epic | casehubio/platform#331 |
| .plan | `wksp/.plan` (position 4/18, #327 active) |

## Next action

Start #327 — docs rewrite with named patterns, use-case catalog, and domain scenarios. This is the foundation that makes every subsequent issue coherent.
