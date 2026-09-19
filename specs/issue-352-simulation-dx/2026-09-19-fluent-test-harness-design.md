# Simulation.forTest() Fluent Test Harness — Design Spec

**Issue:** casehubio/platform#353
**Branch:** issue-352-simulation-dx
**Date:** 2026-09-19

---

## Problem

Setting up a simulation test requires assembling 3-4 objects (corpus,
config, runtime, extractors) with 6+ lines of boilerplate. The
`SimulationConfig` interface alone requires a 14-line anonymous class
for a single method. `InvocationRecord` construction needs tenant, key,
input, output, and timestamp on every entry.

The framework is feature-complete but the test entry point is too
ceremonious for the 80% case: seed some data, resolve, optionally verify.

## Scope

**In scope:**
- `Simulation` class — built result wrapping runtime + corpus
- `Simulation.Builder` — fluent builder returned by `forTest()`
- `stub()` / `seed()` data entry with implicit strategy selection
- Integrated overlay and verifier access
- Default tenancyId (`"test"`)

**Out of scope:**
- CDI integration (this is POJO only, in simulation-core)
- CorpusSeed integration (existing CorpusSeed works alongside)
- Capture mode (harness is for test setup, not traffic recording)
- YAML config binding (that's simulation-config's job)

## Design

### 1. Simulation.Builder (returned by forTest())

```java
public final class Simulation {

    public static Builder forTest() {
        return new Builder("test");
    }

    public static Builder forTest(String defaultTenancyId) {
        return new Builder(defaultTenancyId);
    }

    public static final class Builder {

        private final String defaultTenancyId;
        private final Map<String, String> strategies = new LinkedHashMap<>();
        private final Map<String, List<InvocationRecord<Object, Object>>> records
            = new LinkedHashMap<>();
        private final Map<String, KeyExtractor<?>> extractors = new LinkedHashMap<>();

        Builder(String defaultTenancyId) {
            this.defaultTenancyId = defaultTenancyId;
        }

        // --- stub: key-lookup entries ---

        public <I, O> Builder stub(String qualifiedName, I input, O output) {
            String key = String.valueOf(input);
            addRecord(qualifiedName, key, input, output);
            strategies.merge(qualifiedName, "key-lookup", (old, nw) -> {
                if (!"key-lookup".equals(old))
                    throw ambiguousStrategy(qualifiedName, old, nw);
                return old;
            });
            extractors.putIfAbsent(qualifiedName,
                (Object i) -> String.valueOf(i));
            return this;
        }

        public <I, O> Builder stub(String qualifiedName,
                                    String key, I input, O output) {
            addRecord(qualifiedName, key, input, output);
            strategies.merge(qualifiedName, "key-lookup", (old, nw) -> {
                if (!"key-lookup".equals(old))
                    throw ambiguousStrategy(qualifiedName, old, nw);
                return old;
            });
            return this;
        }

        // --- seed: sequential entries ---

        public <I, O> Builder seed(String qualifiedName, I input, O output) {
            addRecord(qualifiedName, null, input, output);
            strategies.merge(qualifiedName, "sequential", (old, nw) -> {
                if (!"sequential".equals(old))
                    throw ambiguousStrategy(qualifiedName, old, nw);
                return old;
            });
            return this;
        }

        // --- extractors ---

        public <I> Builder keyExtractor(String qualifiedName,
                                         KeyExtractor<I> extractor) {
            extractors.put(qualifiedName, extractor);
            return this;
        }

        // --- explicit strategy override ---

        public Builder strategy(String qualifiedName, String strategyName) {
            strategies.put(qualifiedName, strategyName);
            return this;
        }

        // --- build ---

        public Simulation build() {
            var corpus = new InMemorySimulationCorpus<>();
            records.forEach((qn, recs) -> corpus.seed(qn, recs));

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

        private SimulationConfigException ambiguousStrategy(
                String qn, String existing, String incoming) {
            return new SimulationConfigException(
                "Ambiguous strategy for '" + qn + "': "
                + "stub() implies key-lookup but seed() implies sequential. "
                + "Use one or the other, or call .strategy() explicitly.");
        }
    }
}
```

### 2. Simulation (the built result)

