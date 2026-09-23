# Handoff — Orchestration Primitives: Correlate, Deadline, Condition Combinators (#410, #420)

## What happened this session

Designed and implemented three yaml-core extensions (#410) plus TemporalSimulationDriver lifecycle migration (#420 Phase 1). Full lifecycle: brainstorming with first-principles analysis → design review (3 rounds) → TDD implementation → code review → merge to main.

| Deliverable | Detail |
|-------------|--------|
| OrcPrimitive | Lifecycle interface for polymorphic scope cleanup — replaces instanceof chain |
| Condition combinators | and/or/not/xor/always/never — full boolean algebra |
| awaitAnyState | Multi-target await on BlockingOrcStateMachine + releaseForClose |
| Deadline propagation | ScenarioScope.withDeadline — virtual-thread watcher, scope-chain, SpeedMultiplier-aware |
| EventRouter | Three-layer state machine architecture — string event dispatch, Builder .on() |
| Driver migration | TemporalSimulationDriver lifecycle → BlockingOrcStateMachine, simulation-core gains yaml-core dep |
| Tests | 70 tutorial-quality tests covering all capabilities and composition patterns |

## Key decisions

- **D1: Correlation = composition** — no new primitive. trigger+filter covers it. CorrelationScope utility deferred (#423).
- **D2: Scope-level deadlines** — withDeadline returns child scope. Parent-child cascading by construction (close cascade). DeadlineExceededException catchable by on-error.
- **D5: awaitAnyState** — genuine API gap (awaitState blocks forever on non-target states). Set<S> over Predicate<S>.
- **D7: Driver migration** — internal replacement, lifecycle() accessor exposed. COMPLETED is terminal (stop() from COMPLETED removed).
- **D8: Three-layer state machine** — Layer 1 (OrcStateMachine, unchanged), Layer 2 (EventRouter, this branch), Layer 3 (generated typed dispatch, future #424).

## Follow-up issues queued

| Issue | Scale | Notes |
|-------|-------|-------|
| #420 — YAML-driven orchestration (Phases 2-4) | L | Scenario runner, MCP migration, docs |
| #423 — CorrelationScope utility | S | Consuming-layer request/response lifecycle |
| #424 — Generated typed dispatch (Layer 3) | M | Java pattern matching on sealed event types |
| #425 — Extract orchestration-core module | S | Module boundary cleanup |

## Next action

`work next` — picks up #420 (Phases 2-4) from the queue.
