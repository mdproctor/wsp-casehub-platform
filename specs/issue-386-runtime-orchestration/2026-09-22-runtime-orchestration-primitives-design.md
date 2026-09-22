# Runtime Orchestration Primitives — Design Spec

**Issue:** casehubio/platform#386
**Date:** 2026-09-22
**Status:** Draft

## Overview

Platform's yaml-core provides mature parse-time primitives (`ForEachExpander`, `VariableResolver`, `ModuleExpander`, `Truthiness`). These expand and resolve during YAML loading, producing flat structures.

Runtime orchestration requires evaluation against live state during execution — conditions checked at runtime, loops driven by dynamic data, coordination between concurrent steps. This spec defines the runtime primitives layer: interfaces in yaml-core (zero-dep, J2CL-safe), thread-safe implementations in a new `orchestration-core` module.

## Module Architecture

| Module | Contents | Dependencies |
|--------|----------|-------------|
| `yaml-core` | Runtime evaluation interfaces: `Condition`, `RuntimeForEach`, runtime `VariableSource` extensions | Zero (existing) |
| `orchestration-core` (new) | Coordination primitives: `Semaphore`, `Latch`, `Signal`, `Channel`, `Mutex`, `StateMachine`. Thread-safe via `java.util.concurrent` | JDK only |

**Why two modules:** yaml-core is J2CL-transpilable (targets JavaScript, single-threaded). Coordination primitives need `j.u.c` for thread safety. Clean separation: contracts in yaml-core, concurrent implementations in orchestration-core.

Consumers (scenario-runtime in pages, agentic patterns in blocks) depend on both and compose step-level YAML keywords from these primitives.

## Design Philosophy

The orchestration language is designed for declarative intent. Each construct is individually simple. But complexity accumulates through composition — when you find yourself debugging YAML instead of reading it, extract to a `@ScenarioAction`.

Signs you've crossed the line:
- A single step has 4+ decorators
- Nesting beyond 2 levels
- Tracing data flow through 3+ variable interpolations
- Expressions that need their own unit tests

The language allows this (regular and recursive grammar), but documentation and showcase examples guide developers toward flat patterns and timely delegation to code.

---

## Part 1: Step Decorators

### 1.1 `when` — Conditional Guard

Execute a step only if a condition is true at runtime.

```yaml
- step: adapt-strategy
  when: ${regime} == 'MEAN_REVERTING'
  action: adjust-lookback
  data: { window: 12 }
```

**Evaluation:** The `when` expression is resolved via `VariableResolver` for interpolation, then evaluated by `ExpressionEngine`. Simple equality (`==`, `!=`) is built-in. Complex expressions use the configured engine (MVEL, JQ, JEXL).

**Semantics:**
- `when` evaluates to a boolean. Non-boolean results throw `ConditionEvaluationException`.
- A false `when` skips the step entirely — no action invoked, no side effects.
- `when` composes with all other decorators: evaluated first, before `loop`, `forEach`, `trigger`, etc.

**Test cases:**
```
whenTrue_executesStep
whenFalse_skipsStep
whenWithVariableInterpolation_resolvesBeforeEval
whenWithComplexExpression_usesMvel
whenNonBooleanResult_throwsException
whenComposedWithLoop_evaluatedOnceBeforeLoop
```

---

### 1.2 `loop` — Repetition

Repeat a step (or steps) with a count or exit condition.

**Count-based:**
```yaml
- step: warm-up-cycle
  loop:
    count: 5
    delay: 2s
  action: emit-training-event
```

**Exit-condition-based:**
```yaml
- step: monitor-market
  loop:
    until: ${volatility} < 0.02
    max: 100
    delay: 5s
  action: check-volatility
```

**Multi-step body:**
```yaml
- step: monitoring-cycle
  loop:
    until: ${status} == 'STABLE'
    max: 50
  steps:
    - action: check-prices
    - action: assess-regime
    - action: emit-status
```

**Semantics:**
- `count` and `until` are mutually exclusive. Providing both throws `InvalidLoopException`.
- `max` is a safety limit for `until` loops. Default: 1000. Reaching `max` throws `LoopExhaustedException` unless `on-max: skip` is set.
- `delay` respects the scenario speed multiplier via `TemporalDriverService`.
- `until` is evaluated after each iteration (do-while semantics — the body always runs at least once).
- The loop exposes `${loop.index}` (0-based) and `${loop.iteration}` (1-based) as variables within the body.

