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
| Timed absence | `A then !B[5m]` | Nested `block:` with `timeout:` outer to `from:` |
| Delayed trigger | `A then delay(30s) then B` | Sequence with `delay:` between from: reads |
| Periodic check | `every 10s: check` | `loop: continuous` + `delay: 10s` |
| Sub-pattern | `(A B)` | `block:` as a group |
| Recursive | `((A B) \| (A C))*` | `loop:` + sequential `from:` + `match:`/`cases:` |

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
    boolean isReleased();
    void registerThread(Thread thread);
}
```

**Implementation (`DefaultConsumerHandle`):**
- `volatile boolean running = true` (starts running)
- `volatile boolean released = false` (scope cleanup flag)
- `volatile Thread consumerThread` (for `LockSupport.unpark()`)
- `pause()` sets `running = false`
- `resume()` sets `running = true`, calls `LockSupport.unpark(consumerThread)`
- `isRunning()` returns `running` (single volatile read)
- `isReleased()` returns `released`
- `registerThread(Thread)` stores the consumer's thread reference
- `releaseForClose()` sets `released = true`, calls `LockSupport.unpark(consumerThread)`

Pause uses `LockSupport.park()` instead of `Thread.sleep()`: zero CPU waste
while paused, instant resume via `unpark()`, and clean termination via
`Thread.interrupt()` (which breaks `park()`). The consumer thread registers
itself via `handle.registerThread(Thread.currentThread())` on first loop entry.

**Registration in ExecutionScope:**
- Add `ConsumerHandle consumerHandle(String name)` to `ExecutionScope`
- `DefaultExecutionScope` registers via `getOrCreate(name, ConsumerHandle.class, () -> factory.createConsumerHandle(name))`
- Add `ConsumerHandle createConsumerHandle(String name)` to `PrimitiveFactory`
- `DefaultPrimitiveFactory` implements: `return new DefaultConsumerHandle(name)`

**Why not OrcFlag:** User requirement — "I can see more being needed." ConsumerHandle
is architecturally positioned for future lifecycle extensions (begin/end, metrics,
listeners) without modifying from: or ControlStep. The current implementation is
a volatile boolean, but the type boundary enables growth.

### 2. from: Decorator Hardening

Modify `DecoratorChain.wrapFromSingleChannel()` to add three capabilities:

#### 2a. Channel close handling

**New method on `OrcChannel` interface:** `boolean isClosed()` — returns `true` when
the channel has been cleanly closed (via `close()`) or error-closed (via
`close(Throwable)`). `DefaultOrcChannel` exposes the existing `volatile boolean closed`
field through this method. Without `isClosed()`, the from: receive loop cannot
distinguish a timed-receive null (timeout, continue polling) from a clean-close
null (channel done, exit).

After null return from timed `channel.receive(100ms)`:
1. `channel.isErrorClosed()` → `Result.failed("channel closed: " + channel.closeError().getMessage())`
2. `channel.isClosed()` → `Result.of(Map.of("from.stream-ended", true))` (graceful exit)
3. Neither → continue (timed-receive timeout, re-check conditions)

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
    handle.registerThread(Thread.currentThread());
    while (true) {
        if (handle.isReleased()) {
            return Result.of(Map.of("from.stream-ended", true));
        }
        if (!handle.isRunning()) {
            LockSupport.park();
            if (Thread.interrupted()) {
                return Result.of(Map.of("from.stream-ended", true));
            }
            continue;
        }
        // ... receive logic
    }
};
```

The pause loop uses `LockSupport.park()` instead of `Thread.sleep(100)`:
- **Zero CPU while paused** — park suspends without polling
- **Instant resume** — `unpark()` wakes immediately (no 100ms latency)
- **Clean scope shutdown** — `Thread.interrupt()` breaks park, the consumer
  checks the interrupt flag and returns stream-ended. `releaseForClose()` sets
  `released = true` and calls `unpark()`, ensuring the consumer exits even if
  paused. `DefaultExecutionScope.close()` interrupts spawned tasks, which
  reliably breaks both `park()` and `channel.receive()`.

**Receive loop** (unified, when `name:` or `until:` is present):

```
loop:
  1. Check handle.isReleased() → if released, return stream-ended success
  2. Check handle.isRunning() → if paused, LockSupport.park(), check interrupt, continue
  3. Check until condition → if true, return stream-ended success
  4. Timed receive (100ms) from channel
  5. If null → check channel.isClosed()
     5a. If error-closed → return failure
     5b. If closed → return stream-ended success
     5c. Not closed (timeout) → continue (re-check conditions)
  6. Apply filter → if rejected, continue
  7. Inject into scope, execute inner step
```

