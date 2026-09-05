# Capacity Signal SPI + Redistribution Policy — Batch 1 Design Spec

**Issue:** casehubio/platform#268
**Scope:** casehub-platform-api + casehub-platform (Batch 1 only)
**Status:** validated
**Cross-platform spec:** `wsp-casehub-qhorus/specs/cross-platform-capacity-redistribution/2026-09-02-capacity-redistribution-design.md`

---

## Problem Statement

Three casehub systems independently detect actor overload using incompatible vocabularies:
- **Qhorus** measures `context_window_pct` (0-100) via CONTEXT_PRESSURE watchdog
- **Engine** measures `activeTaskCount` / `maxActiveTaskCount` via `WorkloadConstraint`
- **Platform agent-gate** measures concurrent sessions vs semaphore

No system can see another's load signals. No post-assignment redistribution exists — once work is assigned, it stays even when the actor is saturated.

## Design Scope

Batch 1 delivers the **shared vocabulary and default policy** in platform-api and platform. Domain signal sources and redistribution executors are Batch 2+ (eidos, qhorus, engine).

What Batch 1 provides:
- SPIs that all domains implement to expose their load signals
- A unified capacity view that aggregates signals across domains
- A policy SPI that decides what to do when an actor is overloaded
- A `@Scheduled` monitor that sweeps and fires CDI events
- `@DefaultBean` defaults for all SPIs — existing deployments see no change (aggregator with zero sources returns 0.0, default policy handles all pressure levels)

What Batch 1 does NOT provide:
- Domain signal source implementations (qhorus, engine, platform-gate)
- Redistribution executors (domain-specific)
- Eidos selection enrichment (`SelectionContext.capacityView`)

### Deferred Work — GitHub Issue Tracking

| Batch | Work Item | Repo | Issue |
|-------|-----------|------|-------|
| 2 | Eidos `SelectionContext.capacityView` + `Overloaded` probe | eidos | casehubio/eidos#151 |
| 3 | Qhorus `ContextPressureCapacitySource` + redistribution executor | qhorus | casehubio/qhorus#428 |
| 3 | Platform gate `SessionCapacitySource` | platform | TBD — file before Batch 1 merge |
| 4 | Engine `WorkloadCapacitySource` | engine | TBD — file before Batch 1 merge |
| — | Engine `ActorStateAccumulatorImpl.capacity()` override | engine | TBD — file before Batch 1 merge |

---

## Architecture — Call Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ Platform (@Scheduled)                                           │
│                                                                 │
│   CapacityPressureMonitor                                       │
│     → iterates CapacitySignalSource.observeOverloaded(threshold)│
│     → aggregates via AggregatingActorCapacityView               │
│     → fires CapacityPressureEvent for each overloaded actor     │
└──────────────────────────┬──────────────────────────────────────┘
                           │ CDI @ObservesAsync
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ Domain Executor (qhorus, engine — Batch 2+)                     │
│                                                                 │
│   1. Receives CapacityPressureEvent(actorId, capacity)          │
│   2. Queries own domain state (open obligations, last activity) │
│   3. Builds RedistributionContext                               │
│   4. Calls RedistributionPolicy.evaluate(context)               │
│   5. Acts on RedistributionDecision                             │
└─────────────────────────────────────────────────────────────────┘
```

The domain executor is the composer — it bridges platform capacity signals with domain-specific workload state. The policy stays domain-agnostic. Multiple domain executors may act on the same event independently; over-correction is self-healing (next sweep sees reduced pressure, grace periods provide coordination window).

---

## Layer 0: Observe — Shared Capacity Vocabulary

**Module: platform-api** — package `io.casehub.platform.api.capacity`

### CapacitySignal

```java
public record CapacitySignal(
    String actorId,
    String signalType,
    double pressure,       // 0.0 = idle, 1.0 = saturated, >1.0 = overloaded
    Instant observedAt,
    Map<String, String> metadata
) {
    public CapacitySignal {
        Objects.requireNonNull(actorId);
        Objects.requireNonNull(signalType);
        Objects.requireNonNull(observedAt);
        metadata = metadata == null ? Map.of() : Map.copyOf(metadata);
        if (pressure < 0.0) throw new IllegalArgumentException("pressure must be >= 0.0");
    }
}
```

Signals are tenant-agnostic — an agent's context window and session slots are physical resources shared across tenants. Pressure represents aggregate physical state (D4).

### CapacitySignalSource

```java
/**
 * SPI for observing capacity pressure signals from a specific domain.
 *
 * <p>CDI discovery: implementations annotate {@code @ApplicationScoped}.
 * The aggregator collects all beans via {@code @Any Instance<CapacitySignalSource>}.
 *
 * <p>Thread-safety: implementations must be safe for concurrent access —
 * the monitor sweep and ad-hoc queries may invoke methods concurrently.
 */