**Test cases:**
```
loopCount_executesExactlyNTimes
loopCount_exposesIndexVariable
loopUntil_exitsWhenConditionMet
loopUntil_evaluatesAfterEachIteration (do-while)
loopUntil_reachesMax_throws
loopUntil_reachesMax_withOnMaxSkip_skips
loopWithDelay_respectsSpeedMultiplier
loopCountAndUntilBoth_throws
loopWithMultiStepBody_executesAllStepsPerIteration
loopWithWhen_guardEvaluatedOnceBeforeLoop
```

---

### 1.3 `forEach` — Collection Iteration

Iterate a step over a runtime-resolved collection.

```yaml
- step: evaluate-instruments
  forEach:
    in: ${instruments}
    as: instrument
  action: evaluate
  data:
    symbol: ${each.instrument.symbol}
```

**Multi-step body:**
```yaml
- step: process-instruments
  forEach:
    in: ${instruments}
    as: instrument
  steps:
    - action: fetch-price
      data: { symbol: ${each.instrument.symbol} }
    - action: evaluate-strategy
      data: { prices: ${result.fetch-price.prices} }
```

**Semantics:**
- `in` resolves at runtime to a list. If the resolved value is not iterable, throws `ForEachSourceException`.
- `as` defines the iteration variable name, accessible via `${each.<as>}` (same prefix as parse-time ForEachExpander).
- `${each.index}` (0-based) is always available.
- The runtime `forEach` extends the existing `ForEachExpander` pattern but resolves the collection from a live `VariableSource`, not from static YAML.
- Parallel iteration is opt-in: `parallel: true` runs iterations concurrently (default: sequential).

**Test cases:**
```
forEach_iteratesOverList
forEach_exposesIterationVariable
forEach_exposesIndex
forEach_emptyCollection_skipsStep
forEach_nonIterableSource_throws
forEach_withWhen_filtersPerIteration
forEach_parallel_executesConcurrently
forEach_parallel_collectsAllResults
forEach_withMultiStepBody_executesAllStepsPerItem
```

---

### 1.4 `delay` — Fixed Wait

Wait a fixed duration, respecting the speed multiplier.

```yaml
- step: cooldown
  delay: 5s
```

**Semantics:**
- Duration parsing: `ms`, `s`, `m`, `h` suffixes (reuse `DurationParser` from simulation-config-core).
- Respects `TemporalDriverService` speed multiplier: at speed 2x, a 5s delay waits 2.5s real time.
- `delay` on a step waits before executing the action. Use `delay` inside `loop` for inter-iteration pauses.

**Test cases:**
```
delay_waitsSpecifiedDuration
delay_respectsSpeedMultiplier
delay_parsesMilliseconds
delay_parsesMinutes
delay_invalidSuffix_throws
```

---

### 1.5 `timeout` — Deadline Decorator

Set a deadline on any step. Composes with `on-error` for fallback routing.

```yaml
- step: get-analysis
  timeout: 10s
  on-error: use-cached
```

```yaml
- step: wait-for-data
  trigger:
    type: data
    endpoint: /api/market/regime
    match: { regime: 'MEAN_REVERTING' }
  timeout: 60s
  on-error: skip-adaptation
```

**Semantics:**
- `timeout` wraps the step execution (including any trigger wait) with a deadline.
- On timeout, fires `StepTimeoutException`. If `on-error` is present, routes to the named step/action. If absent, the exception propagates.
- Respects the speed multiplier.
- Delegates to `PolicyEnforcer` internally for consistent timeout handling.

**Test cases:**
```
timeout_stepCompletesBeforeDeadline_succeeds
timeout_stepExceedsDeadline_throwsStepTimeoutException
timeout_withOnError_routesToFallback
timeout_respectsSpeedMultiplier
timeout_composedWithTrigger_coversWaitTime
```

---

### 1.6 `on-error` — Error Routing

Route to an alternative step on failure.

**Simple form:**
```yaml
- step: primary-analysis
  on-error: fallback-analysis
```

**Detailed form:**
```yaml
- step: primary-analysis
  on-error:
    goto: fallback-analysis
    log: "Primary analysis failed, using fallback"
```

**Typed error handling:**
```yaml
- step: call-external
  on-error:
    - match: TimeoutException
      goto: use-cached
    - match: RateLimitException
      goto: backoff-and-retry
    - otherwise:
      goto: abort
```

