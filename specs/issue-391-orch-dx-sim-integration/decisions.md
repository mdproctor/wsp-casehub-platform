# Decisions — #391 DX Refinements + #405 Simulation–Orchestration Integration

## D1: Shorthand forms — per-type parse(Object) factory methods

**Choice:** Follow ForEachDirective pattern — each directive type gets a sealed type with `parse(Object)` factory that handles both scalar (shorthand) and Map (full form).
**Alternatives:**
- Generic ShorthandParser utility in yaml-core — over-abstraction for a handful of types
- yaml-jackson mixin/module (Jackson-level deserialization) — couples parsing to Jackson, breaks zero-dep constraint
**Rationale:** The pattern is proven (ForEachDirective), zero-dep, and self-documenting. ShorthandModule in schema-generator already handles the JSON Schema side.
**Trade-offs:** Each new directive type needs its own parse logic — no shared parser. Acceptable given the small number of directives.
**Sources:** ForEachDirective.parse(), ShorthandModule in schema-generator, yaml-core zero-dep constraint
**Exploration:** quick
**Status:** captured

## D2: Default variable prefix — parse-time prefix rewriting via VariablePrefixRewriter

**Choice:** Add `VariablePrefixRewriter` utility to yaml-core. Consumers declare a default prefix (in YAML document metadata or programmatically) and call the rewriter as an explicit pre-processing step before variable resolution. Bare references (`${regime}`) are rewritten to `${var.regime}` at parse time. VariableResolver is unchanged — bare references remain a hard error.
**Alternatives:**
- `withDefaultPrefix(String)` on VariableResolver (original choice) — silently converts errors into fallback resolution; makes YAML documents context-dependent when different consumers set different defaults
- Constructor parameter / builder config — heavier API change for something that's a parse-time concern
- Automatic prefix inference from registered scopes — unpredictable when multiple scopes exist
**Rationale:** Parse-time rewriting preserves VariableResolver's error semantics (bare references = error). The rewrite is visible in the parsed AST — debuggable, not magical. YAML documents are self-describing: the `defaultPrefix:` declaration is in the document, not buried in the caller's Java code. Shared YAML snippets behave identically regardless of which consumer loads them.
**Trade-offs:** Requires a pre-processing step before variable resolution. Consumers that don't declare a default prefix see no change — bare references still error.
**Sources:** VariableResolver API (withScope, withChainedScope, withObjectScope patterns), issue #391 proposal
**Exploration:** quick
**Revised from:** R1-02, R1-03 — reviewer correctly identified that `withDefaultPrefix()` silently converts errors into fallback resolution and makes YAML documents context-dependent.
**Status:** revised

## D3: Compute blocks — yaml-core data model + platform compilation

**Choice:** Add `ComputeBlock` record to yaml-core (engine key + expression text, engine non-optional). The YAML parser resolves the engine default from ExpressionContext (via D4) at parse time when the author omits `engine:`, baking the resolved engine into the record. Compilation happens at consumer level via ExpressionEngineRegistry. The `compute:` YAML key and step-decorator semantics are a consumer-level binding concern (application-tier YAML scenario runner).
**Alternatives:**
- Full compute infrastructure in yaml-core — violates zero-dep (would need ExpressionEngine dependency)
- Compute blocks entirely in consumer modules — loses reusability for other consumers
- Engine optional on ComputeBlock with context-aware defaults at evaluation time (original choice) — same ComputeBlock crossing contexts (refactoring, shared snippets) silently changes engine
**Rationale:** Clean separation: yaml-core owns the data model (what), platform-api owns the compilation (how), consumer modules own the step binding (where). Each layer stays within its dependency budget. Non-optional engine makes ComputeBlock self-contained and context-independent — the record carries its engine everywhere.
**Trade-offs:** Consumers must wire ComputeBlock to ExpressionEngineRegistry themselves — no automatic compilation. Acceptable since compilation is inherently a runtime/CDI concern.
**Depends on:** D4 (expression defaults determine which engine to bake into ComputeBlock at parse time)
**Sources:** yaml-core zero-dep constraint, ExpressionEngine/ExpressionEngineRegistry in platform-api
**Exploration:** quick
**Revised from:** R1-05 — reviewer correctly identified that nullable engine creates context-dependent ambiguity. R1-06 — clarified "pages" → consumer-level binding.
**Status:** revised

