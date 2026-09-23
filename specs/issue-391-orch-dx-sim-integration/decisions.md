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

## D10: Concurrent simulation phases — hierarchical phase model (PENDING)

**Choice:** TBD — under discussion. Phases (sequential) containing groups of profiles (concurrent). OrcLatch for phase gating, OrcChannel for data delivery. Two-level hierarchy.
**Status:** discussing
