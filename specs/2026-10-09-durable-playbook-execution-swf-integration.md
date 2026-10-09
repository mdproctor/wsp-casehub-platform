# Durable Playbook Execution — SWF Java SDK Integration Spec

**Issue:** #566
**Date:** 2026-10-09

## Goal

Give CaseHub playbooks durable, transactional, retry-safe execution by
embedding the CNCF Serverless Workflow Java SDK (`~/dev/swf-sdk-java`)
as a library. The CaseHub runtime hosts the SWF engine — not the other
way around. The playbook YAML, decorator chain, and step resolver do not
change.

## SWF 1.0 vs CaseHub: Honest Comparison

SWF 1.0 is task-based (NOT the state-machine model of 0.8). It uses
`do:` for sequencing, `fork:` for parallel, `for:` for iteration,
`try:` for error handling. Closer to CaseHub than 0.8, but composition
is still structural (nesting), not annotational (decorators).

**Side-by-side: retry + timeout + forEach**

SWF 1.0:
```yaml
do:
  - processItems:
      try:
        - iterateItems:
            for:
              each: item
              in: '.items'
            do:
              - processItem:
                  call: process
                  with:
                    item: ${ $item }
                  timeout:
                    after: PT30S
      catch:
        errors:
          with:
            type: https://serverlessworkflow.io/errors/timeout
        retry:
          delay: PT1S
          backoff:
            exponential: {}
          limit:
            attempt:
              count: 3
```

CaseHub:
```yaml
- action: process
  forEach: { in: items, as: item }
  retry: { max: 3, backoff: exponential, delay: 1s }
  timeout: 30s
```

SWF 1.0 nests `try:` around `for:` around `do:` around `call:` — 4
levels. CaseHub puts 3 decorators on 1 step — flat.

**Where SWF 1.0 `switch:` differs from CaseHub `if:`:**

SWF 1.0 uses goto-style routing (`then: taskName`):
```yaml
do:
  - decide:
      switch:
        - approve:
            when: '.amount <= 1000'
            then: autoApprove
        - review:
            when: '.amount > 1000'
            then: managerReview
  - autoApprove:
      call: approve-expense
      then: end
  - managerReview:
      call: request-approval
      then: end
```

CaseHub uses per-step guards (no goto, no named targets):
```yaml
- action: approve-expense
  if: "${amount} <= 1000"

- action: request-approval
  if: "${amount} > 1000"
  timeout: 48h
```

SWF 1.0 requires naming each branch target and wiring `then:` →
target. CaseHub guards each step independently — the sequencing is
implicit. CaseHub's model is simpler for non-programmers.

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

## Consistency Under Crash and Restart

The core problem: SWF checkpoints at task boundaries. CaseHub-side
execution happens WITHIN a task. If the process crashes mid-task, SWF
re-executes the entire task. Each CaseHub feature must handle this
correctly.

### Per-Feature Crash Analysis

**`at:` (threshold gate):**
Crash while blocked → SWF re-executes → decorator re-checks counter.
If counter is durable, value is preserved — correct behaviour. If
counter is ephemeral, value is zero — blocks forever. **Rule:** any
counter referenced by `at:` MUST use a durable primitive in durable
mode.

**`resource:/priority:` (contention):**
Crash while holding semaphore → semaphore never released → deadlock.
**Solution:** durable semaphores use lease-based TTL. The lock expires
automatically on crash. On restart, SWF re-executes → decorator
re-acquires fresh. Lease renewal heartbeat prevents premature expiry
during legitimately long steps. **Rule:** durable
`PriorityOrcSemaphore` uses lease + heartbeat, not permanent locks.

**`background:` (spawn):**
Crash after spawn returned success → SWF sees task completed → skips
on restart. But spawned task is gone. **Solution:** in durable mode,
`background:` persists the task definition BEFORE returning success.
On recovery, the runtime reads persisted definitions and re-spawns.
**Rule:** background task registration and SWF checkpoint must be
atomic (same transaction).

**`cancel:` (signal-triggered):**
Crash after signal fired but before step responded → on restart, SWF
re-executes → decorator re-registers watcher. If signal is durable,
`isSignalled()` returns true → immediate cancellation (correct). If
signal is ephemeral → forgotten → step runs uncancelled. **Rule:**
signals used with `cancel:` MUST be durable.

**`from:` (channel read):**
Crash after reading message but before step completed → message
consumed, result not checkpointed → message lost on restart.
**Solution:** two-phase read — read without acknowledgment, process
step, acknowledge + SWF checkpoint in same transaction. Requires
channel backend to support transactional acknowledgment (Kafka
consumer offsets, Redis XACK). **Rule:** `from:` in durable mode
needs at-least-once delivery. Steps must be idempotent, OR channel
and SWF persistence share a transaction.

