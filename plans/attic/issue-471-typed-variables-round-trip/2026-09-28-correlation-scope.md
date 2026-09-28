# CorrelationScope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #423 — feat: CorrelationScope consuming-layer utility for request/response lifecycle
**Issue group:** #423

**Goal:** Build a request/response lifecycle utility that wraps OrcChannel with key-based matching, per-correlation timeout, early-arrival buffering, and scope lifecycle integration.

**Architecture:** CorrelationScope<K, V> lives in yaml-core's orchestration package. It takes an OrcChannel<V> and a Function<V, K> key extractor. A dedicated virtual listener thread drains the channel, extracts keys, and routes values to per-key CompletableFutures. Per-correlation timeouts are SpeedMultiplier-aware via ScheduledExecutorService. The forScope() factory integrates with ScenarioScope lifecycle via OrcPrimitive.

**Tech Stack:** Java 21+ (virtual threads), java.util.concurrent (CompletableFuture, ScheduledExecutorService, ConcurrentHashMap), JUnit 5 + AssertJ

## Global Constraints

- yaml-core must remain zero-dependency — no Quarkus, no JPA, no casehubio imports
- All concurrency via j.u.c locks or lock-free atomics — never `synchronized` (virtual thread pinning)
- Pre-release stage — no backward compatibility constraints

---

## Batch 1: Foundation — CorrelationTimeoutException + ScenarioScope interface change

### Task 1: CorrelationTimeoutException + ScenarioScope.speedMultiplier()

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/CorrelationTimeoutException.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ScenarioScope.java:43` (add speedMultiplier method)
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultScenarioScope.java` (add speedMultiplier accessor + registerPrimitive accessor)
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/CorrelationTimeoutExceptionTest.java`

**Interfaces:**
- Consumes: `SpeedMultiplier` (existing in `io.casehub.yaml.core.runtime`)
- Produces: `CorrelationTimeoutException<K>` (used by Task 2 timeout scheduling), `ScenarioScope.speedMultiplier()` (used by Task 3 forScope factory), `DefaultScenarioScope.registerPrimitive(String, Object)` (used by Task 3)

- [ ] **Step 1: Write failing test for CorrelationTimeoutException**

```java
package io.casehub.yaml.core.orchestration;

import org.junit.jupiter.api.Test;
import java.time.Duration;
import java.util.concurrent.TimeoutException;

import static org.assertj.core.api.Assertions.assertThat;

class CorrelationTimeoutExceptionTest {

    @Test
    void extendsTimeoutException() {
        var ex = new CorrelationTimeoutException<>("order-123", Duration.ofSeconds(5));
        assertThat(ex).isInstanceOf(TimeoutException.class);
    }

    @Test
    void carriesKeyAndDuration() {
        var ex = new CorrelationTimeoutException<>("order-123", Duration.ofSeconds(5));
        assertThat(ex.correlationKey()).isEqualTo("order-123");
        assertThat(ex.timeout()).isEqualTo(Duration.ofSeconds(5));
    }

    @Test
    void messageIncludesKeyAndDuration() {
        var ex = new CorrelationTimeoutException<>(42, Duration.ofMillis(500));
        assertThat(ex.getMessage()).contains("42").contains("PT0.5S");
    }

