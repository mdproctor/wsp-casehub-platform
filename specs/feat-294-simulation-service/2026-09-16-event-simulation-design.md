# Event Simulation Design Spec

**Branch:** issue-294-simulation-service
**Issue:** casehubio/platform#318
**Date:** 2026-09-16

## Overview

Push-side event simulation for the casehub platform. Where the existing simulation framework intercepts SPI method calls (request-response), event simulation generates and injects synthetic CloudEvents into the CDI event bus — the same path real stream processors (webhook, kafka, amqp, poll) use. Events traverse `DataSourceRouter`'s tenancy check and `acceptedEventTypes` filter before reaching wired DataSources, enabling end-to-end testing of the subscription/notification pipeline without real event sources.

The primary use case is pipeline testing: verifying event → DataSource → SubscriptionEngine → NotificationDispatcher end-to-end with deterministic, corpus-driven events.

## Architecture

### Integration with existing simulation framework

Event simulation reuses the existing `SimulationStrategy<I, O>` contract (per D8 — unified contract for request/response and events). The strategy type is `SimulationStrategy<EventTrigger, CloudEvent>`:

- **Input:** `EventTrigger` — carries the event type being requested and tenant context
- **Output:** `CloudEvent` — a complete, ready-to-fire event from the corpus

The existing strategies (sequential, key-lookup, random, recorded-replay, nearest-match) all work unchanged — the corpus stores CloudEvent instances as the output type.

### Core components

#### EventTrigger

The input type for event simulation strategies:

```java
package io.casehub.platform.simulation.event;

public record EventTrigger(
    String eventType,
    String tenancyId,
    Map<String, Object> context
) {}
```

- `eventType` — the CloudEvent type being requested (e.g. `"io.casehub.work.workitem.completed"`)
- `tenancyId` — the tenant context for this emission (from corpus fixture data, not CurrentPrincipal)
- `context` — optional metadata for strategy-specific matching (e.g. entity IDs, scenario state)

#### SimulatedEventEmitter

The core emitter — a POJO with a `tick()` method:

```java
package io.casehub.platform.simulation.event;

public class SimulatedEventEmitter {
    private final SimulationRuntime simulation;
    private final Consumer<CloudEvent> eventSink;
    private final List<EventSourceConfig> sources;

    public SimulatedEventEmitter(
            SimulationRuntime simulation,
            Consumer<CloudEvent> eventSink,
            List<EventSourceConfig> sources) {
        this.simulation = simulation;
        this.eventSink = eventSink;
        this.sources = List.copyOf(sources);
    }

    public EmissionResult tick() {
        List<EmittedEvent> emitted = new ArrayList<>();
        List<EmissionFailure> failures = new ArrayList<>();

        for (EventSourceConfig source : sources) {
            String qualifiedName = source.qualifiedName();
            Optional<SimulationStrategy<EventTrigger, CloudEvent>> strategy =
                    simulation.strategyFor(qualifiedName);
            if (strategy.isEmpty()) continue;

            EventTrigger trigger = new EventTrigger(
                    source.eventType(), source.tenancyId(), Map.of());

            if (!strategy.get().canResolve(trigger)) continue;

            try {
                CloudEvent event = strategy.get().resolve(trigger);
                CloudEvent stamped = CloudEventBuilder.from(event)
                        .withId(UUID.randomUUID().toString())
                        .withTime(OffsetDateTime.now())
                        .build();
                eventSink.accept(stamped);
                emitted.add(new EmittedEvent(qualifiedName, stamped));
            } catch (Exception e) {
                failures.add(new EmissionFailure(qualifiedName, e));
            }
        }

        return new EmissionResult(emitted, failures);
    }
}
```

Key design points:

1. **`Consumer<CloudEvent>` eventSink** — constructor-injected callback. The CDI wiring layer provides `event -> cloudEventBus.fireAsync(event)`. Tests provide a collecting list. This keeps the core module CDI-free (per the *-core convention).

2. **Per-invocation id/time stamping** — the corpus stores CloudEvent templates with type, source, tenancyid, and data. The emitter stamps a fresh UUID `id` and `time` on each emission. This ensures every emitted event is unique even when the same corpus entry is resolved multiple times (e.g. sequential strategy wrapping).

3. **`EmissionResult` return** — synchronous result reporting. Tests assert on `emitted` and `failures` directly. No fire-and-forget.

4. **Per-source error isolation** — one failing source doesn't prevent other sources from emitting. Follows the pattern from `DigestFlushScheduler` (per-key error isolation).

