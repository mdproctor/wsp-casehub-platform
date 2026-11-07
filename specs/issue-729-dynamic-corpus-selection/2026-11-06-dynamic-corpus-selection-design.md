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

    // All SimulationCorpus read methods delegate to the active phase's entries:
    // lookupByKey(qn, key) → filter active phase entries by key
    // lookupByIndex(qn, index) → index into active phase entries
    // list(qn) → return active phase entries
    // listByTenant(qn, tenancyId) → filter active phase entries by tenancyId
    // size(qn) → return active phase entry count
    //
    // record(), seed(), clear() → throw UnsupportedOperationException
    // (PhasedCorpus is read-only — corpus data is seeded per-phase at creation)

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

`PhasedCorpus` implements `SimulationCorpus` but is read-only. All mutation methods (`record`, `seed`, `clear`) throw `UnsupportedOperationException`. Corpus data is loaded per-phase during config parsing and passed in at construction time.

**Runtime phase validation:** If `selector.activePhase()` returns a phase name not in the phases map, `PhasedCorpus` throws `SimulationConfigException` with a diagnostic message listing the available phases. This fail-fast surfaces bad `CorpusSelector` implementations immediately rather than silently returning empty results.

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
    private final AtomicReference<String> currentState;

    public StateMachineSelector(String initial,
                                Map<String, Map<String, String>> transitions) {
        this.currentState = new AtomicReference<>(initial);
        this.transitions = Map.copyOf(transitions);
    }

    @Override
    public String activePhase() { return currentState.get(); }

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

Transitions are triggered externally via `advance(String trigger)`. The wiring layer (in `simulation-config` / playbook runtime) connects trigger sources:
- **Step completion:** playbook step lifecycle observer calls `advance("step-name")`
- **Event detection:** CDI event observer evaluates conditions, calls `advance("event-name")`
- **Explicit signal:** user code calls `advance("trigger-name")` directly

#### DurationSelector

```java
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
        this.phases = phases;
        this.speedMultiplier = speedMultiplier;
        this.nanoSource = nanoSource;
        this.startNanos = nanoSource.getAsLong();
    }

    @Override
    public String activePhase() {
        long elapsed = (nanoSource.getAsLong() - startNanos);
        double speed = speedMultiplier.currentSpeed();
        long simulatedElapsed = (long) (elapsed * speed);
        // Walk phases, find the one whose cumulative duration covers simulatedElapsed
        // Last phase is active indefinitely after its predecessors expire
    }
}
```

