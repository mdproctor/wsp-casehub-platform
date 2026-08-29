# Session Leak Reaper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #242 — Session leak detection for GatedAgentSession (scheduled reaper)
**Issue group:** #242

**Goal:** Add leak detection infrastructure to agent-gate: a session registry, a @Scheduled reaper that warns about sessions held beyond a configurable threshold, and optional force-close with idempotent close guard.

**Architecture:** `SessionRegistry` (@ApplicationScoped) tracks open sessions with monotonic IDs and creation timestamps. `SessionLeakReaper` (@ApplicationScoped, @Scheduled) scans the registry and logs warnings. `GatedAgentSession` gains an `AtomicBoolean` close guard for idempotent close, preventing double semaphore release when the reaper and caller race. Config is nested inside existing `AgentGateProperties`.

**Tech Stack:** Java 21, Quarkus CDI (quarkus-arc), Quarkus Scheduler (quarkus-scheduler), JUnit 5, AssertJ, Awaitility

## Global Constraints

- agent-gate is a library module — no `quarkus:build` goal
- All new classes live in `io.casehub.platform.agent.gate` (package-private where possible)
- Config under existing prefix `casehub.platform.agent.gate.reaper.*`
- No changes to `AgentSession` SPI in platform-api
- No changes to `AdmissionStrategy`, `AdmissionGate`, `ConcurrencyStrategy`, `TokenBucketStrategy`, `SlidingWindowStrategy`

---

## Batch 1: Session Registry + Idempotent Close

### Task 1: SessionRegistry — session tracking bean

**Files:**
- Create: `agent-gate/src/test/java/io/casehub/platform/agent/gate/SessionRegistryTest.java`
- Create: `agent-gate/src/main/java/io/casehub/platform/agent/gate/SessionRegistry.java`

**Interfaces:**
- Consumes: `GatedAgentSession` (existing class, used as map key identity)
- Produces: `SessionRegistry.nextId() → long`, `SessionRegistry.register(long id, GatedAgentSession session)`, `SessionRegistry.register(GatedAgentSession) → long` (convenience — calls nextId + register), `SessionRegistry.registerWithTimestamp(long id, GatedAgentSession session, Instant createdAt)` (test support), `SessionRegistry.deregister(long)`, `SessionRegistry.snapshot() → Map<Long, TrackedSession>`, `SessionRegistry.TrackedSession(long id, GatedAgentSession session, Instant createdAt)`

- [ ] **Step 1: Write SessionRegistryTest**

```java
package io.casehub.platform.agent.gate;

import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;

class SessionRegistryTest {

    @Test
    void registerAndDeregister() {
        var registry = new SessionRegistry();
        var session = dummySession();

        long id = registry.register(session);
        assertThat(registry.snapshot()).containsKey(id);

        registry.deregister(id);
        assertThat(registry.snapshot()).doesNotContainKey(id);
    }

    @Test
    void snapshotIsIsolatedFromMutations() {
        var registry = new SessionRegistry();
        var session = dummySession();
        long id = registry.register(session);

        var snapshot = registry.snapshot();
        registry.deregister(id);

        assertThat(snapshot).containsKey(id);
        assertThat(registry.snapshot()).doesNotContainKey(id);
    }

    @Test
    void deregisterIsIdempotent() {
        var registry = new SessionRegistry();
        long id = registry.register(dummySession());
        registry.deregister(id);
        registry.deregister(id); // no exception
        assertThat(registry.snapshot()).isEmpty();
    }

    @Test
    void idsAreMonotonicallyIncreasing() {
        var registry = new SessionRegistry();
        long id1 = registry.register(dummySession());
        long id2 = registry.register(dummySession());
        long id3 = registry.register(dummySession());
        assertThat(id2).isGreaterThan(id1);
        assertThat(id3).isGreaterThan(id2);
    }

    @Test
    void trackedSessionContainsCreationTimestamp() {
        var registry = new SessionRegistry();
        long id = registry.register(dummySession());

        var tracked = registry.snapshot().get(id);
        assertThat(tracked).isNotNull();
        assertThat(tracked.createdAt()).isNotNull();
        assertThat(tracked.id()).isEqualTo(id);
    }

    @Test
    void concurrentRegisterDeregister() throws Exception {
        var registry = new SessionRegistry();
        int threads = 20;
        var latch = new CountDownLatch(threads);
        var ids = new long[threads];

        for (int i = 0; i < threads; i++) {
            final int idx = i;
            Thread.ofVirtual().start(() -> {
                ids[idx] = registry.register(dummySession());
                latch.countDown();
            });
        }
        assertThat(latch.await(5, TimeUnit.SECONDS)).isTrue();
        assertThat(registry.snapshot()).hasSize(threads);

        var deregLatch = new CountDownLatch(threads);
        for (int i = 0; i < threads; i++) {
            final long id = ids[i];
            Thread.ofVirtual().start(() -> {
                registry.deregister(id);
                deregLatch.countDown();
            });
        }
        assertThat(deregLatch.await(5, TimeUnit.SECONDS)).isTrue();
        assertThat(registry.snapshot()).isEmpty();
    }

    private static GatedAgentSession dummySession() {
        return new GatedAgentSession(
                new NoOpSession(),
                java.util.List.of(), java.util.List.of(),
                Duration.ofSeconds(5),
                new SessionRegistry(), 0);
    }

    private static class NoOpSession implements io.casehub.platform.agent.AgentSession {
        @Override public io.smallrye.mutiny.Multi<io.casehub.platform.agent.AgentEvent> query(String prompt) {
            return io.smallrye.mutiny.Multi.createFrom().empty();
        }
        @Override public io.smallrye.mutiny.Uni<Void> interrupt() {
            return io.smallrye.mutiny.Uni.createFrom().voidItem();
        }
        @Override public void close(Duration maxWait) {}
        @Override public void close() { close(Duration.ofSeconds(30)); }
    }
}
```