public interface CapacitySignalSource {

    /**
     * Stable signal type identifier for this source.
     * Must be unique across all sources — two sources must not share a signal type.
     * Use constants from {@link CapacitySignalTypes} where applicable.
     */
    String signalType();

    /**
     * Observe the current capacity pressure for a specific actor.
     *
     * @param actorId the actor identity string
     * @return the current signal, or {@code Optional.empty()} for actors
     *         this source does not monitor. Never null.
     */
    Optional<CapacitySignal> observe(String actorId);

    /**
     * Return all actors whose pressure is at or above the threshold.
     *
     * <p>Semantics: return signals where {@code pressure >= threshold},
     * consistent with {@link ActorCapacity#isOverloaded(double)}.
     *
     * @param threshold the pressure threshold (inclusive lower bound)
     * @return all overloaded signals; empty list if none. Never null.
     */
    List<CapacitySignal> observeOverloaded(double threshold);
}
```

### CapacitySignalTypes

```java
public final class CapacitySignalTypes {
    public static final String CONTEXT_PRESSURE = "context_pressure";
    public static final String TASK_COUNT = "task_count";
    public static final String SESSION_COUNT = "session_count";

    private CapacitySignalTypes() {}
}
```

String constants, not an enum — consistent with `EndpointPropertyKeys`, `DeliveryChannels`. Extensible by domain repos.

### ActorCapacity

```java
public record ActorCapacity(
    String actorId,
    double aggregatePressure,
    Map<String, Double> pressureBySignalType,
    Instant observedAt
) {
    public ActorCapacity {
        Objects.requireNonNull(actorId);
        Objects.requireNonNull(observedAt);
        pressureBySignalType = pressureBySignalType == null
                ? Map.of() : Map.copyOf(pressureBySignalType);
    }

    public boolean isOverloaded(double threshold) {
        return aggregatePressure >= threshold;
    }
}
```

### ActorCapacityView

```java
/**
 * Aggregated view of actor capacity pressure across all signal sources.
 *
 * <p>All methods return non-null values. For unknown or unmonitored actors,
 * {@link #getCapacity} returns zero aggregate pressure with an empty signal type map.
 *
 * <p>Separate from {@code ActorStateContributor}/{@code ActorStateAccumulator} (D1) —
 * different query model (multi-actor scan vs single-actor push), different purpose
 * (operational monitoring vs dashboard read model), different consumers
 * ({@code @Scheduled} sweep vs REST endpoint).
 */
public interface ActorCapacityView {

    /**
     * Get the aggregated capacity for a specific actor.
     *
     * @param actorId the actor identity string
     * @return non-null capacity; zero pressure with empty signals for unknown actors
     */
    ActorCapacity getCapacity(String actorId);

