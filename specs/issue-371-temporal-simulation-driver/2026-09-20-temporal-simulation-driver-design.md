# Temporal Simulation Driver Design Spec

**Branch:** issue-371-temporal-simulation-driver
**Issue:** casehubio/platform#371
**Date:** 2026-09-20

## Overview

Adds lifecycle-controlled temporal simulation to the simulation framework. The existing `EventSequenceRunner` is fire-and-forget and CloudEvent-specific. This issue fills six gaps: no lifecycle control (pause/resume/stop), no looping, no runtime speed changes, CloudEvent-specific runner, no YAML temporal profiles, and no journal integration for timed sequences.

The approach composes with existing types (`TimedEntry<E>`, `TimedSequence<E>`) rather than creating a parallel type hierarchy. The real new capability is the `TemporalSimulationDriver<E>` — a lifecycle controller that runs temporal profiles on virtual threads with pause/resume/stop/speed control and journal integration.

## Architecture

### Data Model Changes

**TimedEntry<E>** — gains optional `label` for per-event journal tracking:

```java
// moves from event-simulation-core to simulation-core
package io.casehub.platform.simulation;

public record TimedEntry<E>(E event, Duration delay, String label) {

    public TimedEntry(E event, Duration delay) {
        this(event, delay, null);
    }

    public TimedEntry {
        if (event == null) throw new IllegalArgumentException("event must not be null");
        if (delay == null) throw new IllegalArgumentException("delay must not be null");
        if (delay.isNegative()) throw new IllegalArgumentException("delay must not be negative");
    }
}
```

Labels like `"motion-cascade"` or `"temperature-drift"` are meaningful in journal verification (`SimulationVerifier` assertions). Positional tracking (`sequence[0]`) breaks on dynamic composition. Label is nullable for backward compatibility.

**TimedSequence<E>** — moves from `event-simulation-core` to `simulation-core` unchanged. `withMultiplier()`, `fromRecorded()`, `totalDuration()` carry over. The `withMultiplier()` transform preserves labels.

**TemporalProfile<E>** — new record wrapping TimedSequence with lifecycle metadata:

```java
package io.casehub.platform.simulation;

public record TemporalProfile<E>(
        String name,
        String qualifiedName,
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
- `qualifiedName` — method name for corpus/journal tracking (e.g. `"iot.device-state-change"`)
- `loop` — repeat after last event
- `speed` — initial speed multiplier (1.0 = real-time, 10.0 = 10x)

Design precedent: `SimulationProfile` wraps `SimulationConfig + SimulationCorpus`. `TemporalProfile` wraps `TimedSequence` with lifecycle metadata. Same composition pattern.

**EventSequenceRunner** stays in `event-simulation-core`. Import paths change for `TimedEntry`/`TimedSequence`. No API change — it remains the CloudEvent-specific one-shot runner.

### TemporalSimulationDriver

Lifecycle controller. Runs a `TemporalProfile` on a virtual thread with pause/resume/stop/speed control and journal integration.

**State machine:** `IDLE → RUNNING ↔ PAUSED → STOPPED`

```java
package io.casehub.platform.simulation;

public class TemporalSimulationDriver<E> {

    private final Consumer<E> eventSink;
    private final SimulationRuntime simulation;  // nullable — journal optional

    enum State { IDLE, RUNNING, PAUSED, STOPPED }