Note: `dummySession()` uses the new constructor signature that will be introduced in Task 2. For Task 1's initial test run, use a temporary minimal constructor or accept compilation failure until Task 2 completes. Since both tasks are in the same batch, they are implemented together — write this test first, expect it won't compile until Step 3 and Task 2 align.

- [ ] **Step 2: Run test to verify it fails**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl agent-gate test -Dtest=SessionRegistryTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: FAIL — `SessionRegistry` class does not exist

- [ ] **Step 3: Implement SessionRegistry**

```java
package io.casehub.platform.agent.gate;

import jakarta.enterprise.context.ApplicationScoped;

import java.time.Instant;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

@ApplicationScoped
public class SessionRegistry {

    private final AtomicLong idCounter = new AtomicLong();
    private final ConcurrentHashMap<Long, TrackedSession> sessions = new ConcurrentHashMap<>();

    public record TrackedSession(long id, GatedAgentSession session, Instant createdAt) {}

    long nextId() {
        return idCounter.incrementAndGet();
    }

    long register(GatedAgentSession session) {
        long id = nextId();
        sessions.put(id, new TrackedSession(id, session, Instant.now()));
        return id;
    }

    void register(long id, GatedAgentSession session) {
        sessions.put(id, new TrackedSession(id, session, Instant.now()));
    }

    void registerWithTimestamp(long id, GatedAgentSession session, Instant createdAt) {
        sessions.put(id, new TrackedSession(id, session, createdAt));
    }

    void deregister(long id) {
        sessions.remove(id);
    }

    Map<Long, TrackedSession> snapshot() {
        return Map.copyOf(sessions);
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl agent-gate test -Dtest=SessionRegistryTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: PASS (once Task 2's constructor change is in place — if running Task 1 in isolation, the `dummySession()` helper won't compile yet; proceed to Task 2)

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add agent-gate/src/main/java/io/casehub/platform/agent/gate/SessionRegistry.java agent-gate/src/test/java/io/casehub/platform/agent/gate/SessionRegistryTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#242): add SessionRegistry for tracking open GatedAgentSessions"
```

---

### Task 2: Idempotent close guard + registry wiring in GatedAgentSession and GatedAgentProvider

**Files:**
- Modify: `agent-gate/src/main/java/io/casehub/platform/agent/gate/GatedAgentSession.java`
- Modify: `agent-gate/src/main/java/io/casehub/platform/agent/gate/GatedAgentProvider.java`
- Modify: `agent-gate/src/test/java/io/casehub/platform/agent/gate/GatedAgentSessionTest.java`
- Modify: `agent-gate/src/test/java/io/casehub/platform/agent/gate/GatedAgentProviderTest.java`

**Interfaces:**
- Consumes: `SessionRegistry.register(GatedAgentSession) → long`, `SessionRegistry.deregister(long)`
- Produces: `GatedAgentSession(AgentSession, List<AdmissionStrategy>, List<AdmissionStrategy>, Duration, SessionRegistry, long)` constructor, idempotent `close()`

