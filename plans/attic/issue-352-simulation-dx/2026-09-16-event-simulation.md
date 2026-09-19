# Event Simulation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #318 — feat: event simulation — push-side strategies for CDI and CloudEvents
**Issue group:** #312, #313, #314, #315, #327, #325, #320, #317, #318

**Goal:** Build a push-side event emitter that generates synthetic CloudEvents from a simulation corpus and injects them into the CDI event bus for end-to-end pipeline testing.

**Architecture:** New `event-simulation-core` module (POJO, no CDI) containing `SimulatedEventEmitter` with a `tick()` method. The emitter iterates configured event sources, resolves CloudEvents from the existing `SimulationStrategy<EventTrigger, CloudEvent>` framework, stamps per-invocation id/time, and fires via a `Consumer<CloudEvent>` callback. Tests use `InMemorySimulationCorpus` and a collecting list as the sink.

**Tech Stack:** Java 21, CloudEvents SDK (`io.cloudevents:cloudevents-core`), Jackson (`jackson-databind`) for CloudEvent fixture serialisation, JUnit 5, AssertJ.

## Global Constraints

- No CDI, no Quarkus dependencies in event-simulation-core — constructor-injected POJOs only
- CloudEvent `tenancyid` extension is mandatory — DataSourceRouter silently skips events without it
- Per-invocation `id` (UUID) and `time` (OffsetDateTime.now()) must be stamped by the emitter, not stored in corpus
- Module follows `*-core` naming convention (GE-20260909-c81437)
- Package: `io.casehub.platform.simulation.event`

---

## Batch 1: Records + CloudEventFixtureBuilder

### Task 1: Module scaffold + EventTrigger + EventSourceConfig + result records

**Files:**
- Create: `event-simulation-core/pom.xml`
- Modify: `pom.xml` (add `<module>event-simulation-core</module>`)
- Create: `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/EventTrigger.java`
- Create: `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/EventSourceConfig.java`
- Create: `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/EmittedEvent.java`
- Create: `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/EmissionFailure.java`
- Create: `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/EmissionResult.java`
- Test: `event-simulation-core/src/test/java/io/casehub/platform/simulation/event/EventTriggerTest.java`

**Interfaces:**
- Produces: `EventTrigger(String eventType, String tenancyId, Map<String, Object> context)` — input record for event strategies
- Produces: `EventSourceConfig(String qualifiedName, String eventType, String tenancyId)` — per-source configuration
- Produces: `EmittedEvent(String qualifiedName, CloudEvent event)` — single emitted event
- Produces: `EmissionFailure(String qualifiedName, Exception cause)` — single failed emission
- Produces: `EmissionResult(List<EmittedEvent> emitted, List<EmissionFailure> failures)` — tick() return type with `hasFailures()`, `emittedCount()`

- [ ] **Step 1: Create module POM**

Create `event-simulation-core/pom.xml`:

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

    <artifactId>casehub-platform-event-simulation-core</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Event Simulation Core</name>
    <description>Push-side event simulation — SimulatedEventEmitter with tick(),
        EventTrigger input record, CloudEventFixtureBuilder. POJO module, no CDI.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-core</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.cloudevents</groupId>
            <artifactId>cloudevents-core</artifactId>
        </dependency>
        <dependency>
            <groupId>com.fasterxml.jackson.core</groupId>
            <artifactId>jackson-databind</artifactId>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-inmem</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
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

Add `<module>event-simulation-core</module>` after `<module>memory-simulation-core</module>` in the parent `pom.xml`.

- [ ] **Step 3: Create source directories**

```bash
mkdir -p event-simulation-core/src/main/java/io/casehub/platform/simulation/event
mkdir -p event-simulation-core/src/test/java/io/casehub/platform/simulation/event
```

- [ ] **Step 4: Write EventTrigger record**

Create `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/EventTrigger.java`:

```java
package io.casehub.platform.simulation.event;

import java.util.Map;

public record EventTrigger(
        String eventType,
        String tenancyId,
        Map<String, Object> context) {

    public EventTrigger {
        if (eventType == null || eventType.isBlank()) {
            throw new IllegalArgumentException("eventType must not be null or blank");
        }
        if (tenancyId == null || tenancyId.isBlank()) {
            throw new IllegalArgumentException("tenancyId must not be null or blank");
        }
        context = context == null ? Map.of() : Map.copyOf(context);
    }
}
```

