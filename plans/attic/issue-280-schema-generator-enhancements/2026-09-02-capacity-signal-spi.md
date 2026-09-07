# Capacity Signal SPI + Redistribution Policy — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #268 — feat: capacity signal SPI + redistribution policy framework
**Issue group:** #268

**Goal:** Deliver shared capacity vocabulary (pressure 0.0–1.0), observation SPIs, redistribution policy SPI, and default implementations in platform-api + platform.

**Architecture:** Nine new types in `io.casehub.platform.api.capacity` (platform-api) define the shared vocabulary — value records, SPI interfaces, a CDI event, and a sealed decision type. Four implementations in `io.casehub.platform.capacity` (platform) provide default behavior: an aggregating capacity view with error isolation, a configurable threshold-based policy, a `@Scheduled` pressure monitor, and a bridge contributor to the existing actor state dashboard. One default method added to the existing `ActorStateAccumulator` interface.

**Tech Stack:** Java 21+ (records, sealed interfaces, pattern matching), CDI (`@ApplicationScoped`, `@DefaultBean`, `@Any Instance<>`, `Event.fireAsync()`), SmallRye Config (`@ConfigProperty`), Quarkus Scheduler (`@Scheduled`), JUnit 5 + AssertJ (CDI-free, dual-constructor pattern)

## Global Constraints

- `platform-api/` is zero-dependency — no Quarkus, no JPA, no casehubio imports. Pure Java only.
- All new types use `java.time.*`, `java.util.*` — no domain types cross the platform-api boundary.
- All platform implementations use `@DefaultBean` — displaced by `@ApplicationScoped` in domain repos.
- Tests are CDI-free plain JUnit using the dual-constructor pattern (GE-20260602-c4a68a).
- Package: `io.casehub.platform.api.capacity` (platform-api), `io.casehub.platform.capacity` (platform).
- `isOverloaded()` uses `>=` (inclusive threshold — R1-03).
- Sweep threshold reuses `casehub.capacity.redistribution.compress-threshold` — single config key (R1-04).
- `ActorStateAccumulator.capacity()` is a `default` no-op method — non-breaking (R1-05).

---

## Batch 1: Platform-API SPI Types

### Task 1: Value types, SPIs, CDI event, and ActorStateAccumulator extension

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/CapacitySignal.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/CapacitySignalTypes.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/ActorCapacity.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/CapacitySignalSource.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/ActorCapacityView.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/RedistributionPolicy.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/RedistributionContext.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/RedistributionDecision.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/CapacityPressureEvent.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/actor/ActorStateAccumulator.java` — add default `capacity()` method
- Test: `platform-api/src/test/java/io/casehub/platform/api/capacity/CapacitySignalTest.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/capacity/ActorCapacityTest.java`

**Interfaces:**
- Consumes: nothing (foundation types)
- Produces: `CapacitySignal`, `CapacitySignalSource`, `ActorCapacity`, `ActorCapacityView`, `RedistributionPolicy`, `RedistributionContext`, `RedistributionDecision`, `CapacityPressureEvent`, `CapacitySignalTypes` — all used by Batch 2 platform implementations

- [ ] **Step 1: Create package directory**

```bash
mkdir -p platform-api/src/main/java/io/casehub/platform/api/capacity
mkdir -p platform-api/src/test/java/io/casehub/platform/api/capacity
```

- [ ] **Step 2: Write CapacitySignal record**

Create `platform-api/src/main/java/io/casehub/platform/api/capacity/CapacitySignal.java`:

```java
package io.casehub.platform.api.capacity;

import java.time.Instant;
import java.util.Map;
import java.util.Objects;

public record CapacitySignal(
    String actorId,
    String signalType,
    double pressure,
    Instant observedAt,
    Map<String, String> metadata
) {
    public CapacitySignal {
        Objects.requireNonNull(actorId, "actorId");
        Objects.requireNonNull(signalType, "signalType");
        Objects.requireNonNull(observedAt, "observedAt");
        metadata = metadata == null ? Map.of() : Map.copyOf(metadata);
        if (pressure < 0.0) throw new IllegalArgumentException("pressure must be >= 0.0");
    }
}
```

- [ ] **Step 3: Write CapacitySignalTypes constants**

Create `platform-api/src/main/java/io/casehub/platform/api/capacity/CapacitySignalTypes.java`:

```java
package io.casehub.platform.api.capacity;

public final class CapacitySignalTypes {
    public static final String CONTEXT_PRESSURE = "context_pressure";
    public static final String TASK_COUNT = "task_count";
    public static final String SESSION_COUNT = "session_count";

    private CapacitySignalTypes() {}
}
```

- [ ] **Step 4: Write ActorCapacity record**

Create `platform-api/src/main/java/io/casehub/platform/api/capacity/ActorCapacity.java`:

```java
package io.casehub.platform.api.capacity;

import java.time.Instant;
import java.util.Map;
import java.util.Objects;

