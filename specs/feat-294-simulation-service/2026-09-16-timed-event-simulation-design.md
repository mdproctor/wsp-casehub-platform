# Timed Event Simulation Design Spec

**Branch:** issue-294-simulation-service
**Issue:** casehubio/platform#326
**Date:** 2026-09-16

## Overview

Adds timing control to the event simulation framework. Where #318 built the `SimulatedEventEmitter` (what to emit and how to inject), this issue adds when — timed sequences with inter-event delays, a virtual-thread scheduler that executes sequences, timing preservation from captured data, and the Quarkus CDI wiring module (`event-simulation`) that was deferred from #318.

Three deliverables: (1) `TimedSequence<E>` data model with relative delays and time multiplier, (2) `EventSequenceRunner` that executes a timed sequence with virtual-thread sleep between events, (3) the `event-simulation` Quarkus module wiring `SimulatedEventEmitter` with `Event<CloudEvent>.fireAsync()` and `@Scheduled` continuous emission.

## Architecture

### TimedSequence

A generic ordered sequence of events with relative delays between them:

```java
package io.casehub.platform.simulation.event;

public record TimedEntry<E>(E event, Duration delay) {
    public TimedEntry {
        if (event == null) throw new IllegalArgumentException("event must not be null");
        if (delay == null) throw new IllegalArgumentException("delay must not be null");
        if (delay.isNegative()) throw new IllegalArgumentException("delay must not be negative");
    }
}

public record TimedSequence<E>(List<TimedEntry<E>> entries) {
    public TimedSequence {
        entries = List.copyOf(entries);
    }

    public TimedSequence<E> withMultiplier(double multiplier) {
        if (multiplier <= 0) throw new IllegalArgumentException("multiplier must be positive");
        return new TimedSequence<>(entries.stream()
                .map(e -> new TimedEntry<>(e.event(),
                        Duration.ofMillis((long) (e.delay().toMillis() / multiplier))))
                .toList());
    }

    public Duration totalDuration() {
        return entries.stream()
                .map(TimedEntry::delay)
                .reduce(Duration.ZERO, Duration::plus);
    }

    public int size() {
        return entries.size();
    }

    public static <I, O> TimedSequence<O> fromRecorded(List<InvocationRecord<I, O>> records) {
        if (records.isEmpty()) return new TimedSequence<>(List.of());

        List<InvocationRecord<I, O>> sorted = records.stream()
                .sorted(Comparator.comparing(InvocationRecord::recordedAt))
                .toList();

        List<TimedEntry<O>> entries = new ArrayList<>();
        entries.add(new TimedEntry<>(sorted.get(0).output(), Duration.ZERO));

        for (int i = 1; i < sorted.size(); i++) {
            Duration gap = Duration.between(
                    sorted.get(i - 1).recordedAt(),
                    sorted.get(i).recordedAt());
            if (gap.isNegative()) gap = Duration.ZERO;
            entries.add(new TimedEntry<>(sorted.get(i).output(), gap));
        }

        return new TimedSequence<>(entries);
    }
}
```

Key design points:

1. **Generic `<E>`** — works with CloudEvent, AgentEvent, or any event type. Not tied to the event simulation infrastructure.
2. **Relative delays** (D27) — each entry's delay is the wait time since the previous event. First entry's delay is zero (or an initial wait if specified).
3. **`withMultiplier(double)`** (D31) — returns a new sequence with all delays divided by the multiplier. `withMultiplier(10.0)` on a 30-minute case gives 3 minutes. Pure data transform — the scheduler doesn't know about multipliers.
4. **`fromRecorded()`** (D30) — factory method that derives timing from `InvocationRecord.recordedAt()` timestamps. Sorts by recordedAt, computes gaps. No changes to InvocationRecord or capture infrastructure.

### EventSequenceRunner

Executes a `TimedSequence<CloudEvent>` with virtual-thread sleep between events:

```java
package io.casehub.platform.simulation.event;

public class EventSequenceRunner {
    private final Consumer<CloudEvent> eventSink;

    public EventSequenceRunner(Consumer<CloudEvent> eventSink) {
        this.eventSink = eventSink;
    }

    public SequenceResult run(TimedSequence<CloudEvent> sequence) throws InterruptedException {
        List<EmittedEvent> emitted = new ArrayList<>();
        List<EmissionFailure> failures = new ArrayList<>();

        for (int i = 0; i < sequence.size(); i++) {
            TimedEntry<CloudEvent> entry = sequence.entries().get(i);

            if (!entry.delay().isZero()) {
                Thread.sleep(entry.delay());
            }

            try {
                CloudEvent stamped = CloudEventBuilder.from(entry.event())
                        .withId(UUID.randomUUID().toString())
                        .withTime(OffsetDateTime.now())
                        .build();
                eventSink.accept(stamped);
                emitted.add(new EmittedEvent("sequence[" + i + "]", stamped));
            } catch (Exception e) {
                failures.add(new EmissionFailure("sequence[" + i + "]", e));
            }
        }

        return new SequenceResult(emitted, failures);
    }
}
```

