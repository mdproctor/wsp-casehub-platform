# Event Sequence Patterns — Composable CEP Primitives for Playbook Language

**Epic:** casehubio/platform#600
**Branch:** issue-600-event-sequence-patterns
**Date:** 2026-10-13

## Overview

Add composable event sequence matching to the playbook language. Patterns like
`((A then B) or (A then C))*` are expressed as nested YAML structures using
existing primitives (block, loop, from, timeout) plus two new ones (race,
named consumer control).

This is a lightweight sequencing layer — not a CEP engine. Drools CEP handles
production-grade temporal reasoning. This layer gives playbook authors basic
pattern matching composable from existing decorators.

**Design principle:** patterns are recursive. Every composition operator
(sequence, alternation, repetition, negation) can contain any other.
`block:` nests inside `race:` nests inside `loop:` — the grammar is
regular-recursive.

## Pattern Operators → Playbook Mapping

| Pattern | Regex analogue | Playbook expression |
|---------|---------------|---------------------|
| Sequence | `A B` | `block:` with sequential `from:` reads |
| Alternation | `A \| B` | `race:` — first-to-complete wins |
| Repetition | `A*` / `A{n}` | `loop:` wrapping a pattern group |
| Temporal window | `A B[5m]` | `timeout:` on a block |
| Negation/absence | `(?!B)` | `timeout:` as success path |
| Timed absence | `A then !B[5m]` | Sequence: from: A, then timeout: on from: B — timeout = match |
| Delayed trigger | `A then delay(30s) then B` | Sequence with `delay:` between from: reads |
| Periodic check | `every 10s: check` | `loop: continuous` + `delay: 10s` |
| Sub-pattern | `(A B)` | `block:` as a group |
| Recursive | `((A B) \| (A C))*` | `loop: { race: [ block: [...], block: [...] ] }` |

## Architecture

All changes are in two modules:

- **yaml-core** (`io.casehub.yaml.core.orchestration`) — new `ConsumerHandle` primitive
- **yaml-step-runtime** (`io.casehub.yaml.step`) — from: hardening, RaceStep, ControlStep

No new modules. No new dependencies. No CDI changes. Pure Java, J2CL-safe
(yaml-core), virtual-thread-safe (no `synchronized`).

## Component Design

### 1. ConsumerHandle — Named Consumer Primitive

New interface in `io.casehub.yaml.core.orchestration`:

```java
public interface ConsumerHandle extends OrcPrimitive {
    void pause();
    void resume();
    boolean isRunning();
}
```

**Implementation (`DefaultConsumerHandle`):**
- `volatile boolean running = true` (starts running)
- `pause()` sets `running = false`
- `resume()` sets `running = true`
- `isRunning()` returns `running` (single volatile read)
- `releaseForClose()` sets `running = false` (scope cleanup unblocks paused consumers via timed-receive wakeup)

**Registration in ExecutionScope:**
- Add `ConsumerHandle consumerHandle(String name)` to `ExecutionScope`
- `DefaultExecutionScope` registers via `getOrCreate(name, ConsumerHandle.class, DefaultConsumerHandle::new)`

**Why not OrcFlag:** User requirement — "I can see more being needed." ConsumerHandle
is architecturally positioned for future lifecycle extensions (begin/end, metrics,
listeners) without modifying from: or ControlStep. The current implementation is
a volatile boolean, but the type boundary enables growth.

### 2. from: Decorator Hardening

Modify `DecoratorChain.wrapFromSingleChannel()` to add three capabilities:

#### 2a. Channel close handling

After `channel.receive()`:
- Null return → `Result.of(Map.of("from.stream-ended", true))` (graceful exit)
- `channel.isErrorClosed()` → `Result.failed("channel closed: " + channel.closeError().getMessage())`

Channel close is a coordination signal: closing a channel implicitly tells all
consumers to exit. This is intentional (CSP pattern) and must be documented.

#### 2b. until: condition

New field in from: map syntax: `from: { channel: x, until: "expr" }`.

Before each receive attempt, evaluate the until expression against the current
resolver. If true, return stream-ended success. Uses timed receive (100ms) so
the condition can be re-checked between attempts.

#### 2c. Named consumers with pause/resume

New field in from: map syntax: `from: { channel: x, name: "enricher" }`.

**Registration:** The ConsumerHandle is registered eagerly during `wrapFrom`
construction — in the lambda-building phase, not inside the returned lambda's
execution. This ensures the handle exists in ExecutionScope before any
`background:` decorator spawns the virtual thread, preventing the race condition
where `pause: enricher` executes before the consumer registers its handle.

```java
// In wrapFrom, during lambda construction (synchronous):
ConsumerHandle handle = scope.consumerHandle(handleName);

// In the returned lambda (may run on background thread):
return ctx -> {
    while (true) {
        if (!handle.isRunning()) { Thread.sleep(100); continue; }
        // ... receive logic
    }
};
```

**Receive loop** (unified, when `name:` or `until:` is present):