public record ActorCapacity(
    String actorId,
    double aggregatePressure,
    Map<String, Double> pressureBySignalType,
    Instant observedAt
) {
    public ActorCapacity {
        Objects.requireNonNull(actorId, "actorId");
        Objects.requireNonNull(observedAt, "observedAt");
        pressureBySignalType = pressureBySignalType == null
                ? Map.of() : Map.copyOf(pressureBySignalType);
    }

    public boolean isOverloaded(double threshold) {
        return aggregatePressure >= threshold;
    }
}
```

- [ ] **Step 5: Write CapacitySignal tests**

Create `platform-api/src/test/java/io/casehub/platform/api/capacity/CapacitySignalTest.java`:

```java
package io.casehub.platform.api.capacity;

import org.junit.jupiter.api.Test;
import java.time.Instant;
import java.util.Map;

import static org.assertj.core.api.Assertions.*;

class CapacitySignalTest {

    @Test
    void valid_signal() {
        var signal = new CapacitySignal("agent-1", "context_pressure", 0.75,
                Instant.now(), Map.of("channel", "ch-1"));
        assertThat(signal.actorId()).isEqualTo("agent-1");
        assertThat(signal.pressure()).isEqualTo(0.75);
        assertThat(signal.metadata()).containsEntry("channel", "ch-1");
    }

    @Test
    void null_actorId_throws() {
        assertThatNullPointerException().isThrownBy(() ->
                new CapacitySignal(null, "type", 0.5, Instant.now(), null));
    }

    @Test
    void null_signalType_throws() {
        assertThatNullPointerException().isThrownBy(() ->
                new CapacitySignal("a", null, 0.5, Instant.now(), null));
    }

    @Test
    void null_observedAt_throws() {
        assertThatNullPointerException().isThrownBy(() ->
                new CapacitySignal("a", "t", 0.5, null, null));
    }

    @Test
    void negative_pressure_throws() {
        assertThatIllegalArgumentException().isThrownBy(() ->
                new CapacitySignal("a", "t", -0.1, Instant.now(), null));
    }

    @Test
    void zero_pressure_valid() {
        var signal = new CapacitySignal("a", "t", 0.0, Instant.now(), null);
        assertThat(signal.pressure()).isEqualTo(0.0);
    }

    @Test
    void pressure_above_one_valid() {
        var signal = new CapacitySignal("a", "t", 1.5, Instant.now(), null);
        assertThat(signal.pressure()).isEqualTo(1.5);
    }

    @Test
    void null_metadata_becomes_empty_map() {
        var signal = new CapacitySignal("a", "t", 0.5, Instant.now(), null);
        assertThat(signal.metadata()).isEmpty();
    }

    @Test
    void metadata_is_defensive_copy() {
        var mutable = new java.util.HashMap<String, String>();
        mutable.put("k", "v");
        var signal = new CapacitySignal("a", "t", 0.5, Instant.now(), mutable);
        mutable.put("k2", "v2");
        assertThat(signal.metadata()).doesNotContainKey("k2");
    }
}
```

- [ ] **Step 6: Write ActorCapacity tests**

Create `platform-api/src/test/java/io/casehub/platform/api/capacity/ActorCapacityTest.java`:

```java
package io.casehub.platform.api.capacity;

import org.junit.jupiter.api.Test;
import java.time.Instant;
import java.util.Map;

import static org.assertj.core.api.Assertions.*;

class ActorCapacityTest {

    @Test
    void isOverloaded_at_threshold_returns_true() {
        var cap = new ActorCapacity("a", 0.7, Map.of(), Instant.now());
        assertThat(cap.isOverloaded(0.7)).isTrue();
    }

    @Test
    void isOverloaded_above_threshold_returns_true() {
        var cap = new ActorCapacity("a", 0.8, Map.of(), Instant.now());
        assertThat(cap.isOverloaded(0.7)).isTrue();
    }

    @Test
    void isOverloaded_below_threshold_returns_false() {
        var cap = new ActorCapacity("a", 0.69, Map.of(), Instant.now());
        assertThat(cap.isOverloaded(0.7)).isFalse();
    }

    @Test
    void zero_pressure_not_overloaded() {
        var cap = new ActorCapacity("a", 0.0, Map.of(), Instant.now());
        assertThat(cap.isOverloaded(0.7)).isFalse();
    }

    @Test
    void null_actorId_throws() {
        assertThatNullPointerException().isThrownBy(() ->
                new ActorCapacity(null, 0.5, Map.of(), Instant.now()));
    }

    @Test
    void null_pressureBySignalType_becomes_empty() {
        var cap = new ActorCapacity("a", 0.5, null, Instant.now());
        assertThat(cap.pressureBySignalType()).isEmpty();
    }

    @Test
    void pressureBySignalType_is_defensive_copy() {
        var mutable = new java.util.HashMap<String, Double>();
        mutable.put("t", 0.5);
        var cap = new ActorCapacity("a", 0.5, mutable, Instant.now());
        mutable.put("t2", 0.9);
        assertThat(cap.pressureBySignalType()).doesNotContainKey("t2");
    }
}
```

- [ ] **Step 7: Run value type tests**

Run: `mvn --batch-mode test -pl platform-api -Dtest="CapacitySignalTest,ActorCapacityTest" -DfailIfNoTests=false`
Expected: All tests PASS.

- [ ] **Step 8: Write SPI interfaces**

Create `CapacitySignalSource.java`:

```java
package io.casehub.platform.api.capacity;

