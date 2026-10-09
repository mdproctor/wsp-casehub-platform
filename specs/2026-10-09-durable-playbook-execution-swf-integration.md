# Durable Playbook Execution — SWF Java SDK Integration Spec

**Issue:** #566
**Date:** 2026-10-09

## Goal

Give CaseHub playbooks durable, transactional, retry-safe execution by
embedding the CNCF Serverless Workflow Java SDK (`~/dev/swf-sdk-java`)
as a library. The CaseHub runtime hosts the SWF engine — not the other
way around. The playbook YAML, decorator chain, and step resolver do not
change.

## The SDK: What We Get for Free

The SWF Java SDK is a CompletableFuture-based runtime with extensive
SPIs. Key findings from code inspection:

### Execution Model

Not a state machine walker — it's a **linked executor chain** with
CompletableFuture composition. `WorkflowApplication` (builder) →
`WorkflowDefinition` (parsed) → `WorkflowMutableInstance` (running).
Each task returns `CompletableFuture<TaskContext>` chained via
`thenCompose`.

### SPIs We'll Use

| SPI | How CaseHub Uses It |
|-----|-------------------|
| `CallableTaskBuilder` (ServiceLoader) | **Primary integration seam.** CaseHub registers a builder that delegates to `DecoratorChain` for step execution. |
| `PersistenceInstanceStore` | **Durability.** Pluggable state store — SDK ships `mvstore` (embedded H2) and `bigmap` (distributed). We add our own backed by PostgreSQL or Redis. |
| `EventConsumer` / `EventPublisher` (ServiceLoader) | **Events.** Bridge `OrcSignal`/`OrcChannel` to CloudEvents for cross-process communication. Default `InMemoryEvents` works for single-process. |
| `ExpressionFactory` (ServiceLoader) | **Expression evaluation.** Register CaseHub's `VariableResolver` + `ConditionEvaluator` alongside the SDK's JQ engine. |
| `TaskExecutorFactory` (ServiceLoader) | **Custom task types.** Register CaseHub-specific task executors for `at:`, `background:`, `cancel:` behaviours that have no SWF equivalent. |
| `WorkflowExecutionListener` (ServiceLoader) | **Audit trail.** Hook lifecycle events for compliance logging — every task start/complete/fail/retry is captured. |
| `CallableTaskProxyBuilder` (ServiceLoader) | **Decorator wrapping.** Intercept all callable tasks to apply CaseHub decorators (resource contention, priority, threshold gates). |

### SPIs We Don't Need (SDK Handles It)

| Concern | SDK Mechanism |
|---------|--------------|
| Retry with backoff | `RetryExecutor` + `RetryIntervalFunction` (constant, exponential, linear) |
| Per-task timeout | `CompletableFuture.orTimeout()` in `AbstractTaskExecutor` |
| Error handling | `TryExecutor` with catch filters and error matching |
| Parallel execution | `ForkExecutor` — `CompletableFuture.allOf` on branches |
| Sequential execution | `DoExecutor` — linked executor chain |
| Conditional branching | `SwitchExecutor` — data conditions |
| Iteration | `ForExecutor` — sequential/parallel with while/do |
| Checkpoint/resume | `WorkflowPersistenceInstance.restoreContext()` — completed tasks skipped, retrying tasks re-executed |