    /**
     * Find all actors whose aggregate pressure is at or above the threshold.
     *
     * @param threshold the pressure threshold (inclusive, consistent with
     *                  {@link ActorCapacity#isOverloaded(double)})
     * @return all overloaded actors; empty list if none. Never null.
     */
    List<ActorCapacity> getOverloaded(double threshold);
}
```

---

## Layer 1: Select — Eidos Enrichment (Batch 2, deferred)

Deferred to Batch 2. `SelectionContext.capacityView` enrichment enables load-aware agent selection — `CapabilityHealth` gains an `Overloaded` probe step. See casehubio/eidos#151.

---

## Layer 2: Decide — Redistribution Policy

**Module: platform-api** — package `io.casehub.platform.api.capacity`

### RedistributionPolicy

```java
public interface RedistributionPolicy {
    RedistributionDecision evaluate(RedistributionContext context);
}
```

### RedistributionContext

```java
public record RedistributionContext(
    String actorId,
    ActorCapacity capacity,
    String triggerSignalType,
    int openObligationCount,
    Duration timeSinceLastActivity
) {
    public RedistributionContext {
        Objects.requireNonNull(actorId);
        Objects.requireNonNull(capacity);
        Objects.requireNonNull(triggerSignalType);
        Objects.requireNonNull(timeSinceLastActivity);
    }
}
```

Built by domain executors (D2), not by platform. The executor queries its own domain state for `openObligationCount` and `timeSinceLastActivity`, then calls the policy.

### RedistributionDecision

```java
public sealed interface RedistributionDecision {
    record Redistribute(String reason, Duration gracePeriod,
                        Set<String> excludeActors) implements RedistributionDecision {}
    record Compress(String reason) implements RedistributionDecision {}
    record Hold(String reason) implements RedistributionDecision {}
    record Escalate(String reason) implements RedistributionDecision {}
}
```

The decision says WHAT to do. HOW MUCH to redistribute and circular guard logic are domain executor responsibilities (D5).

### CapacityPressureEvent

```java
/**
 * CDI event fired by CapacityPressureMonitor for each overloaded actor.
 *
 * <p>Observers receive this event via @ObservesAsync on a managed thread pool
 * where @RequestScoped context is not active. Do not inject @RequestScoped
 * beans (e.g., CurrentPrincipal) in observers. Use @ActivateRequestContext
 * if request-scoped access is required.
 *
 * <p>triggerSignalType is the highest-pressure signal type, with lexicographic
 * tie-breaking when multiple signals share the same max pressure.
 */
public record CapacityPressureEvent(
    String actorId,
    ActorCapacity capacity,
    double threshold,
    String triggerSignalType
) {}
```

CDI event fired by `CapacityPressureMonitor`. Raw observation only — carries no decision. Domain executors observe, compose context, and call the policy.

---

## Layer 0.5: Aggregate + Monitor — Platform Implementations

**Module: platform** — package `io.casehub.platform.capacity`

### AggregatingActorCapacityView

```java
@DefaultBean
@ApplicationScoped
public class AggregatingActorCapacityView implements ActorCapacityView {

    private static final Logger LOG = Logger.getLogger(AggregatingActorCapacityView.class);

    @Any Instance<CapacitySignalSource> sources;

    @Override
    public ActorCapacity getCapacity(String actorId) {
        Map<String, Double> pressures = new LinkedHashMap<>();

        for (var source : sources) {
            try {
                source.observe(actorId).ifPresent(signal ->
                    pressures.put(signal.signalType(), signal.pressure()));
            } catch (Exception e) {
                LOG.warnf("Signal source %s failed for actorId=%s: %s",
                        source.signalType(), actorId, e.getMessage());
            }
        }

        double aggregate = pressures.values().stream()
                .mapToDouble(Double::doubleValue)
                .max().orElse(0.0);

        return new ActorCapacity(actorId, aggregate,
                Map.copyOf(pressures), Instant.now());
    }