    @Test
    void genericKeyType_preservesType() {
        CorrelationTimeoutException<Integer> ex =
            new CorrelationTimeoutException<>(42, Duration.ofSeconds(1));
        Integer key = ex.correlationKey();
        assertThat(key).isEqualTo(42);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=CorrelationTimeoutExceptionTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — class does not exist

- [ ] **Step 3: Implement CorrelationTimeoutException**

Create `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/CorrelationTimeoutException.java`:

```java
package io.casehub.yaml.core.orchestration;

import java.time.Duration;
import java.util.concurrent.TimeoutException;

public class CorrelationTimeoutException<K> extends TimeoutException {
    private final K correlationKey;
    private final Duration timeout;

    public CorrelationTimeoutException(K correlationKey, Duration timeout) {
        super("Correlation timeout for key '" + correlationKey + "' after " + timeout);
        this.correlationKey = correlationKey;
        this.timeout = timeout;
    }

    public K correlationKey() { return correlationKey; }
    public Duration timeout() { return timeout; }
}
```

- [ ] **Step 4: Add speedMultiplier() to ScenarioScope interface**

Add to `ScenarioScope.java` after `remainingTime()` (line 43):

```java
default SpeedMultiplier speedMultiplier() { return io.casehub.yaml.core.runtime.SpeedMultiplier.identity(); }
```

Default method — no breaking change to existing implementations.

- [ ] **Step 5: Add speedMultiplier() and registerPrimitive() to DefaultScenarioScope**

Add two package-private methods to `DefaultScenarioScope`:

```java
@Override
public SpeedMultiplier speedMultiplier() { return speedMultiplier; }

void registerPrimitive(String name, Object primitive) {
    primitives.put(name, primitive);
}
```

`speedMultiplier()` overrides the interface default to return the actual field.
`registerPrimitive()` is package-private — only visible to CorrelationScope.forScope() in the same package.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=CorrelationTimeoutExceptionTest`
Expected: PASS (4 tests)

Also run existing tests to verify no regressions:
Run: `mvn --batch-mode test -pl yaml-core -Dtest=ScenarioScopeTest`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/CorrelationTimeoutException.java yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ScenarioScope.java yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultScenarioScope.java yaml-core/src/test/java/io/casehub/yaml/core/orchestration/CorrelationTimeoutExceptionTest.java
git commit -m "feat(#423): CorrelationTimeoutException + ScenarioScope.speedMultiplier()

Generic exception extending TimeoutException with key and duration.
ScenarioScope gains speedMultiplier() default method.
DefaultScenarioScope gains registerPrimitive() package-private accessor.

Refs #423

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 2: Core — CorrelationScope with listener, matching, timeout, close

### Task 2: CorrelationScope — expectResponse, awaitResponse, close

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/CorrelationScope.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/CorrelationScopeTest.java`

**Interfaces:**
- Consumes: `OrcChannel<V>` (send/receive), `Function<V, K>` (extractor), `SpeedMultiplier` (timeout scaling), `OrcPrimitive` (lifecycle), `CorrelationTimeoutException<K>` (from Task 1), `ChannelClosedException` (error propagation)
- Produces: `CorrelationScope<K, V>` — full public API: `expectResponse(K, Duration)`, `awaitResponse(K)`, `hasPending(K)`, `pendingCount()`, `oldestPendingAge()`, `close()`, `releaseForClose()`

- [ ] **Step 1: Write failing test — basic request-response flow**

```java
package io.casehub.yaml.core.orchestration;

import org.junit.jupiter.api.Test;
import java.time.Duration;

import static org.assertj.core.api.Assertions.assertThat;

class CorrelationScopeTest {

    @Test
    void expectThenSend_awaitReturnsValue() throws Exception {
        var ch = new DefaultOrcChannel<String>("test");
        var cs = new CorrelationScope<>(ch, v -> v.split(":")[0]);

        cs.expectResponse("order-1", Duration.ofSeconds(5));

        Thread.ofVirtual().start(() -> {
            try { ch.send("order-1:payload"); } catch (InterruptedException e) {}
        });

        String result = cs.awaitResponse("order-1");
        assertThat(result).isEqualTo("order-1:payload");
        assertThat(cs.pendingCount()).isZero();

        cs.close();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=CorrelationScopeTest#expectThenSend_awaitReturnsValue -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — class does not exist

- [ ] **Step 3: Implement CorrelationScope**

Create `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/CorrelationScope.java`:

```java
package io.casehub.yaml.core.orchestration;

import io.casehub.yaml.core.runtime.SpeedMultiplier;

import java.time.Duration;
import java.util.Optional;
import java.util.concurrent.CancellationException;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.function.Function;

public final class CorrelationScope<K, V> implements OrcPrimitive, AutoCloseable {

    private static final long BUFFER_GRACE_NANOS = Duration.ofSeconds(1).toNanos();

    private final OrcChannel<V> channel;
    private final Function<V, K> keyExtractor;
    private final SpeedMultiplier speedMultiplier;
    private final ConcurrentHashMap<K, PendingCorrelation<K, V>> pending = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<K, BufferedValue<V>> earlyArrivals = new ConcurrentHashMap<>();
    private final ScheduledExecutorService scheduler;
    private final Thread listenerThread;
    private volatile boolean closed;

    record PendingCorrelation<K, V>(K key, CompletableFuture<V> future,
                                    long registeredAtNanos, ScheduledFuture<?> timeoutTask) {}

    record BufferedValue<V>(V value, long arrivedAtNanos) {}

    public CorrelationScope(OrcChannel<V> channel, Function<V, K> keyExtractor) {
        this(channel, keyExtractor, SpeedMultiplier.identity());
    }

    public CorrelationScope(OrcChannel<V> channel, Function<V, K> keyExtractor,
                            SpeedMultiplier speedMultiplier) {
        this.channel = channel;
        this.keyExtractor = keyExtractor;
        this.speedMultiplier = speedMultiplier;
        this.scheduler = Executors.newSingleThreadScheduledExecutor(r ->
            Thread.ofVirtual().name("correlation-timeout").unstarted(r));
        this.scheduler.scheduleAtFixedRate(this::evictStaleBuffer,
            BUFFER_GRACE_NANOS, BUFFER_GRACE_NANOS, TimeUnit.NANOSECONDS);
        this.listenerThread = Thread.ofVirtual().name("correlation-listener").start(this::listenerLoop);
    }

    public static <K, V> CorrelationScope<K, V> forScope(
            ScenarioScope scope, String name, Function<V, K> keyExtractor) {
        if (!(scope instanceof DefaultScenarioScope dss)) {
            throw new IllegalArgumentException(
                "forScope() requires DefaultScenarioScope. Use the OrcChannel constructor for custom implementations.");
        }
        OrcChannel<V> channel = scope.channel(name + ".correlation");
        CorrelationScope<K, V> cs = new CorrelationScope<>(channel, keyExtractor, scope.speedMultiplier());
        dss.registerPrimitive(name, cs);
        return cs;
    }

    public void expectResponse(K correlationKey, Duration timeout) {
        if (closed) throw new IllegalStateException("CorrelationScope is closed");

        double speed = Math.max(speedMultiplier.currentSpeed(), 0.001);
        long realTimeoutNanos = (long) (timeout.toNanos() / speed);
        CompletableFuture<V> future = new CompletableFuture<>();
        ScheduledFuture<?> timeoutTask = scheduler.schedule(() -> {
            PendingCorrelation<K, V> removed = pending.remove(correlationKey);
            if (removed != null) {
                removed.future().completeExceptionally(
                    new CorrelationTimeoutException<>(correlationKey, timeout));
            }
        }, realTimeoutNanos, TimeUnit.NANOSECONDS);

        PendingCorrelation<K, V> pc = new PendingCorrelation<>(
            correlationKey, future, System.nanoTime(), timeoutTask);

        PendingCorrelation<K, V> existing = pending.putIfAbsent(correlationKey, pc);
        if (existing != null) {
            timeoutTask.cancel(false);
            throw new IllegalStateException("Correlation key already pending: " + correlationKey);
        }

        if (closed) {
            PendingCorrelation<K, V> removed = pending.remove(correlationKey);
            if (removed != null) {
                timeoutTask.cancel(false);
                future.cancel(true);
            }
            throw new IllegalStateException("CorrelationScope closed during registration");
        }

        BufferedValue<V> buffered = earlyArrivals.remove(correlationKey);
        if (buffered != null) {
            timeoutTask.cancel(false);
            future.complete(buffered.value());
        }
    }

    public V awaitResponse(K correlationKey) throws InterruptedException, TimeoutException {
        PendingCorrelation<K, V> pc = pending.get(correlationKey);
        if (pc == null) {
            throw new IllegalStateException("No pending correlation for key: " + correlationKey);
        }
        try {
            return pc.future().get();
        } catch (CancellationException e) {
            throw new InterruptedException("correlation scope closed");
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof CorrelationTimeoutException<?> te) throw te;
            if (cause instanceof InterruptedException ie) throw ie;
            if (cause instanceof RuntimeException re) throw re;
            throw new RuntimeException(cause);
        } finally {
            pending.remove(correlationKey);
        }
    }

    public boolean hasPending(K correlationKey) {
        PendingCorrelation<K, V> pc = pending.get(correlationKey);
        return pc != null && !pc.future().isDone();
    }

    public int pendingCount() { return pending.size(); }

    public Optional<Duration> oldestPendingAge() {
        long now = System.nanoTime();
        long oldest = Long.MAX_VALUE;
        for (PendingCorrelation<K, V> pc : pending.values()) {
            if (!pc.future().isDone()) {
                oldest = Math.min(oldest, pc.registeredAtNanos());
            }
        }
        if (oldest == Long.MAX_VALUE) return Optional.empty();
        return Optional.of(Duration.ofNanos(now - oldest));
    }

    @Override
    public void releaseForClose() { close(); }

    @Override
    public void close() {
        if (closed) return;
        closed = true;

        for (PendingCorrelation<K, V> pc : pending.values()) {
            pc.future().cancel(true);
            if (pc.timeoutTask() != null) pc.timeoutTask().cancel(false);
        }
        pending.clear();
        earlyArrivals.clear();

        scheduler.shutdownNow();
        if (listenerThread != null) listenerThread.interrupt();
    }

    private void listenerLoop() {
        while (!closed) {
            V value;
            try {
                value = channel.receive();
            } catch (ChannelClosedException e) {
                failAllPending(e.getCause() != null ? e.getCause() : e);
                return;
            } catch (InterruptedException e) {
                return;
            }
            if (value == null) return;

            K key;
            try {
                key = keyExtractor.apply(value);
            } catch (Exception e) {
                continue;
            }
            if (key == null) continue;

            PendingCorrelation<K, V> pc = pending.remove(key);
            if (pc != null) {
                if (pc.timeoutTask() != null) pc.timeoutTask().cancel(false);
                pc.future().complete(value);
            } else {
                earlyArrivals.put(key, new BufferedValue<>(value, System.nanoTime()));
            }
        }
    }

    private void failAllPending(Throwable cause) {
        for (PendingCorrelation<K, V> pc : pending.values()) {
            pc.future().completeExceptionally(cause);
            if (pc.timeoutTask() != null) pc.timeoutTask().cancel(false);
        }
        pending.clear();
    }

    private void evictStaleBuffer() {
        long now = System.nanoTime();
        earlyArrivals.entrySet().removeIf(e ->
            (now - e.getValue().arrivedAtNanos()) > BUFFER_GRACE_NANOS);
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=CorrelationScopeTest#expectThenSend_awaitReturnsValue`
Expected: PASS

- [ ] **Step 5: Write remaining core tests**

Add to `CorrelationScopeTest.java`:

```java
@Test
void multipleKeys_routedCorrectly() throws Exception {
    var ch = new DefaultOrcChannel<String>("test");
    var cs = new CorrelationScope<>(ch, v -> v.split(":")[0]);

    cs.expectResponse("a", Duration.ofSeconds(5));
    cs.expectResponse("b", Duration.ofSeconds(5));

    Thread.ofVirtual().start(() -> {
        try {
            ch.send("b:second");
            ch.send("a:first");
        } catch (InterruptedException e) {}
    });

    assertThat(cs.awaitResponse("a")).isEqualTo("a:first");
    assertThat(cs.awaitResponse("b")).isEqualTo("b:second");
    cs.close();
}

@Test
void duplicateKey_throwsIllegalState() {
    var ch = new DefaultOrcChannel<String>("test");
    var cs = new CorrelationScope<>(ch, v -> v);
    cs.expectResponse("key", Duration.ofSeconds(5));

    assertThatThrownBy(() -> cs.expectResponse("key", Duration.ofSeconds(5)))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageContaining("already pending");

    cs.close();
}

@Test
void timeout_throwsCorrelationTimeoutException() {
    var ch = new DefaultOrcChannel<String>("test");
    var cs = new CorrelationScope<>(ch, v -> v);
    cs.expectResponse("key", Duration.ofMillis(50));

    assertThatThrownBy(() -> cs.awaitResponse("key"))
        .isInstanceOf(CorrelationTimeoutException.class)
        .isInstanceOf(java.util.concurrent.TimeoutException.class);

    cs.close();
}

@Test
void close_cancelsAllPending() throws Exception {
    var ch = new DefaultOrcChannel<String>("test");
    var cs = new CorrelationScope<>(ch, v -> v);
    cs.expectResponse("key", Duration.ofSeconds(30));

    var latch = new java.util.concurrent.CountDownLatch(1);
    var caught = new java.util.concurrent.atomic.AtomicReference<Exception>();
    Thread.ofVirtual().start(() -> {
        try {
            cs.awaitResponse("key");
        } catch (Exception e) {
            caught.set(e);
        }
        latch.countDown();
    });

    Thread.sleep(50);
    cs.close();
    assertThat(latch.await(2, java.util.concurrent.TimeUnit.SECONDS)).isTrue();
    assertThat(caught.get()).isInstanceOf(InterruptedException.class);
}

@Test
void pendingCount_tracksRegistrations() {
    var ch = new DefaultOrcChannel<String>("test");
    var cs = new CorrelationScope<>(ch, v -> v);

    assertThat(cs.pendingCount()).isZero();
    cs.expectResponse("a", Duration.ofSeconds(5));
    assertThat(cs.pendingCount()).isEqualTo(1);
    cs.expectResponse("b", Duration.ofSeconds(5));
    assertThat(cs.pendingCount()).isEqualTo(2);

    cs.close();
}

@Test
void oldestPendingAge_returnsEmpty_whenNoPending() {
    var ch = new DefaultOrcChannel<String>("test");
    var cs = new CorrelationScope<>(ch, v -> v);
    assertThat(cs.oldestPendingAge()).isEmpty();
    cs.close();
}

@Test
void oldestPendingAge_returnsDuration_whenPending() throws Exception {
    var ch = new DefaultOrcChannel<String>("test");
    var cs = new CorrelationScope<>(ch, v -> v);
    cs.expectResponse("key", Duration.ofSeconds(30));
    Thread.sleep(20);
    assertThat(cs.oldestPendingAge()).isPresent();
    assertThat(cs.oldestPendingAge().get().toMillis()).isGreaterThanOrEqualTo(15);
    cs.close();
}

@Test
void hasPending_tracksState() throws Exception {
    var ch = new DefaultOrcChannel<String>("test");
    var cs = new CorrelationScope<>(ch, v -> v);

    assertThat(cs.hasPending("key")).isFalse();
    cs.expectResponse("key", Duration.ofSeconds(5));
    assertThat(cs.hasPending("key")).isTrue();

    ch.send("key");
    cs.awaitResponse("key");
    assertThat(cs.hasPending("key")).isFalse();

    cs.close();
}

@Test
void close_idempotent() {
    var ch = new DefaultOrcChannel<String>("test");
    var cs = new CorrelationScope<>(ch, v -> v);
    cs.close();
    cs.close(); // no exception
}

@Test
void expectResponse_closedScope_throwsIllegalState() {
    var ch = new DefaultOrcChannel<String>("test");
    var cs = new CorrelationScope<>(ch, v -> v);
    cs.close();

    assertThatThrownBy(() -> cs.expectResponse("key", Duration.ofSeconds(1)))
        .isInstanceOf(IllegalStateException.class);
}
```

- [ ] **Step 6: Run all tests**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=CorrelationScopeTest`
Expected: PASS (all tests)

- [ ] **Step 7: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/CorrelationScope.java yaml-core/src/test/java/io/casehub/yaml/core/orchestration/CorrelationScopeTest.java
git commit -m "feat(#423): CorrelationScope — core request/response lifecycle

Listener thread, key-based matching, per-correlation timeout,
early-arrival buffer, OrcPrimitive lifecycle, observability.

Refs #423

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 3: Edge cases — error propagation, extractor safety, SpeedMultiplier, forScope()

### Task 3: Error propagation, extractor safety, SpeedMultiplier, forScope() integration

**Files:**
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/CorrelationScopeTest.java` (add edge case tests)

**Interfaces:**
- Consumes: `CorrelationScope<K, V>` (from Task 2), `DefaultScenarioScope` (registerPrimitive from Task 1)
- Produces: validated edge-case coverage — no new public API

- [ ] **Step 1: Write error propagation + extractor safety tests**

Add to `CorrelationScopeTest.java`:

```java
@Test
void channelErrorClose_failsAllPendingWithCause() throws Exception {
    var ch = new DefaultOrcChannel<String>("test");
    var cs = new CorrelationScope<>(ch, v -> v);
    cs.expectResponse("key", Duration.ofSeconds(30));

    var latch = new java.util.concurrent.CountDownLatch(1);
    var caught = new java.util.concurrent.atomic.AtomicReference<Exception>();
    Thread.ofVirtual().start(() -> {
        try {
            cs.awaitResponse("key");
        } catch (Exception e) {
            caught.set(e);
        }
        latch.countDown();
    });

    Thread.sleep(50);
    ch.close(new RuntimeException("upstream failure"));
    assertThat(latch.await(2, java.util.concurrent.TimeUnit.SECONDS)).isTrue();
    assertThat(caught.get()).isInstanceOf(RuntimeException.class)
        .hasMessage("upstream failure");

    cs.close();
}

@Test
void extractorThrows_messageDropped_listenerContinues() throws Exception {
    var callCount = new java.util.concurrent.atomic.AtomicInteger(0);
    var ch = new DefaultOrcChannel<String>("test");
    var cs = new CorrelationScope<>(ch, v -> {
        int c = callCount.incrementAndGet();
        if (c == 1) throw new RuntimeException("bad message");
        return v.split(":")[0];
    });

    cs.expectResponse("good", Duration.ofSeconds(5));
    ch.send("bad-message");
    ch.send("good:payload");

    assertThat(cs.awaitResponse("good")).isEqualTo("good:payload");
    cs.close();
}

@Test
void extractorReturnsNull_messageDropped_listenerContinues() throws Exception {
    var ch = new DefaultOrcChannel<String>("test");
    var cs = new CorrelationScope<>(ch, v -> v.startsWith("null") ? null : v);

    cs.expectResponse("valid", Duration.ofSeconds(5));
    ch.send("null-value");
    ch.send("valid");

    assertThat(cs.awaitResponse("valid")).isEqualTo("valid");
    cs.close();
}

@Test
void speedMultiplier_affectsTimeout() {
    var ch = new DefaultOrcChannel<String>("test");
    SpeedMultiplier fast = () -> 10.0;
    var cs = new CorrelationScope<>(ch, v -> v, fast);

    long start = System.nanoTime();
    cs.expectResponse("key", Duration.ofSeconds(1));

    assertThatThrownBy(() -> cs.awaitResponse("key"))
        .isInstanceOf(CorrelationTimeoutException.class);

    long elapsed = System.nanoTime() - start;
    assertThat(Duration.ofNanos(elapsed).toMillis()).isLessThan(500);

    cs.close();
}

@Test
void earlyArrival_completesImmediately() throws Exception {
    var ch = new DefaultOrcChannel<String>("test");
    var cs = new CorrelationScope<>(ch, v -> v.split(":")[0]);

    ch.send("key:early-payload");
    Thread.sleep(50);

    cs.expectResponse("key", Duration.ofSeconds(5));
    String result = cs.awaitResponse("key");
    assertThat(result).isEqualTo("key:early-payload");

    cs.close();
}

@Test
void forScope_registersAsPrimitive() throws Exception {
    var scope = new DefaultScenarioScope();
    var cs = CorrelationScope.<String, String>forScope(scope, "test-corr", v -> v);

    assertThat(scope.primitive("test-corr", CorrelationScope.class)).isSameAs(cs);

    cs.close();
    scope.close();
}

@Test
void forScope_scopeClose_cascadesToCorrelationScope() throws Exception {
    var scope = new DefaultScenarioScope();
    var cs = CorrelationScope.<String, String>forScope(scope, "test-corr", v -> v);

    cs.expectResponse("key", Duration.ofSeconds(30));

    var latch = new java.util.concurrent.CountDownLatch(1);
    var caught = new java.util.concurrent.atomic.AtomicReference<Exception>();
    Thread.ofVirtual().start(() -> {
        try {
            cs.awaitResponse("key");
        } catch (Exception e) {
            caught.set(e);
        }
        latch.countDown();
    });

    Thread.sleep(50);
    scope.close();
    assertThat(latch.await(2, java.util.concurrent.TimeUnit.SECONDS)).isTrue();
    assertThat(caught.get()).isInstanceOf(InterruptedException.class);
}
```

- [ ] **Step 2: Run all tests**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=CorrelationScopeTest`
Expected: PASS (all tests including new edge cases)

- [ ] **Step 3: Run full yaml-core test suite**

Run: `mvn --batch-mode test -pl yaml-core`
Expected: PASS — no regressions from ScenarioScope interface change

- [ ] **Step 4: Commit**

```bash
git add yaml-core/src/test/java/io/casehub/yaml/core/orchestration/CorrelationScopeTest.java
git commit -m "test(#423): edge cases — error propagation, extractor safety, SpeedMultiplier, forScope

ChannelClosedException error-close, null/throwing extractors,
10x speed timeout, early-arrival buffer, scope lifecycle cascade.

Refs #423

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 5: Run full project build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — CorrelationScope compiles in all downstream modules

---

## References

- [2026-09-28-correlation-scope-design.md] — design spec this plan implements
- [yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcChannel.java] — channel interface
- [yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcChannel.java] — channel impl, close/error semantics
- [yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ScenarioScope.java] — scope interface
- [yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultScenarioScope.java:145-175] — close cascade, primitive map
- [yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcPrimitive.java] — lifecycle interface
- [yaml-core/src/main/java/io/casehub/yaml/core/runtime/SpeedMultiplier.java] — speed SPI
- [yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ChannelClosedException.java] — error-close exception
- [GitHub #423] — focal issue
- [GitHub #410] — parent issue (D1 correlation trade-off)
