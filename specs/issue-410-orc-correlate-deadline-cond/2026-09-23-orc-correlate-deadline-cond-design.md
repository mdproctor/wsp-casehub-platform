# Orchestration Primitives: Correlate, Deadline, Condition Combinators + Driver Migration

**Issues:** #410 (correlate, deadline propagation, condition combinators), #420 Phase 1 (TemporalSimulationDriver lifecycle migration)
**Branch:** issue-410-orc-correlate-deadline-cond
**Date:** 2026-09-23
**Depends on:** #386 (runtime orchestration primitives — landed), #391 (DX refinements + simulation integration — landed)
**Feeds:** #420 Phases 2-4 (scenario runner, MCP migration, documentation)

## Context

Platform #386 and #391 established the orchestration primitive set: ScenarioScope with 12 factory methods, PrimitiveFactory, BlockingOrcStateMachine, SpeedMultiplier, spawn/childScope, shared-state primitives (Counter, Gauge, Flag, Accumulator, Map). This branch adds three capabilities from #410 and migrates the TemporalSimulationDriver to use BlockingOrcStateMachine (#420 Phase 1).

**Scope:**
- Condition combinators (D4)
- Deadline propagation on ScenarioScope (D2)
- Correlation remains composition over trigger+filter — no new primitive (D1)
- OrcPrimitive lifecycle interface — prerequisite for deadline (D3)
- BlockingOrcStateMachine.awaitAnyState() — prerequisite for driver migration (D5)
- ScenarioScope.stateMachine() return type alignment (D6)
- TemporalSimulationDriver migration to BlockingOrcStateMachine (D7)
- EventRouter + Builder .on() — three-layer state machine architecture (D8)

