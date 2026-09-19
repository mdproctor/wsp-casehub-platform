# Timed Event Simulation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #326 — feat: timed event simulation — scheduled triggers and delay sequences
**Issue group:** #312, #313, #314, #315, #327, #325, #320, #317, #318, #326

**Goal:** Add timing control to the event simulation framework — timed sequences with inter-event delays, a virtual-thread sequence runner, timing preservation from captured data, and the Quarkus CDI wiring module.

**Architecture:** Extend `event-simulation-core` with `TimedSequence<E>` (generic ordered sequence with relative delays and time multiplier) and `EventSequenceRunner` (virtual-thread executor). Create new `event-simulation` Quarkus module for CDI wiring: `@Produces` for `SimulatedEventEmitter` with `Event<CloudEvent>.fireAsync()` sink, and `@Scheduled` continuous tick.

**Tech Stack:** Java 21 (virtual threads), CloudEvents SDK, Quarkus CDI + Scheduler, JUnit 5, AssertJ.

## Global Constraints

- `event-simulation-core` remains POJO — no CDI, no Quarkus dependencies
- `event-simulation` is the Quarkus module — CDI, @Scheduled, Event<CloudEvent>
- Package: `io.casehub.platform.simulation.event` (core), `io.casehub.platform.simulation.event.quarkus` (Quarkus)
- Relative delays (Duration) — never negative, first entry can be Duration.ZERO
- Time multiplier must be positive (> 0)
- `Thread.sleep()` for delays — caller runs on virtual thread
- `@Scheduled` default is `OFF` — no emission unless configured

---

## Batch 1: TimedSequence + EventSequenceRunner (core)

### Task 1: TimedEntry + TimedSequence

**Files:**
- Create: `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/TimedEntry.java`
- Create: `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/TimedSequence.java`
- Test: `event-simulation-core/src/test/java/io/casehub/platform/simulation/event/TimedSequenceTest.java`

**Interfaces:**
- Consumes: `InvocationRecord<I, O>` (simulation-api — `recordedAt()` field)
- Produces: `TimedEntry<E>(E event, Duration delay)` — single entry with delay
- Produces: `TimedSequence<E>(List<TimedEntry<E>> entries)` — ordered sequence
- Produces: `TimedSequence.withMultiplier(double) → TimedSequence<E>` — scaled delays
- Produces: `TimedSequence.fromRecorded(List<InvocationRecord<I, O>>) → TimedSequence<O>` — factory from captured data
- Produces: `TimedSequence.totalDuration() → Duration`
- Produces: `TimedSequence.size() → int`

- [ ] **Step 1: Write failing tests**

Create `event-simulation-core/src/test/java/io/casehub/platform/simulation/event/TimedSequenceTest.java`:

