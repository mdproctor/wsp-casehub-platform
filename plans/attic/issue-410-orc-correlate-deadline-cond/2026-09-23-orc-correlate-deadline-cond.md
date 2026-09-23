# Orchestration Primitives: Correlate, Deadline, Condition Combinators + Driver Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #410 — yaml-core: correlate, deadline propagation, condition combinators
**Issue group:** #410, #420 (Phase 1 only)

**Goal:** Add condition combinators, deadline propagation on ScenarioScope, EventRouter, and migrate TemporalSimulationDriver lifecycle to BlockingOrcStateMachine.

**Architecture:** OrcPrimitive lifecycle interface enables polymorphic cleanup for deadline expiry. awaitAnyState() on BlockingOrcStateMachine enables pause/stop coordination. Deadlines are scope-level via virtual-thread watcher with adaptive sleep. EventRouter composes with any OrcStateMachine via transition() delegation. TemporalSimulationDriver replaces hand-rolled concurrency with BlockingOrcStateMachine.

**Tech Stack:** Java 21+, JUnit 5, AssertJ, virtual threads, java.util.concurrent

## Global Constraints

- yaml-core must remain zero-dependency (pure Java + j.u.c only)
- All orchestration primitives MUST use j.u.c locks or lock-free atomics — never `synchronized` (virtual thread pinning)
- simulation-core gains a compile dependency on yaml-core for this branch
- Pre-release — no backward compatibility constraints

---

## Batch 1: Foundation — OrcPrimitive + Condition Combinators

### Task 1: OrcPrimitive Lifecycle Interface

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcPrimitive.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcChannel.java:5`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcLatch.java:5`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcSignal.java:5`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcSemaphore.java:5`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcStateMachine.java:3`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcCounter.java:3`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcGauge.java:3`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcFlag.java:3`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcAccumulator.java:3`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcMap.java:6`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcChannel.java` — override releaseForClose()
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcLatch.java` — override releaseForClose()
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcSignal.java` — override releaseForClose()
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcSemaphore.java` — override releaseForClose()
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultScenarioScope.java:126-164` — refactor close()
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/OrcPrimitiveTest.java`

**Interfaces:**
- Produces: `OrcPrimitive` interface with `default void releaseForClose() {}` — used by all subsequent tasks and DefaultScenarioScope.close()

- [ ] **Step 1: Write failing tests for releaseForClose on each primitive type**

```java
package io.casehub.yaml.core.orchestration;

import org.junit.jupiter.api.Test;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import static org.assertj.core.api.Assertions.assertThat;

class OrcPrimitiveTest {

    @Test
    void channelReleaseForClose_closesChannel() {
        var channel = new DefaultOrcChannel<String>("test");
        channel.send("data");
        channel.releaseForClose();
        assertThat(channel.isEmpty()).isFalse(); // buffered data remains
        // next receive after drain should see closed
    }

    @Test
    void latchReleaseForClose_countsDownToZero() {
        var latch = new DefaultOrcLatch("test", 3);
        latch.releaseForClose();
        assertThat(latch.getCount()).isEqualTo(0);
    }

    @Test
    void signalReleaseForClose_signalsIfUnsignalled() {
        var signal = new DefaultOrcSignal("test");
        assertThat(signal.isSignalled()).isFalse();
        signal.releaseForClose();
        assertThat(signal.isSignalled()).isTrue();
    }

    @Test
    void semaphoreReleaseForClose_shutsDown() {
        var sem = new DefaultOrcSemaphore("test", 1);
        sem.releaseForClose();
        // verify shutdown behavior — tryAcquire should fail or return false
    }

    @Test
    void scopeClose_usesPolymorphicDispatch() throws InterruptedException {
        var scope = new DefaultScenarioScope();
        var latch = scope.latch("test", 5);
        var signal = scope.signal("test-sig");
        scope.close();
        assertThat(latch.getCount()).isEqualTo(0);
        assertThat(signal.isSignalled()).isTrue();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-core test -Dtest=OrcPrimitiveTest -Dsurefire.failIfNoSpecifiedTests=false --batch-mode`
Expected: compilation error — `OrcPrimitive` does not exist, `releaseForClose()` method not found

