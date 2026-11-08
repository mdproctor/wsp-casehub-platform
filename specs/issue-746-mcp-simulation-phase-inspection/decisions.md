# Decisions — #746 MCP Simulation Phase Inspection

## D1: Module placement

**Choice:** Add `CorpusSelectorService` to `event-simulation/` alongside `TemporalDriverService`
**Alternatives:**
- Separate module — unnecessary overhead for 3 operations on existing runtime
- `simulation-config/` — wrong layer; config produces beans, doesn't expose MCP surfaces
**Rationale:** `event-simulation/` already has the graphql-generator APT, Quarkus REST deps, and the exact same dependency chain (simulation-config → simulation-core → SimulationRuntime). Follows the existing `TemporalDriverService` pattern exactly.
**Trade-offs:** None significant — same module, same pattern.
**Sources:** event-simulation/pom.xml, TemporalDriverService.java
**Exploration:** quick
**Status:** captured

## D2: CorpusSelector API extensions

**Choice:** Add `type()` and `reset()` default methods to `CorpusSelector` interface (simulation-api)
**Alternatives:**
- `instanceof` checks in MCP service — brittle, violates OCP, requires MCP layer to know all selector types
- Separate `Resettable` interface — over-engineering for 4 implementations
**Rationale:** Default methods keep backward compatibility. `type()` returns a human-readable string for MCP status. `reset()` defaults to no-op so selectors with no meaningful reset (RandomSelector) don't need to override.
**Trade-offs:** Slight API surface increase in simulation-api, but these are introspection/debug methods consistent with the debugging purpose of #746.
**Sources:** CorpusSelector.java, StateMachineSelector.java, DurationSelector.java, LookupCountSelector.java, RandomSelector.java
**Exploration:** quick
**Status:** captured

## D3: SimulationRuntime accessor methods

**Choice:** Add `allSelectorPhases()`, `resetSelector(qualifiedName)`, per-selector `advanceStateMachine(qualifiedName, trigger)` to SimulationRuntime
**Alternatives:**
- Expose raw `corpusSelectors` map — breaks encapsulation, exposes internal ConcurrentHashMap
- Move all logic to the MCP service — would require public accessor for the map anyway
**Rationale:** SimulationRuntime already owns the selector registry. Adding query/mutation methods keeps the responsibility in the right place. The MCP service stays thin (delegation only).
**Trade-offs:** Three new public methods on SimulationRuntime, but they're natural extensions of the existing `stateMachineStates()` and `advanceStateMachines()` methods.
**Sources:** SimulationRuntime.java:246-268 (existing state machine methods)
**Exploration:** quick
**Depends on:** D2 (type/reset on CorpusSelector)
**Status:** captured