- [ ] **Step 1: Add idempotent close test to GatedAgentSessionTest**

Add these tests to the existing `GatedAgentSessionTest`:

```java
@Test
void doubleCloseReleasesPermitOnlyOnce() throws Exception {
    var concurrency = new ConcurrencyStrategy(2);
    concurrency.tryAcquire(Duration.ofSeconds(1));
    concurrency.tryAcquire(Duration.ofSeconds(1));
    var registry = new SessionRegistry();
    var session = new GatedAgentSession(
            stubSession("x"),
            List.of(concurrency), List.of(),
            Duration.ofSeconds(5),
            registry, registry.register(null));

    session.close();
    session.close(); // second close is no-op

    // Only one permit released — one of two should be available
    assertThat(concurrency.tryAcquire(Duration.ofMillis(50))).isTrue();
    assertThat(concurrency.tryAcquire(Duration.ofMillis(50))).isFalse();
}

@Test
void closeDeregistersFromRegistry() {
    var registry = new SessionRegistry();
    var session = new GatedAgentSession(
            stubSession("x"),
            List.of(), List.of(),
            Duration.ofSeconds(5),
            registry, 0);
    long id = registry.register(session);
    // Re-create with correct ID
    session = new GatedAgentSession(
            stubSession("x"),
            List.of(), List.of(),
            Duration.ofSeconds(5),
            registry, id);

    session.close();
    assertThat(registry.snapshot()).doesNotContainKey(id);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl agent-gate test -Dtest=GatedAgentSessionTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: FAIL — constructor signature mismatch

- [ ] **Step 3: Update GatedAgentSession with idempotent close + registry**

Replace `GatedAgentSession.java` entirely:

```java
package io.casehub.platform.agent.gate;

import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentSession;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import java.time.Duration;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

final class GatedAgentSession implements AgentSession {

    private final AgentSession delegate;
    private final List<AdmissionStrategy> sessionStrategies;
    private final List<AdmissionStrategy> queryStrategies;
    private final Duration queryAcquireTimeout;
    private final SessionRegistry registry;
    private final long sessionId;
    private final AtomicBoolean closed = new AtomicBoolean(false);

    GatedAgentSession(AgentSession delegate,
                      List<AdmissionStrategy> sessionStrategies,
                      List<AdmissionStrategy> queryStrategies,
                      Duration queryAcquireTimeout,
                      SessionRegistry registry,
                      long sessionId) {
        this.delegate = delegate;
        this.sessionStrategies = sessionStrategies;
        this.queryStrategies = queryStrategies;
        this.queryAcquireTimeout = queryAcquireTimeout;
        this.registry = registry;
        this.sessionId = sessionId;
    }

    long sessionId() {
        return sessionId;
    }

    @Override
    public Multi<AgentEvent> query(String prompt) {
        if (closed.get()) {
            return Multi.createFrom().failure(
                    new IllegalStateException("GatedAgentSession has been closed"));
        }
        if (!queryStrategies.isEmpty()) {
            GatedAgentProvider.acquireAll(queryStrategies, queryAcquireTimeout);
        }
        return delegate.query(prompt);
    }

    @Override
    public Uni<Void> interrupt() {
        return delegate.interrupt();
    }

    @Override
    public void close(Duration maxWait) {
        if (!closed.compareAndSet(false, true)) {
            return;
        }
        try {
            delegate.close(maxWait);
        } finally {
            registry.deregister(sessionId);
            GatedAgentProvider.releaseAll(sessionStrategies);
        }
    }