- [ ] **Step 5: Write EventSourceConfig record**

Create `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/EventSourceConfig.java`:

```java
package io.casehub.platform.simulation.event;

public record EventSourceConfig(
        String qualifiedName,
        String eventType,
        String tenancyId) {

    public EventSourceConfig {
        if (qualifiedName == null || qualifiedName.isBlank()) {
            throw new IllegalArgumentException("qualifiedName must not be null or blank");
        }
        if (eventType == null || eventType.isBlank()) {
            throw new IllegalArgumentException("eventType must not be null or blank");
        }
        if (tenancyId == null || tenancyId.isBlank()) {
            throw new IllegalArgumentException("tenancyId must not be null or blank");
        }
    }
}
```

- [ ] **Step 6: Write result records**

Create `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/EmittedEvent.java`:

```java
package io.casehub.platform.simulation.event;

import io.cloudevents.CloudEvent;

public record EmittedEvent(String qualifiedName, CloudEvent event) {}
```

Create `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/EmissionFailure.java`:

```java
package io.casehub.platform.simulation.event;

public record EmissionFailure(String qualifiedName, Exception cause) {}
```

Create `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/EmissionResult.java`:

```java
package io.casehub.platform.simulation.event;

import java.util.List;

public record EmissionResult(
        List<EmittedEvent> emitted,
        List<EmissionFailure> failures) {

    public EmissionResult {
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

- [ ] **Step 7: Write EventTriggerTest**

Create `event-simulation-core/src/test/java/io/casehub/platform/simulation/event/EventTriggerTest.java`:

```java
package io.casehub.platform.simulation.event;