```
loop:
  1. Check handle.isRunning() → if paused, sleep 100ms, continue
  2. Check until condition → if true, return stream-ended success
  3. Timed receive (100ms) from channel
  4. If null (timeout) → continue (re-check conditions)
  5. If null (channel closed) → return stream-ended success
  6. If error-closed → return failure
  7. Apply filter → if rejected, continue
  8. Inject into scope, execute inner step
```

Plain `from:` (no name, no until) retains the current blocking receive — zero
overhead for the common case.

**Backpressure:** When a consumer is paused, its channel continues to buffer.
Bounded channels (`channel(name, capacity)`) may block producers. This is
expected — pause intentionally creates upstream backpressure.

### 3. ControlStep — pause:/resume: Step Type

New variant in `ResolvedStep` sealed hierarchy:

```java
record ControlStep(
    String name,
    String target,
    boolean activate,
    Map<String, Object> decorators
) implements ResolvedStep
```

- `pause: enricher` → `ControlStep(null, "enricher", false, Map.of())`
- `resume: enricher` → `ControlStep(null, "enricher", true, Map.of())`

**Evaluation in StructuralStepEvaluator:**

```java
case ResolvedStep.ControlStep c -> evaluateControl(c);
```

```java
private Result evaluateControl(ResolvedStep.ControlStep control) {
    if (scope == null) return Result.failed("'pause'/'resume' requires an ExecutionScope");
    ConsumerHandle handle = scope.primitive(control.target(), ConsumerHandle.class);
    if (handle == null) return Result.failed("Consumer '" + control.target() + "' not found");
    if (control.activate()) handle.resume(); else handle.pause();
    return Result.of(Map.of());
}
```

**Naming semantics:** pause/resume instead of stop/start. Communicates continuity —
the consumer is suspended, not destroyed. Leaves room for begin/end lifecycle
boundaries if needed (serverless workflow alignment).

### 4. RaceStep — First-to-Complete Alternation

New variant in `ResolvedStep` sealed hierarchy:

```java
record RaceStep(
    String name,
    List<ResolvedStep> branches,
    Map<String, Object> decorators
) implements ResolvedStep {
    public RaceStep {
        if (branches == null || branches.size() < 2) {
            throw new IllegalArgumentException("race requires at least 2 branches");
        }
        branches = List.copyOf(branches);
        decorators = Map.copyOf(decorators);
    }
}
```

YAML syntax:
```yaml
- race:
    - block:
        - from: { channel: events, filter: "type == LOGIN" }
        - from: { channel: events, filter: "type == MFA_CONFIRM" }
    - block:
        - from: { channel: events, filter: "type == LOGIN" }
        - from: { channel: events, filter: "type == SSO_TOKEN" }
```

**Evaluation in StructuralStepEvaluator:**

Same pattern as `evaluateSelect`: launch each branch on a virtual thread via
`newVirtualThreadPerTaskExecutor()`. First successful result wins via
`AtomicReference.compareAndSet()`. Winner cancels remaining branches via
`future.cancel(true)`, which interrupts their threads.

```java
private Result evaluateRace(ResolvedStep.RaceStep race, StepContext ctx, StepRunner runner) {
    int branchCount = race.branches().size();
    var winnerResult = new AtomicReference<Result>();
    var winnerIndex = new AtomicInteger(-1);
    Future<?>[] futures = new Future<?>[branchCount];

    try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
        for (int i = 0; i < branchCount; i++) {
            int idx = i;
            ResolvedStep branch = race.branches().get(i);
            futures[i] = executor.submit(() -> {
                Result result = evaluateInternal(branch, ctx, runner);
                if (result.isSuccess() && winnerIndex.compareAndSet(-1, idx)) {
                    winnerResult.set(result);
                    for (int j = 0; j < branchCount; j++) {
                        if (j != idx && futures[j] != null) futures[j].cancel(true);
                    }
                }
            });
        }
        for (Future<?> f : futures) {
            try { f.get(); }
            catch (ExecutionException | CancellationException e) { /* expected */ }
        }
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        return Result.failed("Race interrupted");
    }

    Result result = winnerResult.get();
    return result != null ? result : Result.failed("No race branch completed successfully");
}
```

**Cancellation:** `future.cancel(true)` interrupts the branch thread. `from:`
decorators already handle `InterruptedException` cleanly (return failure + set
interrupt flag). Nested `channel.receive()`, `signal.await()`, `Thread.sleep()`
all throw `InterruptedException` — the interrupt propagates through the entire
branch stack.

**Decorator support:** RaceStep has `decorators()` like all ResolvedStep variants.
Wrapping race: with `loop:`, `timeout:`, `background:` etc. composes naturally.
`loop: continuous` + `race:` = `(pattern)*` repetition.

### 5. Walker / StepSchemaComposer Changes

- `StepSchemaComposer.DECORATOR_KEYS` already contains `race` — used for keyword
  recognition during parsing. No change needed.
- **Walker:** Add `race:` → `RaceStep` parsing alongside `block:`/`parallel:`.
  Parse `race:` value as a list of child steps (same as `parallel:`).
