# CorrelationScope — Request/Response Lifecycle Utility

**Issue:** casehubio/platform#423
**Branch:** issue-423-correlation-scope
**Date:** 2026-09-28
**Depends on:** #410 (D1 correlation trade-off — landed), #386 (runtime orchestration primitives — landed)

## Context

Platform #410 D1 resolved correlation at the primitive layer as composition over trigger+filter — no new OrcCorrelation primitive. The lifecycle concern — timeout on missing response, cleanup of stale correlations, observability of pending correlations — was deferred to a consuming-layer utility. This spec defines that utility.

**Scope:**
- `CorrelationScope<K, V>` — request/response lifecycle over OrcChannel
- Per-correlation timeout with SpeedMultiplier awareness
- Key-based matching via caller-supplied extractor
- Early-arrival buffer for ordering race elimination
- OrcPrimitive lifecycle integration
- Observability (pending count, oldest pending age)

**Not in scope:**
- Scatter-gather / 1:N cardinality — QuorumTracker + channel composition handles this
- `correlate:` YAML shorthand — parse-time concern for scenario format spec (#409)
- Step-level integration (decorator wiring) — separate consuming-layer concern

---

## Part 1: CorrelationScope Class

### Package and Module

`io.casehub.yaml.core.orchestration.CorrelationScope<K, V>` in the `yaml-core` module.

CorrelationScope's dependencies are exclusively yaml-core types (OrcChannel) and JDK (ConcurrentHashMap, CompletableFuture, ScheduledExecutorService, Function). Zero external deps — same profile as DefaultScenarioScope.

### Public API

```java
package io.casehub.yaml.core.orchestration;

import java.time.Duration;
import java.util.Optional;
import java.util.concurrent.TimeoutException;
import java.util.function.Function;

public final class CorrelationScope<K, V> implements OrcPrimitive, AutoCloseable {

    public CorrelationScope(OrcChannel<V> channel, Function<V, K> keyExtractor) { ... }

    public CorrelationScope(OrcChannel<V> channel, Function<V, K> keyExtractor,
                            SpeedMultiplier speedMultiplier) { ... }

    public static <K, V> CorrelationScope<K, V> forScope(
            ScenarioScope scope, String name, Function<V, K> keyExtractor) { ... }

    public void expectResponse(K correlationKey, Duration timeout);

    public V awaitResponse(K correlationKey) throws InterruptedException, TimeoutException;

    public boolean hasPending(K correlationKey);

    public int pendingCount();

    public Optional<Duration> oldestPendingAge();

    @Override
    public void releaseForClose();

    @Override
    public void close();
}
```

### Constructor

The two-arg constructor uses `SpeedMultiplier.identity()` (no time scaling). The three-arg constructor takes an explicit SpeedMultiplier for simulation-aware timeouts.

On construction:
1. Store channel, extractor, speedMultiplier
2. Create a single-thread ScheduledExecutorService (virtual thread)
3. Spawn the listener thread (virtual) to drain the channel

### forScope() Factory

```java
public static <K, V> CorrelationScope<K, V> forScope(
        ScenarioScope scope, String name, Function<V, K> keyExtractor) {
    OrcChannel<V> channel = scope.channel(name + ".correlation");
    CorrelationScope<K, V> cs = new CorrelationScope<>(channel, keyExtractor, /* scope's speedMultiplier */);
    // Register as primitive for lifecycle cascade
    // scope.primitive() lookup with the name will find it
    return cs;
}
```

The factory creates a named channel, constructs CorrelationScope with the scope's SpeedMultiplier, and registers the CorrelationScope in the scope's primitive map. When `ScenarioScope.close()` cascades, it calls `CorrelationScope.releaseForClose()` automatically.

**SpeedMultiplier access:** `forScope()` needs the SpeedMultiplier from the scope. DefaultScenarioScope stores it as a field. The factory can access it via a package-private method or by passing it as a parameter. Since CorrelationScope is in the same package (`io.casehub.yaml.core.orchestration`), package-private access is available.

**Primitive registration:** DefaultScenarioScope stores primitives in a `ConcurrentHashMap<String, Object>`. The `forScope()` factory must register the CorrelationScope in this map (via a package-private registration method or by making CorrelationScope's constructor accept a registration callback). The key is the provided `name`.

---

## Part 2: Internal Architecture

### PendingCorrelation Record

```java
record PendingCorrelation<K, V>(
    K key,
    CompletableFuture<V> future,
    long registeredAtNanos,
    java.util.concurrent.ScheduledFuture<?> timeoutTask
) {}
```

### Registry

```java
private final ConcurrentHashMap<K, PendingCorrelation<K, V>> pending = new ConcurrentHashMap<>();
```

### Early-Arrival Buffer

```java
private final ConcurrentHashMap<K, BufferedValue<V>> earlyArrivals = new ConcurrentHashMap<>();

record BufferedValue<V>(V value, long arrivedAtNanos) {}
```

### Listener Thread

A single virtual thread drains the internal OrcChannel in a loop:

```java
private void listenerLoop() {
    while (!closed) {
        V value;
        try {
            value = channel.receive();
        } catch (InterruptedException e) {
            return; // scope closing
        }
        if (value == null) {
            // Channel closed — propagate error or exit
            if (channel.isErrorClosed()) {
                failAllPending(channel.closeError());
            }
            return;
        }

        K key;
        try {
            key = keyExtractor.apply(value);
        } catch (Exception e) {
            // Log at DEBUG, skip message, continue
            continue;
        }

        PendingCorrelation<K, V> pc = pending.remove(key);
        if (pc != null) {
            pc.timeoutTask().cancel(false);
            pc.future().complete(value);
        } else {
            // Buffer for late registration
            earlyArrivals.put(key, new BufferedValue<>(value, System.nanoTime()));
        }
    }
}
```

**Key behaviors:**
- Extractor failure: caught, logged at DEBUG, message discarded, listener continues (D6 safety)
- Channel normal close: `receive()` returns null, listener exits
- Channel error close: `receive()` throws `ChannelClosedException` with cause, all pending correlations failed with the cause (D10)
- Matched value: removes PendingCorrelation, cancels timeout task, completes future
- Unmatched value: buffered in early-arrival map with timestamp (D8)

### expectResponse()

```java
public void expectResponse(K correlationKey, Duration timeout) {
    if (closed) throw new IllegalStateException("CorrelationScope is closed");

    // D11: fail-fast on duplicate key
    CompletableFuture<V> future = new CompletableFuture<>();
    PendingCorrelation<K, V> pc = new PendingCorrelation<>(
        correlationKey, future, System.nanoTime(), null);

    PendingCorrelation<K, V> existing = pending.putIfAbsent(correlationKey, pc);
    if (existing != null) {
        throw new IllegalStateException(
            "Correlation key already pending: " + correlationKey);
    }

    // D8: check early-arrival buffer first
    BufferedValue<V> buffered = earlyArrivals.remove(correlationKey);
    if (buffered != null) {
        pending.remove(correlationKey);
        future.complete(buffered.value());
        return;
    }

    // Schedule timeout (SpeedMultiplier-aware)
    double speed = Math.max(speedMultiplier.currentSpeed(), 0.001);
    long realTimeoutNanos = (long) (timeout.toNanos() / speed);
    ScheduledFuture<?> timeoutTask = scheduler.schedule(() -> {
        PendingCorrelation<K, V> removed = pending.remove(correlationKey);
        if (removed != null) {
            removed.future().completeExceptionally(
                new CorrelationTimeoutException(correlationKey, timeout));
        }
    }, realTimeoutNanos, TimeUnit.NANOSECONDS);

    // Update PendingCorrelation with the timeout task
    // (CAS to handle race with listener completing between putIfAbsent and here)
    pending.computeIfPresent(correlationKey, (k, v) ->
        new PendingCorrelation<>(k, v.future(), v.registeredAtNanos(), timeoutTask));
}
```

**SpeedMultiplier note:** The timeout is computed once at registration time using `currentSpeed()`. This is a snapshot — if speed changes after registration, the timeout is not adjusted. This is the same trade-off as DefaultScenarioScope's deadline watcher, where each sleep iteration re-reads speed. For correlation timeouts (typically seconds, not minutes), a single-read snapshot is sufficient. If finer-grained speed tracking is needed, the timeout task can use adaptive rescheduling (future enhancement, not in this spec).

### awaitResponse()

```java
public V awaitResponse(K correlationKey) throws InterruptedException, TimeoutException {
    PendingCorrelation<K, V> pc = pending.get(correlationKey);
    if (pc == null) {
        throw new IllegalStateException(
            "No pending correlation for key: " + correlationKey);
    }
    try {
        return pc.future().get();
    } catch (CancellationException e) {
        // Scope closed — translate to InterruptedException
        throw new InterruptedException("correlation scope closed");
    } catch (java.util.concurrent.ExecutionException e) {
        Throwable cause = e.getCause();
        if (cause instanceof CorrelationTimeoutException te) throw te;
        if (cause instanceof InterruptedException ie) throw ie;
        if (cause instanceof RuntimeException re) throw re;
        throw new RuntimeException(cause);
    }
}
```

**Exception translation:**
- Timeout: `CorrelationTimeoutException` (extends TimeoutException) — per-correlation deadline expired
- Scope close: `CancellationException` → `InterruptedException` — consistent with other primitives
- Channel error: upstream cause propagated directly (D10)
- Normal completion: value returned

### close() / releaseForClose()

```java
@Override
public void releaseForClose() {
    close();
}

@Override
public void close() {
    if (closed) return;
    closed = true;

    // 1. Cancel all pending futures (awaiters get CancellationException → InterruptedException)
    for (PendingCorrelation<K, V> pc : pending.values()) {
        pc.future().cancel(true);
        if (pc.timeoutTask() != null) pc.timeoutTask().cancel(false);
    }
    pending.clear();
    earlyArrivals.clear();

    // 2. Shutdown scheduler (no new timeout tasks)
    scheduler.shutdownNow();

    // 3. Listener thread exits when channel.receive() is interrupted or returns null
    if (listenerThread != null) listenerThread.interrupt();
}
```

Order: cancel futures → clear maps → shutdown scheduler → interrupt listener. This ensures awaiters are unblocked before resources are cleaned up.

---

## Part 3: CorrelationTimeoutException

```java
package io.casehub.yaml.core.orchestration;

import java.time.Duration;
import java.util.concurrent.TimeoutException;

public class CorrelationTimeoutException extends TimeoutException {
    private final Object correlationKey;
    private final Duration timeout;

    public CorrelationTimeoutException(Object correlationKey, Duration timeout) {
        super("Correlation timeout for key '" + correlationKey + "' after " + timeout);
        this.correlationKey = correlationKey;
        this.timeout = timeout;
    }

    public Object correlationKey() { return correlationKey; }
    public Duration timeout() { return timeout; }
}
```

The key is stored as `Object` (not `K`) because TimeoutException is not generic. Callers who know the key type can cast. The key's `toString()` appears in the exception message for diagnostics.

---

## Part 4: Early-Arrival Buffer Eviction

The ScheduledExecutorService runs a periodic eviction task:

```java
private static final long BUFFER_GRACE_NANOS = Duration.ofSeconds(1).toNanos();

// Scheduled at construction, runs every 1s
scheduler.scheduleAtFixedRate(() -> {
    long now = System.nanoTime();
    earlyArrivals.entrySet().removeIf(e ->
        (now - e.getValue().arrivedAtNanos()) > BUFFER_GRACE_NANOS);
}, BUFFER_GRACE_NANOS, BUFFER_GRACE_NANOS, TimeUnit.NANOSECONDS);
```

Entries older than 1 second are evicted. The grace period is fixed (not SpeedMultiplier-adjusted) because it covers real-time scheduling jitter, not scenario time.

---

## Part 5: Observability

```java
public int pendingCount() {
    return pending.size();
}

public Optional<Duration> oldestPendingAge() {
    long now = System.nanoTime();
    long oldest = Long.MAX_VALUE;
    for (PendingCorrelation<K, V> pc : pending.values()) {
        oldest = Math.min(oldest, pc.registeredAtNanos());
    }
    if (oldest == Long.MAX_VALUE) return Optional.empty();
    return Optional.of(Duration.ofNanos(now - oldest));
}
```

Both methods are lock-free reads of ConcurrentHashMap. `oldestPendingAge()` is O(n) over pending correlations — acceptable for typical counts (<100).

---

## Part 6: forScope() Registration

DefaultScenarioScope stores primitives in `ConcurrentHashMap<String, Object> primitives`. The `forScope()` factory needs to register CorrelationScope in this map. Since CorrelationScope is in the same package (`io.casehub.yaml.core.orchestration`), it can access package-private methods on DefaultScenarioScope.

**Required change to DefaultScenarioScope:**

Add a package-private registration method:

```java
void registerPrimitive(String name, Object primitive) {
    primitives.put(name, primitive);
}
```

This allows `forScope()` to register the CorrelationScope:

```java
public static <K, V> CorrelationScope<K, V> forScope(
        ScenarioScope scope, String name, Function<V, K> keyExtractor) {
    OrcChannel<V> channel = scope.channel(name + ".correlation");
    SpeedMultiplier speed = ((DefaultScenarioScope) scope).speedMultiplier();
    CorrelationScope<K, V> cs = new CorrelationScope<>(channel, keyExtractor, speed);
    ((DefaultScenarioScope) scope).registerPrimitive(name, cs);
    return cs;
}
```

**Trade-off:** The cast to `DefaultScenarioScope` couples `forScope()` to the concrete implementation. This is acceptable — `forScope()` is a convenience factory, not a contract. Users who implement custom ScenarioScope implementations use the OrcChannel constructor directly. If a non-DefaultScenarioScope is passed, `forScope()` throws `IllegalArgumentException` with a message directing to the OrcChannel constructor.

---

## Module Impact

| Module | Changes |
|--------|---------|
| yaml-core | CorrelationScope, CorrelationTimeoutException (new classes). DefaultScenarioScope: `registerPrimitive()` + `speedMultiplier()` package-private accessors |

---

## Test Cases

```
# Construction and basic lifecycle
correlationScope_constructor_startsListenerThread
correlationScope_close_stopsListenerThread
correlationScope_close_idempotent
correlationScope_forScope_registersAsPrimitive
correlationScope_forScope_scopeCloseCallsReleaseForClose

# Core request-response flow
expectResponse_thenSend_awaitReturnsValue
expectResponse_awaitBeforeSend_blocksUntilArrival
expectResponse_multipleKeys_routedCorrectly
expectResponse_duplicateKey_throwsIllegalState

# Timeout
expectResponse_timeout_throwsCorrelationTimeoutException
expectResponse_timeout_autoCleansPendingCorrelation
correlationTimeoutException_extendsTimeoutException
correlationTimeoutException_carriesKeyAndDuration

# SpeedMultiplier
expectResponse_timeout_respectsSpeedMultiplier
expectResponse_timeout_speedIdentity_usesRealTime

# Early-arrival buffer
expectResponse_responseArrivedEarly_completesImmediately
earlyArrival_evictedAfterGracePeriod
earlyArrival_claimedBeforeEviction_notEvicted

# Lifecycle cascade
scopeClose_cancelsAllPending_awaitersGetInterruptedException
releaseForClose_sameAsClose
close_schedulerShutdown_noLeakedThreads

# Error propagation
channelErrorClose_failsAllPendingWithCause
channelNormalClose_listenerExits

# Key extractor safety
extractor_throws_messageDropped_listenerContinues
extractor_returnsNull_messageDropped_listenerContinues

# Observability
pendingCount_empty_returnsZero
pendingCount_afterExpect_returnsOne
pendingCount_afterMatch_returnsZero
oldestPendingAge_noPending_returnsEmpty
oldestPendingAge_withPending_returnsDuration
oldestPendingAge_multipleKeys_returnsOldest

# Thread safety
concurrent_expectAndSend_noRace
concurrent_multipleExpects_differentKeys_independent
```

---

## Implementation Order

1. **CorrelationTimeoutException** — trivial, no dependencies
2. **DefaultScenarioScope accessors** — `registerPrimitive()` + `speedMultiplier()` package-private methods
3. **CorrelationScope** — PendingCorrelation, BufferedValue, listener thread, expectResponse, awaitResponse, close
4. **forScope() factory** — integrates with scope lifecycle
5. **Tests** — ordered by the test case groups above

Parallelism: (1, 2) → 3 → 4 → 5

---

## References

- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcChannel.java` — channel interface composed by CorrelationScope
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcChannel.java` — channel impl, close/error semantics
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ScenarioScope.java` — scope interface, channel factory
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultScenarioScope.java` — scope impl, primitive map, SpeedMultiplier
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcPrimitive.java` — lifecycle interface
- `yaml-core/src/main/java/io/casehub/yaml/core/runtime/SpeedMultiplier.java` — speed SPI for simulation-aware timeouts
- `docs/specs/issue-410-orc-correlate-deadline-cond/2026-09-23-orc-correlate-deadline-cond-design.md` — parent spec, D1 correlation trade-off
- `docs/specs/issue-410-orc-correlate-deadline-cond/decisions.md` — D1 decision (composition over primitive)
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/QuorumTracker.java` — M-of-N completion for scatter-gather composition