**`forEach: { collect: all }`:**
Crash mid-iteration → SWF re-executes entire task → all iterations
re-run. **Better approach:** compile `forEach` to SWF's native `for:`
construct in durable mode (SDK's `ForExecutor` checkpoints per
iteration). **Rule:** in durable mode, `forEach` compiles to SWF
`for:`, not the CaseHub decorator.

### The Consistency Boundary

**SWF checkpoint and durable primitive mutations must be in the same
transaction.**

```
┌─ Transaction ─────────────────────────────────────────┐
│  1. CaseHub step executes (inside CallableTask)       │
│  2. Primitive mutations (counter++, flag set)         │
│  3. SWF checkpoint (task completed, position advances) │
│  4. Channel message acknowledged                      │
│  5. Background task definition persisted               │
│  COMMIT                                               │
└───────────────────────────────────────────────────────┘
```

If ALL of these use the same PostgreSQL database, this is a single
ACID transaction. If primitives are in Redis, atomicity is lost and
compensating mechanisms are needed (reconciliation on recovery).

**Recommendation:** Phase 1 uses PostgreSQL for everything — SWF
persistence AND durable primitives. Same database, same transaction,
exact consistency. Redis is a Phase 3 optimisation for high-throughput
channels where PostgreSQL latency is unacceptable.

### SDK Persistence Model (verified from source)

The SDK uses **CRUD with explicit begin/commit/rollback** — NOT an
append-only log. The flow in `DefaultPersistenceInstanceWriter`:

```java
PersistenceInstanceTransaction tx = store.begin();
try {
    operation.accept(tx);  // writes: task status, output, context
    tx.commit(definition);
} catch (Exception ex) {
    tx.rollback(definition);
    throw ex;
}
```

Per checkpoint: task status (COMPLETED/RETRIED), output data, workflow
context, transition info, iteration count.

**Atomic co-persistence strategy:** CaseHub implements
`PersistenceInstanceStore` with a PostgreSQL backend. The `begin()`
method opens a JDBC transaction. CaseHub's durable primitives use the
SAME connection (via context-passing). `commit()` commits both SWF
state and primitive mutations atomically.

```java
public class CaseHubPersistenceStore implements PersistenceInstanceStore {
    private final DataSource dataSource;

    public PersistenceInstanceTransaction begin() {
        Connection conn = dataSource.getConnection();
        conn.setAutoCommit(false);
        // Store conn in thread-local — durable primitives read it
        TransactionContext.setCurrent(conn);
        return new PostgresTransaction(conn);
    }
}

// DurableOrcCounter uses the same connection:
public class DurableOrcCounter implements OrcCounter {
    public void increment() {
        Connection conn = TransactionContext.current();
        // UPDATE counter_primitives SET value = value + 1 WHERE ...
        // Same transaction as the SWF checkpoint
    }
}
```

No SDK changes required. CaseHub implements the existing SPI with
a connection-sharing strategy. The SDK doesn't care what else happens
in the transaction — it just calls `commit()`.

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

## SDK Runtime Enhancements (to make integration clean)

These are SDK-internal enhancements, not spec changes — they improve
the Java implementation's extensibility without changing the SWF
specification. Ranked by integration impact.

### 1. Decouple Persistence from Execution (Critical)

Currently persistence is coupled to the executor chain — you must go
through `WorkflowApplication → WorkflowDefinition →
WorkflowMutableInstance` to get checkpoint/resume. CaseHub needs to
use the persistence layer as a standalone library: "checkpoint this
state, resume from this checkpoint" without routing through SWF's
`DoExecutor`/`ForkExecutor`.

This would let CaseHub run its own `DecoratorChain` while the SDK's
persistence machinery handles checkpoint/resume. CaseHub owns the
execution; the SDK owns the durability.

### 2. Custom State Entries on TaskContext (High)

`TaskContext` carries workflow data as `WorkflowModel` (a JSON blob).
If CaseHub could register typed state entries — "persist this counter
value at `.primitives.supply`", "persist this flag at
`.primitives.ready`" — primitive state would be automatically
checkpointed with the workflow data. One JSON document holds
everything. No separate persistence mechanism for primitives.

This eliminates the need for `DurablePrimitiveFactory` entirely —
primitive state lives in the workflow data and is checkpointed by the
SDK.

### 3. Resume Lifecycle Hooks (High)

On crash recovery, the SDK skips completed tasks and re-executes the
current one. But CaseHub needs to restore its runtime state BEFORE
re-execution starts:

- Re-register `cancel:` signal watchers
- Re-spawn `background:` tasks from saved definitions
- Reconnect to durable primitive values
- Re-register `at:` threshold listeners

