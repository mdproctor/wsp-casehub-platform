# Capacity Signal SPI + Redistribution Policy Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #268 — feat: capacity signal SPI + redistribution policy framework
**Issue group:** #268

**Goal:** Platform-level shared vocabulary for actor capacity signals and redistribution policies — SPIs in platform-api, default implementations in platform/.

**Architecture:** Three layers: signal model (CapacitySignal record, CapacitySignalSource SPI, ActorCapacityView SPI) in platform-api, policy model (RedistributionPolicy SPI, RedistributionAction enum, context/decision records, CapacityPressureEvent CDI event) in platform-api, runtime implementations (AggregatingActorCapacityView, DefaultRedistributionPolicy, CapacityPressureMonitor) in platform/.

**Tech Stack:** Pure Java (platform-api), Quarkus CDI + MicroProfile Config + @Scheduled (platform/)

## Global Constraints

- platform-api must remain zero-dependency — no Quarkus, no JPA, no casehubio imports
- All new types in `io.casehub.platform.api.capacity` (platform-api) and `io.casehub.platform.capacity` (platform/)
- Pressure is normalised 0.0–1.0; values outside this range throw IllegalArgumentException
- CDI discovery via `@Inject @Any Instance<CapacitySignalSource>` — consistent with ActorStateContributor pattern

---

## Batch 1: Signal Model + Policy Model (platform-api)

### Task 1: CapacitySignal record + CapacitySignalSource SPI + ActorCapacityView SPI

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/CapacitySignal.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/CapacitySignalSource.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/ActorCapacityView.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/capacity/CapacitySignalTest.java`

**Interfaces:**
- Produces: `CapacitySignal(String actorId, String source, double pressure, Instant timestamp)` — validated record
- Produces: `CapacitySignalSource { String sourceName(); List<CapacitySignal> signals(); }`
- Produces: `ActorCapacityView { CapacitySignal aggregatedPressure(String actorId); List<CapacitySignal> signalsByActor(String actorId); List<CapacitySignal> allAggregatedPressures(); }`

- [ ] **Step 1: Write failing tests for CapacitySignal validation**

```java
package io.casehub.platform.api.capacity;