import java.util.List;
import java.util.Optional;

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

Create `ActorCapacityView.java`:

```java
package io.casehub.platform.api.capacity;

import java.util.List;

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

- [ ] **Step 9: Write decision types and CDI event**

Create `RedistributionDecision.java`:

```java
package io.casehub.platform.api.capacity;

import java.time.Duration;
import java.util.Set;

public sealed interface RedistributionDecision {
    record Redistribute(String reason, Duration gracePeriod,
                        Set<String> excludeActors) implements RedistributionDecision {}
    record Compress(String reason) implements RedistributionDecision {}
    record Hold(String reason) implements RedistributionDecision {}
    record Escalate(String reason) implements RedistributionDecision {}
}
```

Create `RedistributionContext.java`:

```java
package io.casehub.platform.api.capacity;

import java.time.Duration;
import java.util.Objects;

public record RedistributionContext(
    String actorId,
    ActorCapacity capacity,
    String triggerSignalType,
    int openObligationCount,
    Duration timeSinceLastActivity
) {
    public RedistributionContext {
        Objects.requireNonNull(actorId, "actorId");
        Objects.requireNonNull(capacity, "capacity");
        Objects.requireNonNull(triggerSignalType, "triggerSignalType");
        Objects.requireNonNull(timeSinceLastActivity, "timeSinceLastActivity");
    }
}
```

Create `RedistributionPolicy.java`:

```java
package io.casehub.platform.api.capacity;

public interface RedistributionPolicy {
    RedistributionDecision evaluate(RedistributionContext context);
}
```

Create `CapacityPressureEvent.java`:

```java
package io.casehub.platform.api.capacity;

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

- [ ] **Step 10: Add capacity() default method to ActorStateAccumulator**

Use `ide_edit_member` to add to `ActorStateAccumulator.java` at the end of the interface body:

```java
/**
 * Set the aggregated capacity pressure for this actor.
 *
 * <p>Default no-op — existing AccumulatorImpl implementations are not broken.
 * Override to surface capacity data in the actor state response.
 *
 * @param aggregatePressure   max-pressure across all signal sources (0.0 = idle, 1.0+ = overloaded)
 * @param pressureBySignalType per-signal-type breakdown; defensive copy recommended
 */
default void capacity(double aggregatePressure, Map<String, Double> pressureBySignalType) {}
```

Add `import java.util.Map;` to the imports if not already present.

- [ ] **Step 11: Compile platform-api**

Run: `mvn --batch-mode compile -pl platform-api`
Expected: BUILD SUCCESS — all types compile, no dependency violations.

- [ ] **Step 12: Run all platform-api tests**

Run: `mvn --batch-mode test -pl platform-api`
Expected: All tests PASS including new capacity tests and existing actor tests (default method is backward compatible).

- [ ] **Step 13: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/capacity/
git add platform-api/src/test/java/io/casehub/platform/api/capacity/
git add platform-api/src/main/java/io/casehub/platform/api/actor/ActorStateAccumulator.java
git commit -m "feat(#268): capacity signal SPI + redistribution policy types in platform-api

Refs #268"
```

---

## Batch 2: Platform Implementations

### Task 2: AggregatingActorCapacityView

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/capacity/AggregatingActorCapacityView.java`
- Test: `platform/src/test/java/io/casehub/platform/capacity/AggregatingActorCapacityViewTest.java`

**Interfaces:**
- Consumes: `CapacitySignalSource`, `CapacitySignal`, `ActorCapacity`, `ActorCapacityView` (from Task 1)
- Produces: `AggregatingActorCapacityView` — used by Task 4 (`CapacityPressureMonitor`) and Task 4 (`CapacityActorStateContributor`)

- [ ] **Step 1: Create package directory**

```bash
mkdir -p platform/src/main/java/io/casehub/platform/capacity
mkdir -p platform/src/test/java/io/casehub/platform/capacity
```

- [ ] **Step 2: Write the failing tests**

Create `platform/src/test/java/io/casehub/platform/capacity/AggregatingActorCapacityViewTest.java`:

```java
package io.casehub.platform.capacity;

import io.casehub.platform.api.capacity.*;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.*;

class AggregatingActorCapacityViewTest {

    @Test
    void getCapacity_single_source_single_actor() {
        var source = stubSource("context_pressure", "agent-1", 0.8);
        var view = new AggregatingActorCapacityView(List.of(source));

        var cap = view.getCapacity("agent-1");

        assertThat(cap.actorId()).isEqualTo("agent-1");
        assertThat(cap.aggregatePressure()).isEqualTo(0.8);
        assertThat(cap.pressureBySignalType()).containsEntry("context_pressure", 0.8);
    }

    @Test
    void getCapacity_multiple_sources_max_pressure() {
        var src1 = stubSource("context_pressure", "agent-1", 0.9);
        var src2 = stubSource("task_count", "agent-1", 0.3);
        var view = new AggregatingActorCapacityView(List.of(src1, src2));

        var cap = view.getCapacity("agent-1");

        assertThat(cap.aggregatePressure()).isEqualTo(0.9);
        assertThat(cap.pressureBySignalType())
                .containsEntry("context_pressure", 0.9)
                .containsEntry("task_count", 0.3);
    }

    @Test
    void getCapacity_no_sources_returns_zero() {
        var view = new AggregatingActorCapacityView(List.of());

        var cap = view.getCapacity("agent-1");

        assertThat(cap.aggregatePressure()).isEqualTo(0.0);
        assertThat(cap.pressureBySignalType()).isEmpty();
    }

    @Test
    void getCapacity_source_returns_empty_for_actor() {
        var source = stubSource("context_pressure", "other-agent", 0.8);
        var view = new AggregatingActorCapacityView(List.of(source));

        var cap = view.getCapacity("agent-1");

        assertThat(cap.aggregatePressure()).isEqualTo(0.0);
        assertThat(cap.pressureBySignalType()).isEmpty();
    }

    @Test
    void getCapacity_failing_source_is_isolated() {
        var good = stubSource("task_count", "agent-1", 0.5);
        var bad = failingSource("context_pressure");
        var view = new AggregatingActorCapacityView(List.of(bad, good));

        var cap = view.getCapacity("agent-1");

        assertThat(cap.aggregatePressure()).isEqualTo(0.5);
        assertThat(cap.pressureBySignalType()).containsOnlyKeys("task_count");
    }

    @Test
    void getOverloaded_deduplicates_across_sources() {
        var src1 = stubOverloaded("ctx", List.of(signal("agent-1", "ctx", 0.9)));
        var src2 = stubOverloaded("task", List.of(signal("agent-1", "task", 0.3)));
        var view = new AggregatingActorCapacityView(List.of(src1, src2));

        var result = view.getOverloaded(0.7);

        assertThat(result).hasSize(1);
        assertThat(result.get(0).actorId()).isEqualTo("agent-1");
        assertThat(result.get(0).aggregatePressure()).isEqualTo(0.9);
    }

    @Test
    void getOverloaded_multiple_actors() {
        var src = stubOverloaded("ctx", List.of(
                signal("agent-1", "ctx", 0.9),
                signal("agent-2", "ctx", 0.8)));
        var view = new AggregatingActorCapacityView(List.of(src));

        var result = view.getOverloaded(0.7);

        assertThat(result).hasSize(2);
        assertThat(result).extracting(ActorCapacity::actorId)
                .containsExactlyInAnyOrder("agent-1", "agent-2");
    }

    @Test
    void getOverloaded_filters_below_threshold_after_aggregation() {
        var src1 = stubOverloaded("ctx", List.of(signal("agent-1", "ctx", 0.6)));
        var view = new AggregatingActorCapacityView(List.of(src1));

        var result = view.getOverloaded(0.7);

        assertThat(result).isEmpty();
    }

    @Test
    void getOverloaded_no_sources_returns_empty() {
        var view = new AggregatingActorCapacityView(List.of());
        assertThat(view.getOverloaded(0.7)).isEmpty();
    }

    @Test
    void getOverloaded_failing_source_is_isolated() {
        var good = stubOverloaded("task", List.of(signal("agent-1", "task", 0.9)));
        var bad = failingSource("ctx");
        var view = new AggregatingActorCapacityView(List.of(bad, good));

        var result = view.getOverloaded(0.7);

        assertThat(result).hasSize(1);
        assertThat(result.get(0).actorId()).isEqualTo("agent-1");
    }

    // --- test helpers ---

    private static CapacitySignal signal(String actorId, String type, double pressure) {
        return new CapacitySignal(actorId, type, pressure, Instant.now(), Map.of());
    }

    private static CapacitySignalSource stubSource(String type, String actorId, double pressure) {
        return new CapacitySignalSource() {
            @Override public String signalType() { return type; }
            @Override public Optional<CapacitySignal> observe(String id) {
                return id.equals(actorId)
                        ? Optional.of(signal(actorId, type, pressure))
                        : Optional.empty();
            }
            @Override public List<CapacitySignal> observeOverloaded(double threshold) {
                return pressure >= threshold ? List.of(signal(actorId, type, pressure)) : List.of();
            }
        };
    }

    private static CapacitySignalSource stubOverloaded(String type, List<CapacitySignal> signals) {
        return new CapacitySignalSource() {
            @Override public String signalType() { return type; }
            @Override public Optional<CapacitySignal> observe(String id) { return Optional.empty(); }
            @Override public List<CapacitySignal> observeOverloaded(double threshold) { return signals; }
        };
    }

    private static CapacitySignalSource failingSource(String type) {
        return new CapacitySignalSource() {
            @Override public String signalType() { return type; }
            @Override public Optional<CapacitySignal> observe(String id) {
                throw new RuntimeException("source failure");
            }
            @Override public List<CapacitySignal> observeOverloaded(double threshold) {
                throw new RuntimeException("source failure");
            }
        };
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform -Dtest="AggregatingActorCapacityViewTest" -DfailIfNoTests=false`
Expected: FAIL — `AggregatingActorCapacityView` class not found.