import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class EventTriggerTest {

    @Test
    void constructsWithRequiredFields() {
        var trigger = new EventTrigger("io.casehub.work.workitem.completed", "tenant-1", Map.of());
        assertThat(trigger.eventType()).isEqualTo("io.casehub.work.workitem.completed");
        assertThat(trigger.tenancyId()).isEqualTo("tenant-1");
        assertThat(trigger.context()).isEmpty();
    }

    @Test
    void nullContextDefaultsToEmptyMap() {
        var trigger = new EventTrigger("type", "tenant", null);
        assertThat(trigger.context()).isNotNull().isEmpty();
    }

    @Test
    void contextIsDefensivelyCopied() {
        var mutable = new java.util.HashMap<String, Object>();
        mutable.put("key", "value");
        var trigger = new EventTrigger("type", "tenant", mutable);
        mutable.put("new", "entry");
        assertThat(trigger.context()).doesNotContainKey("new");
    }

    @Test
    void rejectsNullEventType() {
        assertThatThrownBy(() -> new EventTrigger(null, "tenant", Map.of()))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void rejectsBlankTenancyId() {
        assertThatThrownBy(() -> new EventTrigger("type", "  ", Map.of()))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void emissionResultReportsCorrectly() {
        var result = new EmissionResult(List.of(), List.of());
        assertThat(result.hasFailures()).isFalse();
        assertThat(result.emittedCount()).isZero();
    }

    @Test
    void eventSourceConfigRejectsNullQualifiedName() {
        assertThatThrownBy(() -> new EventSourceConfig(null, "type", "tenant"))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `mvn --batch-mode -pl event-simulation-core test`
Expected: all tests PASS, module compiles

- [ ] **Step 9: Commit**

```bash
git add event-simulation-core/ pom.xml
git commit -m "feat(#318): event-simulation-core module scaffold + records

EventTrigger, EventSourceConfig, EmissionResult, EmittedEvent,
EmissionFailure records for push-side event simulation.

Refs #318

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: CloudEventFixtureBuilder

**Files:**
- Create: `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/CloudEventFixtureBuilder.java`
- Test: `event-simulation-core/src/test/java/io/casehub/platform/simulation/event/CloudEventFixtureBuilderTest.java`

**Interfaces:**
- Consumes: `io.cloudevents.CloudEvent`, `io.cloudevents.core.builder.CloudEventBuilder`
- Produces: `CloudEventFixtureBuilder.fromMap(Map<String, Object>) → CloudEvent` — converts YAML-friendly maps to CloudEvent instances
- Produces: `CloudEventFixtureBuilder.toMap(CloudEvent) → Map<String, Object>` — converts CloudEvents to YAML-friendly maps (for corpus export)

- [ ] **Step 1: Write failing test for fromMap**

Create `event-simulation-core/src/test/java/io/casehub/platform/simulation/event/CloudEventFixtureBuilderTest.java`:

```java
package io.casehub.platform.simulation.event;

import io.cloudevents.CloudEvent;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class CloudEventFixtureBuilderTest {

    @Test
    void fromMapBuildsCloudEventWithRequiredFields() {
        Map<String, Object> map = Map.of(
                "type", "io.casehub.work.workitem.completed",
                "source", "/simulation/event-emitter");

        CloudEvent event = CloudEventFixtureBuilder.fromMap(map);

        assertThat(event.getType()).isEqualTo("io.casehub.work.workitem.completed");
        assertThat(event.getSource().toString()).isEqualTo("/simulation/event-emitter");
    }

    @Test
    void fromMapIncludesTenancyIdExtension() {
        Map<String, Object> map = Map.of(
                "type", "test.event",
                "source", "/test",
                "tenancyid", "tenant-1");

        CloudEvent event = CloudEventFixtureBuilder.fromMap(map);

        assertThat(event.getExtension("tenancyid")).isEqualTo("tenant-1");
    }

    @Test
    void fromMapIncludesDataPayload() {
        Map<String, Object> map = Map.ofEntries(
                Map.entry("type", "test.event"),
                Map.entry("source", "/test"),
                Map.entry("datacontenttype", "application/json"),
                Map.entry("data", Map.of("workItemId", "WI-001", "caseId", "CASE-001")));

        CloudEvent event = CloudEventFixtureBuilder.fromMap(map);

        assertThat(event.getData()).isNotNull();
        assertThat(event.getDataContentType()).isEqualTo("application/json");
        String dataStr = new String(event.getData().toBytes());
        assertThat(dataStr).contains("WI-001");
    }

    @Test
    void fromMapRejectsMissingType() {
        Map<String, Object> map = Map.of("source", "/test");

        assertThatThrownBy(() -> CloudEventFixtureBuilder.fromMap(map))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("type");
    }

    @Test
    void fromMapRejectsMissingSource() {
        Map<String, Object> map = Map.of("type", "test.event");

        assertThatThrownBy(() -> CloudEventFixtureBuilder.fromMap(map))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("source");
    }

    @Test
    void toMapRoundTrips() {
        Map<String, Object> original = Map.ofEntries(
                Map.entry("type", "test.event"),
                Map.entry("source", "/test"),
                Map.entry("tenancyid", "tenant-1"),
                Map.entry("datacontenttype", "application/json"),
                Map.entry("data", Map.of("key", "value")));

        CloudEvent event = CloudEventFixtureBuilder.fromMap(original);
        Map<String, Object> roundTripped = CloudEventFixtureBuilder.toMap(event);

        assertThat(roundTripped.get("type")).isEqualTo("test.event");
        assertThat(roundTripped.get("source")).isEqualTo("/test");
        assertThat(roundTripped.get("tenancyid")).isEqualTo("tenant-1");
    }

    @Test
    void fromMapHandlesArbitraryExtensions() {
        Map<String, Object> map = Map.of(
                "type", "test.event",
                "source", "/test",
                "tenancyid", "t1",
                "customext", "custom-value");

        CloudEvent event = CloudEventFixtureBuilder.fromMap(map);

        assertThat(event.getExtension("customext")).isEqualTo("custom-value");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode -pl event-simulation-core test -Dtest=CloudEventFixtureBuilderTest`
Expected: FAIL — class not found

- [ ] **Step 3: Implement CloudEventFixtureBuilder**

Create `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/CloudEventFixtureBuilder.java`:

```java
package io.casehub.platform.simulation.event;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.cloudevents.CloudEvent;
import io.cloudevents.core.builder.CloudEventBuilder;

import java.net.URI;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

public final class CloudEventFixtureBuilder {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final Set<String> KNOWN_FIELDS = Set.of(
            "id", "type", "source", "time", "datacontenttype", "dataschema",
            "subject", "specversion", "data", "data_base64");

    private CloudEventFixtureBuilder() {}

    public static CloudEvent fromMap(final Map<String, Object> map) {
        final String type = requireString(map, "type");
        final String source = requireString(map, "source");

        final CloudEventBuilder builder = CloudEventBuilder.v1()
                .withType(type)
                .withSource(URI.create(source));

        if (map.containsKey("subject")) {
            builder.withSubject((String) map.get("subject"));
        }
        if (map.containsKey("datacontenttype")) {
            builder.withDataContentType((String) map.get("datacontenttype"));
        }
        if (map.containsKey("dataschema")) {
            builder.withDataSchema(URI.create((String) map.get("dataschema")));
        }
        if (map.containsKey("data")) {
            final String contentType = (String) map.getOrDefault("datacontenttype", "application/json");
            builder.withData(contentType, serializeData(map.get("data")));
        }

        for (final Map.Entry<String, Object> entry : map.entrySet()) {
            if (!KNOWN_FIELDS.contains(entry.getKey()) && entry.getValue() != null) {
                builder.withExtension(entry.getKey(), entry.getValue().toString());
            }
        }

        return builder.build();
    }

    public static Map<String, Object> toMap(final CloudEvent event) {
        final Map<String, Object> map = new LinkedHashMap<>();
        map.put("type", event.getType());
        map.put("source", event.getSource().toString());

        if (event.getSubject() != null) {
            map.put("subject", event.getSubject());
        }
        if (event.getDataContentType() != null) {
            map.put("datacontenttype", event.getDataContentType());
        }
        if (event.getDataSchema() != null) {
            map.put("dataschema", event.getDataSchema().toString());
        }
        if (event.getData() != null) {
            try {
                map.put("data", MAPPER.readValue(event.getData().toBytes(), Object.class));
            } catch (final Exception e) {
                map.put("data", new String(event.getData().toBytes()));
            }
        }

        for (final String extName : event.getExtensionNames()) {
            map.put(extName, event.getExtension(extName));
        }

        return map;
    }

    private static byte[] serializeData(final Object data) {
        if (data instanceof byte[] bytes) {
            return bytes;
        }
        if (data instanceof String s) {
            return s.getBytes();
        }
        try {
            return MAPPER.writeValueAsBytes(data);
        } catch (final JsonProcessingException e) {
            throw new IllegalArgumentException("Cannot serialize event data", e);
        }
    }

    private static String requireString(final Map<String, Object> map, final String key) {
        final Object value = map.get(key);
        if (value == null) {
            throw new IllegalArgumentException("CloudEvent map must contain '" + key + "'");
        }
        return value.toString();
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode -pl event-simulation-core test -Dtest=CloudEventFixtureBuilderTest`
Expected: all tests PASS

- [ ] **Step 5: Commit**

```bash
git add event-simulation-core/
git commit -m "feat(#318): CloudEventFixtureBuilder — map ↔ CloudEvent conversion

Converts between YAML-friendly Map<String, Object> and CloudEvent
instances. Handles type, source, tenancyid extension, arbitrary
extensions, and JSON data serialisation via Jackson.

Refs #318

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 2: SimulatedEventEmitter + integration tests

### Task 3: SimulatedEventEmitter with tick()

**Files:**
- Create: `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/SimulatedEventEmitter.java`
- Test: `event-simulation-core/src/test/java/io/casehub/platform/simulation/event/SimulatedEventEmitterTest.java`

**Interfaces:**
- Consumes: `SimulationRuntime.strategyFor(String) → Optional<SimulationStrategy<EventTrigger, CloudEvent>>` (from simulation-core)
- Consumes: `EventTrigger`, `EventSourceConfig`, `EmissionResult`, `EmittedEvent`, `EmissionFailure` (from Task 1)
- Consumes: `CloudEventBuilder.from(event).withId(...).withTime(...).build()` (from cloudevents-core)
- Produces: `SimulatedEventEmitter(SimulationRuntime, Consumer<CloudEvent>, List<EventSourceConfig>)` — constructor
- Produces: `SimulatedEventEmitter.tick() → EmissionResult` — emits one batch of events
- Produces: `SimulatedEventEmitter.defaultKeyExtractor() → KeyExtractor<EventTrigger>` — static factory for the default key extractor

- [ ] **Step 1: Write failing test — tick emits events from corpus**

Create `event-simulation-core/src/test/java/io/casehub/platform/simulation/event/SimulatedEventEmitterTest.java`:

```java
package io.casehub.platform.simulation.event;

import io.casehub.platform.simulation.ExhaustionPolicy;
import io.casehub.platform.simulation.InvocationRecord;
import io.casehub.platform.simulation.SimulationConfig;
import io.casehub.platform.simulation.SimulationRuntime;
import io.casehub.platform.simulation.inmem.InMemorySimulationCorpus;
import io.cloudevents.CloudEvent;
import io.cloudevents.core.builder.CloudEventBuilder;
import org.junit.jupiter.api.Test;

import java.net.URI;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class SimulatedEventEmitterTest {

    private static final String QN = "event-emitter.workitem-completed";

    @Test
    void tickEmitsEventFromCorpus() {
        var corpus = new InMemorySimulationCorpus<EventTrigger, CloudEvent>();
        var config = stubConfig(Optional.of("sequential"), Optional.empty());
        var runtime = new SimulationRuntime(config, corpus);

        CloudEvent template = CloudEventBuilder.v1()
                .withId("template-id")
                .withType("io.casehub.work.workitem.completed")
                .withSource(URI.create("/simulation/event-emitter"))
                .withExtension("tenancyid", "default")
                .withData("application/json", "{\"workItemId\":\"WI-001\"}".getBytes())
                .build();

        corpus.seed(QN, List.of(new InvocationRecord<>(
                "default", "wic",
                new EventTrigger("io.casehub.work.workitem.completed", "default", Map.of()),
                template, Instant.now())));

        List<CloudEvent> emitted = new ArrayList<>();
        var emitter = new SimulatedEventEmitter(runtime, emitted::add,
                List.of(new EventSourceConfig(QN, "io.casehub.work.workitem.completed", "default")));

        EmissionResult result = emitter.tick();

        assertThat(result.emittedCount()).isEqualTo(1);
        assertThat(result.hasFailures()).isFalse();
        assertThat(emitted).hasSize(1);
        assertThat(emitted.get(0).getType()).isEqualTo("io.casehub.work.workitem.completed");
    }

    @Test
    void tickStampsFreshIdAndTime() {
        var corpus = new InMemorySimulationCorpus<EventTrigger, CloudEvent>();
        var config = stubConfig(Optional.of("sequential"), Optional.empty());
        var runtime = new SimulationRuntime(config, corpus);

        CloudEvent template = CloudEventBuilder.v1()
                .withId("original-id")
                .withType("test.event")
                .withSource(URI.create("/test"))
                .withExtension("tenancyid", "t1")
                .build();

        corpus.seed(QN, List.of(new InvocationRecord<>(
                "t1", null,
                new EventTrigger("test.event", "t1", Map.of()),
                template, Instant.now())));

        List<CloudEvent> emitted = new ArrayList<>();
        var emitter = new SimulatedEventEmitter(runtime, emitted::add,
                List.of(new EventSourceConfig(QN, "test.event", "t1")));

        emitter.tick();
        emitter.tick();

        assertThat(emitted).hasSize(2);
        assertThat(emitted.get(0).getId()).isNotEqualTo("original-id");
        assertThat(emitted.get(1).getId()).isNotEqualTo("original-id");
        assertThat(emitted.get(0).getId()).isNotEqualTo(emitted.get(1).getId());
        assertThat(emitted.get(0).getTime()).isNotNull();
        assertThat(emitted.get(1).getTime()).isNotNull();
    }

    @Test
    void tickSkipsSourcesWithNoStrategy() {
        var corpus = new InMemorySimulationCorpus<EventTrigger, CloudEvent>();
        var config = stubConfig(Optional.empty(), Optional.empty());
        var runtime = new SimulationRuntime(config, corpus);

        List<CloudEvent> emitted = new ArrayList<>();
        var emitter = new SimulatedEventEmitter(runtime, emitted::add,
                List.of(new EventSourceConfig(QN, "test.event", "t1")));

        EmissionResult result = emitter.tick();

        assertThat(result.emittedCount()).isZero();
        assertThat(result.hasFailures()).isFalse();
        assertThat(emitted).isEmpty();
    }

    @Test
    void tickSkipsSourcesWhenCannotResolve() {
        var corpus = new InMemorySimulationCorpus<EventTrigger, CloudEvent>();
        var config = stubConfig(Optional.of("key-lookup"), Optional.empty());
        var runtime = new SimulationRuntime(config, corpus);
        runtime.registerExtractor(QN, SimulatedEventEmitter.defaultKeyExtractor());

        List<CloudEvent> emitted = new ArrayList<>();
        var emitter = new SimulatedEventEmitter(runtime, emitted::add,
                List.of(new EventSourceConfig(QN, "missing.event", "t1")));

        EmissionResult result = emitter.tick();

        assertThat(result.emittedCount()).isZero();
        assertThat(emitted).isEmpty();
    }

    @Test
    void tickIsolatesErrorsPerSource() {
        var corpus = new InMemorySimulationCorpus<EventTrigger, CloudEvent>();
        var config = new SimulationConfig() {
            @Override
            public Optional<String> strategyFor(String qn) {
                return Optional.of("sequential");
            }
            @Override
            public boolean captureEnabled(String qn) { return false; }
            @Override
            public Optional<ExhaustionPolicy> exhaustionPolicy(String qn) {
                return Optional.of(ExhaustionPolicy.THROW);
            }
        };
        var runtime = new SimulationRuntime(config, corpus);

        String qnGood = "event-emitter.good";
        String qnBad = "event-emitter.bad";

        CloudEvent goodEvent = CloudEventBuilder.v1()
                .withId("g")
                .withType("good.event")
                .withSource(URI.create("/test"))
                .withExtension("tenancyid", "t1")
                .build();
        corpus.seed(qnGood, List.of(new InvocationRecord<>(
                "t1", null,
                new EventTrigger("good.event", "t1", Map.of()),
                goodEvent, Instant.now())));

        List<CloudEvent> emitted = new ArrayList<>();
        var emitter = new SimulatedEventEmitter(runtime, emitted::add,
                List.of(
                        new EventSourceConfig(qnBad, "bad.event", "t1"),
                        new EventSourceConfig(qnGood, "good.event", "t1")));

        EmissionResult result = emitter.tick();

        assertThat(result.emittedCount()).isEqualTo(1);
        assertThat(result.hasFailures()).isTrue();
        assertThat(result.failures().get(0).qualifiedName()).isEqualTo(qnBad);
        assertThat(emitted).hasSize(1);
    }

    @Test
    void tickWithMultipleSourcesEmitsAll() {
        var corpus = new InMemorySimulationCorpus<EventTrigger, CloudEvent>();
        var config = stubConfig(Optional.of("sequential"), Optional.empty());
        var runtime = new SimulationRuntime(config, corpus);

        String qn1 = "event-emitter.a";
        String qn2 = "event-emitter.b";

        for (String qn : List.of(qn1, qn2)) {
            CloudEvent ce = CloudEventBuilder.v1()
                    .withId("id")
                    .withType(qn + ".event")
                    .withSource(URI.create("/test"))
                    .withExtension("tenancyid", "t1")
                    .build();
            corpus.seed(qn, List.of(new InvocationRecord<>(
                    "t1", null,
                    new EventTrigger(qn + ".event", "t1", Map.of()),
                    ce, Instant.now())));
        }

        List<CloudEvent> emitted = new ArrayList<>();
        var emitter = new SimulatedEventEmitter(runtime, emitted::add,
                List.of(
                        new EventSourceConfig(qn1, qn1 + ".event", "t1"),
                        new EventSourceConfig(qn2, qn2 + ".event", "t1")));

        EmissionResult result = emitter.tick();

        assertThat(result.emittedCount()).isEqualTo(2);
        assertThat(emitted).hasSize(2);
    }

    @Test
    void defaultKeyExtractorUsesTypeAndTenancy() {
        var extractor = SimulatedEventEmitter.defaultKeyExtractor();
        var trigger = new EventTrigger("io.casehub.work.workitem.completed", "tenant-1", Map.of());

        String key = extractor.extract(trigger);

        assertThat(key).isEqualTo("io.casehub.work.workitem.completed::tenant-1");
    }

    // --- helpers ---

    private static SimulationConfig stubConfig(Optional<String> strategy,
                                                Optional<ExhaustionPolicy> exhaustion) {
        return new SimulationConfig() {
            @Override
            public Optional<String> strategyFor(String qn) { return strategy; }
            @Override
            public boolean captureEnabled(String qn) { return false; }
            @Override
            public Optional<ExhaustionPolicy> exhaustionPolicy(String qn) { return exhaustion; }
        };
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode -pl event-simulation-core test -Dtest=SimulatedEventEmitterTest`
Expected: FAIL — class not found

- [ ] **Step 3: Implement SimulatedEventEmitter**

Create `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/SimulatedEventEmitter.java`:

```java
package io.casehub.platform.simulation.event;

import io.casehub.platform.simulation.KeyExtractor;
import io.casehub.platform.simulation.SimulationRuntime;
import io.casehub.platform.simulation.SimulationStrategy;
import io.cloudevents.CloudEvent;
import io.cloudevents.core.builder.CloudEventBuilder;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.function.Consumer;

public class SimulatedEventEmitter {

    private final SimulationRuntime simulation;
    private final Consumer<CloudEvent> eventSink;
    private final List<EventSourceConfig> sources;

    public SimulatedEventEmitter(final SimulationRuntime simulation,
                                  final Consumer<CloudEvent> eventSink,
                                  final List<EventSourceConfig> sources) {
        this.simulation = simulation;
        this.eventSink = eventSink;
        this.sources = List.copyOf(sources);
    }

    @SuppressWarnings("unchecked")
    public EmissionResult tick() {
        final List<EmittedEvent> emitted = new ArrayList<>();
        final List<EmissionFailure> failures = new ArrayList<>();

        for (final EventSourceConfig source : sources) {
            final String qualifiedName = source.qualifiedName();

            final Optional<SimulationStrategy<EventTrigger, CloudEvent>> strategy =
                    simulation.strategyFor(qualifiedName);
            if (strategy.isEmpty()) {
                continue;
            }

            final EventTrigger trigger = new EventTrigger(
                    source.eventType(), source.tenancyId(), java.util.Map.of());

            if (!strategy.get().canResolve(trigger)) {
                continue;
            }

            try {
                final CloudEvent event = strategy.get().resolve(trigger);
                final CloudEvent stamped = CloudEventBuilder.from(event)
                        .withId(UUID.randomUUID().toString())
                        .withTime(OffsetDateTime.now())
                        .build();
                eventSink.accept(stamped);
                emitted.add(new EmittedEvent(qualifiedName, stamped));
            } catch (final Exception e) {
                failures.add(new EmissionFailure(qualifiedName, e));
            }
        }

        return new EmissionResult(emitted, failures);
    }

    public static KeyExtractor<EventTrigger> defaultKeyExtractor() {
        return trigger -> trigger.eventType() + "::" + trigger.tenancyId();
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode -pl event-simulation-core test`
Expected: all tests PASS

- [ ] **Step 5: Run full build to verify no regressions**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 6: Commit**

```bash
git add event-simulation-core/
git commit -m "feat(#318): SimulatedEventEmitter with tick()

Core emitter for push-side event simulation. Iterates configured
event sources, resolves CloudEvents from SimulationStrategy, stamps
fresh id/time per emission, fires via Consumer<CloudEvent> callback.
Per-source error isolation. 7 tests.

Refs #318

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4: Documentation — update simulation guide + CLAUDE.md

**Files:**
- Modify: `docs/guides/simulation-guide.md` (add event simulation section)
- Modify: `CLAUDE.md` (add event-simulation-core module entry)

**Interfaces:**
- Consumes: all types from Tasks 1-3

- [ ] **Step 1: Add event-simulation-core to CLAUDE.md module table**

Add after the `memory-simulation-core` entry in the Modules section of `CLAUDE.md`:

```markdown
| `event-simulation-core/` | `casehub-platform-event-simulation-core` | Push-side event simulation — SimulatedEventEmitter with tick(), EventTrigger input record, CloudEventFixtureBuilder (Map ↔ CloudEvent). POJO module, no CDI. Consumer<CloudEvent> callback for CDI bus injection. Per-source error isolation. No quarkus:build goal |
```

- [ ] **Step 2: Add event simulation section to simulation guide**

Add a new section before the "What's next" section in `docs/guides/simulation-guide.md`:

```markdown
## Event simulation

Event simulation generates synthetic CloudEvents and injects them
into the CDI event bus — the same path real stream processors use.
Events traverse DataSourceRouter's tenancy check and
acceptedEventTypes filter before reaching wired DataSources.

### Core components

| Type | Purpose |
|------|---------|
| `EventTrigger` | Input record — eventType, tenancyId, context |
| `EventSourceConfig` | Per-source config — qualifiedName, eventType, tenancyId |
| `SimulatedEventEmitter` | Core emitter with `tick()` method |
| `CloudEventFixtureBuilder` | Map ↔ CloudEvent conversion for YAML corpus |
| `EmissionResult` | Synchronous result from `tick()` |

### Usage

```java
// 1. Build a corpus with CloudEvent entries
var corpus = new InMemorySimulationCorpus<EventTrigger, CloudEvent>();
CloudEvent template = CloudEventFixtureBuilder.fromMap(Map.of(
        "type", "io.casehub.work.workitem.completed",
        "source", "/simulation/event-emitter",
        "tenancyid", "default",
        "datacontenttype", "application/json",
        "data", Map.of("workItemId", "WI-001")));
corpus.seed("event-emitter.wic", List.of(new InvocationRecord<>(
        "default", "wic",
        new EventTrigger("io.casehub.work.workitem.completed", "default", Map.of()),
        template, Instant.now())));

// 2. Configure and create the emitter
var config = ...; // strategy = "sequential" for "event-emitter.wic"
var runtime = new SimulationRuntime(config, corpus);
List<CloudEvent> sink = new ArrayList<>();
var emitter = new SimulatedEventEmitter(runtime, sink::add,
        List.of(new EventSourceConfig("event-emitter.wic",
                "io.casehub.work.workitem.completed", "default")));

// 3. Emit
EmissionResult result = emitter.tick();
assertThat(result.emittedCount()).isEqualTo(1);
assertThat(sink.get(0).getType())
        .isEqualTo("io.casehub.work.workitem.completed");
```

The emitter stamps a fresh UUID `id` and `time` on each emission.
Corpus entries store CloudEvent templates without these fields.

### Tenant context

The emitter does not use `CurrentPrincipal`. Tenant context comes
from `EventSourceConfig.tenancyId()` and the `tenancyid` CloudEvent
extension in the corpus. For multi-tenant testing, configure multiple
EventSourceConfig entries with different tenant IDs.
```

- [ ] **Step 3: Update "What's next" section — mark event simulation as done**

In the "What's next" section of `docs/guides/simulation-guide.md`, change:

```
- **Event simulation** — push-side strategies for event sequences,
  timed delivery, and DataSource injection
```

to:

```
- **Timed event simulation** — @Scheduled wrapper for continuous
  background event emission with configurable timing patterns
```

- [ ] **Step 4: Commit**

```bash
git add docs/guides/simulation-guide.md CLAUDE.md
git commit -m "docs(#318): add event simulation to guide and CLAUDE.md

Refs #318

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## References

- [2026-09-16-event-simulation-design.md] — design spec this plan implements
- SimulationRuntime.java — strategy resolution and registration API
- SimulatedAgentBackend.java — module structure precedent (Path B integration pattern)
- AgentSimulationInput.java — input record precedent
- SimulatedAgentBackendTest.java — test pattern with stubConfig helper
- InMemorySimulationCorpus — test corpus backend
- CloudEventBuilder — io.cloudevents.core.builder (CloudEvent construction)
- DataSourceRouter.java:159-188 — CDI CloudEvent routing (tenancy check + acceptedEventTypes)
- DigestFlushScheduler.java:49 — tick() pattern precedent
- agent-simulation-core/pom.xml — POM structure precedent
- [GitHub #318] — feat: event simulation
- [GitHub #326] — timed simulation (deferred @Scheduled wrapper)