**Semantics:**
- Simple form: any exception routes to the named step.
- Detailed form: `goto` names the target step, `log` emits a message.
- Typed form: `match` checks the exception type (simple class name matching). `otherwise` is the catch-all. Evaluated top-to-bottom, first match wins.
- `on-error` catches exceptions from the step's action, not from decorators (a `when` evaluation failure is a configuration error, not a runtime error).

**Test cases:**
```
onError_simpleForm_routesToNamedStep
onError_detailedForm_logsAndRoutes
onError_typedMatch_routesByExceptionType
onError_typedMatch_firstMatchWins
onError_otherwise_catchesAll
onError_noMatch_propagatesException
onError_doesNotCatchDecoratorErrors
```

---

### 1.7 `retry` — Resilience Decorator

Retry a failed step with configurable backoff. Delegates to existing `PolicyEnforcer` / `ExecutionPolicy` from governance.

```yaml
- step: submit-order
  retry:
    max: 3
    backoff: exponential
    delay: 1s
```

**With circuit breaker:**
```yaml
- step: call-external-api
  retry:
    max: 5
    backoff: exponential-with-jitter
    delay: 500ms
    circuit-breaker:
      threshold: 5
      reset: 60s
    fallback: use-default
```

**Semantics:**
- `max` → `RetryPolicy.maxAttempts`. `delay` → `RetryPolicy.delayMs`. `backoff` → `BackoffStrategy` enum (fixed, exponential, exponential-with-jitter).
- `circuit-breaker` is an optional sub-field (not a separate keyword). Maps to `CircuitBreakerPolicy`.
- `fallback` names a step to route to when retries are exhausted (equivalent to `on-error` but scoped to retry exhaustion).
- Delegates to `PolicyEnforcer.execute(policy, callable)` — no reimplementation.

**Test cases:**
```
retry_succedsOnFirstAttempt_noRetry
retry_failsThenSucceeds_retriesCorrectly
retry_exhaustsRetries_throwsOrRoutes
retry_exponentialBackoff_delaysIncrease
retry_withCircuitBreaker_opensAfterThreshold
retry_withCircuitBreaker_resetsAfterWindow
retry_withFallback_routesOnExhaustion
retry_respectsSpeedMultiplierOnDelay
```

---

### 1.8 `trigger` — Unified Wait-For

Wait for a condition to become true. Unifies data triggers, time triggers, and event triggers under one keyword.

**Data trigger — poll an endpoint:**
```yaml
- step: wait-for-regime-shift
  trigger:
    type: data
    endpoint: /api/market/regime
    match: { regime: 'MEAN_REVERTING' }
    poll: 2s
    timeout: 60s
    fallback: skip-adaptation
```

**Time trigger — wait for simulated time:**
```yaml
- step: market-close
  trigger:
    type: time
    at: T+30s
```

**Absolute time:**
```yaml
- step: eod-report
  trigger:
    type: time
    at: "16:00"
```

**Event trigger — wait for a CloudEvent:**
```yaml
- step: wait-for-incident
  trigger:
    type: event
    source: ras
    eventType: io.casehub.fsitrading.situation.volatility-spike
    timeout: 120s
```

**Event trigger with data filter:**
```yaml
- step: wait-for-high-severity
  trigger:
    type: event
    eventType: io.casehub.alert.created
    filter: ${event.data.severity} == 'CRITICAL'
    timeout: 300s
```

**Semantics:**
- `type: data` — polls the endpoint at `poll` interval, checks `match` against response. `match` is a map of field→value checks (equality). For complex matching, use `filter` with an expression.
- `type: time` — `at` accepts relative (`T+30s`, `T+5m`) or absolute (`"16:00"`, `"2026-09-22T08:30:00"`). Respects speed multiplier. Integrates with `TemporalDriverService`.
- `type: event` — subscribes to CloudEvents matching `eventType` (and optionally `source`). `filter` applies an expression to the event data. Uses existing DataSource/subscription infrastructure.
- `timeout` and `fallback` compose naturally: timeout fires `TriggerTimeoutException`, `fallback` names the alternative step (or use `on-error` at the step level).
- A trigger without `timeout` waits indefinitely — this must be flagged with a warning at parse time.

