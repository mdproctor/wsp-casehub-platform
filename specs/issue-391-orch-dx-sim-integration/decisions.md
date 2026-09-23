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

## D2: Default variable prefix — withDefaultPrefix(String) on VariableResolver

**Choice:** Add `withDefaultPrefix(String)` to VariableResolver. Bare references (`${regime}`) try the default prefix as fallback. Scoped prefixes always win.
**Alternatives:**
- Constructor parameter / builder config — heavier API change for something that's a runtime concern
- Automatic prefix inference from registered scopes — unpredictable when multiple scopes exist
**Rationale:** Immutable copy via withDefaultPrefix() matches existing VariableResolver API style (withScope, withChainedScope, etc.). Resolution order is clear: exact match → default prefix → deferred/exception.
**Trade-offs:** Adds one more concept to VariableResolver. Bare references become ambiguous if the default prefix changes between contexts — callers must be explicit about which prefix is the default.
**Sources:** VariableResolver API (withScope, withChainedScope, withObjectScope patterns), issue #391 proposal
**Exploration:** quick
**Status:** captured

## D3: Compute blocks — yaml-core data model + platform compilation

**Choice:** Add `ComputeBlock` record to yaml-core (engine key + expression text, engine optional). Compilation happens at consumer level via ExpressionEngineRegistry. The `compute:` YAML key and step-decorator semantics are a pages binding concern.
**Alternatives:**
- Full compute infrastructure in yaml-core — violates zero-dep (would need ExpressionEngine dependency)
- Compute blocks entirely in pages — loses reusability for other consumers
**Rationale:** Clean separation: yaml-core owns the data model (what), platform-api owns the compilation (how), pages owns the step binding (where). Each layer stays within its dependency budget.
**Trade-offs:** Consumers must wire ComputeBlock to ExpressionEngineRegistry themselves — no automatic compilation. Acceptable since compilation is inherently a runtime/CDI concern.
**Depends on:** D4 (expression defaults determine which engine is used when ComputeBlock.engine is null)
**Sources:** yaml-core zero-dep constraint, ExpressionEngine/ExpressionEngineRegistry in platform-api
**Exploration:** quick
**Status:** captured

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