Plain `from:` (no name, no until) retains the current blocking receive — zero
overhead for the common case.

**Fan-in:** `wrapFromFanIn` receives the same treatment — until:, name:, and
channel close handling apply to the fan-in polling loop. The ConsumerHandle
is shared across all channels in a fan-in group (one handle per consumer,
not per channel).

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
) implements ResolvedStep {
    public ControlStep {
        if (target == null || target.isBlank()) {
            throw new IllegalArgumentException(
                "pause/resume requires a non-blank target consumer name");
        }
        decorators = Map.copyOf(decorators);
    }
}
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

**Design decision:** Issue #602 proposed `stop:`/`start:` as the primary keywords
with `pause:`/`resume:` as an optional alternative. This spec **supersedes**
`stop:`/`start:` with `pause:`/`resume:` exclusively. Rationale: `stop` implies
destruction (handle discarded, re-registration required), while `pause` accurately
describes the suspension semantics. The `stop:`/`start:` keywords are not
implemented. Issue #602's title should be updated to reflect this decision.

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
    var branchFailures = new AtomicReference[branchCount];
    Future<?>[] futures = new Future<?>[branchCount];

    try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
        for (int i = 0; i < branchCount; i++) {
            int idx = i;
            branchFailures[idx] = new AtomicReference<String>();
            ResolvedStep branch = race.branches().get(i);
            futures[i] = executor.submit(() -> {
                Result result = evaluateInternal(branch, ctx, runner);
                if (result.isSuccess() && winnerIndex.compareAndSet(-1, idx)) {
                    winnerResult.set(result);
                    for (int j = 0; j < branchCount; j++) {
                        if (j != idx && futures[j] != null) futures[j].cancel(true);
                    }
                } else if (!result.isSuccess()) {
                    String msg = result instanceof Result.Failure f ? f.message() : "unknown";
                    branchFailures[idx].set("branch " + idx + ": " + msg);
                }
            });
        }
        try {
            for (Future<?> f : futures) {
                try { f.get(); }
                catch (ExecutionException | CancellationException e) { /* expected */ }
            }
        } finally {
            for (Future<?> f : futures) {
                if (f != null) f.cancel(true);
            }
        }
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        return Result.failed("Race interrupted");
    }

    Result result = winnerResult.get();
    if (result != null) return result;

    var failures = new ArrayList<String>();
    for (var ref : branchFailures) {
        Object msg = ref.get();
        if (msg != null) failures.add((String) msg);
    }
    return Result.failed("All race branches failed: " + String.join("; ", failures));
}
```

**All-fail diagnostics:** When no branch succeeds, the error message includes
each branch's failure reason. This surfaces filter mismatches, timeouts, and
execution errors that would otherwise be opaque.

**Cancellation:** `future.cancel(true)` interrupts the branch thread. `from:`
decorators already handle `InterruptedException` cleanly (return failure + set
interrupt flag). Nested `channel.receive()`, `signal.await()`, `Thread.sleep()`
all throw `InterruptedException` — the interrupt propagates through the entire
branch stack.

**Executor hang prevention:** The `finally` block inside the try-with-resources
cancels all branch futures before `executor.close()` runs. Without this, an
external interruption (e.g., timeout decorator cancelling the race) would cause
`executor.close()` to hang: `shutdown()` doesn't interrupt running tasks, and
`awaitTermination()` would block indefinitely on branches stuck in
`channel.receive()`. This is the same pattern that exists in `evaluateSelect`
and should be retrofitted there as well.

**Channel semantics in race:** Race branches sharing the same channel have
competing-consumer semantics — each event is delivered to exactly one branch.
`DefaultOrcChannel` uses `LinkedBlockingQueue`; `receive()` calls `queue.poll()`
which removes the item. An event consumed and rejected by one branch's filter
is permanently lost to other branches. For event pattern matching on a shared
stream, use sequential `from:` reads with `match:`/`cases:` (see Recursive
Sub-Pattern below). Race is designed for independent channels/signals where
branches wait on separate data sources.

**Decorator support:** RaceStep has `decorators()` like all ResolvedStep variants.
Wrapping race: with `loop:`, `timeout:`, `background:` etc. composes naturally.
`loop: continuous` + `race:` = `(pattern)*` repetition.

### 5. Walker / StepSchemaComposer Changes

- **Walker `RESERVED_KEYS`:** Add `pause` and `resume`. Without them, the Walker
  falls through to `registry.resolve("pause")`, which fails with "unknown key."
- **Walker `resolveOne()`:** Add `race:` → `RaceStep` parsing alongside
  `block:`/`parallel:` in the structural-keyword branch. Parse `race:` value as
  a list of child steps (same as `parallel:`), validated to have `size() >= 2`.
- **Walker `resolveOne()`:** Add `pause:` and `resume:` to the structural-keyword
  branch. These produce `ControlStep(target, false)` and `ControlStep(target, true)`
  respectively. Value is a string (the target consumer name). They are structural
  keywords (like `block:`, `select:`), NOT decorators — they produce a distinct
  step type, not a wrapper around an inner execution.
- **Walker `resolveOne()` — decorator-only steps:** Before the terminal
  `throw new IllegalArgumentException("no step type identified")`, add a fallback:
  when no structural keyword, action, or invoke is found but decorators are
  non-empty, create a `BlockStep` with an empty step list and the decorators.

  ```java
  // Before the final throw:
  if (!decorators.isEmpty()) {
      return new ResolvedStep.BlockStep(stepName, List.of(), decorators);
  }
  ```

  This desugars decorator-only steps (e.g., `- from: { channel: events }`,
  `- delay: 15s`, `- publish: { channel: out, data: "x" }`) to empty blocks
  wrapped by their decorators. `evaluateBlock` returns `Result.of(Map.of())`
  for an empty block; the decorators execute around it. Without this change,
  every `from:`-only step in the temporal and recursive patterns fails at
  parse time with "no step type identified."

- **`StepSchemaComposer`:** already contains `race` in `DECORATOR_KEYS` for
  schema generation. `pause` and `resume` are **not** added to `DECORATOR_KEYS` —
  they are structural keywords, not decorators. The schema must represent them
  as step-type alternatives in the `oneOf` array (like `block:`, `parallel:`):

  | Keyword | Schema variant |
  |---------|---------------|
  | `race:` | `{ "type": "array", "items": { "$ref": "#/definitions/step" } }` — list of child steps, mirroring `parallel:` |
  | `pause:` | `{ "type": "string" }` — target consumer name |
  | `resume:` | `{ "type": "string" }` — target consumer name |

## Temporal Pattern Composition

These patterns compose from existing decorators — no new code, just documentation
and tests verifying the composition works correctly.

### Timed Absence — "A happened, B didn't follow within N"

```yaml
- block:
    - from: { channel: events, filter: "type == EXPANSION_STARTED" }
    - block:
        - from: { channel: events, filter: "type == ARMY_MOVED_TO_NATURAL" }
      timeout: 30s
      on-error: greedy-build-detected   # timeout = absence = pattern matched
