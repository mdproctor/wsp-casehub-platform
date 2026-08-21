# Session Leak Detection for GatedAgentSession

**Issue:** casehubio/platform#242
**Module:** agent-gate
**Scale:** S | **Complexity:** Med

## Problem

An unclosed `GatedAgentSession` permanently leaks a `ConcurrencyStrategy` semaphore slot. Under the default configuration (gate present, provider semaphores disabled), this is the only concurrency control — a leaked slot directly reduces system capacity. The `AgentSession` contract requires callers to use try-with-resources, but there is no detection or recovery mechanism when they don't.

## Design

### Session Registry

`GatedAgentProvider` gains a package-private `ConcurrentHashMap<GatedAgentSession, Instant>` that tracks all open gated sessions with their creation timestamp.

- **Register:** in `openSession()`, immediately after the delegate session is created and before returning the `GatedAgentSession` to the caller
- **Deregister:** in `GatedAgentSession.close()`, in the `finally` block alongside strategy release

The map key is the session instance itself (identity-based). The value is the creation `Instant`.

### SessionLeakReaper

A new `@ApplicationScoped` bean in `io.casehub.platform.agent.gate`:

```
@ApplicationScoped
public class SessionLeakReaper {

    @Inject GatedAgentProvider provider;
    @Inject SessionLeakReaperProperties properties;

    @Scheduled(every = "${casehub.platform.agent.gate.reaper.scan-interval:60s}")
    void scan() { ... }
}
```

The scan iterates the provider's session registry. For each entry where `Duration.between(createdAt, Instant.now())` exceeds `warn-threshold`:

1. Log at WARN level: session identity hash, hold duration, creation timestamp
2. If force-close is enabled and hold duration exceeds `force-close-threshold`: call `session.close(Duration.ofSeconds(5))` and log at WARN that force-close was invoked

Force-close uses a 5-second timeout on the delegate's graceful drain (per D2). The reaper iterates a snapshot of the map (`Map.copyOf()` or stream) so that concurrent close/deregister during iteration does not cause `ConcurrentModificationException`.

### CDI Interaction with @Decorator

`GatedAgentProvider` is a `@Decorator` — CDI decorators are not normal beans and cannot be directly `@Inject`-ed into other beans. The reaper needs access to the session registry.

The registry is extracted into a standalone `@ApplicationScoped` bean:

```
@ApplicationScoped
public class SessionRegistry {

    private final ConcurrentHashMap<GatedAgentSession, Instant> sessions = new ConcurrentHashMap<>();

    void register(GatedAgentSession session) {
        sessions.put(session, Instant.now());
    }

    void deregister(GatedAgentSession session) {
        sessions.remove(session);
    }

    Map<GatedAgentSession, Instant> snapshot() {
        return Map.copyOf(sessions);
    }
}
```

`GatedAgentProvider` injects `SessionRegistry` and calls `register`/`deregister`. `SessionLeakReaper` also injects `SessionRegistry` and calls `snapshot()` during scans. Both beans are `@ApplicationScoped` — CDI manages the single instance.

`GatedAgentSession` receives the `SessionRegistry` reference and calls `deregister(this)` in its `close()` `finally` block. This is simpler than a `Runnable` callback and makes the deregistration intent explicit.

### Configuration

New properties under the existing `casehub.platform.agent.gate` prefix:

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `reaper.scan-interval` | Duration | `60s` | How often the reaper scans for leaked sessions |
| `reaper.warn-threshold` | Duration | `5m` | Session hold time before WARN log |
| `reaper.force-close-enabled` | boolean | `false` | Whether to force-close sessions exceeding force-close-threshold |
| `reaper.force-close-threshold` | Duration | `30m` | Session hold time before force-close (only when enabled) |

These are added to a new `SessionLeakReaperProperties` config mapping interface (separate from `AgentGateProperties` — the reaper is a distinct concern with its own config prefix `casehub.platform.agent.gate.reaper`).

### Log Output

WARN log format for leak detection:
```
Leaked GatedAgentSession detected: id={identityHashCode}, held for {duration}, created at {timestamp}
```

WARN log format for force-close:
```
Force-closing leaked GatedAgentSession: id={identityHashCode}, held for {duration}, created at {timestamp}
```

Both use `org.jboss.logging.Logger` consistent with the rest of the platform.

### Activation

The reaper is always active when agent-gate is on the classpath. The `@Scheduled` scan runs at the configured interval. If no sessions are open, the scan is a no-op (empty map iteration). If `warn-threshold` is set to `0` or a very large value, the reaper effectively does nothing — no need for an explicit enable/disable toggle.

### Impact on Existing Code

**GatedAgentSession:** constructor gains a `SessionRegistry` parameter. `close()` adds `registry.deregister(this)` in the `finally` block.

**GatedAgentProvider:** `openSession()` adds `registry.register(session)` after session creation. Injects `SessionRegistry`.

**New classes:**
- `SessionRegistry` — `@ApplicationScoped`, session tracking
- `SessionLeakReaper` — `@ApplicationScoped`, `@Scheduled` scan
- `SessionLeakReaperProperties` — `@ConfigMapping`, reaper config

**No changes to:**
- `AdmissionStrategy`, `AdmissionGate`, `ConcurrencyStrategy`, `TokenBucketStrategy`, `SlidingWindowStrategy`
- `AgentSession` SPI in platform-api
- Any consumer code

### Testing

- **SessionLeakReaperTest:** unit test with a mock `SessionRegistry` pre-populated with sessions at various ages. Verify WARN logs emitted for sessions exceeding threshold. Verify force-close invoked when enabled and threshold exceeded. Verify no action for sessions within threshold.
- **SessionRegistryTest:** unit test for register/deregister/snapshot — verify thread safety with concurrent register/deregister, verify deregister is idempotent.
- **GatedAgentSessionTest:** extend existing test to verify `deregister` is called on close (including when delegate throws).
- **GatedAgentProviderTest:** extend existing test to verify `register` is called on session creation.

## References

- `agent-gate/src/main/java/io/casehub/platform/agent/gate/GatedAgentSession.java` — current session wrapper, close() with finally
- `agent-gate/src/main/java/io/casehub/platform/agent/gate/GatedAgentProvider.java` — @Decorator, openSession() creates gated sessions
- `agent-gate/src/main/java/io/casehub/platform/agent/gate/ConcurrencyStrategy.java` — Semaphore-based concurrency, the slot that leaks
- `agent-gate/src/main/java/io/casehub/platform/agent/gate/AgentGateProperties.java` — existing config mapping pattern
- `agent-api/src/main/java/io/casehub/platform/agent/AgentSession.java` — SPI contract, close() javadoc warns about leaks
- PP-20260617-609995 — resource ownership: caller-supplied AutoCloseable lifecycle
- PP-20260808-340f01 — CDI @Decorator pattern for cross-cutting AgentProvider concerns
