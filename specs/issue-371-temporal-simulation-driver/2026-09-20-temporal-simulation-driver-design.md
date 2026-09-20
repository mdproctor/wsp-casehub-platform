# Temporal Simulation Driver Design Spec

**Branch:** issue-371-temporal-simulation-driver
**Issue:** casehubio/platform#371
**Date:** 2026-09-20

## Overview

Adds lifecycle-controlled temporal simulation to the simulation framework. The existing `EventSequenceRunner` is fire-and-forget and CloudEvent-specific. This issue fills six gaps: no lifecycle control (pause/resume/stop), no looping, no runtime speed changes, CloudEvent-specific runner, no YAML temporal profiles, and no journal integration for timed sequences.

The approach composes with existing types (`TimedEntry<E>`, `TimedSequence<E>`) rather than creating a parallel type hierarchy. The real new capability is the `TemporalSimulationDriver<E>` — a lifecycle controller that runs temporal profiles on virtual threads with pause/resume/stop/speed control and journal integration.

## Architecture

### Data Model Changes

**TimedEntry<E>** — gains optional `label` and `qualifiedName` for per-event journal tracking:

```java
// moves from event-simulation-core to simulation-core
package io.casehub.platform.simulation;

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

- `label` — human-readable identifier for journal verification (`SimulationVerifier` assertions). Positional tracking (`sequence[0]`) breaks on dynamic composition. Nullable for backward compatibility.
- `qualifiedName` — per-entry override of the profile-level qualifiedName. Nullable — when null, the driver uses the profile's qualifiedName. Set during `sequence:` ref concatenation to preserve each sub-profile's attribution (e.g., `iot.alarm` events inside a `full-demo` profile retain their original qualifiedName rather than inheriting `iot.device-state-change` from the parent profile).

**TimedSequence<E>** — moves from `event-simulation-core` to `simulation-core` unchanged. `withMultiplier()`, `fromRecorded()`, `totalDuration()` carry over. The `withMultiplier()` transform preserves labels and qualifiedNames.

**TemporalProfile<E>** — new record wrapping TimedSequence with lifecycle metadata:

```java
package io.casehub.platform.simulation;

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

- `name` — human-readable identifier (e.g. `"morning-routine"`)
- `qualifiedName` — default method name for corpus/journal tracking (e.g. `"iot.device-state-change"`). Individual `TimedEntry` entries may override this via their own `qualifiedName` field.
- `tenancyId` — tenant context for journal recording (nullable). Resolved from YAML `tenancy-id:` with fallback to config-level `default-tenancy-id`. Generated decorators get tenancyId from `currentPrincipal.tenancyId()`, but the temporal driver runs on its own virtual thread without a security context — tenancyId must be part of the profile data.
- `loop` — repeat after last event
- `speed` — initial speed multiplier (1.0 = real-time, 10.0 = 10x)

Design precedent: `SimulationProfile` wraps `SimulationConfig + SimulationCorpus`. `TemporalProfile` wraps `TimedSequence` with lifecycle metadata. Same composition pattern.

**EventSequenceRunner** stays in `event-simulation-core`. Import paths change for `TimedEntry`/`TimedSequence`. No API change — it remains the CloudEvent-specific one-shot runner.

### TemporalSimulationDriver

Lifecycle controller. Runs a `TemporalProfile` on a virtual thread with pause/resume/stop/speed control and journal integration.

**State machine:** `IDLE → RUNNING ↔ PAUSED → STOPPED`, plus `RUNNING → COMPLETED` for non-looping profiles.

```java
package io.casehub.platform.simulation;

public class TemporalSimulationDriver<E> {

    private final TemporalEventSink<E> eventSink;
    private final SimulationRuntime simulation;  // nullable — journal optional

    enum State { IDLE, RUNNING, PAUSED, STOPPED, COMPLETED }

    public TemporalSimulationDriver(TemporalEventSink<E> eventSink, SimulationRuntime simulation);
    public TemporalSimulationDriver(TemporalEventSink<E> eventSink);  // no journal

    public void start(TemporalProfile<E> profile);
    public void pause();
    public void resume();
    public void stop();
    public void setSpeed(double speed);
    public State state();
    public boolean isRunning();
    public DriverResult lastResult();
}
```