A `WorkflowResumeListener` SPI with `onBeforeResume(instance)` would
give CaseHub the hook to restore state before the executor chain
restarts.

### 4. Pluggable Executor Passthrough Mode (High)

`TaskExecutorFactory` creates executors per task type. If there was a
"passthrough" mode where the factory says "I'll handle this task
entirely — just give me the lifecycle hooks (checkpoint on complete,
retry on fail)" — CaseHub could register its `DecoratorChain` as the
executor for all CaseHub task types. The SDK manages lifecycle;
CaseHub manages execution. Clean boundary.

```java
// CaseHub registers a factory that handles all CaseHub tasks
public class CaseHubExecutorFactory implements TaskExecutorFactory {
    public boolean accept(TaskBase task) {
        return task instanceof CaseHubTask;
    }

    public TaskExecutor create(TaskBase task, ...) {
        return new PassthroughExecutor(task, decoratorChain,
            // lifecycle callbacks from SDK:
            onComplete -> persistence.checkpoint(task, result),
            onFail -> persistence.recordFailure(task, error),
            onRetry -> persistence.recordRetry(task, attempt));
    }
}
```

### 5. Transaction Participation on Checkpoint (Medium)

Expose the active transaction from `PersistenceInstanceStore` so
external code can participate in the same commit. A
`getActiveTransaction()` method or pre/post-commit hooks would let
CaseHub's primitive mutations commit atomically with the SDK's
checkpoint.

Currently achievable by implementing `PersistenceInstanceStore` with
a shared JDBC connection (described in Atomic co-persistence strategy
above), but a first-class SPI would be cleaner.

### 6. Interruptible Task Execution (Medium)

The SDK uses `CompletableFuture.orTimeout()` for timeouts — which
completes the future exceptionally but does NOT interrupt the
underlying thread. CaseHub's `cancel:` uses `Thread.interrupt()`.
If `AbstractTaskExecutor` interrupted the execution thread on timeout
(not just timed out the future), CaseHub's interrupt-based
cancellation would compose naturally with SDK-managed timeouts.

Has workarounds — CaseHub can manage its own interrupt inside the
`CallableTask` — but first-class support eliminates the impedance.

### Impact Summary

| Enhancement | Impact | Spec change? | Difficulty |
|---|---|---|---|
| Decouple persistence | Critical | No | Medium |
| Custom state entries | High | No | Easy |
| Resume hooks | High | No | Easy |
| Executor passthrough | High | No | Medium |
| Transaction participation | Medium | No | Easy |
| Interruptible execution | Medium | No | Easy |

With #1 and #4, CaseHub's runtime becomes: "DecoratorChain + SWF
persistence." No impedance mismatch, no dual persistence, no adapter
layers. CaseHub runs the orchestration; the SDK checkpoints the state.

### Additional Enhancements That Eliminate CaseHub Build Work

These would remove items from the "What We Must Build" list entirely:

**7. PostgreSQL Persistence Module**

The SDK ships MVStore (embedded H2) and bigmap (distributed). A
PostgreSQL `PersistenceInstanceStore` implementation would eliminate
`PersistenceStore adapter` from the CaseHub build list. PostgreSQL
is the production default for most CaseHub deployments — having it
in the SDK saves every user from building their own.

**8. Background Task Registry in Persistence**