```java
package io.casehub.platform.simulation.event;

import io.casehub.platform.simulation.InvocationRecord;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.time.Instant;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class TimedSequenceTest {

    @Test
    void timedEntryRejectsNullEvent() {
        assertThatThrownBy(() -> new TimedEntry<>(null, Duration.ZERO))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void timedEntryRejectsNegativeDelay() {
        assertThatThrownBy(() -> new TimedEntry<>("event", Duration.ofSeconds(-1)))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void emptySequence() {
        var seq = new TimedSequence<>(List.of());
        assertThat(seq.size()).isZero();
        assertThat(seq.totalDuration()).isEqualTo(Duration.ZERO);
    }

    @Test
    void sequencePreservesOrder() {
        var seq = new TimedSequence<>(List.of(
                new TimedEntry<>("A", Duration.ZERO),
                new TimedEntry<>("B", Duration.ofSeconds(5)),
                new TimedEntry<>("C", Duration.ofSeconds(30))));

        assertThat(seq.size()).isEqualTo(3);
        assertThat(seq.entries().get(0).event()).isEqualTo("A");
        assertThat(seq.entries().get(1).delay()).isEqualTo(Duration.ofSeconds(5));
        assertThat(seq.entries().get(2).delay()).isEqualTo(Duration.ofSeconds(30));
    }

    @Test
    void totalDurationSumsDelays() {
        var seq = new TimedSequence<>(List.of(
                new TimedEntry<>("A", Duration.ZERO),
                new TimedEntry<>("B", Duration.ofSeconds(5)),
                new TimedEntry<>("C", Duration.ofSeconds(30))));

        assertThat(seq.totalDuration()).isEqualTo(Duration.ofSeconds(35));
    }

    @Test
    void withMultiplierScalesDelays() {
        var seq = new TimedSequence<>(List.of(
                new TimedEntry<>("A", Duration.ofSeconds(10)),
                new TimedEntry<>("B", Duration.ofSeconds(30))));

        var fast = seq.withMultiplier(10.0);

        assertThat(fast.entries().get(0).delay()).isEqualTo(Duration.ofSeconds(1));
        assertThat(fast.entries().get(1).delay()).isEqualTo(Duration.ofSeconds(3));
        assertThat(fast.size()).isEqualTo(2);
    }

    @Test
    void withMultiplierRejectsZero() {
        var seq = new TimedSequence<>(List.of(new TimedEntry<>("A", Duration.ZERO)));
        assertThatThrownBy(() -> seq.withMultiplier(0))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void withMultiplierRejectsNegative() {
        var seq = new TimedSequence<>(List.of(new TimedEntry<>("A", Duration.ZERO)));
        assertThatThrownBy(() -> seq.withMultiplier(-1.0))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void fromRecordedDerivesTiming() {
        var records = List.of(
                new InvocationRecord<>("t1", null, "inputA", "outputA",
                        Instant.parse("2026-09-16T10:00:00Z")),
                new InvocationRecord<>("t1", null, "inputB", "outputB",
                        Instant.parse("2026-09-16T10:00:05Z")),
                new InvocationRecord<>("t1", null, "inputC", "outputC",
                        Instant.parse("2026-09-16T10:00:35Z")));

        var sequence = TimedSequence.<String, String>fromRecorded(records);

        assertThat(sequence.size()).isEqualTo(3);
        assertThat(sequence.entries().get(0).event()).isEqualTo("outputA");
        assertThat(sequence.entries().get(0).delay()).isEqualTo(Duration.ZERO);
        assertThat(sequence.entries().get(1).event()).isEqualTo("outputB");
        assertThat(sequence.entries().get(1).delay()).isEqualTo(Duration.ofSeconds(5));
        assertThat(sequence.entries().get(2).event()).isEqualTo("outputC");
        assertThat(sequence.entries().get(2).delay()).isEqualTo(Duration.ofSeconds(30));
    }

    @Test
    void fromRecordedSortsByTimestamp() {
        var records = List.of(
                new InvocationRecord<>("t1", null, "in2", "second",
                        Instant.parse("2026-09-16T10:00:10Z")),
                new InvocationRecord<>("t1", null, "in1", "first",
                        Instant.parse("2026-09-16T10:00:00Z")));

        var sequence = TimedSequence.<String, String>fromRecorded(records);

        assertThat(sequence.entries().get(0).event()).isEqualTo("first");
        assertThat(sequence.entries().get(1).event()).isEqualTo("second");
        assertThat(sequence.entries().get(1).delay()).isEqualTo(Duration.ofSeconds(10));
    }

    @Test
    void fromRecordedEmptyList() {
        var sequence = TimedSequence.<String, String>fromRecorded(List.of());
        assertThat(sequence.size()).isZero();
    }

    @Test
    void entriesListIsDefensivelyCopied() {
        var entries = new java.util.ArrayList<TimedEntry<String>>();
        entries.add(new TimedEntry<>("A", Duration.ZERO));
        var seq = new TimedSequence<>(entries);
        entries.add(new TimedEntry<>("B", Duration.ofSeconds(1)));
        assertThat(seq.size()).isEqualTo(1);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode -pl event-simulation-core test -Dtest=TimedSequenceTest`
Expected: FAIL — classes not found

- [ ] **Step 3: Implement TimedEntry**

Create `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/TimedEntry.java`:

```java
package io.casehub.platform.simulation.event;

import java.time.Duration;

public record TimedEntry<E>(E event, Duration delay) {

    public TimedEntry {
        if (event == null) {
            throw new IllegalArgumentException("event must not be null");
        }
        if (delay == null) {
            throw new IllegalArgumentException("delay must not be null");
        }
        if (delay.isNegative()) {
            throw new IllegalArgumentException("delay must not be negative");
        }
    }
}
```