**TemporalEventSink<E>** — replaces `Consumer<E>` to provide delivery context:

```java
@FunctionalInterface
public interface TemporalEventSink<E> {
    void deliver(String qualifiedName, String label, E event);
}
```

The driver calls `eventSink.deliver(effectiveQualifiedName, label, event)` for each entry, where `effectiveQualifiedName` is `entry.qualifiedName() != null ? entry.qualifiedName() : profile.qualifiedName()`. This gives consumers the context needed for CloudEvent construction (qualifiedName → event type) and logging (label → event identity).

**Key behaviors:**

1. **start()** — spawns a virtual thread. Iterates entries: `Thread.sleep(delay / speed)` → deliver via `eventSink.deliver(effectiveQualifiedName, label, event)` → record to journal. When `loop=true`, restarts from the beginning and increments `loopIterations`. Throws `IllegalStateException` on non-IDLE driver. On natural completion of a non-looping profile, transitions to COMPLETED.

2. **pause()** — sets state to PAUSED. Driver thread blocks on the lock's `Condition`. No events fire while paused.

3. **resume()** — signals the condition, state returns to RUNNING. Sequence continues from where it paused.

4. **stop()** — sets state to STOPPED, interrupts the driver thread. Terminal — cannot restart. Callable from RUNNING, PAUSED, or COMPLETED.

5. **setSpeed(double)** — volatile field. Next sleep uses new value. Mid-sleep is not interrupted — change takes effect on next event.

6. **Journal integration** — if `SimulationRuntime` is provided, each event delivery calls `simulation.recordJournal(effectiveQualifiedName, tenancyId, label, event, true)`. The `tenancyId` comes from `profile.tenancyId()`. This feeds `SimulationVerifier`.

   Journal recording is a no-op when no overlay is active on `SimulationRuntime` — this is the standard framework behavior. The same `overlayStack.isEmpty()` fast path is used by all generated decorators. The driver does not manage overlays itself; overlay lifecycle is the caller's responsibility. Typical pattern:
   - Test pushes an overlay via `SimulationRuntime.pushOverlay()`
   - Test creates a driver and calls `start(profile)`
   - Driver records to the top overlay's journal via `recordJournal()`
   - Test calls `driver.stop()` — ensures no further events fire
   - Test verifies via `SimulationVerifier.on(overlay)` — counts are final
   - Test pops the overlay — journal is discarded, isolation complete

   The driver must be stopped before overlay pop. If a still-running driver outlives its overlay, and a subsequent test pushes a new overlay, the driver records into the wrong test's journal — cross-test contamination. Stopping the driver first also ensures `lastResult()` has the final count and no events arrive between verification and pop.

   If an overlay is popped while a driver is still running (programming error), subsequent journal recording calls become no-ops (empty overlay stack). The driver continues firing events, just without journal recording.

7. **Error isolation** — one failing event delivery doesn't stop the sequence. Failure recorded in `DriverResult` with both the entry's label and its positional index. Same pattern as `EventSequenceRunner`.

8. **lastResult()** — returns a snapshot of accumulated execution state. Available during RUNNING, PAUSED, COMPLETED, and STOPPED. Returns null before `start()` is called. For looping profiles, counts are cumulative across all completed iterations. The `failures` list is bounded to the last 100 failures; `failureCount` tracks the cumulative total.

9. **Post-completion (non-looping)** — when the sequence completes naturally, the virtual thread terminates and the driver transitions to COMPLETED. `lastResult()` returns the final accumulated result. `stop()` can still be called (transitions to STOPPED, idempotent). `isRunning()` returns false.