#### EventSourceConfig

Configures one event source — what qualified name to resolve from and what tenant context to use:

```java
package io.casehub.platform.simulation.event;

public record EventSourceConfig(
    String qualifiedName,
    String eventType,
    String tenancyId
) {}
```

The `qualifiedName` is the strategy lookup key (e.g. `"event-emitter.workitem-completed"`). This follows the existing pattern where each SPI method has its own qualified name for strategy resolution.

#### EmissionResult and EmittedEvent

```java
public record EmissionResult(
    List<EmittedEvent> emitted,
    List<EmissionFailure> failures
) {
    public boolean hasFailures() { return !failures.isEmpty(); }
    public int emittedCount() { return emitted.size(); }
}

public record EmittedEvent(String qualifiedName, CloudEvent event) {}

public record EmissionFailure(String qualifiedName, Exception cause) {}
```

### Module structure

**`event-simulation-core`** — POJO module, no CDI:
- `EventTrigger` — input record
- `SimulatedEventEmitter` — core emitter with `tick()`
- `EventSourceConfig` — per-source configuration
- `EmissionResult`, `EmittedEvent`, `EmissionFailure` — result types
- `CloudEventFixtureBuilder` — utility for building corpus-ready CloudEvents

Dependencies:
- `simulation-api` (SimulationStrategy, SimulationCorpus, KeyExtractor)
- `simulation-core` (SimulationRuntime, strategy implementations)
- `io.cloudevents:cloudevents-api` (CloudEvent, CloudEventBuilder)

No CDI, no Quarkus. Constructor-injected POJOs only.