## Integration Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                    CaseHub Playbook Runtime                    │
│                                                               │
│  Playbook YAML ──→ Playbook Compiler ──→ SWF WorkflowDefinition │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │              SWF Java SDK (embedded library)             │  │
│  │                                                         │  │
│  │  WorkflowApplication                                    │  │
│  │    ├── TaskExecutorFactory ← CaseHubTaskExecutorFactory  │  │
│  │    ├── CallableTaskBuilder ← CaseHubCallableTaskBuilder │  │
│  │    ├── PersistenceInstanceStore ← PostgresPersistence    │  │
│  │    ├── EventConsumer/Publisher ← CloudEventBridge        │  │
│  │    ├── ExpressionFactory ← CaseHubExpressionFactory     │  │
│  │    └── WorkflowExecutionListener ← AuditLogger          │  │
│  └─────────────────────┬───────────────────────────────────┘  │
│                        │                                      │
│              ┌─────────┴─────────┐                            │
│              │  PrimitiveFactory  │ ← shared state layer      │
│              │  (Durable impls)   │                            │
│              └───────────────────┘                            │
└───────────────────────────────────────────────────────────────┘
```

## The Playbook Compiler

The compiler translates CaseHub YAML into SWF `Workflow` objects via
the fluent API (no SWF YAML generation). It runs at parse time.

### What maps directly

| CaseHub YAML | SWF Fluent API |
|-------------|----------------|
| Step sequence (block) | `tasks(do(...))` — DoExecutor chain |
| `if:` guard | `switch_(dataCondition(...))` — SwitchExecutor |
| `match:` | `switch_(dataCondition(...))` with multiple conditions |
| `parallel:` | `fork(branches(...))` — ForkExecutor |
| `forEach:` | `for_(...)` — ForExecutor |
| `retry:` | `try_(do(...)).retry(...)` — TryExecutor + RetryExecutor |
| `timeout:` | Task-level timeout property |
| `on-error:` | `try_(do(...)).catch_(...)` — TryExecutor catch handler |
| `signal:/wait:` | `emit(...)` / `listen(...)` — CloudEvent publish/subscribe |
| `on-complete:` | Already desugared to signal/wait before compilation |
| `loop: { until: }` | `for_(...).do_(...).while_(...)` — ForExecutor |
| `loop: continuous` | `for_(...).do_(...).while_(alwaysTrue)` |
| `delay:` | `wait_(duration)` — WaitExecutor |

### What needs CaseHub-side execution

These features have no SWF equivalent. The compiler wraps them as
CaseHub `CallableTask` implementations that the SDK invokes but CaseHub
executes internally:

| CaseHub Feature | Compilation Strategy |
|-----------------|---------------------|
| `at:` (threshold gate) | CaseHub `CallableTask` that blocks on `OrcNumericPrimitive.onThresholdChange()` |
| `resource:/priority:` | CaseHub `CallableTask` that acquires `PriorityOrcSemaphore` before delegating to inner step |
| `background:` | CaseHub `CallableTask` that calls `scope.spawn()` and returns immediately |
| `cancel:` | CaseHub `CallableTask` that registers signal watcher, delegates to inner, interrupts on signal |
| `from:` (channel read) | CaseHub `CallableTask` that calls `channel.receive()` |
| `forEach: { collect: all }` | CaseHub `CallableTask` that iterates and accumulates results |

The `CallableTaskProxyBuilder` SPI wraps these around the standard SWF
task execution — so a step with `retry: 3` + `resource: minerals` gets:
- SWF handles the retry (RetryExecutor)
- CaseHub proxy handles the resource contention (PriorityOrcSemaphore)

### Compilation example

```yaml
# CaseHub YAML
- action: process-claim
  at: >=100 pending-claims
  resource: claims-api
  priority: high
  retry: { max: 3, on: [TIMEOUT] }
  timeout: 30s