    @Override
    public void close() {
        close(Duration.ofSeconds(30));
    }
}
```

- [ ] **Step 4: Update GatedAgentProvider to inject SessionRegistry and wire registration**

Add `SessionRegistry` injection and update `openSession()`:

In `GatedAgentProvider.java`, add field:
```java
@Inject SessionRegistry registry;
```

Update the test constructor to accept `SessionRegistry`:
```java
GatedAgentProvider(AgentProvider delegate, List<AdmissionStrategy> strategies,
                   Duration acquireTimeout, Duration queryAcquireTimeout,
                   SessionRegistry registry) {
    this.delegate = delegate;
    this.acquireTimeout = acquireTimeout;
    this.queryAcquireTimeout = queryAcquireTimeout;
    this.registry = registry;
    setStrategies(strategies);
}
```

Update `openSession()` — pre-allocate ID via `nextId()`, construct session, then register:

```java
@Override
public AgentSession openSession(AgentSessionInit init) {
    if (!active) {
        return delegate.openSession(init);
    }
    acquireAll(strategies, acquireTimeout);
    try {
        AgentSession session = delegate.openSession(init);
        long id = registry.nextId();
        var gated = new GatedAgentSession(session, sessionStrategies,
                invocationStrategies, queryAcquireTimeout, registry, id);
        registry.register(id, gated);
        return gated;
    } catch (Exception e) {
        releaseAll(strategies);
        throw e;
    }
}
```

- [ ] **Step 5: Update existing tests in GatedAgentSessionTest**

Update all existing test helper methods to use the new constructor. The `StubSession` inner class stays unchanged. The `stubSession()` helper and all direct `new GatedAgentSession(...)` calls gain the two extra parameters:

```java
// Change all occurrences of:
new GatedAgentSession(delegate, sessionStrategies, queryStrategies, timeout)
// to:
new GatedAgentSession(delegate, sessionStrategies, queryStrategies, timeout, new SessionRegistry(), 0)
```

Make `StubSession` package-private (remove `private`) so `SessionRegistryTest` can reference it.

- [ ] **Step 6: Update GatedAgentProviderTest**

Update the `createGated()` helper to pass a `SessionRegistry`:

```java
private GatedAgentProvider createGated(AgentProvider delegate,
                                       int maxConcurrent,
                                       double permitsPerSecond,
                                       int burstCapacity,
                                       Duration acquireTimeout,
                                       Duration queryAcquireTimeout) {
    var strategies = new java.util.ArrayList<AdmissionStrategy>();
    if (permitsPerSecond > 0) {
        int burst = burstCapacity > 0 ? burstCapacity
                : (int) Math.ceil(permitsPerSecond);
        strategies.add(new TokenBucketStrategy(permitsPerSecond, burst));
    }
    if (maxConcurrent > 0) {
        strategies.add(new ConcurrencyStrategy(maxConcurrent));
    }
    return new GatedAgentProvider(delegate, strategies,
            acquireTimeout, queryAcquireTimeout, new SessionRegistry());
}
```

- [ ] **Step 7: Run all agent-gate tests**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl agent-gate test -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: ALL PASS

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add agent-gate/src/main/java/io/casehub/platform/agent/gate/GatedAgentSession.java agent-gate/src/main/java/io/casehub/platform/agent/gate/GatedAgentProvider.java agent-gate/src/main/java/io/casehub/platform/agent/gate/SessionRegistry.java agent-gate/src/test/java/io/casehub/platform/agent/gate/GatedAgentSessionTest.java agent-gate/src/test/java/io/casehub/platform/agent/gate/GatedAgentProviderTest.java agent-gate/src/test/java/io/casehub/platform/agent/gate/SessionRegistryTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#242): idempotent close guard + registry wiring in GatedAgentSession/Provider"
```

---

## Batch 2: Reaper + Configuration

### Task 3: Reaper config nested in AgentGateProperties + SessionLeakReaper

**Files:**
- Modify: `agent-gate/src/main/java/io/casehub/platform/agent/gate/AgentGateProperties.java`
- Create: `agent-gate/src/test/java/io/casehub/platform/agent/gate/SessionLeakReaperTest.java`
- Create: `agent-gate/src/main/java/io/casehub/platform/agent/gate/SessionLeakReaper.java`
- Modify: `agent-gate/src/test/resources/application.properties`
- Modify: `agent-gate/pom.xml`

**Interfaces:**
- Consumes: `SessionRegistry.snapshot() → Map<Long, TrackedSession>`, `GatedAgentSession.close(Duration)`, `GatedAgentSession.sessionId()`, `AgentGateProperties.reaper()`
- Produces: `SessionLeakReaper.scan()` (@Scheduled), `AgentGateProperties.Reaper` (nested config interface)

- [ ] **Step 1: Add quarkus-scheduler dependency to pom.xml**

Add to `agent-gate/pom.xml` dependencies section:

```xml
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-scheduler</artifactId>
</dependency>
```

- [ ] **Step 2: Add Reaper nested interface to AgentGateProperties**

