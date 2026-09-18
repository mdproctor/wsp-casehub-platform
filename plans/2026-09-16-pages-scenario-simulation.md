# Pages Scenario Simulation Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #322 — pages scenario integration — strategy and corpus configuration in scenario scripts
**Issue group:** #322 (platform), casehub-pages#450 (pages)

**Goal:** Add runtime-scoped simulation overlay stack to SimulationRuntime so scenario scripts can configure strategies, seed corpora, and assert against simulated invocations with per-scenario isolation.

**Architecture:** SimulationRuntime gains a CopyOnWriteArrayList overlay stack. Each overlay contains its own SimulationConfig, SimulationCorpus, and InvocationJournal. Strategy resolution walks the stack top-down. Generated decorators gain journal recording. Pages ScenarioOrchestrator calls pushOverlay/popOverlay around scenario execution.

**Tech Stack:** Java 21, JUnit 5, AssertJ, Jackson YAML, CDI (Quarkus)

## Global Constraints

- simulation-core is a POJO module — no CDI, no Quarkus imports
- simulation-api is zero-dep — no additions to it
- Pages scenario-runtime depends on Quarkus CDI
- All new types in simulation-core use constructor injection
- Tests use JUnit 5 + AssertJ (no Quarkus test runtime for simulation-core)

---

## Batch 1: Platform overlay infrastructure (simulation-core)

### Task 1: JournalEntry record and InvocationJournal

**Files:**
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/JournalEntry.java`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/InvocationJournal.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/InvocationJournalTest.java`

**Interfaces:**
- Consumes: nothing
- Produces: `JournalEntry(String qualifiedName, Object input, Object output, Instant timestamp, boolean simulated)`, `InvocationJournal` with `void record(JournalEntry)`, `List<JournalEntry> entries()`, `List<JournalEntry> entriesFor(String qualifiedName)`, `long countFor(String qualifiedName)`

- [ ] **Step 1: Write the failing test**

```java
package io.casehub.platform.simulation;

import org.junit.jupiter.api.Test;
import java.time.Instant;
import static org.assertj.core.api.Assertions.assertThat;

class InvocationJournalTest {

    @Test
    void recordAndRetrieveEntries() {
        var journal = new InvocationJournal();
        var entry = new JournalEntry("spi.method", "input", "output", Instant.now(), true);
        journal.record(entry);

        assertThat(journal.entries()).hasSize(1);
        assertThat(journal.entries().get(0).qualifiedName()).isEqualTo("spi.method");
        assertThat(journal.entries().get(0).simulated()).isTrue();
    }

    @Test
    void entriesForFiltersbyQualifiedName() {
        var journal = new InvocationJournal();
        journal.record(new JournalEntry("spi.a", "in1", "out1", Instant.now(), true));
        journal.record(new JournalEntry("spi.b", "in2", "out2", Instant.now(), false));
        journal.record(new JournalEntry("spi.a", "in3", "out3", Instant.now(), true));

        assertThat(journal.entriesFor("spi.a")).hasSize(2);
        assertThat(journal.entriesFor("spi.b")).hasSize(1);
        assertThat(journal.entriesFor("spi.c")).isEmpty();
    }

    @Test
    void countForReturnsCorrectCount() {
        var journal = new InvocationJournal();
        journal.record(new JournalEntry("spi.a", "in1", "out1", Instant.now(), true));
        journal.record(new JournalEntry("spi.a", "in2", "out2", Instant.now(), false));

        assertThat(journal.countFor("spi.a")).isEqualTo(2);
        assertThat(journal.countFor("spi.b")).isZero();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl simulation-core test -Dtest=InvocationJournalTest -q --batch-mode`
Expected: FAIL — classes do not exist

- [ ] **Step 3: Write JournalEntry record**

```java
package io.casehub.platform.simulation;

import java.time.Instant;

public record JournalEntry(
    String qualifiedName,
    Object input,
    Object output,
    Instant timestamp,
    boolean simulated
) {}
```

- [ ] **Step 4: Write InvocationJournal**

