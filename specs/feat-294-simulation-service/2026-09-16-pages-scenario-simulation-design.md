# Pages Scenario Simulation Integration — Design Spec

**Branch:** issue-294-simulation-service
**Issues:** casehubio/platform#322 (platform API), casehub-pages#450 (pages consumer)
**Epic:** casehubio/platform#294
**Date:** 2026-09-16

## Overview

Extends the simulation framework with runtime-scoped simulation contexts so that scenario scripts can configure strategies, seed corpora, assert against invocations, and switch strategies mid-scenario — all with per-scenario isolation.

The work spans two repos:
- **casehub-platform** (#322) — `SimulationOverlay` API on `SimulationRuntime`: push/pop overlay stack, isolated corpus, invocation journal
- **casehub-pages** (#450) — scenario YAML schema extension, `ScenarioOrchestrator` lifecycle hooks, assertion step type

## Architecture

### Overlay stack on SimulationRuntime

`SimulationRuntime` currently resolves strategies from a single `SimulationConfig` and caches them in a `ConcurrentHashMap`. This design adds a stack of `SimulationOverlay` objects that layer on top of the base config.

```
┌─────────────────────────────────┐
│  SimulationRuntime              │
│                                 │
│  overlayStack: [               │
│    Overlay 2 (mid-scenario)    │  ← top, checked first
│    Overlay 1 (scenario setup)  │
│  ]                              │
│                                 │
│  baseConfig: SmallRyeConfig     │  ← fallback
│  baseCorpus: InMemoryCorpus     │
│  strategyCache: ConcurrentMap   │
└─────────────────────────────────┘
```

**Strategy resolution** (`strategyFor(qualifiedName)`):
1. Walk overlay stack top-down
2. First overlay whose config returns a strategy for `qualifiedName` wins
3. Create and return the strategy using that overlay's corpus
4. If no overlay has a strategy, fall through to base config + base corpus

**Strategy cache invalidation:** On `pushOverlay()`, evict cached strategies for every qualified name declared in the new overlay's config. Other cached strategies remain valid. On `popOverlay()`, evict the same set — the next call re-resolves from the remaining stack or base.

### SimulationOverlay

An opaque handle returned by `pushOverlay()`. Not publicly constructable.

```java
public final class SimulationOverlay {
    // package-private constructor — only SimulationRuntime creates these
    SimulationOverlay(SimulationConfig config, SimulationCorpus corpus) { ... }

    SimulationConfig config();
    SimulationCorpus corpus();
    InvocationJournal journal();
}
```

Each overlay owns:
- **Config** — strategy declarations for specific qualified names (partial — only the SPIs this overlay controls)
- **Corpus** — fresh `InMemorySimulationCorpus`, seeded by the scenario. Discarded on pop.
- **Journal** — records every intercepted call while this overlay is active

### InvocationJournal

Records every call intercepted by a generated decorator while an overlay is active.

```java
public final class InvocationJournal {
    void record(JournalEntry entry);
    List<JournalEntry> entries();
    List<JournalEntry> entriesFor(String qualifiedName);
    long countFor(String qualifiedName);
}

public record JournalEntry(
    String qualifiedName,
    Object input,
    Object output,
    Instant timestamp,
    boolean simulated   // true = strategy resolved, false = passthrough to delegate
) {}
```

The `simulated` flag distinguishes "strategy resolved this" from "delegate was called." This enables assertions like "agent-provider.invoke was called 3 times, all simulated" or "preference-provider.get was called but hit the real implementation."

### SimulationRuntime API additions

```java
// Push a new overlay with strategy overrides and an isolated corpus
public SimulationOverlay pushOverlay(SimulationConfig config, SimulationCorpus corpus);

// Push with auto-created empty InMemorySimulationCorpus
public SimulationOverlay pushOverlay(SimulationConfig config);

// Pop a specific overlay (identity check prevents mismatched pops)
public void popOverlay(SimulationOverlay overlay);

// Pop all overlays — teardown convenience
public void popAll();

// Query the journal for a specific overlay
public List<JournalEntry> journal(SimulationOverlay overlay);

// Check if any overlay is active
public boolean hasActiveOverlay();
```

**Thread safety:** The overlay stack is a `CopyOnWriteArrayList` — reads (strategy resolution on every intercepted call) are lock-free. Writes (push/pop) are infrequent (scenario setup/teardown). The `ScenarioOrchestrator` is single-scenario (`volatile` state fields, no concurrent scenario support), so concurrent overlay mutations don't arise in practice.

### MapSimulationConfig

A new `SimulationConfig` implementation for programmatic use (scenarios don't use SmallRye Config):

```java
public class MapSimulationConfig implements SimulationConfig {
    // Builder-style construction
    public static MapSimulationConfig of(Map<String, String> strategies);
    public static MapSimulationConfig of(Map<String, String> strategies,
                                          Map<String, Boolean> captures);
}
```

Constructed from a `Map<String, String>` of qualified name → strategy name. This is what the scenario YAML `strategies:` block deserialises into.

### Generated decorator changes

The generated decorators need one change: after resolving a strategy (or falling through to delegate), record the invocation in the active overlay's journal (if any).

Current generated code (SimulatedCaseMemoryStore example):
```java
Optional<SimulationStrategy<Object, Object>> strategy = simulation.strategyFor(qualifiedName);
if (strategy.isPresent() && strategy.get().canResolve(arg0)) {
    return (List<Memory>) strategy.get().resolve(arg0);
}
List<Memory> result = delegate.query(arg0);
if (simulation.captureEnabled(qualifiedName)) {
    simulation.capture(qualifiedName, currentPrincipal.tenancyId(), arg0, result);
}
return result;
```

Updated pattern — adds journal recording:
```java
Optional<SimulationStrategy<Object, Object>> strategy = simulation.strategyFor(qualifiedName);
if (strategy.isPresent() && strategy.get().canResolve(arg0)) {
    Object result = strategy.get().resolve(arg0);
    simulation.recordJournal(qualifiedName, arg0, result, true);
    return (List<Memory>) result;
}
List<Memory> result = delegate.query(arg0);
simulation.recordJournal(qualifiedName, arg0, result, false);
if (simulation.captureEnabled(qualifiedName)) {
    simulation.capture(qualifiedName, currentPrincipal.tenancyId(), arg0, result);
}
return result;
```

`simulation.recordJournal()` is a no-op when no overlay is active (fast path: `overlayStack.isEmpty()` check).

### Module placement

All platform-side additions live in `simulation-core`:
- `SimulationOverlay` — overlay handle
- `InvocationJournal` + `JournalEntry` — journal infrastructure
- `MapSimulationConfig` — programmatic config implementation
- `SimulationRuntime` changes — overlay stack, push/pop, journal delegation

No new modules. The generator (`simulation-generator`) gets the updated decorator template.

## Pages Integration (casehub-pages#450)

### Scenario YAML schema extension

A `simulation:` block at the scenario root level:

```yaml
scenario: Patient intake with simulated LLM
simulation:
  strategies:
    agent-provider.invoke: sequential
    case-memory-store.query: key-lookup
  corpus:
    - fixtures/agent-responses.yaml
    - fixtures/memory-data.yaml
  capture:
    - preference-provider.get
steps:
  - name: start-case
    domain: cases
    operation: startCase
    params:
      definitionId: intake-v1
```

- **`strategies`** — map of qualified name → strategy name. Same keys as `casehub.simulation.<spi>.<method>` config properties.
- **`corpus`** — list of YAML fixture file paths (relative to scenario library path). Loaded via `YamlCorpusLoader` and seeded into the overlay's corpus.
- **`capture`** — list of qualified names to enable capture for (recorded in journal AND stored in overlay corpus for potential export).

### ScenarioOrchestrator lifecycle hooks

**On start (before dispatching sequences):**
1. Parse `simulation:` block from the scenario YAML
2. If present, build `MapSimulationConfig` from `strategies` map
3. Create fresh `InMemorySimulationCorpus`
4. Load and seed corpus files via `YamlCorpusLoader`
5. Call `simulationRuntime.pushOverlay(config, corpus)`
6. Store the returned `SimulationOverlay` handle for teardown

**On stop/completion (before clearing state):**
1. If overlay handle exists, call `simulationRuntime.popOverlay(overlay)`
2. Overlay, corpus, and journal are discarded

### Mid-scenario strategy switching

A step can declare a `simulation:` block that pushes a new overlay:

```yaml
steps:
  - name: real-phase
    domain: cases
    operation: startCase
  - name: switch-to-simulated
    simulation:
      strategies:
        agent-provider.invoke: key-lookup
      corpus:
        - fixtures/llm-responses.yaml
  - name: simulated-phase
    domain: agents
    operation: invoke
```

The `switch-to-simulated` step is a control step (like `navigate` or `wait`) — it pushes a new overlay and completes immediately. The new overlay stays active for subsequent steps. All overlays are popped on scenario teardown via `popAll()`.

### Assertion step type

New assertion variant for simulation verification:

```yaml
- name: verify-agent-called
  assert:
    simulation:
      invoked: agent-provider.invoke
      count: 2
      input-contains:
        prompt: "patient intake"
```

The assertion queries the overlay's journal:
- **`invoked`** — qualified name to check
- **`count`** (optional) — exact invocation count. If omitted, asserts at least one invocation.
- **`simulated`** (optional, default: true) — filter by simulated flag
- **`input-contains`** (optional) — map of field → expected value. Checks that at least one journal entry's input contains these fields (via Jackson ObjectMapper.convertValue to Map, then field matching).

### Dependency: SimulationRuntime injection

`ScenarioOrchestrator` is `@ApplicationScoped` and already uses CDI injection. It gets `SimulationRuntime` injected:

```java
@Inject SimulationRuntime simulationRuntime;
```

This requires `casehub-pages` to add `casehub-platform-simulation-core` as a compile dependency in the `scenario-runtime` module (alongside its existing platform dependencies).

## Testing

### Platform side (simulation-core)

- **SimulationRuntime overlay tests:**
  - Push overlay, verify `strategyFor()` resolves from overlay config
  - Push two overlays, verify top-down resolution order
  - Pop overlay, verify fallback to base config
  - `popAll()` clears all overlays
  - Strategy cache invalidation on push/pop

- **InvocationJournal tests:**
  - Record entries, query by qualified name
  - Count entries
  - `simulated` flag correctly set

- **MapSimulationConfig tests:**
  - Construct from map, verify `strategyFor()` returns correct values
  - Empty map returns `Optional.empty()` for all queries

- **Generator template tests:**
  - Generated decorator records journal entries
  - No-op when no overlay active (fast path)

### Pages side (casehub-pages)

- **Scenario YAML parsing:**
  - Parse `simulation:` block into config + corpus paths
  - Missing `simulation:` block → no overlay pushed

- **Lifecycle integration:**
  - Overlay pushed on start, popped on stop
  - Overlay pushed on completion (all steps done)
  - Corpus seeded from fixture files

- **Assertion step:**
  - Count assertion passes/fails
  - Input-contains matching
  - Simulated flag filtering

## References

- SimulationRuntime.java — current strategy resolution and cache
- SimulationConfig.java — interface extended by MapSimulationConfig
- InMemorySimulationCorpus.java — used as overlay corpus
- SmallRyeSimulationConfig.java — existing config implementation (base config)
- SimulationDecoratorProcessor.java — generator template needs journal recording
- ScenarioOrchestrator.java (casehub-pages) — lifecycle hooks
- ScenarioStep.java (casehub-pages) — assertion step type extension
- YamlCorpusLoader.java — corpus fixture loading
- D11 — boot-time config decision (extended by D43)
- D43-D48 — phase 8 decisions