```

**Decorator ordering constraint:** `from:` (4.5) is outer to `timeout:` (5) in
the decorator chain. When both appear on the same step, `from:` blocks for the
event indefinitely — `timeout:` never fires because it's inner and hasn't been
entered. The nested-block approach solves this: `timeout:` and `on-error:` are
decorators on the outer step (the wrapping `block:`), while `from:` is on the
inner step. The timeout decorator runs the block on a virtual thread with
`future.get(30s)`. The inner `from:` blocks for the event. If timeout expires,
`future.cancel(true)` interrupts the `from:` thread. The `from:` returns failure
(interrupted), the timeout returns `Result.failed()`, and `on-error` catches it.

The inner `from:` also sees the deadline via `ctx.deadline().remainingTime()`
(propagated from the outer `timeout:` decorator's `deadlineCtx`), so it uses
timed receive and exits cleanly at deadline expiry.

### Delayed Sequence — "wait N after A before checking for B"

```yaml
- block:
    - from: { channel: events, filter: "type == SCOUT_SPOTTED" }
    - delay: 15s
    - block:
        - from: { channel: events, filter: "type == COUNTER_PREPARED" }
      timeout: 45s
      on-error: unprepared-alert
```

Same nested-block pattern as Timed Absence — `timeout:` and `on-error:` must be
outer to `from:`. `delay:` respects `speedMultiplier` for simulation time
acceleration.

### Periodic Absence (Heartbeat) — "every N, check signal arrived"

```yaml
- step: heartbeat-monitor
  loop: continuous
  background: true
  delay: 10s
  block:
    - block:
        - from: { channel: heartbeats, filter: "source == agent-7" }
      timeout: 10s
      on-error: agent-unresponsive
