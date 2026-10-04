# HANDOFF — Slot 198

## Status

**Branch:** issue-1206-spring-completeness
**Epic:** engine#1206 — Spring completeness
**Active issue:** engine#1208 — CDI modules without core extraction
**State:** work-adapter complete — all 3 modules done, ready to advance to #1209

## This Session

- Completed all 8 remaining work-adapter CDI removals (4 commits):
  - HumanTaskRecoveryService: @Inject → constructor, @Observes StartupEvent → init()
  - CaseCompensationNotifier: Instance<T> → Optional<T>, @ObservesAsync → public method
  - CompensationSubscriptionBootstrap: 2× Instance<T> → Optional<T>, @Observes StartupEvent → init()
  - ActionGateCancelledHandler: @ConsumeEvent → public method, constructor injection
  - ActionGateCompletionApplier: EventBus → 3× Consumer<T> callbacks
  - WorkStrategyContributor: 4× Instance<T> @Any → List<T>, startup → init()
  - WorkItemLifecycleAdapter: EventBus → Consumer<T>, @ObservesAsync → public methods
  - PlanItemCompletionApplier: 2× Event<T> → Consumer<T>, EventBus → Consumer<T>, 8 fields → constructor
- Expanded EngineAdapterBeans with @Produces for all 10 POJOs + CDI observer bridges + EventBus consumer bridge + startup init
- Updated 3 tests: CaseCompensationNotifierTest, CompensationSubscriptionBootstrapTest (constructor instead of reflection), HumanTaskRecoveryServiceTest (onStart→init)
- Compilation verified. 16 unit tests pass. @QuarkusTest tests fail due to pre-existing CDI errors (stigmergy/convergence/improvement — unrelated)

## Resume Point

Issue #1208 is complete (all 3 modules: eidos-routing, yaml-cbr, work-adapter). Advance to #1209 — MCP Spring module.

## Architecture Decisions (this session)

- **SPI interfaces for REST domains confirmed.** #1119's reversal (class-based @McpDomain) was premature — Spring generators need SPI interfaces. Platform supports both modes; SPIs are right for Spring story.
- **7 of 10 #1208 modules need NO -core extraction.** a2a, actor-state, engine-ai, flow, mcp, queue, work-cloudevent are pure CDI wiring — POJOs already live in engine-support-core.
- **eidos-routing and yaml-cbr cleaned in-place** (no -core modules) — too small to warrant separate modules.
- **work-adapter gets in-place cleanup** (not -core extraction) — same module, POJOs + quarkus/ wiring class.
- **@Transactional stays on POJOs** — jakarta.transaction, not CDI-specific.
- **Vert.x EventBus → Consumer<T>** — framework-neutral callback, CDI wiring bridges to EventBus.

## Canonical Engine State

Canonical engine branch `issue-1206-spring-completeness` has 7 commits (4 cherry-picked here, 3 discarded — overlapping #1207 work + reverted EvolutionApi). **Reset to main after slot work lands.**

## Prior Session

- Completed engine#1207: removed all Quarkus/CDI imports from 3 -core modules (8 commits, 97 files)
- Design spec + plan written for full epic

## Deferred

- spring-integration-test needs mock SPIs for newly-generated beans (RoutingSignalAssembler, resilience beans) — S/Low
- EvolutionApi @McpDomain SPI — blocked on graphql-spring-generator inner class type support

## References

- Spec: `specs/issue-1206-spring-completeness/2026-10-03-spring-completeness-design.md`
- Plan: `plans/2026-10-03-quarkus-leak-cleanup.md`
- Decisions: `specs/issue-1206-spring-completeness/decisions.md`