Respects `SpeedMultiplier` — at 10x speed, a 10s phase expires after 1s of wall-clock time. The last phase has no duration limit (it's the terminal state). The package-private constructor accepts a `LongSupplier` for the time source, allowing tests to inject a controllable clock for deterministic duration-based selection tests.

#### LookupCountSelector

```java
public final class LookupCountSelector implements CorpusSelector {
    private final List<CorpusSelectorConfig.CountPhase> phases;
    private final AtomicInteger lookupCount = new AtomicInteger(0);

    @Override
    public String activePhase() {
        int count = lookupCount.get();
        // Walk phases, find the one whose cumulative count covers this lookup
        // Last phase is active indefinitely after count thresholds
    }

    @Override
    public void onResolved() {
        lookupCount.incrementAndGet();
    }
}
```

The `count` field on each phase is how many successful resolutions that phase handles before advancing to the next.

**Lookup counting lifecycle:** `activePhase()` is pure read — no side effects. `LookupCountSelector` overrides `onResolved()` to increment the counter. The runtime's strategy wrapping (see §SimulationRuntime Changes) calls `onResolved()` after each successful `strategy.resolve()` — transparent to callers. This separation avoids double-counting from the `canResolve()` + `resolve()` pair that both call through to `PhasedCorpus.lookupByKey()`.

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

**Selector persistence:** Corpus selectors are stored in a `ConcurrentHashMap<String, CorpusSelector>` on the runtime that is **not** cleared by `pushOverlay()` / `popOverlay()`. This is distinct from the strategy cache (`strategyCache`), which IS cleared on overlay changes. When `createStrategy()` is called after a cache invalidation, `buildSelector()` reuses the existing selector via `computeIfAbsent` — preserving transition state, lookup counts, and duration start times across overlay push/pop cycles.

**Config scoping:** `createStrategy()` takes the effective `SimulationConfig` as a parameter. `strategyFor()` passes `overlay.config()` for overlay strategies and `this.config` for base strategies. This ensures overlays use their own corpus-selection (or none, via the `Optional.empty()` default on `SimulationConfig`), without inheriting the base config's corpus-selection. If the base config has `corpus-selection: state-machine` for a QN and an overlay provides its own corpus for that QN, the overlay's corpus is used directly — the base config's phased corpus does not override it.

```java
// Selector map — NOT cleared by push/pop (selectors outlive the strategy cache)
private final ConcurrentHashMap<String, CorpusSelector> corpusSelectors = new ConcurrentHashMap<>();

private SimulationStrategy<?, ?> createStrategy(String qualifiedName,
                                                 String strategyName,
                                                 SimulationCorpus corpus,
                                                 SimulationConfig effectiveConfig) {
    SimulationCorpus effectiveCorpus = corpus;
    CorpusSelector selector = null;
    Optional<CorpusSelectorConfig> selection = effectiveConfig.corpusSelection(qualifiedName);
    if (selection.isPresent()) {
        selector = buildSelector(qualifiedName, selection.get());
        effectiveCorpus = new PhasedCorpus<>(selector, selection.get().phases());
    }

    SimulationStrategy<?, ?> strategy = switch (resolveAlias(strategyName)) {
        case "key-lookup" -> new KeyLookupStrategy<>(effectiveCorpus, qualifiedName, ...);
        // ... same as before, using effectiveCorpus instead of corpus
    };

    if (selector != null) {
        strategy = wrapWithSelector(strategy, selector);
    }
    return strategy;
}

private CorpusSelector buildSelector(String qualifiedName, CorpusSelectorConfig config) {
    return corpusSelectors.computeIfAbsent(qualifiedName, qn -> switch (config) {
        case CorpusSelectorConfig.StateMachine sm ->
            new StateMachineSelector(sm.initial(), sm.transitions());
        case CorpusSelectorConfig.Duration d ->
            new DurationSelector(d.orderedPhases(), this::globalSpeed);
        case CorpusSelectorConfig.LookupCount lc ->
            new LookupCountSelector(lc.orderedPhases());
        case CorpusSelectorConfig.Weighted w ->
            new RandomSelector(w.weightedPhases());
    });
}

@SuppressWarnings({"rawtypes", "unchecked"})
private static SimulationStrategy<?, ?> wrapWithSelector(SimulationStrategy strategy,
                                                          CorpusSelector selector) {
    return new SimulationStrategy<>() {
        @Override public Object resolve(Object input) {
            Object result = strategy.resolve(input);
            selector.onResolved();
            return result;
        }
        @Override public boolean canResolve(Object input) {
            return strategy.canResolve(input);
        }
        @Override public DataRealism dataRealism() {
            return strategy.dataRealism();
        }
    };
}
```

The `wrapWithSelector` method wraps the strategy so that `onResolved()` fires after every `resolve()` call. Because callers receive the wrapped strategy from `strategyFor()`, the lifecycle hook is transparent — generated `@Decorator` classes and `SimulatingAction` call `strategy.resolve()` directly and the notification fires automatically.

The existing `strategyFor()` method is updated to pass the appropriate config:

```java
// Overlay path:
createStrategy(qn, overlayStrategy.get(), overlay.corpus(), overlay.config())
// Base path:
createStrategy(qn, strategyName, corpus, config)
```

The `stateMachineSelector()` API casts from the general `corpusSelectors` map:

```java
public Optional<StateMachineSelector> stateMachineSelector(String qualifiedName) {
    CorpusSelector selector = corpusSelectors.get(qualifiedName);
    return selector instanceof StateMachineSelector sms
        ? Optional.of(sms) : Optional.empty();
}
```

### YAML Schema

The `corpus-selection` block is a new optional property on `method-config`, mutually exclusive with `corpus` and `corpus-files`. The JSON schema enforces this via a `not` constraint on `method-config`:

```json
"not": {
  "anyOf": [
    { "required": ["corpus-selection", "corpus"] },
    { "required": ["corpus-selection", "corpus-files"] }
  ]
}
```

The `corpus-selection` property is added to `method-config`:

```json
"corpus-selection": { "$ref": "#/$defs/corpus-selection-config" }
```

The `$defs/corpus-selection-config` definition uses `if/then` on the `type` discriminator:

```json
"corpus-selection-config": {
  "type": "object",
  "required": ["type"],
  "properties": {
    "type": {
      "type": "string",
      "enum": ["state-machine", "duration", "lookup-count", "random"]
    }
  },
  "allOf": [
    {
      "if": { "properties": { "type": { "const": "state-machine" } }, "required": ["type"] },
      "then": {
        "required": ["initial", "transitions", "phases"],
        "properties": {
          "initial": { "type": "string", "description": "Starting state" },
          "transitions": {
            "type": "object",
            "description": "fromState → trigger → toState",
            "additionalProperties": {
              "type": "object",
              "additionalProperties": { "type": "string" }
            }
          },
          "phases": {
            "type": "object",
            "description": "State name → corpus entries",
            "additionalProperties": {
              "type": "array",
              "items": { "$ref": "#/$defs/corpus-entry" }
            }
          }
        }
      }
    },
    {
      "if": { "properties": { "type": { "const": "duration" } }, "required": ["type"] },
      "then": {
        "required": ["phases"],
        "properties": {
          "phases": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["name", "corpus"],
              "properties": {
                "name": { "type": "string" },
                "duration": { "type": ["string", "number"], "description": "Phase duration (5s, 2m, 500ms). Omit on last phase (terminal)." },
                "corpus": { "type": "array", "items": { "$ref": "#/$defs/corpus-entry" } }
              }
            }
          }
        }
      }
    },
    {
      "if": { "properties": { "type": { "const": "lookup-count" } }, "required": ["type"] },
      "then": {
        "required": ["phases"],
        "properties": {
          "phases": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["name", "corpus"],
              "properties": {
                "name": { "type": "string" },
                "count": { "type": "integer", "minimum": 1, "description": "Resolutions before advancing. Omit on last phase (terminal)." },
                "corpus": { "type": "array", "items": { "$ref": "#/$defs/corpus-entry" } }
              }
            }
          }
        }
      }
    },
    {
      "if": { "properties": { "type": { "const": "random" } }, "required": ["type"] },
      "then": {
        "required": ["phases"],
        "properties": {
          "phases": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["name", "weight", "corpus"],
              "properties": {
                "name": { "type": "string" },
                "weight": { "type": "number", "minimum": 0, "maximum": 1, "description": "Selection probability. All weights must sum to 1.0." },
                "corpus": { "type": "array", "items": { "$ref": "#/$defs/corpus-entry" } }
              }
            }
          }
        }
      }
    }
  ]
}
```

YAML examples:

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

The mechanism is **strategy wrapping**: `SimulationRuntime.createStrategy()` wraps the strategy in a delegating wrapper that calls `selector.onResolved()` after `resolve()` (see `wrapWithSelector()` in §SimulationRuntime Changes). The wrapped strategy IS the strategy returned by `strategyFor()`. Callers — generated `@Decorator` classes, `SimulatingAction`, and any future strategy consumers — call `strategy.resolve()` directly on the wrapped strategy, and the `onResolved()` notification fires automatically. No caller changes required.

**Exception behavior:** If `resolve()` throws, `onResolved()` is not called — failed resolutions are not counted. This is correct: a `SimulationKeyNotFoundException` or other resolution failure should not advance `LookupCountSelector`'s counter.

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
9. Runtime: `PhasedCorpus` throws `SimulationConfigException` if `activePhase()` returns a name not in the phases map
10. State machine (warning): phases not reachable from `initial` via the transition graph are logged as warnings at parse time — likely a missing transition in the configuration

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
- Selector persistence across overlay cycles:
  - `StateMachineSelector`: advance state, push/pop overlay, verify state preserved
  - `LookupCountSelector`: resolve N times, push/pop overlay, verify count not reset
  - `DurationSelector`: resolve, push/pop overlay, verify start time not restarted
  - `stateMachineSelector(qn)` returns the same instance before and after overlay push/pop

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
- Playbook step lifecycle wiring (connecting step completion events to `StateMachineSelector.advance()`) — #730
- CDI event observer wiring for event-triggered transitions — #731
- MCP tool for runtime phase inspection / manual trigger — #732
- Per-phase `corpus-files` (external file references within phases) — #733
- Profile-level corpus-selection (phases that span multiple methods) — #734

Note: issue #729 should remain open after this scope — the "event-triggered selector" acceptance criterion (#730, #731) is explicitly deferred to follow-up work. This scope delivers the selector infrastructure; wiring comes next.

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