Key design points:

1. **Virtual-thread sleep** (D28) — `Thread.sleep(delay)` between events. The caller is responsible for running this on a virtual thread (the Quarkus module handles this via `Executors.newVirtualThreadPerTaskExecutor()`).
2. **InterruptedException propagation** — sleep is interruptible. Cancellation is a thread interrupt. The caller catches `InterruptedException` to handle cancellation.
3. **Per-event id/time stamping** — same pattern as `SimulatedEventEmitter.tick()`. Corpus stores templates; runner stamps fresh id/time per emission.
4. **Per-event error isolation** — one failing event doesn't stop the sequence. Follows the same pattern as `SimulatedEventEmitter.tick()`.

### SequenceResult

```java
public record SequenceResult(
        List<EmittedEvent> emitted,
        List<EmissionFailure> failures) {

    public SequenceResult {
        emitted = List.copyOf(emitted);
        failures = List.copyOf(failures);
    }

    public boolean hasFailures() { return !failures.isEmpty(); }
    public int emittedCount() { return emitted.size(); }
    public boolean isComplete() { return true; }
}
```

Reuses `EmittedEvent` and `EmissionFailure` from #318.

### Module structure

**`event-simulation-core`** (existing, extend):
- Add: `TimedEntry<E>` — record with event + delay
- Add: `TimedSequence<E>` — ordered sequence with `withMultiplier()`, `fromRecorded()`, `totalDuration()`
- Add: `EventSequenceRunner` — virtual-thread-based sequence executor
- Add: `SequenceResult` — execution result

**`event-simulation`** (new Quarkus module):
- `EventSimulationBeans` — `@Produces` for `SimulatedEventEmitter` wired to `Event<CloudEvent>.fireAsync()`, reads `EventSourceConfig` from `casehub.simulation.event.*` properties
- `EventSimulationScheduler` — `@Scheduled` bean that calls `emitter.tick()` on a configurable interval for continuous background emission
- `EventSequenceService` — `@ApplicationScoped` service that runs `EventSequenceRunner` on virtual threads, manages active sequences

Dependencies for `event-simulation`:
- `event-simulation-core` (SimulatedEventEmitter, TimedSequence, EventSequenceRunner)
- `simulation-core` (SimulationRuntime)
- `simulation-config` (runtime, config, corpus beans)
- `quarkus-scheduler` (for @Scheduled)
- `quarkus-arc` (for CDI)

### Quarkus CDI wiring

`EventSimulationBeans`:

```java
@ApplicationScoped
public class EventSimulationBeans {
    @Inject Event<CloudEvent> cloudEventBus;
    @Inject SimulationRuntime simulation;

    @Produces @ApplicationScoped
    SimulatedEventEmitter emitter() {
        List<EventSourceConfig> sources = loadSourcesFromConfig();
        return new SimulatedEventEmitter(
                simulation,
                event -> cloudEventBus.fireAsync(event),
                sources);
    }

    @Produces @ApplicationScoped
    EventSequenceRunner sequenceRunner() {
        return new EventSequenceRunner(
                event -> cloudEventBus.fireAsync(event));
    }

    private List<EventSourceConfig> loadSourcesFromConfig() {
        // Read casehub.simulation.event.* properties
        // Each key pattern: casehub.simulation.event.<name>.event-type + .tenancy-id
        // Build EventSourceConfig(qualifiedName="event-emitter.<name>", eventType, tenancyId)
    }
}
```

`EventSimulationScheduler`:

```java
@ApplicationScoped
public class EventSimulationScheduler {
    @Inject SimulatedEventEmitter emitter;

    @Scheduled(every = "${casehub.simulation.event.interval:OFF}",
               identity = "event-simulation-tick")
    void tick() {
        emitter.tick();
    }
}
```

Uses `OFF` as default — the scheduler is inactive unless `casehub.simulation.event.interval` is configured. This follows the platform pattern where simulation activates only with explicit config.

### Configuration