```

Uses `step:` (not `action:`) to name the step. `action` is not a Walker reserved
key — it would be resolved against the plugin registry, causing either "unknown
key" or a structural-keyword ambiguity with `block:`.

### Recursive Sub-Pattern — `((A then B) or (A then C))*`

**Note on channel semantics in race:** `OrcChannel` uses `LinkedBlockingQueue` —
each event is consumed by exactly one reader. When race branches share a channel,
they compete for events. An event consumed and rejected by one branch's filter is
permanently lost to other branches. This makes race over a shared channel
non-deterministic and potentially deadlock-prone for pattern matching.

The correct approach uses sequential `from:` reads with `match:`/`cases:` for
alternation on a single event stream:

```yaml
- loop: continuous
  background: true
  block:
    - from: { channel: events, filter: "type == A" }
    - match: from.type
      from: { channel: events, filter: "type == B or type == C" }
      cases:
        - pattern: B
          publish: { channel: matched, data: "AB" }
        - pattern: C
          publish: { channel: matched, data: "AC" }
```

**Step 1** (`from:` only): A decorator-only step — desugars to an empty block
with the `from:` decorator. Reads and consumes event A from the channel (the
event data is discarded — we only need to advance past A).

**Step 2** (`match:` + `from:` on the same step): The `from:` decorator reads
the next B or C event and injects it into the scoped resolver as `from` (the
default alias). The `match:` structural keyword then evaluates `from.type`
against the scoped resolver. Because `from:` is a decorator wrapping the match
dispatch, the variable is visible to match's scrutinee evaluation.

**Variable scoping constraint:** The `from:` decorator injects variables into a
scoped `VariableResolver` that is local to its inner execution — not to sibling
steps in a block. `evaluateBlock` passes the same unmodified `ctx` to every step.
Therefore `from:` and `match:` must be on the **same** step for the injected
variable to be visible to match. Placing them on separate sequential steps would
cause `match: followup.type` to resolve against the outer (unscoped) resolver and
fail.

Each `cases:` entry (`publish: { channel: matched, data: "AB" }`) is also a
decorator-only step — the `publish:` decorator wraps an empty block.

Inject event sequence [A, B, A, C, A, B] → matched channel receives [AB, AC, AB].

**When race IS appropriate:** race branches waiting on **independent** channels or
signals (like `select:`). Each branch has its own data source — no competing
consumption:

```yaml
- race:
    - block:
        - from: { channel: login-events }
        - from: { channel: mfa-events }
    - block:
        - from: { channel: login-events }
        - from: { channel: sso-events }
```

Even here, the `login-events` channel is shared — consider whether the competing-
consumer semantics are acceptable for the use case.

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

## Complete API Surface

All interface and class changes required by this spec:

| File | Change |
|------|--------|
| `OrcChannel` (interface) | Add `boolean isClosed()` |
| `DefaultOrcChannel` | Implement `isClosed()` — expose existing `volatile boolean closed` |
| `ConsumerHandle` (new interface) | `pause()`, `resume()`, `isRunning()`, `isReleased()`, `registerThread(Thread)` |
| `DefaultConsumerHandle` (new class) | Implementation with `LockSupport.park()`/`unpark()` |
| `PrimitiveFactory` (interface) | Add `ConsumerHandle createConsumerHandle(String name)` |
| `DefaultPrimitiveFactory` | Implement `createConsumerHandle()` |
| `ExecutionScope` (interface) | Add `ConsumerHandle consumerHandle(String name)` |
| `DefaultExecutionScope` | Implement via `getOrCreate(name, ConsumerHandle.class, () -> factory.createConsumerHandle(name))` |
| `ResolvedStep` (sealed interface) | Add `ControlStep` and `RaceStep` to `permits` clause |
| `ResolvedStep.ControlStep` (new record) | With compact constructor validating non-blank `target` |
| `ResolvedStep.RaceStep` (new record) | With compact constructor validating `branches.size() >= 2` |
| `Walker.RESERVED_KEYS` | Add `"pause"`, `"resume"` |
| `Walker.resolveOne()` | Add structural keyword handling for `race:`, `pause:`, `resume:`; add decorator-only step fallback (empty `BlockStep`) |
| `StructuralStepEvaluator.dispatchStep()` | Add `case ControlStep` and `case RaceStep` |
| `DecoratorChain.wrapFrom()` | Add `until:`, `name:`, channel-close handling to receive loop |
| `StepSchemaComposer.compose()` | Add `oneOf` schema variants for `race:`, `pause:`, `resume:` |

The `permits` clause change on `ResolvedStep` is a sealed-interface modification
that requires recompilation of all `switch` expressions over `ResolvedStep`
(Walker, StructuralStepEvaluator, and any test pattern matches).

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
