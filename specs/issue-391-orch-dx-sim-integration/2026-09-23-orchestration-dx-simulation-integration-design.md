# Orchestration DX Refinements + Simulation Integration

**Issues:** #391 (DX refinements), #405 (simulation-orchestration), #411 (four-tier escape), #412 (execution model + browser parity), #413 (design rules)
**Branch:** issue-391-orch-dx-sim-integration
**Date:** 2026-09-23
**Depends on:** #386 (runtime orchestration primitives — landed)
**Feeds:** #410 (correlate, deadline propagation, condition combinators)

## Context

Platform#386 added runtime orchestration primitives to yaml-core: OrcStateMachine, OrcChannel, OrcSemaphore, OrcSignal, OrcLatch, ScenarioScope, StepResultStore, DurationParser, and SpeedMultiplier SPI. This branch builds on that foundation in two directions:

1. **DX refinements (#391):** reduce verbosity for common orchestration patterns without changing the underlying model
2. **Simulation–orchestration integration (#405):** connect the simulation infrastructure (TemporalSimulationDriver, TimedSequence, SimulationRuntime) with the orchestration primitives, enabling YAML-driven simulation scenarios

**#405 scope:** Issue #405 defines four integration directions. This spec addresses directions 1 and 2:

| Direction | Status | Where addressed |
|-----------|--------|----------------|
| 1. Simulation consumes orchestration | ✅ Addressed | D5 (BlockingOrcStateMachine), D8 (feed→channel) |
| 2. Orchestration consumes simulation | ✅ Addressed | D6 (SpeedMultiplier wiring), D7 (CorpusVariableSource) |
| 3. @SimulationEligible orchestration primitives | ⏳ Deferred | Tracked as #414 |
| 4. Convergence with agentic patterns (TerminationSpec) | ⏳ Deferred | Tracked as #415 |

Direction 3 (decorator generation for orchestration primitives to inject pre-recorded messages, force state sequences, adjust semaphore permits) overlaps with `SimulatedPrimitiveFactory` (D9) but is broader — D9 is factory-level substitution; direction 3 envisions annotation-driven decorator generation via the existing `SimulationDecoratorProcessor`. This is deferred because the decorator generator needs primitives to be stable first.

Direction 4 (TerminationSpec delegating to yaml-core orchestration primitives) requires #410 (deadline propagation, condition combinators) as a prerequisite — deferring until #410 lands.

## Strategic Position

The combination of these two issues creates a YAML orchestration language with capabilities no existing playbook language provides:

| Capability | Ansible | Argo | Step Functions | casehub YAML |
|-----------|---------|------|---------------|-------------|
| Temporal execution (events over time) | no | no | no | yes |
| Speed-multiplied time (10x/100x) | no | no | no | yes |
| Typed concurrent channels | no | no | no | yes |
| Concurrent data feeds (Web Worker model) | basic forks | DAG parallel | parallel branches | spawn + channels |
| Thread-safe shared state | no | no | no | counter, gauge, flag, accumulator, map |
| Expression power | Jinja2 | Go templates | JSONPath | JQ + MVEL + CDI bean invoke |
| Deadline propagation | no | timeouts only | timeouts only | cascading scope deadlines |
| Scenario debugging | no | logs | logs | Journal + step tracing (MCP debugger: future) |

The closest comparable is Temporal.io — but Temporal's position is "you need a programming language, YAML isn't expressive enough." This design proves that wrong via the four-tier escape model.

## Design Constraint: YAML Capability Equivalence

YAML simulation scenarios must be capability-equivalent to the programmatic Java API. No reduced fidelity — different mechanisms, same guarantees. If a common simulation pattern requires Java escape, that's a YAML gap to fix, not a feature.

---

## Part 1: DX Refinements (#391)

### 1.1 Shorthand Forms (D1)

Each orchestration directive type gets a sealed type with `parse(Object)` factory method, following the proven ForEachDirective pattern. Scalar form for simple cases, object form for complex.

```yaml
# Shorthand                             # Full form
forEach: ${instruments} as instrument    forEach:
                                           in: ${instruments}
                                           as: instrument

loop: 5                                  loop:
                                           count: 5

retry: 3                                 retry:
                                           max: 3
                                           backoff: exponential
                                           delay: 1s
```

ShorthandModule in schema-generator handles the JSON Schema side (scalar-or-object `oneOf`). yaml-core stays zero-dependency.

### 1.2 Default Variable Prefix (D2)

New `VariablePrefixRewriter` utility in yaml-core. Consumers declare a default prefix in YAML document metadata and call the rewriter as a pre-processing step before variable resolution.

```yaml
defaultPrefix: var

# Author writes:                        # Rewriter produces:
when: ${regime} == 'MEAN_REVERTING'      when: ${var.regime} == 'MEAN_REVERTING'
data:                                    data:
  symbol: ${instrument.symbol}             symbol: ${each.instrument.symbol}
```

VariableResolver is unchanged — bare references remain a hard error. The rewrite is visible in the parsed AST (debuggable, not magical).

**Rewriter mechanics:** VariablePrefixRewriter is YAML-aware, not a blind text transform. It receives:
1. The `defaultPrefix` value (e.g., `var`)
2. The set of forEach `as:` variable names extracted from the document's forEach declarations
3. The set of registered scoped prefixes from VariableResolver's prefix sources

**Rewrite rules (priority order):**
1. If the bare reference matches a registered scoped prefix — never rewrite (recognized prefixes)
2. If the bare reference matches a forEach `as:` variable — rewrite to `each.` prefix
3. Otherwise — rewrite to the declared `defaultPrefix`

**Collision rule:** If both a `var.instrument` scope and a `forEach: ${instruments} as instrument` exist, the forEach binding wins (rule 2 before rule 3). This is intentional — forEach creates a more specific scope.

**Recognized prefix list:** Derived from VariableResolver's registered prefix sources (`prefixSources.keySet()` + `objectPrefixSources.keySet()`), not hardcoded. Adding a new scoped prefix (e.g., `corpus.`, `shared.`) via `withScope()` or `withObjectScope()` automatically adds it to the recognized set. No rewriter code change needed.

### 1.3 Compute Blocks (D3)

New `ComputeBlock` record in yaml-core: engine key (non-optional) + expression text.

```yaml
- step: top-movers
  compute:
    engine: jq
    expression: |
      .prices
      | map(select(.change > 0.05))
      | sort_by(.change)
      | reverse
      | .[0:5]
```

When the author omits `engine:`, the YAML parser resolves the default from ExpressionContext (D4) at parse time and bakes it into the record. ComputeBlock is self-contained and context-independent.

Three-tier escape model (expanded to four tiers in Part 2):
1. One-liner — `transform: ".price * 1.1"` (in the step)
2. Multi-line block — `compute:` with pipe expression (in YAML)
3. Java code — `@ScenarioAction` (full language with debugger)

### 1.4 Expression Engine Defaults (D4)

New `ExpressionContext` enum in platform-api: `CONDITION`, `TRANSFORM`, `FILTER`.

New methods on `ExpressionEngineRegistry`:
- `registerDefault(ExpressionContext context, String engineType)`
- `String resolveDefault(ExpressionContext context)`

Platform defaults:

| Context | Default engine | Rationale |
|---------|---------------|-----------|
| CONDITION (`when`, `until`, guards) | MVEL | Boolean expressions: `x == 'Y'`, `x > 5`, `a && b` |
| TRANSFORM (`transform`, `compute`, data) | JQ | Data transforms: `.prices \| map(...)` |
| FILTER | JQ | Filtering: `select(.change > 0.05)` |

Overridable via `registerDefault()`. No `engine:` needed in YAML for the common case.

---

## Part 2: Simulation–Orchestration Integration (#405)

### 2.1 Two-Tier OrcStateMachine (D5)

`OrcStateMachine<S>` interface unchanged. New extension interface `BlockingOrcStateMachine<S>` (following GraphCaseMemoryStore pattern):

```java
public interface BlockingOrcStateMachine<S extends Enum<S>> extends OrcStateMachine<S> {
    void awaitState(S target) throws InterruptedException;
    boolean awaitState(S target, Duration timeout) throws InterruptedException;
    void awaitTransition(S from, S to) throws InterruptedException;
}
```

Two implementations:
- `DefaultOrcStateMachine<S>` — current (AtomicReference CAS, handlers, no blocking)
- `DefaultBlockingOrcStateMachine<S>` — layers ReentrantLock + Condition, SpeedMultiplier-aware timeouts

`SpeedMultiplier.identity()` — new static factory: `static SpeedMultiplier identity() { return () -> 1.0; }`. Contract: 1.0 = real-time.

ScenarioScope factory returns blocking variant by default (coordination is ScenarioScope's purpose).

ScenarioScope factory method return type changes to `BlockingOrcStateMachine<S>`:

```java
<S extends Enum<S>> BlockingOrcStateMachine<S> stateMachine(String name, Class<S> stateType, S initialState);
```

This is a breaking API change — justified because #386 is fresh with no external consumers. Callers typed to `OrcStateMachine<S>` still compile (covariant return), and callers that need blocking gain direct access without casting.

**Consolidates:** TemporalSimulationDriver lifecycle can use the same state-machine interface as all other platform state machines (uniform monitoring, debugging, YAML binding). The driver already manages lifecycle correctly with ReentrantLock + Condition — the value is API consolidation, not new capability. Scenario step coordination. Deadline cancellation (#410).

### 2.2 SpeedMultiplier Wiring (D6)

Single CDI producer in simulation-config:

```java
@Produces
SpeedMultiplier speedMultiplier(SimulationRuntime runtime) {
    return runtime::globalSpeed;
}
```

ScenarioScope passes SpeedMultiplier to BlockingOrcStateMachine instances. Without simulation-config on classpath, `SpeedMultiplier.identity()` applies — graceful degradation.

### 2.3 SimulationCorpus as VariableSource (D7)

New `CorpusVariableSource implements ObjectVariableSource` in simulation-config:

```yaml
forEach: ${corpus.trades} as trade
  steps:
    - step: process
      data: { symbol: ${each.trade.symbol}, price: ${each.trade.price} }
```

Prefix `corpus`. Drill-down via ObjectVariableSource: `${corpus.trades[0].symbol}`. Registered on VariableResolver via `withObjectScope("corpus", corpusSource)`. ForEachExpander already accepts any collection — no yaml-core changes.

### 2.4 Temporal Feed → Channel (D8)

New `feed:` property in simulation config YAML:

```yaml
temporal-profiles:
  flash-crash:
    events: [...]
    feed: trades-channel
```

Two-phase wiring:
1. **Startup:** simulation-config creates `FeedBinding` records (feedName, channelName, profileRef, eventType)
2. **Scenario start:** `feedBinding.activate(scope)` creates a TemporalEventSink adapter:

```java
TemporalEventSink<E> sink = (qualifiedName, label, event) ->
    scope.channel(channelName, eventType).send(event);
```

The adapter receives all three TemporalEventSink parameters (`qualifiedName`, `label`, `event`). Only `event` is forwarded to the channel — `qualifiedName` and `label` are available for logging/tracing but are not part of the channel payload.

**Type-validated channels:** New ScenarioScope method:

```java
<T> OrcChannel<T> channel(String name, Class<T> type);
```

The `type` parameter validates `type.isInstance(value)` on every `send()`. For non-generic concrete types (e.g., `Trade.class`), this provides strong runtime type safety. For generic types like `Map<String, Object>`, the erasure check (`Map.class.isInstance(...)`) validates the container type but not the generic parameters — this is a known limitation of Java's type erasure, not a design gap.

### 2.5 OrcPrimitive Lifecycle Interface (D9a)

All orchestration primitives implement a common lifecycle interface:

```java
public interface OrcPrimitive {
    default void releaseForClose() {}
}
```

Each primitive interface (`OrcChannel`, `OrcSignal`, `OrcLatch`, `OrcSemaphore`, `OrcStateMachine`, `OrcCounter`, `OrcGauge`, `OrcFlag`, `OrcAccumulator`, `OrcMap`) extends `OrcPrimitive`. Primitive implementations override `releaseForClose()` when they hold blocking resources:

| Primitive | releaseForClose() behavior |
|-----------|---------------------------|
| `OrcChannel` | closes the channel (releases blocked receivers) |
| `OrcLatch` | counts down to zero (releases blocked waiters) |
| `OrcSignal` | signals if unsignalled (releases blocked waiters) |
| `OrcSemaphore` | shuts down (releases blocked acquirers) |
| `OrcStateMachine` | no-op (non-blocking CAS) |
| `OrcCounter` | no-op (lock-free accumulation) |
| `OrcGauge` | no-op (atomic reference) |
| `OrcFlag` | no-op (atomic boolean) |
| `OrcAccumulator` | resets to identity value |
| `OrcMap` | no-op (data container) |

`DefaultScenarioScope.close()` becomes:

```java
for (Object p : primitives.values()) {
    if (p instanceof OrcPrimitive orc) {
        orc.releaseForClose();
    }
}
```

No instanceof chains, no coupling to concrete types, and `SimulatedPrimitiveFactory` implementations automatically participate in lifecycle cleanup.

### 2.5b Pluggable PrimitiveFactory (D9)

Extract `PrimitiveFactory` strategy from ScenarioScope's factory methods:

```java
public interface PrimitiveFactory {
    <T> OrcChannel<T> createChannel(String name, int capacity);
    OrcSignal createSignal(String name);
    <S extends Enum<S>> BlockingOrcStateMachine<S> createStateMachine(
        String name, Class<S> stateType, S initialState);
    OrcLatch createLatch(String name, int count);
    OrcSemaphore createSemaphore(String name, int permits);
    OrcCounter createCounter(String name);
    <T> OrcGauge<T> createGauge(String name);
    OrcFlag createFlag(String name);
    OrcAccumulator createAccumulator(String name, DoubleBinaryOperator op, double identity);
    <K, V> OrcMap<K, V> createMap(String name);
}
```

All `create*` methods return types that extend `OrcPrimitive` — the lifecycle contract is implicit in the type hierarchy. ScenarioScope caches via `ConcurrentHashMap.computeIfAbsent` — same-name-same-instance contract. PrimitiveFactory is stateless (no thread-safety requirements).

`SimulatedPrimitiveFactory` returns pre-loaded/scripted primitives for deterministic testing.

### 2.6 Concurrent Sub-Scenarios: spawn + childScope (D10)

Web Worker-style concurrency model on ScenarioScope:

```java
SpawnedTask spawn(String name, Runnable task);
ScenarioScope childScope(String name);
```

**SpawnedTask handle:** `isDone()`, `isFailed()`, `exception()`, `join()`, `join(Duration timeout)` (SpeedMultiplier-aware).

**Cancellation contract:**
1. `close()` calls `Thread.interrupt()` on all spawned virtual threads
2. All orchestration primitives throw `InterruptedException` — spawned tasks are interrupt-responsive
3. After interrupting, `close()` joins with timeout (5s default per task, SpeedMultiplier-aware)
4. Stuck tasks are logged — best-effort cleanup

**Total close budget:** The root scope enforces a total close budget of 30s (SpeedMultiplier-aware). All child scope close operations and join timeouts share this budget. When the budget is exhausted, remaining stuck tasks are logged at WARN level and abandoned. This prevents unbounded timeout accumulation in deep scope hierarchies — a 3-level hierarchy with 5 children each won't accumulate 75s of join timeouts.

**Lifecycle:**
- `childScope()` creates nested scope — closing parent closes all children (depth-first)
- Deadlines propagate downward
- SpeedMultiplier propagates through scope hierarchy

```yaml
scenario: flash-crash-response
  concurrent:
    - profile: trade-feed
      feed: trades
    - profile: market-data
      feed: market
    - profile: news-cascade
      feed: news

  steps:
    - step: detect-anomaly
      when: ${trades.last.change} > 0.05
    - step: respond
      invoke: TradingService::haltTrading
      input: ${alert}
```

### 2.7 Shared-State Primitives (D11)

Five new ScenarioScope primitives:

| Primitive | Java Backing | API |
|-----------|-------------|-----|
| `OrcCounter` | `LongAdder` | `increment()`, `decrement()`, `add(long)`, `get()`, `reset()` |
| `OrcGauge<T>` | `AtomicReference<T>` | `set(T)`, `get()`, `compareAndSet(T, T)` |
| `OrcFlag` | `AtomicBoolean` | `set()`, `clear()`, `toggle()`, `get()` |
| `OrcAccumulator` | `DoubleAccumulator` | `accumulate(double)`, `get()`, `reset()` |
| `OrcMap<K,V>` | `ConcurrentHashMap` | `get`, `put`, `putIfAbsent`, `computeIfAbsent`, `merge`, `remove`, `containsKey`, `size` |

Child scopes inherit the parent's primitive namespace. All primitives are thread-safe by construction (D13).

**YAML declaration and usage:**

```yaml
shared:
  events-fired: counter
  market-state: gauge
  is-ready: flag
  total-volume: accumulator                          # defaults: op=sum, identity=0.0
  max-price:
    type: accumulator
    op: max                                          # DoubleBinaryOperator: sum, max, min
    identity: -Infinity                              # initial value
  positions: map

# Reading
when: ${shared.events-fired} > 1000
when: ${shared.market-state} == 'STRESSED'
data: { pos: ${shared.positions[AAPL]} }

# Writing (step-level update: block)
update:
  shared.events-fired: +1                         # counter increment
  shared.total-volume: += ${trade.quantity}        # accumulator add
  shared.market-state: ${new-state}                # gauge set
  shared.is-ready: true                            # flag set
  shared.positions[${symbol}]:                     # map operations
    default: { quantity: 0, avg_price: 0.0 }       # computeIfAbsent
    merge: ".quantity + $new.quantity"              # merge (JQ)
  shared.positions[${symbol}] ?= { quantity: 0 }   # putIfAbsent
```

**Accumulator defaults:** The scalar form `total-volume: accumulator` defaults to `op=sum` (`Double::sum`) with `identity=0.0`. Custom operators use the object form. Three built-in operators: `sum` (Double::sum, identity 0.0), `max` (Double::max, identity -Infinity), `min` (Double::min, identity +Infinity). Custom `DoubleBinaryOperator` requires Java (Tier 3/4).

**Update: block parsing model:** The `update:` block is parsed as raw YAML key-value pairs into AST nodes — no type context needed at parse time. At runtime, the step executor resolves each key's primitive type from the `shared:` declarations and interprets the value accordingly. Syntax disambiguation is purely lexical:

| Syntax pattern | Operation | Applicable types |
|---------------|-----------|-----------------|
| `+N` or `-N` | increment/decrement by N | counter |
| `+= expr` | accumulate expression value | accumulator |
| `true` / `false` | set/clear | flag |
| map with `default:`/`merge:` keys | computeIfAbsent/merge | map |
| `key ?= value` | putIfAbsent | map |
| anything else | set | gauge |

A type mismatch (e.g., `+1` on a gauge) is a runtime validation error with a clear message referencing the `shared:` declaration.

### 2.8 ScenarioScope as Lifecycle Manager (D12)

ScenarioScope owns primitives, threads, and nested scopes. Its `close()` releases all owned resources:
- Calls `releaseForClose()` on every `OrcPrimitive` in the scope (D9a — no instanceof chains)
- Interrupts spawned threads (D10 cancellation contract)
- Recursively closes child scopes (depth-first, within the total close budget)

The `OrcPrimitive.releaseForClose()` interface (D9a) replaces the current concrete-type instanceof chain. Each primitive's cleanup semantics are encoded in its own implementation, not in DefaultScenarioScope. This also means `SimulatedPrimitiveFactory` implementations participate in lifecycle cleanup automatically — custom implementations that don't extend the `Default*` classes are no longer invisible to close().

---

## Part 3: Expression and Escape Model

### 3.1 Four-Tier Escape Model (D14)

| Tier | Syntax | Power | Debugging |
|------|--------|-------|-----------|
| 1. Expression | `transform: ".price * 1.1"` | JQ/MVEL one-liners | Journal + step tracing |
| 2. Compute block | `compute: \| .prices \| map(...)` | Multi-line expressions | Journal + step tracing |
| 3. Bean invoke | `invoke: Bean::method` | Full CDI stack | IntelliJ breakpoint on method |
| 4. @ScenarioAction | `action: name` | Stateful, scope-aware | IntelliJ full step-through |

### 3.2 Bean Invoke Syntax

**Module boundary:** yaml-core parses `invoke:` into an `InvokeDirective` AST node that captures the bean/method reference as strings — no CDI dependency. CDI bean resolution happens at runtime in the consumer module (simulation-config or orchestration-runtime). This follows the same pattern as `ComputeBlock` — yaml-core creates the AST, the runtime evaluates it.

| Concern | Module | Responsibility |
|---------|--------|---------------|
| Parsing `invoke: Bean::method` → `InvokeDirective` | yaml-core | String capture only — no CDI types |
| CDI bean lookup, method resolution, invocation | consumer module | Full CDI container access |
| Method parameter binding from `input:` | consumer module | Reflection + `-parameters` flag |

**CDI bean method call:**
```yaml
invoke: io.casehub.trading.AlertRepository::save
input: ${alert}
output: shared.save-result
```

Resolves `AlertRepository` as a CDI bean, gets the managed instance (injected dependencies, transactions, interceptors), calls `save(input)`.

**Variable instance method call:**
```yaml
invoke: ${order}::cancel
input: "Market closed"
```

Resolves `${order}` from scope, calls `cancel("Market closed")` on the instance.

**Multi-argument with expressions:**
```yaml
invoke: OrderService::placeOrder
input:
  symbol: ${instrument.symbol}
  price:
    transform: ".price * (1 + .spread)"
  quantity: ${trade.quantity}
output: shared.order-result
```

Each input element can be a variable reference, literal, expression, or compute block. Named parameters require `-parameters` compiler flag (standard in Quarkus). Positional array form also supported.

### 3.3 Fidelity Safeguards

| Gap | Solution | Result |
|-----|----------|--------|
| Type-safe events | yaml-codegen JSON Schema validation at parse time + type-validated channels (D8) | Equivalent or better — schema constraints are stricter than Java constructors |
| Java operations | Tier 3 `invoke:` — CDI bean call, full application stack | Full — no operation lost |
| Debugging | IntelliJ breakpoints on `invoke:` methods + step tracing journal | Partial — Tier 3/4 methods get full IntelliJ debugging; Tier 1/2 rely on journal + step tracing |

**Future: MCP scenario debugging.** An MCP-based debugger for YAML scenarios (`breakpoint`, `inspect`, `step`, `modify`) is a natural extension of the interpreted execution model (§5.1) but is NOT part of this design. It will be designed separately and should NOT be cited as evidence for current fidelity parity.

---

## Part 4: Design Rules

### 4.1 Virtual-Thread Safety (D13)

All orchestration primitives MUST use `java.util.concurrent` locks or lock-free primitives. NEVER `synchronized`. This is a design rule — `synchronized` pins virtual threads to carrier threads.

Current implementations verified compliant: DefaultOrcStateMachine (AtomicReference CAS), DefaultOrcChannel (ReentrantLock via LinkedBlockingQueue), DefaultOrcSemaphore (j.u.c.Semaphore), DefaultOrcLatch (CountDownLatch), DefaultOrcSignal (ReentrantLock + Condition for repeatable mode, CompletableFuture for one-shot mode, volatile signalled flag).

### 4.2 Concurrency Model — Non-Goals

The concurrency model is Web Worker-style. Explicitly NOT:
- Actor frameworks
- Dataflow graph engines
- Coordination middleware
- Complex data sharing/passing techniques

Concurrency is: spawn + channels + shared constructs + lifecycle. The power is in composition.

### 4.3 Convergence Direction

Simulation's execution model should eventually be expressible as orchestration YAML rather than programmatic API. The spawn primitive supports both Java Runnables (backward compat) and YAML sub-scenario execution (future). The simulation API becomes a backward-compat adapter, not the primary model.

### 4.4 yaml-core Zero-Dependency Constraint

yaml-core remains zero-dependency (pure Java + java.util.concurrent). New primitives (OrcCounter, OrcGauge, OrcFlag, OrcAccumulator, OrcMap, BlockingOrcStateMachine, PrimitiveFactory, SpawnedTask) live in yaml-core's orchestration package. Bridges to simulation and CDI live in simulation-config and consumer modules.

**J2CL transpilability boundary:** The J2CL transpilability claim in the pom.xml description applies to yaml-core's **declaration primitives** (VariableResolver, ForEachExpander, Truthiness, CsvParser, ConditionalInclude, shorthand parsing) — the original zero-dependency YAML processing layer. The **orchestration package** (added in #386) is NOT J2CL-transpilable — it uses `java.util.concurrent` types (ReentrantLock, CountDownLatch, Semaphore, CompletableFuture, LinkedBlockingQueue, AtomicReference, LongAdder, DoubleAccumulator, ConcurrentHashMap) that are absent from J2CL's JRE emulation. Browser parity for orchestration is achieved through a parallel TypeScript implementation (§5.2), not J2CL transpilation. The pom.xml description should be updated to: "Pure Java YAML declaration primitives — variable resolution, forEach expansion, conditional inclusion, CSV data sources, iteration groups, orchestration coordination. Zero dependencies. Declaration layer is J2CL-transpilable; orchestration has parallel TypeScript implementation."

---

## Part 5: Execution Model + Browser Parity (D15)

### 5.1 Interpreted Dispatch with Compiled Expressions

YAML scenarios are NOT code-generated. The execution model is:

1. **Parse time:** YAML → AST. Expressions compiled into `CompiledExpression` instances (cached). ComputeBlock engine resolved. Variable prefix rewriting (D2) applied.
2. **Runtime:** Scenario runner walks the AST — evaluates conditions, dispatches steps, manages spawn/channels/shared state. Dynamic step dispatch.

Interpreted because: dynamic behavior (speed changes, pause/resume, breakpoints), `invoke:` CDI bean calls, MCP debugging introspection all require runtime control. The hot path (expression evaluation) is compiled at parse time — dispatch is I/O-bound.

### 5.2 TypeScript/Browser Parity

yaml-core's declaration primitives are J2CL-transpilable. The orchestration package uses a parallel TypeScript implementation (not J2CL transpilation — see §4.4). The same YAML scenario must produce identical results on JVM and in the browser.

| Java (JVM) | TypeScript (Browser) |
|-----------|---------------------|
| `spawn()` → virtual thread | `new Worker()` → Web Worker |
| `OrcChannel` → `LinkedBlockingQueue` | `MessagePort` → structured cloning |
| `OrcCounter/OrcGauge/OrcFlag` | `SharedArrayBuffer` + `Atomics` |
| `awaitState()` → blocking | `Atomics.wait()` in Worker / async `await` on main thread |
| `OrcMap` → `ConcurrentHashMap` | Shared-state Worker (message-passing emulation) |
| `scope.close()` → `Thread.interrupt()` | `worker.terminate()` |

**Key constraint:** No primitive API can depend on JVM-specific blocking semantics that can't be emulated with Web Workers + SharedArrayBuffer + Atomics. The TypeScript scenario runner is async — `await channel.receive()` instead of blocking.

**OrcMap browser parity caveat:** On the JVM, `ConcurrentHashMap` provides linearizable compound operations (`computeIfAbsent`, `merge`, `putIfAbsent`) with concurrent access. On the browser, the shared-state Worker serializes all map operations through a single message queue. This provides identical correctness guarantees — serial execution through the Worker is linearizable by construction. However, the browser implementation is effectively single-threaded for map access. This is a known performance fidelity reduction, not a correctness gap. "Identical results" means: given the same operations in the same logical order, both runtimes produce the same final state. It does NOT mean: both runtimes exhibit the same concurrency throughput characteristics.

---

## Module Impact

| Module | Changes |
|--------|---------|
| `yaml-core` | D1 (shorthand sealed types), D2 (VariablePrefixRewriter), D3 (ComputeBlock record), D5 (BlockingOrcStateMachine interface + impl), D9 (PrimitiveFactory interface), D10 (spawn/childScope on ScenarioScope, SpawnedTask), D11 (OrcCounter, OrcGauge, OrcFlag, OrcAccumulator, OrcMap), D12 (lifecycle close extensions) |
| `platform-api` | D4 (ExpressionContext enum, ExpressionEngineRegistry defaults) |
| `expression` | D4 (register MVEL/JQ defaults at startup) |
| `simulation-config` | D6 (SpeedMultiplier producer), D7 (CorpusVariableSource), D8 (FeedBinding + feed: config) |
| `schema-generator` | D1 (ShorthandModule definitions for new directive types) |

## References

- ForEachDirective.parse() — yaml-core shorthand pattern
- ShorthandModule — schema-generator scalar-or-object JSON Schema
- VariableResolver — yaml-core variable resolution
- OrcStateMachine / DefaultOrcStateMachine — yaml-core orchestration
- ScenarioScope / DefaultScenarioScope — yaml-core scope management
- SpeedMultiplier — yaml-core runtime SPI
- ExpressionEngine / ExpressionEngineRegistry — platform-api expression
- TemporalSimulationDriver — simulation-core temporal execution
- TimedSequence — simulation-core event sequences
- SimulationRuntime — simulation-core runtime
- GraphCaseMemoryStore — platform-api extension interface pattern
- casehubio/platform#386 — runtime orchestration primitives (landed)
- casehubio/platform#410 — correlate, deadline propagation, condition combinators (next)