    @Override
    public List<ActorCapacity> getOverloaded(double threshold) {
        Map<String, Map<String, Double>> byActor = new LinkedHashMap<>();

        for (var source : sources) {
            try {
                for (var signal : source.observeOverloaded(threshold)) {
                    byActor.computeIfAbsent(signal.actorId(), k -> new LinkedHashMap<>())
                            .put(signal.signalType(), signal.pressure());
                }
            } catch (Exception e) {
                LOG.warnf("Signal source %s failed during sweep: %s",
                        source.signalType(), e.getMessage());
            }
        }

        return byActor.entrySet().stream()
                .map(e -> {
                    double agg = e.getValue().values().stream()
                            .mapToDouble(Double::doubleValue).max().orElse(0.0);
                    return new ActorCapacity(e.getKey(), agg,
                            Map.copyOf(e.getValue()), Instant.now());
                })
                .filter(c -> c.isOverloaded(threshold))
                .toList();
    }
}
```

Aggregation strategy: max-pressure across signal types (D3). An agent at 0.9 context pressure and 0.3 task count is at 0.9 aggregate — any single saturated dimension is a redistribution trigger.

### DefaultRedistributionPolicy

```java
@DefaultBean
@ApplicationScoped
public class DefaultRedistributionPolicy implements RedistributionPolicy {

    @ConfigProperty(name = "casehub.capacity.redistribution.compress-threshold",
                    defaultValue = "0.7")
    double compressThreshold;

    @ConfigProperty(name = "casehub.capacity.redistribution.redistribute-threshold",
                    defaultValue = "0.85")
    double redistributeThreshold;

    @ConfigProperty(name = "casehub.capacity.redistribution.immediate-threshold",
                    defaultValue = "0.95")
    double immediateThreshold;

    @ConfigProperty(name = "casehub.capacity.redistribution.grace-period",
                    defaultValue = "PT30S")
    Duration gracePeriod;

    @ConfigProperty(name = "casehub.capacity.redistribution.inactivity-escalation",
                    defaultValue = "PT5M")
    Duration inactivityEscalation;

    @Override
    public RedistributionDecision evaluate(RedistributionContext context) {
        double pressure = context.capacity().aggregatePressure();

        if (context.timeSinceLastActivity().compareTo(inactivityEscalation) > 0) {
            return new RedistributionDecision.Escalate(
                    "inactive for " + context.timeSinceLastActivity());
        }

        if (pressure < compressThreshold) {
            return new RedistributionDecision.Hold("within tolerance");
        }

        if (pressure < redistributeThreshold) {
            return new RedistributionDecision.Compress(
                    "pressure " + pressure + " above compress threshold");
        }

        if (context.openObligationCount() == 0) {
            return new RedistributionDecision.Hold(
                    "overloaded but no movable work");
        }

        Duration effectiveGrace = pressure >= immediateThreshold
                ? Duration.ZERO : gracePeriod;

        return new RedistributionDecision.Redistribute(
                "pressure " + pressure + " above redistribute threshold",
                effectiveGrace, Set.of(context.actorId()));
    }
}
```

| Pressure | Open Obligations | Decision |
|----------|-----------------|----------|
| any, inactive > 5m | any | Escalate |
| < 0.7 | any | Hold |
| \>= 0.7 and < 0.85 | any | Compress |
| \>= 0.85 and < 0.95 | > 0 | Redistribute (grace 30s) |
| \>= 0.95 | > 0 | Redistribute (immediate) |
| \>= 0.85 | 0 | Hold (nothing to move) |

### CapacityPressureMonitor

```java
@ApplicationScoped
public class CapacityPressureMonitor {

    private static final Logger LOG = Logger.getLogger(CapacityPressureMonitor.class);

    @Inject ActorCapacityView capacityView;
    @Inject Event<CapacityPressureEvent> pressureEvent;

    @ConfigProperty(name = "casehub.capacity.redistribution.compress-threshold",
                    defaultValue = "0.7")
    double sweepThreshold;

    @Scheduled(every = "${casehub.capacity.sweep-interval:60s}",
               identity = "capacity-pressure-sweep")
    void sweep() {
        List<ActorCapacity> overloaded = capacityView.getOverloaded(sweepThreshold);

        for (var capacity : overloaded) {
            String trigger = capacity.pressureBySignalType().entrySet().stream()
                    .max(Map.Entry.<String, Double>comparingByValue()
                            .thenComparing(Map.Entry.comparingByKey()))
                    .map(Map.Entry::getKey)
                    .orElse("unknown");

            LOG.debugf("Actor %s overloaded: pressure=%.2f, trigger=%s",
                    capacity.actorId(), capacity.aggregatePressure(), trigger);

            pressureEvent.fireAsync(new CapacityPressureEvent(
                    capacity.actorId(), capacity, sweepThreshold, trigger));
        }
    }
}
```

Single sweep prevents event storms — individual sources don't fire events directly.

### CapacityActorStateContributor

```java
@ApplicationScoped
public class CapacityActorStateContributor implements ActorStateContributor {