```java
@ConfigMapping(prefix = "casehub.platform.agent.gate")
public interface AgentGateProperties {

    // ... existing methods unchanged ...

    Reaper reaper();

    interface Reaper {
        @WithDefault("5m")
        Duration warnThreshold();

        @WithDefault("false")
        boolean forceCloseEnabled();

        @WithDefault("30m")
        Duration forceCloseThreshold();

        @WithDefault("24h")
        Duration maxRegistryAge();
    }
}
```

- [ ] **Step 3: Write SessionLeakReaperTest**

```java
package io.casehub.platform.agent.gate;

import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentSession;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.logging.Handler;
import java.util.logging.Level;
import java.util.logging.LogRecord;
import java.util.logging.Logger;
import java.util.ArrayList;

import static org.assertj.core.api.Assertions.assertThat;

class SessionLeakReaperTest {

    private SessionRegistry registry;
    private List<String> logMessages;
    private Handler logHandler;

    @BeforeEach
    void setUp() {
        registry = new SessionRegistry();
        logMessages = new ArrayList<>();
        logHandler = new Handler() {
            @Override
            public void publish(LogRecord record) {
                if (record.getLevel().intValue() >= Level.WARNING.intValue()) {
                    logMessages.add(record.getMessage());
                }
            }
            @Override public void flush() {}
            @Override public void close() {}
        };
    }

    @Test
    void scanDoesNothingWhenNoSessions() {
        var reaper = createReaper(Duration.ofMinutes(5), false, Duration.ofMinutes(30), Duration.ofHours(24));
        reaper.scan();
        // no exception, no logs
    }

    @Test
    void scanWarnsForSessionExceedingThreshold() {
        var session = registerOldSession(Duration.ofMinutes(10));
        var reaper = createReaper(Duration.ofMinutes(5), false, Duration.ofMinutes(30), Duration.ofHours(24));

        reaper.scan();

        assertThat(logMessages).anyMatch(msg -> msg.contains("Leaked GatedAgentSession detected"));
    }

    @Test
    void scanDoesNotWarnForSessionWithinThreshold() {
        var session = registerFreshSession();
        var reaper = createReaper(Duration.ofMinutes(5), false, Duration.ofMinutes(30), Duration.ofHours(24));

        reaper.scan();

        assertThat(logMessages).noneMatch(msg -> msg.contains("Leaked"));
    }

    @Test
    void scanForceClosesWhenEnabledAndThresholdExceeded() {
        var closedFlag = new AtomicBoolean(false);
        var session = registerOldSession(Duration.ofMinutes(45), closedFlag);
        var reaper = createReaper(Duration.ofMinutes(5), true, Duration.ofMinutes(30), Duration.ofHours(24));

        reaper.scan();

        assertThat(closedFlag.get()).isTrue();
        assertThat(logMessages).anyMatch(msg -> msg.contains("Force-closing"));
    }

    @Test
    void scanDoesNotForceCloseWhenDisabled() {
        var closedFlag = new AtomicBoolean(false);
        var session = registerOldSession(Duration.ofMinutes(45), closedFlag);
        var reaper = createReaper(Duration.ofMinutes(5), false, Duration.ofMinutes(30), Duration.ofHours(24));

        reaper.scan();

        assertThat(closedFlag.get()).isFalse();
        assertThat(logMessages).anyMatch(msg -> msg.contains("Leaked GatedAgentSession detected"));
    }

    @Test
    void scanEvictsAndClosesSessionExceedingMaxRegistryAge() {
        var closedFlag = new AtomicBoolean(false);
        var session = registerOldSession(Duration.ofHours(25), closedFlag);
        var reaper = createReaper(Duration.ofMinutes(5), false, Duration.ofMinutes(30), Duration.ofHours(24));

        assertThat(registry.snapshot()).hasSize(1);
        reaper.scan();
        assertThat(registry.snapshot()).isEmpty();
        assertThat(closedFlag.get()).isTrue();
        assertThat(logMessages).anyMatch(msg -> msg.contains("Evicted stale"));
    }

    @Test
    void scanContinuesAfterForceCloseException() {
        // Register two sessions: one that throws on close, one normal
        var throwingSession = registerOldSessionThrowing(Duration.ofMinutes(45));
        var normalClosed = new AtomicBoolean(false);
        var normalSession = registerOldSession(Duration.ofMinutes(45), normalClosed);

        var reaper = createReaper(Duration.ofMinutes(5), true, Duration.ofMinutes(30), Duration.ofHours(24));
        reaper.scan();

        // Both should be attempted — the exception from the first should not prevent the second
        assertThat(normalClosed.get()).isTrue();
        assertThat(logMessages).anyMatch(msg -> msg.contains("Failed to force-close"));
    }

    // --- helpers ---

    private SessionLeakReaper createReaper(Duration warnThreshold,
                                           boolean forceCloseEnabled,
                                           Duration forceCloseThreshold,
                                           Duration maxRegistryAge) {
        var reaper = new SessionLeakReaper(registry,
                warnThreshold, forceCloseEnabled, forceCloseThreshold, maxRegistryAge);
        // Attach log handler for assertions
        var julLogger = Logger.getLogger(SessionLeakReaper.class.getName());
        julLogger.addHandler(logHandler);
        julLogger.setLevel(Level.WARNING);
        return reaper;
    }

    private long registerFreshSession() {
        var session = new GatedAgentSession(
                new NoOpSession(), List.of(), List.of(),
                Duration.ofSeconds(5), registry, 0);
        return registry.register(session);
    }

    private long registerOldSession(Duration age) {
        return registerOldSession(age, new AtomicBoolean(false));
    }

    private long registerOldSession(Duration age, AtomicBoolean closedFlag) {
        var delegate = new NoOpSession() {
            @Override
            public void close(Duration maxWait) {
                closedFlag.set(true);
            }
        };
        var id = registry.nextId();
        var session = new GatedAgentSession(
                delegate, List.of(), List.of(),
                Duration.ofSeconds(5), registry, id);
        // Use reflection or a test-visible method to backdate the creation timestamp
        registry.registerWithTimestamp(id, session, Instant.now().minus(age));
        return id;
    }

    private long registerOldSessionThrowing(Duration age) {
        var delegate = new NoOpSession() {
            @Override
            public void close(Duration maxWait) {
                throw new RuntimeException("delegate close failed");
            }
        };
        var id = registry.nextId();
        var session = new GatedAgentSession(
                delegate, List.of(), List.of(),
                Duration.ofSeconds(5), registry, id);
        registry.registerWithTimestamp(id, session, Instant.now().minus(age));
        return id;
    }

    private static class NoOpSession implements AgentSession {
        @Override
        public Multi<AgentEvent> query(String prompt) {
            return Multi.createFrom().empty();
        }

        @Override
        public Uni<Void> interrupt() {
            return Uni.createFrom().voidItem();
        }

        @Override
        public void close(Duration maxWait) {}

        @Override
        public void close() { close(Duration.ofSeconds(30)); }
    }
}
```

