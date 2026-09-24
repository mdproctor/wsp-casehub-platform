# OrchestrationScope Bridge — Design Spec

**Issue:** casehubio/casehub-desiredstate#151
**Date:** 2026-09-24
**Status:** Draft

## Problem

yaml-core orchestration (ScenarioScope, primitives) and desiredstate's reconciliation loop are independent systems. There is no bridge that lets a provisioned node use orchestration primitives — semaphores, state machines, channels — scoped to its lifecycle. This blocks the agent pool use case and any future node type that needs runtime coordination.

## Design

### OrchestrationScope interface (desiredstate-api)

A new interface in `io.casehub.desiredstate.api` that mirrors `ScenarioScope` from yaml-core. No dependency on yaml-core — pure API contract.

```java
package io.casehub.desiredstate.api;

import java.time.Duration;
import java.util.Optional;
import java.util.Set;
import java.util.function.DoubleBinaryOperator;

public interface OrchestrationScope extends AutoCloseable {

    OrchestrationSemaphore semaphore(String name, int permits);
    OrchestrationSemaphore semaphore(String name, int permits, Duration window);
    OrchestrationLatch latch(String name, int count);
    OrchestrationSignal signal(String name);
    <T> OrchestrationChannel<T> channel(String name);
    <T> OrchestrationChannel<T> channel(String name, int capacity);
    <S extends Enum<S>> BlockingOrchestrationStateMachine<S> stateMachine(
            String name, Class<S> stateType, S initialState);
    OrchestrationCounter counter(String name);
    <T> OrchestrationGauge<T> gauge(String name);
    OrchestrationFlag flag(String name);
    OrchestrationAccumulator accumulator(String name, DoubleBinaryOperator op, double identity);
    <K, V> OrchestrationMap<K, V> map(String name);

    <T> T primitive(String name, Class<T> type);

    OrchestrationTask spawn(String name, Runnable task);

    OrchestrationScope childScope(String name);
    OrchestrationScope withDeadline(Duration deadline);
    OrchestrationScope withDeadline(Duration deadline, Runnable onDeadline);
    boolean isDeadlineExpired();
    Optional<Duration> remainingTime();

    @Override
    void close();
}
```

### Primitive interfaces (desiredstate-api)

Each orchestration primitive gets a corresponding interface in desiredstate-api, mirroring the yaml-core `Orc*` interfaces. These are thin — same method signatures, no implementation.

| desiredstate-api interface | yaml-core counterpart |
|---|---|
| `OrchestrationSemaphore` | `OrcSemaphore` |
| `OrchestrationLatch` | `OrcLatch` |
| `OrchestrationSignal` | `OrcSignal` |
| `OrchestrationChannel<T>` | `OrcChannel<T>` |
| `BlockingOrchestrationStateMachine<S>` | `BlockingOrcStateMachine<S>` |
| `OrchestrationStateMachine<S>` | `OrcStateMachine<S>` |
| `OrchestrationCounter` | `OrcCounter` |
| `OrchestrationGauge<T>` | `OrcGauge<T>` |
| `OrchestrationFlag` | `OrcFlag` |
| `OrchestrationAccumulator` | `OrcAccumulator` |
| `OrchestrationMap<K,V>` | `OrcMap<K,V>` |
| `OrchestrationTask` | `SpawnedTask` |

### Context integration (desiredstate-api)

`ProvisionContext` and `DeprovisionContext` gain a `scope()` accessor:

```java
// ProvisionContext additions
public OrchestrationScope scope() { ... }

// DeprovisionContext additions  
public OrchestrationScope scope() { ... }
```

The scope is the node's child scope — provisioners call `scope().semaphore("capacity", 10)` to get a node-private semaphore, or access shared graph-level primitives via the parent scope's primitives (which are resolved by name — same name in parent and child returns the parent's instance if the child hasn't created its own).

### Bridge adapter (desiredstate-runtime)

`ScenarioScopeAdapter` in desiredstate-runtime wraps `ScenarioScope` as `OrchestrationScope`:

```java
package io.casehub.desiredstate.runtime;

public class ScenarioScopeAdapter implements OrchestrationScope {
    private final ScenarioScope delegate;

    public ScenarioScopeAdapter(ScenarioScope delegate) {
        this.delegate = delegate;
    }

    @Override
    public OrchestrationSemaphore semaphore(String name, int permits) {
        return new OrcSemaphoreAdapter(delegate.semaphore(name, permits));
    }
    // ... each method delegates, wrapping return types in adapter classes
}
```

Each primitive adapter follows the same pattern — wraps the yaml-core primitive, delegates all methods.

### Lifecycle wiring (desiredstate-runtime)

**TenantLoop** (inner class of ReconciliationLoop):

```java
// New field
private volatile ScenarioScope rootScope;

void start() {
    // Create root scope for this tenant's graph
    this.rootScope = new DefaultScenarioScope("tenant:" + tenancyId);
    // ... existing start() logic
}

void stop() {
    // ... existing stop() logic
    if (rootScope != null) {
        rootScope.close();  // cascades to all child scopes
    }
}
```

**SimpleTransitionExecutor** (or a decorator/wrapper):

For each node provision step:
1. Create `childScope(nodeId.value())` from the root scope
2. Wrap in `ScenarioScopeAdapter`
3. Pass via `ProvisionContext`

For each node deprovision step:
1. Look up existing child scope for the node
2. Pass via `DeprovisionContext` (provisioner can clean up)
3. Close child scope after deprovision completes

**Scope registry:** The root scope's child scopes are keyed by node ID. The executor (or a new `ScopeRegistry` collaborator) maintains the mapping so deprovision can look up the scope created during provision.

### Concrete example — agent pool node

```java
public class PoolNodeProvisioner implements NodeProvisioner {

    @Override
    public ProvisionResult provision(DesiredNode node, ProvisionContext ctx) {
        OrchestrationScope scope = ctx.scope();

        // Node-private: capacity semaphore
        OrchestrationSemaphore capacity = scope.semaphore("capacity",
                node.spec().maxActive());

        // Node-private: per-session state tracking
        BlockingOrchestrationStateMachine<SessionState> lifecycle =
                scope.stateMachine("lifecycle", SessionState.class,
                        SessionState.IDLE);

        // Graph-shared: memory budget (created on root scope by another
        // provisioner or by graph-level setup)
        // Access via the scope — name resolution walks up to parent
        OrchestrationGauge<Long> memoryBudget = scope.gauge("memory-budget");

        // ... start the pool using these primitives
        return new ProvisionResult.Success();
    }
}
```

### NoOp fallback

`NoOpOrchestrationScope` as a `@DefaultBean` — returns no-op primitives. Provisioners that use scopes but run without yaml-core on the classpath get silent no-ops (same pattern as `NoOpCaseMemoryStore`). This keeps scope usage optional — existing provisioners that don't call `scope()` are unaffected.

## Module changes

| Module | Change |
|---|---|
| `desiredstate-api` | New: `OrchestrationScope`, all primitive interfaces, `OrchestrationTask`. Modified: `ProvisionContext`, `DeprovisionContext` |
| `desiredstate-runtime` | New: `ScenarioScopeAdapter`, primitive adapter classes, `ScopeRegistry`. Modified: `ReconciliationLoop.TenantLoop`, `SimpleTransitionExecutor` |
| `desiredstate-testing` | New: `InMemoryOrchestrationScope` test fixture |

## Out of scope

- ProcessExecutor primitive (separate issue)
- yaml-core changes (ScenarioScope already has everything needed)
- CaseTransitionExecutor scope integration (future — same pattern, just wired differently)

## References

- `yaml-core/src/main/java/.../orchestration/ScenarioScope.java` — the interface being mirrored
- `yaml-core/src/main/java/.../orchestration/DefaultScenarioScope.java` — the implementation the adapter delegates to
- `desiredstate/runtime/.../ReconciliationLoop.java` — lifecycle management target
- `desiredstate/api/.../ProvisionContext.java` — context object gaining scope accessor
- `platform-api/.../agent/AgentRuntime.java` — reference pattern for SPI + runtime adapter separation