**Test cases:**
```
triggerData_pollsUntilMatch
triggerData_timeout_throwsOrFallback
triggerData_pollInterval_respectsSpeedMultiplier
triggerData_matchMultipleFields
triggerData_withFilter_usesExpressionEngine
triggerTime_relative_waitsCorrectDuration
triggerTime_absolute_waitsUntilTime
triggerTime_respectsSpeedMultiplier
triggerEvent_matchesByType
triggerEvent_matchesByTypeAndSource
triggerEvent_withFilter_appliesExpression
triggerEvent_timeout_throws
triggerNoTimeout_emitsWarningAtParseTime
```

---

### 1.9 `transform` — Scoped Data Reshape

Single-expression transform for keeping simple data reshaping in YAML. Uses the configured `ExpressionEngine`.

```yaml
- step: enrich
  transform: "{ symbol: $.instrument, price: $.last_trade }"
  engine: jq
```

**With explicit input:**
```yaml
- step: reshape
  transform:
    input: ${result.fetch.body}
    expression: ".prices | map({ symbol: .sym, close: .last })"
    engine: jq
```

**Semantics:**
- Simple form: expression operates on the step's input data (previous step result or step `data`).
- Detailed form: `input` names the source, `expression` is the transform, `engine` selects the expression engine (default: jq).
- **Scoping rule:** the expression must be a one-liner. If the transform needs conditional logic, multiple fields from different sources, or iteration — use a `@ScenarioAction` instead.
- The result of the transform replaces the step's output (available as `${result.<step-name>}`).

**Test cases:**
```
transform_simpleExpression_reshapesData
transform_withExplicitInput_usesNamedSource
transform_jqEngine_evaluatesCorrectly
transform_mvelEngine_evaluatesCorrectly
transform_resultAvailableAsStepResult
transform_invalidExpression_throwsWithClearMessage
```

---

## Part 2: Coordination Primitives

All coordination primitives are interfaces in `orchestration-core`. Implementations are thread-safe via `java.util.concurrent`. Each primitive is designed to be execution-model-agnostic — the interface contract works for both virtual-thread and async-event implementations.

### 2.1 `Semaphore` — Concurrency Control

Limits concurrent access to a shared resource.

```java
public interface OrcSemaphore {
    void acquire() throws InterruptedException;
    boolean tryAcquire(long timeout, TimeUnit unit) throws InterruptedException;
    void release();
    int availablePermits();
}
```

**YAML usage (step-level):**
```yaml
- step: call-api
  semaphore:
    name: api-calls
    permits: 3
  action: fetch-market-data
```

**Rate limiting (time-windowed semaphore):**
```yaml
- step: emit-ticks
  semaphore:
    name: tick-rate
    permits: 10
    per: 1s
  action: emit-price-tick
```

**Semantics:**
- Named semaphores are shared across all steps in a scenario. Same name = same semaphore instance.
- `permits` is the max concurrent acquisitions. Default: 1 (mutex behavior).
- `per` adds a time window — permits are replenished at the specified rate (subsumes `rateLimit` from issue).
- Acquisition blocks until a permit is available (or timeout from step-level `timeout`).

**Test cases:**
```
semaphore_acquireAndRelease_basic
semaphore_blocksWhenNoPermits
semaphore_releasesOnStepCompletion (even on error)
semaphore_namedSharing_sameNameSameInstance
semaphore_differentNames_independent
semaphore_withTimeWindow_replenishesPermits
semaphore_tryAcquireTimeout_returnsFalse
concurrent_multipleThreadsRespectPermitLimit
concurrent_noDeadlockUnderContention
```

---

### 2.2 `Latch` — Countdown Synchronization

Wait for N signals before proceeding. Foundation for barrier and quorum patterns.

```java
public interface OrcLatch {
    void countDown();
    void await() throws InterruptedException;
    boolean await(long timeout, TimeUnit unit) throws InterruptedException;
    long getCount();
}
```

**YAML usage (as `barrier` sugar):**
```yaml
- step: await-all-strategies
  barrier:
    await: [momentum-eval, risk-eval, compliance-check]
    timeout: 30s
```

**YAML usage (as `quorum` sugar):**
```yaml
- step: consensus
  quorum:
    required: 2
    of: [strategy-a-vote, strategy-b-vote, strategy-c-vote]
    timeout: 15s
```