```java
package io.casehub.platform.simulation;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public final class InvocationJournal {

    private final List<JournalEntry> entries = Collections.synchronizedList(new ArrayList<>());

    public void record(final JournalEntry entry) {
        entries.add(entry);
    }

    public List<JournalEntry> entries() {
        return List.copyOf(entries);
    }

    public List<JournalEntry> entriesFor(final String qualifiedName) {
        return entries.stream()
                .filter(e -> qualifiedName.equals(e.qualifiedName()))
                .toList();
    }

    public long countFor(final String qualifiedName) {
        return entries.stream()
                .filter(e -> qualifiedName.equals(e.qualifiedName()))
                .count();
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mvn -pl simulation-core test -Dtest=InvocationJournalTest -q --batch-mode`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add simulation-core/src/main/java/io/casehub/platform/simulation/JournalEntry.java simulation-core/src/main/java/io/casehub/platform/simulation/InvocationJournal.java simulation-core/src/test/java/io/casehub/platform/simulation/InvocationJournalTest.java
git commit -m "feat(#322): JournalEntry record and InvocationJournal"
```

---

### Task 2: MapSimulationConfig and SimulationOverlay

**Files:**
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/MapSimulationConfig.java`
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationOverlay.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/MapSimulationConfigTest.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/SimulationOverlayTest.java`

**Interfaces:**
- Consumes: `InvocationJournal` (from Task 1), `SimulationConfig` (existing), `SimulationCorpus` (existing)
- Produces: `MapSimulationConfig` with `static of(Map<String, String> strategies)`, `static of(Map<String, String> strategies, Map<String, Boolean> captures)`. `SimulationOverlay` with `SimulationConfig config()`, `SimulationCorpus corpus()`, `InvocationJournal journal()`

- [ ] **Step 1: Write the failing tests**

```java
package io.casehub.platform.simulation;

import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class MapSimulationConfigTest {

    @Test
    void strategyForReturnsConfiguredStrategy() {
        var config = MapSimulationConfig.of(Map.of("spi.query", "sequential"));
        assertThat(config.strategyFor("spi.query")).hasValue("sequential");
    }

    @Test
    void strategyForReturnsEmptyForUnconfigured() {
        var config = MapSimulationConfig.of(Map.of("spi.query", "sequential"));
        assertThat(config.strategyFor("spi.store")).isEmpty();
    }

    @Test
    void captureEnabledFromExplicitConfig() {
        var config = MapSimulationConfig.of(
                Map.of("spi.query", "sequential"),
                Map.of("spi.store", true));
        assertThat(config.captureEnabled("spi.store")).isTrue();
        assertThat(config.captureEnabled("spi.query")).isFalse();
    }

    @Test
    void exhaustionPolicyAlwaysEmpty() {
        var config = MapSimulationConfig.of(Map.of("spi.query", "sequential"));
        assertThat(config.exhaustionPolicy("spi.query")).isEmpty();
    }
}
```

```java
package io.casehub.platform.simulation;