## D4: Expression engine defaults — ExpressionContext enum + registry defaults

**Choice:** Add `ExpressionContext` enum (CONDITION, TRANSFORM, FILTER) to platform-api. Add `registerDefault(context, engineType)` and `resolveDefault(context)` to ExpressionEngineRegistry. Platform defaults: CONDITION → "mvel", TRANSFORM/FILTER → "jq". Overridable.
**Alternatives:**
- Hardcoded defaults in consumers — duplicated, inconsistent across modules
- Configuration-driven (application.properties) — overhead for something that rarely changes; convention is better here
**Rationale:** Conventions reduce ceremony for the 80% case (issue's stated principle). Registry-based registration is consistent with existing ExpressionEngineRegistry patterns and allows override without configuration.
**Trade-offs:** Adds a new concept (ExpressionContext) to platform-api. If future engines arrive (e.g., SpEL), the convention may need revisiting — but registerDefault() handles that.
**Sources:** ExpressionEngineRegistry SPI, MvelExpressionEngine, JQExpressionEngine, issue #391 proposal
**Exploration:** quick
**Status:** captured

## D5: OrcStateMachine two-tier — simple + blocking concurrent variant

**Choice:** Keep `OrcStateMachine<S>` interface unchanged. `BlockingOrcStateMachine<S>` is an extension interface (following the `GraphCaseMemoryStore extends CaseMemoryStore` pattern) that adds `awaitState(S)`, `awaitState(S, Duration)`, `awaitTransition(S from, S to)`. Two implementations: `DefaultOrcStateMachine<S>` (current — AtomicReference CAS, handlers, no blocking) for synchronous use, and `DefaultBlockingOrcStateMachine<S>` implementing `BlockingOrcStateMachine<S>` (layers ReentrantLock + Condition, SpeedMultiplier-aware timeouts via constructor injection with `SpeedMultiplier.identity()` default). ScenarioScope factory returns blocking variant by default — ScenarioScope's primary use case is step coordination, which requires blocking wait. `SpeedMultiplier.identity()` is a new static factory method on the existing `@FunctionalInterface`: `static SpeedMultiplier identity() { return () -> 1.0; }`, establishing the contract that 1.0 = real-time (1:1 wall-clock mapping).
**Alternatives:**
- Single implementation with optional blocking — flag-based behavior is fragile
- OrcStateMachine without blocking wait — leaves TemporalSimulationDriver unable to use it (needs pause/resume coordination)
- Default methods throwing UnsupportedOperationException on OrcStateMachine — Liskov violation; the GraphCaseMemoryStore pattern uses extension interfaces, not default-throw methods
**Rationale:** Two-tier lets each consumer pick the right tool. Extension interface pattern (not default-throw on base interface) preserves Liskov substitution. Blocking variant unlocks TemporalSimulationDriver lifecycle, scenario step coordination, and deadline cancellation (#410). SpeedMultiplier is already in yaml-core, no new dependency. Blocking as ScenarioScope default is correct because ScenarioScope's purpose IS coordination — consumers not needing blocking use DefaultOrcStateMachine directly.
**Trade-offs:** Two implementations to maintain. Acceptable — the blocking variant is thin (wraps base with lock + condition).
**Sources:** DefaultOrcStateMachine, TemporalSimulationDriver (volatile + ReentrantLock), SpeedMultiplier SPI, GraphCaseMemoryStore extension interface pattern, issue #410 deadline propagation
**Exploration:** quick
**Revised from:** R1-11 — clarified that BlockingOrcStateMachine is an extension interface, not a concrete-only class. R1-13 — added SpeedMultiplier.identity() as explicit SPI contract.
**Status:** revised

## D6: SpeedMultiplier wiring — CDI producer in simulation-config

**Choice:** Single CDI `@Produces` method in simulation-config: `SpeedMultiplier speedMultiplier(SimulationRuntime runtime) { return runtime::globalSpeed; }`. ScenarioScope passes it to BlockingOrcStateMachine instances. Orchestration primitives consume via CDI.
**Alternatives:**
- Direct SimulationRuntime references in orchestration — couples orchestration to simulation instead of using the SPI
- Configuration-driven speed — loses runtime dynamism (speed changes during simulation)
**Rationale:** Method reference is the thinnest possible bridge. SpeedMultiplier SPI already exists in yaml-core for exactly this purpose. One line of code.
**Trade-offs:** Requires simulation-config on the classpath for speed-aware orchestration. Without it, SpeedMultiplier.identity() default applies — graceful degradation.
**Depends on:** D5 (BlockingOrcStateMachine consumes SpeedMultiplier)
**Sources:** SpeedMultiplier SPI, SimulationRuntime.globalSpeed(), yaml-core zero-dep constraint
**Exploration:** quick
**Status:** captured

## D7: SimulationCorpus as VariableSource — corpus prefix scope for forEach

**Choice:** New `CorpusVariableSource implements ObjectVariableSource` in simulation-config. Prefix `corpus` — `${corpus.trades}` resolves to the list of input objects from the named corpus. Drill-down via ObjectVariableSource: `${corpus.trades[0].symbol}`. Registered on VariableResolver via `withObjectScope("corpus", corpusSource)`.
**Alternatives:**
- Corpus integration in yaml-core — violates zero-dep (simulation-api dependency)
- Manual Java bridge per consumer — duplicated, no YAML-level reuse
**Rationale:** Bridge lives in simulation-config where both dependencies (yaml-core VariableResolver, simulation-api SimulationCorpus) are available. ForEachExpander already accepts any collection — no yaml-core changes needed.
**Trade-offs:** Corpus entries must be keyed by qualified name. InvocationRecord<I,O>.input() is the iterated value — consumers need corpus entries with meaningful input types.
**Sources:** SimulationCorpus SPI, ObjectVariableSource, ForEachExpander, VariableResolver.withObjectScope
**Exploration:** quick
**Revised from:** R1-15 — removed spurious D2 dependency. `${corpus.trades}` uses an explicit `corpus` prefix; D2's default prefix mechanism is irrelevant.
**Status:** revised

## D8: Temporal profile → OrcChannel feed — declarative event-to-channel wiring

**Choice:** New `feed:` property in simulation config YAML on temporal profiles. Two-phase wiring: (1) at startup, simulation-config reads YAML and creates `FeedBinding` records (`feedName`, `channelName`, `profileRef`, `eventType`); (2) at scenario start, the scenario runner calls `feedBinding.activate(scope)` which creates the TemporalEventSink<E> capturing the scope: `event -> scope.channel(channelName, eventType).send(event)`. Declarative end-to-end simulation: temporal profile drives events, orchestration scenario consumes them.
**Type validation:** `FeedBinding` records the expected event type (`Class<E>`) from the temporal profile's generic parameter. `OrcChannel` gains an optional type-token overload: `channel(String name, Class<T> type)`. When a type token is provided, `send()` validates `type.isInstance(value)` before enqueuing, surfacing type mismatches at wiring/delivery time with a descriptive error instead of a raw `ClassCastException`.
**Alternatives:**
- Java-only wiring — works but requires consumer code for every scenario
- Document as pattern only — misses the opportunity for declarative scenario testing
**Rationale:** Implementation is small (config parsing + sink wiring). Capability is significant: declarative simulation-driven scenario testing without Java bridge code. Temporal profiles already have YAML config — `feed:` is a natural extension. Two-phase wiring solves the lifecycle mismatch: CDI beans initialize at startup, ScenarioScope is per-scenario-execution.
**Trade-offs:** Tight coupling between temporal profile naming and channel naming. Mitigated by making `feed:` optional — profiles without it work as before. Type validation is best-effort (YAML can't enforce generic types).
**Sources:** TemporalEventSink<E>, OrcChannel<T>, simulation config YAML, TemporalProfileConfig
**Exploration:** quick
**Revised from:** R1-17 — clarified two-phase wiring lifecycle (startup config → scenario-start activation). R1-18 — added type validation via channel type-token overload.
**Status:** revised

## D9: ScenarioScope simulation — pluggable PrimitiveFactory strategy

**Choice:** Extract `PrimitiveFactory` strategy interface from ScenarioScope's factory methods. ScenarioScope delegates channel(), signal(), stateMachine() etc. to its PrimitiveFactory. Default factory creates real primitives. `SimulatedPrimitiveFactory` returns pre-loaded/scripted primitives (channels with queued messages, pre-fired signals, state machines on specific states). Constructor injection, no CDI required.
**Alternatives:**
- @SimulationEligible + @Decorator on ScenarioScope — requires CDI interception; ScenarioScope isn't always CDI-managed
- @SimulationEligible on individual primitives (OrcChannel, OrcSignal) — primitives are factory-created, @Decorator can't intercept
- Simulation-aware ScenarioScope subclass — hard to compose with other ScenarioScope behaviors
**Rationale:** Strategy pattern keeps ScenarioScope's zero-dep constraint. PrimitiveFactory is a clean extension point that works regardless of DI framework. SimulatedPrimitiveFactory can be configured from simulation YAML corpus data.
**Instance contract:** PrimitiveFactory is stateless — it creates new instances only. ScenarioScope handles caching via `ConcurrentHashMap.computeIfAbsent(name, k -> factory.createX(name))`. The `computeIfAbsent` call guarantees: (a) the factory is called at most once per name, (b) all callers see the same instance (same-name-same-instance contract). PrimitiveFactory implementations have no thread-safety requirements and no instance tracking responsibilities.
**Trade-offs:** Adds a new interface (PrimitiveFactory) and changes ScenarioScope's internal structure. Acceptable — the factory methods already exist, this just names the abstraction.
**Sources:** ScenarioScope factory methods, @SimulationEligible generator, simulation-core patterns
**Exploration:** quick
**Revised from:** R1-20 — documented the same-name-same-instance contract (stateless factory, ScenarioScope handles caching).
**Status:** revised

## D10: Concurrent sub-scenarios — spawn + childScope on ScenarioScope

**Choice:** Add `SpawnedTask spawn(String name, Runnable task)` and `ScenarioScope childScope(String name)` to ScenarioScope. `spawn` starts a virtual thread owned by the scope and returns a `SpawnedTask` handle. `childScope` creates a nested scope — closing a parent closes all children (cancels spawned tasks). Deadlines propagate downward. SpeedMultiplier-aware timeouts on spawned tasks.
**SpawnedTask handle:** Exposes `isDone()`, `isFailed()`, `exception()`, `join()`, `join(Duration timeout)` (SpeedMultiplier-aware). On scope `close()`, all spawned tasks are checked for failures — if any spawned task failed with an uncaught exception, the first failure is reported (subsequent failures suppressed).
**Cancellation contract:** (1) `close()` calls `Thread.interrupt()` on all spawned virtual threads. (2) Spawned tasks are expected to be interrupt-responsive — all orchestration primitives (OrcChannel.send/receive, OrcLatch.await, OrcSemaphore.acquire, BlockingOrcStateMachine.awaitState) throw InterruptedException. (3) After interrupting, `close()` joins each spawned task with a timeout (default: 5s, SpeedMultiplier-aware). (4) Tasks that haven't terminated after timeout are logged as stuck — best-effort cleanup. Virtual threads cannot be forcibly killed. (5) CPU-bound tasks that don't check Thread.interrupted() will delay cleanup but not prevent it.
**Alternatives:**
- Java StructuredTaskScope (JEP 505, Java 25) — not available at Java 21 language level (platform constraint: `--release 21` on Java 26 JVM). Additionally, StructuredTaskScope is one-shot fork-join; spawn is for long-running tasks that live for the scope's lifetime.
- Adopt simulation drivers into scope — couples ScenarioScope to simulation API; too specific
- Phase model (sequential phases containing concurrent groups) — over-structured for the use case
- No concurrency primitive (leave to consumers) — every consumer reimplements fork/join on virtual threads
- spawn(Runnable) without handle (original choice) — spawned task failures invisible, no error propagation path
**Rationale:** `spawn` is the minimal primitive for "run this concurrently." `childScope` is the minimal primitive for "group things with shared lifecycle." Together they give structured concurrency without framework coupling. A spawned task can be a temporal simulation feed, a YAML sub-scenario, or any Runnable — the scope doesn't care what it runs, only that it owns the lifecycle. SpawnedTask handle enables failure detection and structured error propagation.
**Trade-offs:** ScenarioScope grows from a pure factory into a lifecycle manager. Acceptable — it already owns close() and primitive cleanup. Spawn adds thread ownership, which is a natural extension of the same lifecycle model.
**Design direction:** This is the first step toward convergence — simulation's execution model eventually expressible as orchestration YAML rather than programmatic API. The spawn primitive is designed to support both Java Runnables (backward compat) and YAML sub-scenario execution (future).
**Sources:** TemporalSimulationDriver (virtual thread execution), ScenarioScope.close(), Java structured concurrency patterns, issue #405 Direction 1
**Exploration:** quick
**Revised from:** R1-22 — acknowledged Java 21 constraint as explicit trade-off. R1-23 — spawn now returns SpawnedTask handle for error propagation. R1-24 — documented explicit cancellation contract.
**Status:** revised

## D11: Shared-state primitives — OrcCounter, OrcGauge, OrcFlag, OrcAccumulator, OrcMap

**Choice:** Five new ScenarioScope primitives covering the full spectrum of thread-safe shared state:

| Primitive | Java backing | API |
|-----------|-------------|-----|
| `OrcCounter` | `LongAdder` | `increment()`, `decrement()`, `add(long)`, `get()`, `reset()` |
| `OrcGauge<T>` | `AtomicReference<T>` | `set(T)`, `get()`, `compareAndSet(T expect, T update)` |
| `OrcFlag` | `AtomicBoolean` | `set()`, `clear()`, `toggle()`, `get()` |
| `OrcAccumulator` | `DoubleAccumulator` | `accumulate(double)`, `get()`, `reset()`, constructor takes `DoubleBinaryOperator` + identity |
| `OrcMap<K,V>` | `ConcurrentHashMap<K,V>` | `get(K)`, `put(K,V)`, `putIfAbsent(K,V)`, `computeIfAbsent(K, Function)`, `merge(K,V, BiFunction)`, `remove(K)`, `containsKey(K)`, `size()` |

Child scopes inherit the parent's primitive namespace by default. All primitives are thread-safe by construction (D13) — there is nothing unsafe to share. Spawned tasks access primitives through the inherited namespace.

**YAML declaration and usage:**
```yaml
# Declaration
shared:
  events-fired: counter
  market-state: gauge
  is-ready: flag
  total-volume: accumulator
  positions: map

# Reading (via VariableResolver ${shared.X} prefix)
when: ${shared.events-fired} > 1000
when: ${shared.is-ready}
data: { state: ${shared.market-state}, pos: ${shared.positions[AAPL]} }

# Writing (step-level update: block with shorthand)
update:
  shared.events-fired: +1                        # counter increment
  shared.total-volume: += ${trade.quantity}       # accumulator add
  shared.market-state: ${new-state}               # gauge set
  shared.is-ready: true                           # flag set
  shared.positions[${symbol}]:                    # map operations
    default: { quantity: 0, avg_price: 0.0 }      # computeIfAbsent
    merge: ".quantity + $new.quantity"             # merge expression (JQ)
  shared.positions[${symbol}] ?= { quantity: 0 }  # putIfAbsent one-liner
```

**Alternatives:**
- Raw ConcurrentMap on ScenarioScope — loses type safety, users can put non-thread-safe objects in it
- Explicit sharing declarations on spawn (original choice) — unenforceable in Java (closures bypass visibility restrictions), adds ceremony to the 80% case (temporal feeds always need channels), and unnecessary given D13 (all primitives are thread-safe)
- Counter + Gauge only — too limited for trading simulation use cases (accumulators for P&L, maps for per-instrument tracking, flags for market state)
**Rationale:** Each construct has clear semantics and is thread-safe by its type — users can't break safety. The full set covers trading simulation patterns: counters for event tracking, gauges for latest price/state, flags for market open/close, accumulators for running P&L, maps for per-instrument positions. `update:` block with shorthand operators (`+1`, `+=`, `?=`, `default:`/`merge:`) keeps YAML non-verbose. Namespace inheritance (rather than explicit sharing) is the right default because D13 guarantees all primitives are thread-safe, making the sharing boundary a documentation concern — and the YAML/Java source code already documents what each fork accesses. For YAML forks, scope is fully enforced at parse time (YAML can only reference declared constructs by name).
**Trade-offs:** Five new primitive types. Acceptable — each is thin (wraps a j.u.c atomic/concurrent type), and the set covers the full spectrum. OrcMap's `computeIfAbsent`/`merge` need expression bridge for YAML (uses D3 ComputeBlock + D4 expression defaults).
**Depends on:** D10 (spawn/childScope provides the fork model), D3/D4 (expression bridge for OrcMap merge/compute operations), D13 (virtual-thread safety — all constructs use j.u.c, never synchronized), D14 (YAML capability equivalence guides primitive design)
**Design constraints:**
- No actor frameworks, no dataflow graph engines, no coordination middleware. The concurrency model is: spawn + channels + shared constructs + lifecycle.
**Sources:** java.util.concurrent.atomic (LongAdder, AtomicReference, AtomicBoolean, DoubleAccumulator), ConcurrentHashMap, trading simulation use cases
**Exploration:** quick
**Revised from:** R2-03, R2-04 — removed explicit sharing model (unenforceable in Java, unnecessary given D13's thread-safety guarantee). R2-05 — reworded concurrency constraint (OrcChannel IS CSP; the constraint targets actor frameworks and middleware, not channels). R2-06 — eliminated sharing ceremony; child scopes inherit parent namespace by default. R2-07 — extracted YAML capability equivalence to D14.
**Status:** revised

## D12: ScenarioScope as lifecycle manager — explicit architectural role

**Choice:** ScenarioScope is the lifecycle manager for orchestration scenarios, owning primitives, threads, and nested scopes. Its `close()` releases all owned resources: closes channels, counts down latches, signals unsignalled signals, shuts down semaphores, interrupts spawned threads, and recursively closes child scopes. This is the same lifecycle model extended to new resource types, not a role change.
**Alternatives:**
- Separate `ExecutionContext` composing a ScenarioScope — adds a new type for no architectural benefit; two closely-related objects that must be passed together
- `ScenarioRunner` that owns lifecycle while ScenarioScope stays a factory — the runner would need access to all factory methods (spawned tasks create primitives), artificially separating things that belong together
- ScenarioScope stays a primitive factory only; lifecycle managed externally — breaks encapsulation; callers must know which primitives to clean up
**Rationale:** ScenarioScope already implements `AutoCloseable` and its `close()` already performs lifecycle management for all primitive types. Adding thread ownership (D10 spawn) and nested scope hierarchy (D10 childScope) extends the same model to new resource types. `close()` for resource cleanup and `close()` for structured concurrency teardown are the same operation: release everything this scope owns.
**Trade-offs:** ScenarioScope's API surface grows. Acceptable — the alternative (separate lifecycle manager) adds complexity without architectural benefit.
**Sources:** DefaultScenarioScope.close() (current implementation), AutoCloseable contract, D9 (PrimitiveFactory), D10 (spawn/childScope)
**Surfaced by:** R1-26 — reviewer correctly identified this as an implicit decision that should be explicit.
**Exploration:** quick
**Status:** captured

## D13: Virtual-thread safety constraint on orchestration primitives

**Choice:** All orchestration primitives (OrcChannel, OrcStateMachine, OrcSemaphore, OrcLatch, OrcSignal, OrcCounter, OrcGauge) MUST use `java.util.concurrent` locks (`ReentrantLock`, `Semaphore`, `CountDownLatch`, `AbstractQueuedSynchronizer`) or lock-free primitives (`AtomicReference`, `volatile`). NEVER use `synchronized` blocks or methods. This is a design rule, not a recommendation.
**Rationale:** D10 spawns virtual threads. `synchronized` blocks pin virtual threads to carrier threads, creating a throughput bottleneck proportional to the number of carrier threads (typically CPU count). `java.util.concurrent` locks are virtual-thread-aware since JDK 21 — virtual threads park and unmount from the carrier when they can't acquire the lock. Current implementations are already compliant (verified): DefaultOrcStateMachine (CAS), DefaultOrcChannel (LinkedBlockingQueue/ArrayBlockingQueue with ReentrantLock), DefaultOrcSemaphore (java.util.concurrent.Semaphore), DefaultOrcLatch (CountDownLatch), DefaultOrcSignal (volatile). The constraint prevents future regressions.
**Alternatives:**
- No explicit constraint (status quo) — current implementations happen to be safe, but future primitives could introduce `synchronized` without anyone noticing
- Document as a guideline rather than a rule — guidelines get ignored under time pressure
**Trade-offs:** Developers must be aware of the constraint when adding new primitives. Acceptable — the constraint is simple and the rationale is clear.
**Sources:** JEP 444 (Virtual Threads, JDK 21), DefaultOrcChannel (LinkedBlockingQueue internals), DefaultOrcStateMachine (AtomicReference), D10 (virtual thread spawn)
**Surfaced by:** R1-28 — reviewer correctly identified this as an implicit constraint that should be explicit.
**Exploration:** quick
**Status:** captured

## D14: YAML capability equivalence — four-tier escape model, no fidelity loss

**Choice:** YAML simulation scenarios must be capability-equivalent to the programmatic Java API. No reduced fidelity — different mechanisms, same guarantees. Four-tier escape model:

| Tier | Syntax | Power | Debugging |
|------|--------|-------|-----------|
| 1. Expression | `transform: ".price * 1.1"` | JQ/MVEL data transforms | Journal + step tracing |
| 2. Compute block | `compute: \| ...` | Multi-line expressions | Journal + step tracing |
| 3. Bean invoke | `invoke: Bean::method` | Full CDI stack — any managed bean, any method | IntelliJ breakpoint on method |
| 4. @ScenarioAction | `action: name` | Stateful, scope-aware, multi-step | IntelliJ full step-through |

**Bean invoke (tier 3):** `invoke: io.casehub.trading.AlertRepository::save` resolves `AlertRepository` as a CDI bean, gets the managed instance (injected dependencies, transactions, interceptors), calls `save(input)`. Any existing CDI bean method is callable from YAML — no adapter, no annotation, no ceremony. This makes tier 4 (@ScenarioAction) a niche tool for multi-step stateful logic only.

**Fidelity safeguards — closing all three gaps:**

| Gap | Solution | Fidelity |
|-----|----------|----------|
| Type-safe event construction | yaml-codegen JSON Schema validation at parse time + type-validated channels (D8). Schema constraints can be stricter than Java constructors. | Equivalent or better |
| Arbitrary Java operations | Tier 3 `invoke:` — CDI bean method call. Full application stack (database, HTTP, messaging, caching) via existing beans. | Full — no operation lost |
| Debugging | MCP-based scenario debugger (pause/inspect/step/modify via MCP tools) + IntelliJ breakpoints on invoke'd Java methods. | Equivalent — different mechanism |

**MCP scenario debugging primitives:**
- `breakpoint(scenario, step)` — pause before step execution
- `inspect(scope)` — return full state tree (channels, shared constructs, step results, variables)
- `step(scope)` — execute one step, return result, stay paused
- `modify(scope, construct, value)` — set gauge, send to channel, set counter

**Fidelity constraint:** If a common simulation pattern requires Java escape (tier 3/4), that is a YAML gap to fix — not a feature. The YAML tier must cover the 80% case without escape. Escape to Java is a clean bridge, not a crutch.

**Alternatives:**
- Three-tier model without `invoke:` (original) — forces @ScenarioAction for any Java integration, adding ceremony for simple method calls
- Full YAML parity (zero Java escape) — too ambitious; some patterns (custom guards, complex merge logic) are inherently programmatic
- No fidelity constraint — risks creating a toy YAML layer that always falls back to Java
**Rationale:** The four-tier model closes all fidelity gaps. Tiers 1-2 are YAML-native. Tier 3 (`invoke:`) gives YAML full access to the CDI application stack with zero ceremony — any bean, any method, fully managed instance. Tier 4 (@ScenarioAction) handles the remaining niche of stateful scope-aware logic. MCP-based debugging provides equivalent (and in some ways superior — remote, AI-assistable) debugging capability.
**Trade-offs:** YAML schema complexity increases with four tiers. The `invoke:` tier requires CDI bean resolution at runtime — class not found or method not found errors surface at execution time, not parse time. Acceptable — the same is true for @ScenarioAction references.
**Depends on:** D3/D4 (expression tiers), D8 (type-validated channels), D11 (shared-state YAML syntax)
**Design constraint:** YAML simulation expression must be capability-equivalent to the programmatic API. The four-tier escape model ensures this. If a common simulation pattern requires Java escape, that's a YAML gap to fix, not a feature.
**Strategic context:** This is the differentiator from Ansible playbooks. Ansible has sequential tasks + parallel forks + Jinja2 templates. casehub YAML has temporal execution + concurrent data feeds + typed channels + speed-multiplied time + four-tier expression power + MCP debugging. No playbook language does this.
**Sources:** Issue #405 Direction 1, CDI bean resolution, MCP tool model, TemporalDriverService (existing pause/resume), StepResultStore (existing state), four-tier escape model
**Surfaced by:** R2-07 (three-tier version), evolved to four-tier via brainstorm discussion.
**Exploration:** deep-analysis
**Status:** captured
