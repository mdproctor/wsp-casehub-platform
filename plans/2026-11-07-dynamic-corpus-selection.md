# Dynamic Corpus Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #729 — feat: dynamic corpus selection — phased simulation responses driven by strategy-based triggers
**Issue group:** #729

**Goal:** Enable simulation corpus responses to change over time based on pluggable selection strategies (state machine, duration, lookup count, random), so that simulated systems can model real-world progressions like order status changes, service degradation, and chaos testing.

**Architecture:** A `CorpusSelector` interface (simulation-api) determines which phase of corpus data is active. `PhasedCorpus` decorates `SimulationCorpus`, delegating lookups to the active phase's entries. Four selector implementations (simulation-core) handle different trigger types. `SimulationRuntime.createStrategy()` wraps the corpus in `PhasedCorpus` when `corpus-selection` is configured. YAML parsing in `YamlSimulationConfig` (simulation-config-core) handles the new `corpus-selection` block.

**Tech Stack:** Java 21, JUnit 5, AssertJ, Jackson YAML

## Global Constraints

- `simulation-api` must remain zero-dependency — no Quarkus, no yaml-core imports
- `CorpusSelector`, `PhasedCorpus`, and `CorpusSelectorConfig` go in simulation-api
- Selector implementations go in simulation-core (may depend on yaml-core for `SpeedMultiplier`)
- All concurrency uses `java.util.concurrent` — never `synchronized` (virtual thread pinning)
- `corpus` and `corpus-selection` are mutually exclusive on a method in YAML
- `corpus-files` and `corpus-selection` are mutually exclusive on a method in YAML
- Follow existing test patterns: JUnit 5 + AssertJ, `stubConfig()` helpers

---

## Batch 1: Core SPI + PhasedCorpus (simulation-api)

### Task 1: CorpusSelector interface + CorpusSelectorConfig sealed hierarchy

**Files:**
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/CorpusSelector.java`
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/CorpusSelectorConfig.java`
- Test: `simulation-api/src/test/java/io/casehub/platform/simulation/CorpusSelectorConfigTest.java`

**Interfaces:**
- Consumes: nothing (leaf types)
- Produces: `CorpusSelector` (interface: `String activePhase()`, `default void onResolved() {}`), `CorpusSelectorConfig` (sealed interface with `StateMachine`, `Duration`, `LookupCount`, `Weighted` records and `DurationPhase`, `CountPhase`, `WeightedPhase` sub-records, plus `Map<String, List<InvocationRecord<Object, Object>>> phases()` common method)

- [ ] **Step 1: Write test for CorpusSelectorConfig records**

```java
package io.casehub.platform.simulation;

import org.junit.jupiter.api.Test;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class CorpusSelectorConfigTest {

    @Test
    void stateMachineConfigCarriesAllFields() {
        var phases = Map.<String, List<InvocationRecord<Object, Object>>>of(
                "pending", List.of(InvocationRecord.of("t1", "k1", "in", "out-pending")),
                "completed", List.of(InvocationRecord.of("t1", "k1", "in", "out-completed")));
        var transitions = Map.of("pending", Map.of("pay", "completed"));

        var config = new CorpusSelectorConfig.StateMachine("pending", transitions, phases);

        assertThat(config.initial()).isEqualTo("pending");
        assertThat(config.transitions()).containsKey("pending");
        assertThat(config.phases()).hasSize(2);
    }

    @Test
    void durationConfigCarriesOrderedPhases() {
        var orderedPhases = List.of(
                new CorpusSelectorConfig.DurationPhase("normal", Duration.ofSeconds(10)),
                new CorpusSelectorConfig.DurationPhase("degraded", null));
        var phases = Map.<String, List<InvocationRecord<Object, Object>>>of(
                "normal", List.of(), "degraded", List.of());

        var config = new CorpusSelectorConfig.Duration(orderedPhases, phases);

        assertThat(config.orderedPhases()).hasSize(2);
        assertThat(config.orderedPhases().get(0).duration()).isEqualTo(Duration.ofSeconds(10));
        assertThat(config.orderedPhases().get(1).duration()).isNull();
    }

    @Test
    void lookupCountConfigCarriesOrderedPhases() {
        var orderedPhases = List.of(
                new CorpusSelectorConfig.CountPhase("pending", 3),
                new CorpusSelectorConfig.CountPhase("completed", 0));
        var phases = Map.<String, List<InvocationRecord<Object, Object>>>of(
                "pending", List.of(), "completed", List.of());

        var config = new CorpusSelectorConfig.LookupCount(orderedPhases, phases);

        assertThat(config.orderedPhases()).hasSize(2);
        assertThat(config.orderedPhases().get(0).count()).isEqualTo(3);
    }

    @Test
    void weightedConfigCarriesWeightedPhases() {
        var weightedPhases = List.of(
                new CorpusSelectorConfig.WeightedPhase("normal", 0.8),
                new CorpusSelectorConfig.WeightedPhase("error", 0.2));
        var phases = Map.<String, List<InvocationRecord<Object, Object>>>of(
                "normal", List.of(), "error", List.of());

        var config = new CorpusSelectorConfig.Weighted(weightedPhases, phases);

        assertThat(config.weightedPhases()).hasSize(2);
        assertThat(config.weightedPhases().get(0).weight()).isEqualTo(0.8);
    }

    @Test
    void sealedInterfaceIsExhaustive() {
        CorpusSelectorConfig config = new CorpusSelectorConfig.StateMachine(
                "init", Map.of(), Map.of());
        assertThat(config).isInstanceOf(CorpusSelectorConfig.class);

        var result = switch (config) {
            case CorpusSelectorConfig.StateMachine sm -> "sm";
            case CorpusSelectorConfig.Duration d -> "d";
            case CorpusSelectorConfig.LookupCount lc -> "lc";
            case CorpusSelectorConfig.Weighted w -> "w";
        };
        assertThat(result).isEqualTo("sm");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl simulation-api -Dtest=CorpusSelectorConfigTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — compilation errors, classes don't exist

- [ ] **Step 3: Implement CorpusSelector and CorpusSelectorConfig**

Create `CorpusSelector.java`:
```java
package io.casehub.platform.simulation;

