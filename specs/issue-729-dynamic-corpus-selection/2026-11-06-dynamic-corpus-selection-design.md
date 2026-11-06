# Dynamic Corpus Selection — Design Spec

**Issue:** casehubio/platform#729
**Branch:** issue-729-dynamic-corpus-selection
**Date:** 2026-11-06

## Problem

Simulation corpus responses are static — a key always resolves to the same entry. Real systems change behaviour over time: an order starts as PENDING and becomes COMPLETED, a service degrades after load, a third-party API returns different schemas after a version cutover. Neither SPI decorator simulation nor playbook step simulation can model these progressions without programmatic overlay manipulation.

## Solution Overview

Introduce a `CorpusSelector` abstraction that determines which **phase** of corpus data is active for a given qualified name at any point during simulation. The selector sits at the corpus level — a `PhasedCorpus` wraps the real `SimulationCorpus` and delegates to phase-specific sub-corpora based on the selector's current state. Strategies (`KeyLookupStrategy`, `SequentialStrategy`, etc.) are created with the `PhasedCorpus` and don't know phases exist.

This design requires zero changes to existing strategies, generated `@Decorator` classes, or `SimulatingAction`.

## Architecture

### Component Hierarchy

```
SimulationRuntime.createStrategy(qn, strategyName, corpus)
    │
    ├── No corpus-selection configured → use corpus as-is (existing path)
    │
    └── corpus-selection configured →
            Build PhasedCorpus(selector, phaseCorpora)
            Pass PhasedCorpus to strategy constructor
            Strategy calls PhasedCorpus.lookupByKey() etc.
                → PhasedCorpus asks selector for active phase
                → delegates to phase-specific InvocationRecord list
```

### Module Placement

| Type | Module | Rationale |
|------|--------|-----------|
| `CorpusSelector` (interface) | simulation-api | Zero-dep SPI, alongside `SimulationCorpus` |
| `PhasedCorpus` | simulation-api | Decorates `SimulationCorpus` (same module) |
| `CorpusSelectorConfig` (sealed) | simulation-api | Config records, zero-dep |
| `StateMachineSelector` | simulation-core | Needs j.u.c for thread safety |
| `DurationSelector` | simulation-core | Needs `SpeedMultiplier` from yaml-core |
| `LookupCountSelector` | simulation-core | Needs `AtomicInteger` (trivial) |
| `RandomSelector` | simulation-core | Needs `Random` |
| YAML parsing for `corpus-selection` | simulation-config-core | Extends `YamlSimulationConfig` |
| Quarkus wiring (trigger connections) | simulation-config | Extends `SimulationConfigBeans` |

### Type Definitions

#### CorpusSelector (simulation-api)

```java
public interface CorpusSelector {
    String activePhase();
    default void onResolved() {}
}
```

Returns the name of the currently active phase. Thread-safe — may be called concurrently from multiple strategy invocations.

#### PhasedCorpus (simulation-api)

```java
public final class PhasedCorpus<I, O> implements SimulationCorpus<I, O> {

    private final CorpusSelector selector;
    private final Map<String, List<InvocationRecord<I, O>>> phases;
    // phase name → corpus entries for that phase

    // All SimulationCorpus methods delegate to the active phase's entries:
    // lookupByKey(qn, key) → filter active phase entries by key
    // lookupByIndex(qn, index) → index into active phase entries
    // list(qn) → return active phase entries
    // size(qn) → return active phase entry count
    //
    // record(), seed(), clear() → throw UnsupportedOperationException
    // (PhasedCorpus is read-only — corpus data is seeded per-phase at creation)
}
```

`PhasedCorpus` implements `SimulationCorpus` but is read-only. All mutation methods (`record`, `seed`, `clear`) throw `UnsupportedOperationException`. Corpus data is loaded per-phase during config parsing and passed in at construction time.

#### CorpusSelectorConfig (simulation-api)