**Choice:** Keep `OrcStateMachine<S>` interface unchanged. Two implementations: `DefaultOrcStateMachine<S>` (current — AtomicReference CAS, handlers, no blocking) for synchronous use, and `BlockingOrcStateMachine<S>` (layers ReentrantLock + Condition, adds `awaitState(S)`, `awaitState(S, Duration)`, `awaitTransition(S from, S to)`, SpeedMultiplier-aware timeouts via constructor injection with identity default). ScenarioScope factory returns blocking variant by default.
**Alternatives:**
- Single implementation with optional blocking — flag-based behavior is fragile
- OrcStateMachine without blocking wait — leaves TemporalSimulationDriver unable to use it (needs pause/resume coordination)
**Rationale:** Two-tier lets each consumer pick the right tool. Blocking variant unlocks TemporalSimulationDriver lifecycle, scenario step coordination, and deadline cancellation (#410). SpeedMultiplier is already in yaml-core, no new dependency.
**Trade-offs:** Two implementations to maintain. Acceptable — the blocking variant is thin (wraps base with lock + condition).
**Sources:** DefaultOrcStateMachine, TemporalSimulationDriver (volatile + ReentrantLock), SpeedMultiplier SPI, issue #410 deadline propagation
**Exploration:** quick
**Status:** captured

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
**Depends on:** D2 (default prefix may apply when corpus scope is not explicitly prefixed)
**Sources:** SimulationCorpus SPI, ObjectVariableSource, ForEachExpander, VariableResolver.withObjectScope
**Exploration:** quick
**Status:** captured

## D8: Temporal profile → OrcChannel feed — declarative event-to-channel wiring

**Choice:** New `feed:` property in simulation config YAML on temporal profiles. simulation-config wires at startup: creates a TemporalEventSink<E> that calls `scope.channel(feedName).send(event)`. Declarative end-to-end simulation: temporal profile drives events, orchestration scenario consumes them.
**Alternatives:**
- Java-only wiring — works but requires consumer code for every scenario
- Document as pattern only — misses the opportunity for declarative scenario testing
**Rationale:** Implementation is small (config parsing + sink wiring). Capability is significant: declarative simulation-driven scenario testing without Java bridge code. Temporal profiles already have YAML config — `feed:` is a natural extension.
**Trade-offs:** Tight coupling between temporal profile naming and channel naming. Mitigated by making `feed:` optional — profiles without it work as before.
**Sources:** TemporalEventSink<E>, OrcChannel<T>, simulation config YAML, TemporalProfileConfig
**Exploration:** quick
**Status:** captured

## D9: ScenarioScope simulation — pluggable PrimitiveFactory strategy

**Choice:** Extract `PrimitiveFactory` strategy interface from ScenarioScope's factory methods. ScenarioScope delegates channel(), signal(), stateMachine() etc. to its PrimitiveFactory. Default factory creates real primitives. `SimulatedPrimitiveFactory` returns pre-loaded/scripted primitives (channels with queued messages, pre-fired signals, state machines on specific states). Constructor injection, no CDI required.
**Alternatives:**
- @SimulationEligible + @Decorator on ScenarioScope — requires CDI interception; ScenarioScope isn't always CDI-managed
- @SimulationEligible on individual primitives (OrcChannel, OrcSignal) — primitives are factory-created, @Decorator can't intercept
- Simulation-aware ScenarioScope subclass — hard to compose with other ScenarioScope behaviors
**Rationale:** Strategy pattern keeps ScenarioScope's zero-dep constraint. PrimitiveFactory is a clean extension point that works regardless of DI framework. SimulatedPrimitiveFactory can be configured from simulation YAML corpus data.
**Trade-offs:** Adds a new interface (PrimitiveFactory) and changes ScenarioScope's internal structure. Acceptable — the factory methods already exist, this just names the abstraction.
**Sources:** ScenarioScope factory methods, @SimulationEligible generator, simulation-core patterns
**Exploration:** quick
**Status:** captured

## D10: Concurrent sub-scenarios — spawn + childScope on ScenarioScope

**Choice:** Add `spawn(String name, Runnable task)` and `childScope(String name)` to ScenarioScope. `spawn` starts a virtual thread owned by the scope. `childScope` creates a nested scope — closing a parent closes all children (cancels spawned tasks). Deadlines propagate downward. SpeedMultiplier-aware timeouts on spawned tasks.
**Alternatives:**
- Adopt simulation drivers into scope — couples ScenarioScope to simulation API; too specific
- Phase model (sequential phases containing concurrent groups) — over-structured for the use case
- No concurrency primitive (leave to consumers) — every consumer reimplements fork/join on virtual threads
**Rationale:** `spawn` is the minimal primitive for "run this concurrently." `childScope` is the minimal primitive for "group things with shared lifecycle." Together they give structured concurrency without framework coupling. A spawned task can be a temporal simulation feed, a YAML sub-scenario, or any Runnable — the scope doesn't care what it runs, only that it owns the lifecycle.
**Trade-offs:** ScenarioScope grows from a pure factory into a lifecycle manager. Acceptable — it already owns close() and primitive cleanup. Spawn adds thread ownership, which is a natural extension.
**Design direction:** This is the first step toward convergence — simulation's execution model eventually expressible as orchestration YAML rather than programmatic API. The spawn primitive is designed to support both Java Runnables (backward compat) and YAML sub-scenario execution (future).
**Sources:** TemporalSimulationDriver (virtual thread execution), ScenarioScope.close(), Java structured concurrency patterns, issue #405 Direction 1
**Exploration:** quick
**Status:** captured

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