**Thread model:** Virtual-thread `Thread.sleep()` — same pattern as `EventSequenceRunner`. Each driver runs its own virtual thread. Avoids ScheduledFuture cancel-clear-reschedule gotcha (GE-20260701-82909e). Virtual threads are cheap for simulation workloads.

**Thread safety:** All state transitions protected by a single `ReentrantLock`. Speed is volatile (single writer, driver thread reads). Pause/resume uses the lock's `Condition` — checking state and awaiting share the same lock, eliminating the race window between state check and condition wait.

**DriverResult + DriverFailure:**

```java
public record DriverFailure(int index, String label, Exception cause) {}

public record DriverResult(
        int emittedCount,
        int failureCount,
        int loopIterations,
        List<DriverFailure> failures) {

    public DriverResult {
        failures = List.copyOf(failures);
    }

    public boolean hasFailures() { return failureCount > 0; }
}
```

`DriverFailure` includes both `index` (positional within the sequence) and `label` (from `TimedEntry.label()`, nullable). When label is null, the index provides a reliable fallback identifier. `DriverFailure` is local to simulation-core — no dependency on `EmissionFailure` in event-simulation-core.

`failureCount` is the cumulative total across all loop iterations. `failures` is bounded to the last 100 entries (driver-internal); `failureCount` may exceed `failures.size()` for long-running looping profiles with frequent transient errors.

**TemporalDriverFactory:**

```java
@FunctionalInterface
public interface TemporalDriverFactory<E> {
    TemporalSimulationDriver<E> create();
}
```

Drivers are lightweight (virtual thread + small state). Multiple profiles can run concurrently with separate driver instances. The factory pattern is cleaner than a reusable singleton since `stop()` is terminal. A custom interface rather than `Supplier<TemporalSimulationDriver<E>>` — CDI bean resolution with nested parameterized types (`Supplier<TemporalSimulationDriver<Map<String, Object>>>`) is fragile and poorly supported; a dedicated type resolves unambiguously.

### YAML Loading

**New types in simulation-config-core:**

```java
record TemporalProfileConfig(
        String qualifiedName,
        String tenancyId,
        boolean loop,
        double speed,
        List<TemporalEventConfig> events,
        String eventsFile,
        String fromCorpus,
        List<SequenceRef> sequence) {}

record TemporalEventConfig(
        String delay,
        String label,
        Map<String, Object> payload) {}

record SequenceRef(
        String ref,
        String delay) {}
```

**Four mutually exclusive event sources** — validated at parse time:

| Source | YAML key | Java equivalent |
|--------|----------|----------------|
| Inline events | `events:` | `new TimedSequence<>(entries)` |
| External file | `events-file:` | `loader.load(path)` |
| Corpus-derived | `from-corpus:` | `TimedSequence.fromRecorded(corpus.list(qn))` |
| Concatenation | `sequence:` | compose referenced profiles |

**Duration parsing:** `"5s"`, `"2m"`, `"500ms"`, bare number as millis.

**YamlSimulationConfig extensions:**

- Parses new top-level `temporal-profiles:` section
- Parses `temporal:` within `profiles:` — list of refs and/or inline definitions
- New methods:
  - `Map<String, TemporalProfileConfig> temporalProfiles()`
  - `TemporalProfile<Map<String, Object>> resolveTemporalProfile(String name)` — builds from config, resolves `from-corpus` via corpus data, resolves `sequence:` refs recursively with cycle detection
  - `List<TemporalProfileConfig> temporalForProfile(String profileName)`

**`from-corpus` resolution:** Calls `TimedSequence.fromRecorded(corpus.list(qualifiedName))` — derives timing from `InvocationRecord.recordedAt()` timestamps. Requires corpus data to be loaded first (startup ordering: corpus → temporal profiles).