```properties
# Continuous emission (calls tick() on interval)
casehub.simulation.event.interval=10s

# Event source definitions
casehub.simulation.event.sources.workitem-completed.event-type=io.casehub.work.workitem.completed
casehub.simulation.event.sources.workitem-completed.tenancy-id=default

casehub.simulation.event.sources.capacity-pressure.event-type=io.casehub.capacity.pressure
casehub.simulation.event.sources.capacity-pressure.tenancy-id=default

# Strategy for each source (uses existing simulation.* namespace)
casehub.simulation.event-emitter.workitem-completed.strategy=sequential
casehub.simulation.event-emitter.capacity-pressure.strategy=key-lookup

# Corpus files (loaded by simulation-config)
casehub.simulation.corpus.files=classpath:simulation/events.yaml
```

### Testing

**TimedSequence** — pure unit tests, no CDI:

```java
@Test
void fromRecordedDerivesTiming() {
    var records = List.of(
            new InvocationRecord<>("t1", null, trigger, eventA,
                    Instant.parse("2026-09-16T10:00:00Z")),
            new InvocationRecord<>("t1", null, trigger, eventB,
                    Instant.parse("2026-09-16T10:00:05Z")),
            new InvocationRecord<>("t1", null, trigger, eventC,
                    Instant.parse("2026-09-16T10:00:35Z")));

    var sequence = TimedSequence.fromRecorded(records);

    assertThat(sequence.size()).isEqualTo(3);
    assertThat(sequence.entries().get(0).delay()).isEqualTo(Duration.ZERO);
    assertThat(sequence.entries().get(1).delay()).isEqualTo(Duration.ofSeconds(5));
    assertThat(sequence.entries().get(2).delay()).isEqualTo(Duration.ofSeconds(30));
}

@Test
void withMultiplierScalesDelays() {
    var sequence = new TimedSequence<>(List.of(
            new TimedEntry<>("A", Duration.ofSeconds(10)),
            new TimedEntry<>("B", Duration.ofSeconds(30))));

    var fast = sequence.withMultiplier(10.0);

    assertThat(fast.entries().get(0).delay()).isEqualTo(Duration.ofSeconds(1));
    assertThat(fast.entries().get(1).delay()).isEqualTo(Duration.ofSeconds(3));
}
```

**EventSequenceRunner** — unit tests with short delays:

```java
@Test
void runExecutesSequenceInOrder() throws InterruptedException {
    List<CloudEvent> emitted = new ArrayList<>();
    var runner = new EventSequenceRunner(emitted::add);

    var sequence = new TimedSequence<>(List.of(
            new TimedEntry<>(eventA, Duration.ZERO),
            new TimedEntry<>(eventB, Duration.ofMillis(50)),
            new TimedEntry<>(eventC, Duration.ofMillis(50))));

    SequenceResult result = runner.run(sequence);

    assertThat(result.emittedCount()).isEqualTo(3);
    assertThat(emitted).hasSize(3);
}
```

**EventSimulationScheduler** — `@QuarkusTest` with application.properties configuring the interval and corpus.

## Scope

This issue (#326) delivers:

| Deliverable | Module | Description |
|-------------|--------|-------------|
| `TimedEntry<E>` | event-simulation-core | Record: event + delay |
| `TimedSequence<E>` | event-simulation-core | Ordered sequence with multiplier, fromRecorded() |
| `EventSequenceRunner` | event-simulation-core | Virtual-thread sequence executor |
| `SequenceResult` | event-simulation-core | Runner result type |
| `EventSimulationBeans` | event-simulation | CDI wiring — @Produces emitter + runner |
| `EventSimulationScheduler` | event-simulation | @Scheduled continuous tick() |
| Unit tests | both | TimedSequence + runner + scheduler tests |

## References

- [platform#326](https://github.com/casehubio/platform/issues/326) — this issue
- [platform#318](https://github.com/casehubio/platform/issues/318) — event simulation core (completed)
- [2026-09-16-event-simulation-design.md](2026-09-16-event-simulation-design.md) — #318 spec
- D26-D31 — decisions captured for this issue
- D8 — unified contract for request/response and events
- D23 — tick() pattern (SimulatedEventEmitter)
- SimulatedEventEmitter.java — tick() emitter (just built)
- CapacityPressureMonitor.java — @Scheduled pattern precedent
- PolicyEnforcer.java — virtual-thread executor precedent
- InvocationRecord.java — recordedAt field for timing derivation
- simulation-config/ — @Produces SimulationRuntime, @Startup corpus populator
