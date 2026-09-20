# Temporal Simulation Driver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #371 — TemporalSimulationDriver — timed event sequence execution for simulation profiles
**Issue group:** #371

**Goal:** Add lifecycle-controlled temporal simulation (start/pause/resume/stop/setSpeed) with YAML profile loading and journal integration, composing with existing TimedEntry/TimedSequence types.

**Architecture:** Move TimedEntry/TimedSequence from event-simulation-core to simulation-core (generic, no CloudEvent dep). Add TemporalProfile wrapper, TemporalSimulationDriver with virtual-thread lifecycle, YAML temporal-profiles parsing in simulation-config-core, CDI wiring in simulation-config and event-simulation.

**Tech Stack:** Java 21 (virtual threads, records), JUnit 5, AssertJ, Jackson YAML, Quarkus CDI

## Global Constraints

- simulation-core has no CDI, no Quarkus — pure Java + simulation-api + simulation-inmem only
- simulation-config-core has no CDI — pure Java + Jackson
- All new records use defensive copies (`List.copyOf`)
- Pre-release maturity — no backward compatibility shims needed
- `ide_move_file` for all source file moves (updates imports across project)
- `ide_refactor_safe_delete` for removing source files
- Short delays (10-50ms) in all timing tests

---

## Batch 1: Foundation — data model + driver in simulation-core

### Task 1: Move TimedEntry + TimedSequence to simulation-core, add label + qualifiedName

**Files:**
- Move: `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/TimedEntry.java` → `simulation-core/src/main/java/io/casehub/platform/simulation/TimedEntry.java` (use `ide_move_file`)
- Move: `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/TimedSequence.java` → `simulation-core/src/main/java/io/casehub/platform/simulation/TimedSequence.java` (use `ide_move_file`)
- Move: `event-simulation-core/src/test/java/io/casehub/platform/simulation/event/TimedSequenceTest.java` → `simulation-core/src/test/java/io/casehub/platform/simulation/TimedSequenceTest.java` (use `ide_move_file`)
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/TimedEntry.java` (add label + qualifiedName)
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/TimedSequence.java` (preserve label + qualifiedName in withMultiplier)
- Modify: `simulation-core/src/test/java/io/casehub/platform/simulation/TimedSequenceTest.java` (add label tests)

**Interfaces:**
- Produces: `TimedEntry<E>(E event, Duration delay, String label, String qualifiedName)` with convenience constructors `TimedEntry(E, Duration)` and `TimedEntry(E, Duration, String label)`
- Produces: `TimedSequence<E>` unchanged API, preserves label/qualifiedName through transforms

- [ ] **Step 1: Move TimedEntry.java via ide_move_file**

Use `ide_move_file` to move from `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/TimedEntry.java` to `simulation-core/src/main/java/io/casehub/platform/simulation/`. IntelliJ updates all imports across the project.

- [ ] **Step 2: Move TimedSequence.java via ide_move_file**

Use `ide_move_file` to move from `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/TimedSequence.java` to `simulation-core/src/main/java/io/casehub/platform/simulation/`.

- [ ] **Step 3: Move TimedSequenceTest.java via ide_move_file**

Use `ide_move_file` to move from `event-simulation-core/src/test/java/io/casehub/platform/simulation/event/TimedSequenceTest.java` to `simulation-core/src/test/java/io/casehub/platform/simulation/`.

- [ ] **Step 4: Verify build compiles after moves**

Run: `mvn --batch-mode -pl simulation-core,event-simulation-core -am compile test-compile`
Expected: BUILD SUCCESS (IntelliJ updated all imports)

- [ ] **Step 5: Write failing test for label field**

Add to `simulation-core/src/test/java/io/casehub/platform/simulation/TimedSequenceTest.java`:

```java
@Test
void timedEntryPreservesLabel() {
    var entry = new TimedEntry<>("event", Duration.ZERO, "my-label");
    assertThat(entry.label()).isEqualTo("my-label");
    assertThat(entry.qualifiedName()).isNull();
}

@Test
void timedEntryLabelDefaultsToNull() {
    var entry = new TimedEntry<>("event", Duration.ZERO);
    assertThat(entry.label()).isNull();
    assertThat(entry.qualifiedName()).isNull();
}

@Test
void timedEntryPreservesQualifiedName() {
    var entry = new TimedEntry<>("event", Duration.ofSeconds(1), "label", "my.method");
    assertThat(entry.qualifiedName()).isEqualTo("my.method");
}

@Test
void withMultiplierPreservesLabels() {
    var seq = new TimedSequence<>(List.of(
            new TimedEntry<>("A", Duration.ofSeconds(10), "step-a", "method.a"),
            new TimedEntry<>("B", Duration.ofSeconds(20), "step-b")));

    var fast = seq.withMultiplier(10.0);

    assertThat(fast.entries().get(0).label()).isEqualTo("step-a");
    assertThat(fast.entries().get(0).qualifiedName()).isEqualTo("method.a");
    assertThat(fast.entries().get(1).label()).isEqualTo("step-b");
    assertThat(fast.entries().get(1).qualifiedName()).isNull();
}
```

Run: `mvn --batch-mode -pl simulation-core test -Dtest=TimedSequenceTest`
Expected: FAIL — TimedEntry has no label/qualifiedName fields yet

- [ ] **Step 6: Add label + qualifiedName to TimedEntry**

Replace the `TimedEntry` record body:

```java
package io.casehub.platform.simulation;

import java.time.Duration;

public record TimedEntry<E>(E event, Duration delay, String label, String qualifiedName) {

    public TimedEntry(E event, Duration delay) {
        this(event, delay, null, null);
    }

    public TimedEntry(E event, Duration delay, String label) {
        this(event, delay, label, null);
    }

    public TimedEntry {
        if (event == null) throw new IllegalArgumentException("event must not be null");
        if (delay == null) throw new IllegalArgumentException("delay must not be null");
        if (delay.isNegative()) throw new IllegalArgumentException("delay must not be negative");
    }
}
```

- [ ] **Step 7: Update TimedSequence.withMultiplier to preserve label + qualifiedName**

In `TimedSequence.java`, update the map in `withMultiplier()`:

```java
.map(e -> new TimedEntry<>(e.event(),
        Duration.ofMillis((long) (e.delay().toMillis() / multiplier)),
        e.label(), e.qualifiedName()))
```

- [ ] **Step 8: Run tests**

Run: `mvn --batch-mode -pl simulation-core test -Dtest=TimedSequenceTest`
Expected: PASS — all existing + new label tests green

- [ ] **Step 9: Verify event-simulation-core still compiles**

