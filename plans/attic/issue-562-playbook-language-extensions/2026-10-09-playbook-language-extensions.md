# Playbook Language Extensions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #562 — Playbook language: supply-gated triggers, inline continuations, step priority
**Issue group:** #562

**Goal:** Add three playbook language primitives — `at:` metric-threshold triggers, `on-complete:` inline continuations, and `priority:`/`resource:` step priority — to yaml-core and yaml-step-runtime.

**Architecture:** New `OrcNumericPrimitive` marker interface unifies numeric primitives with callback-driven observation. `PriorityOrcSemaphore` extends the semaphore model with priority-aware acquisition. `on-complete:` is pure parse-phase syntax sugar desugaring to signal/wait. `at:` and `resource:` are DecoratorChain extensions.

**Tech Stack:** Java 21, yaml-core (zero-dep, j.u.c concurrency), yaml-jackson (Jackson), yaml-step-runtime (step evaluation), JUnit 5

## Global Constraints

- yaml-core must remain zero-dependency and J2CL-safe
- All primitives MUST use j.u.c locks or lock-free atomics — never `synchronized` (virtual thread pinning)
- yaml-plugin-api must remain zero-dependency
- ADR-0011 governs keyword reservation — all new keywords are imperative layer
- JSON Schema Draft 2020-12 for all schema additions
- IntelliJ MCP required for all code navigation and refactoring

---

## Batch 1: yaml-core Primitives

Foundation primitives that everything else depends on. After this batch: OrcNumericPrimitive exists, OrcCounter/OrcAccumulator have listener support, PriorityOrcSemaphore works, and ExecutionScope can look up numeric primitives and priority semaphores.

### Task 1: OrcNumericPrimitive Interface + Listener Support on OrcCounter and OrcAccumulator

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcNumericPrimitive.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcCounter.java:3` — extend OrcNumericPrimitive
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcCounter.java:5-22` — add listener fields and notification
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcAccumulator.java:3` — extend OrcNumericPrimitive
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcAccumulator.java:6-21` — add listener fields and notification
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/OrcNumericPrimitiveTest.java`

**Interfaces:**
- Produces: `OrcNumericPrimitive` interface with `doubleValue()`, `onThresholdChange(DoubleConsumer)`, `removeThresholdListener(DoubleConsumer)` — consumed by Task 2, Task 6
- Produces: `OrcCounter extends OrcNumericPrimitive` — consumed by Task 3
- Produces: `OrcAccumulator extends OrcNumericPrimitive` — consumed by Task 3

- [ ] **Step 1: Write failing tests for OrcNumericPrimitive contract on OrcCounter**

```java
package io.casehub.yaml.core.orchestration;

import org.junit.jupiter.api.Test;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import static org.junit.jupiter.api.Assertions.*;

class OrcNumericPrimitiveTest {

    @Test
    void counterImplementsOrcNumericPrimitive() {
        var counter = new DefaultOrcCounter();
        assertInstanceOf(OrcNumericPrimitive.class, counter);
    }

    @Test
    void counterDoubleValueReturnsSum() {
        var counter = new DefaultOrcCounter();
        counter.add(42);
        assertEquals(42.0, counter.doubleValue());
    }

    @Test
    void counterListenerFiresOnIncrement() throws Exception {
        var counter = new DefaultOrcCounter();
        var future = new CompletableFuture<Double>();
        counter.onThresholdChange(future::complete);
        counter.increment();
        assertEquals(1.0, future.get(1, TimeUnit.SECONDS));
    }

    @Test
    void counterListenerFiresOnAdd() throws Exception {
        var counter = new DefaultOrcCounter();
        var future = new CompletableFuture<Double>();
        counter.onThresholdChange(future::complete);
        counter.add(10);
        assertEquals(10.0, future.get(1, TimeUnit.SECONDS));
    }

    @Test
    void counterRemoveListenerStopsNotification() {
        var counter = new DefaultOrcCounter();
        var called = new java.util.concurrent.atomic.AtomicBoolean(false);
        java.util.function.DoubleConsumer listener = v -> called.set(true);
        counter.onThresholdChange(listener);
        counter.removeThresholdListener(listener);
        counter.increment();
        assertFalse(called.get());
    }

    @Test
    void accumulatorImplementsOrcNumericPrimitive() {
        var acc = new DefaultOrcAccumulator(Double::sum, 0.0);
        assertInstanceOf(OrcNumericPrimitive.class, acc);
    }

    @Test
    void accumulatorDoubleValueReturnsGet() {
        var acc = new DefaultOrcAccumulator(Double::sum, 0.0);
        acc.accumulate(3.14);
        assertEquals(3.14, acc.doubleValue(), 0.001);
    }

    @Test
    void accumulatorListenerFiresOnAccumulate() throws Exception {
        var acc = new DefaultOrcAccumulator(Double::sum, 0.0);
        var future = new CompletableFuture<Double>();
        acc.onThresholdChange(future::complete);
        acc.accumulate(5.0);
        assertEquals(5.0, future.get(1, TimeUnit.SECONDS), 0.001);
    }

