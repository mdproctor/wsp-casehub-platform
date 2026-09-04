# Capacity Signal SPI + Redistribution Policy Framework — Design Spec

**Issue:** casehubio/platform#268
**Date:** 2026-09-04
**Status:** Draft

## Summary

Platform-level shared vocabulary for actor capacity signals and redistribution
policy. Three layers:

1. **Signal model** — `CapacitySignal` record, `CapacitySignalSource` SPI,
   `ActorCapacityView` aggregated read API (all in platform-api)
2. **Policy model** — `RedistributionPolicy` SPI, `RedistributionContext`,
   `RedistributionDecision`, `RedistributionAction` (all in platform-api)
3. **Runtime** — `AggregatingActorCapacityView`, `DefaultRedistributionPolicy`,
   `CapacityPressureMonitor` (all in platform/)

Consumers (qhorus, engine) observe `CapacityPressureEvent` CDI events to
act on redistribution decisions.

## Part 1 — Signal Model (platform-api)

### Package: `io.casehub.platform.api.capacity`

### CapacitySignal

```java
public record CapacitySignal(String actorId,
                              String source,
                              double pressure,
                              Instant timestamp) {

    public CapacitySignal {
        if (pressure < 0.0 || pressure > 1.0) {
            throw new IllegalArgumentException(
                    "Pressure must be between 0.0 and 1.0, got: " + pressure);
        }
        Objects.requireNonNull(actorId, "actorId is required");
        Objects.requireNonNull(source, "source is required");
        if (timestamp == null) { timestamp = Instant.now(); }
    }
}
```

- `actorId` — the actor under pressure (same identity string used across all backends)
- `source` — signal source name (e.g., `"work-queue"`, `"qhorus-channel"`)
- `pressure` — normalised 0.0 (idle) to 1.0 (at capacity)
- `timestamp` — when the signal was sampled. Defaults to now if null.

Validation in the compact constructor: pressure range enforced, actorId
and source non-null. Defensive — signals from misbehaving sources fail
at construction, not at aggregation.

### CapacitySignalSource

```java
public interface CapacitySignalSource {

    String sourceName();

    List<CapacitySignal> signals();
}
```

- `sourceName()` — stable name for this source (appears in diagnostics and events)
- `signals()` — returns all current capacity signals across all actors this
  source tracks. Bounded by active actor count, not total actors.

CDI discovery: implementations annotated `@ApplicationScoped`. The aggregator
collects via `@Inject @Any Instance<CapacitySignalSource>`.

Source-provides-all design: the monitor sweeps all sources on a schedule.
Sources know which actors they're tracking (work queues, channel assignments).
No per-actor method — the aggregator filters by actor.

### ActorCapacityView

```java
public interface ActorCapacityView {

    CapacitySignal aggregatedPressure(String actorId);

    List<CapacitySignal> signalsByActor(String actorId);

    List<CapacitySignal> allAggregatedPressures();
}
```

- `aggregatedPressure(actorId)` — synthetic signal with `max(pressure)` across
  all sources for the actor. Source is `"aggregated"`. Returns a signal with
  `pressure = 0.0` if no signals exist for the actor.
- `signalsByActor(actorId)` — individual source signals for diagnostics
- `allAggregatedPressures()` — all actors with any signal, each as an
  aggregated pressure. Used by the monitor for the sweep.

## Part 2 — Policy Model (platform-api)

### Package: `io.casehub.platform.api.capacity`

### RedistributionAction

```java
public enum RedistributionAction {
    NONE,
    COMPRESS,
    REDISTRIBUTE,
    ESCALATE
}
```

- `NONE` — pressure below all thresholds, no action needed
- `COMPRESS` — moderate pressure, compress current workload (defer
  non-urgent items, extend deadlines)
- `REDISTRIBUTE` — high pressure, redistribute work to other actors
- `ESCALATE` — critical pressure, escalate to supervisor / halt routing

### RedistributionContext

```java
public record RedistributionContext(String actorId,
                                     CapacitySignal aggregatedSignal,
                                     List<CapacitySignal> sourceSignals) {

    public RedistributionContext {
        Objects.requireNonNull(actorId);
        Objects.requireNonNull(aggregatedSignal);
        if (sourceSignals == null) { sourceSignals = List.of(); }
    }
}
```

The input to a `RedistributionPolicy`. Contains the aggregated pressure
plus individual source signals for policies that need source-level detail.

### RedistributionDecision