```

Compiles to (pseudo-fluent):
```java
tasks(
  try_(
    do_(
      casehubTask("process-claim")        // CallableTask via CaseHubCallableTaskBuilder
        .withDecorators(Map.of(
            "at", ">=100 pending-claims",  // CaseHub handles via proxy
            "resource", "claims-api",      // CaseHub handles via proxy
            "priority", "high"))           // CaseHub handles via proxy
    )
    .retry(retryPolicy()
        .maxAttempts(3)
        .retryableErrors("TIMEOUT")       // SWF handles
        .exponentialBackoff())
  ).timeout(Duration.ofSeconds(30))       // SWF handles
)
```

SWF owns: retry, timeout, checkpoint, resume.
CaseHub owns: threshold gate, resource contention, priority.
Both execute within the same `CompletableFuture` chain.

## Durable Primitives

The `PrimitiveFactory` SPI gains durable implementations. The choice
is configured per-playbook or per-environment:

### Option A: Database-backed (PostgreSQL)

```java
public class PostgresPrimitiveFactory implements PrimitiveFactory {
    // OrcCounter → SELECT/UPDATE on counter_primitives table
    // OrcFlag → SELECT/UPDATE on flag_primitives table
    // OrcSignal → INSERT into signal_events + LISTEN/NOTIFY
    // PriorityOrcSemaphore → SELECT FOR UPDATE with priority ordering
}
```

**Pro:** Transactional consistency with SWF persistence (same database).
**Con:** Latency (network round-trip per primitive operation).

### Option B: Redis-backed

```java
public class RedisPrimitiveFactory implements PrimitiveFactory {
    // OrcCounter → INCR
    // OrcFlag → SET/GET
    // OrcSignal → PUB/SUB
    // OrcChannel → XADD/XREAD (Redis Streams)
    // PriorityOrcSemaphore → Sorted Set + WATCH/MULTI
}
```

**Pro:** Low latency, natural fit for pub/sub and streams.
**Con:** Separate consistency domain from SWF persistence.

### Option C: Hybrid

- Slow primitives (flags, counters that change rarely) → PostgreSQL
  (consistent with SWF state)
- Fast primitives (channels, signals, frequently-updated counters) →
  Redis (low latency)

### Listener observation on durable primitives

`OrcNumericPrimitive.onThresholdChange()` on a durable counter needs
cross-process notification. Options:
- PostgreSQL: `LISTEN/NOTIFY` on counter mutations
- Redis: Keyspace notifications or PUB/SUB on counter key changes
- Both: the `DurableOrcCounter` fires local listeners AND publishes
  a notification. Remote processes subscribe and fire their local
  `at:` decorator listeners.

## Recovery: What Happens on Crash

1. **SWF persistence restores the workflow position.** Completed tasks
   are marked done. The current task is re-executed (or retried if it
   was mid-retry).

2. **Durable primitives retain their values.** The supply counter is
   still at 14. The flag is still set. The channel still has pending
   items.

3. **`background:` tasks are re-spawned.** The SWF persistence
   listener records active background tasks. On recovery,
   `WorkflowPersistenceInstance.restoreContext()` re-spawns them from
   the saved task definitions.

4. **`cancel:` signal watchers are re-registered.** On recovery, the
   CaseHub `CallableTaskProxy` re-registers signal watchers for any
   step that has `cancel:`. If the signal already fired (persisted
   in durable store), the task is cancelled immediately.

5. **`at:` thresholds are re-evaluated.** On recovery, the decorator
   checks the current durable counter value. If the threshold is
   already met, execution proceeds immediately. If not, the listener
   re-registers.

## What We Might Request as SDK Enhancements

| Enhancement | Why | Feasibility |
|------------|-----|-------------|
| Priority-aware task scheduling | `ForkExecutor` runs all branches equally — no priority | Medium — add priority to branch definition |
| Threshold-gated task start | No concept of "wait for a data condition to become true" | Medium — combine `listen` + data condition |
| Background/spawn task type | No "start and continue" — all tasks block | Hard — changes the executor chain model |
| Structured cancellation by signal | Cancellation is workflow-level only | Medium — add per-task cancellation scope |
| Custom retry predicate | `retryableErrors` matches error names, not categories | Easy — add predicate-based retry filter |

Most of these can be emulated via `CallableTaskBuilder` /
`CallableTaskProxyBuilder` without SDK changes. Enhancements would
make them first-class SWF features, benefiting the broader ecosystem.

## What We Must Build

| Component | Size | Description |
|-----------|------|-------------|
| `PlaybookCompiler` | L | Translates CaseHub YAML → SWF `Workflow` via fluent API |
| `CaseHubCallableTaskBuilder` | M | ServiceLoader-registered builder that delegates to DecoratorChain |
| `CaseHubCallableTaskProxy` | M | Wraps CaseHub decorators (at:, resource:, cancel:) around any callable |
| `CaseHubExpressionFactory` | S | Bridges VariableResolver + ConditionEvaluator to SWF expression SPI |
| `DurablePrimitiveFactory` | L | PostgreSQL and/or Redis implementations of all primitives |
| `DurableOrc*` implementations | L | Per-primitive durable adapters with cross-process notification |
| `CloudEventBridge` | M | Bridges OrcSignal/OrcChannel to SWF EventConsumer/EventPublisher |
| `BackgroundTaskRecovery` | M | Persists and re-spawns background tasks on crash recovery |
| `AuditListener` | S | WorkflowExecutionListener for compliance audit trail |
| `PersistenceStore` adapter | M | PostgreSQL-backed PersistenceInstanceStore (or use SDK's mvstore) |

## What Does NOT Change

- Playbook YAML syntax — identical
- Decorator chain — identical
- Step resolver — identical
- StepSchemaComposer — identical
- JSON Schema — identical
- TS DSL — identical (compiles to same YAML)
- Plugin API — identical (`@StepPlugin`, `Result`, `Action`)
- In-process execution mode — still works (DefaultPrimitiveFactory)

## Execution Mode Selection

```java
// Ephemeral (current — in-process, no persistence)
var app = PlaybookRuntime.builder()
    .ephemeral()
    .build();