**Semantics:**
- `barrier` creates a latch with count = number of awaited steps. Each named step's completion calls `countDown()`. The barrier step blocks on `await()`.
- `quorum` creates a latch with count = `required`. Same countdown mechanics, but proceeds before all steps complete.
- Steps named in `await` or `of` must exist in the scenario. Missing step names throw `UnknownStepException` at parse time.
- The latch is created when the first awaited step starts (lazy init, not at scenario load).

**Test cases:**
```
latch_countDown_decrementsCount
latch_await_blocksUntilZero
latch_await_timeout_returnsFalse
barrier_awaitsAllNamedSteps
barrier_stepCompletionOrder_doesNotMatter
barrier_timeout_throwsOrFallback
barrier_unknownStepName_throwsAtParseTime
quorum_proceedsOnRequiredCount
quorum_doesNotWaitForAll
quorum_requiredGreaterThanOf_throwsAtParseTime
concurrent_multipleCountdowns_safeUnderContention
concurrent_awaitAndCountdown_noDeadlock
```

---

### 2.3 `Signal` — Named Notification

One step signals another to proceed. One-shot or repeatable.

```java
public interface OrcSignal {
    void signal();
    void signal(Object payload);
    void await() throws InterruptedException;
    boolean await(long timeout, TimeUnit unit) throws InterruptedException;
    Object payload();
    boolean isSignalled();
}
```

**YAML usage (as `race` sugar):**
```yaml
- step: race-data-feeds
  race: [primary-feed, backup-feed]
  timeout: 5s
```

**Explicit signal/wait:**
```yaml
- step: producer
  action: generate-data
  signal: data-ready

- step: consumer
  wait: data-ready
  action: process-data
  data: { input: ${signal.data-ready.payload} }
```

**Semantics:**
- `race` creates a signal per named step. First signal wins — the race step proceeds with the winner's result, other steps receive a cancellation signal.
- `signal: <name>` emits a named signal on step completion. `wait: <name>` blocks until the signal is received.
- Signals can carry a payload, accessible via `${signal.<name>.payload}`.
- One-shot signals (default) can only be signalled once. Repeatable signals (for pub/sub patterns) are opt-in: `signal: { name: tick, repeatable: true }`.

**Test cases:**
```
signal_signalAndAwait_basic
signal_awaitBeforeSignal_blocksUntilSignalled
signal_withPayload_payloadAccessible
signal_oneShotSignal_secondSignalIgnored
signal_repeatableSignal_multipleSignals
race_firstCompletionWins
race_otherStepsReceiveCancellation
race_timeout_throwsOrFallback
race_allStepsFail_propagatesFirstError
concurrent_signalAndAwait_safeUnderContention
```

---

### 2.4 `Channel<T>` — Typed Data Passing

Pass data between concurrent steps. Bounded or unbounded.

```java
public interface OrcChannel<T> {
    void send(T value) throws InterruptedException;
    boolean send(T value, long timeout, TimeUnit unit) throws InterruptedException;
    T receive() throws InterruptedException;
    T receive(long timeout, TimeUnit unit) throws InterruptedException;
    boolean isEmpty();
    void close();
}
```

**YAML usage:**
```yaml
- step: producer
  loop:
    count: 10
  action: generate-event
  publish:
    channel: events
    data: ${result}

- step: consumer
  loop:
    until: ${channel.events.closed}
  subscribe:
    channel: events
  action: process-event
  data: { event: ${channel.events.value} }
```

**Semantics:**
- Named channels are shared across steps. Same name = same channel instance.
- `publish` sends to a channel. `subscribe` receives from a channel. Both block when the channel is full/empty (backpressure).
- Bounded channels: `channel: { name: events, capacity: 100 }`. Default: unbounded.
- `close()` signals no more data — receivers see `closed = true` after draining.
- Channels are typed at the Java interface level but untyped in YAML (everything is `Map<String, Object>`).

**Test cases:**
```
channel_sendAndReceive_basic
channel_blocksOnFullBounded
channel_blocksOnEmptyReceive
channel_close_drainThenClosed
channel_namedSharing_sameNameSameInstance
channel_unbounded_neverBlocksOnSend
concurrent_producerConsumer_safeUnderContention
concurrent_multipleProducers_allDataDelivered
concurrent_multipleConsumers_eachItemDeliveredOnce
```

---

### 2.5 `Mutex` — Exclusive Section

Exclusive access to a named resource.