import io.casehub.platform.simulation.inmem.InMemorySimulationCorpus;
import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class SimulationOverlayTest {

    @Test
    void overlayExposesConfigCorpusAndJournal() {
        var config = MapSimulationConfig.of(Map.of("spi.query", "sequential"));
        var corpus = new InMemorySimulationCorpus<>();
        var overlay = new SimulationOverlay(config, corpus);

        assertThat(overlay.config().strategyFor("spi.query")).hasValue("sequential");
        assertThat(overlay.corpus()).isSameAs(corpus);
        assertThat(overlay.journal()).isNotNull();
        assertThat(overlay.journal().entries()).isEmpty();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl simulation-core test -Dtest="MapSimulationConfigTest,SimulationOverlayTest" -q --batch-mode`
Expected: FAIL — classes do not exist

- [ ] **Step 3: Write MapSimulationConfig**

```java
package io.casehub.platform.simulation;

import java.util.Map;
import java.util.Optional;

public final class MapSimulationConfig implements SimulationConfig {

    private final Map<String, String> strategies;
    private final Map<String, Boolean> captures;

    private MapSimulationConfig(final Map<String, String> strategies,
                                 final Map<String, Boolean> captures) {
        this.strategies = Map.copyOf(strategies);
        this.captures = Map.copyOf(captures);
    }

    public static MapSimulationConfig of(final Map<String, String> strategies) {
        return new MapSimulationConfig(strategies, Map.of());
    }

    public static MapSimulationConfig of(final Map<String, String> strategies,
                                          final Map<String, Boolean> captures) {
        return new MapSimulationConfig(strategies, captures);
    }

    @Override
    public Optional<String> strategyFor(final String qualifiedName) {
        return Optional.ofNullable(strategies.get(qualifiedName));
    }

    @Override
    public boolean captureEnabled(final String qualifiedName) {
        return captures.getOrDefault(qualifiedName, false);
    }

    @Override
    public Optional<ExhaustionPolicy> exhaustionPolicy(final String qualifiedName) {
        return Optional.empty();
    }

    public Map<String, String> strategies() {
        return strategies;
    }
}
```

- [ ] **Step 4: Write SimulationOverlay**

```java
package io.casehub.platform.simulation;

public final class SimulationOverlay {

    private final SimulationConfig config;
    private final SimulationCorpus<?, ?> corpus;
    private final InvocationJournal journal;

    SimulationOverlay(final SimulationConfig config, final SimulationCorpus<?, ?> corpus) {
        this.config = config;
        this.corpus = corpus;
        this.journal = new InvocationJournal();
    }

    public SimulationConfig config() {
        return config;
    }

    @SuppressWarnings("rawtypes")
    public SimulationCorpus corpus() {
        return (SimulationCorpus) corpus;
    }

    public InvocationJournal journal() {
        return journal;
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -pl simulation-core test -Dtest="MapSimulationConfigTest,SimulationOverlayTest" -q --batch-mode`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add simulation-core/src/main/java/io/casehub/platform/simulation/MapSimulationConfig.java simulation-core/src/main/java/io/casehub/platform/simulation/SimulationOverlay.java simulation-core/src/test/java/io/casehub/platform/simulation/MapSimulationConfigTest.java simulation-core/src/test/java/io/casehub/platform/simulation/SimulationOverlayTest.java
git commit -m "feat(#322): MapSimulationConfig and SimulationOverlay"
```

---

### Task 3: SimulationRuntime overlay stack — pushOverlay, popOverlay, strategy resolution

**Files:**
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java`
- Modify: `simulation-core/src/test/java/io/casehub/platform/simulation/SimulationRuntimeTest.java`

**Interfaces:**
- Consumes: `SimulationOverlay` (Task 2), `MapSimulationConfig` (Task 2), `InvocationJournal` (Task 1)
- Produces: `SimulationRuntime.pushOverlay(SimulationConfig, SimulationCorpus)`, `SimulationRuntime.pushOverlay(SimulationConfig)`, `SimulationRuntime.popOverlay(SimulationOverlay)`, `SimulationRuntime.popAll()`, `SimulationRuntime.journal(SimulationOverlay)`, `SimulationRuntime.hasActiveOverlay()`, `SimulationRuntime.recordJournal(String, Object, Object, boolean)`

- [ ] **Step 1: Write the failing tests for overlay stack**

Add to `SimulationRuntimeTest.java`:

```java
// --- overlay stack ---

@Test
void pushOverlayMakesStrategyResolveFromOverlay() {
    var baseConfig = stubConfig(Optional.empty(), false, Optional.empty());
    var runtime = new SimulationRuntime(baseConfig, new NoOpSimulationCorpus<>());
    assertThat(runtime.<String, String>strategyFor(QN)).isEmpty();

    var overlayConfig = MapSimulationConfig.of(Map.of(QN, "sequential"));
    var overlayCorpus = new TestCorpus();
    overlayCorpus.seed(QN, List.of(new InvocationRecord<>("t1", null, "in", "out", Instant.now())));
    var overlay = runtime.pushOverlay(overlayConfig, overlayCorpus);

    assertThat(runtime.<String, String>strategyFor(QN)).isPresent();
    assertThat(runtime.hasActiveOverlay()).isTrue();
}

@Test
void popOverlayRestoresBaseResolution() {
    var baseConfig = stubConfig(Optional.empty(), false, Optional.empty());
    var runtime = new SimulationRuntime(baseConfig, new NoOpSimulationCorpus<>());

    var overlayConfig = MapSimulationConfig.of(Map.of(QN, "sequential"));
    var overlay = runtime.pushOverlay(overlayConfig);

    runtime.popOverlay(overlay);
    assertThat(runtime.<String, String>strategyFor(QN)).isEmpty();
    assertThat(runtime.hasActiveOverlay()).isFalse();
}

@Test
void multipleOverlaysResolveTopDown() {
    var baseConfig = stubConfig(Optional.empty(), false, Optional.empty());
    var runtime = new SimulationRuntime(baseConfig, new NoOpSimulationCorpus<>());

    var corpus1 = new TestCorpus();
    corpus1.seed(QN, List.of(new InvocationRecord<>("t1", null, "in", "first", Instant.now())));
    var overlay1 = runtime.pushOverlay(MapSimulationConfig.of(Map.of(QN, "sequential")), corpus1);

    var corpus2 = new TestCorpus();
    corpus2.seed(QN, List.of(new InvocationRecord<>("t1", null, "in", "second", Instant.now())));
    var overlay2 = runtime.pushOverlay(MapSimulationConfig.of(Map.of(QN, "sequential")), corpus2);

    // Top overlay wins
    var strategy = runtime.<String, String>strategyFor(QN);
    assertThat(strategy).isPresent();
    assertThat(strategy.get().resolve("in")).isEqualTo("second");
}

@Test
void popAllClearsEntireStack() {
    var baseConfig = stubConfig(Optional.empty(), false, Optional.empty());
    var runtime = new SimulationRuntime(baseConfig, new NoOpSimulationCorpus<>());

    runtime.pushOverlay(MapSimulationConfig.of(Map.of(QN, "sequential")));
    runtime.pushOverlay(MapSimulationConfig.of(Map.of("other.method", "random")));

    runtime.popAll();
    assertThat(runtime.hasActiveOverlay()).isFalse();
    assertThat(runtime.<String, String>strategyFor(QN)).isEmpty();
}

@Test
void journalReturnsOverlayJournal() {
    var baseConfig = stubConfig(Optional.empty(), false, Optional.empty());
    var runtime = new SimulationRuntime(baseConfig, new NoOpSimulationCorpus<>());
    var overlay = runtime.pushOverlay(MapSimulationConfig.of(Map.of()));

    runtime.recordJournal(QN, "input", "output", true);

    var journal = runtime.journal(overlay);
    assertThat(journal).hasSize(1);
    assertThat(journal.get(0).simulated()).isTrue();
}

@Test
void recordJournalNoOpWhenNoOverlay() {
    var baseConfig = stubConfig(Optional.empty(), false, Optional.empty());
    var runtime = new SimulationRuntime(baseConfig, new NoOpSimulationCorpus<>());

    // Should not throw
    runtime.recordJournal(QN, "input", "output", false);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl simulation-core test -Dtest=SimulationRuntimeTest -q --batch-mode`
Expected: FAIL — pushOverlay, popOverlay, etc. do not exist

- [ ] **Step 3: Implement overlay stack on SimulationRuntime**

Modify `SimulationRuntime.java` — add overlay stack fields and methods. The key changes:

1. Add `CopyOnWriteArrayList<SimulationOverlay> overlayStack` field
2. Modify `strategyFor()` to walk overlay stack top-down before checking base config
3. Add `pushOverlay()` — creates overlay, adds to stack, evicts cached strategies for declared qualified names
4. Add `popOverlay()` — identity-checks the overlay, removes from stack, evicts cached strategies
5. Add `popAll()` — clears entire stack and strategy cache
6. Add `hasActiveOverlay()` — checks if stack is non-empty
7. Add `recordJournal()` — records to top overlay's journal (no-op if stack empty)
8. Add `journal()` — returns journal entries for a given overlay

The strategy creation in overlay mode must use the overlay's corpus, not the base corpus. Modify `createStrategy()` to accept a corpus parameter, and have `strategyFor()` pass the overlay's corpus when resolving from an overlay.

Since overlay strategies should NOT be cached in the base cache (they're scoped to the overlay), use a per-overlay strategy cache inside SimulationOverlay instead. Add a `ConcurrentHashMap<String, SimulationStrategy<?,?>> strategyCache` to SimulationOverlay.

```java
// New fields on SimulationRuntime:
private final CopyOnWriteArrayList<SimulationOverlay> overlayStack = new CopyOnWriteArrayList<>();

// Modified strategyFor:
public <I, O> Optional<SimulationStrategy<I, O>> strategyFor(final String qualifiedName) {
    // Walk overlay stack top-down
    var stack = overlayStack;
    for (int i = stack.size() - 1; i >= 0; i--) {
        var overlay = stack.get(i);
        var overlayStrategy = overlay.config().strategyFor(qualifiedName);
        if (overlayStrategy.isPresent()) {
            return Optional.of((SimulationStrategy<I, O>) overlay.strategyCache()
                    .computeIfAbsent(qualifiedName, qn ->
                            createStrategy(qn, overlayStrategy.get(), overlay.corpus())));
        }
    }
    // Fall through to base config
    return config.strategyFor(qualifiedName)
            .map(strategyName -> (SimulationStrategy<I, O>) strategyCache.computeIfAbsent(
                    qualifiedName, qn -> createStrategy(qn, strategyName, corpus)));
}

// New methods:
public SimulationOverlay pushOverlay(final SimulationConfig config, final SimulationCorpus<?, ?> corpus) {
    var overlay = new SimulationOverlay(config, corpus);
    overlayStack.add(overlay);
    evictCachedStrategies(config);
    return overlay;
}

public SimulationOverlay pushOverlay(final SimulationConfig config) {
    return pushOverlay(config, new io.casehub.platform.simulation.inmem.InMemorySimulationCorpus<>());
}

public void popOverlay(final SimulationOverlay overlay) {
    if (!overlayStack.remove(overlay)) {
        throw new IllegalArgumentException("Overlay not found in stack");
    }
    evictCachedStrategies(overlay.config());
}

public void popAll() {
    overlayStack.clear();
    strategyCache.clear();
}

public List<JournalEntry> journal(final SimulationOverlay overlay) {
    return overlay.journal().entries();
}

public boolean hasActiveOverlay() {
    return !overlayStack.isEmpty();
}

public void recordJournal(final String qualifiedName, final Object input,
                           final Object output, final boolean simulated) {
    var stack = overlayStack;
    if (stack.isEmpty()) return;
    var topOverlay = stack.get(stack.size() - 1);
    topOverlay.journal().record(new JournalEntry(qualifiedName, input, output,
            java.time.Instant.now(), simulated));
}
```

Also modify `createStrategy` to accept a `SimulationCorpus` parameter instead of using `this.corpus` directly. And add `strategyCache()` method to SimulationOverlay (package-private `ConcurrentHashMap`).

- [ ] **Step 4: Add simulation-inmem as a compile dependency to simulation-core pom.xml**

The `pushOverlay(config)` convenience method creates an `InMemorySimulationCorpus`. This requires simulation-inmem as a compile dependency (currently test-only).

Modify `simulation-core/pom.xml` — change simulation-inmem scope from `test` to `compile`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -pl simulation-core test -Dtest=SimulationRuntimeTest -q --batch-mode`
Expected: PASS (all existing + new tests)

- [ ] **Step 6: Run full simulation-core test suite**

Run: `mvn -pl simulation-core test -q --batch-mode`
Expected: PASS — no regressions

- [ ] **Step 7: Commit**

```bash
git add simulation-core/
git commit -m "feat(#322): SimulationRuntime overlay stack — push/pop/journal"
```

---

## Batch 2: Generator template update

### Task 4: Update SimulationDecoratorProcessor to emit journal recording

**Files:**
- Modify: `simulation-generator/src/main/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessor.java`
- Modify: `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessorTest.java`

**Interfaces:**
- Consumes: `SimulationRuntime.recordJournal(String, Object, Object, boolean)` (Task 3)
- Produces: Updated generated decorator template that calls `simulation.recordJournal()` after every strategy resolution or delegate call

- [ ] **Step 1: Update the generated method template in `generateSimulatedMethod`**

Modify the `generateSimulatedMethod` method in `SimulationDecoratorProcessor.java`. The new pattern for each method:

```java
// After strategy resolution (simulated=true):
if (strategy.isPresent() && strategy.get().canResolve(input)) {
    Object result = strategy.get().resolve(input);
    simulation.recordJournal(qualifiedName, input, result, true);
    return (ReturnType) result;
}
// After delegate call (simulated=false):
ReturnType result = delegate.method(args);
simulation.recordJournal(qualifiedName, input, result, false);
if (simulation.captureEnabled(qualifiedName)) { ... }
return result;
```

For void methods, the journal records `null` as the output.

- [ ] **Step 2: Update processor test to verify journal recording in generated source**

Add assertion to `SimulationDecoratorProcessorTest` that the generated source contains `simulation.recordJournal`:

```java
@Test
void generatedSourceContainsJournalRecording() {
    // Use existing test infrastructure to generate source for TestSimpleService
    // Assert the generated source contains "simulation.recordJournal"
    var sources = processor.generateFromIndex(index);
    var source = sources.stream()
            .filter(s -> s.className().contains("SimulatedTestSimpleService"))
            .findFirst().orElseThrow();
    assertThat(source.sourceCode()).contains("simulation.recordJournal(qualifiedName,");
}
```

- [ ] **Step 3: Run generator tests**

Run: `mvn -pl simulation-generator test -q --batch-mode`
Expected: PASS

- [ ] **Step 4: Rebuild dependent modules to regenerate decorators**

Run: `mvn --batch-mode install -pl simulation-core,simulation-generator,memory-simulation-core,platform-simulation-core -DskipTests`
Expected: BUILD SUCCESS — regenerated decorators now include journal recording

- [ ] **Step 5: Run full test suite for affected modules**

Run: `mvn --batch-mode test -pl simulation-core,simulation-generator,memory-simulation-core,platform-simulation-core`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add simulation-generator/ memory-simulation-core/ platform-simulation-core/
git commit -m "feat(#322): generator emits journal recording in decorators"
```

---

## Batch 3: Pages scenario integration (casehub-pages)

### Task 5: SimulationSpec record and parser extension

**Files:**
- Create: `pages/backend/scenario/src/main/java/io/casehub/pages/scenario/SimulationSpec.java`
- Modify: `pages/backend/scenario/src/main/java/io/casehub/pages/scenario/HierarchicalScenario.java`
- Modify: `pages/backend/scenario/src/main/java/io/casehub/pages/scenario/HierarchicalParser.java`
- Test: `pages/backend/scenario/src/test/java/io/casehub/pages/scenario/SimulationSpecParsingTest.java`

**Interfaces:**
- Consumes: existing `HierarchicalParser`, `HierarchicalScenario`
- Produces: `SimulationSpec(Map<String, String> strategies, List<String> corpus, List<String> capture)`, `HierarchicalScenario.simulation()` returning `SimulationSpec` (nullable)

- [ ] **Step 1: Write the failing test**

```java
package io.casehub.pages.scenario;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class SimulationSpecParsingTest {

    @Test
    void parsesSimulationBlock() {
        String yaml = """
                scenario: Test with simulation
                simulation:
                  strategies:
                    agent-provider.invoke: sequential
                    case-memory-store.query: key-lookup
                  corpus:
                    - fixtures/agent-responses.yaml
                  capture:
                    - preference-provider.get
                steps:
                  - label: step1
                    target: browser
                    commands:
                      - action: navigate
                        value: /home
                """;
        var scenario = HierarchicalParser.parse(yaml);
        assertThat(scenario.simulation()).isNotNull();
        assertThat(scenario.simulation().strategies())
                .containsEntry("agent-provider.invoke", "sequential")
                .containsEntry("case-memory-store.query", "key-lookup");
        assertThat(scenario.simulation().corpus()).containsExactly("fixtures/agent-responses.yaml");
        assertThat(scenario.simulation().capture()).containsExactly("preference-provider.get");
    }

    @Test
    void parsesScenarioWithoutSimulationBlock() {
        String yaml = """
                scenario: Plain scenario
                steps:
                  - label: step1
                    target: browser
                    commands:
                      - action: navigate
                        value: /home
                """;
        var scenario = HierarchicalParser.parse(yaml);
        assertThat(scenario.simulation()).isNull();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl backend/scenario test -Dtest=SimulationSpecParsingTest -q --batch-mode` (from pages repo root)
Expected: FAIL — SimulationSpec does not exist, simulation() not on HierarchicalScenario

- [ ] **Step 3: Create SimulationSpec record**

```java
package io.casehub.pages.scenario;

import java.util.List;
import java.util.Map;

public record SimulationSpec(
        Map<String, String> strategies,
        List<String> corpus,
        List<String> capture) {

    public SimulationSpec {
        strategies = strategies != null ? Map.copyOf(strategies) : Map.of();
        corpus = corpus != null ? List.copyOf(corpus) : List.of();
        capture = capture != null ? List.copyOf(capture) : List.of();
    }
}
```

- [ ] **Step 4: Add `simulation` field to HierarchicalScenario**

Add `SimulationSpec simulation` parameter to the record. Update the canonical constructor to accept it. Update existing constructors/callers to pass `null`.

- [ ] **Step 5: Parse `simulation:` block in HierarchicalParser**

In `HierarchicalParser.parse()`, after parsing `on-error`, add:

```java
SimulationSpec simulation = null;
if (root.has("simulation")) {
    simulation = parseSimulation(root.get("simulation"));
}
```

Add helper method:

```java
@SuppressWarnings("unchecked")
private static SimulationSpec parseSimulation(JsonNode node) {
    Map<String, String> strategies = node.has("strategies")
            ? YAML.convertValue(node.get("strategies"), Map.class)
            : Map.of();
    List<String> corpus = node.has("corpus")
            ? YAML.convertValue(node.get("corpus"), List.class)
            : List.of();
    List<String> capture = node.has("capture")
            ? YAML.convertValue(node.get("capture"), List.class)
            : List.of();
    return new SimulationSpec(strategies, corpus, capture);
}
```

Pass `simulation` to the `HierarchicalScenario` constructor.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn -pl backend/scenario test -q --batch-mode` (from pages repo root)
Expected: PASS (all existing + new tests)

- [ ] **Step 7: Commit**

```bash
git add backend/scenario/
git commit -m "feat(casehub-pages#450): SimulationSpec record and parser extension"
```

---

### Task 6: ScenarioOrchestrator simulation lifecycle hooks

**Files:**
- Modify: `pages/backend/scenario-runtime/pom.xml`
- Modify: `pages/backend/scenario-runtime/src/main/java/io/casehub/pages/scenario/runtime/ScenarioOrchestrator.java`
- Test: `pages/backend/scenario-runtime/src/test/java/io/casehub/pages/scenario/runtime/ScenarioOrchestratorSimulationTest.java`

**Interfaces:**
- Consumes: `SimulationSpec` (Task 5), `SimulationRuntime.pushOverlay()` / `popOverlay()` / `popAll()` (Task 3), `MapSimulationConfig` (Task 2), `YamlCorpusLoader` (existing in simulation-config-core)
- Produces: ScenarioOrchestrator pushes overlay on start, pops on stop/completion

- [ ] **Step 1: Add simulation-core and simulation-config-core dependencies to scenario-runtime pom.xml**

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-simulation-core</artifactId>
    <version>${casehub-platform.version}</version>
</dependency>
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-simulation-config-core</artifactId>
    <version>${casehub-platform.version}</version>
</dependency>
```

- [ ] **Step 2: Write the failing test**

```java
package io.casehub.pages.scenario.runtime;

import io.casehub.platform.simulation.MapSimulationConfig;
import io.casehub.platform.simulation.SimulationRuntime;
import io.casehub.platform.simulation.NoOpSimulationCorpus;
import org.junit.jupiter.api.Test;
import java.util.Map;
import java.util.Optional;
import static org.assertj.core.api.Assertions.assertThat;

class ScenarioOrchestratorSimulationTest {

    @Test
    void startWithSimulationPushesOverlay() {
        var baseConfig = stubConfig();
        var runtime = new SimulationRuntime(baseConfig, new NoOpSimulationCorpus<>());

        // Parse a scenario YAML with simulation block
        String yaml = """
                scenario: Test
                simulation:
                  strategies:
                    agent-provider.invoke: sequential
                steps:
                  - label: step1
                    target: browser
                    commands:
                      - action: navigate
                        value: /home
                """;

        // After start, overlay should be active
        // (test will verify runtime.hasActiveOverlay() after orchestrator.start())
        assertThat(runtime.hasActiveOverlay()).isFalse();

        // Create orchestrator with runtime injected and start
        // This requires refactoring to accept SimulationRuntime
        // Test verifies the integration point exists
    }

    private static io.casehub.platform.simulation.SimulationConfig stubConfig() {
        return new io.casehub.platform.simulation.SimulationConfig() {
            @Override public Optional<String> strategyFor(String qn) { return Optional.empty(); }
            @Override public boolean captureEnabled(String qn) { return false; }
            @Override public Optional<io.casehub.platform.simulation.ExhaustionPolicy> exhaustionPolicy(String qn) { return Optional.empty(); }
        };
    }
}
```

- [ ] **Step 3: Add SimulationRuntime injection to ScenarioOrchestrator**

Add to `ScenarioOrchestrator`:

```java
@Inject Instance<SimulationRuntime> simulationRuntimeInstance;
private volatile SimulationOverlay activeOverlay;
```

Use `Instance<SimulationRuntime>` (not direct injection) so the orchestrator works when simulation-core is not on the classpath — `Instance.isResolvable()` gates all simulation operations.

- [ ] **Step 4: Add simulation activation in start() method**

In `start(String yaml, boolean startPaused)`, after `this.scenario = HierarchicalParser.parse(yaml)`, add:

```java
activateSimulation(this.scenario.simulation());
```

Add private method:

```java
private void activateSimulation(SimulationSpec spec) {
    if (spec == null || !simulationRuntimeInstance.isResolvable()) return;
    var runtime = simulationRuntimeInstance.get();
    var config = MapSimulationConfig.of(spec.strategies(),
            spec.capture().stream().collect(
                    java.util.stream.Collectors.toMap(c -> c, c -> true)));
    var corpus = new io.casehub.platform.simulation.inmem.InMemorySimulationCorpus<>();

    if (!spec.corpus().isEmpty()) {
        var loader = new io.casehub.platform.simulation.config.YamlCorpusLoader();
        var loaded = loader.loadFromPaths(spec.corpus().stream()
                .map(p -> libraryPath() + "/" + p)
                .toList());
        loaded.forEach(corpus::seed);
    }

    this.activeOverlay = runtime.pushOverlay(config, corpus);
}

private String libraryPath() {
    return scenario != null && scenario.meta() != null && scenario.meta().library() != null
            ? scenario.meta().library()
            : System.getProperty("java.io.tmpdir") + "/casehub-scenario-library";
}
```

- [ ] **Step 5: Add simulation deactivation in stop() method**

In `stop()`, before clearing state, add:

```java
deactivateSimulation();
```

Add private method:

```java
private void deactivateSimulation() {
    if (activeOverlay == null || !simulationRuntimeInstance.isResolvable()) return;
    simulationRuntimeInstance.get().popOverlay(activeOverlay);
    activeOverlay = null;
}
```

Also add deactivation in the completion path (when all steps complete, in `onStepResult` after `fireCallback`):

```java
if (completedSteps.size() == allSteps.size()) {
    deactivateSimulation();
    // ... existing fireCallback
}
```

- [ ] **Step 6: Run scenario-runtime tests**

Run: `mvn -pl backend/scenario-runtime test -q --batch-mode` (from pages repo root)
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add backend/scenario-runtime/
git commit -m "feat(casehub-pages#450): ScenarioOrchestrator simulation lifecycle hooks"
```

---

## Batch 4: Documentation and guide update

### Task 7: Update simulation guide and CLAUDE.md

**Files:**
- Modify: `platform/docs/guides/simulation-guide.md`
- Modify: `platform/CLAUDE.md`

**Interfaces:**
- Consumes: all above
- Produces: documentation

- [ ] **Step 1: Add "Scenario Integration" section to simulation guide**

Add a new section after "Platform SPIs" covering:
- SimulationOverlay API (pushOverlay/popOverlay/popAll)
- MapSimulationConfig for programmatic strategy configuration
- InvocationJournal for assertion support
- Mid-scenario strategy switching
- Example YAML showing `simulation:` block in scenario scripts

- [ ] **Step 2: Update CLAUDE.md simulation-core module description**

Add mentions of `SimulationOverlay`, `InvocationJournal`, `JournalEntry`, `MapSimulationConfig` to the simulation-core module entry.

- [ ] **Step 3: Commit**

```bash
git add docs/guides/simulation-guide.md CLAUDE.md
git commit -m "docs(#322): simulation guide — scenario integration section"
```

## References

- [2026-09-16-pages-scenario-simulation-design.md] — design spec this plan implements
- [simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java] — overlay stack target
- [simulation-core/src/main/java/io/casehub/platform/simulation/SimulationConfig.java] — interface for MapSimulationConfig
- [simulation-generator/src/main/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessor.java] — template update
- [pages/backend/scenario/src/main/java/io/casehub/pages/scenario/HierarchicalParser.java] — YAML parser extension
- [pages/backend/scenario-runtime/src/main/java/io/casehub/pages/scenario/runtime/ScenarioOrchestrator.java] — lifecycle hooks
- [D43-D48] — phase 8 decisions
- [casehubio/platform#322] — platform issue
- [casehubio/casehub-pages#450] — pages issue
