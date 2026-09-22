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
| `yaml-core` | Runtime evaluation contracts: `Condition`, `RuntimeForEach`, `ObjectVariableSource`, `SpeedMultiplier` SPI, `ConditionEvaluator` | Zero (existing) |
| `orchestration-core` (new) | Coordination primitives: `Semaphore`, `Latch`, `Signal`, `Channel`, `StateMachine`. Own `DurationParser` (same syntax as simulation-config-core, extended with `h`). Thread-safe via `java.util.concurrent` | JDK only |
| Consuming module (e.g. scenario-runtime) | Step decorator evaluators: `LoopEvaluator`, `TriggerEvaluator`, `TransformEvaluator`, `RetryDecorator`, `TimeoutDecorator`, `DelayEvaluator` | yaml-core, orchestration-core, platform-api, governance-core, simulation-core |

**Why three tiers:** yaml-core is J2CL-transpilable — it defines pure contracts with zero dependencies. Coordination primitives need `j.u.c` for thread safety but have no platform dependencies — `orchestration-core` is genuinely JDK-only. Step decorator evaluators compose platform services (`ExpressionEngine` from platform-api, `PolicyEnforcer` from governance-core, `SimulationRuntime.globalSpeed()` from simulation-core) with coordination primitives — they cannot be JDK-only and belong in the consuming module.

`ConditionEvaluator` is stateless and pure — it evaluates `when` expressions via `Truthiness` and delegates complex expressions to `ExpressionEngine` through a functional SPI (`java.util.function.Function<String, Boolean>`). It lives in yaml-core because its core logic is string truthiness evaluation; the expression engine binding happens at the consuming layer.

## Design Philosophy

The orchestration language is designed for declarative intent. Each construct is individually simple. But complexity accumulates through composition — when you find yourself debugging YAML instead of reading it, extract to a `@ScenarioAction`.

Signs you've crossed the line:
- A single step has 4+ decorators
- Nesting beyond 2 levels
- Tracing data flow through 3+ variable interpolations
- Expressions that need their own unit tests

The language allows this (regular and recursive grammar), but documentation and showcase examples guide developers toward flat patterns and timely delegation to code.

### Type Safety — The Ansible Differentiator

Ansible started as declarative configuration and accumulated `when`, `loop`, `until`, `block/rescue`, `register` — each individually reasonable, but together forming a Turing-complete language that's worse at being a language than Python and worse at being declarative than Terraform. The root cause: Ansible is not type-safe. Everything is Jinja2 string templating. Errors surface at runtime, deep into playbook runs.

Our primitives avoid this trap through typed Java interfaces:
- `ExpressionEngine.compile(expr, contextType, resultType)` — expressions type-checked at compile time
- `VariableResolver` with scoped prefixes — unknown prefixes fail at parse time, not runtime
- Step names in `barrier`, `race`, `quorum` — validated against the scenario definition at parse time
- `StateMachine` transitions — invalid transitions rejected before execution
- `OrcChannel<T>` — typed data passing, not string blobs
- `@ScenarioAction` escape hatch — when logic exceeds YAML's comfort zone, developers move to full Java with IDE support, debuggers, and type safety. Ansible has no equivalent native escape. **Prerequisite:** `@ScenarioAction` is defined in the scenario format spec (casehubio/platform#409). It does not exist in the codebase yet. The tipping-point guidance in §4.3 targets this mechanism — until #409 lands, "extract to code" means implementing the action as a regular Java method registered with the scenario engine.

This type safety is not optional. Every new primitive must be parse-time-validatable. If a construct can only report errors at runtime, it doesn't belong in the YAML surface — it belongs in Java code.

### Decorator Evaluation Order

When multiple decorators are present on a single step, they form a nesting stack — each decorator wraps the layer inside it. The canonical evaluation order, from outermost to innermost:

| Order | Decorator | Role | Phase |
|-------|-----------|------|-------|
| 1 | `when` | Guard — if false, skip entire step | Pre-execution |
| 2 | `forEach` | Iteration — creates per-item context; `when` re-evaluated per iteration | Structural |
| 3 | `loop` | Repetition — creates per-iteration context; `when` evaluated once before loop | Structural |
| 4 | `on-error` | Error handler — catches all runtime exceptions from layers below | Protection |
| 5 | `timeout` | Deadline — wraps everything below including trigger wait | Protection |
| 6 | `trigger` | Wait — blocks until precondition met | Pre-action |
| 7 | `retry` | Resilience — retries inner execution on failure | Protection |
| 8 | `semaphore` | Concurrency control — acquired before action, released after (finally). `mutex:` is sugar for `semaphore: { permits: 1 }` | Protection |
| 9 | `delay` | Pre-action pause | Pre-action |
| 10 | **action** | Step action executes | Execution |
| 11 | `signal`/`publish` | Post-action notification/data send | Post-action |
| 12 | `transition` | Post-action state machine event | Post-action |
| 13 | `transform` | Post-action data reshape | Post-action |

