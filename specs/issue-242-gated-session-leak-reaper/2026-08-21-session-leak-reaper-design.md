# Session Leak Detection for GatedAgentSession

**Issue:** casehubio/platform#242
**Module:** agent-gate
**Scale:** S | **Complexity:** Med

## Problem

An unclosed `GatedAgentSession` permanently leaks a `ConcurrencyStrategy` semaphore slot. Under the default configuration (gate present, provider semaphores disabled), this is the only concurrency control — a leaked slot directly reduces system capacity. The `AgentSession` contract requires callers to use try-with-resources, but there is no detection or recovery mechanism when they don't.

## Design

### Session Registry

A new `@ApplicationScoped` bean `SessionRegistry` tracks all open gated sessions. This is a standalone bean (not inside `GatedAgentProvider`) because CDI `@Decorator` beans cannot be injected into other beans.

```
@ApplicationScoped
public class SessionRegistry {

    private final AtomicLong idCounter = new AtomicLong();
    private final ConcurrentHashMap<Long, TrackedSession> sessions = new ConcurrentHashMap<>();

    record TrackedSession(long id, GatedAgentSession session, Instant createdAt) {}

    long register(GatedAgentSession session) {
        long id = idCounter.incrementAndGet();
        sessions.put(id, new TrackedSession(id, session, Instant.now()));
        return id;
    }

    void deregister(long id) {
        sessions.remove(id);
    }

    Map<Long, TrackedSession> snapshot() {
        return Map.copyOf(sessions);
    }
}
```

- **Register:** `GatedAgentProvider.openSession()` calls `registry.register(session)` immediately after creating the `GatedAgentSession`, before returning it to the caller. The returned `long id` is passed to the session's constructor.
- **Deregister:** `GatedAgentSession.close()` calls `registry.deregister(id)` in its `finally` block alongside strategy release.

The registry uses a monotonically increasing `AtomicLong` ID per session rather than identity hash codes — this avoids hash collisions and provides unambiguous log correlation.

### Idempotent Close Guard

`GatedAgentSession` gains an `AtomicBoolean closed` field. The `close()` method uses `compareAndSet(false, true)` as a gate — only the first caller executes the delegate close, strategy release, and deregistration. Subsequent calls are no-ops.

This prevents the double-release race between a normal caller close and the reaper's force-close: if both call `close()` concurrently, only one thread enters the `finally` block. Without this guard, `Semaphore.release()` would be called twice (it does not check whether the caller holds a permit), permanently inflating concurrency beyond the configured maximum.

```
void close(Duration maxWait) {
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
```

### SessionLeakReaper

A new `@ApplicationScoped` bean in `io.casehub.platform.agent.gate`:

```
@ApplicationScoped
public class SessionLeakReaper {

    @Inject SessionRegistry registry;
    @Inject AgentGateProperties properties;

    @Scheduled(every = "${casehub.platform.agent.gate.reaper.scan-interval:60s}")
    void scan() { ... }
}
```

The scan iterates a snapshot of the registry (`registry.snapshot()`). For each entry where `Duration.between(createdAt, Instant.now())` exceeds `warn-threshold`:

1. Log at WARN level: session ID, hold duration, creation timestamp
2. If force-close is enabled and hold duration exceeds `force-close-threshold`: call `session.close(Duration.ofSeconds(5))`, catch any exception, log at WARN that force-close was invoked (or failed)
3. If hold duration exceeds `max-registry-age`: evict the entry from the registry via `registry.deregister(id)`, log at WARN that the session was evicted (the semaphore slot remains leaked, but the registry reference and delegate resources are released for GC)

**Exception handling:** Force-close calls are wrapped in try-catch. Any exception from `delegate.close()` is caught and logged at WARN — a failing delegate must not crash the scan loop or prevent processing of subsequent sessions.

**Sequential execution:** Force-closes run sequentially within the scan. This is acceptable — force-close is rare (disabled by default), the 5-second timeout bounds each call, and the reaper runs on a scheduled thread that is not latency-sensitive.

### Configuration

New properties nested inside the existing `AgentGateProperties` interface, following the established pattern of nested interfaces (`Concurrency`, `TokenBucketConfig`, `SlidingWindow`):