    @Test
    void multipleListenersAllFire() throws Exception {
        var counter = new DefaultOrcCounter();
        var f1 = new CompletableFuture<Double>();
        var f2 = new CompletableFuture<Double>();
        counter.onThresholdChange(f1::complete);
        counter.onThresholdChange(f2::complete);
        counter.increment();
        assertEquals(1.0, f1.get(1, TimeUnit.SECONDS));
        assertEquals(1.0, f2.get(1, TimeUnit.SECONDS));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=OrcNumericPrimitiveTest`
Expected: compilation errors — `OrcNumericPrimitive` doesn't exist yet

- [ ] **Step 3: Create OrcNumericPrimitive interface**

Use `ide_create_file` to create:

```java
package io.casehub.yaml.core.orchestration;

import java.util.function.DoubleConsumer;

public interface OrcNumericPrimitive extends OrcPrimitive {
    double doubleValue();
    void onThresholdChange(DoubleConsumer listener);
    void removeThresholdListener(DoubleConsumer listener);
}
```

- [ ] **Step 4: Make OrcCounter extend OrcNumericPrimitive**

Use `ide_replace_member` on `OrcCounter.java`. Change:
```java
public interface OrcCounter extends OrcPrimitive
```
to:
```java
public interface OrcCounter extends OrcNumericPrimitive
```

- [ ] **Step 5: Implement listener support in DefaultOrcCounter**

Use `ide_insert_member` to add field and methods to `DefaultOrcCounter`:

```java
private final java.util.concurrent.CopyOnWriteArrayList<java.util.function.DoubleConsumer> listeners =
        new java.util.concurrent.CopyOnWriteArrayList<>();

@Override
public double doubleValue() {
    return (double) adder.sum();
}

@Override
public void onThresholdChange(java.util.function.DoubleConsumer listener) {
    listeners.add(listener);
}

@Override
public void removeThresholdListener(java.util.function.DoubleConsumer listener) {
    listeners.remove(listener);
}

private void notifyListeners() {
    double val = doubleValue();
    for (var listener : listeners) {
        listener.accept(val);
    }
}
```

Use `ide_replace_member` to update `increment()`, `decrement()`, and `add()` to call `notifyListeners()` after the mutation:

```java
@Override public void increment() { adder.increment(); notifyListeners(); }
@Override public void decrement() { adder.decrement(); notifyListeners(); }
@Override public void add(long delta) { adder.add(delta); notifyListeners(); }
```

- [ ] **Step 6: Make OrcAccumulator extend OrcNumericPrimitive**

Use `ide_replace_member` on `OrcAccumulator.java`. Change:
```java
public interface OrcAccumulator extends OrcPrimitive
```
to:
```java
public interface OrcAccumulator extends OrcNumericPrimitive
```

- [ ] **Step 7: Implement listener support in DefaultOrcAccumulator**

Use `ide_insert_member` to add field and methods to `DefaultOrcAccumulator`:

```java
private final java.util.concurrent.CopyOnWriteArrayList<java.util.function.DoubleConsumer> listeners =
        new java.util.concurrent.CopyOnWriteArrayList<>();

@Override
public double doubleValue() {
    return accumulator.get();
}

@Override
public void onThresholdChange(java.util.function.DoubleConsumer listener) {
    listeners.add(listener);
}

@Override
public void removeThresholdListener(java.util.function.DoubleConsumer listener) {
    listeners.remove(listener);
}

private void notifyListeners() {
    double val = doubleValue();
    for (var listener : listeners) {
        listener.accept(val);
    }
}
```

Use `ide_replace_member` to update `accumulate()` to call `notifyListeners()`:

```java
@Override public void accumulate(double value) { accumulator.accumulate(value); notifyListeners(); }
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=OrcNumericPrimitiveTest`
Expected: all 8 tests PASS

- [ ] **Step 9: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcNumericPrimitive.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcCounter.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcCounter.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcAccumulator.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcAccumulator.java
git add yaml-core/src/test/java/io/casehub/yaml/core/orchestration/OrcNumericPrimitiveTest.java
git commit -m "feat(#562): OrcNumericPrimitive interface + listener support on OrcCounter and OrcAccumulator"
```

### Task 2: Priority Enum + PriorityOrcSemaphore

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/Priority.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/PriorityOrcSemaphore.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultPriorityOrcSemaphore.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/PriorityOrcSemaphoreTest.java`

**Interfaces:**
- Produces: `Priority` enum (BACKGROUND=0, NORMAL=1, HIGH=2) — consumed by Task 3, Task 7
- Produces: `PriorityOrcSemaphore` interface with `acquire(Priority)`, `tryAcquire(Priority, long, TimeUnit)`, `release()`, `availablePermits()` — consumed by Task 3, Task 7

- [ ] **Step 1: Write failing tests**

```java
package io.casehub.yaml.core.orchestration;

import org.junit.jupiter.api.Test;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import static org.junit.jupiter.api.Assertions.*;

class PriorityOrcSemaphoreTest {

    @Test
    void acquireAndRelease() throws InterruptedException {
        var sem = new DefaultPriorityOrcSemaphore(1);
        sem.acquire(Priority.NORMAL);
        assertEquals(0, sem.availablePermits());
        sem.release();
        assertEquals(1, sem.availablePermits());
    }

    @Test
    void higherPriorityAcquiresFirst() throws Exception {
        var sem = new DefaultPriorityOrcSemaphore(1);
        sem.acquire(Priority.NORMAL); // hold the permit

        var order = Collections.synchronizedList(new ArrayList<String>());
        var ready = new CountDownLatch(2);

        Thread bgThread = Thread.ofVirtual().start(() -> {
            try {
                ready.countDown();
                sem.acquire(Priority.BACKGROUND);
                order.add("background");
                sem.release();
            } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        });

        Thread highThread = Thread.ofVirtual().start(() -> {
            try {
                ready.countDown();
                sem.acquire(Priority.HIGH);
                order.add("high");
                sem.release();
            } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        });

        ready.await(1, TimeUnit.SECONDS);
        Thread.sleep(50); // let both threads enqueue
        sem.release(); // release the initial hold

        bgThread.join(2000);
        highThread.join(2000);

        assertEquals(List.of("high", "background"), order);
    }

    @Test
    void tryAcquireRespectsTimeout() throws InterruptedException {
        var sem = new DefaultPriorityOrcSemaphore(1);
        sem.acquire(Priority.NORMAL);
        assertFalse(sem.tryAcquire(Priority.HIGH, 50, TimeUnit.MILLISECONDS));
        sem.release();
    }

    @Test
    void acquireIsInterruptible() throws InterruptedException {
        var sem = new DefaultPriorityOrcSemaphore(1);
        sem.acquire(Priority.NORMAL);

        Thread t = Thread.ofVirtual().start(() -> {
            assertThrows(InterruptedException.class,
                    () -> sem.acquire(Priority.HIGH));
        });

        Thread.sleep(50);
        t.interrupt();
        t.join(1000);
    }

    @Test
    void multiplePermits() throws InterruptedException {
        var sem = new DefaultPriorityOrcSemaphore(3);
        sem.acquire(Priority.NORMAL);
        sem.acquire(Priority.NORMAL);
        sem.acquire(Priority.NORMAL);
        assertEquals(0, sem.availablePermits());
        sem.release();
        assertEquals(1, sem.availablePermits());
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=PriorityOrcSemaphoreTest`
Expected: compilation errors

- [ ] **Step 3: Create Priority enum**

```java
package io.casehub.yaml.core.orchestration;

public enum Priority {
    BACKGROUND(0), NORMAL(1), HIGH(2);

    private final int level;

    Priority(int level) { this.level = level; }

    public int level() { return level; }
}
```

- [ ] **Step 4: Create PriorityOrcSemaphore interface**

```java
package io.casehub.yaml.core.orchestration;

import java.util.concurrent.TimeUnit;

public interface PriorityOrcSemaphore extends OrcPrimitive {
    void acquire(Priority priority) throws InterruptedException;
    boolean tryAcquire(Priority priority, long timeout, TimeUnit unit) throws InterruptedException;
    void release();
    int availablePermits();
}
```

- [ ] **Step 5: Create DefaultPriorityOrcSemaphore**

```java
package io.casehub.yaml.core.orchestration;

import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;
import java.util.PriorityQueue;

public final class DefaultPriorityOrcSemaphore implements PriorityOrcSemaphore {

    private final ReentrantLock lock = new ReentrantLock(true);
    private int permits;
    private final PriorityQueue<Waiter> waiters = new PriorityQueue<>();

    public DefaultPriorityOrcSemaphore(int permits) {
        if (permits < 1) throw new IllegalArgumentException("permits must be >= 1");
        this.permits = permits;
    }

    @Override
    public void acquire(Priority priority) throws InterruptedException {
        lock.lockInterruptibly();
        try {
            if (permits > 0) {
                permits--;
                return;
            }
            var waiter = new Waiter(priority, lock.newCondition());
            waiters.add(waiter);
            while (!waiter.acquired) {
                waiter.condition.await();
            }
        } finally {
            lock.unlock();
        }
    }

    @Override
    public boolean tryAcquire(Priority priority, long timeout, TimeUnit unit)
            throws InterruptedException {
        long deadlineNanos = System.nanoTime() + unit.toNanos(timeout);
        lock.lockInterruptibly();
        try {
            if (permits > 0) {
                permits--;
                return true;
            }
            var waiter = new Waiter(priority, lock.newCondition());
            waiters.add(waiter);
            while (!waiter.acquired) {
                long remaining = deadlineNanos - System.nanoTime();
                if (remaining <= 0) {
                    waiters.remove(waiter);
                    return false;
                }
                waiter.condition.awaitNanos(remaining);
            }
            return true;
        } finally {
            lock.unlock();
        }
    }

    @Override
    public void release() {
        lock.lock();
        try {
            Waiter next = waiters.poll();
            if (next != null) {
                next.acquired = true;
                next.condition.signal();
            } else {
                permits++;
            }
        } finally {
            lock.unlock();
        }
    }

    @Override
    public int availablePermits() {
        lock.lock();
        try {
            return permits;
        } finally {
            lock.unlock();
        }
    }

    @Override
    public void releaseForClose() {
        lock.lock();
        try {
            for (var waiter : waiters) {
                waiter.acquired = true;
                waiter.condition.signal();
            }
            waiters.clear();
        } finally {
            lock.unlock();
        }
    }

    private static final class Waiter implements Comparable<Waiter> {
        final Priority priority;
        final Condition condition;
        volatile boolean acquired;

        Waiter(Priority priority, Condition condition) {
            this.priority = priority;
            this.condition = condition;
        }

        @Override
        public int compareTo(Waiter other) {
            return Integer.compare(other.priority.level(), this.priority.level());
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=PriorityOrcSemaphoreTest`
Expected: all 5 tests PASS

- [ ] **Step 7: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/Priority.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/PriorityOrcSemaphore.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultPriorityOrcSemaphore.java
git add yaml-core/src/test/java/io/casehub/yaml/core/orchestration/PriorityOrcSemaphoreTest.java
git commit -m "feat(#562): Priority enum + PriorityOrcSemaphore with priority-queue acquisition"
```

### Task 3: PrimitiveFactory + ExecutionScope Wiring

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/PrimitiveFactory.java:29-31` — add createPrioritySemaphore
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultPrimitiveFactory.java` — implement createPrioritySemaphore
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ExecutionScope.java:28-30` — add numericPrimitive and prioritySemaphore
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultExecutionScope.java:101-123` — implement new accessors
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/ExecutionScopeNumericTest.java`

**Interfaces:**
- Consumes: `OrcNumericPrimitive` from Task 1, `PriorityOrcSemaphore` + `Priority` from Task 2
- Produces: `PrimitiveFactory.createPrioritySemaphore(String name, int permits)` — consumed by Task 7
- Produces: `ExecutionScope.numericPrimitive(String name)` — consumed by Task 6
- Produces: `ExecutionScope.prioritySemaphore(String name)` — consumed by Task 7

- [ ] **Step 1: Write failing tests**

```java
package io.casehub.yaml.core.orchestration;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ExecutionScopeNumericTest {

    @Test
    void numericPrimitiveReturnsCounter() {
        var scope = new DefaultExecutionScope();
        scope.counter("supply");
        OrcNumericPrimitive np = scope.numericPrimitive("supply");
        assertNotNull(np);
        assertInstanceOf(OrcCounter.class, np);
    }

    @Test
    void numericPrimitiveReturnsAccumulator() {
        var scope = new DefaultExecutionScope();
        scope.accumulator("total", Double::sum, 0.0);
        OrcNumericPrimitive np = scope.numericPrimitive("total");
        assertNotNull(np);
        assertInstanceOf(OrcAccumulator.class, np);
    }

    @Test
    void numericPrimitiveThrowsForNonNumeric() {
        var scope = new DefaultExecutionScope();
        scope.flag("ready");
        assertThrows(IllegalArgumentException.class,
                () -> scope.numericPrimitive("ready"));
    }

    @Test
    void numericPrimitiveThrowsForMissing() {
        var scope = new DefaultExecutionScope();
        assertThrows(IllegalArgumentException.class,
                () -> scope.numericPrimitive("nonexistent"));
    }

    @Test
    void prioritySemaphoreCreatesAndReturns() throws InterruptedException {
        var scope = new DefaultExecutionScope();
        var sem = scope.prioritySemaphore("minerals", 2);
        assertNotNull(sem);
        assertEquals(2, sem.availablePermits());
        sem.acquire(Priority.NORMAL);
        assertEquals(1, sem.availablePermits());
        sem.release();
    }

    @Test
    void prioritySemaphoreReusesExisting() throws InterruptedException {
        var scope = new DefaultExecutionScope();
        var sem1 = scope.prioritySemaphore("minerals", 1);
        var sem2 = scope.prioritySemaphore("minerals", 1);
        assertSame(sem1, sem2);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ExecutionScopeNumericTest`
Expected: compilation errors

- [ ] **Step 3: Add createPrioritySemaphore to PrimitiveFactory**

Use `ide_insert_member` on `PrimitiveFactory.java` after line 31:

```java
PriorityOrcSemaphore createPrioritySemaphore(String name, int permits);
```

- [ ] **Step 4: Implement in DefaultPrimitiveFactory**

Use `ide_insert_member` on `DefaultPrimitiveFactory.java`:

```java
@Override
public PriorityOrcSemaphore createPrioritySemaphore(String name, int permits) {
    return new DefaultPriorityOrcSemaphore(permits);
}
```

- [ ] **Step 5: Add numericPrimitive and prioritySemaphore to ExecutionScope**

Use `ide_insert_member` on `ExecutionScope.java` after line 30:

```java
OrcNumericPrimitive numericPrimitive(String name);

PriorityOrcSemaphore prioritySemaphore(String name, int permits);
```

- [ ] **Step 6: Implement in DefaultExecutionScope**

Use `ide_insert_member` on `DefaultExecutionScope.java`:

```java
@Override
public OrcNumericPrimitive numericPrimitive(String name) {
    Object p = findPrimitive(name);
    if (p == null) {
        throw new IllegalArgumentException("No primitive named '" + name + "'");
    }
    if (p instanceof OrcNumericPrimitive np) {
        return np;
    }
    throw new IllegalArgumentException(
            "Primitive '" + name + "' is not numeric (type: " + p.getClass().getSimpleName() + ")");
}

@Override
public PriorityOrcSemaphore prioritySemaphore(String name, int permits) {
    return getOrCreate(name, PriorityOrcSemaphore.class,
            () -> factory.createPrioritySemaphore(name, permits));
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ExecutionScopeNumericTest`
Expected: all 6 tests PASS

- [ ] **Step 8: Run all yaml-core tests to check for regressions**

Run: `mvn --batch-mode test -pl yaml-core`
Expected: all tests PASS

- [ ] **Step 9: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/PrimitiveFactory.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultPrimitiveFactory.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ExecutionScope.java
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultExecutionScope.java
git add yaml-core/src/test/java/io/casehub/yaml/core/orchestration/ExecutionScopeNumericTest.java
git commit -m "feat(#562): wire PrimitiveFactory + ExecutionScope for numeric primitives and priority semaphores"
```

**Note on OrcGauge:** The spec describes `OrcGauge<T extends Number>` implementing `OrcNumericPrimitive`, but the existing `OrcGauge<T>` is generic with no type bound. Adding the bound would break non-numeric gauges. This batch covers OrcCounter and OrcAccumulator (the primary `at:` use cases: supply counts, cumulative amounts). Numeric gauge support (via a separate `numericGauge()` factory method) is deferred — the `numericPrimitive(name)` lookup will throw a clear error if someone references a non-numeric gauge in `at:`.

## Batch 2: Parse Layer — ResourceDeclaration + on-complete Desugaring

After this batch: `resources:` YAML section parses into typed records, `on-complete:` desugars to signal/wait at parse time.

### Task 4: ResourceDeclaration + YamlModuleFileBuilder

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/ResourceDeclaration.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleFile.java:6-14` — add resources field
- Modify: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlModuleFileBuilder.java:18-44` — add @JsonProperty resources
- Test: `yaml-jackson/src/test/java/io/casehub/yaml/jackson/ResourceDeclarationParseTest.java`

**Interfaces:**
- Produces: `ResourceDeclaration` record with `concurrency` (int) — consumed by Task 7
- Produces: `YamlModuleFile.resources()` accessor — consumed by Task 7

- [ ] **Step 1: Write failing tests**

```java
package io.casehub.yaml.jackson;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import io.casehub.yaml.core.module.YamlModuleFile;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ResourceDeclarationParseTest {

    private final ObjectMapper mapper = new ObjectMapper(new YAMLFactory())
            .registerModule(new YamlCoreJacksonModule());

    @Test
    void parsesResourcesSection() throws Exception {
        String yaml = """
                resources:
                  minerals:
                    concurrency: 1
                  gas:
                    concurrency: 2
                steps:
                  step1:
                    action: test
                """;
        var file = mapper.readValue(yaml, YamlModuleFile.class);
        assertNotNull(file.resources());
        assertEquals(2, file.resources().size());
        assertEquals(1, file.resources().get("minerals").concurrency());
        assertEquals(2, file.resources().get("gas").concurrency());
    }

    @Test
    void emptyResourcesIsEmptyMap() throws Exception {
        String yaml = """
                steps:
                  step1:
                    action: test
                """;
        var file = mapper.readValue(yaml, YamlModuleFile.class);
        assertNotNull(file.resources());
        assertTrue(file.resources().isEmpty());
    }

    @Test
    void resourcesSectionDoesNotAppearInSections() throws Exception {
        String yaml = """
                resources:
                  minerals:
                    concurrency: 1
                steps:
                  step1:
                    action: test
                """;
        var file = mapper.readValue(yaml, YamlModuleFile.class);
        assertFalse(file.sections().containsKey("resources"));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-jackson -Dtest=ResourceDeclarationParseTest`
Expected: compilation errors

- [ ] **Step 3: Create ResourceDeclaration record**

```java
package io.casehub.yaml.core.module;

public record ResourceDeclaration(int concurrency) {
    public ResourceDeclaration {
        if (concurrency < 1) {
            throw new IllegalArgumentException("concurrency must be >= 1, got: " + concurrency);
        }
    }
}
```

- [ ] **Step 4: Add resources field to YamlModuleFile**

Use `ide_replace_member` on `YamlModuleFile.java` to update the record:

```java
public record YamlModuleFile(
        YamlModuleHeader module,
        Map<String, Map<String, Object>> sections,
        List<YamlImport> imports,
        Map<String, ResourceDeclaration> resources) {

    public YamlModuleFile {
        if (sections == null) {sections = Map.of();}
        if (imports == null) {imports = List.of();}
        if (resources == null) {resources = Map.of();}
    }

    public YamlModuleFile(YamlModuleHeader module,
                          Map<String, Map<String, Object>> sections,
                          List<YamlImport> imports) {
        this(module, sections, imports, Map.of());
    }

    public YamlModule toModule() {
        return new YamlModule(module.name(), module.parameters(),
                              module.outputs(), sections);
    }
    // YamlModuleHeader inner record unchanged
}
```

- [ ] **Step 5: Add @JsonProperty resources to YamlModuleFileBuilder**

Use `ide_insert_member` on `YamlModuleFileBuilder.java` to add field and setter:

```java
private Map<String, io.casehub.yaml.core.module.ResourceDeclaration> resources = new java.util.LinkedHashMap<>();

@com.fasterxml.jackson.annotation.JsonProperty("resources")
public YamlModuleFileBuilder resources(Map<String, io.casehub.yaml.core.module.ResourceDeclaration> resources) {
    if (resources != null) { this.resources = resources; }
    return this;
}
```

Use `ide_replace_member` to update the `build()` method:

```java
public YamlModuleFile build() {
    return new YamlModuleFile(module, Map.copyOf(sections),
            List.copyOf(imports), Map.copyOf(resources));
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-jackson -Dtest=ResourceDeclarationParseTest`
Expected: all 3 tests PASS

- [ ] **Step 7: Run all yaml-jackson tests for regressions**

Run: `mvn --batch-mode test -pl yaml-jackson`
Expected: all tests PASS

- [ ] **Step 8: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/module/ResourceDeclaration.java
git add yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleFile.java
git add yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlModuleFileBuilder.java
git add yaml-jackson/src/test/java/io/casehub/yaml/jackson/ResourceDeclarationParseTest.java
git commit -m "feat(#562): ResourceDeclaration record + first-class resources: section parsing"
```

### Task 5: OnCompleteExpander — Parse-Phase Desugaring

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/expand/OnCompleteExpander.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/expand/SourceLocationMap.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/expand/OnCompleteExpanderTest.java`

**Interfaces:**
- Produces: `OnCompleteExpander.expand(List<Map<String, Object>> steps)` returns `ExpandedSteps` (record: `List<Map<String, Object>> steps`, `SourceLocationMap locations`) — consumed by step resolution pipeline
- Produces: `SourceLocationMap.originalName(String generatedName)` returns `Optional<String>` — consumed by error formatters

- [ ] **Step 1: Write failing tests**

```java
package io.casehub.yaml.step.expand;

import org.junit.jupiter.api.Test;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

class OnCompleteExpanderTest {

    @Test
    void simpleOnComplete() {
        var parent = stepMap("build", "GATEWAY",
                "on-complete", List.of(stepMap("train", "STALKER")));

        var result = OnCompleteExpander.expand(List.of(parent));

        assertEquals(2, result.steps().size());
        // Parent gets name and signal
        var expanded = result.steps().get(0);
        assertNotNull(expanded.get("name"));
        assertNotNull(expanded.get("signal"));
        assertNull(expanded.get("on-complete"));
        // Continuation gets wait
        var cont = result.steps().get(1);
        assertEquals(expanded.get("signal"), cont.get("wait"));
    }

    @Test
    void multipleOnCompleteContinuations() {
        var parent = stepMap("build", "GATEWAY",
                "on-complete", List.of(
                        stepMap("train", "STALKER"),
                        stepMap("train", "SENTRY")));

        var result = OnCompleteExpander.expand(List.of(parent));
        assertEquals(3, result.steps().size());
        String signal = (String) result.steps().get(0).get("signal");
        assertEquals(signal, result.steps().get(1).get("wait"));
        assertEquals(signal, result.steps().get(2).get("wait"));
    }

    @Test
    void nestedOnComplete() {
        var inner = stepMap("action", "chrono",
                "on-complete", List.of(stepMap("action", "boost")));
        var parent = stepMap("build", "NEXUS",
                "on-complete", List.of(inner));

        var result = OnCompleteExpander.expand(List.of(parent));
        assertEquals(3, result.steps().size());
    }

    @Test
    void preservesExistingName() {
        var parent = stepMap("build", "GATEWAY");
        parent.put("name", "my-gateway");
        parent.put("on-complete", List.of(stepMap("train", "STALKER")));

        var result = OnCompleteExpander.expand(List.of(parent));
        assertEquals("my-gateway", result.steps().get(0).get("name"));
        assertEquals("my-gateway_done", result.steps().get(1).get("wait"));
    }

    @Test
    void mergesExistingSignal() {
        var parent = stepMap("build", "GATEWAY");
        parent.put("signal", "existing-signal");
        parent.put("on-complete", List.of(stepMap("train", "STALKER")));

        var result = OnCompleteExpander.expand(List.of(parent));
        Object signal = result.steps().get(0).get("signal");
        assertInstanceOf(List.class, signal);
        @SuppressWarnings("unchecked")
        var signals = (List<String>) signal;
        assertTrue(signals.contains("existing-signal"));
        assertEquals(2, signals.size());
    }

    @Test
    void stepsWithoutOnCompletePassThrough() {
        var step = stepMap("action", "test");
        var result = OnCompleteExpander.expand(List.of(step));
        assertEquals(1, result.steps().size());
        assertSame(step, result.steps().get(0));
    }

    @Test
    void sourceLocationMapTracksGeneratedNames() {
        var parent = stepMap("build", "GATEWAY",
                "on-complete", List.of(stepMap("train", "STALKER")));

        var result = OnCompleteExpander.expand(List.of(parent));
        String genName = (String) result.steps().get(0).get("name");
        assertTrue(result.locations().isGenerated(genName));
    }

    private static Map<String, Object> stepMap(String... kvPairs) {
        var map = new LinkedHashMap<String, Object>();
        for (int i = 0; i < kvPairs.length - 1; i += 2) {
            map.put(kvPairs[i], kvPairs[i + 1]);
        }
        return map;
    }

    private static Map<String, Object> stepMap(String k1, Object v1, String k2, Object v2) {
        var map = new LinkedHashMap<String, Object>();
        map.put(k1, v1);
        map.put(k2, v2);
        return map;
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=OnCompleteExpanderTest`
Expected: compilation errors

- [ ] **Step 3: Create SourceLocationMap**

```java
package io.casehub.yaml.step.expand;

import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

public final class SourceLocationMap {
    private final Map<String, String> generatedToOriginal = new ConcurrentHashMap<>();

    void record(String generatedName, String parentContext) {
        generatedToOriginal.put(generatedName, parentContext);
    }

    public boolean isGenerated(String name) {
        return generatedToOriginal.containsKey(name);
    }

    public Optional<String> originalContext(String generatedName) {
        return Optional.ofNullable(generatedToOriginal.get(generatedName));
    }
}
```

- [ ] **Step 4: Create OnCompleteExpander**

```java
package io.casehub.yaml.step.expand;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

public final class OnCompleteExpander {

    private OnCompleteExpander() {}

    public record ExpandedSteps(List<Map<String, Object>> steps, SourceLocationMap locations) {}

    public static ExpandedSteps expand(List<Map<String, Object>> steps) {
        var counter = new AtomicInteger(0);
        var locations = new SourceLocationMap();
        var result = new ArrayList<Map<String, Object>>();
        expandRecursive(steps, result, counter, locations);
        return new ExpandedSteps(result, locations);
    }

    @SuppressWarnings("unchecked")
    private static void expandRecursive(List<Map<String, Object>> steps,
                                         List<Map<String, Object>> output,
                                         AtomicInteger counter,
                                         SourceLocationMap locations) {
        for (var step : steps) {
            Object onComplete = step.get("on-complete");
            if (onComplete == null) {
                output.add(step);
                continue;
            }

            var expanded = new LinkedHashMap<>(step);
            expanded.remove("on-complete");

            int id = counter.incrementAndGet();
            String name;
            if (expanded.containsKey("name")) {
                name = (String) expanded.get("name");
            } else {
                name = "__oc_" + id;
                expanded.put("name", name);
                locations.record(name, "on-complete block #" + id);
            }

            String signalName = name + "_done";
            Object existingSignal = expanded.get("signal");
            if (existingSignal != null) {
                var signals = new ArrayList<String>();
                if (existingSignal instanceof List<?> list) {
                    list.forEach(s -> signals.add((String) s));
                } else {
                    signals.add((String) existingSignal);
                }
                signals.add(signalName);
                expanded.put("signal", signals);
            } else {
                expanded.put("signal", signalName);
            }

            output.add(expanded);

            List<Map<String, Object>> continuations = (List<Map<String, Object>>) onComplete;
            var continuationSteps = new ArrayList<Map<String, Object>>();
            for (var cont : continuations) {
                var contExpanded = new LinkedHashMap<>(cont);
                contExpanded.put("wait", signalName);
                continuationSteps.add(contExpanded);
            }

            expandRecursive(continuationSteps, output, counter, locations);
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=OnCompleteExpanderTest`
Expected: all 7 tests PASS

- [ ] **Step 6: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/expand/OnCompleteExpander.java
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/expand/SourceLocationMap.java
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/expand/OnCompleteExpanderTest.java
git commit -m "feat(#562): OnCompleteExpander — parse-phase desugaring of on-complete: to signal/wait"
```

## Batch 3: Decorators + Schema

After this batch: `at:` decorator blocks/guards on thresholds, `resource:`/`priority:` decorators enable priority-aware contention, StepSchemaComposer emits schemas for all new elements, ADR-0011 updated.

### Task 6: ThresholdCondition Parser + at: Decorator

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/ThresholdCondition.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java:42-59` — add wrapAt between wrapTimeout and wrapWait
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/ThresholdConditionTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/WrapAtDecoratorTest.java`

**Interfaces:**
- Consumes: `OrcNumericPrimitive` from Task 1, `ExecutionScope.numericPrimitive(String)` from Task 3
- Produces: `ThresholdCondition` record with `parse(String)` factory — parser for `[op]<number> <metric>` syntax

- [ ] **Step 1: Write failing tests for ThresholdCondition parser**

```java
package io.casehub.yaml.step.eval;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import static org.junit.jupiter.api.Assertions.*;

class ThresholdConditionTest {

    @ParameterizedTest
    @CsvSource({
            "'14 supply',       '>=', 14.0, 'supply'",
            "'>=14 supply',     '>=', 14.0, 'supply'",
            "'>14 supply',      '>',  14.0, 'supply'",
            "'<22 temperature', '<',  22.0, 'temperature'",
            "'<=80 allocation', '<=', 80.0, 'allocation'",
            "'3.14 pi',         '>=', 3.14, 'pi'"
    })
    void parsesConditionString(String input, String expectedOp,
                                double expectedThreshold, String expectedMetric) {
        var cond = ThresholdCondition.parse(input);
        assertEquals(expectedOp, cond.operator());
        assertEquals(expectedThreshold, cond.threshold(), 0.001);
        assertEquals(expectedMetric, cond.metricName());
    }

    @Test
    void evaluateGreaterOrEqual() {
        var cond = ThresholdCondition.parse(">=14 supply");
        assertTrue(cond.test(14.0));
        assertTrue(cond.test(15.0));
        assertFalse(cond.test(13.9));
    }

    @Test
    void evaluateLessThan() {
        var cond = ThresholdCondition.parse("<22 temperature");
        assertTrue(cond.test(21.0));
        assertFalse(cond.test(22.0));
        assertFalse(cond.test(23.0));
    }

    @Test
    void invalidInputThrows() {
        assertThrows(IllegalArgumentException.class, () -> ThresholdCondition.parse(""));
        assertThrows(IllegalArgumentException.class, () -> ThresholdCondition.parse("nope"));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=ThresholdConditionTest`
Expected: compilation errors

- [ ] **Step 3: Create ThresholdCondition**

```java
package io.casehub.yaml.step.eval;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

public record ThresholdCondition(String operator, double threshold, String metricName) {

    private static final Pattern PATTERN =
            Pattern.compile("^(>=|>|<=|<)?\\s*(\\d+(?:\\.\\d+)?)\\s+(\\w+)$");

    public static ThresholdCondition parse(String input) {
        Matcher m = PATTERN.matcher(input.trim());
        if (!m.matches()) {
            throw new IllegalArgumentException("Invalid threshold condition: '" + input + "'");
        }
        String op = m.group(1) != null ? m.group(1) : ">=";
        double threshold = Double.parseDouble(m.group(2));
        String metric = m.group(3);
        return new ThresholdCondition(op, threshold, metric);
    }

    public boolean test(double value) {
        return switch (operator) {
            case ">=" -> value >= threshold;
            case ">"  -> value > threshold;
            case "<=" -> value <= threshold;
            case "<"  -> value < threshold;
            default -> throw new IllegalStateException("Unknown operator: " + operator);
        };
    }
}
```

- [ ] **Step 4: Run ThresholdCondition tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=ThresholdConditionTest`
Expected: all tests PASS

- [ ] **Step 5: Write failing tests for wrapAt decorator**

```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.core.condition.ConditionEvaluator;
import io.casehub.yaml.core.orchestration.DefaultExecutionScope;
import io.casehub.yaml.core.orchestration.ExecutionScope;
import io.casehub.yaml.core.runtime.SpeedMultiplier;
import io.casehub.yaml.plugin.api.Result;
import org.junit.jupiter.api.Test;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import static org.junit.jupiter.api.Assertions.*;

class WrapAtDecoratorTest {

    @Test
    void blockingWaitUntilThresholdMet() throws Exception {
        var scope = new DefaultExecutionScope();
        var counter = scope.counter("supply");
        var chain = new DecoratorChain(new ConditionEvaluator(), SpeedMultiplier.identity(), scope);
        var executed = new CompletableFuture<Boolean>();

        DecoratedExecution inner = ctx -> {
            executed.complete(true);
            return Result.of(Map.of());
        };

        var decorated = chain.apply(Map.of("at", ">=14 supply"), inner);
        var ctx = StepContext.of(scope);

        Thread.ofVirtual().start(() -> decorated.execute(ctx));
        Thread.sleep(50);
        assertFalse(executed.isDone());

        counter.add(14);
        assertTrue(executed.get(2, TimeUnit.SECONDS));
    }

    @Test
    void guardModeSkipsWhenNotMet() {
        var scope = new DefaultExecutionScope();
        scope.counter("supply"); // value is 0
        var chain = new DecoratorChain(new ConditionEvaluator(), SpeedMultiplier.identity(), scope);

        DecoratedExecution inner = ctx -> Result.of(Map.of("ran", true));

        var decorated = chain.apply(
                Map.of("at", Map.of("metric", "14 supply", "mode", "guard")), inner);

        Result result = decorated.execute(StepContext.of(scope));
        assertTrue(result.output().isEmpty()); // skipped
    }

    @Test
    void guardModeExecutesWhenMet() {
        var scope = new DefaultExecutionScope();
        var counter = scope.counter("supply");
        counter.add(20);
        var chain = new DecoratorChain(new ConditionEvaluator(), SpeedMultiplier.identity(), scope);

        DecoratedExecution inner = ctx -> Result.of(Map.of("ran", true));

        var decorated = chain.apply(
                Map.of("at", Map.of("metric", "14 supply", "mode", "guard")), inner);

        Result result = decorated.execute(StepContext.of(scope));
        assertEquals(true, result.output().get("ran"));
    }

    @Test
    void compoundConditionsAllMustBeMet() throws Exception {
        var scope = new DefaultExecutionScope();
        var supply = scope.counter("supply");
        var minerals = scope.counter("minerals");
        var chain = new DecoratorChain(new ConditionEvaluator(), SpeedMultiplier.identity(), scope);
        var executed = new CompletableFuture<Boolean>();

        DecoratedExecution inner = ctx -> {
            executed.complete(true);
            return Result.of(Map.of());
        };

        var decorated = chain.apply(
                Map.of("at", java.util.List.of(">=14 supply", ">=150 minerals")), inner);

        Thread.ofVirtual().start(() -> decorated.execute(StepContext.of(scope)));

        supply.add(14);
        Thread.sleep(50);
        assertFalse(executed.isDone()); // minerals not met

        minerals.add(150);
        assertTrue(executed.get(2, TimeUnit.SECONDS));
    }
}
```

- [ ] **Step 6: Add wrapAt to DecoratorChain**

In `DecoratorChain.java`, add the new import and method. The `apply()` method (line 42) builds the chain from innermost to outermost. Add `wrapAt` between `wrapTimeout` (line 55) and `wrapWait` (line 54):

Use `ide_insert_member` to add `wrapAt` method and use `ide_replace_member` to update `apply()` to include the `wrapAt` call.

The `wrapAt` method:

```java
@SuppressWarnings("unchecked")
private DecoratedExecution wrapAt(DecoratedExecution inner, Map<String, Object> decorators) {
    Object atVal = decorators.get("at");
    if (atVal == null) return inner;
    if (scope == null) return ctx -> Result.failed("'at:' requires an execution scope");

    List<ThresholdCondition> conditions = new ArrayList<>();
    boolean guardMode = false;

    if (atVal instanceof String s) {
        conditions.add(ThresholdCondition.parse(s));
    } else if (atVal instanceof List<?> list) {
        for (Object item : list) {
            conditions.add(ThresholdCondition.parse((String) item));
        }
    } else if (atVal instanceof Map<?, ?> map) {
        conditions.add(ThresholdCondition.parse((String) map.get("metric")));
        guardMode = "guard".equals(map.get("mode"));
    }

    if (conditions.isEmpty()) return inner;

    boolean isGuard = guardMode;
    return ctx -> {
        if (isGuard) {
            for (var cond : conditions) {
                var prim = scope.numericPrimitive(cond.metricName());
                if (!cond.test(prim.doubleValue())) {
                    return Result.of(Map.of());
                }
            }
            return inner.execute(ctx);
        }

        var future = new java.util.concurrent.CompletableFuture<Void>();
        var listeners = new ArrayList<java.util.function.DoubleConsumer>();

        for (var cond : conditions) {
            var prim = scope.numericPrimitive(cond.metricName());
            java.util.function.DoubleConsumer listener = value -> {
                if (allConditionsMet(conditions)) {
                    future.complete(null);
                }
            };
            listeners.add(listener);
            prim.onThresholdChange(listener);
        }

        if (allConditionsMet(conditions)) {
            future.complete(null);
        }

        try {
            future.get();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return Result.failed("Interrupted while waiting for threshold");
        } catch (java.util.concurrent.ExecutionException e) {
            return Result.failed("Error waiting for threshold: " + e.getCause().getMessage());
        } finally {
            for (int i = 0; i < conditions.size(); i++) {
                scope.numericPrimitive(conditions.get(i).metricName())
                        .removeThresholdListener(listeners.get(i));
            }
        }

        return inner.execute(ctx);
    };
}

private boolean allConditionsMet(List<ThresholdCondition> conditions) {
    for (var cond : conditions) {
        var prim = scope.numericPrimitive(cond.metricName());
        if (!cond.test(prim.doubleValue())) return false;
    }
    return true;
}
```

- [ ] **Step 7: Run tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=WrapAtDecoratorTest`
Expected: all 4 tests PASS (may need to adjust StepContext construction based on actual API)

- [ ] **Step 8: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/ThresholdCondition.java
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/ThresholdConditionTest.java
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/WrapAtDecoratorTest.java
git commit -m "feat(#562): ThresholdCondition parser + at: decorator in DecoratorChain"
```

### Task 7: resource:/priority: Decorator + StepSchemaComposer + ADR-0011

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java:373-414` — extend wrapSemaphore for resource:/priority:
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepSchemaComposer.java:15-19,89-93` — add new DECORATOR_KEYS and typed schemas
- Modify: `docs/adr/0011-three-layer-evaluation-model-keyword-reservation.md` — add new keywords
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/WrapResourceDecoratorTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/StepSchemaComposerExtTest.java`

**Interfaces:**
- Consumes: `PriorityOrcSemaphore` + `Priority` from Task 2, `ExecutionScope.prioritySemaphore(String, int)` from Task 3

- [ ] **Step 1: Write failing tests for resource:/priority: decorator**

```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.core.condition.ConditionEvaluator;
import io.casehub.yaml.core.orchestration.DefaultExecutionScope;
import io.casehub.yaml.core.orchestration.Priority;
import io.casehub.yaml.core.runtime.SpeedMultiplier;
import io.casehub.yaml.plugin.api.Result;
import org.junit.jupiter.api.Test;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import static org.junit.jupiter.api.Assertions.*;

class WrapResourceDecoratorTest {

    @Test
    void resourceAcquiresAndReleases() {
        var scope = new DefaultExecutionScope();
        scope.prioritySemaphore("minerals", 1);
        var chain = new DecoratorChain(new ConditionEvaluator(), SpeedMultiplier.identity(), scope);

        DecoratedExecution inner = ctx -> Result.of(Map.of("ran", true));
        var decorated = chain.apply(Map.of("resource", "minerals"), inner);

        Result result = decorated.execute(StepContext.of(scope));
        assertEquals(true, result.output().get("ran"));
        assertEquals(1, scope.prioritySemaphore("minerals", 1).availablePermits());
    }

    @Test
    void priorityDefaultsToNormal() throws Exception {
        var scope = new DefaultExecutionScope();
        scope.prioritySemaphore("minerals", 1);
        var chain = new DecoratorChain(new ConditionEvaluator(), SpeedMultiplier.identity(), scope);

        var order = Collections.synchronizedList(new ArrayList<String>());
        var sem = scope.prioritySemaphore("minerals", 1);
        sem.acquire(Priority.NORMAL); // hold

        var latch = new CountDownLatch(1);
        Thread t = Thread.ofVirtual().start(() -> {
            var dec = chain.apply(Map.of("resource", "minerals"), ctx -> {
                order.add("step");
                return Result.of(Map.of());
            });
            latch.countDown();
            dec.execute(StepContext.of(scope));
        });

        latch.await(1, TimeUnit.SECONDS);
        Thread.sleep(50);
        sem.release();
        t.join(2000);

        assertEquals(List.of("step"), order);
    }

    @Test
    void highPriorityAcquiresBeforeBackground() throws Exception {
        var scope = new DefaultExecutionScope();
        scope.prioritySemaphore("minerals", 1);
        var chain = new DecoratorChain(new ConditionEvaluator(), SpeedMultiplier.identity(), scope);

        var sem = scope.prioritySemaphore("minerals", 1);
        sem.acquire(Priority.NORMAL); // hold

        var order = Collections.synchronizedList(new ArrayList<String>());
        var ready = new CountDownLatch(2);

        Thread bg = Thread.ofVirtual().start(() -> {
            var dec = chain.apply(
                    Map.of("resource", "minerals", "priority", "background"),
                    ctx -> { order.add("bg"); return Result.of(Map.of()); });
            ready.countDown();
            dec.execute(StepContext.of(scope));
        });

        Thread hi = Thread.ofVirtual().start(() -> {
            var dec = chain.apply(
                    Map.of("resource", "minerals", "priority", "high"),
                    ctx -> { order.add("high"); return Result.of(Map.of()); });
            ready.countDown();
            dec.execute(StepContext.of(scope));
        });

        ready.await(1, TimeUnit.SECONDS);
        Thread.sleep(50); // let both enqueue
        sem.release();

        bg.join(2000);
        hi.join(2000);

        assertEquals(List.of("high", "bg"), order);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=WrapResourceDecoratorTest`
Expected: compilation or test errors

- [ ] **Step 3: Extend wrapSemaphore in DecoratorChain for resource:/priority:**

Use `ide_replace_member` on the `wrapSemaphore` method in `DecoratorChain.java` to add resource/priority handling:

```java
private DecoratedExecution wrapSemaphore(DecoratedExecution inner, Map<String, Object> decorators) {
    // Existing semaphore/mutex handling
    Object semVal = decorators.get("semaphore");
    Object mutexVal = decorators.get("mutex");
    Object resourceVal = decorators.get("resource");

    if (semVal == null && mutexVal == null && resourceVal == null) return inner;
    if (scope == null) return ctx -> Result.failed("semaphore/resource requires an execution scope");

    if (resourceVal != null) {
        String resourceName = (String) resourceVal;
        String priorityStr = (String) decorators.getOrDefault("priority", "normal");
        io.casehub.yaml.core.orchestration.Priority priority =
                io.casehub.yaml.core.orchestration.Priority.valueOf(priorityStr.toUpperCase());
        return ctx -> {
            var sem = scope.prioritySemaphore(resourceName, 1);
            try {
                sem.acquire(priority);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return Result.failed("Interrupted acquiring resource '" + resourceName + "'");
            }
            try {
                return inner.execute(ctx);
            } finally {
                sem.release();
            }
        };
    }

    // Existing semaphore/mutex logic unchanged
    String name;
    int permits;
    if (mutexVal != null) {
        name = (String) mutexVal;
        permits = 1;
    } else if (semVal instanceof Map<?, ?> map) {
        name = (String) map.get("name");
        permits = ((Number) map.get("permits")).intValue();
    } else {
        name = (String) semVal;
        permits = 1;
    }
    return ctx -> {
        OrcSemaphore sem = scope.semaphore(name, permits);
        try {
            sem.acquire();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return Result.failed("Interrupted acquiring semaphore '" + name + "'");
        }
        try {
            return inner.execute(ctx);
        } finally {
            sem.release();
        }
    };
}
```

- [ ] **Step 4: Run resource decorator tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=WrapResourceDecoratorTest`
Expected: all 3 tests PASS

- [ ] **Step 5: Update StepSchemaComposer**

Use `ide_replace_member` to update `DECORATOR_KEYS`:

```java
private static final Set<String> DECORATOR_KEYS = Set.of(
        "if", "on-success", "on-failure", "forEach", "loop",
        "retry", "timeout", "delay", "on-error", "trigger",
        "transform", "signal", "publish", "transition",
        "semaphore", "barrier", "quorum", "race",
        "at", "on-complete", "resource", "priority");
```

Add typed schema generation in the `compose()` method after the shared properties loop (line 91). Use `ide_insert_member` to add after the `for (String key : DECORATOR_KEYS)` loop:

```java
// at: typed schema
ObjectNode atSchema = sharedProps.putObject("at");
ArrayNode atOneOf = atSchema.putArray("oneOf");
ObjectNode atString = atOneOf.addObject();
atString.put("type", "string");
ObjectNode atArray = atOneOf.addObject();
atArray.put("type", "array");
atArray.putObject("items").put("type", "string");
ObjectNode atObject = atOneOf.addObject();
atObject.put("type", "object");
ObjectNode atObjProps = atObject.putObject("properties");
atObjProps.putObject("metric").put("type", "string");
atObjProps.putObject("mode").putArray("enum").add("wait").add("guard");
atObject.putArray("required").add("metric");

// on-complete: recursive step array
ObjectNode onCompleteSchema = sharedProps.putObject("on-complete");
onCompleteSchema.put("type", "array");
onCompleteSchema.putObject("items").put("$ref", "#");

// resource: string
sharedProps.putObject("resource").put("type", "string");

// priority: enum
ObjectNode prioritySchema = sharedProps.putObject("priority");
prioritySchema.putArray("enum").add("background").add("normal").add("high");
```

- [ ] **Step 6: Write and run StepSchemaComposer tests**

```java
package io.casehub.yaml.step.catalog;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import io.casehub.yaml.plugin.api.PluginRegistry;
import io.casehub.yaml.plugin.api.MapServiceRegistry;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class StepSchemaComposerExtTest {

    @Test
    void schemaContainsNewDecoratorKeys() {
        var registry = new io.casehub.yaml.plugin.api.DefaultPluginRegistry();
        var mapper = new ObjectMapper();
        ObjectNode schema = StepSchemaComposer.compose(registry, mapper);
        ObjectNode props = (ObjectNode) schema.get("properties");

        assertTrue(props.has("at"));
        assertTrue(props.has("on-complete"));
        assertTrue(props.has("resource"));
        assertTrue(props.has("priority"));
    }

    @Test
    void atSchemaHasOneOf() {
        var registry = new io.casehub.yaml.plugin.api.DefaultPluginRegistry();
        var mapper = new ObjectMapper();
        ObjectNode schema = StepSchemaComposer.compose(registry, mapper);
        ObjectNode atSchema = (ObjectNode) schema.get("properties").get("at");
        assertTrue(atSchema.has("oneOf"));
        assertEquals(3, atSchema.get("oneOf").size());
    }

    @Test
    void prioritySchemaHasEnum() {
        var registry = new io.casehub.yaml.plugin.api.DefaultPluginRegistry();
        var mapper = new ObjectMapper();
        ObjectNode schema = StepSchemaComposer.compose(registry, mapper);
        ObjectNode prioritySchema = (ObjectNode) schema.get("properties").get("priority");
        assertTrue(prioritySchema.has("enum"));
        assertEquals(3, prioritySchema.get("enum").size());
    }
}
```

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=StepSchemaComposerExtTest`
Expected: all 3 tests PASS

- [ ] **Step 7: Update ADR-0011**

Append to the "Reserved keywords per layer" section:

```markdown
* **`at`** — imperative only. Blocking threshold gate (default) or
  non-blocking guard (mode: guard). Watches numeric orchestration
  primitives (OrcCounter, OrcAccumulator, OrcGauge<Number>). Added by
  #562.
* **`on-complete`** — imperative only. Syntax sugar desugared at parse
  time to `signal:`/`wait:` pairs. Not present in the runtime AST.
  Added by #562.
* **`resource`** — imperative only. Decorator binding a step to a named
  contended resource (PriorityOrcSemaphore). Added by #562.
* **`priority`** — imperative only. Decorator annotation qualifying
  `resource:` with background/normal/high contention priority. Added
  by #562.
```

- [ ] **Step 8: Run all tests across affected modules**

Run: `mvn --batch-mode test -pl yaml-core,yaml-jackson,yaml-step-runtime`
Expected: all tests PASS

- [ ] **Step 9: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepSchemaComposer.java
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/WrapResourceDecoratorTest.java
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/StepSchemaComposerExtTest.java
git add docs/adr/0011-three-layer-evaluation-model-keyword-reservation.md
git commit -m "feat(#562): resource:/priority: decorator, StepSchemaComposer updates, ADR-0011 keyword registration"
```

## References

- [2026-10-09-playbook-language-extensions-design.md](/Users/mdproctor/claude/public/casehub/platform/specs/issue-562-playbook-language-extensions/2026-10-09-playbook-language-extensions-design.md) — design spec this plan implements
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcPrimitive.java:3` — marker interface
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcGauge.java:3-6` — generic gauge interface
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcGauge.java:5-16` — AtomicReference implementation
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcCounter.java:3-8` — counter interface
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcCounter.java:5-22` — LongAdder implementation
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcAccumulator.java:3-6` — accumulator interface
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcAccumulator.java:6-21` — DoubleAccumulator implementation
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcSemaphore.java:5-9` — semaphore interface (signature reference)
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcSemaphore.java:10-103` — semaphore implementation (pattern reference)
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/PrimitiveFactory.java:6-31` — factory interface
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ExecutionScope.java:3-51` — scope interface
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultExecutionScope.java:11-260` — scope implementation (getOrCreate:178, findPrimitive:184, registerPrimitive:220)
- `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleFile.java:6-30` — module file record
- `yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlModuleFileBuilder.java:16-44` — builder with @JsonAnySetter
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java:26-500` — decorator chain (apply:42, wrapTimeout:149, wrapWait:345, wrapSemaphore:373, wrapPostSignal:416)
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepSchemaComposer.java:13-108` — schema composer (DECORATOR_KEYS:15-19, compose:23)
- `docs/adr/0011-three-layer-evaluation-model-keyword-reservation.md` — keyword reservation ADR
- [GitHub #562](https://github.com/casehubio/platform/issues/562) — focal issue