**Key semantics derived from this order:**
- `timeout` wraps `retry` — the deadline covers the entire retry sequence, not individual attempts. For per-attempt timeouts, use `retry.timeout` (delegated to `PolicyEnforcer`).
- `on-error` wraps `timeout` — timeout exceptions (`StepTimeoutException`) are catchable by `on-error`.
- `semaphore` is inside `retry` — the permit is re-acquired on each retry attempt, not held across the retry sequence.
- `trigger` is inside `timeout` — the trigger wait counts against the step's deadline.

**Fallback precedence:** Scoped fallbacks (`trigger.fallback`, `retry.fallback`) handle their specific exception types before the exception propagates. If a scoped fallback is set, `on-error` does not see that exception. If no scoped fallback is set, the exception propagates to `on-error`. Precedence: `trigger.fallback` > `retry.fallback` > `on-error` (each for its own exception type).

### Parallel Execution

Steps execute **sequentially** by default — the order in the YAML file determines execution order. Parallel execution is opt-in via the `parallel:` structural keyword:

```yaml
steps:
  - step: setup
    action: initialize

  - parallel:
      - step: momentum-eval
        action: evaluate-momentum
      - step: risk-eval
        action: evaluate-risk
      - step: compliance-check
        action: check-compliance

  - step: aggregate
    action: aggregate-results
```

**Semantics:**
- Steps within a `parallel:` block execute concurrently. The block completes when all steps **terminate** (implicit barrier). Termination means success, failure, or cancellation — a cancelled step (e.g. via `race` or `quorum` cancellation) counts as terminated. The implicit barrier waits for termination, not success. This prevents deadlocks when coordination primitives cancel losing steps inside the block.
- **Early-advance patterns:** `quorum` and `race` belong **inside** the `parallel:` block when early-advance semantics are needed. The coordination step launches alongside its referenced steps and waits for its condition (N-of-M for quorum, first-completion for race). When satisfied, it runs its action and optionally cancels remaining steps. The parallel block's implicit barrier then completes once all steps (including cancelled ones) have terminated.
- **Post-facto check:** `quorum` or `barrier` placed **after** a `parallel:` block is a post-facto success check — all steps have already terminated, and the check verifies that enough succeeded.
- `forEach: { parallel: true }` is the per-iteration parallelism mechanism (each iteration runs concurrently).
- The `parallel:` block is a structural keyword, not a step decorator — it appears at the same level as steps in the step list.

### Branching Patterns

D3 dropped `if/else` and `branches`. Simple conditional branching uses `when`-pair — two or more steps with mutually exclusive conditions:

```yaml
- step: handle-high
  when: ${risk-level} == 'HIGH'
  action: escalate

- step: handle-low
  when: ${risk-level} != 'HIGH'
  action: proceed
```

For 3+ branches, use a `StateMachine` (§2.6) with guarded transitions, or extract to a `@ScenarioAction` where Java's `switch`/`if-else` is clearer and more maintainable.

**Limitations of when-pairs:** Manually maintaining mutually exclusive conditions is error-prone for 3+ branches. This is intentional — it creates pressure toward `StateMachine` or `@ScenarioAction` at exactly the point where YAML branching becomes harder to read than code.

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
- `when` is the outermost decorator (see Decorator Evaluation Order). Composition with structural decorators:
  - `when` + `loop`: `when` evaluated **once** before the loop begins. If false, the entire loop is skipped.
  - `when` + `forEach`: `when` evaluated **per iteration**, within the forEach variable context. This matches the parse-time `ForEachExpander` semantics where `when` filters individual items — the guard can reference `${each.<as>}` variables.
  - `when` alone: evaluated once before the step action.