public interface CorpusSelector {
    String activePhase();
    default void onResolved() {}
}
```

Create `CorpusSelectorConfig.java`:
```java
package io.casehub.platform.simulation;

import java.time.Duration;
import java.util.List;
import java.util.Map;

public sealed interface CorpusSelectorConfig {

    Map<String, List<InvocationRecord<Object, Object>>> phases();

    record StateMachine(
            String initial,
            Map<String, Map<String, String>> transitions,
            Map<String, List<InvocationRecord<Object, Object>>> phases
    ) implements CorpusSelectorConfig {}

    record Duration(
            List<DurationPhase> orderedPhases,
            Map<String, List<InvocationRecord<Object, Object>>> phases
    ) implements CorpusSelectorConfig {}

    record LookupCount(
            List<CountPhase> orderedPhases,
            Map<String, List<InvocationRecord<Object, Object>>> phases
    ) implements CorpusSelectorConfig {}

    record Weighted(
            List<WeightedPhase> weightedPhases,
            Map<String, List<InvocationRecord<Object, Object>>> phases
    ) implements CorpusSelectorConfig {}

    record DurationPhase(String name, java.time.Duration duration) {}
    record CountPhase(String name, int count) {}
    record WeightedPhase(String name, double weight) {}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl simulation-api -Dtest=CorpusSelectorConfigTest`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add simulation-api/src/main/java/io/casehub/platform/simulation/CorpusSelector.java simulation-api/src/main/java/io/casehub/platform/simulation/CorpusSelectorConfig.java simulation-api/src/test/java/io/casehub/platform/simulation/CorpusSelectorConfigTest.java
git commit -m "feat(simulation-api): add CorpusSelector interface and CorpusSelectorConfig sealed hierarchy

Refs #729"
```

### Task 2: PhasedCorpus

**Files:**
- Create: `simulation-api/src/main/java/io/casehub/platform/simulation/PhasedCorpus.java`
- Test: `simulation-api/src/test/java/io/casehub/platform/simulation/PhasedCorpusTest.java`

**Interfaces:**
- Consumes: `CorpusSelector` (interface from Task 1), `SimulationCorpus<I,O>` (existing), `InvocationRecord<I,O>` (existing), `SimulationConfigException` (existing)
- Produces: `PhasedCorpus<I,O> implements SimulationCorpus<I,O>` — constructor takes `CorpusSelector selector`, `Map<String, List<InvocationRecord<I,O>>> phases`. Read-only: `record()`, `seed()`, `clear()` throw `UnsupportedOperationException`. Delegates all reads to the active phase's entries.

- [ ] **Step 1: Write failing tests for PhasedCorpus**

```java
package io.casehub.platform.simulation;

import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class PhasedCorpusTest {

    private static final String QN = "test-spi.query";

    @Test
    void lookupByKeyDelegatesToActivePhase() {
        var phase = new AtomicReference<>("phase-a");
        CorpusSelector selector = phase::get;
        var phases = Map.<String, List<InvocationRecord<Object, Object>>>of(
                "phase-a", List.of(InvocationRecord.of("t1", "k1", "in-a", "out-a")),
                "phase-b", List.of(InvocationRecord.of("t1", "k1", "in-b", "out-b")));
        var corpus = new PhasedCorpus<>(selector, phases);

        assertThat(corpus.lookupByKey(QN, "k1")).contains("out-a");

        phase.set("phase-b");
        assertThat(corpus.lookupByKey(QN, "k1")).contains("out-b");
    }

    @Test
    void lookupByIndexDelegatesToActivePhase() {
        var phase = new AtomicReference<>("first");
        CorpusSelector selector = phase::get;
        var phases = Map.<String, List<InvocationRecord<Object, Object>>>of(
                "first", List.of(InvocationRecord.of("t1", null, "in1", "out1")),
                "second", List.of(InvocationRecord.of("t1", null, "in2", "out2")));
        var corpus = new PhasedCorpus<>(selector, phases);

        assertThat(corpus.lookupByIndex(QN, 0)).contains("out1");

        phase.set("second");
        assertThat(corpus.lookupByIndex(QN, 0)).contains("out2");
    }

    @Test
    void listReturnsActivePhaseEntries() {
        CorpusSelector selector = () -> "only";
        var entry = InvocationRecord.of("t1", "k", "in", "out");
        var corpus = new PhasedCorpus<>(selector, Map.of("only", List.of(entry)));

        assertThat(corpus.list(QN)).hasSize(1);
        assertThat(corpus.list(QN).get(0).output()).isEqualTo("out");
    }

    @Test
    void sizeReturnsActivePhaseSize() {
        CorpusSelector selector = () -> "a";
        var corpus = new PhasedCorpus<>(selector, Map.of(
                "a", List.of(InvocationRecord.of("t1", null, "in", "out")),
                "b", List.of()));

        assertThat(corpus.size(QN)).isEqualTo(1);
    }

    @Test
    void unknownPhaseThrowsSimulationConfigException() {
        CorpusSelector selector = () -> "nonexistent";
        var corpus = new PhasedCorpus<>(selector, Map.of("a", List.of()));

        assertThatThrownBy(() -> corpus.lookupByKey(QN, "any"))
                .isInstanceOf(SimulationConfigException.class)
                .hasMessageContaining("nonexistent")
                .hasMessageContaining("a");
    }

    @Test
    void mutationMethodsThrowUnsupportedOperationException() {
        CorpusSelector selector = () -> "a";
        var corpus = new PhasedCorpus<>(selector, Map.of("a", List.of()));

        assertThatThrownBy(() -> corpus.record(QN, "t1", "in", "out"))
                .isInstanceOf(UnsupportedOperationException.class);
        assertThatThrownBy(() -> corpus.record(QN, "t1", "k", "in", "out"))
                .isInstanceOf(UnsupportedOperationException.class);
        assertThatThrownBy(() -> corpus.seed(QN, List.of()))
                .isInstanceOf(UnsupportedOperationException.class);
        assertThatThrownBy(() -> corpus.clear(QN))
                .isInstanceOf(UnsupportedOperationException.class);
    }

    @Test
    void listByTenantFiltersActivePhase() {
        CorpusSelector selector = () -> "a";
        var corpus = new PhasedCorpus<>(selector, Map.of("a", List.of(
                InvocationRecord.of("tenant-1", "k", "in1", "out1"),
                InvocationRecord.of("tenant-2", "k", "in2", "out2"))));

        assertThat(corpus.listByTenant(QN, "tenant-1")).hasSize(1);
        assertThat(corpus.listByTenant(QN, "tenant-1").get(0).output()).isEqualTo("out1");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl simulation-api -Dtest=PhasedCorpusTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — PhasedCorpus doesn't exist

- [ ] **Step 3: Implement PhasedCorpus**

Create `PhasedCorpus.java`:
```java
package io.casehub.platform.simulation;

import java.util.List;
import java.util.Map;
import java.util.Optional;

public final class PhasedCorpus<I, O> implements SimulationCorpus<I, O> {