```java
public sealed interface CorpusSelectorConfig {

    Map<String, List<InvocationRecord<Object, Object>>> phases();

    record StateMachine(
        String initial,
        Map<String, Map<String, String>> transitions,  // fromState → trigger → toState
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

The `phases()` method provides the shared contract for extracting per-phase corpus data, used by `PhasedCorpus` construction. Each variant carries type-specific configuration for its selector.

### Selector Implementations (simulation-core)

#### StateMachineSelector

```java
public final class StateMachineSelector implements CorpusSelector {
    private final Map<String, Map<String, String>> transitions;
    private volatile String currentState;

    public StateMachineSelector(String initial,
                                Map<String, Map<String, String>> transitions) { ... }

    @Override
    public String activePhase() { return currentState; }

    public void advance(String trigger) {
        // Look up currentState in transitions map
        // If trigger matches, transition to new state
        // Thread-safe via volatile + CAS or similar
    }
}
```

Transitions are triggered externally via `advance(String trigger)`. The wiring layer (in `simulation-config` / playbook runtime) connects trigger sources:
- **Step completion:** playbook step lifecycle observer calls `advance("step-name")`
- **Event detection:** CDI event observer evaluates conditions, calls `advance("event-name")`
- **Explicit signal:** user code calls `advance("trigger-name")` directly

#### DurationSelector

```java
public final class DurationSelector implements CorpusSelector {
    private final List<CorpusSelectorConfig.DurationPhase> phases;
    private final SpeedMultiplier speedMultiplier;
    private final long startNanos;

    @Override
    public String activePhase() {
        long elapsed = (System.nanoTime() - startNanos);
        double speed = speedMultiplier.currentSpeed();
        long simulatedElapsed = (long) (elapsed * speed);
        // Walk phases, find the one whose cumulative duration covers simulatedElapsed
        // Last phase is active indefinitely after its predecessors expire
    }
}
```

Respects `SpeedMultiplier` — at 10x speed, a 10s phase expires after 1s of wall-clock time. The last phase has no duration limit (it's the terminal state).

#### LookupCountSelector

```java
public final class LookupCountSelector implements CorpusSelector {
    private final List<CorpusSelectorConfig.CountPhase> phases;
    private final AtomicInteger lookupCount = new AtomicInteger(0);

    @Override
    public String activePhase() {
        int count = lookupCount.getAndIncrement();
        // Walk phases, find the one whose cumulative count covers this lookup
        // Last phase is active indefinitely after count thresholds
    }
}
```

The `count` field on each phase is how many successful resolutions that phase handles before advancing to the next.

**Lookup counting lifecycle:** `activePhase()` is pure read — no side effects. `LookupCountSelector` also implements `advance()` which increments the counter. The `SimulationRuntime` calls `advanceCorpusSelector(qn)` after each successful `strategy.resolve()` — this is a one-line addition to the runtime's resolution path. This separation avoids double-counting from the `canResolve()` + `resolve()` pair that both call through to `PhasedCorpus.lookupByKey()`.

See the **Lifecycle Hook** section below for details.

#### RandomSelector

```java
public final class RandomSelector implements CorpusSelector {
    private final List<CorpusSelectorConfig.WeightedPhase> phases;
    private final Random random;

    @Override
    public String activePhase() {
        double r = random.nextDouble();
        // Walk phases, accumulate weights, return first phase whose
        // cumulative weight exceeds r
    }
}
```

Stateless — each lookup independently selects a phase by weight. Weights must sum to 1.0 (validated at parse time).

### SimulationConfig Extension

```java
public interface SimulationConfig {
    // ... existing methods ...