**Test cases:**
```
whenTrue_executesStep
whenFalse_skipsStep
whenWithVariableInterpolation_resolvesBeforeEval
whenWithComplexExpression_usesMvel
whenNonBooleanResult_throwsException
whenComposedWithLoop_evaluatedOnceBeforeLoop
whenComposedWithForEach_evaluatedPerIteration
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
- `max` is a safety limit for `until` loops. Default: 1000. Reaching `max` throws `LoopExhaustedException` unless `on-max: skip` is set. When `until` is specified without an explicit `max`, the parser emits a **parse-time warning** indicating the implicit default of 1000 applies. This surfaces implicit loop bounds to scenario authors who may have assumed unbounded iteration.
- `delay` respects the scenario speed multiplier via `SpeedMultiplier` SPI.
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
loopUntil_noExplicitMax_emitsParseWarning
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
- **Parallel failure semantics:** When `parallel: true` and an iteration fails:
  - All other in-flight iterations continue to completion (no fail-fast). This matches the platform's stance that partial results are more useful than aborted work.
  - Failures are collected into a `ForEachCompositeException` containing each failed iteration's index, item, and exception.
  - The `on-error` handler fires once for the entire `forEach` step (not per iteration), receiving the composite exception. The handler can inspect individual failures via `${error.failures}`.
  - `retry` retries the entire `forEach` step (all iterations), not individual failed iterations. Per-iteration retry is a deliberate non-goal — iteration bodies are arbitrary step sequences, and partial retry of a parallel fan-out creates ambiguous result-set semantics.

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
forEach_parallel_failureInOneIteration_othersComplete
forEach_parallel_compositeException_containsAllFailures
forEach_parallel_onError_firesOnceWithComposite
forEach_parallel_retry_retriesAllIterations
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
- Duration parsing: `ms`, `s`, `m`, `h` suffixes. orchestration-core provides its own `DurationParser` (same syntax as simulation-config-core's, extended with `h` for hours). No dependency on simulation-config-core.
- Respects `SpeedMultiplier` SPI (defined in yaml-core, implemented by the runtime — e.g. backed by `TemporalDriverService` in event-simulation): at speed 2x, a 5s delay waits 2.5s real time.
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
- `timeout` wraps the step execution (including any trigger wait) with a deadline (see Decorator Evaluation Order — timeout is outside trigger).
- On timeout, fires `StepTimeoutException`. If `on-error` is present, routes to the named step/action. If absent, the exception propagates.
- Respects the speed multiplier via `SpeedMultiplier` SPI.
- Delegates to `PolicyEnforcer` internally for consistent timeout handling.
- **Interaction with `trigger.timeout`:** Both can be active simultaneously. `trigger.timeout` applies only to the trigger wait phase and fires `TriggerTimeoutException`. Step-level `timeout` applies to the entire execution (including trigger wait) and fires `StepTimeoutException`. Whichever fires first wins. Example: `trigger.timeout: 60s` + step `timeout: 20s` → step timeout fires at 20s, pre-empting the trigger timeout. Different exception types enable typed `on-error` matching.

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
- `on-error` catches runtime exceptions from the entire step execution, including decorator-generated runtime exceptions: `StepTimeoutException` (from `timeout`), `RetryExhaustedException` (from `retry` when no `retry.fallback` is set), `TriggerTimeoutException` (from `trigger` when no `trigger.fallback` is set). See Decorator Evaluation Order — `on-error` wraps `timeout`, which wraps `trigger` and `retry`.
- `on-error` does **not** catch `StepCancelledException` — cancellation from `race` or `quorum` is an external termination signal, not a step-level error. The runtime checks `if (exception instanceof StepCancelledException) rethrow` before invoking the on-error handler. This prevents `on-error` from defeating cancellation intent. `StepCancelledException` extends `java.util.concurrent.CancellationException` (JDK, not a custom hierarchy).
- `on-error` does **not** catch configuration errors (malformed expressions, unknown variables, invalid step references) — these fail fast at parse time.

**Test cases:**
```
onError_simpleForm_routesToNamedStep
onError_detailedForm_logsAndRoutes
onError_typedMatch_routesByExceptionType
onError_typedMatch_firstMatchWins
onError_otherwise_catchesAll
onError_noMatch_propagatesException
onError_catchesStepTimeoutException
onError_catchesRetryExhaustedException_whenNoRetryFallback
onError_catchesTriggerTimeoutException_whenNoTriggerFallback
onError_doesNotSeeException_whenScopedFallbackHandlesIt
onError_parseTimeErrors_failFast_bypassOnError
onError_stepCancelledException_bypassesOnError
onError_raceCancellation_notCaughtByOtherwise
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
- `circuit-breaker` is an optional sub-field (not a separate keyword). Maps to `CircuitBreakerPolicy`. **Prerequisite:** `DefaultPolicyEnforcer.execute()` currently reads `policy.retries()` and `policy.timeoutMs()` but does not read `policy.circuitBreaker()` — the `CircuitBreakerPolicy` record exists in `platform-api` but is functionally ignored by the enforcer. `DefaultPolicyEnforcer` must be extended to implement circuit breaker state tracking (failure counter, open/half-open/closed states, recovery window) before this YAML keyword is functional. See casehubio/platform#TBD.
- `fallback` names a step to route to when retries are exhausted (equivalent to `on-error` but scoped to retry exhaustion).
- `timeout` (optional sub-field of `retry`) — per-attempt timeout. When set, each retry attempt has this deadline. Maps to `ExecutionPolicy.timeoutMs`. This is distinct from step-level `timeout` which is the total step deadline (see Decorator Evaluation Order). Example: `retry: { max: 3, delay: 1s, timeout: 5s }` means each attempt gets 5s, retried up to 3 times.
- **Composition with step-level `timeout`:** When both are present, two timeout layers are active. Step-level `timeout` is the outer deadline (covers trigger wait + entire retry sequence). `retry.timeout` is the per-attempt deadline (each individual attempt). The step decorator layer constructs a single `ExecutionPolicy(retryTimeoutMs, retryPolicy, circuitBreakerPolicy)` and passes it to one `PolicyEnforcer.execute()` call. The step-level timeout wraps this call externally. When step-level `timeout` is present but `retry.timeout` is not, `ExecutionPolicy` gets `timeoutMs = null` (no per-attempt timeout — only the outer step deadline applies).
- Delegates to `PolicyEnforcer.execute(policy, action)` — where `action` is `Supplier<T>` (not `Callable<T>` — `Supplier.get()` does not throw checked exceptions; step actions that throw checked exceptions must be wrapped as unchecked). No reimplementation.

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
- `type: time` — `at` accepts relative (`T+30s`, `T+5m`) or absolute (`"16:00"`, `"2026-09-22T08:30:00"`). Respects speed multiplier via `SpeedMultiplier` SPI.
- `type: event` — subscribes to CloudEvents matching `eventType` (and optionally `source`). `filter` applies an expression to the event data. **Integration point:** the trigger registers a CDI `@ObservesAsync CloudEvent` observer qualified with `@CloudEventType(eventType)` (see `platform-api/.../CloudEventType.java`). `CloudEventTypeDispatcher` (in `platform` module) dispatches incoming CloudEvents to type-qualified observers. The trigger observer blocks on an internal `OrcSignal` until a matching event arrives (or timeout). For `source` and `filter` matching, the observer receives all events of the given type and applies source/filter checks before signalling. **Subscription lifecycle:** the CDI observer is registered when the trigger step begins execution (not at scenario load time). Events fired before the step reaches the trigger decorator are missed — this is correct behaviour, not a bug. The trigger is "wait for the next event," not "check if any event ever happened." Each scenario execution gets its own independent observer instance; concurrent scenario executions do not interfere. The observer is unregistered when the step completes (or the scenario is disposed).
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