- [ ] **Step 4: Write AggregatingActorCapacityView**

Create `platform/src/main/java/io/casehub/platform/capacity/AggregatingActorCapacityView.java`:

```java
package io.casehub.platform.capacity;

import io.casehub.platform.api.capacity.*;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.inject.Any;
import jakarta.enterprise.inject.Instance;
import jakarta.enterprise.inject.spi.CDI;
import jakarta.inject.Inject;
import jakarta.inject.Singleton;
import org.jboss.logging.Logger;

import java.time.Instant;
import java.util.*;

@DefaultBean
@Singleton
public class AggregatingActorCapacityView implements ActorCapacityView {

    private static final Logger LOG = Logger.getLogger(AggregatingActorCapacityView.class);

    private final Iterable<CapacitySignalSource> sources;

    @Inject
    public AggregatingActorCapacityView(@Any Instance<CapacitySignalSource> sources) {
        this((Iterable<CapacitySignalSource>) sources);
    }

    AggregatingActorCapacityView(List<CapacitySignalSource> sources) {
        this.sources = sources;
    }

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

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform -Dtest="AggregatingActorCapacityViewTest" -DfailIfNoTests=false`
Expected: All tests PASS.

- [ ] **Step 6: Commit**

```bash
git add platform/src/main/java/io/casehub/platform/capacity/
git add platform/src/test/java/io/casehub/platform/capacity/
git commit -m "feat(#268): AggregatingActorCapacityView — max-pressure aggregation with error isolation

Refs #268"
```

---

### Task 3: DefaultRedistributionPolicy

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/capacity/DefaultRedistributionPolicy.java`
- Test: `platform/src/test/java/io/casehub/platform/capacity/DefaultRedistributionPolicyTest.java`

**Interfaces:**
- Consumes: `RedistributionPolicy`, `RedistributionContext`, `RedistributionDecision`, `ActorCapacity` (from Task 1)
- Produces: `DefaultRedistributionPolicy` — used by domain executors (Batch 2+) via CDI injection

- [ ] **Step 1: Write the failing tests**

Create `platform/src/test/java/io/casehub/platform/capacity/DefaultRedistributionPolicyTest.java`:

```java
package io.casehub.platform.capacity;

import io.casehub.platform.api.capacity.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import java.time.Duration;
import java.time.Instant;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.*;

class DefaultRedistributionPolicyTest {

    private final DefaultRedistributionPolicy policy = new DefaultRedistributionPolicy(
            0.7, 0.85, 0.95, Duration.ofSeconds(30), Duration.ofMinutes(5));

    private RedistributionContext ctx(double pressure, int obligations, Duration inactive) {
        var cap = new ActorCapacity("agent-1", pressure, Map.of("ctx", pressure), Instant.now());
        return new RedistributionContext("agent-1", cap, "ctx", obligations, inactive);
    }

    @Test
    void below_compress_threshold_returns_hold() {
        var decision = policy.evaluate(ctx(0.5, 3, Duration.ofSeconds(10)));
        assertThat(decision).isInstanceOf(RedistributionDecision.Hold.class);
    }

    @Test
    void at_compress_threshold_returns_compress() {
        var decision = policy.evaluate(ctx(0.7, 3, Duration.ofSeconds(10)));
        assertThat(decision).isInstanceOf(RedistributionDecision.Compress.class);
    }

    @Test
    void between_compress_and_redistribute_returns_compress() {
        var decision = policy.evaluate(ctx(0.8, 3, Duration.ofSeconds(10)));
        assertThat(decision).isInstanceOf(RedistributionDecision.Compress.class);
    }

    @Test
    void at_redistribute_threshold_with_obligations_returns_redistribute() {
        var decision = policy.evaluate(ctx(0.85, 3, Duration.ofSeconds(10)));
        assertThat(decision).isInstanceOf(RedistributionDecision.Redistribute.class);
        var r = (RedistributionDecision.Redistribute) decision;
        assertThat(r.gracePeriod()).isEqualTo(Duration.ofSeconds(30));
        assertThat(r.excludeActors()).contains("agent-1");
    }

    @Test
    void above_immediate_threshold_returns_redistribute_zero_grace() {
        var decision = policy.evaluate(ctx(0.96, 3, Duration.ofSeconds(10)));
        assertThat(decision).isInstanceOf(RedistributionDecision.Redistribute.class);
        var r = (RedistributionDecision.Redistribute) decision;
        assertThat(r.gracePeriod()).isEqualTo(Duration.ZERO);
    }

    @Test
    void high_pressure_zero_obligations_returns_hold() {
        var decision = policy.evaluate(ctx(0.9, 0, Duration.ofSeconds(10)));
        assertThat(decision).isInstanceOf(RedistributionDecision.Hold.class);
        assertThat(((RedistributionDecision.Hold) decision).reason()).contains("no movable work");
    }