    private final CorpusSelector selector;
    private final Map<String, List<InvocationRecord<I, O>>> phases;

    public PhasedCorpus(CorpusSelector selector, Map<String, List<InvocationRecord<I, O>>> phases) {
        this.selector = selector;
        this.phases = Map.copyOf(phases);
    }

    @Override
    public Optional<O> lookupByKey(String qualifiedName, String key) {
        return activeEntries(qualifiedName).stream()
                .filter(r -> key.equals(r.key()))
                .map(InvocationRecord::output)
                .findFirst();
    }

    @Override
    public Optional<O> lookupByIndex(String qualifiedName, int index) {
        var entries = activeEntries(qualifiedName);
        if (index < 0 || index >= entries.size()) return Optional.empty();
        return Optional.of(entries.get(index).output());
    }

    @Override
    public List<InvocationRecord<I, O>> list(String qualifiedName) {
        return activeEntries(qualifiedName);
    }

    @Override
    public List<InvocationRecord<I, O>> listByTenant(String qualifiedName, String tenancyId) {
        return activeEntries(qualifiedName).stream()
                .filter(r -> tenancyId.equals(r.tenancyId()))
                .toList();
    }

    @Override
    public int size(String qualifiedName) {
        return activeEntries(qualifiedName).size();
    }

    @Override
    public void record(String qualifiedName, String tenancyId, I input, O output) {
        throw new UnsupportedOperationException("PhasedCorpus is read-only");
    }

    @Override
    public void record(String qualifiedName, String tenancyId, String key, I input, O output) {
        throw new UnsupportedOperationException("PhasedCorpus is read-only");
    }

    @Override
    public void seed(String qualifiedName, List<InvocationRecord<I, O>> records) {
        throw new UnsupportedOperationException("PhasedCorpus is read-only");
    }

    @Override
    public void clear(String qualifiedName) {
        throw new UnsupportedOperationException("PhasedCorpus is read-only");
    }