**Simple form (default engine):**
```yaml
- step: enrich
  transform: "{ symbol: $.instrument, price: $.last_trade }"
```

**Simple form with explicit engine:**
```yaml
- step: enrich
  transform:
    expression: "{ symbol: $.instrument, price: $.last_trade }"
    engine: mvel
```

**Detailed form with explicit input:**
```yaml
- step: reshape
  transform:
    input: ${result.fetch.body}
    expression: ".prices | map({ symbol: .sym, close: .last })"
    engine: jq
```

**Semantics:**
- Simple form: when `transform` is a plain string, it is the expression with the default engine (jq). Operates on the **action's output** — the transform receives the result of the step's action and reshapes it. This follows from the post-action position in the Decorator Evaluation Order (position 13, after the action at position 10).
- Detailed form: `input` names the source, `expression` is the transform, `engine` selects the expression engine (default: jq). `engine` is always a sub-field of `transform`, never a step-level sibling.
- **Scoping rule:** the expression must be a one-liner. If the transform needs conditional logic, multiple fields from different sources, or iteration — use a `@ScenarioAction` instead.
- The result of the transform replaces the step's output (available as `${result.<step-name>}`).

**Test cases:**
```
transform_simpleExpression_reshapesData
transform_withExplicitInput_usesNamedSource
transform_jqEngine_evaluatesCorrectly
transform_mvelEngine_evaluatesCorrectly
transform_defaultInput_isActionOutput
transform_resultAvailableAsStepResult
transform_invalidExpression_throwsWithClearMessage
```

---

## Part 2: Coordination Primitives

All coordination primitives are interfaces in `orchestration-core`. Implementations are thread-safe via `java.util.concurrent`. These are **virtual-thread-first** interfaces — blocking methods (`acquire()`, `await()`, `receive()`, `lock()`) use `throws InterruptedException` and are designed for the virtual-thread execution model where blocking is cheap. An async/event-driven consumer would need to wrap these in async adapters (e.g., `CompletableFuture.supplyAsync(() -> { latch.await(); return result; })`), which is efficient on virtual threads but incompatible with single-threaded event loops (Vert.x, Netty). If async-native coordination is needed in the future, async counterparts can be added alongside these interfaces — but the current design commits to virtual threads as the primary execution model.

### Lifecycle and Scope

All coordination primitives are scoped to a **single scenario execution**. The orchestration runtime owns a `ScenarioScope` that creates, tracks, and disposes all named primitive instances.

- **Creation:** Primitives are created eagerly at scenario load time, based on the parsed scenario definition. Latches, signals, channels, semaphores, and state machines referenced in the YAML are instantiated before step execution begins. This eliminates race conditions from lazy initialization.
- **Normal completion:** When the scenario completes successfully, all primitives are disposed. Semaphore permits are released. Channels are closed. Latches are counted down to zero.
- **Abnormal termination:** On timeout, unrecoverable error, or user cancellation, the `ScenarioScope` performs forced cleanup:
  - Semaphore permits released (finally semantics, same as on-error per step)
  - Channels closed with an error marker — consumers see `closed = true` and `error = true`
  - Latches counted down to zero (to unblock any waiting barrier/quorum steps)
  - Signals signalled with an error payload (to unblock any waiting steps)
  - State machines left in current state (no auto-transition on abort)
- **Reuse:** Primitives are NOT reused across scenario runs. Each execution gets fresh instances. No state leaks between runs.

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

**YAML usage (mutex sugar — exclusive access):**
```yaml
- step: update-portfolio
  mutex: portfolio-state
  action: recalculate-positions
```

