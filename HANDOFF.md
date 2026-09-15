# Handoff — Simulation Service (Slot 195)

## What happened this session

Two issues completed (#320, #317), advancing the queue from position 6/18 to 8/18.

**#320 — CaseMemoryStore simulation adapter (Path A):** Three generator enhancements + new module. (1) Generator now distinguishes abstract vs default methods — abstract methods get simulation/capture logic, default methods delegate to the wrapped bean. (2) Generator reads `META-INF/simulation-eligible.txt` listing files alongside annotation scan — enables simulation for SPIs in peer repos that can't depend on simulation-api. On-demand Jandex indexing from classpath for JARs without pre-built indexes. (3) New `memory-simulation-core` module with listing file for CaseMemoryStore — `SimulatedCaseMemoryStore` @Decorator generated at compile time. 5 integration tests verify strategy interception, capture, passthrough, and default method delegation.

**Key discovery:** CaseMemoryStore migrated from platform-api to neocortex-memory-api (neocortex#56). The issue assumed it was still in platform-api. The listing-file mechanism was built anyway — it's needed for any SPI in a peer repo, and keeps the change self-contained in platform.

**#317 — NearestMatchStrategy:** Constraint weighting and similarity scoring. `SimilarityScorer<I>` functional interface in simulation-api (parallel to KeyExtractor). `NearestMatchStrategy` in simulation-core — O(n) corpus scan, threshold-based matching. `RecordFieldScorer` + `FieldSimilarity` (EXACT, SUBSTRING, NUMERIC_RANGE, IGNORE) in simulation-config-core — field-based scoring via Jackson decomposition. `DeclarativeScorerFactory` parses config strings (`fields:domain:exact:1.0,question:substring:0.5`) into scorer instances. 22 tests across strategy, scorer, and factory. RecordFieldScorer placed in simulation-config-core (not simulation-core) because it needs Jackson — simulation-core remains zero-dep.

## Decisions

- **D17: Generic SimilarityScorer, not CBR reuse** — CBR's CbrSimilarityScorer operates on FeatureValue maps, wrong abstraction for arbitrary SPI inputs. Bridge to CBR is a consumer concern.
- **D18: Programmatic + declarative (both)** — RecordFieldScorer builder for power users, DeclarativeScorerFactory for config-driven. #329/#330 extend the declarative layer.
- **D19: Threshold on strategy, not scorer** — canResolve() returns false below threshold, resolve() throws SimulationNoMatchException. Default 0.0.
- **D20: O(n) scan, no indexing** — corpora are small (10-50 entries). Indexing is a follow-on if needed.

## References

| Artifact | Path |
|----------|------|
| Design spec (Phase 1) | `wksp/specs/feat-294-simulation-service/2026-09-15-simulation-service-design.md` |
| Design spec (#317) | `wksp/specs/feat-294-simulation-service/2026-09-16-nearest-match-strategy-design.md` |
| Implementation plan (#320) | `wksp/plans/2026-09-15-casememorystore-simulation-adapter.md` |
| Implementation plan (#317) | `wksp/plans/2026-09-16-nearest-match-strategy.md` |
| Decisions (D13-D20) | `wksp/specs/feat-294-simulation-service/decisions.md` |
| Simulation guide | `proj/docs/guides/simulation-guide.md` |
| .plan | `wksp/.plan` (position 8/18, #318 active) |

## Next action

Start #318 — event simulation. SimulatedEventEmitter + DataSource pipeline integration + @Scheduled emission. This is a different subsystem from strategies/scoring — needs its own brainstorming. The design spec sketches EventTrigger record and a scheduled emitter that resolves from a strategy and injects CloudEvents into the DataSource pipeline. Key question: tenant context for @Scheduled (runs outside request context — no CurrentPrincipal available).