```java
public interface OrcMutex {
    void lock() throws InterruptedException;
    boolean tryLock(long timeout, TimeUnit unit) throws InterruptedException;
    void unlock();
    boolean isLocked();
}
```

**YAML usage:**
```yaml
- step: update-portfolio
  mutex: portfolio-state
  action: recalculate-positions
```

**Semantics:**
- Named mutexes are shared across steps. Same name = same mutex instance.
- The mutex is acquired before the step action and released after (even on error — finally semantics).
- Not reentrant by default. A step that holds a mutex and attempts to acquire it again deadlocks (this is detectable and throws `MutexReentrancyException`).
- Use when multiple concurrent steps must not modify the same state simultaneously.

**Test cases:**
```
mutex_lockAndUnlock_basic
mutex_blocksWhenAlreadyLocked
mutex_releasedOnError (finally semantics)
mutex_reentrancy_throws
mutex_namedSharing_sameNameSameInstance
concurrent_exclusiveAccess_noRaceConditions
concurrent_tryLockTimeout_returnsFalse
```

---

### 2.6 `StateMachine` — State Transitions

Declare states, transitions, and guards. Atomic transitions via CAS.

```java
public interface OrcStateMachine<S extends Enum<S>> {
    S currentState();
    boolean transition(S from, S to);
    boolean transition(S from, S to, Object payload);
    void onTransition(S from, S to, TransitionHandler handler);
    void onEnter(S state, StateHandler handler);
    void onExit(S state, StateHandler handler);
}
```

**YAML usage:**
```yaml
stateMachine:
  name: order-lifecycle
  initial: pending
  transitions:
    - from: pending
      to: approved
      on: approve
      when: ${risk-score} < 0.8
    - from: pending
      to: rejected
      on: reject
    - from: approved
      to: shipped
      on: ship
    - from: approved
      to: cancelled
      on: cancel
    - from: shipped
      to: delivered
      on: deliver
  terminal: [rejected, cancelled, delivered]
```

**Step integration:**
```yaml
- step: process-order
  action: evaluate-risk
  transition:
    machine: order-lifecycle
    event: approve
    on-guard-fail: manual-review
```

**Semantics:**
- `transitions` define valid state changes. Invalid transitions throw `IllegalTransitionException`.
- `when` on a transition is a guard condition — evaluated at transition time. If false, the transition is rejected (not an error — the state machine stays in its current state). `on-guard-fail` names a fallback step.
- `on` is the event name that triggers the transition. Steps fire events via the `transition` decorator.
- `terminal` states are declared explicitly. Attempting to transition from a terminal state throws.
- State transitions are atomic (CAS on `AtomicReference<State>`). No intermediate states are visible to observers.
- Transition handlers (`onTransition`, `onEnter`, `onExit`) fire after the CAS succeeds — they observe the committed state.
- State is queryable: `${machine.order-lifecycle.state}` resolves to the current state name.

**Test cases:**
```
stateMachine_initialState_isSet
stateMachine_validTransition_changesState
stateMachine_invalidTransition_throws
stateMachine_guardCondition_preventsTransition
stateMachine_guardCondition_onGuardFail_routesToStep
stateMachine_terminalState_rejectsTransitions
stateMachine_transitionHandler_firesAfterCommit
stateMachine_onEnter_firesOnStateEntry
stateMachine_onExit_firesOnStateExit
stateMachine_stateQueryable_viaVariableResolver
concurrent_atomicTransition_noDuplicateStates
concurrent_competingTransitions_exactlyOneWins
concurrent_observersSeeCOmmittedStateOnly
```

---

## Part 3: Extended Existing Primitives

### 3.1 Runtime `VariableSource` — Live State Resolution

Extend `VariableResolver` with runtime sources that resolve from live state, not static YAML.

**New variable prefixes:**
```
${result.<step-name>.<field>}   — previous step result
${loop.index}                   — current loop iteration (0-based)
${loop.iteration}               — current loop iteration (1-based)
${each.<as>.<field>}            — current forEach item (already exists)
${machine.<name>.state}         — state machine current state
${signal.<name>.payload}        — signal payload
${channel.<name>.value}         — last received channel value
${channel.<name>.closed}        — channel closed flag
${env.<key>}                    — environment/config value
```