**`sequence` resolution:** Recursive ref lookup with cycle detection (visited name set). Each ref resolves to a `TimedSequence`, concatenated in order. During concatenation, each entry's `qualifiedName` is set to its source profile's `qualifiedName`, preserving per-entry attribution across composed sequences (e.g., `alarm-sequence` entries concatenated into `full-demo` retain `iot.alarm` rather than inheriting `iot.device-state-change`).

Optional `delay` on a ref is absorbed into the referenced profile's first entry — the gap duration is added to that entry's existing delay. This avoids inserting a synthetic gap `TimedEntry` (which would require a non-null event, resulting in a phantom event delivery and spurious journal recording). If the referenced profile's sequence is empty, the gap delay is discarded.

Example: `delay: 30s` on `ref: alarm-sequence` means alarm-sequence's first event fires 30s after morning-routine's last event, by adding 30s to that first entry's delay.

**Full YAML example:**

```yaml
temporal-profiles:
  morning-routine:
    qualified-name: iot.device-state-change
    tenancy-id: demo-tenant    # optional — defaults to config default-tenancy-id
    loop: true
    speed: 10.0
    events:
      - delay: 0
        label: motion-cascade
        payload: { deviceId: motion-01, state: ACTIVE }
      - delay: 5s
        label: lights-on
        payload: { deviceId: light-01, state: ON }
      - delay: 2m
        label: thermostat-adjust
        payload: { deviceId: thermo-01, setpoint: 22.5 }

  replayed-feed:
    qualified-name: bank-feed.transaction
    from-corpus: bank-feed.transaction
    speed: 5.0

  alarm-sequence:
    qualified-name: iot.alarm
    events-file: classpath:simulation/alarm-events.yaml

  full-demo:
    qualified-name: iot.device-state-change
    loop: true
    sequence:
      - ref: morning-routine
      - delay: 30s
        ref: alarm-sequence

profiles:
  demo:
    methods:
      iot.device-state.getState:
        strategy: key-lookup
        corpus: [...]
    temporal:
      - ref: morning-routine
      - qualified-name: iot.quick-burst
        loop: false
        events:
          - delay: 0
            payload: { deviceId: smoke-01, state: ALARM }
          - delay: 1s
            payload: { deviceId: smoke-01, state: CLEAR }
```

### Quarkus Wiring

**simulation-config** — provides parsed temporal profiles:

```java
// in SimulationConfigBeans
@Produces @ApplicationScoped
TemporalProfileRegistry temporalProfileRegistry(YamlSimulationConfig config,
                                                 SimulationCorpus corpus) {
    // Resolves all top-level temporal-profiles after corpus is loaded
}
```

`TemporalProfileRegistry` is a POJO in simulation-config-core:

```java
public class TemporalProfileRegistry {
    public Optional<TemporalProfile<Map<String, Object>>> resolve(String name);
    public Set<String> profileNames();
}
```

**event-simulation** — provides driver factory wired to the CDI event bus:

```java
// in EventSimulationBeans
@Produces @ApplicationScoped
TemporalDriverFactory<Map<String, Object>> temporalDriverFactory(SimulationRuntime runtime) {
    return () -> new TemporalSimulationDriver<>(
            (qualifiedName, label, payload) -> {
                try {
                    CloudEvent ce = CloudEventBuilder.v1()
                            .withType(qualifiedName)
                            .withId(UUID.randomUUID().toString())
                            .withSource(URI.create("//simulation"))
                            .withTime(OffsetDateTime.now())
                            .withData("application/json",
                                    jsonMapper.writeValueAsBytes(payload))
                            .build();
                    cloudEventBus.fireAsync(ce);
                } catch (JsonProcessingException e) {
                    throw new UncheckedIOException(e);
                }
            },
            runtime);
}
```

The factory type is `Map<String, Object>` to match `TemporalProfileRegistry`'s resolved type (YAML payloads are maps). The `TemporalEventSink` receives `qualifiedName` from the driver's loop context — the CDI producer uses it as the CloudEvent type. Domains inject `TemporalDriverFactory` + `TemporalProfileRegistry`, call `factory.create()` to get a driver, then `driver.start(profile)`:

```java
@Inject TemporalDriverFactory<Map<String, Object>> driverFactory;
@Inject TemporalProfileRegistry registry;

var profile = registry.resolve("morning-routine").get();
var driver = driverFactory.create();
driver.start(profile);  // types align — both Map<String, Object>
```

### Module Change Summary

| Module | Changes |
|--------|---------|
| `simulation-core` | + `TimedEntry` (moved), + `TimedSequence` (moved), + `TemporalProfile`, + `TemporalSimulationDriver`, + `TemporalEventSink`, + `DriverResult`, + `DriverFailure`, + `TemporalDriverFactory` |
| `event-simulation-core` | − `TimedEntry` (moved), − `TimedSequence` (moved), update imports in `EventSequenceRunner` + tests |
| `simulation-config-core` | + `TemporalProfileConfig`, + `TemporalEventConfig`, + `SequenceRef`, + temporal YAML parsing in `YamlSimulationConfig`, + `TemporalProfileRegistry` |
| `simulation-config` | + `@Produces TemporalProfileRegistry` in `SimulationConfigBeans` |
| `event-simulation` | + `@Produces TemporalDriverFactory<Map<String, Object>>` in `EventSimulationBeans` |

## Testing

### simulation-core (unit tests, no CDI)

| Test | What it verifies |
|------|-----------------|
| `TimedEntryTest` | Label field — null default, preserved through construction |
| `TimedSequenceTest` | Existing tests (moved) + label propagation through `withMultiplier()` and `fromRecorded()` |
| `TemporalProfileTest` | Construction, validation (null name, zero speed), immutability |
| `TemporalSimulationDriverTest` — basic run | Sequence executes in order, events delivered to sink |
| `TemporalSimulationDriverTest` — looping | Sequence repeats, events accumulate across iterations |
| `TemporalSimulationDriverTest` — pause/resume | Events stop during pause, resume continues from paused position |
| `TemporalSimulationDriverTest` — stop | Mid-sequence stop, no further events, state is STOPPED |
| `TemporalSimulationDriverTest` — speed | `speed=10.0` delivers a 1s-delay event in ~100ms (tolerance-based) |
| `TemporalSimulationDriverTest` — setSpeed mid-flight | Speed change takes effect on next delay |
| `TemporalSimulationDriverTest` — journal with overlay | With SimulationRuntime + active overlay, journal records each event with label and qualifiedName |
| `TemporalSimulationDriverTest` — journal without overlay | With SimulationRuntime but no overlay, journal recording is a no-op — events still fire |
| `TemporalSimulationDriverTest` — error isolation | One failing event doesn't stop the sequence, failure has both index and label |
| `TemporalSimulationDriverTest` — completion | Non-looping profile transitions to COMPLETED, lastResult() available |
| `TemporalSimulationDriverTest` — concat qualifiedNames | Concatenated sequence preserves per-entry qualifiedNames from source profiles |

All driver tests use short delays (10-50ms). Timing assertions use tolerances.

### simulation-config-core (unit tests, no CDI)

| Test | What it verifies |
|------|-----------------|
| YAML inline events | Parses `events:` with delay/label/payload |
| YAML events-file | Resolves external file path |
| YAML from-corpus | Derives TimedSequence from corpus InvocationRecords |
| YAML sequence refs | Resolves refs, concatenates, absorbs gap delays into first entry of referenced sequence |
| YAML cycle detection | Circular `sequence:` refs → clear error |
| YAML mutual exclusivity | Two sources on one profile → parse error |
| YAML inline in profiles | `temporal:` within a profile — refs + inline |
| Duration parsing | `"5s"`, `"2m"`, `"500ms"`, bare millis |

### event-simulation-core

Existing `EventSequenceRunnerTest` and `TimedSequenceTest` — update imports after move. Verify nothing breaks.