**`event-simulation` (deferred)** — Quarkus wiring module. Not part of this issue. Would provide:
- `@Produces SimulatedEventEmitter` with `Event<CloudEvent>.fireAsync()` as the sink
- `@Startup` bean that reads `casehub.simulation.event.*` config and builds `EventSourceConfig` list
- `@Scheduled` wrapper for continuous emission (#326)

### CloudEvent corpus format

Corpus entries store complete CloudEvents as YAML fixtures. Per D24, the strategy resolves CloudEvent directly — the corpus is the single source of truth:

```yaml
qualifiedName: event-emitter.workitem-completed
tenancy: default
records:
  - key: "workitem-complete-basic"
    input:
      eventType: "io.casehub.work.workitem.completed"
      tenancyId: "default"
      context: {}
    output:
      type: "io.casehub.work.workitem.completed"
      source: "/simulation/event-emitter"
      tenancyid: "default"
      datacontenttype: "application/json"
      data:
        workItemId: "WI-001"
        caseId: "CASE-001"
        actorId: "actor-1"
        completedAt: "2026-09-16T10:00:00Z"
```

The `output` section maps directly to CloudEvent fields. The emitter stamps `id` (UUID) and `time` (now) at emission time — these are not in the corpus since they must be unique per emission.

Note: CloudEvent serialisation/deserialisation for YAML corpus requires a custom adapter since `CloudEvent` is an interface (not a POJO). The `CloudEventFixtureBuilder` utility converts between YAML-friendly maps and `CloudEvent` instances:

```java
package io.casehub.platform.simulation.event;

public class CloudEventFixtureBuilder {
    public static CloudEvent fromMap(Map<String, Object> map) {
        CloudEventBuilder builder = CloudEventBuilder.v1()
                .withType((String) map.get("type"))
                .withSource(URI.create((String) map.get("source")));

        if (map.containsKey("tenancyid")) {
            builder.withExtension("tenancyid", (String) map.get("tenancyid"));
        }
        if (map.containsKey("datacontenttype")) {
            builder.withDataContentType((String) map.get("datacontenttype"));
        }
        if (map.containsKey("data")) {
            builder.withData(
                    (String) map.getOrDefault("datacontenttype", "application/json"),
                    serializeData(map.get("data")));
        }
        return builder.build();
    }

    private static byte[] serializeData(Object data) {
        // Jackson ObjectMapper serialisation
    }
}
```

### Configuration

Event sources are configured via the existing `casehub.simulation.*` namespace:

```properties
# Configure a sequential event source
casehub.simulation.event-emitter.workitem-completed.strategy=sequential

# Configure a key-lookup event source
casehub.simulation.event-emitter.case-lifecycle.strategy=key-lookup

# Corpus file path (loaded by simulation-config at startup)
casehub.simulation.corpus.files=classpath:simulation/events.yaml
```

The `event-emitter` prefix is the SPI name. Method names after it (e.g. `workitem-completed`, `case-lifecycle`) are the event source identifiers that form the qualified name: `event-emitter.workitem-completed`.

### KeyExtractor for events

Default key extractor for event triggers — extracts by event type:

```java
public static KeyExtractor<EventTrigger> defaultKeyExtractor() {
    return trigger -> trigger.eventType() + "::" + trigger.tenancyId();
}
```

Registered at startup by the Quarkus wiring layer (or programmatically in tests).

### Tenant context

Per the exploration findings, `@Scheduled` tasks in the platform never use `CurrentPrincipal` — they derive tenant context from data. The event emitter follows the same pattern:

- `EventSourceConfig.tenancyId()` provides the tenant context
- Corpus fixtures include `tenancyid` in the CloudEvent output
- The emitter does not inject `CurrentPrincipal`
- `DataSourceRouter` reads `tenancyid` from the CloudEvent extension for routing

For multi-tenant testing, configure multiple `EventSourceConfig` entries with different `tenancyId` values.

### Testing

The emitter is fully testable without CDI:

```java
@Test
void tickEmitsEventsFromCorpus() {
    InMemorySimulationCorpus corpus = new InMemorySimulationCorpus();
    SimulationRuntime runtime = new SimulationRuntime(config, corpus);

    CloudEvent ce = CloudEventBuilder.v1()
            .withType("io.casehub.work.workitem.completed")
            .withSource(URI.create("/simulation"))
            .withExtension("tenancyid", "default")
            .withData("application/json", "{}".getBytes())
            .build();
    corpus.seed("event-emitter.emit", List.of(
            new InvocationRecord<>("default", "wic", eventTrigger, ce, Instant.now())));

    List<CloudEvent> emitted = new ArrayList<>();
    SimulatedEventEmitter emitter = new SimulatedEventEmitter(
            runtime, emitted::add,
            List.of(new EventSourceConfig("event-emitter.emit",
                    "io.casehub.work.workitem.completed", "default")));

    EmissionResult result = emitter.tick();
    assertThat(result.emittedCount()).isEqualTo(1);
    assertThat(emitted).hasSize(1);
    assertThat(emitted.get(0).getType()).isEqualTo("io.casehub.work.workitem.completed");
}
```

No Quarkus test runtime needed. The `Consumer<CloudEvent>` callback makes assertion trivial.

## Scope

This issue (#318) delivers:

| Deliverable | Module | Description |
|-------------|--------|-------------|
| `EventTrigger` | event-simulation-core | Input record for event strategies |
| `SimulatedEventEmitter` | event-simulation-core | Core emitter with `tick()` |
| `EventSourceConfig` | event-simulation-core | Per-source configuration |
| `EmissionResult` | event-simulation-core | Synchronous result reporting |
| `CloudEventFixtureBuilder` | event-simulation-core | Map ↔ CloudEvent conversion |
| Unit tests | event-simulation-core | Emitter tests with in-memory corpus |

**Explicitly deferred:**

| Item | Issue | Rationale |
|------|-------|-----------|
| `@Scheduled` wrapper | #326 | Timed simulation — timing patterns are orthogonal |
| Quarkus CDI wiring (`event-simulation` module) | #326 | Wiring the `Event<CloudEvent>` sink and startup config |
| Burst/jitter/distribution patterns | #326 | Timing control |
| REST client simulation | #319 | Different interception mechanism |

## References

- [platform#318](https://github.com/casehubio/platform/issues/318) — this issue
- [platform#326](https://github.com/casehubio/platform/issues/326) — timed simulation (next in queue)
- [simulation-service-design.md](2026-09-15-simulation-service-design.md) — Phase 1 design (event simulation section)
- D8 — unified contract for request/response and events
- D21-D25 — decisions captured for this issue
- DataSourceRouter.java — CDI CloudEvent → DataSource bridge (routing logic at lines 159-188)
- CloudEventTypeDispatcher.java — type-qualified re-dispatch
- DigestFlushScheduler.java — tick() pattern precedent (line 49)
- DeliveryRetryProcessor.java — tick() pattern precedent (line 58)
- agent-simulation-core/ — module structure precedent (SimulatedAgentBackend, AgentSimulationInput)
- WebhookResource.java — CloudEvent construction and CDI bus injection pattern (lines 109-113)
- KafkaStreamProcessor.java — CloudEvent construction pattern (lines 153-168)