`mutex: <name>` is syntactic sugar for `semaphore: { name: <name>, permits: 1 }`. It communicates exclusive-access intent more clearly than a semaphore with permits=1. The sugar produces the same `OrcSemaphore` instance — there is no separate `OrcMutex` interface.

**Semantics:**
- Named semaphores are shared across all steps in a scenario. Same name = same semaphore instance.
- `permits` is the max concurrent acquisitions. Default: 1 (mutex behavior).
- `per` adds a time window — permits are replenished at the specified rate (subsumes `rateLimit` from issue).
- Acquisition blocks until a permit is available (or timeout from step-level `timeout`).
- **Reentrancy detection:** When `permits: 1` (including via `mutex:` sugar), the semaphore detects reentrancy — if a step attempts to acquire a semaphore it already holds, `SemaphoreReentrancyException` is thrown instead of deadlocking. This detection is only meaningful for single-permit semaphores; multi-permit semaphores do not track ownership. Ownership is tracked by **step execution context** (the step's logical ID within the scenario), not by `Thread.currentThread()`. Virtual threads may be scheduled on different carrier threads across suspension points, so thread identity is unreliable for ownership tracking. The step execution context is stable for the lifetime of a step's execution regardless of thread migration.

**Test cases:**
```
semaphore_acquireAndRelease_basic
semaphore_blocksWhenNoPermits
semaphore_releasesOnStepCompletion (even on error)
semaphore_namedSharing_sameNameSameInstance
semaphore_differentNames_independent
semaphore_withTimeWindow_replenishesPermits
semaphore_tryAcquireTimeout_returnsFalse
semaphore_mutexSugar_equivalentToPermitsOne
semaphore_singlePermit_reentrancy_throws
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
- The latch is created eagerly at scenario load time (see Lifecycle and Scope). Step names are validated at parse time; the latch count is known from the declaration. Eager init eliminates race conditions between barrier waiters and awaited steps.
- **Step failure handling:**
  - **Barrier:** Step failure (exception) DOES call `countDown()` — the step completed, just with an error. The barrier unblocks and the consuming action receives a result set containing both successful and failed step outcomes. The consuming action can inspect `${result.<step>.error}` to distinguish.
  - **Quorum:** Step failure does NOT count toward the `required` threshold — only successful completions count. If the number of surviving (non-failed) steps drops below `required`, the quorum throws `QuorumUnreachableException` (or routes to fallback) rather than waiting indefinitely.

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
- `race` creates a signal per named step. First signal wins — the race step proceeds with the winner's result. **Cancellation mechanism:** losing steps are cancelled via `Thread.interrupt()` on their virtual thread. The orchestration runtime wraps the resulting `InterruptedException` in `StepCancelledException` (extends `java.util.concurrent.CancellationException`). `StepCancelledException` bypasses `on-error` handlers (see §1.6) — cancellation is an external termination signal, not a step failure. The runtime performs decorator cleanup:
  - `semaphore` — permit released (finally semantics)
  - `retry` — `DefaultPolicyEnforcer` already handles `InterruptedPolicyException` (breaks retry loop)
  - `publish` — partial publishes already in the channel are NOT rolled back (channel is ordered, rolling back would require coordination with consumers who may have already consumed earlier items)
  - In-progress HTTP requests (`trigger: { type: data }`) — the `Future` is cancelled; whether the underlying HTTP call aborts depends on the HTTP client implementation
- `signal: <name>` emits a named signal on step completion. `wait: <name>` blocks until the signal is received.
- **Payload retention:** Signals retain their payload after being signalled. `isSignalled()` returns `true` permanently. `await()` returns immediately if the signal was already fired before the waiter arrived. The payload remains accessible via `${signal.<name>.payload}`.
- **Multi-waiter semantics:** When a signal fires, ALL waiting steps are unblocked (broadcast, not point-to-point). This matches `CountDownLatch.countDown()` semantics — the signal is a fact about the world, not a message to a specific consumer.
- One-shot signals (default) can only be signalled once. Subsequent `signal()` calls are ignored.
- **Repeatable signals** use latest-value semantics, not queued delivery. Each `signal(payload)` overwrites the previous payload. Waiters see the latest payload at the time they wake up. If queued delivery is needed, use `Channel` instead. This avoids overlap between repeatable signals and channels.

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

Pass data between concurrent steps within a single scenario execution. Bounded or unbounded.

**Distinction from qhorus channels:** `OrcChannel<T>` is an in-process, ephemeral coordination primitive — analogous to Go channels or CSP. It exists for the lifetime of a scenario execution and is garbage-collected when the scenario completes. Qhorus channels (APPEND, COLLECT, BARRIER, EPHEMERAL, LAST_WRITE) are distributed, persistent messaging infrastructure for cross-process communication. These serve fundamentally different purposes: `OrcChannel` coordinates concurrent steps within a single execution; qhorus channels coordinate distributed actors across processes and time. The issue's "NOT in YAML" guidance refers to distributed channel infrastructure, not in-process coordination.

```java
public interface OrcChannel<T> {
    void send(T value) throws InterruptedException;
    boolean send(T value, long timeout, TimeUnit unit) throws InterruptedException;
    T receive() throws InterruptedException;
    T receive(long timeout, TimeUnit unit) throws InterruptedException;
    boolean isEmpty();
    void close();
    void close(Throwable cause);
    boolean isErrorClosed();
    Throwable closeError();
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
    close-on-complete: true

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
- Bounded channels: `channel: { name: events, capacity: 100 }`. Default: unbounded. Unbounded is the correct default for an in-process orchestration primitive — scenarios run within a single JVM with bounded lifetimes, and capacity tuning is a performance concern, not a correctness concern. The runtime emits a **high-water-mark warning** (logged at WARN level) when an unbounded channel exceeds 10,000 queued items, indicating a likely producer-consumer imbalance that the scenario author should address with explicit capacity.
- **Close semantics:** `close-on-complete: true` (default) closes the channel when the publishing step completes — both on success and on failure. On producer failure (exception), the channel is **error-closed**: `close(Throwable cause)` sets the channel to closed state with an error marker. Consumers draining remaining items proceed normally; when the buffer is exhausted, the next `receive()` throws `ChannelClosedException` wrapping the producer's exception (rather than returning `closed = true` silently). This prevents consumers from silently interpreting an incomplete data stream as complete. Explicit close: `close-channel: events` as a standalone action for multi-producer scenarios. `close()` (no-arg) signals normal completion — receivers see `closed = true` after draining remaining items.
- **Multi-producer close detection:** The parser detects when multiple `publish` declarations target the same channel and any has `close-on-complete: true` (including the default). This is a **parse-time error** — the first producer to complete would close the channel, killing remaining producers. The error message directs the author to set `close-on-complete: false` on all producers and use explicit `close-channel:` for coordinated shutdown. `send()` on a closed channel throws `ChannelClosedException`.
- Channels are typed at the Java interface level but untyped in YAML (everything is `Map<String, Object>`).

**Test cases:**
```
channel_sendAndReceive_basic
channel_blocksOnFullBounded
channel_blocksOnEmptyReceive
channel_close_drainThenClosed
channel_errorClose_producerFailure_consumersGetException
channel_errorClose_drainsRemainingBeforeError
channel_namedSharing_sameNameSameInstance
channel_unbounded_neverBlocksOnSend
concurrent_producerConsumer_safeUnderContention
concurrent_multipleProducers_allDataDelivered
concurrent_multipleConsumers_eachItemDeliveredOnce
channel_multiProducerWithCloseOnComplete_parseTimeError
channel_sendOnClosedChannel_throwsChannelClosedException
```

---

### 2.5 `StateMachine` — State Transitions

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
- **Guard-CAS atomicity (TOCTOU):** Guard evaluation and CAS are separate operations. The guard is evaluated against current variable state, then the CAS attempts the transition. Between guard evaluation and CAS, the guard's input data could theoretically change (e.g., `risk-score` changes from 0.5 to 0.9 between guard check and CAS). The CAS ensures **state consistency** (exactly one transition from a given state wins), but does not guarantee **guard-state consistency** (the guard condition still holds at CAS time). This TOCTOU window is microseconds in-process and acceptable for scenario orchestration. For transitions requiring strong guard-state consistency (e.g., financial compliance gates), implement the guard+transition in a `@ScenarioAction` that holds an explicit lock on the guarded data.
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

### 3.0 yaml-core Runtime Contracts

The following interfaces are added to yaml-core. They are pure contracts — zero dependencies, J2CL-safe. Implementations live in the consuming module.

**`Condition` — Runtime boolean evaluation:**
```java
@FunctionalInterface
public interface Condition {
    boolean evaluate();
}
```

Used by the `when` decorator. The consuming layer binds a `Condition` from a `VariableResolver` + `ExpressionEngine` pair at step construction time. yaml-core's `ConditionEvaluator` handles the common case (simple equality via `Truthiness`) and delegates complex expressions through a `Function<String, Boolean>` SPI.

**`RuntimeForEach` — Runtime collection resolution:**
```java
@FunctionalInterface
public interface RuntimeForEach {
    java.util.List<?> resolve();
}
```

Used by the `forEach` decorator when `in` references a runtime variable (e.g., `${instruments}`). The consuming layer binds a `RuntimeForEach` from a `VariableResolver` + `ObjectVariableSource` pair at step construction time. Resolves the collection from live state, not from static YAML. Returns a `List<?>` — each element becomes an iteration context accessible via `${each.<as>}`.

**`SpeedMultiplier` — Simulation speed SPI:**
```java
@FunctionalInterface
public interface SpeedMultiplier {
    double currentSpeed();
}
```

Used by `delay`, `timeout`, and `trigger` decorators to adjust durations for simulation speed. Default implementation returns 1.0 (real-time). The consuming layer provides an implementation backed by `SimulationRuntime.globalSpeed()` from simulation-core.

---

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
${result.<step-name>.error}      — step error (null if succeeded, exception object if failed — for barrier result inspection)
${channel.<name>.value}         — last received channel value
${channel.<name>.closed}        — channel closed flag
${channel.<name>.error}         — channel close error (null if normal close, Throwable if error-closed)
${env.<key>}                    — environment/config value
```

**Semantics:**
- Runtime sources are registered as `VariableSource` implementations, scoped to the execution context.
- The resolver tries prefixes in registration order. Runtime prefixes (`result`, `loop`, `machine`, `signal`, `channel`) are registered by the orchestration runtime, not by the YAML author.
- Deferred prefix handling (already in `VariableResolver`) allows parse-time validation to flag unknown prefixes while deferring runtime-only prefixes.
- **`${result.<step>}` resolution scope:** `${result.<step>}` is valid when the named step has completed and the referencing step can observe its result. For sequential steps, this means the named step must precede the referencing step in declaration order. For concurrent steps (inside `parallel:` blocks or concurrent step groups), results from sibling concurrent steps are not available via `${result}` — use `barrier`, `signal`, or `channel` for cross-step data flow in concurrent contexts. Referencing a step that has not yet completed throws `UnresolvedVariableException` at runtime. The parser emits a warning when `${result.<step>}` references a step that is not a sequential predecessor (best-effort static analysis — not all concurrent patterns are detectable at parse time).

**Type widening for runtime sources:** The existing `VariableSource` returns `String resolve(String name)`, which is correct for parse-time resolution where all values are interpolated into strings. Runtime sources need to pass complex objects (step results as maps, signal payloads, channel values). yaml-core introduces `ObjectVariableSource`:

```java
@FunctionalInterface
public interface ObjectVariableSource {
    Object resolve(String name);
}
```

`VariableResolver` is extended to try `ObjectVariableSource` first for runtime-registered prefixes. String interpolation (inside `${}` in templates) still stringifies via `toString()`. But when the resolved value is consumed directly as `data:` for an action (not interpolated into a template string), the typed `Object` is passed through — preserving maps, lists, and primitive types. This keeps yaml-core J2CL-safe (no new heavy types) while allowing runtime sources to return typed objects.

**Test cases:**
```
runtimeSource_resultPrefix_resolvesFromStepResult
runtimeSource_loopPrefix_resolvesIndexAndIteration
runtimeSource_machinePrefix_resolvesCurrentState
runtimeSource_signalPrefix_resolvesPayload
runtimeSource_channelPrefix_resolvesValueAndClosed
runtimeSource_channelPrefix_resolvesError
runtimeSource_resultPrefix_resolvesError_nullOnSuccess
runtimeSource_resultPrefix_resolvesError_exceptionOnFailure
runtimeSource_unknownPrefix_throws
runtimeSource_deferredPrefix_passesThrough
runtimeSource_resultFromSequentialPredecessor_resolves
runtimeSource_resultFromConcurrentSibling_throwsUnresolved
runtimeSource_resultFromUnrunStep_throwsUnresolved
```

---

## Issue Part 2 Pattern Mapping

The issue's Part 2 proposes coordination patterns. This section maps each to the spec's primitives:

| Part 2 Pattern | Mapping | Status |
|---|---|---|
| `correlate` — match response by key | `trigger: { type: event, filter: ${event.data.orderId} == ${orderId} }` — event trigger with key-matching filter expression | Covered by composition |
| `scatter-gather` — fan out, collect | `parallel:` block + `barrier: { await: [...] }` for all-responses; `quorum: { required: N }` for min-response policy | Covered by composition |
| `deadline propagation` — scope-level deadline | Step-level `timeout:` on a parent step, or `timeout:` on each step in a `parallel:` block. Scenario-level deadline can be expressed as a top-level step with `timeout:` wrapping all others | Covered by `timeout` |
| `discriminator` — advance on first, keep collecting | `race: [...]` advances on first completion. Race cancels remaining steps. Discriminator (advance but continue collecting) is a distinct pattern — deferred | Deferred: casehubio/platform#392 |

**`correlate` composition example:**
```yaml
- step: submit-order
  action: send-order
  signal: order-submitted

- step: await-confirmation
  trigger:
    type: event
    eventType: io.casehub.order.confirmed
    filter: ${event.data.orderId} == ${result.submit-order.orderId}
    timeout: 10s
    fallback: order-timeout
```

**`scatter-gather` composition example:**
```yaml
- parallel:
    - step: momentum-eval
      action: evaluate-momentum
    - step: risk-eval
      action: evaluate-risk
    - step: compliance-eval
      action: evaluate-compliance
- step: gather-results
  quorum:
    required: 2
    of: [momentum-eval, risk-eval, compliance-eval]
    timeout: 10s
  action: aggregate-assessments
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

**Multi-agent consensus — early advance (quorum inside parallel):**
```yaml
scenario: strategy-consensus
steps:
  - parallel:
      - step: momentum-eval
        action: evaluate-momentum
        data: { portfolio: ${portfolio} }
      - step: risk-eval
        action: evaluate-risk
        data: { portfolio: ${portfolio} }
      - step: compliance-check
        action: check-compliance
        data: { portfolio: ${portfolio} }
      - step: consensus
        quorum:
          required: 2
          of: [momentum-eval, risk-eval, compliance-check]
          timeout: 15s
        action: aggregate-votes
```

The `consensus` step is **inside** the `parallel:` block. It launches alongside the three evaluation steps and awaits any 2 completions. Once 2 of 3 finish, `aggregate-votes` runs immediately — the slowest evaluation may still be in progress. The `parallel:` block's implicit barrier then waits for all 4 steps to terminate (the remaining evaluation completes or is cancelled).

**Post-facto success check (quorum after parallel):**
```yaml
steps:
  - parallel:
      - step: momentum-eval
        action: evaluate-momentum
      - step: risk-eval
        action: evaluate-risk
      - step: compliance-check
        action: check-compliance

  - step: verify-consensus
    quorum:
      required: 2
      of: [momentum-eval, risk-eval, compliance-check]
    action: aggregate-votes
```

Here `quorum` is **after** the `parallel:` block — all three evaluations have already terminated (the implicit barrier waited for all). The quorum acts as a post-facto check: "did at least 2 succeed?" If fewer than 2 succeeded, `QuorumNotMetException` is thrown. No early-advance benefit — use this pattern when you want to verify sufficient success from a concurrent group.

**Producer-consumer with backpressure (parallel + channel + loop + semaphore):**
```yaml
scenario: event-pipeline
steps:
  - parallel:
      - step: producer
        loop:
          count: 100
        action: generate-event
        publish:
          channel: events
          close-on-complete: true
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
| `LoopEvaluatorTest` (new) | consuming module | Count loops, exit-condition loops, max safety, delay |
| `TriggerEvaluatorTest` (new) | consuming module | Data/time/event triggers, polling, timeout |
| `TransformEvaluatorTest` (new) | consuming module | Expression-based transforms, engine selection |
| `RetryDecoratorTest` (new) | consuming module | Retry with backoff, circuit breaker, PolicyEnforcer delegation |
| `OrcSemaphoreTest` (new) | orchestration-core | Permits, blocking, time-windowed replenishment |
| `OrcLatchTest` (new) | orchestration-core | Countdown, await, timeout |
| `OrcSignalTest` (new) | orchestration-core | Signal/await, payload, one-shot vs repeatable |
| `OrcChannelTest` (new) | orchestration-core | Send/receive, bounded backpressure, close semantics |
| `OrcStateMachineTest` (new) | orchestration-core | Transitions, guards, terminal states, handlers |
| `ConcurrentSemaphoreTest` (new) | orchestration-core | Multi-thread contention on semaphore |
| `ConcurrentLatchTest` (new) | orchestration-core | Multi-thread countdown/await races |
| `ConcurrentSignalTest` (new) | orchestration-core | Multi-thread signal/await races |
| `ConcurrentChannelTest` (new) | orchestration-core | Producer-consumer under contention |
| `ConcurrentStateMachineTest` (new) | orchestration-core | Competing CAS transitions |
| `ParallelExecutorTest` (new) | consuming module | Parallel step execution, implicit barrier on block completion, termination semantics (success/failure/cancellation all count) |
| `CompositionTest` (new) | consuming module | Two-primitive compositions (when+loop, trigger+timeout, forEach+retry, when+forEach per-iteration filter) |
| `TippingPointTest` (new) | consuming module | Three-primitive compositions documenting the boundary |
| `DecoratorOrderTest` (new) | consuming module | Verifies canonical decorator evaluation order (timeout wraps retry, on-error wraps timeout, etc.) |

---

## References

- `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ForEachExpander.java` — parse-time forEach, pattern for runtime extension
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java` — variable resolution with pluggable sources and deferred prefixes
- `yaml-core/src/main/java/io/casehub/yaml/core/condition/Truthiness.java` — boolean string evaluation
- `platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionEngine.java` — expression compilation SPI
- `platform-api/src/main/java/io/casehub/platform/api/governance/ExecutionPolicy.java` — retry/timeout/circuit-breaker records
- `governance-core/src/main/java/io/casehub/platform/governance/PolicyEnforcer.java` — policy enforcement SPI
- `event-simulation/src/main/java/io/casehub/platform/simulation/event/quarkus/TemporalDriverService.java` — `@ApplicationScoped` Quarkus CDI bean for speed-multiplied temporal simulation drivers. Runtime orchestration does not depend on this directly — instead, yaml-core defines a `SpeedMultiplier` SPI that orchestration-core consumes, and the runtime bridges to `TemporalDriverService` (or any other speed source) at the integration layer
- casehubio/platform#386 — original issue with 21 proposed patterns
- casehubio/casehub-pages#461 — scenario model parsing (AfterTrigger wired, others parsed but unevaluated)
- D1–D6 in `decisions.md` — design decisions for this spec