Note: `SessionRegistry` needs a `registerWithTimestamp(long, GatedAgentSession, Instant)` method (package-private, test support) to allow backdating sessions for test scenarios. Add it alongside `register()`:

```java
void registerWithTimestamp(long id, GatedAgentSession session, Instant createdAt) {
    sessions.put(id, new TrackedSession(id, session, createdAt));
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl agent-gate test -Dtest=SessionLeakReaperTest -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: FAIL — `SessionLeakReaper` class does not exist

- [ ] **Step 5: Implement SessionLeakReaper**

```java
package io.casehub.platform.agent.gate;

import io.quarkus.scheduler.Scheduled;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.time.Duration;
import java.time.Instant;
import java.util.logging.Level;
import java.util.logging.Logger;

@ApplicationScoped
public class SessionLeakReaper {

    private static final Logger LOG = Logger.getLogger(SessionLeakReaper.class.getName());
    private static final Duration FORCE_CLOSE_TIMEOUT = Duration.ofSeconds(5);

    private final SessionRegistry registry;
    private final Duration warnThreshold;
    private final boolean forceCloseEnabled;
    private final Duration forceCloseThreshold;
    private final Duration maxRegistryAge;

    @Inject
    SessionLeakReaper(SessionRegistry registry, AgentGateProperties properties) {
        this(registry,
             properties.reaper().warnThreshold(),
             properties.reaper().forceCloseEnabled(),
             properties.reaper().forceCloseThreshold(),
             properties.reaper().maxRegistryAge());
    }

    SessionLeakReaper(SessionRegistry registry,
                      Duration warnThreshold,
                      boolean forceCloseEnabled,
                      Duration forceCloseThreshold,
                      Duration maxRegistryAge) {
        this.registry = registry;
        this.warnThreshold = warnThreshold;
        this.forceCloseEnabled = forceCloseEnabled;
        this.forceCloseThreshold = forceCloseThreshold;
        this.maxRegistryAge = maxRegistryAge;
        validateThresholds();
    }

