# HANDOFF — Slot 198

## Status

**Branch:** issue-1206-spring-completeness
**Epic:** engine#1206 — Spring completeness
**Active issue:** engine#1208 — CDI modules without core extraction
**State:** in progress — 2 of 3 modules done, work-adapter partially started

## This Session

- Resolved canonical engine overlap: two sessions working same epic on same branch name
  - Canonical had 7 commits (mix of #1095 SPI + overlapping #1207 cleanup)
  - Cherry-picked 4 clean #1095 commits into slot (SPI interfaces for 5 REST domains)
  - Canonical branch to be reset to main after this work lands
- Advanced .plan: #1206 and #1207 marked done, #1208 active
- Surveyed 10 modules for #1208: 7 are pure CDI wiring (no -core needed), 3 need work
- Completed eidos-routing: EngineAwareAgentSelector → POJO, Instance<T> → Optional<T>/direct, new EidosRoutingBeans
- Completed yaml-cbr: StepExecutionCbrBridge + StepFileCallableDispatcher → POJOs, new YamlCbrBeans
- Started work-adapter: HumanTaskScheduleHandler + JudgmentWorkItemScheduler → constructor injection (2 of 10 CDI files done)

## Resume Point

Continue work-adapter CDI removal. 8 files remaining:

| File | Key patterns | Difficulty |
|------|-------------|------------|
| ActionGateCancelledHandler | @ConsumeEvent (Vert.x), @Transactional | Medium |
| ActionGateCompletionApplier | EventBus (Vert.x) → Consumer<T> | Medium |
| CaseCompensationNotifier | Instance<T> → Optional<T>, @ObservesAsync | Easy |
| CompensationSubscriptionBootstrap | 2× Instance<T> → Optional<T>, @Observes StartupEvent → @PostConstruct | Easy |
| PlanItemCompletionApplier | 2× Event<T> → Consumer<T>, EventBus → Consumer<T>, 8 fields | Hard |
| WorkItemLifecycleAdapter | EventBus, 2× @ObservesAsync | Medium |
| WorkStrategyContributor | 4× Instance<T> @Any → List<T>, @Observes StartupEvent | Medium |
| recovery/HumanTaskRecoveryService | @Observes @Priority StartupEvent | Easy |

After all 10 files: expand EngineAdapterBeans with @Produces for all cleaned classes. Tests may need constructor updates.

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