- [ ] **Step 4: Implement TimedSequence**

Create `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/TimedSequence.java`:

```java
package io.casehub.platform.simulation.event;

import io.casehub.platform.simulation.InvocationRecord;

import java.time.Duration;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

public record TimedSequence<E>(List<TimedEntry<E>> entries) {

    public TimedSequence {
        entries = List.copyOf(entries);
    }

    public TimedSequence<E> withMultiplier(final double multiplier) {
        if (multiplier <= 0) {
            throw new IllegalArgumentException("multiplier must be positive");
        }
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

    public static <I, O> TimedSequence<O> fromRecorded(final List<InvocationRecord<I, O>> records) {
        if (records.isEmpty()) {
            return new TimedSequence<>(List.of());
        }

        final List<InvocationRecord<I, O>> sorted = records.stream()
                .sorted(Comparator.comparing(InvocationRecord::recordedAt))
                .toList();

        final List<TimedEntry<O>> entries = new ArrayList<>();
        entries.add(new TimedEntry<>(sorted.get(0).output(), Duration.ZERO));

        for (int i = 1; i < sorted.size(); i++) {
            Duration gap = Duration.between(
                    sorted.get(i - 1).recordedAt(),
                    sorted.get(i).recordedAt());
            if (gap.isNegative()) {
                gap = Duration.ZERO;
            }
            entries.add(new TimedEntry<>(sorted.get(i).output(), gap));
        }

        return new TimedSequence<>(entries);
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode -pl event-simulation-core test -Dtest=TimedSequenceTest`
Expected: all tests PASS

- [ ] **Step 6: Commit**

```bash
git add event-simulation-core/
git commit -m "feat(#326): TimedEntry + TimedSequence — timed event sequences

Generic ordered sequence with relative delays. withMultiplier() for
speed control. fromRecorded() derives timing from InvocationRecord
timestamps. 12 tests.

Refs #326

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: EventSequenceRunner + SequenceResult

**Files:**
- Create: `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/SequenceResult.java`
- Create: `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/EventSequenceRunner.java`
- Test: `event-simulation-core/src/test/java/io/casehub/platform/simulation/event/EventSequenceRunnerTest.java`

**Interfaces:**
- Consumes: `TimedSequence<CloudEvent>`, `TimedEntry<CloudEvent>` (Task 1)
- Consumes: `EmittedEvent`, `EmissionFailure` (from #318)
- Consumes: `CloudEventBuilder.from(event).withId(...).withTime(...)` (cloudevents-core)
- Produces: `SequenceResult(List<EmittedEvent> emitted, List<EmissionFailure> failures)` — result type with `hasFailures()`, `emittedCount()`
- Produces: `EventSequenceRunner(Consumer<CloudEvent> eventSink)` — constructor
- Produces: `EventSequenceRunner.run(TimedSequence<CloudEvent>) → SequenceResult` — blocking execution with Thread.sleep between events

- [ ] **Step 1: Write failing tests**

Create `event-simulation-core/src/test/java/io/casehub/platform/simulation/event/EventSequenceRunnerTest.java`:

```java
package io.casehub.platform.simulation.event;

import io.cloudevents.CloudEvent;
import io.cloudevents.core.builder.CloudEventBuilder;
import org.junit.jupiter.api.Test;