### event-simulation (Quarkus integration)

`@QuarkusTest` verifying `TemporalDriverFactory<Map<String, Object>>` is injectable and produces a working driver that converts map payloads to CloudEvents and fires them via `Event<CloudEvent>`.

## Scope

| Deliverable | Module | Description |
|-------------|--------|-------------|
| `TimedEntry<E>` (moved + label + qualifiedName) | simulation-core | Add label + qualifiedName, relocate from event-simulation-core |
| `TimedSequence<E>` (moved) | simulation-core | Relocate, unchanged API |
| `TemporalProfile<E>` | simulation-core | Sequence + name + qualifiedName + tenancyId + loop + speed |
| `TemporalSimulationDriver<E>` | simulation-core | Lifecycle controller with journal integration |
| `DriverResult` | simulation-core | Driver execution result |
| `DriverFailure` | simulation-core | Per-event failure record (index + label + cause) |
| `TemporalEventSink<E>` | simulation-core | Event delivery callback with context (qualifiedName, label, event) |
| `TemporalDriverFactory<E>` | simulation-core | Functional interface for driver creation |
| `TemporalProfileConfig` + parsing | simulation-config-core | YAML temporal profile schema + 4 source types |
| `TemporalProfileRegistry` | simulation-config-core | Resolved profile lookup |
| CDI `TemporalProfileRegistry` | simulation-config | `@Produces` bean |
| CDI `TemporalDriverFactory<Map<String, Object>>` | event-simulation | `@Produces` factory wired to CDI event bus (map → CloudEvent conversion) |
| Import updates | event-simulation-core | `EventSequenceRunner` + tests use new package |
| Unit tests | simulation-core, simulation-config-core | Driver lifecycle + YAML parsing |
| Integration test | event-simulation | `@QuarkusTest` CDI wiring |

## Deferred

| Item | Reason | Tracked |
|------|--------|---------|
| Pages scenario integration (start/stop/speed-change via `delivery: 'graphql'`) | Substantial cross-repo work spanning casehub-platform and casehub-pages. Requires ScenarioOrchestrator lifecycle hooks and new step types. | [casehubio/platform#372](https://github.com/casehubio/platform/issues/372) |
| Speed synchronization with global `SimulationConfig` | `SimulationConfig` has no speed setting today (`strategyFor`, `captureEnabled`, `exhaustionPolicy`, `threshold` only). Per-driver speed via `setSpeed()` is sufficient. Global speed coordination deferred until a `SimulationConfig.speed()` concept exists. | [casehubio/platform#373](https://github.com/casehubio/platform/issues/373) |

## References

- [platform#371](https://github.com/casehubio/platform/issues/371) — this issue
- [platform#326](https://github.com/casehubio/platform/issues/326) — timed event simulation (completed)
- [2026-09-16-timed-event-simulation-design.md](../feat-294-simulation-service/2026-09-16-timed-event-simulation-design.md) — prior TimedSequence/EventSequenceRunner spec
- [GE-20260701-82909e](https://github.com/casehubio/platform/issues/371) — ScheduledFuture cancel-clear-reschedule gotcha (motivated virtual-thread choice)
- [GE-20260915-0a4009](https://github.com/casehubio/platform/issues/371) — CDI @Decorator simulation flat interface requirement
- [GE-20260915-aa3b7f](https://github.com/casehubio/platform/issues/371) — Non-generic CDI registry pattern
- simulation-core/SimulationRuntime.java — overlay stack, journal recording
- simulation-core/SimulationProfile.java — composition pattern precedent
- simulation-config-core/YamlSimulationConfig.java — YAML parsing, inline + external corpus pattern
- event-simulation-core/EventSequenceRunner.java — Thread.sleep pattern, error isolation
- event-simulation-core/TimedEntry.java, TimedSequence.java — data model being extended
- D1-D6 in [decisions.md](decisions.md)