// Durable (SWF engine + PostgreSQL persistence)
var app = PlaybookRuntime.builder()
    .durable()
    .persistence(PostgresPersistence.create(dataSource))
    .primitives(PostgresPrimitiveFactory.create(dataSource))
    .build();

// Hybrid (SWF for durable steps, in-process for real-time)
var app = PlaybookRuntime.builder()
    .hybrid()
    .persistence(PostgresPersistence.create(dataSource))
    .primitives(RedisPrimitiveFactory.create(redisClient))
    .build();
```

The playbook author doesn't choose. The runtime configuration does.
Same YAML, different execution backend.

## Phased Delivery

### Phase 1: Compilation + Basic Durability
- PlaybookCompiler (YAML → SWF Workflow via fluent API)
- CaseHubCallableTaskBuilder (delegate to DecoratorChain)
- PersistenceStore (use SDK's mvstore for embedded persistence)
- Checkpoint/resume for sequential playbooks

### Phase 2: Durable Primitives
- PostgresPrimitiveFactory (counters, flags, gauges)
- Cross-process notification for `at:` thresholds
- Background task persistence and recovery

### Phase 3: Full Integration
- CloudEventBridge (signals ↔ CloudEvents)
- Redis-backed channels and semaphores
- Priority-aware scheduling enhancements (SDK PR)
- Audit trail listener for FSI compliance

## References

- SWF Java SDK: `~/dev/swf-sdk-java` (local clone)
- SDK source: https://github.com/serverlessworkflow/sdk-java
- SWF Spec: https://serverlessworkflow.io/
- #562, #563, #564 — CaseHub language primitives
- #566 — parent issue for this work
- Key SDK classes:
  - `io.serverlessworkflow.impl.WorkflowApplication` — entry point
  - `io.serverlessworkflow.api.CallableTaskBuilder` — primary integration SPI
  - `io.serverlessworkflow.api.CallableTaskProxyBuilder` — decorator SPI
  - `io.serverlessworkflow.impl.persistence.PersistenceInstanceStore` — state persistence SPI
  - `io.serverlessworkflow.impl.events.EventConsumer/EventPublisher` — event SPIs
  - `io.serverlessworkflow.impl.expressions.ExpressionFactory` — expression SPI
  - `io.serverlessworkflow.impl.executors.AbstractTaskExecutor` — base executor
  - `io.serverlessworkflow.experimental.fluent.func.FuncWorkflowBuilder` — fluent API
