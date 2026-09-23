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
**Trade-offs:** ScenarioScope grows from a pure factory into a lifecycle manager. Acceptable — it already owns close() and primitive cleanup. Spawn adds thread ownership, which is a natural extension (see D12).
**Design direction:** This is the first step toward convergence — simulation's execution model eventually expressible as orchestration YAML rather than programmatic API. The spawn primitive is designed to support both Java Runnables (backward compat) and YAML sub-scenario execution (future).
**Sources:** TemporalSimulationDriver (virtual thread execution), ScenarioScope.close(), Java structured concurrency patterns, issue #405 Direction 1
**Exploration:** quick
**Revised from:** R1-22 — acknowledged Java 21 constraint as explicit trade-off. R1-23 — spawn now returns SpawnedTask handle for error propagation. R1-24 — documented explicit cancellation contract.
**Status:** revised

## D11: Explicit shared-state visibility — OrcCounter, OrcGauge, declared sharing

**Choice:** Add `OrcCounter` (thread-safe increment/get) and `OrcGauge<T>` (thread-safe set/get latest value) as ScenarioScope primitives. When spawning a fork, explicitly declare which constructs cross the boundary via a builder: `.sharing(counter).sharing(gauge).feeding(channel)`. Nothing is implicitly shared — if a construct isn't declared, the fork can't see it. Parent creates constructs; forks read/update them.
**Alternatives:**
- Raw ConcurrentMap on ScenarioScope — loses type safety, users can put non-thread-safe objects in it
- Implicit visibility (fork sees all parent primitives) — breaks isolation, hard to reason about data flow
- No shared state at all (channels only) — forces message-passing overhead for simple observable state like counters
**Rationale:** Web Worker model — explicit data crossing the boundary, thread-safe by construction. Counters and gauges cover the common cases (progress tracking, event counts, observable state) without exposing raw concurrent data structures. Declared sharing documents the interface between parent and fork.
**Trade-offs:** Two new primitive types (OrcCounter, OrcGauge). The sharing declaration adds verbosity to spawn. Acceptable — explicitness prevents subtle concurrency bugs.
**Depends on:** D10 (spawn/childScope provides the fork model this builds on)
**Design constraints:**
- No complex concurrency patterns (actors, CSP, dataflow). No data sharing/passing frameworks.
- Concurrency model is Web Worker-style: spawn + channels + declared shared constructs + lifecycle.
- YAML simulation expression must be capability-equivalent to the programmatic API. The three-tier escape model ensures this — YAML tier must cover the 80% case without escape.
**Sources:** Web Worker postMessage/SharedArrayBuffer model, ConcurrentMap/AtomicLong/AtomicReference patterns
**Exploration:** quick
**Status:** captured

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