- [ ] **Step 3: Create OrcPrimitive interface**

Create `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcPrimitive.java`:

```java
package io.casehub.yaml.core.orchestration;

public interface OrcPrimitive {
    default void releaseForClose() {}
}
```

- [ ] **Step 4: Add `extends OrcPrimitive` to all 10 primitive interfaces**

For each interface, change the declaration line. Example for OrcChannel:
```java
// Before
public interface OrcChannel<T> {
// After
public interface OrcChannel<T> extends OrcPrimitive {
```

Apply to: OrcChannel, OrcLatch, OrcSignal, OrcSemaphore, OrcStateMachine, OrcCounter, OrcGauge, OrcFlag, OrcAccumulator, OrcMap.

Use `ide_edit_member` or direct Edit for each interface declaration.

- [ ] **Step 5: Implement releaseForClose() in Default* classes**

In `DefaultOrcChannel` add:
```java
@Override
public void releaseForClose() {
    close();
}
```

In `DefaultOrcLatch` add:
```java
@Override
public void releaseForClose() {
    while (getCount() > 0) {
        countDown();
    }
}
```

In `DefaultOrcSignal` add:
```java
@Override
public void releaseForClose() {
    if (!isSignalled()) {
        signal();
    }
}
```

In `DefaultOrcSemaphore` add:
```java
@Override
public void releaseForClose() {
    shutdown();
}
```

OrcStateMachine, OrcCounter, OrcGauge, OrcFlag, OrcAccumulator, OrcMap — default no-op inherited from OrcPrimitive. No override needed.

- [ ] **Step 6: Refactor DefaultScenarioScope.close() to use polymorphic dispatch**

Replace lines 148-163 in DefaultScenarioScope.close():

```java
// Replace the instanceof chain with:
for (Object p : primitives.values()) {
    if (p instanceof OrcPrimitive orc) {
        orc.releaseForClose();
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn -pl yaml-core test --batch-mode`
Expected: all tests pass including new OrcPrimitiveTest and existing ScenarioScopeTest

- [ ] **Step 8: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcPrimitive.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/Orc*.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/Default*.java
git add yaml-core/src/test/java/io/casehub/yaml/core/orchestration/OrcPrimitiveTest.java
git commit -m "feat(#410): add OrcPrimitive lifecycle interface, refactor scope close

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Condition Combinators

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/runtime/Condition.java`
- Create: `yaml-core/src/test/java/io/casehub/yaml/core/runtime/ConditionCombinatorTest.java`

**Interfaces:**
- Consumes: existing `Condition` interface (single `evaluate()` method)
- Produces: `and(Condition)`, `or(Condition)`, `not()`, `xor(Condition)`, `always()`, `never()` — default and static methods on `Condition`

- [ ] **Step 1: Write failing tests for condition combinators**

```java
package io.casehub.yaml.core.runtime;

import org.junit.jupiter.api.Test;
import java.util.concurrent.atomic.AtomicInteger;
import static org.assertj.core.api.Assertions.assertThat;

class ConditionCombinatorTest {

    @Test
    void and_bothTrue_true() {
        Condition a = () -> true;
        Condition b = () -> true;
        assertThat(a.and(b).evaluate()).isTrue();
    }

    @Test
    void and_firstFalse_shortCircuits() {
        var count = new AtomicInteger(0);
        Condition a = () -> false;
        Condition b = () -> { count.incrementAndGet(); return true; };
        assertThat(a.and(b).evaluate()).isFalse();
        assertThat(count.get()).isZero(); // b never called
    }

    @Test
    void or_firstTrue_shortCircuits() {
        var count = new AtomicInteger(0);
        Condition a = () -> true;
        Condition b = () -> { count.incrementAndGet(); return false; };
        assertThat(a.or(b).evaluate()).isTrue();
        assertThat(count.get()).isZero();
    }

    @Test
    void or_bothFalse_false() {
        Condition a = () -> false;
        Condition b = () -> false;
        assertThat(a.or(b).evaluate()).isFalse();
    }

    @Test
    void not_invertsTrueToFalse() {
        Condition a = () -> true;
        assertThat(a.not().evaluate()).isFalse();
    }