```java
public record RedistributionDecision(RedistributionAction action,
                                      String reason) {

    public static RedistributionDecision none() {
        return new RedistributionDecision(RedistributionAction.NONE, null);
    }

    public static RedistributionDecision compress(String reason) {
        return new RedistributionDecision(RedistributionAction.COMPRESS, reason);
    }

    public static RedistributionDecision redistribute(String reason) {
        return new RedistributionDecision(RedistributionAction.REDISTRIBUTE, reason);
    }

    public static RedistributionDecision escalate(String reason) {
        return new RedistributionDecision(RedistributionAction.ESCALATE, reason);
    }
}
```

Static factories for readability. `reason` is human-readable and appears
in logs and events — e.g., `"pressure 0.87 exceeds redistribute threshold 0.85"`.

### RedistributionPolicy

```java
public interface RedistributionPolicy {

    RedistributionDecision evaluate(RedistributionContext context);
}
```

Single method. The policy evaluates the context and returns a decision.
CDI discovery: implementations annotated `@ApplicationScoped`. The default
implementation lives in `platform/`.

### CapacityPressureEvent

```java
public record CapacityPressureEvent(String actorId,
                                     RedistributionDecision decision,
                                     CapacitySignal aggregatedSignal,
                                     Instant firedAt) {

    public CapacityPressureEvent {
        Objects.requireNonNull(actorId);
        Objects.requireNonNull(decision);
        Objects.requireNonNull(aggregatedSignal);
        if (firedAt == null) { firedAt = Instant.now(); }
    }
}
```

CDI event fired by `CapacityPressureMonitor` when `decision.action() != NONE`.
Consumers observe: `void onPressure(@ObservesAsync CapacityPressureEvent event)`.

## Part 3 — Runtime Implementations (platform/)

### Package: `io.casehub.platform.capacity`

### AggregatingActorCapacityView

```java
@ApplicationScoped
public class AggregatingActorCapacityView implements ActorCapacityView {

    @Inject @Any
    Instance<CapacitySignalSource> signalSources;

    private final Map<String, List<CapacitySignal>> signalCache =
            new ConcurrentHashMap<>();

    public void refresh() {
        Map<String, List<CapacitySignal>> fresh = new ConcurrentHashMap<>();
        for (CapacitySignalSource source : signalSources) {
            for (CapacitySignal signal : source.signals()) {
                fresh.computeIfAbsent(signal.actorId(), k -> new CopyOnWriteArrayList<>())
                     .add(signal);
            }
        }
        signalCache.clear();
        signalCache.putAll(fresh);
    }

    @Override
    public CapacitySignal aggregatedPressure(String actorId) {
        List<CapacitySignal> signals = signalCache.getOrDefault(actorId, List.of());
        if (signals.isEmpty()) {
            return new CapacitySignal(actorId, "aggregated", 0.0, Instant.now());
        }
        double maxPressure = signals.stream()
                .mapToDouble(CapacitySignal::pressure)
                .max().orElse(0.0);
        return new CapacitySignal(actorId, "aggregated", maxPressure, Instant.now());
    }

    @Override
    public List<CapacitySignal> signalsByActor(String actorId) {
        return List.copyOf(signalCache.getOrDefault(actorId, List.of()));
    }

    @Override
    public List<CapacitySignal> allAggregatedPressures() {
        return signalCache.keySet().stream()
                .map(this::aggregatedPressure)
                .toList();
    }
}
```

CDI-discovers all `CapacitySignalSource` beans. `refresh()` collects all
signals into a `ConcurrentHashMap` cache keyed by actorId. The monitor
calls `refresh()` before each sweep.

### DefaultRedistributionPolicy

```java
@ApplicationScoped
public class DefaultRedistributionPolicy implements RedistributionPolicy {

    @ConfigProperty(name = "casehub.capacity.threshold.compress",
                    defaultValue = "0.7")
    double compressThreshold;

    @ConfigProperty(name = "casehub.capacity.threshold.redistribute",
                    defaultValue = "0.85")
    double redistributeThreshold;

    @ConfigProperty(name = "casehub.capacity.threshold.escalate",
                    defaultValue = "0.95")
    double escalateThreshold;

    @Override
    public RedistributionDecision evaluate(RedistributionContext context) {
        double pressure = context.aggregatedSignal().pressure();

        if (pressure >= escalateThreshold) {
            return RedistributionDecision.escalate(
                    "pressure " + pressure + " exceeds escalate threshold "
                    + escalateThreshold);
        }
        if (pressure >= redistributeThreshold) {
            return RedistributionDecision.redistribute(
                    "pressure " + pressure + " exceeds redistribute threshold "
                    + redistributeThreshold);
        }
        if (pressure >= compressThreshold) {
            return RedistributionDecision.compress(
                    "pressure " + pressure + " exceeds compress threshold "
                    + compressThreshold);
        }
        return RedistributionDecision.none();
    }
}
```