**Semantics:**
- Runtime sources are registered as `VariableSource` implementations, scoped to the execution context.
- The resolver tries prefixes in registration order. Runtime prefixes (`result`, `loop`, `machine`, `signal`, `channel`) are registered by the orchestration runtime, not by the YAML author.
- Deferred prefix handling (already in `VariableResolver`) allows parse-time validation to flag unknown prefixes while deferring runtime-only prefixes.

**Test cases:**
```
runtimeSource_resultPrefix_resolvesFromStepResult
runtimeSource_loopPrefix_resolvesIndexAndIteration
runtimeSource_machinePrefix_resolvesCurrentState
runtimeSource_signalPrefix_resolvesPayload
runtimeSource_channelPrefix_resolvesValueAndClosed
runtimeSource_unknownPrefix_throws
runtimeSource_deferredPrefix_passesThrough
```

---

## Part 4: Composition Examples

### 4.1 Golden Path — Each Primitive Standalone

Each example demonstrates one keyword in the simplest possible form.

**Traffic light cycle (loop + delay):**
```yaml
scenario: traffic-light
steps:
  - step: cycle
    loop:
      count: 10
    steps:
      - step: red
        action: set-light
        data: { color: red }
        delay: 30s
      - step: amber
        action: set-light
        data: { color: amber }
        delay: 5s
      - step: green
        action: set-light
        data: { color: green }
        delay: 25s
```

### 4.2 Two-Primitive Composition — Clean

**Poll with retry (trigger + retry):**
```yaml
- step: wait-for-service
  trigger:
    type: data
    endpoint: /health
    match: { status: UP }
    poll: 5s
  timeout: 60s
  retry:
    max: 3
    backoff: exponential
    delay: 10s
  on-error: service-unavailable
```

**Guarded iteration (when + forEach):**
```yaml
- step: process-active-instruments
  when: ${market-open} == 'true'
  forEach:
    in: ${instruments}
    as: instrument
  action: evaluate
  data: { symbol: ${each.instrument.symbol} }
```

### 4.3 Three-Primitive Composition — The Boundary

**This is where documentation says "consider extracting to code":**

```yaml
# Acceptable — each decorator serves a clear purpose
- step: resilient-batch-process
  forEach:
    in: ${items}
    as: item
  retry:
    max: 2
    backoff: fixed
    delay: 1s
  timeout: 30s
  action: process-item
  data: { id: ${each.item.id} }
```

**This crosses the line — extract to @ScenarioAction:**

```yaml
# Too much — loop with nested forEach, conditional transform, retry
- step: complex-processing
  loop:
    until: ${status} == 'DONE'
    max: 50
  steps:
    - forEach:
        in: ${batch}
        as: item
      when: ${each.item.active} == 'true'
      action: process
      transform: ".result | { id: .itemId, score: .confidence * 100 }"
      retry:
        max: 3
        backoff: exponential
        delay: 500ms
```

**Better as code:**
```java
@ScenarioAction("complex-processing")
public void complexProcessing(ScenarioContext ctx) {
    while (!ctx.resolve("status").equals("DONE")) {
        for (var item : ctx.resolveList("batch")) {
            if (item.get("active").equals("true")) {
                var result = policyEnforcer.execute(
                    retryPolicy, () -> process(item));
                // transform in Java is clear, debuggable, testable
            }
        }
    }
}
```

### 4.4 Coordination Showcase

**Multi-agent consensus (barrier + quorum + race):**
```yaml
scenario: strategy-consensus
steps:
  - step: momentum-eval
    action: evaluate-momentum
    data: { portfolio: ${portfolio} }

  - step: risk-eval
    action: evaluate-risk
    data: { portfolio: ${portfolio} }

  - step: compliance-check
    action: check-compliance
    data: { portfolio: ${portfolio} }

  - step: await-all
    barrier:
      await: [momentum-eval, risk-eval, compliance-check]
      timeout: 30s

  - step: consensus
    quorum:
      required: 2
      of: [momentum-eval, risk-eval, compliance-check]
      timeout: 15s
    action: aggregate-votes
```

**Producer-consumer with backpressure (channel + loop + semaphore):**
```yaml
scenario: event-pipeline
steps:
  - step: producer
    loop:
      count: 100
    action: generate-event
    publish:
      channel: events
    semaphore:
      name: event-rate
      permits: 10
      per: 1s

  - step: consumer
    loop:
      until: ${channel.events.closed}
    subscribe:
      channel: events
    action: process-event

  - step: finalise
    barrier:
      await: [consumer]
    action: generate-report
```

