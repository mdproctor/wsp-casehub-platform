# Handoff — Simulation DX (Slot 195)

## What happened this session

Implemented 7 of 9 platform issues for the simulation DX epic (#352). All XS/S scope, delivered with TDD, zero regressions across 152+ simulation-core tests.

| Issue | Title | What landed |
|-------|-------|------------|
| #353 | `Simulation.forTest()` fluent test harness | `Simulation` class + `Builder` with `stub()`/`seed()`/`resolve()`/`overlay()`/`verifier()`. 15 tests. |
| #354 | `seed.applyTo(runtime, corpus)` | `SimulationRuntime.apply(CorpusSeed)` — adapted to preserve module boundary. 2 tests. |
| #355 | `MapSimulationConfig.builder()` | Builder with `.strategy()`, `.capture()`, `.exhaustion()`, `.threshold()`. 5 tests. |
| #356 | Strategy name aliases | `resolveAlias()` maps key/seq/rand/replay/nearest to canonical forms. 5 tests. |
| #357 | `SimulationVerifier.on(overlay)` overload | Eliminates `.journal()` boilerplate. 1 test. |
| #358 | `simulation-starter` aggregate dep | POM module pulling all simulation artifacts. No tests (POM only). |
| #359 | Auto-detect identity key extractor | `requireExtractor()` falls back to `String.valueOf` identity. 2 new tests, 2 updated. |
| #360 | Default tenancyId for YAML corpus | `YamlCorpusLoader(defaultTenancyId)` + `casehub.simulation.default-tenancy-id` config. 3 tests. |

## Decisions

- **D354: API inversion** — issue said `seed.applyTo(runtime, corpus)` but CorpusSeed (simulation-api) can't depend on SimulationRuntime (simulation-core). Implemented as `runtime.apply(seed)` instead. One line, correct dependency direction.
- **D359: Identity fallback** — removed the "requires KeyExtractor" error from `requireExtractor()`. Falls back to `String.valueOf(input)`. Multi-param SPIs that need custom keys get `SimulationKeyNotFoundException` as the signal.

## Queue state

Position 8/10. Active issue: #361 (inline corpus entries in scenario YAML, M/Med).
Items #353-#360 complete. #361 needs brainstorming — it touches YAML schema design and scenario engine integration.
Remaining after #361: 2 pages-repo issues (casehub-pages#453, #454) — not implementable in this repo.

## Next action

Brainstorm #361 — inline corpus entries in scenario YAML. M/Med scope. Design the YAML schema for inline corpus blocks and how they integrate with the existing scenario parser. Then TDD.

## References

| Artifact | Path |
|----------|------|
| Epic #352 | casehubio/platform#352 |
| .plan | `wksp/.plan` (position 8/10, #361 active) |
| Design spec (#353) | `wksp/specs/issue-352-simulation-dx/2026-09-19-fluent-test-harness-design.md` |
| Decisions | `wksp/specs/issue-352-simulation-dx/decisions.md` |
| Implementation plan (#353) | `wksp/plans/2026-09-19-fluent-test-harness.md` |
| Simulation guide | `proj/docs/guides/simulation-guide.md` |