```java
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

    // --- resolve: direct strategy invocation ---

    @SuppressWarnings("unchecked")
    public <I, O> O resolve(String qualifiedName, I input) {
        SimulationStrategy<I, O> strategy = runtime
            .<I, O>strategyFor(qualifiedName)
            .orElseThrow(() -> new SimulationConfigException(
                "No strategy configured for '" + qualifiedName + "'"));
        return strategy.resolve(input);
    }

    // --- overlay: push and track ---

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

    // --- verifier: on current overlay's journal ---

    public SimulationVerifier verifier() {
        if (currentOverlay == null) {
            throw new IllegalStateException(
                "No active overlay — call overlay() first");
        }
        return SimulationVerifier.on(currentOverlay.journal());
    }

    // --- escape hatch ---

    public SimulationRuntime runtime() {
        return runtime;
    }
}
```

### 3. Usage examples

**Before (current ceremony):**
```java
var corpus = new InMemorySimulationCorpus<String, String>();
corpus.seed("greeting.greet", List.of(
    new InvocationRecord<>("tenant-1", "alice", "Alice",
        "Hello Alice!", Instant.now()),
    new InvocationRecord<>("tenant-1", "bob", "Bob",
        "Hello Bob!", Instant.now())));
var config = new SimulationConfig() {
    @Override public Optional<String> strategyFor(String qn) {
        return qn.equals("greeting.greet")
            ? Optional.of("key-lookup") : Optional.empty();
    }
    @Override public boolean captureEnabled(String qn) { return false; }
    @Override public Optional<ExhaustionPolicy> exhaustionPolicy(String qn) {
        return Optional.empty();
    }
};
var runtime = new SimulationRuntime(config, corpus);
runtime.registerExtractor("greeting.greet",
    (String name) -> name.toLowerCase());
var strategy = runtime.<String, String>strategyFor("greeting.greet")
    .orElseThrow();
assertThat(strategy.resolve("Alice")).isEqualTo("Hello Alice!");
```

**After (fluent harness):**
```java
var sim = Simulation.forTest()
    .stub("greeting.greet", "Alice", "Hello Alice!")
    .stub("greeting.greet", "Bob", "Hello Bob!")
    .keyExtractor("greeting.greet",
        (String name) -> name.toLowerCase())
    .build();

assertThat(sim.<String, String>resolve("greeting.greet", "Alice"))
    .isEqualTo("Hello Alice!");
```

**Sequential:**
```java
var sim = Simulation.forTest()
    .seed("greeting.greet", "Alice", "Hello Alice!")
    .seed("greeting.greet", "Bob", "Hello Bob!")
    .build();

assertThat(sim.<String, String>resolve("greeting.greet", "anyone"))
    .isEqualTo("Hello Alice!");
assertThat(sim.<String, String>resolve("greeting.greet", "anyone"))
    .isEqualTo("Hello Bob!");
```

**Multi-method with verification:**
```java
var sim = Simulation.forTest()
    .stub("acl.canAccess", checkArgs, true)
    .seed("memory.store", storeInput, storeResult)
    .build();

var overlay = sim.overlay();
// ... run code under test ...
sim.verifier().method("acl.canAccess").wasCalled(1);
sim.verifier().method("memory.store").wasCalled();
sim.popOverlay(overlay);
```

### 4. Module placement

`Simulation` and `Simulation.Builder` live in `simulation-core`
(`io.casehub.platform.simulation` package). No new module needed.

Dependencies used by the harness are all already in simulation-core:
`InMemorySimulationCorpus` (from simulation-inmem, already a dependency),
`MapSimulationConfig`, `SimulationRuntime`, `SimulationVerifier`.

### 5. Testing plan

- `SimulationTest` in simulation-core/src/test — unit tests for:
  - `forTest()` with default tenancyId
  - `forTest("custom")` with custom tenancyId
  - `stub()` → key-lookup strategy
  - `seed()` → sequential strategy
  - `stub()` with explicit key
  - `keyExtractor()` override
  - `strategy()` explicit override
  - Mixed stub+seed on same qn → error
  - `resolve()` returns expected values
  - `overlay()` + `verifier()` lifecycle
  - `verifier()` without overlay → error
  - `popOverlay()` clears current overlay
  - `runtime()` escape hatch returns underlying runtime
  - Multi-method simulation

## References

- SimulationRuntime.java — runtime wiring and overlay stack
- MapSimulationConfig.java — map-based config implementation
- SimulationVerifier.java — journal-based verification
- CorpusSeed.java — existing fluent seeding (complementary, not replaced)
- SimulationGettingStartedTest.java — current ceremony baseline
- casehubio/platform#353 — issue with target API sketch
- D1-D6 in decisions.md — all design choices