    private void validateThresholds() {
        if (warnThreshold.compareTo(forceCloseThreshold) > 0) {
            throw new IllegalArgumentException(
                "reaper.warn-threshold (" + warnThreshold + ") must be <= force-close-threshold (" + forceCloseThreshold + ")");
        }
        if (forceCloseThreshold.compareTo(maxRegistryAge) > 0) {
            throw new IllegalArgumentException(
                "reaper.force-close-threshold (" + forceCloseThreshold + ") must be <= max-registry-age (" + maxRegistryAge + ")");
        }
    }

    @Scheduled(every = "${casehub.platform.agent.gate.reaper.scan-interval:60s}",
               identity = "session-leak-reaper")
    void scan() {
        var snapshot = registry.snapshot();
        if (snapshot.isEmpty()) {
            return;
        }

        var now = Instant.now();
        for (var entry : snapshot.values()) {
            Duration held = Duration.between(entry.createdAt(), now);

            if (held.compareTo(maxRegistryAge) > 0) {
                try {
                    entry.session().close(FORCE_CLOSE_TIMEOUT);
                    LOG.warning(String.format(
                        "Evicted stale GatedAgentSession: sessionId=%d, held for %s — closed and semaphore recovered",
                        entry.id(), held));
                } catch (Exception e) {
                    registry.deregister(entry.id());
                    LOG.log(Level.WARNING, String.format(
                        "Evicted stale GatedAgentSession: sessionId=%d, held for %s — close failed, semaphore slot permanently leaked",
                        entry.id(), held), e);
                }
                continue;
            }

            if (forceCloseEnabled && held.compareTo(forceCloseThreshold) > 0) {
                try {
                    entry.session().close(FORCE_CLOSE_TIMEOUT);
                    LOG.warning(String.format(
                        "Force-closed leaked GatedAgentSession: sessionId=%d, held for %s, created at %s",
                        entry.id(), held, entry.createdAt()));
                } catch (Exception e) {
                    LOG.log(Level.WARNING, String.format(
                        "Failed to force-close leaked GatedAgentSession: sessionId=%d, held for %s",
                        entry.id(), held), e);
                }
                continue;
            }

            if (held.compareTo(warnThreshold) > 0) {
                LOG.warning(String.format(
                    "Leaked GatedAgentSession detected: sessionId=%d, held for %s, created at %s",
                    entry.id(), held, entry.createdAt()));
            }
        }
    }
}
```

- [ ] **Step 6: Add test config to application.properties**

Append to `agent-gate/src/test/resources/application.properties`:

```properties
casehub.platform.agent.gate.reaper.scan-interval=60s
casehub.platform.agent.gate.reaper.warn-threshold=5m
casehub.platform.agent.gate.reaper.force-close-enabled=false
casehub.platform.agent.gate.reaper.force-close-threshold=30m
casehub.platform.agent.gate.reaper.max-registry-age=24h
```

- [ ] **Step 7: Run all agent-gate tests**

Run: `/opt/homebrew/bin/mvn --batch-mode -pl agent-gate test -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: ALL PASS

- [ ] **Step 8: Run full project build**

Run: `/opt/homebrew/bin/mvn --batch-mode install -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: BUILD SUCCESS

- [ ] **Step 9: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add agent-gate/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#242): SessionLeakReaper — @Scheduled scan with warn, force-close, eviction"
```

---

## References

- [2026-08-21-session-leak-reaper-design.md] — design spec this plan implements
- [agent-gate/src/main/java/io/casehub/platform/agent/gate/GatedAgentSession.java] — session wrapper being modified
- [agent-gate/src/main/java/io/casehub/platform/agent/gate/GatedAgentProvider.java] — @Decorator being modified
- [agent-gate/src/main/java/io/casehub/platform/agent/gate/AgentGateProperties.java] — config mapping being extended
- [agent-gate/src/test/java/io/casehub/platform/agent/gate/GatedAgentSessionTest.java] — existing tests being extended
- [agent-gate/src/test/java/io/casehub/platform/agent/gate/GatedAgentProviderTest.java] — existing tests being extended
- [PP-20260617-609995] — resource ownership pattern
- [PP-20260808-340f01] — CDI @Decorator pattern
- [GitHub #242] — focal issue