    @Test
    void inactive_beyond_escalation_threshold_returns_escalate() {
        var decision = policy.evaluate(ctx(0.5, 3, Duration.ofMinutes(6)));
        assertThat(decision).isInstanceOf(RedistributionDecision.Escalate.class);
    }

    @Test
    void inactive_escalation_takes_precedence_over_hold() {
        var decision = policy.evaluate(ctx(0.3, 0, Duration.ofMinutes(10)));
        assertThat(decision).isInstanceOf(RedistributionDecision.Escalate.class);
    }

    @Test
    void exactly_at_immediate_threshold_returns_zero_grace() {
        var decision = policy.evaluate(ctx(0.95, 2, Duration.ofSeconds(10)));
        assertThat(decision).isInstanceOf(RedistributionDecision.Redistribute.class);
        var r = (RedistributionDecision.Redistribute) decision;
        assertThat(r.gracePeriod()).isEqualTo(Duration.ZERO);
    }

    @Test
    void just_below_redistribute_threshold_returns_compress() {
        var decision = policy.evaluate(ctx(0.849, 5, Duration.ofSeconds(10)));
        assertThat(decision).isInstanceOf(RedistributionDecision.Compress.class);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform -Dtest="DefaultRedistributionPolicyTest" -DfailIfNoTests=false`
Expected: FAIL — `DefaultRedistributionPolicy` class not found.

- [ ] **Step 3: Write DefaultRedistributionPolicy**

Create `platform/src/main/java/io/casehub/platform/capacity/DefaultRedistributionPolicy.java`:

```java
package io.casehub.platform.capacity;

import io.casehub.platform.api.capacity.*;
import io.quarkus.arc.DefaultBean;
import jakarta.inject.Singleton;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.time.Duration;
import java.util.Set;

@DefaultBean
@Singleton
public class DefaultRedistributionPolicy implements RedistributionPolicy {

    private final double compressThreshold;
    private final double redistributeThreshold;
    private final double immediateThreshold;
    private final Duration gracePeriod;
    private final Duration inactivityEscalation;

    @jakarta.inject.Inject
    public DefaultRedistributionPolicy(
            @ConfigProperty(name = "casehub.capacity.redistribution.compress-threshold",
                            defaultValue = "0.7") double compressThreshold,
            @ConfigProperty(name = "casehub.capacity.redistribution.redistribute-threshold",
                            defaultValue = "0.85") double redistributeThreshold,
            @ConfigProperty(name = "casehub.capacity.redistribution.immediate-threshold",
                            defaultValue = "0.95") double immediateThreshold,
            @ConfigProperty(name = "casehub.capacity.redistribution.grace-period",
                            defaultValue = "PT30S") Duration gracePeriod,
            @ConfigProperty(name = "casehub.capacity.redistribution.inactivity-escalation",
                            defaultValue = "PT5M") Duration inactivityEscalation) {
        this.compressThreshold = compressThreshold;
        this.redistributeThreshold = redistributeThreshold;
        this.immediateThreshold = immediateThreshold;
        this.gracePeriod = gracePeriod;
        this.inactivityEscalation = inactivityEscalation;
    }

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

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform -Dtest="DefaultRedistributionPolicyTest" -DfailIfNoTests=false`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add platform/src/main/java/io/casehub/platform/capacity/DefaultRedistributionPolicy.java
git add platform/src/test/java/io/casehub/platform/capacity/DefaultRedistributionPolicyTest.java
git commit -m "feat(#268): DefaultRedistributionPolicy — configurable threshold-based decisions

Refs #268"
```

---

### Task 4: CapacityPressureMonitor + CapacityActorStateContributor

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/capacity/CapacityPressureMonitor.java`
- Create: `platform/src/main/java/io/casehub/platform/capacity/CapacityActorStateContributor.java`
- Test: `platform/src/test/java/io/casehub/platform/capacity/CapacityPressureMonitorTest.java`
- Test: `platform/src/test/java/io/casehub/platform/capacity/CapacityActorStateContributorTest.java`

**Interfaces:**
- Consumes: `ActorCapacityView`, `ActorCapacity`, `CapacityPressureEvent` (from Tasks 1-2), `ActorStateContributor`, `ActorStateAccumulator` (existing platform-api)
- Produces: `CapacityPressureMonitor` (fires CDI events), `CapacityActorStateContributor` (bridges to actor state dashboard)

- [ ] **Step 1: Write CapacityPressureMonitor tests**

Create `platform/src/test/java/io/casehub/platform/capacity/CapacityPressureMonitorTest.java`:

```java
package io.casehub.platform.capacity;

import io.casehub.platform.api.capacity.*;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.*;

class CapacityPressureMonitorTest {

    @Test
    void sweep_fires_event_for_each_overloaded_actor() {
        var view = stubView(List.of(
                new ActorCapacity("agent-1", 0.9, Map.of("ctx", 0.9), Instant.now()),
                new ActorCapacity("agent-2", 0.8, Map.of("task", 0.8), Instant.now())));
        var events = new ArrayList<CapacityPressureEvent>();
        var monitor = new CapacityPressureMonitor(view, events::add, 0.7);

        monitor.sweep();

        assertThat(events).hasSize(2);
        assertThat(events).extracting(CapacityPressureEvent::actorId)
                .containsExactlyInAnyOrder("agent-1", "agent-2");
    }

    @Test
    void sweep_no_overloaded_actors_fires_no_events() {
        var view = stubView(List.of());
        var events = new ArrayList<CapacityPressureEvent>();
        var monitor = new CapacityPressureMonitor(view, events::add, 0.7);

        monitor.sweep();

        assertThat(events).isEmpty();
    }

    @Test
    void sweep_identifies_highest_pressure_trigger() {
        var view = stubView(List.of(
                new ActorCapacity("agent-1", 0.9,
                        Map.of("ctx", 0.9, "task", 0.3), Instant.now())));
        var events = new ArrayList<CapacityPressureEvent>();
        var monitor = new CapacityPressureMonitor(view, events::add, 0.7);

        monitor.sweep();

        assertThat(events.get(0).triggerSignalType()).isEqualTo("ctx");
    }

    @Test
    void sweep_lexicographic_tiebreak_for_equal_pressure() {
        var view = stubView(List.of(
                new ActorCapacity("agent-1", 0.9,
                        Map.of("beta_signal", 0.9, "alpha_signal", 0.9), Instant.now())));
        var events = new ArrayList<CapacityPressureEvent>();
        var monitor = new CapacityPressureMonitor(view, events::add, 0.7);

        monitor.sweep();

        assertThat(events.get(0).triggerSignalType()).isEqualTo("alpha_signal");
    }

    @Test
    void sweep_carries_threshold_in_event() {
        var view = stubView(List.of(
                new ActorCapacity("agent-1", 0.9, Map.of("ctx", 0.9), Instant.now())));
        var events = new ArrayList<CapacityPressureEvent>();
        var monitor = new CapacityPressureMonitor(view, events::add, 0.7);

        monitor.sweep();

        assertThat(events.get(0).threshold()).isEqualTo(0.7);
    }

    private static ActorCapacityView stubView(List<ActorCapacity> overloaded) {
        return new ActorCapacityView() {
            @Override public ActorCapacity getCapacity(String actorId) {
                return overloaded.stream()
                        .filter(c -> c.actorId().equals(actorId))
                        .findFirst()
                        .orElse(new ActorCapacity(actorId, 0.0, Map.of(), Instant.now()));
            }
            @Override public List<ActorCapacity> getOverloaded(double threshold) {
                return overloaded;
            }
        };
    }
}
```

- [ ] **Step 2: Write CapacityActorStateContributor tests**

Create `platform/src/test/java/io/casehub/platform/capacity/CapacityActorStateContributorTest.java`:

```java
package io.casehub.platform.capacity;

import io.casehub.platform.api.actor.ActorStateAccumulator;
import io.casehub.platform.api.capacity.*;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.*;

class CapacityActorStateContributorTest {

    @Test
    void contributes_aggregate_pressure_and_signals() {
        var view = fixedView("agent-1", 0.85, Map.of("ctx", 0.85, "task", 0.3));
        var contributor = new CapacityActorStateContributor(view);
        var captured = new CapturingAccumulator();

        contributor.contribute("agent-1", captured);

        assertThat(captured.aggregatePressure.get()).isEqualTo(0.85);
        assertThat(captured.pressureBySignalType.get())
                .containsEntry("ctx", 0.85)
                .containsEntry("task", 0.3);
    }

    @Test
    void contributes_zero_when_no_sources() {
        var view = fixedView("agent-1", 0.0, Map.of());
        var contributor = new CapacityActorStateContributor(view);
        var captured = new CapturingAccumulator();

        contributor.contribute("agent-1", captured);

        assertThat(captured.aggregatePressure.get()).isEqualTo(0.0);
        assertThat(captured.pressureBySignalType.get()).isEmpty();
    }

    @Test
    void sourceName_is_capacity() {
        var contributor = new CapacityActorStateContributor(
                fixedView("a", 0.0, Map.of()));
        assertThat(contributor.sourceName()).isEqualTo("capacity");
    }

    private static ActorCapacityView fixedView(String actorId, double pressure,
                                                Map<String, Double> byType) {
        var cap = new ActorCapacity(actorId, pressure, byType, Instant.now());
        return new ActorCapacityView() {
            @Override public ActorCapacity getCapacity(String id) { return cap; }
            @Override public List<ActorCapacity> getOverloaded(double t) { return List.of(); }
        };
    }

    private static class CapturingAccumulator implements ActorStateAccumulator {
        final AtomicReference<Double> aggregatePressure = new AtomicReference<>();
        final AtomicReference<Map<String, Double>> pressureBySignalType = new AtomicReference<>();

        @Override public void trustScore(Double score) {}
        @Override public void capabilityScore(String capability, double score) {}
        @Override public void workItem(java.util.UUID id, String title, String status,
                                       String category, java.util.UUID caseId) {}
        @Override public void commitment(java.util.UUID commitmentId, java.util.UUID channelId,
                                         java.util.UUID caseId, String state, Instant expiresAt) {}
        @Override public void engineActiveCaseId(java.util.UUID caseId) {}

        @Override
        public void capacity(double aggregatePressure, Map<String, Double> pressureBySignalType) {
            this.aggregatePressure.set(aggregatePressure);
            this.pressureBySignalType.set(pressureBySignalType);
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform -Dtest="CapacityPressureMonitorTest,CapacityActorStateContributorTest" -DfailIfNoTests=false`
Expected: FAIL — classes not found.

- [ ] **Step 4: Write CapacityPressureMonitor**

Create `platform/src/main/java/io/casehub/platform/capacity/CapacityPressureMonitor.java`:

```java
package io.casehub.platform.capacity;

import io.casehub.platform.api.capacity.*;
import io.quarkus.scheduler.Scheduled;
import jakarta.enterprise.event.Event;
import jakarta.inject.Inject;
import jakarta.inject.Singleton;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

@Singleton
public class CapacityPressureMonitor {

    private static final Logger LOG = Logger.getLogger(CapacityPressureMonitor.class);

    private final ActorCapacityView capacityView;
    private final Consumer<CapacityPressureEvent> eventSink;
    private final double sweepThreshold;

    @Inject
    public CapacityPressureMonitor(
            ActorCapacityView capacityView,
            Event<CapacityPressureEvent> pressureEvent,
            @ConfigProperty(name = "casehub.capacity.redistribution.compress-threshold",
                            defaultValue = "0.7") double sweepThreshold) {
        this(capacityView, pressureEvent::fireAsync, sweepThreshold);
    }

    CapacityPressureMonitor(ActorCapacityView capacityView,
                            Consumer<CapacityPressureEvent> eventSink,
                            double sweepThreshold) {
        this.capacityView = capacityView;
        this.eventSink = eventSink;
        this.sweepThreshold = sweepThreshold;
    }

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

            eventSink.accept(new CapacityPressureEvent(
                    capacity.actorId(), capacity, sweepThreshold, trigger));
        }
    }
}
```

- [ ] **Step 5: Write CapacityActorStateContributor**

Create `platform/src/main/java/io/casehub/platform/capacity/CapacityActorStateContributor.java`:

```java
package io.casehub.platform.capacity;

import io.casehub.platform.api.actor.ActorStateAccumulator;
import io.casehub.platform.api.actor.ActorStateContributor;
import io.casehub.platform.api.capacity.ActorCapacity;
import io.casehub.platform.api.capacity.ActorCapacityView;
import jakarta.inject.Inject;
import jakarta.inject.Singleton;

@Singleton
public class CapacityActorStateContributor implements ActorStateContributor {

    private final ActorCapacityView capacityView;

    @Inject
    public CapacityActorStateContributor(ActorCapacityView capacityView) {
        this.capacityView = capacityView;
    }

    CapacityActorStateContributor(ActorCapacityView capacityView, Void unused) {
        this.capacityView = capacityView;
    }

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

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform -Dtest="CapacityPressureMonitorTest,CapacityActorStateContributorTest" -DfailIfNoTests=false`
Expected: All tests PASS.

- [ ] **Step 7: Run full platform build**

Run: `mvn --batch-mode install -pl platform-api,platform`
Expected: BUILD SUCCESS — all tests pass, all modules compile.

- [ ] **Step 8: Commit**

```bash
git add platform/src/main/java/io/casehub/platform/capacity/CapacityPressureMonitor.java
git add platform/src/main/java/io/casehub/platform/capacity/CapacityActorStateContributor.java
git add platform/src/test/java/io/casehub/platform/capacity/CapacityPressureMonitorTest.java
git add platform/src/test/java/io/casehub/platform/capacity/CapacityActorStateContributorTest.java
git commit -m "feat(#268): CapacityPressureMonitor sweep + ActorState bridge contributor

Refs #268"
```

---

## References

- [2026-09-02-capacity-signal-spi-design.md] — design spec this plan implements
- [wsp-casehub-qhorus/specs/cross-platform-capacity-redistribution/2026-09-02-capacity-redistribution-design.md] — cross-platform parent spec
- [platform-api/src/main/java/io/casehub/platform/api/actor/ActorStateContributor.java] — existing SPI (D1 validated as separate)
- [platform-api/src/main/java/io/casehub/platform/api/actor/ActorStateAccumulator.java] — extended with default capacity() method
- [engine/actor-state/src/main/java/io/casehub/actorstate/ActorStateAggregator.java] — existing aggregator pattern reference
- [GE-20260602-c4a68a] — dual-constructor aggregator pattern for CDI-free testing
- [GE-20260602-047ac4] — visitor/accumulator pattern for thread-safe aggregation
- [GitHub #268] — feat: capacity signal SPI + redistribution policy framework
- [decisions.md] — 6 captured design decisions (D1-D6)