    default Optional<CorpusSelectorConfig> corpusSelection(String qualifiedName) {
        return Optional.empty();
    }
}
```

Existing implementations (`MapSimulationConfig`, overlay configs) return `Optional.empty()` by default. `YamlSimulationConfig` parses `corpus-selection` blocks and returns the typed config.

### SimulationRuntime Changes

In `createStrategy()`, after resolving the strategy name:

```java
private SimulationStrategy<?, ?> createStrategy(String qualifiedName,
                                                 String strategyName,
                                                 SimulationCorpus corpus) {
    SimulationCorpus effectiveCorpus = corpus;
    Optional<CorpusSelectorConfig> selection = config.corpusSelection(qualifiedName);
    if (selection.isPresent()) {
        effectiveCorpus = buildPhasedCorpus(qualifiedName, selection.get());
    }
    return switch (resolveAlias(strategyName)) {
        case "key-lookup" -> new KeyLookupStrategy<>(effectiveCorpus, qualifiedName, ...);
        // ... same as before, using effectiveCorpus instead of corpus
    };
}

private PhasedCorpus<Object, Object> buildPhasedCorpus(String qualifiedName,
                                                        CorpusSelectorConfig config) {
    CorpusSelector selector = switch (config) {
        case CorpusSelectorConfig.StateMachine sm ->
            new StateMachineSelector(sm.initial(), sm.transitions());
        case CorpusSelectorConfig.Duration d ->
            new DurationSelector(d.orderedPhases(), speedMultiplier());
        case CorpusSelectorConfig.LookupCount lc ->
            new LookupCountSelector(lc.orderedPhases());
        case CorpusSelectorConfig.Weighted w ->
            new RandomSelector(w.weightedPhases());
    };
    return new PhasedCorpus<>(selector, config.phases());
}
```

The `StateMachineSelector` instance is registered in a new `ConcurrentHashMap<String, StateMachineSelector>` on the runtime, so the wiring layer can retrieve it to connect trigger sources:

```java
public Optional<StateMachineSelector> stateMachineSelector(String qualifiedName) {
    return Optional.ofNullable(stateMachineSelectors.get(qualifiedName));
}
```

### YAML Schema

The `corpus-selection` block is a new optional property on `method-config`, mutually exclusive with `corpus` and `corpus-files`:

```yaml
methods:
  rest-request:
    strategy: key-lookup
    key-extractor: "field:url"
    corpus-selection:
      type: state-machine
      initial: pending
      transitions:
        pending:
          process-payment: completed
        completed:
          ship-order: shipped
      phases:
        pending:
          - key: "/api/order/123"
            output: { status: "PENDING" }
        completed:
          - key: "/api/order/123"
            output: { status: "COMPLETED" }
        shipped:
          - key: "/api/order/123"
            output: { status: "SHIPPED", trackingId: "TRK-99421" }
```

#### Duration

```yaml
corpus-selection:
  type: duration
  phases:
    - name: normal
      duration: 10s
      corpus:
        - key: "/api/health"
          output: { status: "OK" }
    - name: degraded
      corpus:
        - key: "/api/health"
          output: { status: "DEGRADED" }
```

The last phase has no `duration` — it's the terminal phase active indefinitely.

#### Lookup-count

```yaml
corpus-selection:
  type: lookup-count
  phases:
    - name: pending
      count: 3
      corpus:
        - key: "/api/order/123"
          output: { status: "PENDING" }
    - name: completed
      corpus:
        - key: "/api/order/123"
          output: { status: "COMPLETED" }
```

The last phase has no `count` — it's the terminal phase.

#### Random/weighted

```yaml
corpus-selection:
  type: random
  phases:
    - name: normal
      weight: 0.8
      corpus:
        - key: "/api/order/123"
          output: { status: "OK" }
    - name: timeout
      weight: 0.15
      corpus:
        - key: "/api/order/123"
          output: { error: "GATEWAY_TIMEOUT" }
    - name: corrupt
      weight: 0.05
      corpus:
        - key: "/api/order/123"
          output: { status: null, data: "garbled" }