    @Inject ActorCapacityView capacityView;

    @Override
    public String sourceName() {
        return "capacity";
    }

    @Override
    public void contribute(String actorId, ActorStateAccumulator accumulator) {
        ActorCapacity cap = capacityView.getCapacity(actorId);
        accumulator.capacity(cap.aggregatePressure(), cap.pressureBySignalType());
    }
}
```

Bridges capacity data into the actor state dashboard (D6). When signal sources are present, the dashboard shows capacity alongside trust scores and work items. When no sources exist, `AggregatingActorCapacityView` returns 0.0 — the contributor reports zero pressure.

### ActorStateAccumulator extension (platform-api)

Add one default method to the existing `ActorStateAccumulator` interface:

```java
default void capacity(double aggregatePressure, Map<String, Double> pressureBySignalType) {}
```

Default no-op follows the visitor pattern evolution convention — "if you don't have data for this dimension, contribute nothing." `ActorStateAccumulatorImpl` in engine-actor-state should override this method to surface capacity data in `ActorStateResponse`. Engine-side changes (tracked in casehubio/engine#TBD):
1. `ActorStateAccumulatorImpl` — new `ConcurrentHashMap<String, Double>` field + method override
2. `ActorStateResponse` — new `double aggregatePressure` + `Map<String, Double> pressureBySignalType` fields
3. `ActorStateAccumulatorImpl.build()` — pass new fields to response record

### No-Op Defaults

```java
// platform-api — NoOpCapacitySignalSource not needed (Instance<> is empty when no sources)
```

No separate NoOp beans needed for `ActorCapacityView` or `RedistributionPolicy`:
- `AggregatingActorCapacityView` is `@DefaultBean` — with zero signal sources, it returns 0.0 pressure and empty overloaded list (inherently no-op). Domain repos can override with `@ApplicationScoped`.
- `DefaultRedistributionPolicy` is `@DefaultBean` — handles all pressure levels including below-threshold (`Hold("within tolerance")`). Domain repos can override with `@ApplicationScoped`.

---

## Module Placement

| Type | Module | Package |
|------|--------|---------|
| `CapacitySignal` | platform-api | `io.casehub.platform.api.capacity` |
| `CapacitySignalSource` | platform-api | `io.casehub.platform.api.capacity` |
| `CapacitySignalTypes` | platform-api | `io.casehub.platform.api.capacity` |
| `ActorCapacity` | platform-api | `io.casehub.platform.api.capacity` |
| `ActorCapacityView` | platform-api | `io.casehub.platform.api.capacity` |
| `RedistributionPolicy` | platform-api | `io.casehub.platform.api.capacity` |
| `RedistributionContext` | platform-api | `io.casehub.platform.api.capacity` |
| `RedistributionDecision` | platform-api | `io.casehub.platform.api.capacity` |
| `CapacityPressureEvent` | platform-api | `io.casehub.platform.api.capacity` |
| `AggregatingActorCapacityView` | platform | `io.casehub.platform.capacity` |
| `DefaultRedistributionPolicy` | platform | `io.casehub.platform.capacity` |
| `CapacityActorStateContributor` | platform | `io.casehub.platform.capacity` |
| `CapacityPressureMonitor` | platform | `io.casehub.platform.capacity` |

---

## Configuration

| Key | Default | Where |
|-----|---------|-------|
| `casehub.capacity.sweep-interval` | `60s` | platform |
| `casehub.capacity.redistribution.compress-threshold` | `0.7` | platform (also used by `CapacityPressureMonitor` as sweep threshold) |
| `casehub.capacity.redistribution.redistribute-threshold` | `0.85` | platform |
| `casehub.capacity.redistribution.immediate-threshold` | `0.95` | platform |
| `casehub.capacity.redistribution.grace-period` | `PT30S` | platform |
| `casehub.capacity.redistribution.inactivity-escalation` | `PT5M` | platform |

---

## Testing Strategy

All tests are CDI-free plain JUnit — following the dual-constructor pattern from GE-20260602-c4a68a.

### Unit Tests

1. **`CapacitySignalTest`** — validation: null actorId, negative pressure, metadata defensive copy
2. **`ActorCapacityTest`** — `isOverloaded()` boundary: at threshold, above, below, zero pressure
3. **`AggregatingActorCapacityViewTest`**
   - Single source, single actor
   - Multiple sources, same actor — max-pressure aggregation
   - Multiple sources, multiple actors — deduplication in `getOverloaded()`
   - No sources — returns 0.0 pressure
   - Source returns empty for `observe()` — skipped, no NPE
   - Exception in one source doesn't prevent aggregation of others
4. **`DefaultRedistributionPolicyTest`**
   - Each row in the decision table
   - Boundary conditions at threshold values
   - Inactivity escalation takes precedence regardless of pressure
   - Zero obligations + high pressure → Hold
5. **`CapacityActorStateContributorTest`**
   - Writes aggregate pressure and per-signal-type map to accumulator
   - Zero pressure when no signal sources exist
6. **`CapacityPressureMonitorTest`**
   - Fires event for each overloaded actor
   - Identifies highest-pressure signal type as trigger (lexicographic tie-break)
   - No overloaded actors → no events fired
   - Exception in one source doesn't prevent sweep of others

---

## Relationship to Existing Infrastructure

### Separate from (not replacing) — but bridged

| Component | Relationship |
|-----------|-------------|
| `ActorStateContributor`/`ActorStateAccumulator` (platform-api) | Different query model, purpose, consumers (D1). Connected via `CapacityActorStateContributor` bridge and new `capacity()` method on `ActorStateAccumulator` (D6) |
| `ActorStateAggregator` (engine/actor-state) | Complementary — dashboard read model gains capacity data via the contributor bridge |

### Reused by (Batch 2+, not this issue)

| Component | Role |
|-----------|------|
| `SelectionContext` (eidos-api) | Gains `capacityView` field for load-aware agent selection |
| `CapabilityHealth` probe chain (eidos) | New `Overloaded` probe step after `BehavioralViolation` |
| `RoutingBridge` (qhorus) | Target selection for redistribution HANDOFFs |
| `CIRCULAR_DELEGATION` watchdog (qhorus) | Existing guard against redistribution ping-pong |

---

## References

- `platform-api/src/main/java/io/casehub/platform/api/actor/ActorStateContributor.java` — existing actor state SPI, validated as separate concern
- `platform-api/src/main/java/io/casehub/platform/api/actor/ActorStateAccumulator.java` — existing accumulator pattern
- `engine/actor-state/src/main/java/io/casehub/actorstate/ActorStateAggregator.java` — existing aggregator with ManagedExecutor
- `eidos/api/src/main/java/io/casehub/eidos/api/CapabilityHealth.java` — existing probe chain (no Overloaded status yet)
- `eidos/api/src/main/java/io/casehub/eidos/api/SelectionContext.java` — 3-field record (Batch 2 adds capacityView)
- GE-20260602-c4a68a — dual-constructor aggregator pattern for CDI-free testing
- GE-20260602-047ac4 — visitor/accumulator pattern for thread-safe multi-backend aggregation
- `~/casehub/parent/docs/platform/boundary-rules.md` — validated: no boundary violations
- `~/casehub/parent/docs/platform/capability-ownership.md` — validated: no existing capacity capability
- `wsp-casehub-qhorus/specs/cross-platform-capacity-redistribution/2026-09-02-capacity-redistribution-design.md` — cross-platform parent spec