    @Test
    void not_invertsFalseToTrue() {
        Condition a = () -> false;
        assertThat(a.not().evaluate()).isTrue();
    }

    @Test
    void xor_sameBothTrue_false() {
        Condition a = () -> true;
        Condition b = () -> true;
        assertThat(a.xor(b).evaluate()).isFalse();
    }

    @Test
    void xor_different_true() {
        Condition a = () -> true;
        Condition b = () -> false;
        assertThat(a.xor(b).evaluate()).isTrue();
    }

    @Test
    void always_returnsTrue() {
        assertThat(Condition.always().evaluate()).isTrue();
    }

    @Test
    void never_returnsFalse() {
        assertThat(Condition.never().evaluate()).isFalse();
    }

    @Test
    void compositeChain_andOrNot() {
        Condition high = () -> true;
        Condition low = () -> false;
        // (true AND !false) OR false → true
        assertThat(high.and(low.not()).or(low).evaluate()).isTrue();
    }

    @Test
    void always_and_x_isX() {
        Condition x = () -> false;
        assertThat(Condition.always().and(x).evaluate()).isFalse();
    }

    @Test
    void never_or_x_isX() {
        Condition x = () -> true;
        assertThat(Condition.never().or(x).evaluate()).isTrue();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-core test -Dtest=ConditionCombinatorTest -Dsurefire.failIfNoSpecifiedTests=false --batch-mode`
Expected: compilation error — `and()`, `or()`, `not()`, `xor()`, `always()`, `never()` not found on Condition

- [ ] **Step 3: Add combinators to Condition interface**

Replace the entire Condition.java content:

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

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn -pl yaml-core test -Dtest=ConditionCombinatorTest --batch-mode`
Expected: all 13 tests pass

- [ ] **Step 5: Run full yaml-core tests for regression**

Run: `mvn -pl yaml-core test --batch-mode`
Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/runtime/Condition.java
git add yaml-core/src/test/java/io/casehub/yaml/core/runtime/ConditionCombinatorTest.java
git commit -m "feat(#410): add condition combinators — and, or, not, xor, always, never

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 2: BlockingOrcStateMachine Extensions

### Task 3: releaseForClose + awaitAnyState + Return Type Alignment

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/BlockingOrcStateMachine.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultBlockingOrcStateMachine.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ScenarioScope.java:16`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultScenarioScope.java:60-62`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/BlockingOrcStateMachineTest.java` (extend)

**Interfaces:**
- Consumes: `OrcPrimitive.releaseForClose()` from Task 1
- Produces: `awaitAnyState(Set<S>)`, `awaitAnyState(Set<S>, Duration)` on `BlockingOrcStateMachine`; `released` flag + `releaseForClose()` on `DefaultBlockingOrcStateMachine`; covariant `stateMachine()` return type on `ScenarioScope`

- [ ] **Step 1: Write failing tests for awaitAnyState and releaseForClose**

Add to `BlockingOrcStateMachineTest.java`:

```java
@Test
void awaitAnyState_currentStateInTargets_returnsImmediately() throws InterruptedException {
    machine.transition(State.IDLE, State.RUNNING);
    State result = machine.awaitAnyState(EnumSet.of(State.RUNNING, State.STOPPED));
    assertThat(result).isEqualTo(State.RUNNING);
}

@Test
void awaitAnyState_waitsUntilTargetReached() throws InterruptedException {
    machine.transition(State.IDLE, State.RUNNING);
    machine.transition(State.RUNNING, State.PAUSED);

    var reached = new AtomicReference<State>();
    var started = new CountDownLatch(1);
    Thread.ofVirtual().start(() -> {
        try {
            started.countDown();
            reached.set(machine.awaitAnyState(EnumSet.of(State.RUNNING, State.STOPPED)));
        } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    });
    started.await(1, TimeUnit.SECONDS);
    Thread.sleep(50);
    assertThat(reached.get()).isNull(); // still waiting

    machine.transition(State.PAUSED, State.RUNNING);
    Thread.sleep(50);
    assertThat(reached.get()).isEqualTo(State.RUNNING);
}

@Test
void awaitAnyState_timeout_returnsCurrentState() throws InterruptedException {
    machine.transition(State.IDLE, State.RUNNING);
    machine.transition(State.RUNNING, State.PAUSED);
    State result = machine.awaitAnyState(
        EnumSet.of(State.RUNNING, State.STOPPED),
        Duration.ofMillis(50));
    assertThat(result).isEqualTo(State.PAUSED);
}

@Test
void releaseForClose_awaitState_throwsInterruptedException() throws InterruptedException {
    machine.transition(State.IDLE, State.RUNNING);
    machine.transition(State.RUNNING, State.PAUSED);

    var interrupted = new AtomicBoolean(false);
    var started = new CountDownLatch(1);
    Thread.ofVirtual().start(() -> {
        try {
            started.countDown();
            machine.awaitState(State.RUNNING);
        } catch (InterruptedException e) {
            interrupted.set(true);
        }
    });
    started.await(1, TimeUnit.SECONDS);
    Thread.sleep(50);

    machine.releaseForClose();
    Thread.sleep(50);
    assertThat(interrupted.get()).isTrue();
}

@Test
void releaseForClose_awaitAnyState_throwsInterruptedException() throws InterruptedException {
    machine.transition(State.IDLE, State.RUNNING);
    machine.transition(State.RUNNING, State.PAUSED);

    var interrupted = new AtomicBoolean(false);
    var started = new CountDownLatch(1);
    Thread.ofVirtual().start(() -> {
        try {
            started.countDown();
            machine.awaitAnyState(EnumSet.of(State.COMPLETED));
        } catch (InterruptedException e) {
            interrupted.set(true);
        }
    });
    started.await(1, TimeUnit.SECONDS);
    Thread.sleep(50);

    machine.releaseForClose();
    Thread.sleep(50);
    assertThat(interrupted.get()).isTrue();
}
```

Add imports: `java.util.EnumSet`, `java.util.concurrent.atomic.AtomicReference`

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-core test -Dtest=BlockingOrcStateMachineTest --batch-mode`
Expected: compilation error — `awaitAnyState` and `releaseForClose` not found

- [ ] **Step 3: Add awaitAnyState to BlockingOrcStateMachine interface**

```java
package io.casehub.yaml.core.orchestration;

import java.time.Duration;
import java.util.Set;

public interface BlockingOrcStateMachine<S extends Enum<S>> extends OrcStateMachine<S> {
    void awaitState(S target) throws InterruptedException;
    boolean awaitState(S target, Duration timeout) throws InterruptedException;
    void awaitTransition(S from, S to) throws InterruptedException;
    S awaitAnyState(Set<S> targets) throws InterruptedException;
    S awaitAnyState(Set<S> targets, Duration timeout) throws InterruptedException;
}
```

- [ ] **Step 4: Implement awaitAnyState + releaseForClose in DefaultBlockingOrcStateMachine**

Add `released` flag field:
```java
private volatile boolean released = false;
```

Add `releaseForClose()`:
```java
@Override
public void releaseForClose() {
    released = true;
    lock.lock();
    try {
        stateChanged.signalAll();
    } finally {
        lock.unlock();
    }
}
```

Add `released` check to existing `awaitState(S)`, `awaitState(S, Duration)`, `awaitTransition(S, S)` — insert `if (released) throw new InterruptedException("state machine released");` (or `return false`/`return currentState()` for timeout variants) inside each while loop before the `stateChanged.await()` call.

Add `awaitAnyState` implementations per the spec (see Part 3 in spec).

- [ ] **Step 5: Change ScenarioScope.stateMachine() return type**

In `ScenarioScope.java` line 16:
```java
// Before
<S extends Enum<S>> OrcStateMachine<S> stateMachine(String name, Class<S> stateType, S initialState);
// After
<S extends Enum<S>> BlockingOrcStateMachine<S> stateMachine(String name, Class<S> stateType, S initialState);
```

In `DefaultScenarioScope.java` update the method signature and return cast accordingly.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn -pl yaml-core test --batch-mode`
Expected: all tests pass including new awaitAnyState and releaseForClose tests

- [ ] **Step 7: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/BlockingOrcStateMachine.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultBlockingOrcStateMachine.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ScenarioScope.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultScenarioScope.java
git add yaml-core/src/test/java/io/casehub/yaml/core/orchestration/BlockingOrcStateMachineTest.java
git commit -m "feat(#410): add awaitAnyState, releaseForClose, align stateMachine return type

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 3: Deadline Propagation

### Task 4: Scope Chain Refactor + Deadline API

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ScenarioScope.java` — add withDeadline, isDeadlineExpired, remainingTime
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DeadlineExceededException.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultScenarioScope.java` — constructor changes (SpeedMultiplier + parent), scope chain (findPrimitive, childScope refactor), close() deadline thread interrupt, withDeadline + watcher
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/DeadlineTest.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/ChildScopeTest.java` — update for scope chain changes

**Interfaces:**
- Consumes: `OrcPrimitive.releaseForClose()` from Task 1, `BlockingOrcStateMachine.releaseForClose()` from Task 3
- Produces: `ScenarioScope.withDeadline(Duration)`, `withDeadline(Duration, Runnable)`, `isDeadlineExpired()`, `remainingTime()`, `DeadlineExceededException`

- [ ] **Step 1: Write failing tests for scope chain + deadline**

```java
package io.casehub.yaml.core.orchestration;

import io.casehub.yaml.core.runtime.SpeedMultiplier;
import org.junit.jupiter.api.Test;
import java.time.Duration;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import static org.assertj.core.api.Assertions.assertThat;

class DeadlineTest {

    @Test
    void childScope_parentPrimitivesAccessibleViaChain() {
        var parent = new DefaultScenarioScope();
        var channel = parent.channel("shared");
        var child = parent.childScope("child");
        assertThat(child.channel("shared")).isSameAs(channel);
        parent.close();
    }

    @Test
    void childScope_close_doesNotReleaseParentPrimitives() throws InterruptedException {
        var parent = new DefaultScenarioScope();
        var latch = parent.latch("shared", 3);
        var child = parent.childScope("child");
        child.close();
        assertThat(latch.getCount()).isEqualTo(3); // parent latch untouched
        parent.close();
    }

    @Test
    void deadline_expiresAfterDuration_closesScope() throws InterruptedException {
        var scope = new DefaultScenarioScope();
        var expired = new AtomicBoolean(false);
        var deadlined = scope.withDeadline(Duration.ofMillis(100), () -> expired.set(true));
        Thread.sleep(300);
        assertThat(expired.get()).isTrue();
        assertThat(deadlined.isDeadlineExpired()).isTrue();
        scope.close();
    }

    @Test
    void deadline_respectsSpeedMultiplier() throws InterruptedException {
        var scope = new DefaultScenarioScope(new DefaultPrimitiveFactory(), () -> 10.0);
        var expired = new AtomicBoolean(false);
        // 1s deadline at 10x speed → expires in ~100ms real time
        scope.withDeadline(Duration.ofSeconds(1), () -> expired.set(true));
        Thread.sleep(300);
        assertThat(expired.get()).isTrue();
        scope.close();
    }

    @Test
    void deadline_remainingTime_decreases() throws InterruptedException {
        var scope = new DefaultScenarioScope();
        var deadlined = scope.withDeadline(Duration.ofSeconds(5));
        Thread.sleep(100);
        var remaining = deadlined.remainingTime();
        assertThat(remaining).isPresent();
        assertThat(remaining.get().toMillis()).isLessThan(5000);
        scope.close();
    }

    @Test
    void deadline_scopeClosedExternally_watcherExits() throws InterruptedException {
        var scope = new DefaultScenarioScope();
        var expired = new AtomicBoolean(false);
        var deadlined = scope.withDeadline(Duration.ofSeconds(60), () -> expired.set(true));
        deadlined.close(); // external close before deadline
        Thread.sleep(100);
        assertThat(expired.get()).isFalse(); // handler did NOT fire
    }

    @Test
    void deadline_withHandler_handlerThrows_scopeStillCloses() throws InterruptedException {
        var scope = new DefaultScenarioScope();
        var deadlined = scope.withDeadline(Duration.ofMillis(50), () -> {
            throw new RuntimeException("handler failure");
        });
        Thread.sleep(200);
        assertThat(deadlined.isDeadlineExpired()).isTrue();
        scope.close();
    }

    @Test
    void deadline_isDeadlineExpired_childReportsParentDeadline() throws InterruptedException {
        var scope = new DefaultScenarioScope();
        var deadlined = scope.withDeadline(Duration.ofMillis(100));
        var child = deadlined.childScope("nested");
        Thread.sleep(300);
        assertThat(child.isDeadlineExpired()).isTrue();
        scope.close();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-core test -Dtest=DeadlineTest -Dsurefire.failIfNoSpecifiedTests=false --batch-mode`
Expected: compilation errors — withDeadline, isDeadlineExpired, remainingTime not found; constructor changes needed

- [ ] **Step 3: Create DeadlineExceededException**

```java
package io.casehub.yaml.core.orchestration;

import java.time.Duration;

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

- [ ] **Step 4: Add deadline methods to ScenarioScope interface**

```java
ScenarioScope withDeadline(java.time.Duration deadline);
ScenarioScope withDeadline(java.time.Duration deadline, Runnable onDeadline);
boolean isDeadlineExpired();
java.util.Optional<java.time.Duration> remainingTime();
```

- [ ] **Step 5: Refactor DefaultScenarioScope — constructor, scope chain, deadline watcher**

This is the main implementation step. Apply all changes from the spec's Part 4:

1. Add fields: `speedMultiplier`, `parent`, `deadlineExpired`, `deadlineRemainingNanos`, `deadlineThread`
2. Update constructors to accept `SpeedMultiplier` and `parent`
3. Refactor `childScope()` to pass `this` as parent (remove `putAll`)
4. Add `findPrimitive(String name)` — walks parent chain
5. Update `getOrCreate()` and `primitive()` to use `findPrimitive()`
6. Add `withDeadline()` implementations
7. Add `startDeadlineWatcher()` with adaptive sleep
8. Add `isDeadlineExpired()` with parent chain walk
9. Add `remainingTime()` with parent chain walk
10. Update `close()` to interrupt deadline thread first

See spec Part 4 for full implementation code.

- [ ] **Step 6: Update ChildScopeTest for scope chain changes**

The existing `ChildScopeTest` may reference `putAll` behavior. Update tests to verify scope-chain-based primitive access instead of copy-on-create.

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn -pl yaml-core test --batch-mode`
Expected: all tests pass — DeadlineTest, ChildScopeTest (updated), ScenarioScopeTest, all existing tests

- [ ] **Step 8: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DeadlineExceededException.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ScenarioScope.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultScenarioScope.java
git add yaml-core/src/test/java/io/casehub/yaml/core/orchestration/DeadlineTest.java
git add yaml-core/src/test/java/io/casehub/yaml/core/orchestration/ChildScopeTest.java
git commit -m "feat(#410): add deadline propagation on ScenarioScope with scope-chain refactor

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 4: EventRouter + Driver Migration

### Task 5: EventRouter + Builder .on()

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/EventRouter.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcStateMachine.java` — extend Builder with .on() and buildRouter()
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/EventRouterTest.java`

**Interfaces:**
- Consumes: `OrcStateMachine.transition()`, `DefaultOrcStateMachine.Builder`
- Produces: `EventRouter<S>` with `fire(String)`, `fire(String, Object)`, `targeting(OrcStateMachine<S>)`; `Builder.on(String, S, S)`, `Builder.on(String, S, S, Predicate)`, `Builder.buildRouter(OrcStateMachine<S>)`

- [ ] **Step 1: Write failing tests for EventRouter**

```java
package io.casehub.yaml.core.orchestration;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import java.util.EnumSet;
import static org.assertj.core.api.Assertions.assertThat;

class EventRouterTest {

    enum OrderState { IDLE, PENDING, APPROVED, CANCELLED }

    private DefaultOrcStateMachine.Builder<OrderState> builder;

    @BeforeEach
    void setUp() {
        builder = DefaultOrcStateMachine.builder("order", OrderState.class, OrderState.IDLE)
                .transition(OrderState.IDLE, OrderState.PENDING)
                .on("approve", OrderState.PENDING, OrderState.APPROVED)
                .on("cancel", OrderState.PENDING, OrderState.CANCELLED)
                .terminal(OrderState.APPROVED, OrderState.CANCELLED);
    }

    @Test
    void fire_matchesEventAndState() {
        var sm = builder.build();
        var router = builder.buildRouter(sm);
        sm.transition(OrderState.IDLE, OrderState.PENDING);
        assertThat(router.fire("approve")).isTrue();
        assertThat(sm.currentState()).isEqualTo(OrderState.APPROVED);
    }

    @Test
    void fire_wrongState_returnsFalse() {
        var sm = builder.build();
        var router = builder.buildRouter(sm);
        // still IDLE — "approve" needs PENDING
        assertThat(router.fire("approve")).isFalse();
    }

    @Test
    void fire_unknownEvent_returnsFalse() {
        var sm = builder.build();
        var router = builder.buildRouter(sm);
        sm.transition(OrderState.IDLE, OrderState.PENDING);
        assertThat(router.fire("unknown")).isFalse();
    }

    @Test
    void fire_withGuard_guardTrue_transitions() {
        var guardedBuilder = DefaultOrcStateMachine.builder("guarded", OrderState.class, OrderState.IDLE)
                .transition(OrderState.IDLE, OrderState.PENDING)
                .on("approve", OrderState.PENDING, OrderState.APPROVED, ctx -> ctx != null)
                .terminal(OrderState.APPROVED);
        var sm = guardedBuilder.build();
        var router = guardedBuilder.buildRouter(sm);
        sm.transition(OrderState.IDLE, OrderState.PENDING);
        assertThat(router.fire("approve", "context")).isTrue();
    }

    @Test
    void fire_withGuard_guardFalse_returnsFalse() {
        var guardedBuilder = DefaultOrcStateMachine.builder("guarded", OrderState.class, OrderState.IDLE)
                .transition(OrderState.IDLE, OrderState.PENDING)
                .on("approve", OrderState.PENDING, OrderState.APPROVED, ctx -> false)
                .terminal(OrderState.APPROVED);
        var sm = guardedBuilder.build();
        var router = guardedBuilder.buildRouter(sm);
        sm.transition(OrderState.IDLE, OrderState.PENDING);
        assertThat(router.fire("approve", "ctx")).isFalse();
    }

    @Test
    void targeting_retargetsToBlockingWrapper() throws InterruptedException {
        var sm = builder.build();
        var blocking = new DefaultBlockingOrcStateMachine<>(sm);
        var router = builder.buildRouter(blocking);
        blocking.transition(OrderState.IDLE, OrderState.PENDING);
        assertThat(router.fire("approve")).isTrue();
        assertThat(blocking.currentState()).isEqualTo(OrderState.APPROVED);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-core test -Dtest=EventRouterTest -Dsurefire.failIfNoSpecifiedTests=false --batch-mode`
Expected: compilation error — `EventRouter` not found, `.on()` method not found on Builder

- [ ] **Step 3: Create EventRouter class**

```java
package io.casehub.yaml.core.orchestration;

import java.util.List;
import java.util.Map;
import java.util.function.Predicate;

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

- [ ] **Step 4: Extend Builder with .on() and buildRouter()**

In `DefaultOrcStateMachine.Builder`, add:

```java
private final Map<String, List<EventRouter.EventMapping<S>>> eventMappings = new java.util.HashMap<>();

public Builder<S> on(String event, S from, S to) {
    transition(from, to);
    eventMappings.computeIfAbsent(event, k -> new java.util.ArrayList<>())
        .add(new EventRouter.EventMapping<>(from, to, null));
    return this;
}

public Builder<S> on(String event, S from, S to, Predicate<Object> guard) {
    transition(from, to, guard);
    eventMappings.computeIfAbsent(event, k -> new java.util.ArrayList<>())
        .add(new EventRouter.EventMapping<>(from, to, guard));
    return this;
}

public EventRouter<S> buildRouter(OrcStateMachine<S> target) {
    return new EventRouter<>(target, Map.copyOf(eventMappings));
}
```

Add import: `java.util.function.Predicate`

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -pl yaml-core test --batch-mode`
Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/EventRouter.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcStateMachine.java
git add yaml-core/src/test/java/io/casehub/yaml/core/orchestration/EventRouterTest.java
git commit -m "feat(#410): add EventRouter + Builder .on() for three-layer state machine architecture

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: TemporalSimulationDriver Migration

**Files:**
- Modify: `simulation-core/pom.xml` — add yaml-core dependency
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/TemporalSimulationDriver.java` — full migration
- Modify: `simulation-core/src/test/java/io/casehub/platform/simulation/TemporalSimulationDriverTest.java` — update for API changes

**Interfaces:**
- Consumes: `BlockingOrcStateMachine` from yaml-core, `DefaultOrcStateMachine.Builder`, `awaitAnyState(Set<S>)` from Task 3
- Produces: `TemporalSimulationDriver.lifecycle()` accessor — exposes `BlockingOrcStateMachine<State>` for MCP tools and external observation

- [ ] **Step 1: Add yaml-core dependency to simulation-core pom.xml**

Add to `simulation-core/pom.xml` dependencies section:

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-yaml-core</artifactId>
</dependency>
```

- [ ] **Step 2: Update TemporalSimulationDriverTest for new API**

Replace `driver.state()` with `driver.lifecycle().currentState()` and `driver.isRunning()` with `driver.lifecycle().currentState() == State.RUNNING`. Update `stop()` on completed driver test to verify it's a no-op (terminal state).

Key test changes:
```java
// Before
assertThat(driver.state()).isEqualTo(TemporalSimulationDriver.State.COMPLETED);
assertThat(driver.isRunning()).isFalse();

// After
assertThat(driver.lifecycle().currentState()).isEqualTo(TemporalSimulationDriver.State.COMPLETED);
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn -pl simulation-core test --batch-mode`
Expected: compilation errors — `lifecycle()` not found, `state()` and `isRunning()` still exist

- [ ] **Step 4: Migrate TemporalSimulationDriver**

Replace the full class implementation:

1. Remove `ReentrantLock lock`, `Condition pauseCondition`, `volatile State state` fields
2. Add `BlockingOrcStateMachine<State> lifecycle` field
3. Add `createLifecycle(SpeedMultiplier)` static factory with transition table
4. Register `onTransition(IDLE, RUNNING, ...)` handler for thread spawning
5. Replace `start()`, `pause()`, `resume()`, `stop()` method bodies
6. Replace `checkPauseOrStop()` with `lifecycle.awaitAnyState(NON_PAUSED)`
7. Update `runLoop()` completion — use `lifecycle.transition(RUNNING, COMPLETED)` instead of lock-guarded state assignment
8. Add `lifecycle()` accessor
9. Remove `state()`, `isRunning()`
10. Update constructors to create lifecycle with SpeedMultiplier

See spec Part 6 for full migrated method implementations.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -pl simulation-core test --batch-mode`
Expected: all tests pass with new lifecycle API

- [ ] **Step 6: Run full build to verify cross-module compatibility**

Run: `mvn --batch-mode install`
Expected: clean build, all tests pass

- [ ] **Step 7: Commit**

```bash
git add simulation-core/pom.xml
git add simulation-core/src/main/java/io/casehub/platform/simulation/TemporalSimulationDriver.java
git add simulation-core/src/test/java/io/casehub/platform/simulation/TemporalSimulationDriverTest.java
git commit -m "feat(#420): migrate TemporalSimulationDriver lifecycle to BlockingOrcStateMachine

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## References

- [2026-09-23-orc-correlate-deadline-cond-design.md] — design spec this plan implements
- [decisions.md] — D1-D8 design decisions
- [yaml-core/src/main/java/io/casehub/yaml/core/runtime/Condition.java] — existing Condition interface
- [yaml-core/src/main/java/io/casehub/yaml/core/orchestration/] — all orchestration primitives
- [simulation-core/src/main/java/io/casehub/platform/simulation/TemporalSimulationDriver.java] — driver to migrate
- [#386 spec] — runtime orchestration primitives design
- [#391 spec] — DX refinements + simulation integration design
- [GitHub #410] — correlate, deadline, condition combinators
- [GitHub #420] — port simulation to YAML-driven orchestration (Phase 1 only)