**Not in scope:**
- `correlate:` YAML shorthand — parse-time concern for scenario format spec (#409)
- #420 Phases 2-4 — scenario runner, MCP migration, documentation
- Extracting orchestration-core module — future module-boundary cleanup

---

## Part 1: OrcPrimitive Lifecycle Interface (D3)

### Interface

```java
package io.casehub.yaml.core.orchestration;

public interface OrcPrimitive {
    default void releaseForClose() {}
}
```

### Primitive Type Changes

All 10 primitive interfaces extend OrcPrimitive:

| Interface | extends OrcPrimitive | releaseForClose() behavior |
|-----------|---------------------|---------------------------|
| OrcChannel\<T\> | yes | close() — releases blocked receivers |
| OrcLatch | yes | count down to zero — releases blocked waiters |
| OrcSignal | yes | signal if unsignalled — releases blocked waiters |
| OrcSemaphore | yes | shutdown() — releases blocked acquirers |
| OrcStateMachine\<S\> | yes | no-op (non-blocking CAS) |
| OrcCounter | yes | no-op (lock-free LongAdder) |
| OrcGauge\<T\> | yes | no-op (AtomicReference) |
| OrcFlag | yes | no-op (AtomicBoolean) |
| OrcAccumulator | yes | no-op (DoubleAccumulator) |
| OrcMap\<K,V\> | yes | no-op (ConcurrentHashMap) |

### DefaultScenarioScope.close() Change

Replace the current instanceof chain (lines 148-163):

```java
// Before: instanceof chain against concrete Default* classes
if (p instanceof DefaultOrcChannel<?> ch) { ch.close(); }
else if (p instanceof DefaultOrcLatch latch) { while (latch.getCount() > 0) latch.countDown(); }
else if (p instanceof DefaultOrcSignal signal) { if (!signal.isSignalled()) signal.signal(); }
else if (p instanceof DefaultOrcSemaphore sem) { sem.shutdown(); }

// After: single polymorphic dispatch
if (p instanceof OrcPrimitive orc) { orc.releaseForClose(); }
```

### Test Cases

```
orcPrimitive_channelReleaseForClose_closesChannel
orcPrimitive_latchReleaseForClose_countsDownToZero
orcPrimitive_signalReleaseForClose_signalsIfUnsignalled
orcPrimitive_semaphoreReleaseForClose_shutsDown
orcPrimitive_counterReleaseForClose_noOp
orcPrimitive_gaugeReleaseForClose_noOp
orcPrimitive_flagReleaseForClose_noOp
orcPrimitive_accumulatorReleaseForClose_noOp
orcPrimitive_mapReleaseForClose_noOp
orcPrimitive_stateMachineReleaseForClose_noOp
scopeClose_usesPolymorphicDispatch_noInstanceofChain
scopeClose_customPrimitiveFactory_getsCleanup
```

---

## Part 2: Condition Combinators (D4)

### Interface Changes

```java
package io.casehub.yaml.core.runtime;

@FunctionalInterface
public interface Condition {
    boolean evaluate();

    default Condition and(Condition other) {
        return () -> this.evaluate() && other.evaluate();
    }

    default Condition or(Condition other) {
        return () -> this.evaluate() || other.evaluate();
    }

    default Condition not() {
        return () -> !this.evaluate();
    }

    default Condition xor(Condition other) {
        return () -> this.evaluate() ^ other.evaluate();
    }

    static Condition always() { return () -> true; }
    static Condition never() { return () -> false; }
}
```

**Semantics:**
- `and()` and `or()` short-circuit (Java `&&`/`||`)
- `xor()` evaluates both operands (no short-circuit — both sides needed for XOR)
- `not()` inverts
- `always()` and `never()` are identity elements for `and`/`or`
- `@FunctionalInterface` preserved — default methods don't break it
- Composition is lazy — no evaluation until `evaluate()` is called

**YAML mapping (future — consuming layer):**
```yaml
when:
  all:                              # Condition.and()
    - ${regime} == 'MEAN_REVERTING'
    - ${volatility} > 0.05
  any:                              # Condition.or()
    - ${risk-level} == 'HIGH'
    - ${drawdown} > 0.03
```

### Test Cases

```
condition_and_bothTrue_true
condition_and_firstFalse_shortCircuits
condition_and_secondFalse_false
condition_or_firstTrue_shortCircuits
condition_or_bothFalse_false
condition_not_invertsTrueToFalse
condition_not_invertsFalseToTrue
condition_xor_sameBothTrue_false
condition_xor_sameBothFalse_false
condition_xor_different_true
condition_always_returnsTrue
condition_never_returnsFalse
condition_compositeChain_andOrNot
condition_always_and_x_isX
condition_never_or_x_isX
```

---

## Part 3: BlockingOrcStateMachine Extensions (D5, D6)

### awaitAnyState (D5)

Add to `BlockingOrcStateMachine`:

```java
S awaitAnyState(Set<S> targets) throws InterruptedException;
S awaitAnyState(Set<S> targets, Duration timeout) throws InterruptedException;
```

Implementation in `DefaultBlockingOrcStateMachine`:

```java
@Override
public S awaitAnyState(Set<S> targets) throws InterruptedException {
    lock.lock();
    try {
        while (!targets.contains(currentState())) {
            stateChanged.await();
        }
        return currentState();
    } finally {
        lock.unlock();
    }
}

@Override
public S awaitAnyState(Set<S> targets, Duration timeout) throws InterruptedException {
    long adjustedNanos = adjustForSpeed(timeout);
    long deadline = System.nanoTime() + adjustedNanos;
    lock.lock();
    try {
        while (!targets.contains(currentState())) {
            long remaining = deadline - System.nanoTime();
            if (remaining <= 0) return currentState();
            stateChanged.await(remaining, TimeUnit.NANOSECONDS);
        }
        return currentState();
    } finally {
        lock.unlock();
    }
}
```

**Why Set\<S\> over Predicate\<S\>:** `Set<S>` is more constrained (no arbitrary predicates) and `EnumSet` provides O(1) contains. The caller enumerates valid exit states, making intent explicit.

### ScenarioScope Return Type (D6)

Change `ScenarioScope.stateMachine()` return type:

```java
// Before
<S extends Enum<S>> OrcStateMachine<S> stateMachine(String name, Class<S> stateType, S initialState);

// After
<S extends Enum<S>> BlockingOrcStateMachine<S> stateMachine(String name, Class<S> stateType, S initialState);
```

Aligns with `PrimitiveFactory.createStateMachine()` which already returns `BlockingOrcStateMachine<S>`. Source-compatible — callers typed to `OrcStateMachine<S>` still compile (covariant return).

### Test Cases

```
awaitAnyState_currentStateInTargets_returnsImmediately
awaitAnyState_waitsUntilTargetReached
awaitAnyState_multipleTargets_returnsFirstMatch
awaitAnyState_interrupted_throwsInterruptedException
awaitAnyState_timeout_returnsCurrentStateOnExpiry
awaitAnyState_timeout_returnsTargetIfReachedInTime
awaitAnyState_timeout_respectsSpeedMultiplier
awaitAnyState_stateTransitionsToNonTarget_continuesWaiting
scenarioScope_stateMachine_returnsBlockingVariant
```

---

## Part 4: Deadline Propagation (D2)

### ScenarioScope API

Add to `ScenarioScope`:

```java
ScenarioScope withDeadline(Duration deadline);
ScenarioScope withDeadline(Duration deadline, Runnable onDeadline);
boolean isDeadlineExpired();
java.util.Optional<Duration> remainingTime();
```

### Exception

```java
package io.casehub.yaml.core.orchestration;

public class DeadlineExceededException extends RuntimeException {
    private final String scopeName;
    private final Duration deadline;

    public DeadlineExceededException(String scopeName, Duration deadline) {
        super("Deadline exceeded in scope '" + scopeName + "' after " + deadline);
        this.scopeName = scopeName;
        this.deadline = deadline;
    }

    public String scopeName() { return scopeName; }
    public Duration deadline() { return deadline; }
}
```

### Implementation

`DefaultScenarioScope` gains:

```java
private volatile boolean deadlineExpired = false;
private volatile long    deadlineRemainingNanos;
private volatile Thread  deadlineThread;

@Override
public ScenarioScope withDeadline(Duration deadline) {
    return withDeadline(deadline, null);
}

@Override
public ScenarioScope withDeadline(Duration deadline, Runnable onDeadline) {
    if (closed) throw new IllegalStateException("Cannot set deadline on closed scope");
    DefaultScenarioScope child = (DefaultScenarioScope) childScope("deadline");
    child.startDeadlineWatcher(deadline, onDeadline);
    return child;
}

@Override
public boolean isDeadlineExpired() { return deadlineExpired; }

@Override
public Optional<Duration> remainingTime() {
    if (deadlineExpired) return Optional.of(Duration.ZERO);
    long remaining = deadlineRemainingNanos;
    if (remaining <= 0) return Optional.empty();
    return Optional.of(Duration.ofNanos(remaining));
}
```

### Deadline Watcher (virtual thread, adaptive sleep)

```java
private void startDeadlineWatcher(Duration scenarioDeadline, Runnable onDeadline) {
    // speedMultiplier is a field on DefaultScenarioScope, passed via constructor
    SpeedMultiplier speed = this.speedMultiplier;

    deadlineRemainingNanos = scenarioDeadline.toNanos();
    deadlineThread = Thread.ofVirtual().name("deadline-watcher").start(() -> {
        double remainingScenario = scenarioDeadline.toNanos();

        while (remainingScenario > 0 && !closed) {
            double currentSpeed = Math.max(speed.currentSpeed(), 0.001);
            long realSleepNanos = (long)(remainingScenario / currentSpeed);
            long maxSleep = 1_000_000_000L; // 1s max — re-check speed
            long actualSleep = Math.min(realSleepNanos, maxSleep);

            if (actualSleep <= 0) break;

            long beforeNanos = System.nanoTime();
            try {
                Thread.sleep(Duration.ofNanos(actualSleep));
            } catch (InterruptedException e) {
                return; // scope closed externally
            }
            long elapsedReal = System.nanoTime() - beforeNanos;
            remainingScenario -= elapsedReal * currentSpeed;
            deadlineRemainingNanos = (long) remainingScenario;
        }

        if (!closed) {
            deadlineExpired = true;
            if (onDeadline != null) onDeadline.run();
            close();
        }
    });
}
```

### Cascading Behavior

Parent-child deadline cascading requires **no explicit propagation code**:

1. `withDeadline(Duration)` creates a child scope
2. Parent's `close()` already cascades to children (depth-first)
3. Parent deadline fires → parent closes → children close. Correct.
4. Child's shorter deadline fires → child closes, parent continues. Correct.
5. `min(parent remaining, child deadline)` is enforced by construction — the parent's watcher fires independently

### Interaction with Step-Level Timeout

| Mechanism | Scope | Exception | Caught by on-error? |
|-----------|-------|-----------|-------------------|
| Step `timeout:` | Single step | StepTimeoutException (future, consuming layer) | Yes |
| Scope `withDeadline()` | Entire scope + descendants | DeadlineExceededException | Yes |
| Race cancellation | External termination | StepCancelledException (future, consuming layer) | No (bypasses on-error) |

Whichever fires first wins. The step executor (consuming layer) checks `scope.isDeadlineExpired()` after catching `InterruptedException` to determine whether to wrap it as `DeadlineExceededException`.

### Test Cases

```
deadline_expiresAfterDuration_closesScope
deadline_respectsSpeedMultiplier
deadline_speedChange_midDeadline_adjusts
deadline_withHandler_handlerFiresBeforeClose
deadline_withHandler_handlerFiresBeforeReleaseForClose
deadline_childScopeInheritsParentDeadline
deadline_childShorterDeadline_childClosesFirst
deadline_parentDeadline_childClosesWithParent
deadline_isDeadlineExpired_trueAfterExpiry
deadline_isDeadlineExpired_falseBeforeExpiry
deadline_remainingTime_decreases
deadline_remainingTime_emptyWhenNoDeadline
deadline_scopeClosedExternally_watcherExits
deadline_primitivesCleaned_viaOrcPrimitive
deadline_blockedAwait_interruptedOnExpiry
deadline_spawnedThreads_interruptedOnExpiry
```

---

## Part 5: EventRouter + Builder Extension (D8)

### Three-Layer State Machine Architecture

```
Layer 3 (future): Generated typed dispatch — fire(E event) with Java pattern matching
Layer 2 (this branch): EventRouter<S> — fire(String, Object) string-based event dispatch
Layer 1 (existing): OrcStateMachine<S> — transition(S, S, Object) state-pair dispatch
```

All layers call `transition()` on the same state machine instance. Blocking semantics (awaitState, signalAll), handlers, and CAS atomicity work uniformly.

### EventRouter

```java
package io.casehub.yaml.core.orchestration;

public class EventRouter<S extends Enum<S>> {
    private final OrcStateMachine<S> target;
    private final Map<String, List<EventMapping<S>>> mappings;

    EventRouter(OrcStateMachine<S> target, Map<String, List<EventMapping<S>>> mappings) {
        this.target = target;
        this.mappings = Map.copyOf(mappings);
    }

    public boolean fire(String event) { return fire(event, null); }

    public boolean fire(String event, Object context) {
        var candidates = mappings.get(event);
        if (candidates == null) return false;
        S current = target.currentState();
        for (var m : candidates) {
            if (m.from() == current) {
                if (m.guard() == null || m.guard().test(context)) {
                    return target.transition(m.from(), m.to(), context);
                }
            }
        }
        return false;
    }

    public EventRouter<S> targeting(OrcStateMachine<S> newTarget) {
        return new EventRouter<>(newTarget, this.mappings);
    }

    public record EventMapping<S>(S from, S to, Predicate<Object> guard) {}
}
```

**fire() semantics:** resolves event name → candidate transitions for current state → first matching guard wins → delegates to `target.transition()`. Returns false if no candidate matches (stale event / wrong state — passive, caller decides).

### Builder Extension

Add `.on()` to `DefaultOrcStateMachine.Builder`:

```java
public Builder<S> on(String event, S from, S to) {
    transition(from, to); // register in transition table
    eventMappings.computeIfAbsent(event, k -> new ArrayList<>())
        .add(new EventRouter.EventMapping<>(from, to, null));
    return this;
}

public Builder<S> on(String event, S from, S to, Predicate<Object> guard) {
    transition(from, to, guard);
    eventMappings.computeIfAbsent(event, k -> new ArrayList<>())
        .add(new EventRouter.EventMapping<>(from, to, guard));
    return this;
}

public EventRouter<S> buildRouter(OrcStateMachine<S> target) {
    return new EventRouter<>(target, Map.copyOf(eventMappings));
}
```

### Composition with BlockingOrcStateMachine

```java
var sm = builder.build();
var blocking = new DefaultBlockingOrcStateMachine<>(sm, speed);
var router = builder.buildRouter(blocking); // targeting blocking wrapper

router.fire("approve", context);
// → blocking.transition(PENDING, APPROVED, context)
//   → delegate.transition() + stateChanged.signalAll()
// awaitState/awaitAnyState unblocked ✓
```

### Future: Generated Typed Dispatch (Layer 3)

Not built on this branch. When the code generator emits typed event dispatch:

```java
// Generated from YAML state machine definition
public class OrderEvents {
    private final OrcStateMachine<OrderState> sm;

    public boolean fire(OrderEvent event) {
        return switch (event) {
            case Submit s  when sm.currentState() == IDLE    && s.amount() > 0
                -> sm.transition(IDLE, PENDING, s);
            case Approve a when sm.currentState() == PENDING && a.count() >= 2
                -> sm.transition(PENDING, APPROVED, a);
            case Cancel c  when sm.currentState() == PENDING
                -> sm.transition(PENDING, CANCELLED, c);
            default -> false;
        };
    }
}
```

Same composition — wraps any `OrcStateMachine<S>` (including blocking), calls `transition()`, all semantics preserved.

### Test Cases

```
eventRouter_fire_matchesEventAndState
eventRouter_fire_wrongState_returnsFalse
eventRouter_fire_unknownEvent_returnsFalse
eventRouter_fire_guardTrue_transitions
eventRouter_fire_guardFalse_returnsFalse
eventRouter_fire_multipleFromStates_matchesCurrent
eventRouter_targeting_retargetsToBlockingWrapper
eventRouter_withBlocking_awaitStateUnblocked
builder_on_registersEventMapping
builder_on_withGuard_registersGuardedMapping
builder_buildRouter_producesRouter
```

---

## Part 6: TemporalSimulationDriver Migration (D7)

### Before / After

**Before (hand-rolled concurrency — 35 lines of lock+condition+volatile):**
```java
private final ReentrantLock lock = new ReentrantLock();
private final Condition pauseCondition = lock.newCondition();
private volatile State state = State.IDLE;

// pause: 8 lines (lock, check, set, unlock)
// resume: 8 lines (lock, check, set, signalAll, unlock)
// stop: 13 lines (lock, check, set, signalAll, interrupt, unlock)
// checkPauseOrStop: 10 lines (lock, while loop, await, unlock)
```

**After (BlockingOrcStateMachine — 0 lines of lock+condition):**
```java
private final BlockingOrcStateMachine<State> lifecycle;

// pause: 1 line — lifecycle.transition(RUNNING, PAUSED)
// resume: 1 line — lifecycle.transition(PAUSED, RUNNING)
// stop: 2 lines — transition + interrupt
// checkPauseOrStop: 1 line — lifecycle.awaitAnyState(NON_PAUSED)
```

### Transition Table

```java
private static BlockingOrcStateMachine<State> createLifecycle(SpeedMultiplier speed) {
    var sm = DefaultOrcStateMachine.<State>builder("temporal-driver", State.class, State.IDLE)
        .transition(IDLE, RUNNING)
        .transition(RUNNING, PAUSED)
        .transition(PAUSED, RUNNING)
        .transition(RUNNING, STOPPED)
        .transition(PAUSED, STOPPED)
        .transition(RUNNING, COMPLETED)
        .terminal(STOPPED, COMPLETED)
        .build();
    return new DefaultBlockingOrcStateMachine<>(sm, speed);
}
```

**COMPLETED is terminal.** The current driver allows `stop()` from COMPLETED (line 78) — this is removed. A completed driver has finished its work; re-stopping it is meaningless. Callers must check state before calling stop().

### Thread Management via onTransition

```java
lifecycle.onTransition(IDLE, RUNNING, payload -> {
    TemporalProfile<E> profile = (TemporalProfile<E>) payload;
    driverThread = Thread.ofVirtual()
        .name("temporal-driver-" + profile.name())
        .start(() -> runLoop(profile));
});
```

- IDLE→RUNNING: spawns virtual thread (profile passed as payload)
- PAUSED→RUNNING: awaitAnyState unblocks in runLoop — no thread spawn
- *→STOPPED: `stop()` calls `driverThread.interrupt()` to break Thread.sleep

### Migrated Methods

```java
public void start(TemporalProfile<E> profile) {
    localSpeedOverride = null;
    if (!lifecycle.transition(IDLE, RUNNING, profile)) {
        throw new IllegalStateException("Driver is " + lifecycle.currentState() + ", expected IDLE");
    }
}

public void pause() {
    lifecycle.transition(RUNNING, PAUSED);
}

public void resume() {
    lifecycle.transition(PAUSED, RUNNING);
}

public void stop() {
    State current = lifecycle.currentState();
    if (current == RUNNING || current == PAUSED) {
        lifecycle.transition(current, STOPPED);
        if (driverThread != null) driverThread.interrupt();
    }
}
```

### Migrated runLoop checkPauseOrStop

```java
private static final Set<State> NON_PAUSED = EnumSet.of(RUNNING, STOPPED, COMPLETED);

private State checkPauseOrStop() throws InterruptedException {
    return lifecycle.awaitAnyState(NON_PAUSED);
}
```

In the run loop:
```java
State s = checkPauseOrStop();
if (s != State.RUNNING) break;
```

### Exposed Lifecycle

```java
public BlockingOrcStateMachine<State> lifecycle() { return lifecycle; }
```

Removed: `state()`, `isRunning()` — use `lifecycle().currentState()` instead.

### Module Dependency

simulation-core gains a compile dependency on yaml-core (for BlockingOrcStateMachine). This is conceptually clean — simulation consumes orchestration primitives — and aligns with the existing SpeedMultiplier dependency (yaml-core runtime SPI).

### Test Cases

```
driver_start_transitionsIdleToRunning
driver_start_notIdle_throws
driver_pause_transitionsRunningToPaused
driver_resume_transitionsPausedToRunning
driver_stop_transitionsRunningToStopped
driver_stop_transitionsPausedToStopped
driver_stop_completedDriver_noOp (terminal — no transition)
driver_lifecycle_exposedForObservation
driver_lifecycle_currentState_replacesStateMethod
driver_runLoop_pauseResume_viaAwaitAnyState
driver_runLoop_stop_interruptsThread
driver_runLoop_completion_transitionsToCompleted
driver_start_passesProfileAsPayload
driver_speed_unchanged (local override + global + profile)
```

---

## Module Impact

| Module | Changes |
|--------|---------|
| yaml-core | OrcPrimitive interface, Condition combinators, awaitAnyState on BlockingOrcStateMachine, ScenarioScope return type + withDeadline API, DeadlineExceededException, DefaultScenarioScope deadline watcher + close refactor, EventRouter + EventMapping, Builder .on() extension |
| simulation-core | TemporalSimulationDriver migration: BlockingOrcStateMachine replaces lock+condition, new yaml-core dependency |

---

## Implementation Order

1. **OrcPrimitive** — all primitives extend it, DefaultScenarioScope.close() refactored (prerequisite for deadline)
2. **Condition combinators** — independent, can be done in parallel with #1
3. **awaitAnyState** — add to BlockingOrcStateMachine (prerequisite for driver migration)
4. **ScenarioScope.stateMachine() return type** — trivial, do with #3
5. **Deadline propagation** — withDeadline on ScenarioScope, DeadlineExceededException, watcher (depends on #1)
6. **EventRouter + Builder .on()** — independent of #5
7. **TemporalSimulationDriver migration** — depends on #3, #4

Parallelism: (1, 2) → (3, 4) → (5, 6) → 7

---

## References

- `yaml-core/src/main/java/io/casehub/yaml/core/runtime/Condition.java` — existing interface
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ScenarioScope.java` — scope interface
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultScenarioScope.java` — scope impl with instanceof chain
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcStateMachine.java` — state machine interface
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcStateMachine.java` — state machine impl with Builder
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/BlockingOrcStateMachine.java` — blocking extension
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultBlockingOrcStateMachine.java` — blocking impl
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/PrimitiveFactory.java` — factory interface (createStateMachine returns BlockingOrcStateMachine)
- `yaml-core/src/main/java/io/casehub/yaml/core/runtime/SpeedMultiplier.java` — speed SPI
- `simulation-core/src/main/java/io/casehub/platform/simulation/TemporalSimulationDriver.java` — driver to migrate
- #386 spec — runtime orchestration primitives design
- #391 spec — DX refinements + simulation integration design
- #386 decisions — D1 (module placement), D3 (composition vs custom keywords)
- D1–D8 in `decisions.md` — design decisions for this spec