    public TemporalSimulationDriver(Consumer<E> eventSink, SimulationRuntime simulation);
    public TemporalSimulationDriver(Consumer<E> eventSink);  // no journal

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

**Key behaviors:**

1. **start()** — spawns a virtual thread. Iterates entries: `Thread.sleep(delay / speed)` → deliver to `eventSink` → record to journal. When `loop=true`, restarts from the beginning. Throws `IllegalStateException` on non-IDLE driver.

2. **pause()** — sets state to PAUSED. Driver thread blocks on a `ReentrantLock` `Condition`. No events fire while paused.

3. **resume()** — signals the condition, state returns to RUNNING. Sequence continues from where it paused.

4. **stop()** — sets state to STOPPED, interrupts the driver thread. Terminal — cannot restart.

5. **setSpeed(double)** — volatile field. Next sleep uses new value. Mid-sleep is not interrupted — change takes effect on next event.

6. **Journal integration** — if `SimulationRuntime` is provided, each event delivery calls `simulation.recordJournal(qualifiedName, tenancyId, label, event, true)`. This feeds `SimulationVerifier`.

7. **Error isolation** — one failing event delivery doesn't stop the sequence. Failure recorded in `DriverResult`. Same pattern as `EventSequenceRunner`.

**Thread model:** Virtual-thread `Thread.sleep()` — same pattern as `EventSequenceRunner`. Each driver runs its own virtual thread. Avoids ScheduledFuture cancel-clear-reschedule gotcha (GE-20260701-82909e). Virtual threads are cheap for simulation workloads.

**Thread safety:** State transitions via `synchronized`. Speed is volatile (single writer). Pause uses `ReentrantLock` + `Condition` for await/signal semantics.

**DriverResult:**

```java
public record DriverResult(
        int emittedCount,
        int failureCount,
        int loopIterations,
        List<EmissionFailure> failures) {

    public DriverResult {
        failures = List.copyOf(failures);
    }

    public boolean hasFailures() { return !failures.isEmpty(); }
}
```

Reuses `EmissionFailure` from event-simulation-core (or moves it to simulation-core alongside the driver).

**TemporalDriverFactory:**

```java
@FunctionalInterface
public interface TemporalDriverFactory<E> {
    TemporalSimulationDriver<E> create();
}
```

Drivers are lightweight (virtual thread + small state). Multiple profiles can run concurrently with separate driver instances. The factory pattern is cleaner than a reusable singleton since `stop()` is terminal.

### YAML Loading

**New types in simulation-config-core:**

```java
record TemporalProfileConfig(
        String qualifiedName,
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

**`sequence` resolution:** Recursive ref lookup with cycle detection (visited name set). Each ref resolves to a `TimedSequence`, concatenated in order. Optional `delay` on a ref inserts a gap `TimedEntry` between sub-sequences.

**Full YAML example:**

```yaml
temporal-profiles:
  morning-routine:
    qualified-name: iot.device-state-change
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

**event-simulation** — provides CloudEvent driver factory:

```java
// in EventSimulationBeans
@Produces @ApplicationScoped
TemporalDriverFactory<CloudEvent> temporalDriverFactory(SimulationRuntime runtime) {
    return () -> new TemporalSimulationDriver<>(
            event -> cloudEventBus.fireAsync(event),
            runtime);
}
```

Domains inject `TemporalDriverFactory` + `TemporalProfileRegistry`, call `factory.create()` to get a driver, then `driver.start(profile)`.

### Module Change Summary

| Module | Changes |
|--------|---------|
| `simulation-core` | + `TimedEntry` (moved), + `TimedSequence` (moved), + `TemporalProfile`, + `TemporalSimulationDriver`, + `DriverResult`, + `TemporalDriverFactory`, + `EmissionFailure` (moved or shared) |
| `event-simulation-core` | − `TimedEntry` (moved), − `TimedSequence` (moved), update imports in `EventSequenceRunner` + tests |
| `simulation-config-core` | + `TemporalProfileConfig`, + `TemporalEventConfig`, + `SequenceRef`, + temporal YAML parsing in `YamlSimulationConfig`, + `TemporalProfileRegistry` |
| `simulation-config` | + `@Produces TemporalProfileRegistry` in `SimulationConfigBeans` |
| `event-simulation` | + `@Produces TemporalDriverFactory<CloudEvent>` in `EventSimulationBeans` |

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
| `TemporalSimulationDriverTest` — journal | With SimulationRuntime, overlay journal records each event with label |
| `TemporalSimulationDriverTest` — error isolation | One failing event doesn't stop the sequence |

All driver tests use short delays (10-50ms). Timing assertions use tolerances.

### simulation-config-core (unit tests, no CDI)

| Test | What it verifies |
|------|-----------------|
| YAML inline events | Parses `events:` with delay/label/payload |
| YAML events-file | Resolves external file path |
| YAML from-corpus | Derives TimedSequence from corpus InvocationRecords |
| YAML sequence refs | Resolves refs, concatenates, inserts gap delays |
| YAML cycle detection | Circular `sequence:` refs → clear error |
| YAML mutual exclusivity | Two sources on one profile → parse error |
| YAML inline in profiles | `temporal:` within a profile — refs + inline |
| Duration parsing | `"5s"`, `"2m"`, `"500ms"`, bare millis |

### event-simulation-core

Existing `EventSequenceRunnerTest` and `TimedSequenceTest` — update imports after move. Verify nothing breaks.

### event-simulation (Quarkus integration)

`@QuarkusTest` verifying `TemporalDriverFactory<CloudEvent>` is injectable and produces a working driver wired to `Event<CloudEvent>`.

## Scope

| Deliverable | Module | Description |
|-------------|--------|-------------|
| `TimedEntry<E>` (moved + label) | simulation-core | Add label, relocate from event-simulation-core |
| `TimedSequence<E>` (moved) | simulation-core | Relocate, unchanged API |
| `TemporalProfile<E>` | simulation-core | Sequence + name + loop + qualifiedName + speed |
| `TemporalSimulationDriver<E>` | simulation-core | Lifecycle controller with journal integration |
| `DriverResult` | simulation-core | Driver execution result |
| `TemporalDriverFactory<E>` | simulation-core | Functional interface for driver creation |
| `TemporalProfileConfig` + parsing | simulation-config-core | YAML temporal profile schema + 4 source types |
| `TemporalProfileRegistry` | simulation-config-core | Resolved profile lookup |
| CDI `TemporalProfileRegistry` | simulation-config | `@Produces` bean |
| CDI `TemporalDriverFactory<CloudEvent>` | event-simulation | `@Produces` factory wired to CDI event bus |
| Import updates | event-simulation-core | `EventSequenceRunner` + tests use new package |
| Unit tests | simulation-core, simulation-config-core | Driver lifecycle + YAML parsing |
| Integration test | event-simulation | `@QuarkusTest` CDI wiring |

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