import org.junit.jupiter.api.Test;
import java.time.Instant;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class CapacitySignalTest {

    @Test
    void valid_signal() {
        var signal = new CapacitySignal("actor-1", "work-queue", 0.75, Instant.now());
        assertThat(signal.actorId()).isEqualTo("actor-1");
        assertThat(signal.source()).isEqualTo("work-queue");
        assertThat(signal.pressure()).isEqualTo(0.75);
    }

    @Test
    void pressure_below_zero_throws() {
        assertThatThrownBy(() -> new CapacitySignal("a", "s", -0.1, Instant.now()))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("0.0");
    }

    @Test
    void pressure_above_one_throws() {
        assertThatThrownBy(() -> new CapacitySignal("a", "s", 1.1, Instant.now()))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("1.0");
    }

    @Test
    void pressure_boundary_zero_accepted() {
        var signal = new CapacitySignal("a", "s", 0.0, Instant.now());
        assertThat(signal.pressure()).isEqualTo(0.0);
    }

    @Test
    void pressure_boundary_one_accepted() {
        var signal = new CapacitySignal("a", "s", 1.0, Instant.now());
        assertThat(signal.pressure()).isEqualTo(1.0);
    }

    @Test
    void null_actorId_throws() {
        assertThatThrownBy(() -> new CapacitySignal(null, "s", 0.5, Instant.now()))
                .isInstanceOf(NullPointerException.class);
    }

    @Test
    void null_source_throws() {
        assertThatThrownBy(() -> new CapacitySignal("a", null, 0.5, Instant.now()))
                .isInstanceOf(NullPointerException.class);
    }

    @Test
    void null_timestamp_defaults_to_now() {
        var before = Instant.now();
        var signal = new CapacitySignal("a", "s", 0.5, null);
        assertThat(signal.timestamp()).isAfterOrEqualTo(before);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform-api -Dtest=CapacitySignalTest`
Expected: Compilation error — class doesn't exist

- [ ] **Step 3: Create CapacitySignal record**

Use `ide_create_file` to create `platform-api/src/main/java/io/casehub/platform/api/capacity/CapacitySignal.java`:

```java
package io.casehub.platform.api.capacity;

import java.time.Instant;
import java.util.Objects;

public record CapacitySignal(String actorId,
                              String source,
                              double pressure,
                              Instant timestamp) {

    public CapacitySignal {
        Objects.requireNonNull(actorId, "actorId is required");
        Objects.requireNonNull(source, "source is required");
        if (pressure < 0.0 || pressure > 1.0) {
            throw new IllegalArgumentException(
                    "Pressure must be between 0.0 and 1.0, got: " + pressure);
        }
        if (timestamp == null) { timestamp = Instant.now(); }
    }
}
```

- [ ] **Step 4: Create CapacitySignalSource interface**

Use `ide_create_file` to create `platform-api/src/main/java/io/casehub/platform/api/capacity/CapacitySignalSource.java`:

```java
package io.casehub.platform.api.capacity;

import java.util.List;

public interface CapacitySignalSource {

    String sourceName();

    List<CapacitySignal> signals();
}
```

- [ ] **Step 5: Create ActorCapacityView interface**

Use `ide_create_file` to create `platform-api/src/main/java/io/casehub/platform/api/capacity/ActorCapacityView.java`:

```java
package io.casehub.platform.api.capacity;

import java.util.List;

public interface ActorCapacityView {

    CapacitySignal aggregatedPressure(String actorId);

    List<CapacitySignal> signalsByActor(String actorId);

    List<CapacitySignal> allAggregatedPressures();
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform-api -Dtest=CapacitySignalTest`
Expected: All 8 tests PASS

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/capacity/ platform-api/src/test/java/io/casehub/platform/api/capacity/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#268): add CapacitySignal record, CapacitySignalSource and ActorCapacityView SPIs

Refs #268"
```

### Task 2: Policy model — RedistributionPolicy SPI + supporting types + CapacityPressureEvent

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/RedistributionAction.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/RedistributionContext.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/RedistributionDecision.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/RedistributionPolicy.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/capacity/CapacityPressureEvent.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/capacity/RedistributionDecisionTest.java`

**Interfaces:**
- Consumes: `CapacitySignal` (from Task 1)
- Produces: `RedistributionAction { NONE, COMPRESS, REDISTRIBUTE, ESCALATE }`
- Produces: `RedistributionContext(String actorId, CapacitySignal aggregatedSignal, List<CapacitySignal> sourceSignals)`
- Produces: `RedistributionDecision(RedistributionAction action, String reason)` with static factories
- Produces: `RedistributionPolicy { RedistributionDecision evaluate(RedistributionContext context); }`
- Produces: `CapacityPressureEvent(String actorId, RedistributionDecision decision, CapacitySignal aggregatedSignal, Instant firedAt)`

- [ ] **Step 1: Write failing tests**

```java
package io.casehub.platform.api.capacity;

import org.junit.jupiter.api.Test;
import java.time.Instant;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;

class RedistributionDecisionTest {

    @Test
    void none_factory() {
        var decision = RedistributionDecision.none();
        assertThat(decision.action()).isEqualTo(RedistributionAction.NONE);
        assertThat(decision.reason()).isNull();
    }

    @Test
    void compress_factory() {
        var decision = RedistributionDecision.compress("high load");
        assertThat(decision.action()).isEqualTo(RedistributionAction.COMPRESS);
        assertThat(decision.reason()).isEqualTo("high load");
    }

    @Test
    void redistribute_factory() {
        var decision = RedistributionDecision.redistribute("overloaded");
        assertThat(decision.action()).isEqualTo(RedistributionAction.REDISTRIBUTE);
    }

    @Test
    void escalate_factory() {
        var decision = RedistributionDecision.escalate("critical");
        assertThat(decision.action()).isEqualTo(RedistributionAction.ESCALATE);
    }

    @Test
    void context_null_source_signals_defaults_empty() {
        var signal = new CapacitySignal("a", "aggregated", 0.5, Instant.now());
        var ctx = new RedistributionContext("a", signal, null);
        assertThat(ctx.sourceSignals()).isEmpty();
    }

    @Test
    void pressure_event_null_firedAt_defaults() {
        var signal = new CapacitySignal("a", "aggregated", 0.9, Instant.now());
        var decision = RedistributionDecision.escalate("critical");
        var before = Instant.now();
        var event = new CapacityPressureEvent("a", decision, signal, null);
        assertThat(event.firedAt()).isAfterOrEqualTo(before);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform-api -Dtest=RedistributionDecisionTest`
Expected: Compilation error

- [ ] **Step 3: Create RedistributionAction enum**

Use `ide_create_file` to create `platform-api/src/main/java/io/casehub/platform/api/capacity/RedistributionAction.java`:

```java
package io.casehub.platform.api.capacity;

public enum RedistributionAction {
    NONE,
    COMPRESS,
    REDISTRIBUTE,
    ESCALATE
}
```

- [ ] **Step 4: Create RedistributionContext record**

Use `ide_create_file` to create `platform-api/src/main/java/io/casehub/platform/api/capacity/RedistributionContext.java`:

```java
package io.casehub.platform.api.capacity;

import java.util.List;
import java.util.Objects;

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

- [ ] **Step 5: Create RedistributionDecision record**

Use `ide_create_file` to create `platform-api/src/main/java/io/casehub/platform/api/capacity/RedistributionDecision.java`:

```java
package io.casehub.platform.api.capacity;

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

- [ ] **Step 6: Create RedistributionPolicy interface**

Use `ide_create_file` to create `platform-api/src/main/java/io/casehub/platform/api/capacity/RedistributionPolicy.java`:

```java
package io.casehub.platform.api.capacity;

public interface RedistributionPolicy {

    RedistributionDecision evaluate(RedistributionContext context);
}
```

- [ ] **Step 7: Create CapacityPressureEvent record**

Use `ide_create_file` to create `platform-api/src/main/java/io/casehub/platform/api/capacity/CapacityPressureEvent.java`:

```java
package io.casehub.platform.api.capacity;

import java.time.Instant;
import java.util.Objects;

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

- [ ] **Step 8: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform-api -Dtest=RedistributionDecisionTest`
Expected: All 6 tests PASS

- [ ] **Step 9: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/capacity/ platform-api/src/test/java/io/casehub/platform/api/capacity/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#268): add RedistributionPolicy SPI, decision types, and CapacityPressureEvent

Refs #268"
```

## Batch 2: Runtime Implementations (platform/)

### Task 3: AggregatingActorCapacityView + DefaultRedistributionPolicy + CapacityPressureMonitor

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/capacity/AggregatingActorCapacityView.java`
- Create: `platform/src/main/java/io/casehub/platform/capacity/DefaultRedistributionPolicy.java`
- Create: `platform/src/main/java/io/casehub/platform/capacity/CapacityPressureMonitor.java`
- Test: `platform/src/test/java/io/casehub/platform/capacity/AggregatingActorCapacityViewTest.java`
- Test: `platform/src/test/java/io/casehub/platform/capacity/DefaultRedistributionPolicyTest.java`
- Test: `platform/src/test/java/io/casehub/platform/capacity/CapacityPressureMonitorTest.java`

**Interfaces:**
- Consumes: `CapacitySignal`, `CapacitySignalSource`, `ActorCapacityView` (from Task 1)
- Consumes: `RedistributionPolicy`, `RedistributionContext`, `RedistributionDecision`, `RedistributionAction`, `CapacityPressureEvent` (from Task 2)
- Produces: `AggregatingActorCapacityView @ApplicationScoped implements ActorCapacityView` — CDI-discovers CapacitySignalSource beans, max-pressure aggregation
- Produces: `DefaultRedistributionPolicy @ApplicationScoped implements RedistributionPolicy` — configurable thresholds via `casehub.capacity.threshold.*`
- Produces: `CapacityPressureMonitor @ApplicationScoped` — @Scheduled sweep, fires CapacityPressureEvent

- [ ] **Step 1: Write failing tests for AggregatingActorCapacityView**

```java
package io.casehub.platform.capacity;

import io.casehub.platform.api.capacity.ActorCapacityView;
import io.casehub.platform.api.capacity.CapacitySignal;
import io.casehub.platform.api.capacity.CapacitySignalSource;
import org.junit.jupiter.api.Test;
import java.time.Instant;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;

class AggregatingActorCapacityViewTest {

    @Test
    void no_sources_returns_zero_pressure() {
        var view = new AggregatingActorCapacityView(List.of());
        view.refresh();
        var result = view.aggregatedPressure("actor-1");
        assertThat(result.pressure()).isEqualTo(0.0);
        assertThat(result.source()).isEqualTo("aggregated");
    }

    @Test
    void single_source_returns_its_pressure() {
        CapacitySignalSource source = new CapacitySignalSource() {
            @Override public String sourceName() { return "work-queue"; }
            @Override public List<CapacitySignal> signals() {
                return List.of(new CapacitySignal("actor-1", "work-queue", 0.6, Instant.now()));
            }
        };
        var view = new AggregatingActorCapacityView(List.of(source));
        view.refresh();
        assertThat(view.aggregatedPressure("actor-1").pressure()).isEqualTo(0.6);
    }

    @Test
    void max_pressure_across_sources() {
        CapacitySignalSource s1 = new CapacitySignalSource() {
            @Override public String sourceName() { return "s1"; }
            @Override public List<CapacitySignal> signals() {
                return List.of(new CapacitySignal("actor-1", "s1", 0.4, Instant.now()));
            }
        };
        CapacitySignalSource s2 = new CapacitySignalSource() {
            @Override public String sourceName() { return "s2"; }
            @Override public List<CapacitySignal> signals() {
                return List.of(new CapacitySignal("actor-1", "s2", 0.8, Instant.now()));
            }
        };
        var view = new AggregatingActorCapacityView(List.of(s1, s2));
        view.refresh();
        assertThat(view.aggregatedPressure("actor-1").pressure()).isEqualTo(0.8);
    }

    @Test
    void multiple_actors_grouped() {
        CapacitySignalSource source = new CapacitySignalSource() {
            @Override public String sourceName() { return "s"; }
            @Override public List<CapacitySignal> signals() {
                return List.of(
                        new CapacitySignal("a", "s", 0.3, Instant.now()),
                        new CapacitySignal("b", "s", 0.7, Instant.now()));
            }
        };
        var view = new AggregatingActorCapacityView(List.of(source));
        view.refresh();
        assertThat(view.aggregatedPressure("a").pressure()).isEqualTo(0.3);
        assertThat(view.aggregatedPressure("b").pressure()).isEqualTo(0.7);
    }

    @Test
    void signals_by_actor_returns_individual_sources() {
        CapacitySignalSource s1 = new CapacitySignalSource() {
            @Override public String sourceName() { return "s1"; }
            @Override public List<CapacitySignal> signals() {
                return List.of(new CapacitySignal("a", "s1", 0.3, Instant.now()));
            }
        };
        CapacitySignalSource s2 = new CapacitySignalSource() {
            @Override public String sourceName() { return "s2"; }
            @Override public List<CapacitySignal> signals() {
                return List.of(new CapacitySignal("a", "s2", 0.6, Instant.now()));
            }
        };
        var view = new AggregatingActorCapacityView(List.of(s1, s2));
        view.refresh();
        assertThat(view.signalsByActor("a")).hasSize(2);
    }

    @Test
    void refresh_replaces_cache() {
        var mutablePressure = new double[]{0.5};
        CapacitySignalSource source = new CapacitySignalSource() {
            @Override public String sourceName() { return "s"; }
            @Override public List<CapacitySignal> signals() {
                return List.of(new CapacitySignal("a", "s", mutablePressure[0], Instant.now()));
            }
        };
        var view = new AggregatingActorCapacityView(List.of(source));
        view.refresh();
        assertThat(view.aggregatedPressure("a").pressure()).isEqualTo(0.5);

        mutablePressure[0] = 0.9;
        view.refresh();
        assertThat(view.aggregatedPressure("a").pressure()).isEqualTo(0.9);
    }

    @Test
    void all_aggregated_pressures() {
        CapacitySignalSource source = new CapacitySignalSource() {
            @Override public String sourceName() { return "s"; }
            @Override public List<CapacitySignal> signals() {
                return List.of(
                        new CapacitySignal("a", "s", 0.3, Instant.now()),
                        new CapacitySignal("b", "s", 0.7, Instant.now()));
            }
        };
        var view = new AggregatingActorCapacityView(List.of(source));
        view.refresh();
        assertThat(view.allAggregatedPressures()).hasSize(2);
    }
}
```

- [ ] **Step 2: Write failing tests for DefaultRedistributionPolicy**

```java
package io.casehub.platform.capacity;

import io.casehub.platform.api.capacity.CapacitySignal;
import io.casehub.platform.api.capacity.RedistributionAction;
import io.casehub.platform.api.capacity.RedistributionContext;
import org.junit.jupiter.api.Test;
import java.time.Instant;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;

class DefaultRedistributionPolicyTest {

    private DefaultRedistributionPolicy policy(double compress, double redistribute, double escalate) {
        return new DefaultRedistributionPolicy(compress, redistribute, escalate);
    }

    private RedistributionContext ctx(double pressure) {
        var signal = new CapacitySignal("a", "aggregated", pressure, Instant.now());
        return new RedistributionContext("a", signal, List.of());
    }

    @Test
    void below_all_thresholds_returns_none() {
        assertThat(policy(0.7, 0.85, 0.95).evaluate(ctx(0.5)).action())
                .isEqualTo(RedistributionAction.NONE);
    }

    @Test
    void at_compress_threshold() {
        assertThat(policy(0.7, 0.85, 0.95).evaluate(ctx(0.75)).action())
                .isEqualTo(RedistributionAction.COMPRESS);
    }

    @Test
    void at_redistribute_threshold() {
        assertThat(policy(0.7, 0.85, 0.95).evaluate(ctx(0.9)).action())
                .isEqualTo(RedistributionAction.REDISTRIBUTE);
    }

    @Test
    void at_escalate_threshold() {
        assertThat(policy(0.7, 0.85, 0.95).evaluate(ctx(0.97)).action())
                .isEqualTo(RedistributionAction.ESCALATE);
    }

    @Test
    void custom_thresholds() {
        assertThat(policy(0.5, 0.6, 0.7).evaluate(ctx(0.55)).action())
                .isEqualTo(RedistributionAction.COMPRESS);
        assertThat(policy(0.5, 0.6, 0.7).evaluate(ctx(0.65)).action())
                .isEqualTo(RedistributionAction.REDISTRIBUTE);
        assertThat(policy(0.5, 0.6, 0.7).evaluate(ctx(0.75)).action())
                .isEqualTo(RedistributionAction.ESCALATE);
    }

    @Test
    void decision_includes_reason() {
        var decision = policy(0.7, 0.85, 0.95).evaluate(ctx(0.9));
        assertThat(decision.reason())
                .contains("0.9")
                .contains("redistribute");
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode install -pl platform-api -DskipTests && mvn --batch-mode test -pl platform -Dtest="AggregatingActorCapacityViewTest,DefaultRedistributionPolicyTest"`
Expected: Compilation error — classes don't exist

- [ ] **Step 4: Create AggregatingActorCapacityView**

Use `ide_create_file` to create `platform/src/main/java/io/casehub/platform/capacity/AggregatingActorCapacityView.java`:

```java
package io.casehub.platform.capacity;

import io.casehub.platform.api.capacity.ActorCapacityView;
import io.casehub.platform.api.capacity.CapacitySignal;
import io.casehub.platform.api.capacity.CapacitySignalSource;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Any;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;

@ApplicationScoped
public class AggregatingActorCapacityView implements ActorCapacityView {

    private final Iterable<CapacitySignalSource> signalSources;
    private final Map<String, List<CapacitySignal>> signalCache = new ConcurrentHashMap<>();

    @Inject
    public AggregatingActorCapacityView(@Any Instance<CapacitySignalSource> signalSources) {
        this.signalSources = signalSources;
    }

    AggregatingActorCapacityView(List<CapacitySignalSource> signalSources) {
        this.signalSources = signalSources;
    }

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

- [ ] **Step 5: Create DefaultRedistributionPolicy**

Use `ide_create_file` to create `platform/src/main/java/io/casehub/platform/capacity/DefaultRedistributionPolicy.java`:

```java
package io.casehub.platform.capacity;

import io.casehub.platform.api.capacity.RedistributionContext;
import io.casehub.platform.api.capacity.RedistributionDecision;
import io.casehub.platform.api.capacity.RedistributionPolicy;
import jakarta.enterprise.context.ApplicationScoped;
import org.eclipse.microprofile.config.inject.ConfigProperty;

@ApplicationScoped
public class DefaultRedistributionPolicy implements RedistributionPolicy {

    private final double compressThreshold;
    private final double redistributeThreshold;
    private final double escalateThreshold;

    public DefaultRedistributionPolicy(
            @ConfigProperty(name = "casehub.capacity.threshold.compress",
                            defaultValue = "0.7") double compressThreshold,
            @ConfigProperty(name = "casehub.capacity.threshold.redistribute",
                            defaultValue = "0.85") double redistributeThreshold,
            @ConfigProperty(name = "casehub.capacity.threshold.escalate",
                            defaultValue = "0.95") double escalateThreshold) {
        this.compressThreshold = compressThreshold;
        this.redistributeThreshold = redistributeThreshold;
        this.escalateThreshold = escalateThreshold;
    }

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

- [ ] **Step 6: Create CapacityPressureMonitor**

Use `ide_create_file` to create `platform/src/main/java/io/casehub/platform/capacity/CapacityPressureMonitor.java`:

```java
package io.casehub.platform.capacity;

import io.casehub.platform.api.capacity.CapacityPressureEvent;
import io.casehub.platform.api.capacity.CapacitySignal;
import io.casehub.platform.api.capacity.RedistributionAction;
import io.casehub.platform.api.capacity.RedistributionContext;
import io.casehub.platform.api.capacity.RedistributionDecision;
import io.casehub.platform.api.capacity.RedistributionPolicy;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Event;
import jakarta.inject.Inject;
import io.quarkus.scheduler.Scheduled;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import java.time.Instant;

@ApplicationScoped
public class CapacityPressureMonitor {

    @Inject
    AggregatingActorCapacityView capacityView;

    @Inject
    RedistributionPolicy policy;

    @Inject
    Event<CapacityPressureEvent> pressureEvent;

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

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform -Dtest="AggregatingActorCapacityViewTest,DefaultRedistributionPolicyTest"`
Expected: All tests PASS

- [ ] **Step 8: Run full build for yaml-core, platform-api, and platform**

Run: `mvn --batch-mode test -pl platform-api,platform`
Expected: BUILD SUCCESS

- [ ] **Step 9: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform/src/main/java/io/casehub/platform/capacity/ platform/src/test/java/io/casehub/platform/capacity/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#268): add AggregatingActorCapacityView, DefaultRedistributionPolicy, CapacityPressureMonitor

CDI-discovered signal sources, max-pressure aggregation,
configurable compress/redistribute/escalate thresholds,
@Scheduled sweep with CapacityPressureEvent CDI event.

Refs #268"
```

## References

- `specs/issue-268-capacity-signal-spi/2026-09-04-capacity-signal-spi-design.md` — design spec
- `platform-api/src/main/java/io/casehub/platform/api/actor/ActorStateContributor.java` — parallel SPI pattern
- `platform-api/src/main/java/io/casehub/platform/api/actor/ActorStateAccumulator.java` — existing accumulator
- `platform-api/src/main/java/io/casehub/platform/api/governance/ExecutionPolicy.java` — policy record pattern
- `platform/src/main/java/io/casehub/platform/mock/NoOpPreferenceStore.java` — @DefaultBean pattern
- `specs/issue-268-capacity-signal-spi/decisions.md` — D1-D6 design decisions
- GitHub #268 — focal issue
- casehubio/qhorus#405 — first consumer