- **Walker:** Add `pause:` → `ControlStep(target, false)` and `resume:` →
  `ControlStep(target, true)` parsing. Value is a string (the target consumer name).
- Add `pause` and `resume` to `DECORATOR_KEYS` for keyword recognition.

## Temporal Pattern Composition

These patterns compose from existing decorators — no new code, just documentation
and tests verifying the composition works correctly.

### Timed Absence — "A happened, B didn't follow within N"

```yaml
- block:
    - from: { channel: events, filter: "type == EXPANSION_STARTED" }
    - action: watch-for-defense
      from: { channel: events, filter: "type == ARMY_MOVED_TO_NATURAL" }
      timeout: 30s
      on-error: greedy-build-detected   # timeout = absence = pattern matched
```

Decorator ordering: `on-error` (4) wraps `from` (4.5) wraps `timeout` (5).
Timeout fires → from: interrupted → on-error catches → returns fallback step name.

### Delayed Sequence — "wait N after A before checking for B"

```yaml
- block:
    - from: { channel: events, filter: "type == SCOUT_SPOTTED" }
    - delay: 15s
    - from: { channel: events, filter: "type == COUNTER_PREPARED" }
      timeout: 45s
      on-error: unprepared-alert
```

`delay:` respects `speedMultiplier` for simulation time acceleration.

### Periodic Absence (Heartbeat) — "every N, check signal arrived"

```yaml
- action: heartbeat-monitor
  loop: continuous
  background: true
  delay: 10s
  block:
    - from: { channel: heartbeats, filter: "source == agent-7" }
      timeout: 10s
      on-error: agent-unresponsive
```

### Recursive Sub-Pattern — `((A then B) or (A then C))*`

```yaml
- loop: continuous
  background: true
  race:
    - block:
        - from: { channel: events, filter: "type == A" }
        - from: { channel: events, filter: "type == B" }
        - publish: { channel: matched, data: "AB" }
    - block:
        - from: { channel: events, filter: "type == A" }
        - from: { channel: events, filter: "type == C" }
        - publish: { channel: matched, data: "AC" }
```

Inject event sequence [A, B, A, C, A, B] → matched channel receives [AB, AC, AB].

## Implementation Order

Dependency graph:

```
ConsumerHandle (yaml-core)
    ↓
from: hardening (#601 + #602 combined)  ──→  ControlStep (#602)
    ↓                                            ↓
Temporal pattern tests (#604)              RaceStep (#603)
    ↓                                            ↓
    └────────────→ Recursive composition (#605) ←┘
```

**Batch 1:** ConsumerHandle + from: hardening + ControlStep (foundation)
**Batch 2:** RaceStep (structural step, independent of from: changes)
**Batch 3:** Temporal pattern tests + recursive composition (integration tests)

## Testing Strategy

| Component | Test type | Key scenarios |
|-----------|-----------|---------------|
| ConsumerHandle | Unit | pause/resume/isRunning, releaseForClose, concurrent access |
| from: until | Unit (DecoratorChainTest) | condition true → exit, condition false → continue, timed re-check |
| from: channel close | Unit (DecoratorChainTest) | null return → success, error-close → failure |
| from: named consumer | Unit (DecoratorChainTest) | handle registration, pause blocks receive, resume unblocks |
| ControlStep | Unit (StructuralStepEvaluatorTest) | pause/resume dispatch, missing handle → error |
| RaceStep | Unit (StructuralStepEvaluatorTest) | first-wins, loser-cancelled, all-fail, nested blocks |
| Background + pause race | Concurrent | pause: immediately after background from: — handle exists |
| Timed absence | Integration | timeout fires (absence), event arrives (no absence) |
| Delayed sequence | Integration | delay respects speedMultiplier, timeout after delay |
| Periodic heartbeat | Integration | heartbeat arrives (ok), heartbeat missing (alert) |
| Recursive composition | Integration | [A,B,A,C,A,B] → [AB,AC,AB], three-level nesting |

## Out of Scope

- Full temporal reasoning (Rete/PHREAK temporal network) — Drools CEP
- Event correlation across streams with shared state — Drools CEP
- Pattern DSL compiling to playbook YAML — future if YAML proves too verbose
- Windowed aggregation — plugin concern, not language primitive
- begin/end consumer lifecycle — future extension on ConsumerHandle

## References

- casehubio/platform#564 — from: decorator (landed, commit c5c46fc8)
- casehubio/platform#562 — at:, on-complete:, resource:, priority: (landed)
- casehubio/platform#563 — loop continuous, cancel, background (landed)
- DecoratorChain.java — decorator ordering and from: implementation
- StructuralStepEvaluator.java — structural step dispatch, SelectStep early-termination pattern
- ResolvedStep.java — sealed hierarchy (10 current variants → 12 with RaceStep + ControlStep)
- OrcChannel.java — channel API (send/receive/close)
- ExecutionScope.java — primitive registration pattern
- OrcFlag.java — existing boolean primitive (ConsumerHandle supersedes for this use case)
