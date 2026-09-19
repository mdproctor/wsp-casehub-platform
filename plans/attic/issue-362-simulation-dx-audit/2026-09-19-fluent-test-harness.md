# Simulation.forTest() Fluent Test Harness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #353 — `Simulation.forTest()` fluent test harness
**Issue group:** #352 (epic: simulation DX)

**Goal:** Reduce simulation test setup from 6+ lines to 2-3 lines via a
fluent `Simulation.forTest()` builder API.

**Architecture:** A single new class `Simulation` with a nested `Builder`
in `simulation-core`. The builder accumulates stub/seed entries with
implicit strategy selection, builds an `InMemorySimulationCorpus` +
`MapSimulationConfig` + `SimulationRuntime` internally. The `Simulation`
result wraps runtime + config + corpus and exposes `resolve()`, `overlay()`,
`verifier()`, and `runtime()` escape hatch.

**Tech Stack:** Pure Java, no CDI. Uses existing simulation-core types
(`SimulationRuntime`, `MapSimulationConfig`, `SimulationOverlay`,
`SimulationVerifier`, `InMemorySimulationCorpus`).

## Global Constraints

- Module: `simulation-core` only — no new modules
- Package: `io.casehub.platform.simulation`
- No CDI annotations — POJO only
- No new dependencies — all types already on simulation-core classpath
- `platform-api/` must remain zero-dependency (not touched)

---

## Batch 1: Simulation class and builder

### Task 1: Simulation.Builder — stub/seed/build with implicit strategy

**Files:**
- Create: `simulation-core/src/main/java/io/casehub/platform/simulation/Simulation.java`
- Test: `simulation-core/src/test/java/io/casehub/platform/simulation/SimulationTest.java`

**Interfaces:**
- Consumes: `SimulationRuntime(SimulationConfig, SimulationCorpus)`, `MapSimulationConfig.of(Map)`, `InMemorySimulationCorpus()`, `InvocationRecord.of(String, String, Object, Object)`, `SimulationConfigException(String)`, `KeyExtractor<I>`
- Produces:
  - `Simulation.forTest()` → `Simulation.Builder`
  - `Simulation.forTest(String defaultTenancyId)` → `Simulation.Builder`
  - `Builder.stub(String qualifiedName, I input, O output)` → `Builder`
  - `Builder.stub(String qualifiedName, String key, I input, O output)` → `Builder`
  - `Builder.seed(String qualifiedName, I input, O output)` → `Builder`
  - `Builder.keyExtractor(String qualifiedName, KeyExtractor<I>)` → `Builder`
  - `Builder.strategy(String qualifiedName, String strategyName)` → `Builder`
  - `Builder.build()` → `Simulation`
  - `Simulation.resolve(String qualifiedName, I input)` → `O`
  - `Simulation.runtime()` → `SimulationRuntime`

- [ ] **Step 1: Write failing test — stub with key-lookup**

Create test file `simulation-core/src/test/java/io/casehub/platform/simulation/SimulationTest.java`:

```java
package io.casehub.platform.simulation;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class SimulationTest {

    @Test
    void stubImpliesKeyLookupStrategy() {
        var sim = Simulation.forTest()
                .stub("greeting.greet", "Alice", "Hello Alice!")
                .stub("greeting.greet", "Bob", "Hello Bob!")
                .build();

        assertThat(sim.<String, String>resolve("greeting.greet", "Alice"))
                .isEqualTo("Hello Alice!");
        assertThat(sim.<String, String>resolve("greeting.greet", "Bob"))
                .isEqualTo("Hello Bob!");
        // Deterministic — same input always returns same output
        assertThat(sim.<String, String>resolve("greeting.greet", "Alice"))
                .isEqualTo("Hello Alice!");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=SimulationTest#stubImpliesKeyLookupStrategy -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation failure — `Simulation` class does not exist.

- [ ] **Step 3: Implement Simulation class with Builder**

Create `simulation-core/src/main/java/io/casehub/platform/simulation/Simulation.java`:

```java
package io.casehub.platform.simulation;

import io.casehub.platform.simulation.inmem.InMemorySimulationCorpus;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

public final class Simulation {

    private final SimulationRuntime runtime;
    private final SimulationConfig config;
    private final SimulationCorpus<?, ?> corpus;
    private SimulationOverlay currentOverlay;

    Simulation(SimulationRuntime runtime, SimulationConfig config,
               SimulationCorpus<?, ?> corpus) {
        this.runtime = runtime;
        this.config = config;
        this.corpus = corpus;
    }

