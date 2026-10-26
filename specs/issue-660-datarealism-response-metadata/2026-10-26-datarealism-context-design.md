# DataRealism Request-Scoped Context — Design Spec

**Issue:** casehubio/platform#660
**Branch:** issue-660-datarealism-response-metadata
**Date:** 2026-10-26

## Background

The simulation framework already carries `DataRealism` levels through the system:
- `JournalEntry` records `DataRealism dataRealism` per SPI call
- `SimulationStrategy.dataRealism()` declares each strategy's realism level
- `SimulationDecoratorProcessor` generates code that passes the correct level to `SimulationRuntime.recordJournal()`
- `SimulationRuntime.fallthroughRealism()` provides configurable levels for delegate fallthrough paths

What's missing: a way for callers to check the realism level of the most recent SPI call **at call time**, without querying the overlay journal. The journal is overlay-scoped and post-hoc; some consumers (agent frameworks, demo UIs) need to inspect realism inline to adjust behavior.

## Design

### DataRealismContext (simulation-core)

A plain mutable POJO — no ThreadLocal, no framework annotations.

```java
package io.casehub.platform.simulation;

public class DataRealismContext {

    public record Observation(String qualifiedName, DataRealism dataRealism) {}

    private Observation current;

    public void set(String qualifiedName, DataRealism dataRealism) {
        current = new Observation(qualifiedName, dataRealism);
    }

    public Observation current() {
        return current;
    }

    public DataRealism dataRealism() {
        return current != null ? current.dataRealism() : null;
    }
}
```

Thread isolation is provided by the CDI/Spring scope mechanism, not by ThreadLocal. Each request gets its own instance.

### CDI Producer (simulation-config)

In `SimulationConfigBeans`:

```java
@Produces
@RequestScoped
public DataRealismContext dataRealismContext() {
    return new DataRealismContext();
}
```

### Spring Producer

In the spring auto-configuration (generated or hand-written):

```java
@Bean
@RequestScope
@ConditionalOnMissingBean
public DataRealismContext dataRealismContext() {
    return new DataRealismContext();
}
```

### Generator Change (SimulationDecoratorProcessor)

The `generateDecoratorSource` method adds one new field to every generated decorator:

```java
@Inject DataRealismContext dataRealismContext;
```

The `generateSimulatedMethod` method adds `dataRealismContext.set(...)` in both the strategy-resolved and fallthrough paths, alongside the existing `recordJournal()` calls:

**Strategy-resolved path (non-void):**
```java
Object simResult = strategy.get().resolve(input);
simulation.recordJournal(qualifiedName, __simTenancyId, input, simResult, strategy.get().dataRealism());
dataRealismContext.set(qualifiedName, strategy.get().dataRealism());
return (ReturnType) simResult;
```

**Fallthrough path (non-void):**
```java
ReturnType result = delegate.method(args);
DataRealism __ftRealism = simulation.fallthroughRealism(qualifiedName);
simulation.recordJournal(qualifiedName, __simTenancyId, input, result, __ftRealism);
dataRealismContext.set(qualifiedName, __ftRealism);
return result;
```

Note: `fallthroughRealism()` result is captured in a local variable to avoid calling it twice. The strategy-resolved path doesn't need this — `strategy.get().dataRealism()` is a constant per strategy instance.

Void variants follow the same pattern.

### Wrapper Inner Classes

The capability wrapper inner classes (static inner classes for `@SimulationEligible(capabilities=...)`) do NOT inject `DataRealismContext` — they are static and don't have CDI injection. Instead, they receive the context via constructor parameter, same as they already receive `SimulationRuntime` and `CurrentPrincipal`.

The wrapper constructor adds `DataRealismContext dataRealismContext` as a fourth parameter. The capability accessor method passes it through.

### Standalone Tests

Tests without CDI/Spring create `DataRealismContext` manually and inject via reflection — the same pattern `DataRealismEndToEndTest` already uses for `CurrentPrincipal` and `SimulationRuntime`:

```java
var context = new DataRealismContext();
inject(decorator, "dataRealismContext", context);

// after SPI call:
assertThat(context.current().dataRealism()).isEqualTo(DataRealism.STRUCTURALLY_VALID);
```

## Scope

### In scope
- `DataRealismContext` class in simulation-core
- `@Produces @RequestScoped` in SimulationConfigBeans
- Spring auto-config bean (generated or hand-written)
- SimulationDecoratorProcessor changes (inject + set)
- DataRealismEndToEndTest updates (inject context, verify it's set)
- New unit test for DataRealismContext itself

### Out of scope
- No changes to JournalEntry, SimulationStrategy, InvocationJournal, SimulationRuntime, or any concrete strategy — these are already complete
- No consumer-side usage of DataRealismContext — that's for connectors#171

## Module Impact

| Module | Change |
|--------|--------|
| simulation-core | New `DataRealismContext` class + test |
| simulation-config | `@Produces @RequestScoped` in SimulationConfigBeans |
| simulation-generator | Inject + set DataRealismContext in generated decorators |
| platform-simulation-core | Update DataRealismEndToEndTest |
| simulation-config-spring (if exists) | Spring @RequestScope bean |

## References

- SimulationDecoratorProcessor.java:332-416 — generateSimulatedMethod (where set() calls go)
- SimulationDecoratorProcessor.java:142-206 — generateDecoratorSource (where @Inject field goes)
- SimulationDecoratorProcessor.java:220-247 — generateWrapperInnerClass (constructor change for capabilities)
- SimulationRuntime.java:141-157 — recordJournal + fallthroughRealism (unchanged)
- SimulationConfigBeans.java:63-69 — existing @Produces pattern
- DataRealismEndToEndTest.java — existing test pattern for manual injection
- casehubio/platform#660 — parent issue
- connectors#171 — downstream consumer (life-domain simulation corpuses)