import java.net.URI;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class EventSequenceRunnerTest {

    @Test
    void runExecutesSequenceInOrder() throws InterruptedException {
        List<CloudEvent> emitted = new ArrayList<>();
        var runner = new EventSequenceRunner(emitted::add);

        var sequence = new TimedSequence<>(List.of(
                new TimedEntry<>(makeEvent("A"), Duration.ZERO),
                new TimedEntry<>(makeEvent("B"), Duration.ofMillis(10)),
                new TimedEntry<>(makeEvent("C"), Duration.ofMillis(10))));

        SequenceResult result = runner.run(sequence);

        assertThat(result.emittedCount()).isEqualTo(3);
        assertThat(result.hasFailures()).isFalse();
        assertThat(emitted).hasSize(3);
    }

    @Test
    void runStampsFreshIdPerEvent() throws InterruptedException {
        List<CloudEvent> emitted = new ArrayList<>();
        var runner = new EventSequenceRunner(emitted::add);

        CloudEvent template = makeEvent("same");
        var sequence = new TimedSequence<>(List.of(
                new TimedEntry<>(template, Duration.ZERO),
                new TimedEntry<>(template, Duration.ZERO)));

        runner.run(sequence);

        assertThat(emitted.get(0).getId()).isNotEqualTo(emitted.get(1).getId());
        assertThat(emitted.get(0).getTime()).isNotNull();
        assertThat(emitted.get(1).getTime()).isNotNull();
    }

    @Test
    void runIsolatesPerEventErrors() throws InterruptedException {
        List<CloudEvent> emitted = new ArrayList<>();
        var runner = new EventSequenceRunner(event -> {
            if (event.getType().equals("fail.event")) {
                throw new RuntimeException("deliberate failure");
            }
            emitted.add(event);
        });

        var sequence = new TimedSequence<>(List.of(
                new TimedEntry<>(makeEvent("ok"), Duration.ZERO),
                new TimedEntry<>(makeEventWithType("fail.event"), Duration.ZERO),
                new TimedEntry<>(makeEvent("also-ok"), Duration.ZERO)));

        SequenceResult result = runner.run(sequence);

        assertThat(result.emittedCount()).isEqualTo(2);
        assertThat(result.hasFailures()).isTrue();
        assertThat(result.failures()).hasSize(1);
        assertThat(emitted).hasSize(2);
    }

    @Test
    void runEmptySequence() throws InterruptedException {
        List<CloudEvent> emitted = new ArrayList<>();
        var runner = new EventSequenceRunner(emitted::add);

        SequenceResult result = runner.run(new TimedSequence<>(List.of()));

        assertThat(result.emittedCount()).isZero();
        assertThat(result.hasFailures()).isFalse();
    }

    @Test
    void runRespectsDelays() throws InterruptedException {
        List<Long> timestamps = new ArrayList<>();
        var runner = new EventSequenceRunner(event -> timestamps.add(System.nanoTime()));

        var sequence = new TimedSequence<>(List.of(
                new TimedEntry<>(makeEvent("A"), Duration.ZERO),
                new TimedEntry<>(makeEvent("B"), Duration.ofMillis(100))));

        runner.run(sequence);

        assertThat(timestamps).hasSize(2);
        long gapMs = (timestamps.get(1) - timestamps.get(0)) / 1_000_000;
        assertThat(gapMs).isGreaterThanOrEqualTo(80);
    }

    @Test
    void sequenceResultReports() {
        var result = new SequenceResult(List.of(), List.of());
        assertThat(result.hasFailures()).isFalse();
        assertThat(result.emittedCount()).isZero();
    }

    // --- helpers ---

    private static CloudEvent makeEvent(String id) {
        return CloudEventBuilder.v1()
                .withId(id)
                .withType("test.event")
                .withSource(URI.create("/test"))
                .withExtension("tenancyid", "t1")
                .build();
    }

    private static CloudEvent makeEventWithType(String type) {
        return CloudEventBuilder.v1()
                .withId("id")
                .withType(type)
                .withSource(URI.create("/test"))
                .withExtension("tenancyid", "t1")
                .build();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode -pl event-simulation-core test -Dtest=EventSequenceRunnerTest`
Expected: FAIL — classes not found

- [ ] **Step 3: Implement SequenceResult**

Create `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/SequenceResult.java`:

```java
package io.casehub.platform.simulation.event;

import java.util.List;

public record SequenceResult(
        List<EmittedEvent> emitted,
        List<EmissionFailure> failures) {

    public SequenceResult {
        emitted = List.copyOf(emitted);
        failures = List.copyOf(failures);
    }

    public boolean hasFailures() {
        return !failures.isEmpty();
    }

    public int emittedCount() {
        return emitted.size();
    }
}
```

- [ ] **Step 4: Implement EventSequenceRunner**

Create `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/EventSequenceRunner.java`:

```java
package io.casehub.platform.simulation.event;

import io.cloudevents.CloudEvent;
import io.cloudevents.core.builder.CloudEventBuilder;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.function.Consumer;

public class EventSequenceRunner {

    private final Consumer<CloudEvent> eventSink;

    public EventSequenceRunner(final Consumer<CloudEvent> eventSink) {
        this.eventSink = eventSink;
    }

    public SequenceResult run(final TimedSequence<CloudEvent> sequence) throws InterruptedException {
        final List<EmittedEvent> emitted = new ArrayList<>();
        final List<EmissionFailure> failures = new ArrayList<>();

        for (int i = 0; i < sequence.size(); i++) {
            final TimedEntry<CloudEvent> entry = sequence.entries().get(i);

            if (!entry.delay().isZero()) {
                Thread.sleep(entry.delay());
            }

            try {
                final CloudEvent stamped = CloudEventBuilder.from(entry.event())
                        .withId(UUID.randomUUID().toString())
                        .withTime(OffsetDateTime.now())
                        .build();
                eventSink.accept(stamped);
                emitted.add(new EmittedEvent("sequence[" + i + "]", stamped));
            } catch (final Exception e) {
                failures.add(new EmissionFailure("sequence[" + i + "]", e));
            }
        }

        return new SequenceResult(emitted, failures);
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode -pl event-simulation-core test`
Expected: all tests PASS (including Task 1 tests)

- [ ] **Step 6: Commit**

```bash
git add event-simulation-core/
git commit -m "feat(#326): EventSequenceRunner — virtual-thread sequence executor

Executes TimedSequence<CloudEvent> with Thread.sleep() between events.
Stamps fresh id/time per emission. Per-event error isolation. 6 tests.

Refs #326

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 2: Quarkus CDI module (event-simulation)

### Task 3: event-simulation module — CDI wiring + @Scheduled

**Files:**
- Create: `event-simulation/pom.xml`
- Modify: `pom.xml` (add `<module>event-simulation</module>`)
- Create: `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/EventSimulationBeans.java`
- Create: `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/EventSimulationScheduler.java`
- Test: `event-simulation/src/test/java/io/casehub/platform/simulation/event/quarkus/EventSimulationBeansTest.java`

**Interfaces:**
- Consumes: `SimulatedEventEmitter(SimulationRuntime, Consumer<CloudEvent>, List<EventSourceConfig>)` (from #318)
- Consumes: `EventSequenceRunner(Consumer<CloudEvent>)` (Task 2)
- Consumes: `SimulationRuntime` (from simulation-config CDI bean)
- Consumes: `Event<CloudEvent>` (CDI event bus)
- Produces: `@Produces @ApplicationScoped SimulatedEventEmitter` — wired to CDI event bus
- Produces: `@Produces @ApplicationScoped EventSequenceRunner` — wired to CDI event bus
- Produces: `EventSimulationScheduler` — @Scheduled tick() wrapper

- [ ] **Step 1: Create module POM**

Create `event-simulation/pom.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-event-simulation</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Event Simulation</name>
    <description>Quarkus CDI wiring for event simulation — @Produces SimulatedEventEmitter
        with Event&lt;CloudEvent&gt;.fireAsync() sink, @Scheduled continuous tick,
        EventSequenceRunner producer.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-event-simulation-core</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-config</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.cloudevents</groupId>
            <artifactId>cloudevents-core</artifactId>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-arc</artifactId>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-scheduler</artifactId>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-junit5</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

</project>
```

- [ ] **Step 2: Add module to parent POM**

Add `<module>event-simulation</module>` after `<module>event-simulation-core</module>` in the parent `pom.xml`.

- [ ] **Step 3: Create source directories**

```bash
mkdir -p event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus
mkdir -p event-simulation/src/test/java/io/casehub/platform/simulation/event/quarkus
mkdir -p event-simulation/src/test/resources
```

- [ ] **Step 4: Implement EventSimulationBeans**

Create `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/EventSimulationBeans.java`:

```java
package io.casehub.platform.simulation.event.quarkus;

import io.casehub.platform.simulation.SimulationRuntime;
import io.casehub.platform.simulation.event.EventSequenceRunner;
import io.casehub.platform.simulation.event.EventSourceConfig;
import io.casehub.platform.simulation.event.SimulatedEventEmitter;
import io.cloudevents.CloudEvent;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Event;
import jakarta.enterprise.inject.Produces;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.ConfigProvider;

import java.util.ArrayList;
import java.util.List;

@ApplicationScoped
public class EventSimulationBeans {

    @Inject
    Event<CloudEvent> cloudEventBus;

    @Inject
    SimulationRuntime simulation;

    @Produces
    @ApplicationScoped
    public SimulatedEventEmitter emitter() {
        final List<EventSourceConfig> sources = loadSourcesFromConfig();
        return new SimulatedEventEmitter(
                simulation,
                event -> cloudEventBus.fireAsync(event),
                sources);
    }

    @Produces
    @ApplicationScoped
    public EventSequenceRunner sequenceRunner() {
        return new EventSequenceRunner(
                event -> cloudEventBus.fireAsync(event));
    }

    private List<EventSourceConfig> loadSourcesFromConfig() {
        final var config = ConfigProvider.getConfig();
        final List<EventSourceConfig> sources = new ArrayList<>();
        final String prefix = "casehub.simulation.event.sources.";

        for (final String name : config.getPropertyNames()) {
            if (name.startsWith(prefix) && name.endsWith(".event-type")) {
                final String sourceName = name.substring(prefix.length(),
                        name.length() - ".event-type".length());
                final String eventType = config.getValue(name, String.class);
                final String tenancyId = config.getOptionalValue(
                        prefix + sourceName + ".tenancy-id", String.class)
                        .orElse("default");
                final String qualifiedName = "event-emitter." + sourceName;
                sources.add(new EventSourceConfig(qualifiedName, eventType, tenancyId));
            }
        }

        return sources;
    }
}
```

- [ ] **Step 5: Implement EventSimulationScheduler**

Create `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/EventSimulationScheduler.java`:

```java
package io.casehub.platform.simulation.event.quarkus;

import io.casehub.platform.simulation.event.SimulatedEventEmitter;
import io.quarkus.scheduler.Scheduled;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;

@ApplicationScoped
public class EventSimulationScheduler {

    private static final Logger LOG = Logger.getLogger(EventSimulationScheduler.class);

    @Inject
    SimulatedEventEmitter emitter;

    @Scheduled(every = "${casehub.simulation.event.interval:OFF}",
               identity = "event-simulation-tick")
    void tick() {
        var result = emitter.tick();
        if (result.emittedCount() > 0) {
            LOG.debugf("Event simulation tick: emitted %d event(s)", result.emittedCount());
        }
        if (result.hasFailures()) {
            result.failures().forEach(f ->
                    LOG.warnf(f.cause(), "Event simulation emission failed for %s",
                            f.qualifiedName()));
        }
    }
}
```

- [ ] **Step 6: Write test**

Create `event-simulation/src/test/java/io/casehub/platform/simulation/event/quarkus/EventSimulationBeansTest.java`:

```java
package io.casehub.platform.simulation.event.quarkus;

import io.casehub.platform.simulation.event.EventSequenceRunner;
import io.casehub.platform.simulation.event.SimulatedEventEmitter;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

@QuarkusTest
class EventSimulationBeansTest {

    @Inject
    SimulatedEventEmitter emitter;

    @Inject
    EventSequenceRunner sequenceRunner;

    @Test
    void emitterIsProduced() {
        assertThat(emitter).isNotNull();
    }

    @Test
    void sequenceRunnerIsProduced() {
        assertThat(sequenceRunner).isNotNull();
    }

    @Test
    void tickWithNoStrategyEmitsNothing() {
        var result = emitter.tick();
        assertThat(result.emittedCount()).isZero();
        assertThat(result.hasFailures()).isFalse();
    }
}
```

Create `event-simulation/src/test/resources/application.properties`:

```properties
# Disable scheduled tick in tests
casehub.simulation.event.interval=OFF
```

- [ ] **Step 7: Run tests**

Run: `mvn --batch-mode -pl event-simulation test`
Expected: all tests PASS

- [ ] **Step 8: Run full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 9: Commit**

```bash
git add event-simulation/ pom.xml
git commit -m "feat(#326): event-simulation Quarkus module — CDI wiring + @Scheduled

@Produces SimulatedEventEmitter with Event<CloudEvent>.fireAsync() sink.
@Produces EventSequenceRunner. @Scheduled tick with configurable interval
(OFF by default). Config-driven EventSourceConfig loading from
casehub.simulation.event.sources.* properties.

Refs #326

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4: Documentation — update simulation guide + CLAUDE.md

**Files:**
- Modify: `docs/guides/simulation-guide.md` (add timed sequence section)
- Modify: `CLAUDE.md` (add event-simulation module entry, update event-simulation-core entry)

**Interfaces:**
- Consumes: all types from Tasks 1-3

- [ ] **Step 1: Update simulation guide — add timed sequences section**

In `docs/guides/simulation-guide.md`, add after the "Tenant context" subsection in the Event simulation section:

```markdown
### Timed sequences

`TimedSequence<E>` provides ordered events with relative delays:

```java
var sequence = new TimedSequence<>(List.of(
        new TimedEntry<>(eventA, Duration.ZERO),
        new TimedEntry<>(eventB, Duration.ofSeconds(5)),
        new TimedEntry<>(eventC, Duration.ofSeconds(30))));

// 10x speed — 35s becomes 3.5s
var fast = sequence.withMultiplier(10.0);
```

Build from captured data — timing derived from `InvocationRecord.recordedAt()`:

```java
var sequence = TimedSequence.fromRecorded(capturedRecords);
var demo = sequence.withMultiplier(100.0); // 30 minutes → 18 seconds
```

Execute with `EventSequenceRunner` (sleeps between events on virtual thread):

```java
var runner = new EventSequenceRunner(event -> cloudEventBus.fireAsync(event));
SequenceResult result = runner.run(sequence);
assertThat(result.emittedCount()).isEqualTo(3);
```

### Continuous emission

Add the `event-simulation` module and configure:

```properties
casehub.simulation.event.interval=10s
casehub.simulation.event.sources.workitem-completed.event-type=io.casehub.work.workitem.completed
casehub.simulation.event.sources.workitem-completed.tenancy-id=default
casehub.simulation.event-emitter.workitem-completed.strategy=sequential
```

The scheduler calls `emitter.tick()` on the configured interval. Set
`interval=OFF` (default) to disable.
```

- [ ] **Step 2: Update CLAUDE.md — add event-simulation module, update event-simulation-core**

Add after the `event-simulation-core` entry in the module table:

```markdown
| `event-simulation/` | `casehub-platform-event-simulation` | Quarkus CDI wiring for event simulation — @Produces SimulatedEventEmitter with Event<CloudEvent>.fireAsync() sink, @Produces EventSequenceRunner, @Scheduled continuous tick (casehub.simulation.event.interval, OFF by default). Config-driven EventSourceConfig loading from casehub.simulation.event.sources.* properties. No quarkus:build goal |
```

Update the `event-simulation-core` description to include TimedSequence:

In the existing entry, append: `, TimedEntry<E> + TimedSequence<E> (generic timed sequences with relative delays, withMultiplier, fromRecorded), EventSequenceRunner (virtual-thread sequence executor)`

Update the New modules list to include `event-simulation`.

- [ ] **Step 3: Update "What's next" section — mark timed simulation as done**

In the "What's next" section of `docs/guides/simulation-guide.md`, remove the "Timed event simulation" bullet.

- [ ] **Step 4: Commit**

```bash
git add docs/guides/simulation-guide.md CLAUDE.md
git commit -m "docs(#326): add timed sequences and CDI wiring to guide and CLAUDE.md

Refs #326

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## References

- [2026-09-16-timed-event-simulation-design.md] — design spec this plan implements
- [2026-09-16-event-simulation-design.md] — #318 spec (foundation)
- SimulatedEventEmitter.java — tick() emitter from #318
- EventTrigger.java, EventSourceConfig.java, EmissionResult.java — #318 types
- CloudEventFixtureBuilder.java — Map ↔ CloudEvent from #318
- SimulationConfigBeans.java — CDI producer pattern for simulation beans
- CapacityPressureMonitor.java:43-44 — @Scheduled annotation pattern
- InvocationRecord.java — recordedAt field for timing derivation
- PolicyEnforcer.java — virtual-thread executor precedent
- simulation-config/pom.xml — Quarkus module POM pattern
- [GitHub #326] — feat: timed event simulation
- [GitHub #318] — event simulation core (completed)