Run: `mvn --batch-mode -pl event-simulation-core -am compile test-compile`
Expected: BUILD SUCCESS

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat(#371): move TimedEntry/TimedSequence to simulation-core, add label + qualifiedName

Move generic timed-event types from event-simulation-core to simulation-core
(no CloudEvent dependency). Add optional label (journal verification) and
qualifiedName (per-entry override for concat attribution) to TimedEntry.
withMultiplier preserves both fields.

Refs #371

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Create TemporalProfile, TemporalEventSink, DriverFailure, DriverResult, TemporalDriverFactory

**Files:**
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/TemporalProfile.java`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/TemporalEventSink.java`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/DriverFailure.java`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/DriverResult.java`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/TemporalDriverFactory.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/TemporalProfileTest.java`

**Interfaces:**
- Produces: `TemporalProfile<E>(String name, String qualifiedName, String tenancyId, TimedSequence<E> sequence, boolean loop, double speed)`
- Produces: `TemporalEventSink<E>` — `void deliver(String qualifiedName, String label, E event)`
- Produces: `DriverFailure(int index, String label, Exception cause)`
- Produces: `DriverResult(int emittedCount, int failureCount, int loopIterations, List<DriverFailure> failures)`
- Produces: `TemporalDriverFactory<E>` — `TemporalSimulationDriver<E> create()`

- [ ] **Step 1: Write failing test for TemporalProfile validation**

Create `simulation-core/src/test/java/io/casehub/platform/simulation/TemporalProfileTest.java`:

```java
package io.casehub.platform.simulation;

import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class TemporalProfileTest {

    @Test
    void constructsWithAllFields() {
        var seq = new TimedSequence<>(List.of(
                new TimedEntry<>("A", Duration.ZERO, "step-a")));
        var profile = new TemporalProfile<>("test", "my.method", "tenant-1",
                seq, true, 10.0);

        assertThat(profile.name()).isEqualTo("test");
        assertThat(profile.qualifiedName()).isEqualTo("my.method");
        assertThat(profile.tenancyId()).isEqualTo("tenant-1");
        assertThat(profile.sequence().size()).isEqualTo(1);
        assertThat(profile.loop()).isTrue();
        assertThat(profile.speed()).isEqualTo(10.0);
    }

    @Test
    void rejectsNullName() {
        var seq = new TimedSequence<>(List.of());
        assertThatThrownBy(() -> new TemporalProfile<>(null, "qn", null, seq, false, 1.0))
                .isInstanceOf(NullPointerException.class);
    }

    @Test
    void rejectsNullQualifiedName() {
        var seq = new TimedSequence<>(List.of());
        assertThatThrownBy(() -> new TemporalProfile<>("n", null, null, seq, false, 1.0))
                .isInstanceOf(NullPointerException.class);
    }

    @Test
    void rejectsNullSequence() {
        assertThatThrownBy(() -> new TemporalProfile<>("n", "qn", null, null, false, 1.0))
                .isInstanceOf(NullPointerException.class);
    }

    @Test
    void rejectsZeroSpeed() {
        var seq = new TimedSequence<>(List.of());
        assertThatThrownBy(() -> new TemporalProfile<>("n", "qn", null, seq, false, 0))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void rejectsNegativeSpeed() {
        var seq = new TimedSequence<>(List.of());
        assertThatThrownBy(() -> new TemporalProfile<>("n", "qn", null, seq, false, -1.0))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void allowsNullTenancyId() {
        var seq = new TimedSequence<>(List.of());
        var profile = new TemporalProfile<>("n", "qn", null, seq, false, 1.0);
        assertThat(profile.tenancyId()).isNull();
    }
}
```

Run: `mvn --batch-mode -pl simulation-core test -Dtest=TemporalProfileTest`
Expected: FAIL — TemporalProfile class does not exist

- [ ] **Step 2: Create all new types**

Create `simulation-core/src/main/java/io/casehub/platform/simulation/TemporalEventSink.java`:

```java
package io.casehub.platform.simulation;

@FunctionalInterface
public interface TemporalEventSink<E> {
    void deliver(String qualifiedName, String label, E event);
}
```

Create `simulation-core/src/main/java/io/casehub/platform/simulation/DriverFailure.java`:

```java
package io.casehub.platform.simulation;

public record DriverFailure(int index, String label, Exception cause) {}
```

Create `simulation-core/src/main/java/io/casehub/platform/simulation/DriverResult.java`:

```java
package io.casehub.platform.simulation;

import java.util.List;

public record DriverResult(
        int emittedCount,
        int failureCount,
        int loopIterations,
        List<DriverFailure> failures) {

    public DriverResult {
        failures = List.copyOf(failures);
    }

    public boolean hasFailures() {
        return failureCount > 0;
    }
}
```

Create `simulation-core/src/main/java/io/casehub/platform/simulation/TemporalDriverFactory.java`:

```java
package io.casehub.platform.simulation;

@FunctionalInterface
public interface TemporalDriverFactory<E> {
    TemporalSimulationDriver<E> create();
}
```

Create `simulation-core/src/main/java/io/casehub/platform/simulation/TemporalProfile.java`:

```java
package io.casehub.platform.simulation;

import java.util.Objects;

public record TemporalProfile<E>(
        String name,
        String qualifiedName,
        String tenancyId,
        TimedSequence<E> sequence,
        boolean loop,
        double speed) {

    public TemporalProfile {
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(qualifiedName, "qualifiedName");
        Objects.requireNonNull(sequence, "sequence");
        if (speed <= 0) throw new IllegalArgumentException("speed must be positive");
    }
}
```

- [ ] **Step 3: Run tests**

Run: `mvn --batch-mode -pl simulation-core test -Dtest=TemporalProfileTest`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(#371): add TemporalProfile, TemporalEventSink, DriverResult, DriverFailure, TemporalDriverFactory

Supporting types for the temporal simulation driver. TemporalProfile wraps
TimedSequence with name, qualifiedName, tenancyId, loop, speed metadata.
TemporalEventSink provides delivery context (qualifiedName, label, event).

Refs #371

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: TemporalSimulationDriver — full lifecycle

**Files:**
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/TemporalSimulationDriver.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/TemporalSimulationDriverTest.java`

**Interfaces:**
- Consumes: `TemporalProfile<E>`, `TemporalEventSink<E>`, `SimulationRuntime`, `DriverResult`, `DriverFailure`
- Produces: `TemporalSimulationDriver<E>` with `start()`, `pause()`, `resume()`, `stop()`, `setSpeed()`, `state()`, `isRunning()`, `lastResult()`

- [ ] **Step 1: Write failing test — basic run**

Create `simulation-core/src/test/java/io/casehub/platform/simulation/TemporalSimulationDriverTest.java`:

```java
package io.casehub.platform.simulation;

import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class TemporalSimulationDriverTest {

    @Test
    void basicRunDeliversAllEvents() throws InterruptedException {
        var delivered = new ArrayList<String>();
        var latch = new CountDownLatch(3);
        TemporalEventSink<String> sink = (qn, label, event) -> {
            delivered.add(event);
            latch.countDown();
        };

        var profile = new TemporalProfile<>("test", "my.method", null,
                new TimedSequence<>(List.of(
                        new TimedEntry<>("A", Duration.ZERO, "step-a"),
                        new TimedEntry<>("B", Duration.ofMillis(10), "step-b"),
                        new TimedEntry<>("C", Duration.ofMillis(10), "step-c"))),
                false, 1.0);

        var driver = new TemporalSimulationDriver<>(sink);
        driver.start(profile);
        latch.await(5, TimeUnit.SECONDS);
        Thread.sleep(50);

        assertThat(delivered).containsExactly("A", "B", "C");
        assertThat(driver.state()).isEqualTo(TemporalSimulationDriver.State.COMPLETED);
        assertThat(driver.isRunning()).isFalse();

        var result = driver.lastResult();
        assertThat(result.emittedCount()).isEqualTo(3);
        assertThat(result.hasFailures()).isFalse();
        assertThat(result.loopIterations()).isEqualTo(1);
    }
}
```

Run: `mvn --batch-mode -pl simulation-core test -Dtest=TemporalSimulationDriverTest#basicRunDeliversAllEvents`
Expected: FAIL — class does not exist

- [ ] **Step 2: Implement TemporalSimulationDriver**

Create `simulation-core/src/main/java/io/casehub/platform/simulation/TemporalSimulationDriver.java`:

```java
package io.casehub.platform.simulation;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;

public class TemporalSimulationDriver<E> {

    private static final int MAX_FAILURES = 100;

    private final TemporalEventSink<E> eventSink;
    private final SimulationRuntime simulation;

    private final ReentrantLock lock = new ReentrantLock();
    private final Condition pauseCondition = lock.newCondition();

    private volatile State state = State.IDLE;
    private volatile double speed;
    private volatile Thread driverThread;
    private volatile DriverResult lastResult;

    public enum State { IDLE, RUNNING, PAUSED, STOPPED, COMPLETED }

    public TemporalSimulationDriver(TemporalEventSink<E> eventSink, SimulationRuntime simulation) {
        this.eventSink = eventSink;
        this.simulation = simulation;
    }

    public TemporalSimulationDriver(TemporalEventSink<E> eventSink) {
        this(eventSink, null);
    }

    public void start(TemporalProfile<E> profile) {
        lock.lock();
        try {
            if (state != State.IDLE) {
                throw new IllegalStateException("Driver is " + state + ", expected IDLE");
            }
            speed = profile.speed();
            state = State.RUNNING;
            driverThread = Thread.ofVirtual()
                    .name("temporal-driver-" + profile.name())
                    .start(() -> runLoop(profile));
        } finally {
            lock.unlock();
        }
    }

    public void pause() {
        lock.lock();
        try {
            if (state == State.RUNNING) {
                state = State.PAUSED;
            }
        } finally {
            lock.unlock();
        }
    }

    public void resume() {
        lock.lock();
        try {
            if (state == State.PAUSED) {
                state = State.RUNNING;
                pauseCondition.signalAll();
            }
        } finally {
            lock.unlock();
        }
    }

    public void stop() {
        lock.lock();
        try {
            if (state == State.RUNNING || state == State.PAUSED || state == State.COMPLETED) {
                state = State.STOPPED;
                pauseCondition.signalAll();
                if (driverThread != null) {
                    driverThread.interrupt();
                }
            }
        } finally {
            lock.unlock();
        }
    }

    public void setSpeed(double speed) {
        if (speed <= 0) throw new IllegalArgumentException("speed must be positive");
        this.speed = speed;
    }

    public State state() { return state; }

    public boolean isRunning() { return state == State.RUNNING; }

    public DriverResult lastResult() { return lastResult; }

    private void runLoop(TemporalProfile<E> profile) {
        int emittedCount = 0;
        int failureCount = 0;
        int loopIterations = 0;
        List<DriverFailure> failures = new ArrayList<>();

        try {
            do {
                List<TimedEntry<E>> entries = profile.sequence().entries();
                for (int i = 0; i < entries.size(); i++) {
                    checkPauseOrStop();
                    if (state == State.STOPPED) break;

                    TimedEntry<E> entry = entries.get(i);

                    if (!entry.delay().isZero()) {
                        long delayMs = (long) (entry.delay().toMillis() / speed);
                        if (delayMs > 0) {
                            Thread.sleep(delayMs);
                        }
                    }

                    checkPauseOrStop();
                    if (state == State.STOPPED) break;

                    String effectiveQN = entry.qualifiedName() != null
                            ? entry.qualifiedName() : profile.qualifiedName();

                    try {
                        eventSink.deliver(effectiveQN, entry.label(), entry.event());
                        emittedCount++;

                        if (simulation != null) {
                            simulation.recordJournal(effectiveQN,
                                    profile.tenancyId(), entry.label(),
                                    entry.event(), true);
                        }
                    } catch (Exception e) {
                        failureCount++;
                        if (failures.size() < MAX_FAILURES) {
                            failures.add(new DriverFailure(i, entry.label(), e));
                        }
                    }
                }

                if (state != State.STOPPED) {
                    loopIterations++;
                }

            } while (profile.loop() && state != State.STOPPED);

        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }

        lastResult = new DriverResult(emittedCount, failureCount,
                loopIterations, failures);

        lock.lock();
        try {
            if (state != State.STOPPED) {
                state = State.COMPLETED;
            }
        } finally {
            lock.unlock();
        }
    }

    private void checkPauseOrStop() throws InterruptedException {
        lock.lock();
        try {
            while (state == State.PAUSED) {
                pauseCondition.await();
            }
        } finally {
            lock.unlock();
        }
    }
}
```

- [ ] **Step 3: Run basic test**

Run: `mvn --batch-mode -pl simulation-core test -Dtest=TemporalSimulationDriverTest#basicRunDeliversAllEvents`
Expected: PASS

- [ ] **Step 4: Add looping test**

```java
@Test
void loopingRepeatsSequence() throws InterruptedException {
    var delivered = new ArrayList<String>();
    var latch = new CountDownLatch(6);
    TemporalEventSink<String> sink = (qn, label, event) -> {
        delivered.add(event);
        latch.countDown();
    };

    var profile = new TemporalProfile<>("loop-test", "my.method", null,
            new TimedSequence<>(List.of(
                    new TimedEntry<>("A", Duration.ZERO),
                    new TimedEntry<>("B", Duration.ofMillis(10)))),
            true, 1.0);

    var driver = new TemporalSimulationDriver<>(sink);
    driver.start(profile);
    latch.await(5, TimeUnit.SECONDS);
    driver.stop();

    assertThat(delivered.size()).isGreaterThanOrEqualTo(6);
    assertThat(delivered.get(0)).isEqualTo("A");
    assertThat(delivered.get(1)).isEqualTo("B");
    assertThat(delivered.get(2)).isEqualTo("A");
    assertThat(driver.lastResult().loopIterations()).isGreaterThanOrEqualTo(3);
}
```

Run: `mvn --batch-mode -pl simulation-core test -Dtest=TemporalSimulationDriverTest#loopingRepeatsSequence`
Expected: PASS

- [ ] **Step 5: Add pause/resume test**

```java
@Test
void pauseStopsDeliveryResumeRestarts() throws InterruptedException {
    var delivered = new ArrayList<String>();
    TemporalEventSink<String> sink = (qn, label, event) -> delivered.add(event);

    var profile = new TemporalProfile<>("pause-test", "my.method", null,
            new TimedSequence<>(List.of(
                    new TimedEntry<>("A", Duration.ZERO),
                    new TimedEntry<>("B", Duration.ofMillis(200)),
                    new TimedEntry<>("C", Duration.ofMillis(10)))),
            false, 1.0);

    var driver = new TemporalSimulationDriver<>(sink);
    driver.start(profile);
    Thread.sleep(50);
    driver.pause();
    assertThat(driver.state()).isEqualTo(TemporalSimulationDriver.State.PAUSED);
    int countAtPause = delivered.size();
    Thread.sleep(100);
    assertThat(delivered.size()).isEqualTo(countAtPause);

    driver.resume();
    Thread.sleep(500);
    assertThat(driver.state()).isEqualTo(TemporalSimulationDriver.State.COMPLETED);
    assertThat(delivered).containsExactly("A", "B", "C");
}
```

Run: `mvn --batch-mode -pl simulation-core test -Dtest=TemporalSimulationDriverTest#pauseStopsDeliveryResumeRestarts`
Expected: PASS

- [ ] **Step 6: Add stop, speed, setSpeed, error isolation, journal, and start-validation tests**

```java
@Test
void stopTerminatesDriver() throws InterruptedException {
    var delivered = new ArrayList<String>();
    TemporalEventSink<String> sink = (qn, label, event) -> delivered.add(event);

    var profile = new TemporalProfile<>("stop-test", "my.method", null,
            new TimedSequence<>(List.of(
                    new TimedEntry<>("A", Duration.ZERO),
                    new TimedEntry<>("B", Duration.ofMillis(500)),
                    new TimedEntry<>("C", Duration.ofMillis(10)))),
            false, 1.0);

    var driver = new TemporalSimulationDriver<>(sink);
    driver.start(profile);
    Thread.sleep(50);
    driver.stop();
    Thread.sleep(100);

    assertThat(driver.state()).isEqualTo(TemporalSimulationDriver.State.STOPPED);
    assertThat(delivered).containsExactly("A");
}

@Test
void speedScalesDelays() throws InterruptedException {
    var timestamps = new ArrayList<Long>();
    TemporalEventSink<String> sink = (qn, label, event) -> timestamps.add(System.nanoTime());
    var latch = new CountDownLatch(2);
    TemporalEventSink<String> trackingSink = (qn, label, event) -> {
        timestamps.add(System.nanoTime());
        latch.countDown();
    };

    var profile = new TemporalProfile<>("speed-test", "my.method", null,
            new TimedSequence<>(List.of(
                    new TimedEntry<>("A", Duration.ZERO),
                    new TimedEntry<>("B", Duration.ofMillis(500)))),
            false, 10.0);

    var driver = new TemporalSimulationDriver<>(trackingSink);
    driver.start(profile);
    latch.await(5, TimeUnit.SECONDS);
    Thread.sleep(50);

    long gapMs = (timestamps.get(1) - timestamps.get(0)) / 1_000_000;
    assertThat(gapMs).isBetween(20L, 150L);
}

@Test
void setSpeedChangesNextDelay() throws InterruptedException {
    var timestamps = new ArrayList<Long>();
    var latch = new CountDownLatch(3);
    TemporalEventSink<String> sink = (qn, label, event) -> {
        timestamps.add(System.nanoTime());
        latch.countDown();
    };

    var profile = new TemporalProfile<>("setspeed-test", "my.method", null,
            new TimedSequence<>(List.of(
                    new TimedEntry<>("A", Duration.ZERO),
                    new TimedEntry<>("B", Duration.ofMillis(500)),
                    new TimedEntry<>("C", Duration.ofMillis(500)))),
            false, 1.0);

    var driver = new TemporalSimulationDriver<>(sink);
    driver.start(profile);
    Thread.sleep(20);
    driver.setSpeed(100.0);
    latch.await(5, TimeUnit.SECONDS);
    Thread.sleep(50);

    long gap2Ms = (timestamps.get(2) - timestamps.get(1)) / 1_000_000;
    assertThat(gap2Ms).isLessThan(100);
}

@Test
void errorIsolationContinuesSequence() throws InterruptedException {
    var delivered = new ArrayList<String>();
    var latch = new CountDownLatch(2);
    TemporalEventSink<String> sink = (qn, label, event) -> {
        if ("B".equals(event)) throw new RuntimeException("deliberate");
        delivered.add(event);
        latch.countDown();
    };

    var profile = new TemporalProfile<>("error-test", "my.method", null,
            new TimedSequence<>(List.of(
                    new TimedEntry<>("A", Duration.ZERO, "step-a"),
                    new TimedEntry<>("B", Duration.ofMillis(10), "step-b"),
                    new TimedEntry<>("C", Duration.ofMillis(10), "step-c"))),
            false, 1.0);

    var driver = new TemporalSimulationDriver<>(sink);
    driver.start(profile);
    latch.await(5, TimeUnit.SECONDS);
    Thread.sleep(50);

    assertThat(delivered).containsExactly("A", "C");
    var result = driver.lastResult();
    assertThat(result.emittedCount()).isEqualTo(2);
    assertThat(result.failureCount()).isEqualTo(1);
    assertThat(result.failures()).hasSize(1);
    assertThat(result.failures().get(0).index()).isEqualTo(1);
    assertThat(result.failures().get(0).label()).isEqualTo("step-b");
}

@Test
void journalRecordsWithOverlay() throws InterruptedException {
    var runtime = new SimulationRuntime(
            new MapSimulationConfig(java.util.Map.of()),
            new io.casehub.platform.simulation.inmem.InMemorySimulationCorpus<>());
    var overlay = runtime.pushOverlay(
            new MapSimulationConfig(java.util.Map.of()));

    var latch = new CountDownLatch(2);
    TemporalEventSink<String> sink = (qn, label, event) -> latch.countDown();

    var profile = new TemporalProfile<>("journal-test", "my.method", "t1",
            new TimedSequence<>(List.of(
                    new TimedEntry<>("A", Duration.ZERO, "step-a"),
                    new TimedEntry<>("B", Duration.ofMillis(10), "step-b"))),
            false, 1.0);

    var driver = new TemporalSimulationDriver<>(sink, runtime);
    driver.start(profile);
    latch.await(5, TimeUnit.SECONDS);
    Thread.sleep(50);
    driver.stop();

    var entries = runtime.journal(overlay);
    assertThat(entries).hasSize(2);
    assertThat(entries.get(0).qualifiedName()).isEqualTo("my.method");
    assertThat(entries.get(0).tenancyId()).isEqualTo("t1");

    runtime.popOverlay(overlay);
}

@Test
void startOnNonIdleThrows() {
    TemporalEventSink<String> sink = (qn, label, event) -> {};
    var profile = new TemporalProfile<>("test", "qn", null,
            new TimedSequence<>(List.of(new TimedEntry<>("A", Duration.ofSeconds(60)))),
            false, 1.0);

    var driver = new TemporalSimulationDriver<>(sink);
    driver.start(profile);
    assertThatThrownBy(() -> driver.start(profile))
            .isInstanceOf(IllegalStateException.class);
    driver.stop();
}

@Test
void setSpeedRejectsZero() {
    TemporalEventSink<String> sink = (qn, label, event) -> {};
    var driver = new TemporalSimulationDriver<>(sink);
    assertThatThrownBy(() -> driver.setSpeed(0))
            .isInstanceOf(IllegalArgumentException.class);
}

@Test
void concatQualifiedNamesPreserved() throws InterruptedException {
    var qualifiedNames = new ArrayList<String>();
    var latch = new CountDownLatch(2);
    TemporalEventSink<String> sink = (qn, label, event) -> {
        qualifiedNames.add(qn);
        latch.countDown();
    };

    var profile = new TemporalProfile<>("concat-test", "parent.method", null,
            new TimedSequence<>(List.of(
                    new TimedEntry<>("A", Duration.ZERO, "a", "child.method"),
                    new TimedEntry<>("B", Duration.ofMillis(10), "b", null))),
            false, 1.0);

    var driver = new TemporalSimulationDriver<>(sink);
    driver.start(profile);
    latch.await(5, TimeUnit.SECONDS);
    Thread.sleep(50);

    assertThat(qualifiedNames.get(0)).isEqualTo("child.method");
    assertThat(qualifiedNames.get(1)).isEqualTo("parent.method");
}
```

Run: `mvn --batch-mode -pl simulation-core test -Dtest=TemporalSimulationDriverTest`
Expected: PASS — all tests green

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(#371): TemporalSimulationDriver — lifecycle-controlled temporal simulation

Virtual-thread driver with start/pause/resume/stop/setSpeed lifecycle.
Journal integration via SimulationRuntime.recordJournal(). Error isolation
per event. Per-entry qualifiedName override for concat attribution.

Refs #371

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 2: YAML loading — temporal profiles in simulation-config-core

### Task 4: Parse temporal-profiles YAML — inline events + duration parsing

**Files:**
- Create: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/TemporalProfileConfig.java`
- Create: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/TemporalEventConfig.java`
- Create: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/SequenceRef.java`
- Create: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/DurationParser.java`
- Modify: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/YamlSimulationConfig.java`
- Test: `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/YamlTemporalProfileTest.java`

**Interfaces:**
- Consumes: `TimedEntry<E>`, `TimedSequence<E>`, `TemporalProfile<E>` from simulation-core
- Produces: `TemporalProfileConfig`, `TemporalEventConfig`, `SequenceRef`, `DurationParser.parse(String) → Duration`
- Produces: `YamlSimulationConfig.temporalProfiles()`, `YamlSimulationConfig.resolveTemporalProfile(String)`

- [ ] **Step 1: Write failing test for inline temporal profile parsing**

Create `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/YamlTemporalProfileTest.java`:

```java
package io.casehub.platform.simulation.config;

import io.casehub.platform.simulation.TemporalProfile;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class YamlTemporalProfileTest {

    @Test
    void parsesInlineEvents() {
        var yaml = """
                temporal-profiles:
                  morning-routine:
                    qualified-name: iot.device-state
                    tenancy-id: demo
                    loop: true
                    speed: 10.0
                    events:
                      - delay: 0
                        label: motion-start
                        payload:
                          deviceId: motion-01
                          state: ACTIVE
                      - delay: 5s
                        label: lights-on
                        payload:
                          deviceId: light-01
                          state: "ON"
                """;

        var config = parse(yaml);
        var profiles = config.temporalProfiles();
        assertThat(profiles).containsKey("morning-routine");

        var tp = profiles.get("morning-routine");
        assertThat(tp.qualifiedName()).isEqualTo("iot.device-state");
        assertThat(tp.tenancyId()).isEqualTo("demo");
        assertThat(tp.loop()).isTrue();
        assertThat(tp.speed()).isEqualTo(10.0);
        assertThat(tp.events()).hasSize(2);
        assertThat(tp.events().get(0).delay()).isEqualTo("0");
        assertThat(tp.events().get(0).label()).isEqualTo("motion-start");
        assertThat(tp.events().get(1).delay()).isEqualTo("5s");
    }

    @Test
    void resolvesTemporalProfile() {
        var yaml = """
                temporal-profiles:
                  test-profile:
                    qualified-name: my.method
                    events:
                      - delay: 0
                        label: step-a
                        payload:
                          key: value
                      - delay: 500ms
                        payload:
                          key: value2
                """;

        var config = parse(yaml);
        var profile = config.resolveTemporalProfile("test-profile");
        assertThat(profile).isPresent();

        TemporalProfile<Map<String, Object>> p = profile.get();
        assertThat(p.name()).isEqualTo("test-profile");
        assertThat(p.qualifiedName()).isEqualTo("my.method");
        assertThat(p.sequence().size()).isEqualTo(2);
        assertThat(p.sequence().entries().get(0).label()).isEqualTo("step-a");
        assertThat(p.sequence().entries().get(1).delay()).isEqualTo(Duration.ofMillis(500));
        assertThat(p.loop()).isFalse();
        assertThat(p.speed()).isEqualTo(1.0);
    }

    private YamlSimulationConfig parse(String yaml) {
        return new YamlSimulationConfig(
                new ByteArrayInputStream(yaml.getBytes(StandardCharsets.UTF_8)));
    }
}
```

Run: `mvn --batch-mode -pl simulation-config-core test -Dtest=YamlTemporalProfileTest`
Expected: FAIL — no temporalProfiles() method

- [ ] **Step 2: Create DurationParser**

Create `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/DurationParser.java`:

```java
package io.casehub.platform.simulation.config;

import java.time.Duration;

public final class DurationParser {

    private DurationParser() {}

    public static Duration parse(String value) {
        if (value == null || value.isBlank()) return Duration.ZERO;
        String trimmed = value.trim();
        if (trimmed.endsWith("ms")) {
            return Duration.ofMillis(Long.parseLong(trimmed.substring(0, trimmed.length() - 2)));
        }
        if (trimmed.endsWith("s")) {
            return Duration.ofSeconds(Long.parseLong(trimmed.substring(0, trimmed.length() - 1)));
        }
        if (trimmed.endsWith("m")) {
            return Duration.ofMinutes(Long.parseLong(trimmed.substring(0, trimmed.length() - 1)));
        }
        return Duration.ofMillis(Long.parseLong(trimmed));
    }
}
```

- [ ] **Step 3: Create config record types**

Create `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/TemporalEventConfig.java`:

```java
package io.casehub.platform.simulation.config;

import java.util.Map;

public record TemporalEventConfig(String delay, String label, Map<String, Object> payload) {}
```

Create `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/SequenceRef.java`:

```java
package io.casehub.platform.simulation.config;

public record SequenceRef(String ref, String delay) {}
```

Create `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/TemporalProfileConfig.java`:

```java
package io.casehub.platform.simulation.config;

import java.util.List;

public record TemporalProfileConfig(
        String qualifiedName,
        String tenancyId,
        boolean loop,
        double speed,
        List<TemporalEventConfig> events,
        String eventsFile,
        String fromCorpus,
        List<SequenceRef> sequence) {

    public TemporalProfileConfig {
        int sourceCount = (events != null && !events.isEmpty() ? 1 : 0)
                + (eventsFile != null ? 1 : 0)
                + (fromCorpus != null ? 1 : 0)
                + (sequence != null && !sequence.isEmpty() ? 1 : 0);
        if (sourceCount > 1) {
            throw new IllegalArgumentException(
                    "Temporal profile must have exactly one source (events, events-file, from-corpus, or sequence), found " + sourceCount);
        }
    }
}
```

- [ ] **Step 4: Add temporal profile parsing to YamlSimulationConfig**

Add field and constructor initialization in `YamlSimulationConfig`:

```java
// New field alongside methods and profiles:
private final Map<String, TemporalProfileConfig> temporalProfiles;

// In constructor, after profiles parsing:
this.temporalProfiles = parseTemporalProfiles(
        (Map<String, Map<String, Object>>) root.get("temporal-profiles"));
```

Add new methods:

```java
public Map<String, TemporalProfileConfig> temporalProfiles() {
    return Collections.unmodifiableMap(temporalProfiles);
}

public Optional<TemporalProfile<Map<String, Object>>> resolveTemporalProfile(String name) {
    TemporalProfileConfig tpc = temporalProfiles.get(name);
    if (tpc == null) return Optional.empty();
    return Optional.of(resolveTemporalProfileConfig(name, tpc, new java.util.HashSet<>()));
}

private TemporalProfile<Map<String, Object>> resolveTemporalProfileConfig(
        String name, TemporalProfileConfig tpc, java.util.Set<String> visited) {
    if (!visited.add(name)) {
        throw new io.casehub.platform.simulation.SimulationConfigException(
                "Circular temporal profile reference: " + name);
    }

    TimedSequence<Map<String, Object>> sequence;

    if (tpc.events() != null && !tpc.events().isEmpty()) {
        var entries = tpc.events().stream()
                .map(e -> new TimedEntry<>(
                        e.payload(),
                        DurationParser.parse(e.delay()),
                        e.label()))
                .toList();
        sequence = new TimedSequence<>(entries);
    } else if (tpc.eventsFile() != null) {
        sequence = loadTemporalEventsFromFile(tpc.eventsFile());
    } else if (tpc.fromCorpus() != null) {
        var records = loadCorpusForTemporalProfile(tpc.fromCorpus());
        sequence = TimedSequence.fromRecorded(records);
    } else if (tpc.sequence() != null && !tpc.sequence().isEmpty()) {
        sequence = resolveSequenceRefs(tpc.sequence(), visited);
    } else {
        sequence = new TimedSequence<>(List.of());
    }

    String tenancyId = tpc.tenancyId() != null ? tpc.tenancyId() : defaultTenancyId;
    return new TemporalProfile<>(name, tpc.qualifiedName(), tenancyId,
            sequence, tpc.loop(), tpc.speed() > 0 ? tpc.speed() : 1.0);
}

private TimedSequence<Map<String, Object>> resolveSequenceRefs(
        List<SequenceRef> refs, java.util.Set<String> visited) {
    var allEntries = new java.util.ArrayList<TimedEntry<Map<String, Object>>>();
    for (SequenceRef ref : refs) {
        TemporalProfileConfig refConfig = temporalProfiles.get(ref.ref());
        if (refConfig == null) {
            throw new io.casehub.platform.simulation.SimulationConfigException(
                    "Unknown temporal profile ref: " + ref.ref());
        }
        TemporalProfile<Map<String, Object>> resolved =
                resolveTemporalProfileConfig(ref.ref(), refConfig, new java.util.HashSet<>(visited));

        List<TimedEntry<Map<String, Object>>> refEntries = resolved.sequence().entries();
        if (!refEntries.isEmpty()) {
            for (int i = 0; i < refEntries.size(); i++) {
                TimedEntry<Map<String, Object>> entry = refEntries.get(i);
                String entryQN = entry.qualifiedName() != null
                        ? entry.qualifiedName() : resolved.qualifiedName();
                if (i == 0 && ref.delay() != null) {
                    Duration gap = DurationParser.parse(ref.delay());
                    allEntries.add(new TimedEntry<>(entry.event(),
                            entry.delay().plus(gap), entry.label(), entryQN));
                } else {
                    allEntries.add(new TimedEntry<>(entry.event(),
                            entry.delay(), entry.label(), entryQN));
                }
            }
        }
    }
    return new TimedSequence<>(allEntries);
}

@SuppressWarnings("unchecked")
private TimedSequence<Map<String, Object>> loadTemporalEventsFromFile(String path) {
    InputStream is = StreamResolver.resolve(path);
    if (is == null) {
        throw new io.casehub.platform.simulation.SimulationConfigException(
                "Temporal events file not found: " + path);
    }
    try (is) {
        List<Map<String, Object>> rawEvents = YAML_MAPPER.readValue(is, List.class);
        var entries = rawEvents.stream()
                .map(e -> new TimedEntry<>(
                        (Map<String, Object>) e.get("payload"),
                        DurationParser.parse(String.valueOf(e.getOrDefault("delay", "0"))),
                        (String) e.get("label")))
                .toList();
        return new TimedSequence<>(entries);
    } catch (java.io.IOException e) {
        throw new java.io.UncheckedIOException("Failed to load temporal events from " + path, e);
    }
}

@SuppressWarnings("unchecked")
private List<InvocationRecord<Object, Object>> loadCorpusForTemporalProfile(String qn) {
    MethodConfig mc = methods.get(qn);
    if (mc == null) return List.of();
    return loadCorpusForMethod(qn, mc);
}

@SuppressWarnings("unchecked")
private Map<String, TemporalProfileConfig> parseTemporalProfiles(
        Map<String, Map<String, Object>> raw) {
    if (raw == null) return Map.of();
    Map<String, TemporalProfileConfig> result = new LinkedHashMap<>();
    raw.forEach((name, props) -> result.put(name, parseTemporalProfileConfig(props)));
    return result;
}

@SuppressWarnings("unchecked")
private TemporalProfileConfig parseTemporalProfileConfig(Map<String, Object> props) {
    String qualifiedName = (String) props.get("qualified-name");
    String tenancyId = (String) props.get("tenancy-id");
    boolean loop = Boolean.TRUE.equals(props.get("loop"));
    double speed = props.containsKey("speed")
            ? ((Number) props.get("speed")).doubleValue() : 0;
    String eventsFile = (String) props.get("events-file");
    String fromCorpus = (String) props.get("from-corpus");

    List<TemporalEventConfig> events = null;
    List<Map<String, Object>> rawEvents = (List<Map<String, Object>>) props.get("events");
    if (rawEvents != null) {
        events = rawEvents.stream()
                .map(e -> new TemporalEventConfig(
                        String.valueOf(e.getOrDefault("delay", "0")),
                        (String) e.get("label"),
                        (Map<String, Object>) e.get("payload")))
                .toList();
    }

    List<SequenceRef> sequence = null;
    List<Map<String, Object>> rawSeq = (List<Map<String, Object>>) props.get("sequence");
    if (rawSeq != null) {
        sequence = rawSeq.stream()
                .map(s -> new SequenceRef(
                        (String) s.get("ref"),
                        s.containsKey("delay") ? String.valueOf(s.get("delay")) : null))
                .toList();
    }

    return new TemporalProfileConfig(qualifiedName, tenancyId, loop, speed,
            events, eventsFile, fromCorpus, sequence);
}
```

Update `KNOWN_TOP_LEVEL_KEYS`:

```java
private static final Set<String> KNOWN_TOP_LEVEL_KEYS =
        Set.of("default-tenancy-id", "methods", "profiles", "temporal-profiles");
```

- [ ] **Step 5: Run tests**

Run: `mvn --batch-mode -pl simulation-config-core test -Dtest=YamlTemporalProfileTest`
Expected: PASS

- [ ] **Step 6: Add tests for duration parsing, mutual exclusivity, cycle detection, sequence refs**

Add to `YamlTemporalProfileTest.java`:

```java
@Test
void durationParsingVariants() {
    assertThat(DurationParser.parse("0")).isEqualTo(Duration.ZERO);
    assertThat(DurationParser.parse("500")).isEqualTo(Duration.ofMillis(500));
    assertThat(DurationParser.parse("500ms")).isEqualTo(Duration.ofMillis(500));
    assertThat(DurationParser.parse("5s")).isEqualTo(Duration.ofSeconds(5));
    assertThat(DurationParser.parse("2m")).isEqualTo(Duration.ofMinutes(2));
    assertThat(DurationParser.parse(null)).isEqualTo(Duration.ZERO);
    assertThat(DurationParser.parse("")).isEqualTo(Duration.ZERO);
}

@Test
void mutualExclusivityRejectsMultipleSources() {
    assertThatThrownBy(() -> new TemporalProfileConfig(
            "qn", null, false, 1.0,
            List.of(new TemporalEventConfig("0", null, Map.of())),
            "classpath:file.yaml", null, null))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("exactly one source");
}

@Test
void sequenceRefsResolve() {
    var yaml = """
            temporal-profiles:
              step-a:
                qualified-name: method.a
                events:
                  - delay: 0
                    label: a1
                    payload: {key: a}
              step-b:
                qualified-name: method.b
                events:
                  - delay: 0
                    label: b1
                    payload: {key: b}
              combined:
                qualified-name: method.combined
                sequence:
                  - ref: step-a
                  - delay: 1s
                    ref: step-b
            """;

    var config = parse(yaml);
    var profile = config.resolveTemporalProfile("combined").get();

    assertThat(profile.sequence().size()).isEqualTo(2);
    assertThat(profile.sequence().entries().get(0).label()).isEqualTo("a1");
    assertThat(profile.sequence().entries().get(0).qualifiedName()).isEqualTo("method.a");
    assertThat(profile.sequence().entries().get(1).label()).isEqualTo("b1");
    assertThat(profile.sequence().entries().get(1).qualifiedName()).isEqualTo("method.b");
    assertThat(profile.sequence().entries().get(1).delay()).isEqualTo(Duration.ofSeconds(1));
}

@Test
void circularRefThrows() {
    var yaml = """
            temporal-profiles:
              a:
                qualified-name: qn
                sequence:
                  - ref: b
              b:
                qualified-name: qn
                sequence:
                  - ref: a
            """;

    var config = parse(yaml);
    assertThatThrownBy(() -> config.resolveTemporalProfile("a"))
            .isInstanceOf(io.casehub.platform.simulation.SimulationConfigException.class)
            .hasMessageContaining("Circular");
}

@Test
void defaultSpeedIsOne() {
    var yaml = """
            temporal-profiles:
              minimal:
                qualified-name: qn
                events:
                  - delay: 0
                    payload: {k: v}
            """;

    var config = parse(yaml);
    var profile = config.resolveTemporalProfile("minimal").get();
    assertThat(profile.speed()).isEqualTo(1.0);
}

@Test
void temporalInProfilesInline() {
    var yaml = """
            profiles:
              demo:
                methods: {}
                temporal:
                  - qualified-name: inline.method
                    events:
                      - delay: 0
                        payload: {k: v}
            """;

    var config = parse(yaml);
    var temporal = config.temporalForProfile("demo");
    assertThat(temporal).hasSize(1);
    assertThat(temporal.get(0).qualifiedName()).isEqualTo("inline.method");
}

@Test
void temporalInProfilesRefs() {
    var yaml = """
            temporal-profiles:
              reusable:
                qualified-name: reusable.method
                events:
                  - delay: 0
                    payload: {k: v}
            profiles:
              demo:
                methods: {}
                temporal:
                  - ref: reusable
            """;

    var config = parse(yaml);
    var temporal = config.temporalForProfile("demo");
    assertThat(temporal).hasSize(1);
    assertThat(temporal.get(0).qualifiedName()).isEqualTo("reusable.method");
}
```

- [ ] **Step 7: Add `temporalForProfile()` and inline parsing to `YamlSimulationConfig`**

Update `ProfileConfig` to include temporal:

```java
record ProfileConfig(
        Map<String, MethodConfig> methods,
        List<String> corpusFiles,
        List<TemporalProfileConfig> temporal) {}
```

Update `parseProfiles()` to parse the `temporal:` key:

```java
@SuppressWarnings("unchecked")
private Map<String, ProfileConfig> parseProfiles(Map<String, Map<String, Object>> raw) {
    if (raw == null) return Map.of();
    Map<String, ProfileConfig> result = new LinkedHashMap<>();
    raw.forEach((name, props) -> {
        Map<String, MethodConfig> profileMethods = parseMethods(
                (Map<String, Map<String, Object>>) props.get("methods"));
        List<String> corpusFiles = (List<String>) props.get("corpus-files");
        List<TemporalProfileConfig> temporal = parseTemporalList(
                (List<Object>) props.get("temporal"));
        result.put(name, new ProfileConfig(profileMethods, corpusFiles, temporal));
    });
    return result;
}

@SuppressWarnings("unchecked")
private List<TemporalProfileConfig> parseTemporalList(List<Object> raw) {
    if (raw == null) return List.of();
    return raw.stream().map(item -> {
        Map<String, Object> props = (Map<String, Object>) item;
        if (props.containsKey("ref") && props.size() == 1) {
            String ref = (String) props.get("ref");
            TemporalProfileConfig refConfig = temporalProfiles.get(ref);
            if (refConfig == null) {
                throw new io.casehub.platform.simulation.SimulationConfigException(
                        "Unknown temporal profile ref: " + ref);
            }
            return refConfig;
        }
        return parseTemporalProfileConfig(props);
    }).toList();
}

public List<TemporalProfileConfig> temporalForProfile(String profileName) {
    ProfileConfig profile = profiles.get(profileName);
    if (profile == null) return List.of();
    return profile.temporal() != null ? profile.temporal() : List.of();
}
```

- [ ] **Step 8: Run all tests**

Run: `mvn --batch-mode -pl simulation-config-core test -Dtest=YamlTemporalProfileTest`
Expected: PASS

Run: `mvn --batch-mode -pl simulation-config-core test`
Expected: PASS — no regressions in existing tests

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat(#371): YAML temporal profile parsing — inline events, duration, sequence refs, cycle detection

Parse temporal-profiles top-level section and temporal within profiles.
Four mutually exclusive sources: events, events-file, from-corpus, sequence.
DurationParser handles ms/s/m suffixes. Cycle detection on sequence refs.
Gap delay absorbed into first entry of referenced profile.

Refs #371

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 3: Quarkus wiring — CDI beans

### Task 5: TemporalProfileRegistry in simulation-config, TemporalDriverFactory in event-simulation

**Files:**
- Create: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/TemporalProfileRegistry.java`
- Modify: `simulation-config/src/main/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigBeans.java`
- Modify: `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/EventSimulationBeans.java`
- Modify: `event-simulation/pom.xml` (add jackson-databind for payload serialization)
- Test: `event-simulation/src/test/java/io/casehub/platform/simulation/event/quarkus/TemporalDriverFactoryTest.java`

**Interfaces:**
- Consumes: `YamlSimulationConfig.resolveTemporalProfile()`, `TemporalProfile<Map<String, Object>>`, `TemporalSimulationDriver<E>`, `TemporalDriverFactory<E>`, `TemporalEventSink<E>`
- Produces: CDI `TemporalProfileRegistry` bean, CDI `TemporalDriverFactory<Map<String, Object>>` bean

- [ ] **Step 1: Create TemporalProfileRegistry**

Create `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/TemporalProfileRegistry.java`:

```java
package io.casehub.platform.simulation.config;

import io.casehub.platform.simulation.TemporalProfile;

import java.util.Collections;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

public class TemporalProfileRegistry {

    private final Map<String, TemporalProfile<Map<String, Object>>> profiles;

    public TemporalProfileRegistry(Map<String, TemporalProfile<Map<String, Object>>> profiles) {
        this.profiles = Map.copyOf(profiles);
    }

    public Optional<TemporalProfile<Map<String, Object>>> resolve(String name) {
        return Optional.ofNullable(profiles.get(name));
    }

    public Set<String> profileNames() {
        return Collections.unmodifiableSet(profiles.keySet());
    }
}
```

- [ ] **Step 2: Add @Produces TemporalProfileRegistry to SimulationConfigBeans**

Add to `simulation-config/src/main/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigBeans.java`:

```java
@Produces
@ApplicationScoped
public TemporalProfileRegistry temporalProfileRegistry(YamlSimulationConfig config) {
    var resolved = new java.util.LinkedHashMap<String, io.casehub.platform.simulation.TemporalProfile<java.util.Map<String, Object>>>();
    for (String name : config.temporalProfiles().keySet()) {
        config.resolveTemporalProfile(name).ifPresent(p -> resolved.put(name, p));
    }
    return new TemporalProfileRegistry(resolved);
}
```

Add import for `TemporalProfileRegistry`:
```java
import io.casehub.platform.simulation.config.TemporalProfileRegistry;
```

- [ ] **Step 3: Add @Produces TemporalDriverFactory to EventSimulationBeans**

Add to `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/EventSimulationBeans.java`:

```java
@Produces
@ApplicationScoped
public TemporalDriverFactory<java.util.Map<String, Object>> temporalDriverFactory(
        SimulationRuntime runtime) {
    return () -> new TemporalSimulationDriver<>(
            (qualifiedName, label, payload) -> {
                try {
                    var mapper = new com.fasterxml.jackson.databind.ObjectMapper();
                    io.cloudevents.CloudEvent ce = io.cloudevents.core.builder.CloudEventBuilder.v1()
                            .withType(qualifiedName)
                            .withId(java.util.UUID.randomUUID().toString())
                            .withSource(java.net.URI.create("//simulation"))
                            .withTime(java.time.OffsetDateTime.now())
                            .withData("application/json", mapper.writeValueAsBytes(payload))
                            .build();
                    cloudEventBus.fireAsync(ce);
                } catch (com.fasterxml.jackson.core.JsonProcessingException e) {
                    throw new java.io.UncheckedIOException(e);
                }
            },
            runtime);
}
```

Add imports:
```java
import io.casehub.platform.simulation.TemporalDriverFactory;
import io.casehub.platform.simulation.TemporalSimulationDriver;
```

- [ ] **Step 4: Add jackson-databind to event-simulation pom.xml if not present**

Check if jackson-databind is already a transitive dependency (it comes via event-simulation-core → jackson-databind). If present transitively, no change needed. If not, add:

```xml
<dependency>
    <groupId>com.fasterxml.jackson.core</groupId>
    <artifactId>jackson-databind</artifactId>
</dependency>
```

- [ ] **Step 5: Verify full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile and tests pass

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(#371): CDI wiring — TemporalProfileRegistry + TemporalDriverFactory<Map>

TemporalProfileRegistry resolves YAML temporal profiles by name.
TemporalDriverFactory<Map<String, Object>> produces drivers wired to
Event<CloudEvent>.fireAsync() with qualifiedName→type, payload→JSON data.

Refs #371

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## References

- [2026-09-20-temporal-simulation-driver-design.md](../specs/issue-371-temporal-simulation-driver/2026-09-20-temporal-simulation-driver-design.md) — design spec this plan implements
- [decisions.md](../specs/issue-371-temporal-simulation-driver/decisions.md) — D1-D6
- simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java — overlay stack, journal recording
- simulation-core/src/main/java/io/casehub/platform/simulation/JournalEntry.java — journal record
- event-simulation-core/src/main/java/io/casehub/platform/simulation/event/TimedEntry.java — moved to simulation-core
- event-simulation-core/src/main/java/io/casehub/platform/simulation/event/TimedSequence.java — moved to simulation-core
- event-simulation-core/src/main/java/io/casehub/platform/simulation/event/EventSequenceRunner.java — existing one-shot runner
- simulation-config-core/src/main/java/io/casehub/platform/simulation/config/YamlSimulationConfig.java — YAML parsing
- simulation-config/src/main/java/io/casehub/platform/simulation/config/quarkus/SimulationConfigBeans.java — CDI wiring
- event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/EventSimulationBeans.java — CDI wiring
- GE-20260701-82909e — ScheduledFuture gotcha (motivated virtual-thread choice)
- [GitHub #371](https://github.com/casehubio/platform/issues/371) — focal issue
