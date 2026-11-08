# MCP Tool for Runtime Simulation Phase Inspection

**Issue:** casehubio/platform#746
**Scale:** S | **Complexity:** Low

## Summary

Add MCP tools to inspect and control corpus selector phases at runtime. Three operations — list active selectors with their phases, manually advance state machine transitions, and reset selectors to initial state — exposed as a new `@McpDomain("corpus-selectors")` in the `event-simulation` module.

## Architecture

### Layer 1 — simulation-api (CorpusSelector interface)

Add two default methods to `CorpusSelector`:

```java
default String type() { return "unknown"; }
default void reset() {}
```

`type()` returns a human-readable selector kind for MCP status output. `reset()` defaults to no-op for selectors where reset is meaningless (RandomSelector).

### Layer 2 — simulation-core (selector implementations + SimulationRuntime)

**Selector implementations:**

| Selector | `type()` | `reset()` behaviour |
|----------|----------|---------------------|
| StateMachineSelector | `"state-machine"` | CAS currentState back to stored initial value |
| DurationSelector | `"duration"` | Reset startNanos via AtomicLong (change from final long) |
| LookupCountSelector | `"lookup-count"` | Set resolveCount AtomicInteger to 0 |
| RandomSelector | `"weighted"` | No-op (stateless per-call) |

**StateMachineSelector** needs a new `private final String initial` field to remember the initial state for reset.

**DurationSelector** needs `startNanos` changed from `final long` to `AtomicLong` to support reset.

**SimulationRuntime** new public methods:

```java
// All selectors — not just state machines
public Map<String, SelectorPhaseInfo> allSelectorInfo()

// Reset a specific selector
public void resetSelector(String qualifiedName)

// Advance a specific state machine (vs broadcast)
public void advanceStateMachine(String qualifiedName, String trigger)
```

`SelectorPhaseInfo` is a new record in simulation-core: `(String type, String activePhase)`.

### Layer 3 — event-simulation (MCP domain)

New `CorpusSelectorService @ApplicationScoped @McpDomain("corpus-selectors")`:

| Operation | Annotation | Description |
|-----------|------------|-------------|
| `list()` | `@PlatformQuery` | List all active corpus selectors with type and current phase |
| `status(qualifiedName)` | `@PlatformQuery` | Get status of a specific selector |
| `advance(request)` | `@PlatformMutation` | Trigger a state machine transition (specific selector + trigger) |
| `reset(qualifiedName)` | `@PlatformMutation` | Reset a selector to its initial state |

**Request/response records:**

- `CorpusSelectorStatus(String qualifiedName, String type, String activePhase)` — returned by list/status
- `CorpusSelectorAdvanceRequest(String qualifiedName, String trigger)` — input for advance

**Error handling:**
- Unknown qualifiedName → `NotFoundException`
- Advance on non-state-machine → `IllegalArgumentException`

**POM change:** Update `domainFilter` compiler arg from `temporal-drivers` to `temporal-drivers,corpus-selectors`.

## Testing

**simulation-core unit tests:**
- `StateMachineSelector`: reset returns to initial state
- `DurationSelector`: reset restarts the timer
- `LookupCountSelector`: reset zeroes the counter
- `SimulationRuntime`: `allSelectorInfo()`, `resetSelector()`, `advanceStateMachine()` with known selectors

**event-simulation Quarkus test:**
- `CorpusSelectorServiceTest` — `@QuarkusTest` injecting the service, verifying list/status/advance/reset operations. Follows `TemporalDriverServiceTest` pattern. Requires a simulation.yaml on the test classpath that declares at least one state-machine corpus-selection config.

## References

- `event-simulation/src/main/java/.../TemporalDriverService.java` — MCP domain pattern
- `simulation-api/src/main/java/.../CorpusSelector.java` — interface to extend
- `simulation-core/src/main/java/.../SimulationRuntime.java:215-268` — existing selector methods
- `simulation-core/src/main/java/.../selector/` — all four selector implementations