```

Weights must sum to 1.0.

### Lifecycle Hook — onResolved()

The `CorpusSelector.onResolved()` method is called after each successful `strategy.resolve()`. This is the increment point for `LookupCountSelector` — it cannot increment inside `activePhase()` because `activePhase()` is called from both `canResolve()` and `resolve()` (strategies call `corpus.lookupByKey()` in both paths).

The call site is `SimulationRuntime`, which wraps the strategy resolution:

```java
public <I, O> O resolveWithSelector(String qualifiedName, SimulationStrategy<I, O> strategy, I input) {
    O result = strategy.resolve(input);
    // Notify corpus selector (if any) that a resolution completed
    CorpusSelector selector = corpusSelectors.get(qualifiedName);
    if (selector != null) {
        selector.onResolved();
    }
    return result;
}
```

The generated `@Decorator` and `SimulatingAction` already call through `runtime.strategyFor()` → `strategy.resolve()`. Adding the `onResolved()` call to the runtime's resolution path is a single integration point — callers don't change.

**Which selectors use onResolved():**
- `LookupCountSelector` — increments counter
- `StateMachineSelector` — no-op (transitions are driven by external `advance()` calls)
- `DurationSelector` — no-op (driven by wall-clock time)
- `RandomSelector` — no-op (stateless)

### Validation Rules

1. `corpus` and `corpus-selection` are mutually exclusive on a method
2. `corpus-files` and `corpus-selection` are mutually exclusive on a method
3. State machine: every state referenced in transitions must have a corresponding phase
4. State machine: `initial` must name an existing phase
5. Duration: last phase must not have a `duration` (terminal)
6. Lookup-count: last phase must not have a `count` (terminal)
7. Random: weights must sum to 1.0 (within floating-point tolerance)
8. All types: phase names must be unique within a `corpus-selection` block

### Testing Strategy

**Unit tests (simulation-core):**
- Each selector implementation tested independently: state transitions, duration with speed multiplier, lookup counting, weighted random distribution
- `PhasedCorpus` tested with mock selector: phase switching, lookup delegation, read-only enforcement
- Integration: `SimulationRuntime` creates strategy with `PhasedCorpus` when config has corpus-selection

**Config tests (simulation-config-core):**
- `YamlSimulationConfig` parses all four `corpus-selection` types
- Validation: mutual exclusion with `corpus`/`corpus-files`, state machine consistency, weight sums, terminal phase rules
- Schema validation: `simulation.schema.json` updated and drift-tested

**Integration tests (simulation-config):**
- End-to-end: YAML → config → runtime → strategy → phased resolution
- State machine trigger wiring via `SimulationRuntime.stateMachineSelector()`
- Duration with `SpeedMultiplier` bridge

## Scope Boundaries

**In scope:**
- `CorpusSelector` interface and `PhasedCorpus` in simulation-api
- Four selector implementations in simulation-core
- `CorpusSelectorConfig` sealed interface in simulation-api
- `SimulationConfig.corpusSelection()` extension
- `SimulationRuntime` changes to build `PhasedCorpus`
- `YamlSimulationConfig` parsing for `corpus-selection` blocks
- `simulation.schema.json` update
- Unit and config tests

**Out of scope (follow-up):**
- Playbook step lifecycle wiring (connecting step completion events to `StateMachineSelector.advance()`)
- CDI event observer wiring for event-triggered transitions
- MCP tool for runtime phase inspection / manual trigger
- Per-phase `corpus-files` (external file references within phases)
- Profile-level corpus-selection (phases that span multiple methods)

## References

- SimulationRuntime.java:52-66, 171-196 — strategy resolution and creation
- SimulationCorpus.java — interface being decorated
- KeyLookupStrategy.java — example strategy that will use PhasedCorpus transparently
- SimulatedPreferenceProvider.java (generated) — example @Decorator calling strategyFor()
- SimulatingAction.java — playbook step simulation integration
- simulation.schema.json — existing schema to extend
- YamlSimulationConfig.java — YAML parsing to extend
- SimulationConfig.java — interface to extend
- yaml-core SpeedMultiplier — used by DurationSelector