    public static Builder forTest() {
        return new Builder("test");
    }

    public static Builder forTest(String defaultTenancyId) {
        return new Builder(defaultTenancyId);
    }

    @SuppressWarnings("unchecked")
    public <I, O> O resolve(String qualifiedName, I input) {
        SimulationStrategy<I, O> strategy = runtime
                .<I, O>strategyFor(qualifiedName)
                .orElseThrow(() -> new SimulationConfigException(
                        "No strategy configured for '" + qualifiedName + "'"));
        return strategy.resolve(input);
    }

    public SimulationRuntime runtime() {
        return runtime;
    }

    @SuppressWarnings({"rawtypes", "unchecked"})
    public static final class Builder {

        private final String defaultTenancyId;
        private final Map<String, String> strategies = new LinkedHashMap<>();
        private final Map<String, List<InvocationRecord>> records = new LinkedHashMap<>();
        private final Map<String, KeyExtractor<?>> extractors = new LinkedHashMap<>();

        Builder(String defaultTenancyId) {
            this.defaultTenancyId = defaultTenancyId;
        }

        public <I, O> Builder stub(String qualifiedName, I input, O output) {
            String key = String.valueOf(input);
            addRecord(qualifiedName, key, input, output);
            mergeStrategy(qualifiedName, "key-lookup");
            extractors.putIfAbsent(qualifiedName,
                    (KeyExtractor<Object>) i -> String.valueOf(i));
            return this;
        }

        public <I, O> Builder stub(String qualifiedName,
                                    String key, I input, O output) {
            addRecord(qualifiedName, key, input, output);
            mergeStrategy(qualifiedName, "key-lookup");
            return this;
        }

        public <I, O> Builder seed(String qualifiedName, I input, O output) {
            addRecord(qualifiedName, null, input, output);
            mergeStrategy(qualifiedName, "sequential");
            return this;
        }

        public <I> Builder keyExtractor(String qualifiedName,
                                         KeyExtractor<I> extractor) {
            extractors.put(qualifiedName, extractor);
            return this;
        }

        public Builder strategy(String qualifiedName, String strategyName) {
            strategies.put(qualifiedName, strategyName);
            return this;
        }

        public Simulation build() {
            var corpus = new InMemorySimulationCorpus();
            records.forEach(corpus::seed);

            var config = MapSimulationConfig.of(strategies);
            var runtime = new SimulationRuntime(config, corpus);
            extractors.forEach(runtime::registerExtractor);

            return new Simulation(runtime, config, corpus);
        }

        private void addRecord(String qualifiedName, String key,
                                Object input, Object output) {
            records.computeIfAbsent(qualifiedName, k -> new ArrayList<>())
                    .add(InvocationRecord.of(defaultTenancyId, key,
                            input, output));
        }