If the SDK tracked spawned/detached tasks in its persistence model
(a list of active background task definitions alongside the workflow
state), crash recovery could re-spawn them automatically. Combined
with resume hooks (#3), this eliminates `BackgroundTaskRecovery`
from the CaseHub build list entirely.

**9. Pluggable Variable Resolution (not just JQ)**

The SDK's `ExpressionFactory` defaults to JQ. If it supported
registering additional variable resolution strategies (not replacing
JQ but augmenting it), CaseHub's `VariableResolver` could be plugged
in directly. `${counter.supply}` would resolve through CaseHub's
`PrimitiveVariableSource` while `.data.field` still resolves through
JQ. Eliminates `CaseHubExpressionFactory` from the build list.

**10. Primitive-to-CloudEvent Auto-Publishing**

If the SDK supported change notifications on workflow data entries
(when `.primitives.supply` changes, emit a CloudEvent), CaseHub's
`OrcNumericPrimitive.onThresholdChange()` listeners could be wired
to workflow data mutations. The `CloudEventBridge` would be
unnecessary — primitive observation flows through the SDK's event
system.

**11. Decorator-Level Lifecycle Events**

`WorkflowExecutionListener` fires events at task level (started,
completed, failed). If it also fired at decorator level (retry
attempt, timeout triggered, resource acquired/released, threshold
reached), the `AuditListener` would get compliance-grade audit
trails from the SDK without CaseHub adding its own instrumentation.

### What the full enhancement set eliminates

| CaseHub Build Item | Eliminated By | Status |
|---|---|---|
| `PlaybookCompiler` | — (needed regardless) | Must build |
| `CaseHubCallableTaskBuilder` | #4 Executor passthrough | Eliminated |
| `CaseHubCallableTaskProxy` | #4 Executor passthrough | Eliminated |
| `CaseHubExpressionFactory` | #9 Pluggable variable resolution | Eliminated |
| `DurablePrimitiveFactory` | #2 Custom state entries | Eliminated |
| `DurableOrc*` implementations | #2 Custom state entries | Eliminated |
| `CloudEventBridge` | #10 Primitive-to-event publishing | Eliminated |
| `BackgroundTaskRecovery` | #3 Resume hooks + #8 Background registry | Eliminated |
| `AuditListener` | #11 Decorator-level events | Simplified |
| `PersistenceStore` adapter | #7 PostgreSQL module | Eliminated |

With all 11 enhancements, CaseHub builds only: **the PlaybookCompiler**
(YAML → SDK API) and a **simplified AuditListener** (decorator-level
events → compliance log). Everything else is SDK infrastructure.

The question is: how many of these enhancements benefit the broader
SWF community vs. being CaseHub-specific? #1, #4, #7, #9 benefit
everyone. #2, #3, #5, #6 are generally useful. #8, #10, #11 are more
niche but defensible as "rich execution observability."

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

## Future: Structured Table Editor for Playbook Authoring

The playbook language has three authoring surfaces: YAML (power users),
TS DSL (programmers), and — eventually — a structured table editor
(non-programmers). The table editor is not a flowchart. It's a
constrained projectional editor where the schema defines what's valid
at every position.

### The model

- A **step** is a row
- A **decorator** is a column (if, at, resource, priority, loop, retry, timeout, cancel, background)
- **Nesting** (on-complete, block, parallel) expands as indented sub-tables under the parent row
- **Sequence** is top-to-bottom row order
- **Resources** are a header table above the steps

```
Resources: [minerals: 1] [gas: 1] [nexus: 1]

┌───┬──────────────┬────────────┬──────────┬──────────┬────────────┬───────┬────┐
│ # │ action       │ at         │ resource │ priority │ loop       │ retry │ bg │
├───┼──────────────┼────────────┼──────────┼──────────┼────────────┼───────┼────┤
│ 1 │ train PROBE  │            │ minerals │ bg       │ continuous │       │ ✓  │
│ 2 │ build PYLON  │ >=14 supply│ minerals │ high     │            │       │    │
│ 3 │ build GATE   │ >=150 min  │ minerals │ high     │            │       │    │
│   └─ on-complete:                                                            │
│   │ 4 │ train STALKER│         │ gateway  │ normal   │            │ 3     │    │
└───┴──────────────┴────────────┴──────────┴──────────┴────────────┴───────┴────┘
```

### Keyboard interaction (structural, not free-text)

- **Arrow keys** move between step rows and decorator columns
- **Enter** on an empty cell opens valid-values picker for that column
  (e.g., resource column shows declared resources; priority shows
  background/normal/high)
- **Tab** cycles through decorator slots on the current step
- **dd** deletes a step row
- **p** pastes below cursor
- **>** indents step into a block/on-complete under the step above
- **<** outdents step from its parent block
- **Drag** rows to reorder; drag into a block to nest

Every keystroke produces a valid AST mutation — not a string edit that
might or might not parse. Invalid states are unconstructable. The
schema IS the editor constraint, enforced at interaction time rather
than validation time.

### Mouse interaction

- Click a cell to edit (dropdown for enums, text for values)
- Click + icon at bottom to add a step
- Right-click for context menu (add block, add on-complete, wrap in
  parallel, add decorator column)
- Drag row handle to reorder
- Drag row into another row's indent zone to nest

### Why this matters

YAML is too free — you can typo `priortiy: high` and discover it at
runtime. The TS DSL requires programming literacy. The structured
table is the authoring surface for the widest audience: constrained
enough to prevent invalid playbooks, visual enough to see all
behaviours at a glance, keyboard-efficient enough for power users.

Three surfaces, one runtime:
- **YAML** — version control, LLM generation, CI/CD
- **TS DSL** — programmers, closures, type safety
- **Structured table** — everyone else

Export from table to YAML is serialisation of the grid state. Import
from YAML to table is parsing into the grid model. Round-trip fidelity
is guaranteed by the shared AST.

Buildable on the existing casehub-pages grid infrastructure. Not a
priority for the current phase — captured here for future reference.

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