**State machine driven workflow:**
```yaml
scenario: approval-workflow
stateMachine:
  name: approval
  initial: draft
  transitions:
    - from: draft
      to: submitted
      on: submit
    - from: submitted
      to: approved
      on: approve
      when: ${approver-count} >= 2
    - from: submitted
      to: rejected
      on: reject
    - from: approved
      to: published
      on: publish
  terminal: [rejected, published]

steps:
  - step: submit-document
    action: submit-for-review
    transition:
      machine: approval
      event: submit

  - step: collect-reviews
    forEach:
      in: ${reviewers}
      as: reviewer
    action: request-review
    data: { reviewer: ${each.reviewer} }

  - step: evaluate-reviews
    action: tally-approvals
    transition:
      machine: approval
      event: approve
      on-guard-fail: await-more-reviews

  - step: publish
    when: ${machine.approval.state} == 'approved'
    action: publish-document
    transition:
      machine: approval
      event: publish
```

---

## Test Organisation

Tests follow the existing yaml-core test structure. Add to existing test classes where primitives extend existing concepts.

| Test class | Module | Coverage |
|---|---|---|
| `TruthinessTest` (extend) | yaml-core | `when` condition evaluation via Truthiness |
| `VariableResolverTest` (extend) | yaml-core | Runtime variable sources (result, loop, machine, signal, channel prefixes) |
| `ForEachExpanderTest` (extend) | yaml-core | Runtime forEach (dynamic collection resolution) |
| `ConditionEvaluatorTest` (new) | yaml-core | Expression-based condition evaluation, type coercion |
| `LoopEvaluatorTest` (new) | orchestration-core | Count loops, exit-condition loops, max safety, delay |
| `TriggerEvaluatorTest` (new) | orchestration-core | Data/time/event triggers, polling, timeout |
| `TransformEvaluatorTest` (new) | orchestration-core | Expression-based transforms, engine selection |
| `RetryDecoratorTest` (new) | orchestration-core | Retry with backoff, circuit breaker, PolicyEnforcer delegation |
| `OrcSemaphoreTest` (new) | orchestration-core | Permits, blocking, time-windowed replenishment |
| `OrcLatchTest` (new) | orchestration-core | Countdown, await, timeout |
| `OrcSignalTest` (new) | orchestration-core | Signal/await, payload, one-shot vs repeatable |
| `OrcChannelTest` (new) | orchestration-core | Send/receive, bounded backpressure, close semantics |
| `OrcMutexTest` (new) | orchestration-core | Lock/unlock, finally semantics, reentrancy detection |
| `OrcStateMachineTest` (new) | orchestration-core | Transitions, guards, terminal states, handlers |
| `ConcurrentSemaphoreTest` (new) | orchestration-core | Multi-thread contention on semaphore |
| `ConcurrentLatchTest` (new) | orchestration-core | Multi-thread countdown/await races |
| `ConcurrentSignalTest` (new) | orchestration-core | Multi-thread signal/await races |
| `ConcurrentChannelTest` (new) | orchestration-core | Producer-consumer under contention |
| `ConcurrentStateMachineTest` (new) | orchestration-core | Competing CAS transitions |
| `CompositionTest` (new) | orchestration-core | Two-primitive compositions (when+loop, trigger+timeout, forEach+retry) |
| `TippingPointTest` (new) | orchestration-core | Three-primitive compositions documenting the boundary |

---

## References

- `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ForEachExpander.java` — parse-time forEach, pattern for runtime extension
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java` — variable resolution with pluggable sources and deferred prefixes
- `yaml-core/src/main/java/io/casehub/yaml/core/condition/Truthiness.java` — boolean string evaluation
- `platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionEngine.java` — expression compilation SPI
- `platform-api/src/main/java/io/casehub/platform/api/governance/ExecutionPolicy.java` — retry/timeout/circuit-breaker records
- `governance-core/src/main/java/io/casehub/platform/governance/PolicyEnforcer.java` — policy enforcement SPI
- `simulation-core` — `TemporalDriverService` for speed-multiplied time
- casehubio/platform#386 — original issue with 21 proposed patterns
- casehubio/casehub-pages#461 — scenario model parsing (AfterTrigger wired, others parsed but unevaluated)
- D1–D6 in `decisions.md` — design decisions for this spec