        private void mergeStrategy(String qualifiedName, String strategyName) {
            strategies.merge(qualifiedName, strategyName, (existing, incoming) -> {
                if (!existing.equals(incoming)) {
                    throw new SimulationConfigException(
                            "Ambiguous strategy for '" + qualifiedName + "': "
                            + "stub() implies key-lookup but seed() implies sequential. "
                            + "Use one or the other, or call .strategy() explicitly.");
                }
                return existing;
            });
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=SimulationTest#stubImpliesKeyLookupStrategy`
Expected: PASS

- [ ] **Step 5: Add remaining builder tests**

Append to `SimulationTest.java`:

```java
    @Test
    void seedImpliesSequentialStrategy() {
        var sim = Simulation.forTest()
                .seed("greeting.greet", "Alice", "Hello Alice!")
                .seed("greeting.greet", "Bob", "Hello Bob!")
                .build();

        assertThat(sim.<String, String>resolve("greeting.greet", "anyone"))
                .isEqualTo("Hello Alice!");
        assertThat(sim.<String, String>resolve("greeting.greet", "anyone"))
                .isEqualTo("Hello Bob!");
        // Wraps around
        assertThat(sim.<String, String>resolve("greeting.greet", "anyone"))
                .isEqualTo("Hello Alice!");
    }

    @Test
    void stubWithExplicitKeyAndExtractor() {
        var sim = Simulation.forTest()
                .stub("greeting.greet", "alice", "Alice", "Hello Alice!")
                .stub("greeting.greet", "bob", "Bob", "Hello Bob!")
                .keyExtractor("greeting.greet",
                        (String name) -> name.toLowerCase())
                .build();

        assertThat(sim.<String, String>resolve("greeting.greet", "ALICE"))
                .isEqualTo("Hello Alice!");
        assertThat(sim.<String, String>resolve("greeting.greet", "Bob"))
                .isEqualTo("Hello Bob!");
    }

    @Test
    void forTestDefaultTenancyId() {
        var sim = Simulation.forTest()
                .seed("spi.method", "in", "out")
                .build();

        var records = sim.runtime()
                .<String, String>strategyFor("spi.method")
                .orElseThrow();
        // Resolves — proves runtime is wired
        assertThat(sim.<String, String>resolve("spi.method", "in"))
                .isEqualTo("out");
    }

    @Test
    void forTestCustomTenancyId() {
        var sim = Simulation.forTest("hospital-a")
                .seed("spi.method", "in", "out")
                .build();

        assertThat(sim.<String, String>resolve("spi.method", "in"))
                .isEqualTo("out");
    }

    @Test
    void mixedStubAndSeedOnSameQnThrows() {
        var builder = Simulation.forTest()
                .stub("spi.method", "key-in", "key-out");

        org.assertj.core.api.Assertions.assertThatThrownBy(() ->
                        builder.seed("spi.method", "seq-in", "seq-out"))
                .isInstanceOf(SimulationConfigException.class)
                .hasMessageContaining("Ambiguous strategy");
    }

    @Test
    void strategyExplicitOverride() {
        var sim = Simulation.forTest()
                .seed("spi.method", "a", "out-a")
                .seed("spi.method", "b", "out-b")
                .strategy("spi.method", "random")
                .build();

        String result = sim.<String, String>resolve("spi.method", "any");
        assertThat(result).isIn("out-a", "out-b");
    }

    @Test
    void multiMethodSimulation() {
        var sim = Simulation.forTest()
                .stub("spi.query", "patient-1", "result-1")
                .seed("spi.store", "input-a", "stored-a")
                .build();

        assertThat(sim.<String, String>resolve("spi.query", "patient-1"))
                .isEqualTo("result-1");
        assertThat(sim.<String, String>resolve("spi.store", "anything"))
                .isEqualTo("stored-a");
    }

    @Test
    void runtimeEscapeHatch() {
        var sim = Simulation.forTest()
                .seed("spi.method", "in", "out")
                .build();

        assertThat(sim.runtime()).isNotNull();
        assertThat(sim.runtime().strategyFor("spi.method")).isPresent();
    }

    @Test
    void resolveWithNoStrategyThrows() {
        var sim = Simulation.forTest()
                .seed("spi.method", "in", "out")
                .build();

        org.assertj.core.api.Assertions.assertThatThrownBy(() ->
                        sim.resolve("nonexistent.method", "input"))
                .isInstanceOf(SimulationConfigException.class)
                .hasMessageContaining("No strategy configured");
    }
```

- [ ] **Step 6: Run all builder tests**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=SimulationTest`
Expected: all 8 tests PASS

- [ ] **Step 7: Commit**

```bash
git add simulation-core/src/main/java/io/casehub/platform/simulation/Simulation.java
git add simulation-core/src/test/java/io/casehub/platform/simulation/SimulationTest.java
git commit -m "feat(#353): Simulation.forTest() fluent builder — stub/seed/resolve

Refs #353

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: Simulation overlay and verifier integration

**Files:**
- Modify: `simulation-core/src/main/java/io/casehub/platform/simulation/Simulation.java`
- Modify: `simulation-core/src/test/java/io/casehub/platform/simulation/SimulationTest.java`

**Interfaces:**
- Consumes: `Simulation` from Task 1, `SimulationOverlay`, `SimulationVerifier.on(InvocationJournal)`, `SimulationRuntime.pushOverlay(SimulationConfig, SimulationCorpus)`, `SimulationRuntime.popOverlay(SimulationOverlay)`
- Produces:
  - `Simulation.overlay()` → `SimulationOverlay`
  - `Simulation.popOverlay(SimulationOverlay)` → `void`
  - `Simulation.verifier()` → `SimulationVerifier`

- [ ] **Step 1: Write failing test — overlay and verifier lifecycle**

Append to `SimulationTest.java`:

```java
    @Test
    void overlayAndVerifierLifecycle() {
        var sim = Simulation.forTest()
                .stub("spi.query", "patient-1", "result-1")
                .build();

        var overlay = sim.overlay();
        sim.resolve("spi.query", "patient-1");
        sim.resolve("spi.query", "patient-1");

        sim.verifier().method("spi.query").wasCalled(2);
        sim.popOverlay(overlay);
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=SimulationTest#overlayAndVerifierLifecycle`
Expected: compilation failure — `overlay()`, `verifier()`, `popOverlay()` don't exist yet.

- [ ] **Step 3: Add overlay and verifier methods to Simulation**

Add these methods to the `Simulation` class (after `runtime()`):

```java
    public SimulationOverlay overlay() {
        currentOverlay = runtime.pushOverlay(config, corpus);
        return currentOverlay;
    }

    public void popOverlay(SimulationOverlay overlay) {
        runtime.popOverlay(overlay);
        if (overlay == currentOverlay) {
            currentOverlay = null;
        }
    }

    public SimulationVerifier verifier() {
        if (currentOverlay == null) {
            throw new IllegalStateException(
                    "No active overlay — call overlay() first");
        }
        return SimulationVerifier.on(currentOverlay.journal());
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=SimulationTest#overlayAndVerifierLifecycle`
Expected: PASS

- [ ] **Step 5: Add remaining overlay/verifier tests**

Append to `SimulationTest.java`:

```java
    @Test
    void verifierWithoutOverlayThrows() {
        var sim = Simulation.forTest()
                .seed("spi.method", "in", "out")
                .build();

        org.assertj.core.api.Assertions.assertThatThrownBy(sim::verifier)
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("No active overlay");
    }

    @Test
    void popOverlayClearsCurrentOverlay() {
        var sim = Simulation.forTest()
                .seed("spi.method", "in", "out")
                .build();

        var overlay = sim.overlay();
        sim.popOverlay(overlay);

        org.assertj.core.api.Assertions.assertThatThrownBy(sim::verifier)
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("No active overlay");
    }

    @Test
    void overlayRecordsSimulatedCalls() {
        var sim = Simulation.forTest()
                .seed("spi.method", "in", "out")
                .build();

        var overlay = sim.overlay();
        sim.resolve("spi.method", "in");

        sim.verifier().method("spi.method").wasCalled(1);
        sim.verifier().method("spi.method").allSimulated();
        sim.popOverlay(overlay);
    }

    @Test
    void multiMethodVerification() {
        var sim = Simulation.forTest()
                .stub("acl.check", "admin", true)
                .seed("mem.store", "input", "stored")
                .build();

        var overlay = sim.overlay();
        sim.resolve("acl.check", "admin");
        sim.resolve("mem.store", "input");
        sim.resolve("mem.store", "input");

        sim.verifier().method("acl.check").wasCalled(1);
        sim.verifier().method("mem.store").wasCalled(2);
        sim.popOverlay(overlay);
    }
```

- [ ] **Step 6: Run all tests**

Run: `mvn --batch-mode test -pl simulation-core -Dtest=SimulationTest`
Expected: all 12 tests PASS

- [ ] **Step 7: Full module build**

Run: `mvn --batch-mode test -pl simulation-core`
Expected: all existing tests still pass (no regressions)

- [ ] **Step 8: Commit**

```bash
git add simulation-core/src/main/java/io/casehub/platform/simulation/Simulation.java
git add simulation-core/src/test/java/io/casehub/platform/simulation/SimulationTest.java
git commit -m "feat(#353): Simulation.overlay() and verifier() integration

Refs #353

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 9: Full project build verification**

Run: `mvn --batch-mode install -pl simulation-api,simulation-core,simulation-inmem,simulation-config-core,simulation-config,simulation-generator,simulation-testing`
Expected: BUILD SUCCESS — all simulation modules compile and pass tests.

## References

- [2026-09-19-fluent-test-harness-design.md] — design spec this plan implements
- SimulationRuntime.java — runtime wiring, strategy creation, overlay stack
- MapSimulationConfig.java — map-based SimulationConfig implementation
- SimulationVerifier.java — journal-based verification API
- SimulationOverlay.java — overlay wrapping config + corpus + journal
- InvocationRecord.java — record with `of()` static factories
- SimulationConfig.java — interface with strategyFor/captureEnabled/exhaustionPolicy
- SimulationConfigException.java — runtime exception in simulation-api
- SimulationGettingStartedTest.java — current ceremony baseline
- GitHub #353 — focal issue
- GitHub #352 — parent epic
- D1-D6 in decisions.md — all design choices