```
@ConfigMapping(prefix = "casehub.platform.agent.gate")
public interface AgentGateProperties {
    // ... existing nested interfaces ...

    Reaper reaper();

    interface Reaper {
        @WithDefault("60s")
        Duration scanInterval();

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

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `reaper.scan-interval` | Duration | `60s` | How often the reaper scans for leaked sessions |
| `reaper.warn-threshold` | Duration | `5m` | Session hold time before WARN log |
| `reaper.force-close-enabled` | boolean | `false` | Whether to force-close sessions exceeding force-close-threshold |
| `reaper.force-close-threshold` | Duration | `30m` | Session hold time before force-close (only when enabled) |
| `reaper.max-registry-age` | Duration | `24h` | Session hold time before eviction from registry (releases reference for GC; slot remains leaked) |

### Log Output

WARN log format for leak detection:
```
Leaked GatedAgentSession detected: sessionId={id}, held for {duration}, created at {timestamp}
```

WARN log format for force-close:
```
Force-closing leaked GatedAgentSession: sessionId={id}, held for {duration}, created at {timestamp}
```

WARN log format for registry eviction:
```
Evicting stale GatedAgentSession from registry: sessionId={id}, held for {duration} — semaphore slot permanently leaked
```

All use `org.jboss.logging.Logger` consistent with the rest of the platform.

### Activation

The reaper is always active when agent-gate is on the classpath. The `@Scheduled` scan runs at the configured interval. If no sessions are open, the scan is a no-op (empty map iteration). If `warn-threshold` is set to `0` or a very large value, the reaper effectively does nothing — no need for an explicit enable/disable toggle.

### Impact on Existing Code

**GatedAgentSession:** constructor gains `SessionRegistry` and `long sessionId` parameters. Gains `AtomicBoolean closed` field for idempotent close guard. `close()` method restructured: CAS gate → delegate close → deregister → release strategies.

**GatedAgentProvider:** `openSession()` calls `registry.register(session)` after session creation, passes registry and session ID to `GatedAgentSession` constructor. Injects `SessionRegistry`.

**AgentGateProperties:** gains nested `Reaper` interface with five config properties.

**New classes:**
- `SessionRegistry` — `@ApplicationScoped`, session tracking with monotonic IDs
- `SessionLeakReaper` — `@ApplicationScoped`, `@Scheduled` scan

**No changes to:**
- `AdmissionStrategy`, `AdmissionGate`, `ConcurrencyStrategy`, `TokenBucketStrategy`, `SlidingWindowStrategy`
- `AgentSession` SPI in platform-api
- Any consumer code

### Testing

- **SessionLeakReaperTest:** unit test with a mock `SessionRegistry` pre-populated with sessions at various ages. Verify WARN logs emitted for sessions exceeding threshold. Verify force-close invoked when enabled and threshold exceeded. Verify no action for sessions within threshold. Verify exception from force-close is caught and logged, scan continues. Verify registry eviction after max-registry-age.
- **SessionRegistryTest:** unit test for register/deregister/snapshot — verify thread safety with concurrent register/deregister, verify deregister is idempotent, verify monotonic ID assignment.
- **GatedAgentSessionTest:** extend existing test to verify deregister is called on close (including when delegate throws). Verify idempotent close — second close is no-op, strategies released exactly once.
- **GatedAgentProviderTest:** extend existing test to verify register is called on session creation.

## References

- `agent-gate/src/main/java/io/casehub/platform/agent/gate/GatedAgentSession.java` — current session wrapper, close() with finally
- `agent-gate/src/main/java/io/casehub/platform/agent/gate/GatedAgentProvider.java` — @Decorator, openSession() creates gated sessions
- `agent-gate/src/main/java/io/casehub/platform/agent/gate/ConcurrencyStrategy.java` — Semaphore-based concurrency, the slot that leaks
- `agent-gate/src/main/java/io/casehub/platform/agent/gate/AgentGateProperties.java` — existing config mapping pattern (nested interfaces)
- `agent-api/src/main/java/io/casehub/platform/agent/AgentSession.java` — SPI contract, close() javadoc warns about leaks
- PP-20260617-609995 — resource ownership: caller-supplied AutoCloseable lifecycle
- PP-20260808-340f01 — CDI @Decorator pattern for cross-cutting AgentProvider concerns
- Design review R1 — double-close race (R1-02), config mapping convention (R1-03), unbounded registry (R1-04), force-close exception handling (R1-05), session ID collisions (R1-06)