    private List<InvocationRecord<I, O>> activeEntries(String qualifiedName) {
        String phase = selector.activePhase();
        List<InvocationRecord<I, O>> entries = phases.get(phase);
        if (entries == null) {
            throw new SimulationConfigException(
                    "Phase '" + phase + "' not found in PhasedCorpus for " + qualifiedName
                    + " — available phases: " + phases.keySet());
        }
        return entries;
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl simulation-api -Dtest=PhasedCorpusTest`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add simulation-api/src/main/java/io/casehub/platform/simulation/PhasedCorpus.java simulation-api/src/test/java/io/casehub/platform/simulation/PhasedCorpusTest.java
git commit -m "feat(simulation-api): add PhasedCorpus — phase-switching SimulationCorpus decorator

Refs #729"
```

## Batch 2: Selector Implementations (simulation-core)

### Task 3: StateMachineSelector + LookupCountSelector + DurationSelector + RandomSelector

**Files:**
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/selector/StateMachineSelector.java`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/selector/LookupCountSelector.java`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/selector/DurationSelector.java`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/selector/RandomSelector.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/selector/StateMachineSelectorTest.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/selector/LookupCountSelectorTest.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/selector/DurationSelectorTest.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/selector/RandomSelectorTest.java`

**Interfaces:**
- Consumes: `CorpusSelector` (from Task 1), `CorpusSelectorConfig.*` records (from Task 1), `SpeedMultiplier` (from yaml-core, for DurationSelector)
- Produces:
  - `StateMachineSelector implements CorpusSelector` — constructor: `(String initial, Map<String, Map<String, String>> transitions)`. Extra method: `void advance(String trigger)`.
  - `DurationSelector implements CorpusSelector` — constructor: `(List<DurationPhase> phases, SpeedMultiplier speedMultiplier)`. Package-private test constructor adds `LongSupplier nanoSource`.
  - `LookupCountSelector implements CorpusSelector` — constructor: `(List<CountPhase> phases)`. Overrides `onResolved()` to increment counter.
  - `RandomSelector implements CorpusSelector` — constructor: `(List<WeightedPhase> phases, Random random)`.

- [ ] **Step 1: Write failing tests for all four selectors**

Create `StateMachineSelectorTest.java`:
```java
package io.casehub.platform.simulation.selector;

import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class StateMachineSelectorTest {

    @Test
    void initialStateIsActivePhase() {
        var selector = new StateMachineSelector("pending",
                Map.of("pending", Map.of("pay", "completed")));
        assertThat(selector.activePhase()).isEqualTo("pending");
    }

    @Test
    void advanceTransitionsToNewState() {
        var selector = new StateMachineSelector("pending",
                Map.of("pending", Map.of("pay", "completed"),
                       "completed", Map.of("ship", "shipped")));

        selector.advance("pay");
        assertThat(selector.activePhase()).isEqualTo("completed");

        selector.advance("ship");
        assertThat(selector.activePhase()).isEqualTo("shipped");
    }

    @Test
    void unknownTriggerDoesNotChangeState() {
        var selector = new StateMachineSelector("pending",
                Map.of("pending", Map.of("pay", "completed")));

        selector.advance("unknown");
        assertThat(selector.activePhase()).isEqualTo("pending");
    }

    @Test
    void terminalStateIgnoresAllTriggers() {
        var selector = new StateMachineSelector("pending",
                Map.of("pending", Map.of("pay", "done")));

        selector.advance("pay");
        assertThat(selector.activePhase()).isEqualTo("done");

        selector.advance("pay");
        assertThat(selector.activePhase()).isEqualTo("done");
    }
}
```

Create `LookupCountSelectorTest.java`:
```java
package io.casehub.platform.simulation.selector;

import io.casehub.platform.simulation.CorpusSelectorConfig;
import org.junit.jupiter.api.Test;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;

class LookupCountSelectorTest {

    @Test
    void firstPhaseActiveBeforeCountReached() {
        var selector = new LookupCountSelector(List.of(
                new CorpusSelectorConfig.CountPhase("pending", 3),
                new CorpusSelectorConfig.CountPhase("completed", 0)));

        assertThat(selector.activePhase()).isEqualTo("pending");
        selector.onResolved();
        assertThat(selector.activePhase()).isEqualTo("pending");
        selector.onResolved();
        assertThat(selector.activePhase()).isEqualTo("pending");
    }

    @Test
    void advancesToNextPhaseAfterCount() {
        var selector = new LookupCountSelector(List.of(
                new CorpusSelectorConfig.CountPhase("pending", 2),
                new CorpusSelectorConfig.CountPhase("completed", 0)));

        selector.onResolved();
        selector.onResolved();
        assertThat(selector.activePhase()).isEqualTo("completed");
    }

    @Test
    void terminalPhaseStaysIndefinitely() {
        var selector = new LookupCountSelector(List.of(
                new CorpusSelectorConfig.CountPhase("a", 1),
                new CorpusSelectorConfig.CountPhase("b", 0)));

        selector.onResolved();
        assertThat(selector.activePhase()).isEqualTo("b");
        selector.onResolved();
        selector.onResolved();
        assertThat(selector.activePhase()).isEqualTo("b");
    }
}
```

Create `DurationSelectorTest.java`:
```java
package io.casehub.platform.simulation.selector;

import io.casehub.platform.simulation.CorpusSelectorConfig;
import io.casehub.yaml.core.runtime.SpeedMultiplier;
import org.junit.jupiter.api.Test;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;
import static org.assertj.core.api.Assertions.assertThat;

class DurationSelectorTest {

    @Test
    void firstPhaseActiveBeforeDuration() {
        var clock = new AtomicLong(0);
        var selector = new DurationSelector(
                List.of(
                        new CorpusSelectorConfig.DurationPhase("normal", Duration.ofSeconds(10)),
                        new CorpusSelectorConfig.DurationPhase("degraded", null)),
                SpeedMultiplier.identity(),
                clock::get);

        assertThat(selector.activePhase()).isEqualTo("normal");
    }

    @Test
    void advancesAfterDuration() {
        var clock = new AtomicLong(0);
        var selector = new DurationSelector(
                List.of(
                        new CorpusSelectorConfig.DurationPhase("normal", Duration.ofSeconds(10)),
                        new CorpusSelectorConfig.DurationPhase("degraded", null)),
                SpeedMultiplier.identity(),
                clock::get);

        clock.set(Duration.ofSeconds(11).toNanos());
        assertThat(selector.activePhase()).isEqualTo("degraded");
    }

    @Test
    void respectsSpeedMultiplier() {
        var clock = new AtomicLong(0);
        var selector = new DurationSelector(
                List.of(
                        new CorpusSelectorConfig.DurationPhase("normal", Duration.ofSeconds(10)),
                        new CorpusSelectorConfig.DurationPhase("degraded", null)),
                () -> 10.0,
                clock::get);

        clock.set(Duration.ofSeconds(2).toNanos());
        assertThat(selector.activePhase()).isEqualTo("degraded");
    }

    @Test
    void multiplePhases() {
        var clock = new AtomicLong(0);
        var selector = new DurationSelector(
                List.of(
                        new CorpusSelectorConfig.DurationPhase("a", Duration.ofSeconds(5)),
                        new CorpusSelectorConfig.DurationPhase("b", Duration.ofSeconds(5)),
                        new CorpusSelectorConfig.DurationPhase("c", null)),
                SpeedMultiplier.identity(),
                clock::get);

        assertThat(selector.activePhase()).isEqualTo("a");
        clock.set(Duration.ofSeconds(6).toNanos());
        assertThat(selector.activePhase()).isEqualTo("b");
        clock.set(Duration.ofSeconds(11).toNanos());
        assertThat(selector.activePhase()).isEqualTo("c");
    }
}
```

Create `RandomSelectorTest.java`:
```java
package io.casehub.platform.simulation.selector;

import io.casehub.platform.simulation.CorpusSelectorConfig;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Random;
import static org.assertj.core.api.Assertions.assertThat;

class RandomSelectorTest {

    @Test
    void selectsPhaseByWeight() {
        var selector = new RandomSelector(
                List.of(
                        new CorpusSelectorConfig.WeightedPhase("normal", 0.8),
                        new CorpusSelectorConfig.WeightedPhase("error", 0.2)),
                new Random(42));

        var results = java.util.stream.IntStream.range(0, 1000)
                .mapToObj(i -> selector.activePhase())
                .toList();

        long normalCount = results.stream().filter("normal"::equals).count();
        assertThat(normalCount).isBetween(700L, 900L);
    }

    @Test
    void deterministicWithFixedSeed() {
        var selector1 = new RandomSelector(
                List.of(
                        new CorpusSelectorConfig.WeightedPhase("a", 0.5),
                        new CorpusSelectorConfig.WeightedPhase("b", 0.5)),
                new Random(123));
        var selector2 = new RandomSelector(
                List.of(
                        new CorpusSelectorConfig.WeightedPhase("a", 0.5),
                        new CorpusSelectorConfig.WeightedPhase("b", 0.5)),
                new Random(123));

        for (int i = 0; i < 100; i++) {
            assertThat(selector1.activePhase()).isEqualTo(selector2.activePhase());
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl simulation-core -Dtest="StateMachineSelectorTest,LookupCountSelectorTest,DurationSelectorTest,RandomSelectorTest" -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — selector classes don't exist

- [ ] **Step 3: Implement all four selectors**

Create `StateMachineSelector.java`:
```java
package io.casehub.platform.simulation.selector;

import io.casehub.platform.simulation.CorpusSelector;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

public final class StateMachineSelector implements CorpusSelector {

    private final Map<String, Map<String, String>> transitions;
    private final AtomicReference<String> currentState;

    public StateMachineSelector(String initial, Map<String, Map<String, String>> transitions) {
        this.currentState = new AtomicReference<>(initial);
        this.transitions = Map.copyOf(transitions);
    }

    @Override
    public String activePhase() {
        return currentState.get();
    }

    public void advance(String trigger) {
        currentState.getAndUpdate(state -> {
            Map<String, String> stateTransitions = transitions.get(state);
            if (stateTransitions == null) return state;
            String next = stateTransitions.get(trigger);
            return next != null ? next : state;
        });
    }
}
```

Create `LookupCountSelector.java`:
```java
package io.casehub.platform.simulation.selector;

import io.casehub.platform.simulation.CorpusSelector;
import io.casehub.platform.simulation.CorpusSelectorConfig;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

public final class LookupCountSelector implements CorpusSelector {

    private final List<CorpusSelectorConfig.CountPhase> phases;
    private final AtomicInteger resolveCount = new AtomicInteger(0);

    public LookupCountSelector(List<CorpusSelectorConfig.CountPhase> phases) {
        this.phases = List.copyOf(phases);
    }

    @Override
    public String activePhase() {
        int count = resolveCount.get();
        int cumulative = 0;
        for (var phase : phases) {
            if (phase.count() <= 0 || count < cumulative + phase.count()) {
                return phase.name();
            }
            cumulative += phase.count();
        }
        return phases.get(phases.size() - 1).name();
    }

    @Override
    public void onResolved() {
        resolveCount.incrementAndGet();
    }
}
```

Create `DurationSelector.java`:
```java
package io.casehub.platform.simulation.selector;

import io.casehub.platform.simulation.CorpusSelector;
import io.casehub.platform.simulation.CorpusSelectorConfig;
import io.casehub.yaml.core.runtime.SpeedMultiplier;
import java.util.List;
import java.util.function.LongSupplier;

public final class DurationSelector implements CorpusSelector {

    private final List<CorpusSelectorConfig.DurationPhase> phases;
    private final SpeedMultiplier speedMultiplier;
    private final LongSupplier nanoSource;
    private final long startNanos;

    public DurationSelector(List<CorpusSelectorConfig.DurationPhase> phases,
                            SpeedMultiplier speedMultiplier) {
        this(phases, speedMultiplier, System::nanoTime);
    }

    DurationSelector(List<CorpusSelectorConfig.DurationPhase> phases,
                     SpeedMultiplier speedMultiplier,
                     LongSupplier nanoSource) {
        this.phases = List.copyOf(phases);
        this.speedMultiplier = speedMultiplier;
        this.nanoSource = nanoSource;
        this.startNanos = nanoSource.getAsLong();
    }

    @Override
    public String activePhase() {
        long elapsed = nanoSource.getAsLong() - startNanos;
        double speed = speedMultiplier.currentSpeed();
        long simulatedNanos = (long) (elapsed * speed);

        long cumulative = 0;
        for (var phase : phases) {
            if (phase.duration() == null || simulatedNanos < cumulative + phase.duration().toNanos()) {
                return phase.name();
            }
            cumulative += phase.duration().toNanos();
        }
        return phases.get(phases.size() - 1).name();
    }
}
```

Create `RandomSelector.java`:
```java
package io.casehub.platform.simulation.selector;

import io.casehub.platform.simulation.CorpusSelector;
import io.casehub.platform.simulation.CorpusSelectorConfig;
import java.util.List;
import java.util.Random;

public final class RandomSelector implements CorpusSelector {

    private final List<CorpusSelectorConfig.WeightedPhase> phases;
    private final Random random;

    public RandomSelector(List<CorpusSelectorConfig.WeightedPhase> phases, Random random) {
        this.phases = List.copyOf(phases);
        this.random = random;
    }

    @Override
    public String activePhase() {
        double r = random.nextDouble();
        double cumulative = 0;
        for (var phase : phases) {
            cumulative += phase.weight();
            if (r < cumulative) {
                return phase.name();
            }
        }
        return phases.get(phases.size() - 1).name();
    }
}
```

- [ ] **Step 4: Run all selector tests**

Run: `mvn --batch-mode test -pl simulation-core -Dtest="StateMachineSelectorTest,LookupCountSelectorTest,DurationSelectorTest,RandomSelectorTest"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add simulation-core/src/main/java/io/casehub/platform/simulation/selector/ simulation-core/src/test/java/io/casehub/platform/simulation/selector/
git commit -m "feat(simulation-core): add four CorpusSelector implementations

StateMachineSelector, LookupCountSelector, DurationSelector, RandomSelector.

Refs #729"
```

## Batch 3: SimulationRuntime + SimulationConfig Integration

### Task 4: Extend SimulationConfig and wire PhasedCorpus into SimulationRuntime

**Files:**
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationConfig.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java`
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/MapSimulationConfig.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/PhasedCorpusRuntimeTest.java`

**Interfaces:**
- Consumes: `CorpusSelector`, `CorpusSelectorConfig`, `PhasedCorpus` (from Tasks 1-2), all four selector implementations (from Task 3), `SpeedMultiplier` (from yaml-core)
- Produces:
  - `SimulationConfig.corpusSelection(String qualifiedName)` → `Optional<CorpusSelectorConfig>` (default `Optional.empty()`)
  - `SimulationRuntime.stateMachineSelector(String qualifiedName)` → `Optional<StateMachineSelector>`
  - `MapSimulationConfig.Builder.corpusSelection(String qualifiedName, CorpusSelectorConfig config)` builder method

- [ ] **Step 1: Write failing tests for runtime integration**

Create `PhasedCorpusRuntimeTest.java`:
```java
package io.casehub.platform.simulation;

import io.casehub.platform.simulation.selector.LookupCountSelector;
import io.casehub.platform.simulation.selector.StateMachineSelector;
import org.junit.jupiter.api.Test;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import static org.assertj.core.api.Assertions.assertThat;

class PhasedCorpusRuntimeTest {

    private static final String QN = "test-spi.query";

    @Test
    void strategyUsesPhasedCorpusWhenCorpusSelectionConfigured() {
        var phases = Map.<String, List<InvocationRecord<Object, Object>>>of(
                "pending", List.of(new InvocationRecord<>("t1", "k1", (Object) "in", (Object) "pending-out", Instant.now())),
                "completed", List.of(new InvocationRecord<>("t1", "k1", (Object) "in", (Object) "completed-out", Instant.now())));
        var smConfig = new CorpusSelectorConfig.StateMachine("pending",
                Map.of("pending", Map.of("pay", "completed")), phases);

        var config = MapSimulationConfig.builder()
                .strategy(QN, "key-lookup")
                .corpusSelection(QN, smConfig)
                .build();
        var runtime = new SimulationRuntime(config, new NoOpSimulationCorpus<>());
        runtime.registerExtractor(QN, (Object input) -> "k1");

        var strategy = runtime.<Object, Object>strategyFor(QN);
        assertThat(strategy).isPresent();
        assertThat(strategy.get().resolve("anything")).isEqualTo("pending-out");

        runtime.stateMachineSelector(QN).ifPresent(sm -> sm.advance("pay"));
        assertThat(strategy.get().resolve("anything")).isEqualTo("completed-out");
    }

    @Test
    void lookupCountSelectorAdvancesViaOnResolved() {
        var phases = Map.<String, List<InvocationRecord<Object, Object>>>of(
                "a", List.of(new InvocationRecord<>("t1", null, (Object) "in", (Object) "out-a", Instant.now())),
                "b", List.of(new InvocationRecord<>("t1", null, (Object) "in", (Object) "out-b", Instant.now())));
        var lcConfig = new CorpusSelectorConfig.LookupCount(
                List.of(new CorpusSelectorConfig.CountPhase("a", 2),
                        new CorpusSelectorConfig.CountPhase("b", 0)), phases);

        var config = MapSimulationConfig.builder()
                .strategy(QN, "sequential")
                .corpusSelection(QN, lcConfig)
                .build();
        var runtime = new SimulationRuntime(config, new NoOpSimulationCorpus<>());

        var strategy = runtime.<Object, Object>strategyFor(QN);
        assertThat(strategy).isPresent();

        assertThat(strategy.get().resolve("x")).isEqualTo("out-a");
        assertThat(strategy.get().resolve("x")).isEqualTo("out-a");
        assertThat(strategy.get().resolve("x")).isEqualTo("out-b");
    }

    @Test
    void noCorpusSelectionUsesRegularCorpus() {
        var config = MapSimulationConfig.builder()
                .strategy(QN, "sequential")
                .build();
        var corpus = new NoOpSimulationCorpus<>();
        var runtime = new SimulationRuntime(config, corpus);

        assertThat(runtime.stateMachineSelector(QN)).isEmpty();
    }

    @Test
    void selectorSurvivesOverlayPushPop() {
        var phases = Map.<String, List<InvocationRecord<Object, Object>>>of(
                "a", List.of(new InvocationRecord<>("t1", null, (Object) "in", (Object) "out-a", Instant.now())),
                "b", List.of(new InvocationRecord<>("t1", null, (Object) "in", (Object) "out-b", Instant.now())));
        var smConfig = new CorpusSelectorConfig.StateMachine("a",
                Map.of("a", Map.of("go", "b")), phases);

        var config = MapSimulationConfig.builder()
                .strategy(QN, "sequential")
                .corpusSelection(QN, smConfig)
                .build();
        var runtime = new SimulationRuntime(config, new NoOpSimulationCorpus<>());

        var strategy1 = runtime.<Object, Object>strategyFor(QN);
        assertThat(strategy1.get().resolve("x")).isEqualTo("out-a");

        runtime.stateMachineSelector(QN).ifPresent(sm -> sm.advance("go"));

        var overlay = runtime.pushOverlay(MapSimulationConfig.of(Map.of("other.method", "seq")));
        runtime.popOverlay(overlay);

        var strategy2 = runtime.<Object, Object>strategyFor(QN);
        assertThat(strategy2.get().resolve("x")).isEqualTo("out-b");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=PhasedCorpusRuntimeTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — `corpusSelection()` method doesn't exist on `SimulationConfig`

- [ ] **Step 3: Extend SimulationConfig**

Add to `SimulationConfig.java`:
```java
default Optional<CorpusSelectorConfig> corpusSelection(String qualifiedName) {
    return Optional.empty();
}
```

- [ ] **Step 4: Extend MapSimulationConfig**

Add a `Map<String, CorpusSelectorConfig> corpusSelections` field. Add to `Builder`:
```java
public Builder corpusSelection(String qualifiedName, CorpusSelectorConfig config) {
    corpusSelections.put(qualifiedName, config);
    return this;
}
```
Add `corpusSelection()` override returning from the map.

- [ ] **Step 5: Wire PhasedCorpus into SimulationRuntime**

Modify `SimulationRuntime`:
- Add field: `private final ConcurrentHashMap<String, CorpusSelector> corpusSelectors = new ConcurrentHashMap<>();`
- In `createStrategy()`: check `config.corpusSelection(qualifiedName)`. If present, call `buildSelector()` to get or create the selector via `corpusSelectors.computeIfAbsent()`, create `PhasedCorpus`, wrap the strategy with `wrapWithSelector()`.
- Add `buildSelector()` private method (exhaustive switch on `CorpusSelectorConfig` sealed variants).
- Add `wrapWithSelector()` private static method that wraps strategy to call `selector.onResolved()` after `resolve()`.
- Add `stateMachineSelector(String qualifiedName)` public method.
- Pass the effective `SimulationConfig` into `createStrategy()` from `strategyFor()` (base config or overlay config).

- [ ] **Step 6: Run tests**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=PhasedCorpusRuntimeTest`
Expected: PASS

- [ ] **Step 7: Run full simulation-core test suite**

Run: `mvn --batch-mode test -pl simulation-core`
Expected: PASS — no regressions in existing tests

- [ ] **Step 8: Commit**

```bash
git add simulation-core/src/main/java/io/casehub/platform/simulation/SimulationConfig.java simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java simulation-core/src/main/java/io/casehub/platform/simulation/MapSimulationConfig.java simulation-core/src/test/java/io/casehub/platform/simulation/PhasedCorpusRuntimeTest.java
git commit -m "feat(simulation-core): wire PhasedCorpus into SimulationRuntime

SimulationConfig.corpusSelection() extension, selector persistence
across overlay cycles, onResolved() lifecycle hook via strategy wrapping.

Refs #729"
```

## Batch 4: YAML Parsing + Schema Update (simulation-config-core)

### Task 5: YamlSimulationConfig corpus-selection parsing + schema update

**Files:**
- Modify: `simulation-config-core/src/main/java/io/casehub/platform/simulation/config/YamlSimulationConfig.java`
- Modify: `simulation-config-core/src/main/resources/schema/simulation.schema.json`
- Test: `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/YamlCorpusSelectionTest.java`
- Modify: `simulation-config-core/src/test/java/io/casehub/platform/simulation/config/SimulationSchemaTest.java`

**Interfaces:**
- Consumes: `CorpusSelectorConfig.*` records (from Task 1), `InvocationRecord` (existing), `DurationParser` (existing in simulation-config-core)
- Produces: `YamlSimulationConfig.corpusSelection(String qualifiedName)` returns the parsed `CorpusSelectorConfig` for the given method, or `Optional.empty()`.

- [ ] **Step 1: Write failing tests for YAML parsing**

Create `YamlCorpusSelectionTest.java`:
```java
package io.casehub.platform.simulation.config;

import io.casehub.platform.simulation.CorpusSelectorConfig;
import org.junit.jupiter.api.Test;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class YamlCorpusSelectionTest {

    @Test
    void parsesStateMachineCorpusSelection() {
        var yaml = """
                methods:
                  test-spi.query:
                    strategy: key-lookup
                    corpus-selection:
                      type: state-machine
                      initial: pending
                      transitions:
                        pending:
                          pay: completed
                      phases:
                        pending:
                          - key: k1
                            output: pending-result
                        completed:
                          - key: k1
                            output: completed-result
                """;
        var config = parse(yaml);

        var selection = config.corpusSelection("test-spi.query");
        assertThat(selection).isPresent();
        assertThat(selection.get()).isInstanceOf(CorpusSelectorConfig.StateMachine.class);

        var sm = (CorpusSelectorConfig.StateMachine) selection.get();
        assertThat(sm.initial()).isEqualTo("pending");
        assertThat(sm.transitions()).containsKey("pending");
        assertThat(sm.phases()).containsKeys("pending", "completed");
        assertThat(sm.phases().get("pending")).hasSize(1);
    }

    @Test
    void parsesDurationCorpusSelection() {
        var yaml = """
                methods:
                  test-spi.query:
                    strategy: sequential
                    corpus-selection:
                      type: duration
                      phases:
                        - name: normal
                          duration: 10s
                          corpus:
                            - output: normal-result
                        - name: degraded
                          corpus:
                            - output: degraded-result
                """;
        var config = parse(yaml);

        var selection = config.corpusSelection("test-spi.query");
        assertThat(selection).isPresent();
        assertThat(selection.get()).isInstanceOf(CorpusSelectorConfig.Duration.class);

        var d = (CorpusSelectorConfig.Duration) selection.get();
        assertThat(d.orderedPhases()).hasSize(2);
        assertThat(d.orderedPhases().get(0).duration().getSeconds()).isEqualTo(10);
        assertThat(d.orderedPhases().get(1).duration()).isNull();
    }

    @Test
    void parsesLookupCountCorpusSelection() {
        var yaml = """
                methods:
                  test-spi.query:
                    strategy: sequential
                    corpus-selection:
                      type: lookup-count
                      phases:
                        - name: pending
                          count: 3
                          corpus:
                            - output: pending-result
                        - name: completed
                          corpus:
                            - output: completed-result
                """;
        var config = parse(yaml);

        var selection = config.corpusSelection("test-spi.query");
        assertThat(selection).isPresent();
        assertThat(selection.get()).isInstanceOf(CorpusSelectorConfig.LookupCount.class);

        var lc = (CorpusSelectorConfig.LookupCount) selection.get();
        assertThat(lc.orderedPhases()).hasSize(2);
        assertThat(lc.orderedPhases().get(0).count()).isEqualTo(3);
    }

    @Test
    void parsesRandomCorpusSelection() {
        var yaml = """
                methods:
                  test-spi.query:
                    strategy: key-lookup
                    corpus-selection:
                      type: random
                      phases:
                        - name: normal
                          weight: 0.8
                          corpus:
                            - key: k1
                              output: ok
                        - name: error
                          weight: 0.2
                          corpus:
                            - key: k1
                              output: fail
                """;
        var config = parse(yaml);

        var selection = config.corpusSelection("test-spi.query");
        assertThat(selection).isPresent();
        assertThat(selection.get()).isInstanceOf(CorpusSelectorConfig.Weighted.class);

        var w = (CorpusSelectorConfig.Weighted) selection.get();
        assertThat(w.weightedPhases()).hasSize(2);
        assertThat(w.weightedPhases().get(0).weight()).isEqualTo(0.8);
    }

    @Test
    void corpusAndCorpusSelectionAreMutuallyExclusive() {
        var yaml = """
                methods:
                  test-spi.query:
                    strategy: sequential
                    corpus:
                      - output: static
                    corpus-selection:
                      type: duration
                      phases:
                        - name: a
                          corpus:
                            - output: phased
                """;
        assertThatThrownBy(() -> parse(yaml))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("mutually exclusive");
    }

    @Test
    void noCorpusSelectionReturnsEmpty() {
        var yaml = """
                methods:
                  test-spi.query:
                    strategy: sequential
                    corpus:
                      - output: static
                """;
        var config = parse(yaml);
        assertThat(config.corpusSelection("test-spi.query")).isEmpty();
    }

    private YamlSimulationConfig parse(String yaml) {
        return new YamlSimulationConfig(
                new ByteArrayInputStream(yaml.getBytes(StandardCharsets.UTF_8)));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl simulation-config-core -Dtest=YamlCorpusSelectionTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — `corpusSelection()` not implemented in `YamlSimulationConfig`

- [ ] **Step 3: Implement corpus-selection parsing in YamlSimulationConfig**

Modify `YamlSimulationConfig`:
- Add `corpusSelection` field to `MethodConfig` record
- Add parsing logic in `parseMethodConfig()`: read `corpus-selection` map, validate mutual exclusion with `corpus`/`corpus-files`, dispatch to `parseCorpusSelectionConfig()` by type
- Add `parseCorpusSelectionConfig()` private method with branches for `state-machine`, `duration`, `lookup-count`, `random`
- For each phase, reuse existing `CorpusEntry` parsing (same structure as inline corpus entries)
- Use `DurationParser.parse()` for duration strings
- Override `corpusSelection(String qualifiedName)` returning from parsed data

- [ ] **Step 4: Run parsing tests**

Run: `mvn --batch-mode test -pl simulation-config-core -Dtest=YamlCorpusSelectionTest`
Expected: PASS

- [ ] **Step 5: Update simulation.schema.json**

Add `corpus-selection` property to `method-config`. Add `$defs/corpus-selection-config` with `if/then` blocks for each type. Add `not`/`anyOf` constraint for mutual exclusion with `corpus` and `corpus-files`.

- [ ] **Step 6: Add schema drift tests**

Add to `SimulationSchemaTest.java`:
```java
@Test
void methodConfigDefinesCorpusSelection() throws IOException {
    JsonNode props = loadSchema().at("/$defs/method-config/properties");
    assertThat(props.has("corpus-selection")).isTrue();
}

@Test
void corpusSelectionConfigDefined() throws IOException {
    JsonNode config = loadSchema().at("/$defs/corpus-selection-config");
    assertThat(config.has("required")).isTrue();
    assertThat(config.get("required").toString()).contains("type");
    JsonNode typeEnum = config.at("/properties/type/enum");
    assertThat(typeEnum.toString()).contains("state-machine", "duration", "lookup-count", "random");
}

@Test
void corpusAndCorpusSelectionMutuallyExclusiveInSchema() throws IOException {
    JsonNode methodConfig = loadSchema().at("/$defs/method-config");
    assertThat(methodConfig.has("not")).isTrue();
}
```

- [ ] **Step 7: Run all simulation-config-core tests**

Run: `mvn --batch-mode test -pl simulation-config-core`
Expected: PASS — all existing + new tests pass

- [ ] **Step 8: Commit**

```bash
git add simulation-config-core/src/main/java/io/casehub/platform/simulation/config/YamlSimulationConfig.java simulation-config-core/src/main/resources/schema/simulation.schema.json simulation-config-core/src/test/java/io/casehub/platform/simulation/config/YamlCorpusSelectionTest.java simulation-config-core/src/test/java/io/casehub/platform/simulation/config/SimulationSchemaTest.java
git commit -m "feat(simulation-config-core): parse corpus-selection YAML + schema update

Supports state-machine, duration, lookup-count, and random types.
Mutually exclusive with corpus/corpus-files.

Refs #729"
```

## Batch 5: Full Build Verification

### Task 6: Full build + integration smoke test

**Files:**
- No new files — verification only

**Interfaces:**
- Consumes: everything from Tasks 1-5
- Produces: green build across all modules

- [ ] **Step 1: Run full project build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS with all tests passing

- [ ] **Step 2: Fix any compilation errors in downstream modules**

If any module fails to compile due to the `SimulationConfig` interface change (new `corpusSelection()` default method), the default `Optional.empty()` return should handle it. Check for any anonymous `SimulationConfig` implementations in tests that might need updating.

- [ ] **Step 3: Commit any fixes**

If fixes were needed:
```bash
git add -A
git commit -m "fix: resolve downstream compilation for SimulationConfig change

Refs #729"
```

## References

- [2026-11-06-dynamic-corpus-selection-design.md] — design spec this plan implements
- SimulationRuntime.java:52-66, 171-196 — strategy resolution and creation
- SimulationCorpus.java — interface being decorated by PhasedCorpus
- SimulationConfig.java — interface extended with corpusSelection()
- MapSimulationConfig.java — builder extended for programmatic use
- KeyLookupStrategy.java — representative strategy using PhasedCorpus transparently
- YamlSimulationConfig.java — YAML parsing extended for corpus-selection blocks
- simulation.schema.json — JSON Schema extended
- SimulationRuntimeTest.java — existing test patterns (stubConfig, TestCorpus helpers)
- SimulationSchemaTest.java — existing schema drift test patterns
- yaml-core SpeedMultiplier — consumed by DurationSelector
- GitHub #729 — focal issue
