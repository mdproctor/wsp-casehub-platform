# HANDOFF — Slot 198

## Status

**Branch:** issue-1206-spring-completeness
**Epic:** engine#1206 — Spring completeness
**Active issue:** engine#1208 — CDI modules without core extraction

## This Session

- Cherry-picked #1095 SPI work from canonical engine (4 commits → 1 squashed)
  - 5 SPI interfaces: EngineCaseApi, EngineCaseControlApi, EngineCaseDefinitionApi, EngineEventLogApi, EnginePlanApi
  - CaseContextView + CaseContextPathView typed DTOs
  - Business logic extracted to CaseService, CaseDefinitionService, EventLogService, PlanService
  - EvolutionApi deferred — graphql-spring-generator can't handle inner class types
- Surveyed 10 modules for #1208: 7 are pure wiring (no -core needed), 3 need work (eidos-routing, yaml-cbr, work-adapter)
- Resolved canonical engine overlap: slot is source of truth, canonical branch to be reset after work lands

## Prior Session

- Completed engine#1207: removed all Quarkus/CDI imports from 3 -core modules (8 commits, 97 files)
- Design spec + plan written for full epic (7 issues)

## Decisions

- Work order: #1207→#1208(excl rest)→#1209→#1210→#1211→#1095→#1199
- #1095 completed out of order (cherry-picked from canonical session)
- SPI interfaces are the right approach for REST domains (not class-based @McpDomain) — needed for Spring generators
- #1119's reversal of SPIs was premature optimization for Quarkus-only; Spring story requires interfaces
- 7 of 10 #1208 modules are pure CDI wiring — no -core extraction needed. Real scope: eidos-routing, yaml-cbr, work-adapter
- Event<T>→Consumer<T>, Instance<T>→Optional<T>/List<T> (platform pattern)

## Deferred

- spring-integration-test needs mock SPIs for newly-generated beans (RoutingSignalAssembler, resilience beans) — S/Low
- EvolutionApi @McpDomain SPI — blocked on graphql-spring-generator inner class type support

## Canonical Engine

Canonical engine branch `issue-1206-spring-completeness` has 7 commits (mix of #1095 + overlapping #1207 work). Slot cherry-picked the 4 clean #1095 commits. Canonical branch should be reset to main after slot work lands.

## References

- Spec: `specs/issue-1206-spring-completeness/2026-10-03-spring-completeness-design.md`
- Plan: `plans/2026-10-03-quarkus-leak-cleanup.md`
- Decisions: `specs/issue-1206-spring-completeness/decisions.md`