Three configurable thresholds evaluated highest-first. `@ConfigProperty`
with sensible defaults. Consumers can replace via `@Alternative @Priority`.

### CapacityPressureMonitor

```java
@ApplicationScoped
public class CapacityPressureMonitor {

    @Inject
    AggregatingActorCapacityView capacityView;

    @Inject
    RedistributionPolicy policy;

    @Inject
    Event<CapacityPressureEvent> pressureEvent;

    @ConfigProperty(name = "casehub.capacity.monitor.interval",
                    defaultValue = "30s")
    Duration interval;

    @ConfigProperty(name = "casehub.capacity.monitor.enabled",
                    defaultValue = "true")
    boolean enabled;

    @Scheduled(every = "${casehub.capacity.monitor.interval:30s}",
               concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    void sweep() {
        if (!enabled) return;

        capacityView.refresh();

        for (CapacitySignal aggregated : capacityView.allAggregatedPressures()) {
            RedistributionContext context = new RedistributionContext(
                    aggregated.actorId(),
                    aggregated,
                    capacityView.signalsByActor(aggregated.actorId()));

            RedistributionDecision decision = policy.evaluate(context);

            if (decision.action() != RedistributionAction.NONE) {
                pressureEvent.fireAsync(new CapacityPressureEvent(
                        aggregated.actorId(), decision, aggregated, Instant.now()));
            }
        }
    }
}
```

`@Scheduled` sweep with configurable interval (default 30s). Skips
concurrent execution. Disabled by default in test profiles via
`casehub.capacity.monitor.enabled=false`.

Flow: refresh signals → aggregate per actor → evaluate policy → fire
event for actionable decisions.

## Backward Compatibility

All new types. No changes to existing APIs. `ActorStateContributor` and
`ActorStateAccumulator` are unchanged.

## Test Plan

### platform-api tests (unit — pure Java)

| Test | Coverage |
|------|----------|
| `CapacitySignal_validates_pressure_range` | pressure < 0 and > 1 throw |
| `CapacitySignal_validates_required_fields` | null actorId/source throw |
| `CapacitySignal_defaults_timestamp` | null timestamp → Instant.now() |
| `RedistributionDecision_factories` | each factory produces correct action |
| `RedistributionContext_null_defaults` | null sourceSignals → empty list |

### platform/ tests (@QuarkusTest)

| Test | Coverage |
|------|----------|
| `AggregatingView_no_sources_empty` | no signal sources → pressure 0.0 |
| `AggregatingView_single_source` | one source → signals returned |
| `AggregatingView_max_pressure_across_sources` | two sources, max wins |
| `AggregatingView_multiple_actors` | signals grouped by actorId |
| `AggregatingView_refresh_replaces_cache` | stale signals replaced |
| `DefaultPolicy_below_all_thresholds` | pressure 0.5 → NONE |
| `DefaultPolicy_compress_threshold` | pressure 0.75 → COMPRESS |
| `DefaultPolicy_redistribute_threshold` | pressure 0.9 → REDISTRIBUTE |
| `DefaultPolicy_escalate_threshold` | pressure 0.97 → ESCALATE |
| `DefaultPolicy_custom_thresholds` | config override respected |
| `Monitor_fires_event_on_pressure` | COMPRESS/REDISTRIBUTE/ESCALATE → event fired |
| `Monitor_no_event_below_threshold` | pressure 0.3 → no event |
| `Monitor_disabled_skips_sweep` | enabled=false → no sweep |

## References

- `io.casehub.platform.api.actor.ActorStateContributor` — existing parallel SPI pattern
- `io.casehub.platform.api.actor.ActorStateAccumulator` — existing accumulator pattern
- `io.casehub.platform.api.governance.ExecutionPolicy` — existing policy record pattern
- `platform/` existing @DefaultBean implementations
- casehubio/platform#268 — this issue
- casehubio/qhorus#405 — first consumer (qhorus redistribution)
- `decisions.md` — D1–D6 design decisions
