# Decisions — Correlate, Deadline Propagation, Condition Combinators

## D1: Correlation — composition over new primitive

**Choice:** No new `OrcCorrelation` primitive. Correlation stays as composition over existing trigger+filter: `trigger: { type: event, filter: ${event.data.orderId} == ${result.submit-order.orderId} }`. A `correlate:` YAML shorthand that desugars to trigger+filter is a parse-time concern for the scenario format spec (#409), not a yaml-core primitive.
**Alternatives:**
- First-class `OrcCorrelation<K,V>` on ScenarioScope — adds a seventh coordination primitive for a pattern already expressible via composition
- Hybrid (internal to trigger evaluator) — adds hidden complexity without user-facing benefit
**Rationale:** The #386 spec's pattern mapping demonstrated that correlation is trigger+filter composition. Adding a primitive duplicates capability. The YAML DX improvement (shorthand syntax) belongs at the parse layer, not the runtime primitive layer.
**Trade-offs:** No dedicated API for request/response patterns. Complex correlation scenarios may require verbose trigger+filter expressions. Trigger+filter is a *matching* mechanism, not a *lifecycle* mechanism — if request-response lifecycle management is needed (timeout on missing response, cleanup of stale correlations, observability of pending correlations), a `CorrelationScope` utility can be built at the consuming layer wrapping channel+filter+timeout+auto-deregister. This is a future pattern, not a yaml-core primitive.
**Sources:** #386 spec §Issue Part 2 Pattern Mapping (correlate: "Covered by composition"), #410 issue body
**Exploration:** quick
**Status:** captured (revised: lifecycle concern acknowledged per review R1-02)

## D2: Deadline propagation — scope-level on ScenarioScope

**Choice:** `ScenarioScope.withDeadline(Duration)` returns a deadline-aware child scope. `withDeadline(Duration, Runnable onDeadline)` variant with pre-close handler. Query methods: `isDeadlineExpired()`, `remainingTime()`. On expiry: fire handler, then `close()` cascades. `DeadlineExceededException extends RuntimeException` — catchable by `on-error`, distinct from `StepTimeoutException` (step-local) and `StepCancelledException` (external termination). SpeedMultiplier-aware via adaptive-sleep virtual thread watcher (1s max interval). Parent-child cascading handled by scope hierarchy + close cascade — no explicit propagation needed.
**Alternatives:**
- Deadline as step decorator (`deadline:` keyword) — simpler but doesn't compose with spawn/childScope
- Both scope and step — maximum flexibility but two concepts to explain
**Rationale:** Deadlines are a scope concern, not a step concern. The scope hierarchy already provides cascading via `close()`. A parent deadline firing closes all descendants automatically. A child's shorter deadline closes the child without affecting the parent. Correct by construction, no explicit propagation code.
**Trade-offs:** Requires OrcPrimitive lifecycle interface (D3) for clean deadline expiry cleanup. The 1s adaptive-sleep polling introduces up to 1 real-second inaccuracy on deadline expiry when speed changes mid-sleep — acceptable for orchestration deadlines measured in tens of seconds. Root scope cannot be deadlined directly — `withDeadline` always creates a child scope (Go `context.WithTimeout` pattern). One virtual thread per active deadline scope.

**Exception hierarchy:** `DeadlineExceededException extends RuntimeException` in `io.casehub.yaml.core.orchestration`. This is the only exception type this branch defines. `StepTimeoutException` and `StepCancelledException` are consuming-layer concerns for the scenario runner (#420 Phase 2) — the runtime wraps primitive-level exceptions into step-specific types. When a deadline fires and `close()` cascades, blocked primitives receive interruption through their standard mechanisms (e.g., `InterruptedException` from `channel.receive()`, `latch.await()`). The step executor in the consuming layer catches these and wraps them as `DeadlineExceededException` when `scope.isDeadlineExpired()` is true.

**Depends on:** D3 (OrcPrimitive — deadline expiry calls close() which needs releaseForClose())
**Sources:** #410 issue body, #391 spec §2.1 (BlockingOrcStateMachine SpeedMultiplier-aware timeouts), DefaultScenarioScope.close() cascade logic
**Exploration:** deep-analysis
**Status:** captured (revised: exception hierarchy and root-scope behavior clarified per review R1-04, R1-05)

## D3: OrcPrimitive lifecycle interface

**Choice:** New `OrcPrimitive` interface with `default void releaseForClose() {}`. All 10 primitive interfaces (OrcChannel, OrcLatch, OrcSignal, OrcSemaphore, OrcStateMachine, OrcCounter, OrcGauge, OrcFlag, OrcAccumulator, OrcMap) extend it. Each `Default*` implementation overrides `releaseForClose()` with its cleanup semantics. `DefaultScenarioScope.close()` replaces the current instanceof chain with single polymorphic dispatch: `if (p instanceof OrcPrimitive orc) orc.releaseForClose();`.
**Alternatives:**
- Keep instanceof chain — works but grows with every new primitive, couples to concrete types, misses SimulatedPrimitiveFactory implementations
- Visitor pattern — heavyweight for a single-method dispatch
**Rationale:** The current instanceof chain has two real defects: (1) it references `Default*` concrete classes instead of interfaces — a custom `PrimitiveFactory` returning non-Default implementations gets no cleanup, and (2) it is not extensible — every new primitive type requires a new instanceof branch. The shared-state primitives (OrcCounter, OrcGauge, OrcFlag, OrcAccumulator, OrcMap) are absent from the chain but currently don't need cleanup (no blocking waiters). OrcPrimitive provides the extension point for all primitives while eliminating concrete-type coupling.
**Trade-offs:** Adds an interface to every primitive type. Minimal — `releaseForClose()` is a default no-op, so primitives that don't need cleanup (shared-state group) have zero implementation burden.
**Sources:** #391 spec D9a, DefaultScenarioScope.close() lines 148-163 (existing instanceof chain)
**Exploration:** deep-analysis
**Status:** captured

## D4: Condition combinators — full boolean algebra with xor

**Choice:** Default methods on `Condition`: `and(Condition)`, `or(Condition)`, `not()`, `xor(Condition)`. Static factories: `always()`, `never()`. Short-circuit evaluation for `and`/`or`. Preserves `@FunctionalInterface` (default methods don't break it).
**Alternatives:**
- Without xor — incomplete boolean algebra
- With nOf(n, conditions...) — quorum-style checks, deferred as speculative
**Rationale:** Complete boolean algebra enables arbitrary condition composition. `xor` completes the set. Short-circuit for `and`/`or` matches Java `&&`/`||` semantics. Static factories `always()`/`never()` are identity elements for `and`/`or` respectively — useful in builder patterns and conditional chaining.
**Trade-offs:** None meaningful. Adding default methods to a @FunctionalInterface is a standard Java pattern.
**Sources:** #410 issue body, existing Condition interface (yaml-core/src/main/java/io/casehub/yaml/core/runtime/Condition.java)
**Exploration:** quick
**Status:** captured

## D5: BlockingOrcStateMachine.awaitAnyState() — multi-target await

**Choice:** Add `S awaitAnyState(Set<S> targets) throws InterruptedException` and `S awaitAnyState(Set<S> targets, Duration timeout) throws InterruptedException` to `BlockingOrcStateMachine`. Returns the matched state. SpeedMultiplier-aware timeout variant.
**Alternatives:**
- Use `awaitState(RUNNING)` + thread interruption for stop — `awaitState` blocks forever when state transitions to STOPPED (the while loop re-checks `currentState() != RUNNING`, which is true for STOPPED, so it awaits again and never exits)
- Add `awaitNotState(S)` — less general, doesn't extend to 3+ state discrimination
**Rationale:** The existing `awaitState(S target)` only exits when the state IS the target. For pause/stop coordination, the loop needs to exit for RUNNING (continue), STOPPED (exit), or COMPLETED (exit) — three targets. `awaitState(RUNNING)` blocks forever on STOPPED. This is a genuine API gap, not over-engineering. Any lifecycle with >2 states hits this.
**Trade-offs:** Slightly larger BlockingOrcStateMachine interface. The Set<S> parameter is naturally expressed with EnumSet for enum states.
**Sources:** DefaultBlockingOrcStateMachine.awaitState() implementation (lines 70-79), TemporalSimulationDriver.checkPauseOrStop() (lines 191-200)
**Exploration:** deep-analysis
**Status:** captured

## D6: ScenarioScope.stateMachine() return type alignment

**Choice:** Change `ScenarioScope.stateMachine()` return type from `OrcStateMachine<S>` to `BlockingOrcStateMachine<S>`. Aligns with `PrimitiveFactory.createStateMachine()` which already returns `BlockingOrcStateMachine<S>`.
**Alternatives:**
- Keep OrcStateMachine return type — forces callers to cast when they need awaitState/awaitAnyState
**Rationale:** PrimitiveFactory already creates blocking state machines. ScenarioScope's purpose is coordination, which requires blocking. The covariant return is source-compatible — callers typed to `OrcStateMachine<S>` still compile.
**Trade-offs:** None. Pre-release, no external consumers.
**Sources:** ScenarioScope.java line 16, PrimitiveFactory.java lines 20-21
**Exploration:** quick
**Status:** captured

## D7: TemporalSimulationDriver migration — internal replacement with exposed lifecycle

**Choice:** Replace `ReentrantLock` + `Condition` + `volatile State` with `BlockingOrcStateMachine<State>`. Transition table via Builder: IDLE→RUNNING, RUNNING↔PAUSED, RUNNING→STOPPED, PAUSED→STOPPED, RUNNING→COMPLETED. Terminal: STOPPED, COMPLETED. `onTransition(IDLE, RUNNING, payload)` handler spawns virtual thread (profile passed as payload — no mutable field for handoff). `checkPauseOrStop()` → `lifecycle.awaitAnyState(EnumSet.of(RUNNING, STOPPED, COMPLETED))`. `stop()` transitions + interrupts thread (breaks Thread.sleep). Expose `lifecycle()` accessor. Remove `state()`, `isRunning()` — single source of truth: `lifecycle().currentState()`. Speed management unchanged (local override + global + profile is domain-specific).
**Alternatives:**
- Extend with Lifecycle interface — adds abstraction without a second consumer
- Replace with generic LifecycleDriver — over-engineers for one concrete use case
**Rationale:** The driver's 35 lines of lock+condition+volatile code duplicate exactly what BlockingOrcStateMachine provides. The migration eliminates hand-rolled concurrency, exposes the state machine for MCP tools and scenario orchestration, and validates that BlockingOrcStateMachine (with awaitAnyState) is sufficient for real lifecycle management.
**Trade-offs:** Removes `state()` and `isRunning()` convenience methods — callers migrate to `lifecycle().currentState()`. Pre-release, so no backward compatibility concern. COMPLETED→STOPPED transition is intentionally removed — COMPLETED is terminal by design. The current driver allows `stop()` from COMPLETED (line 78: `state == State.COMPLETED`), which is wrong — a completed driver should not be re-stoppable. Callers must check state before calling stop().

**Module dependency:** `TemporalSimulationDriver` lives in `simulation-core`. `BlockingOrcStateMachine` lives in `yaml-core`. This migration adds `yaml-core` as a dependency of `simulation-core`. This dependency is on yaml-core's orchestration package specifically — simulation-core already converges with orchestration via `SpeedMultiplier` (yaml-core runtime SPI). The dependency is conceptually clean (simulation consumes orchestration primitives) even though yaml-core is broader than an ideal `orchestration-core` module. Extracting a separate orchestration-core module is a future module-boundary cleanup, not gated on this migration.

**Depends on:** D5 (awaitAnyState — needed for checkPauseOrStop)
**Sources:** TemporalSimulationDriver.java lines 15-18 (lock+condition+state), lines 75-88 (stop allows COMPLETED→STOPPED), lines 191-200 (checkPauseOrStop)
**Exploration:** deep-analysis
**Status:** captured (revised: COMPLETED terminal behavior and module dependency clarified per review R1-16, R1-17)

## D8: Three-layer state machine architecture — EventRouter composition

**Choice:** Three-layer architecture where all layers compose through `transition()`:
- **Layer 1 (existing):** `OrcStateMachine<S>` — state-pair dispatch, CAS, guards, handlers. Unchanged.
- **Layer 2 (new):** `EventRouter<S>` — standalone class that maps string event names to transitions. Wraps any `OrcStateMachine<S>` via composition. `fire(String event, Object context)` resolves event → (from, to) and calls `target.transition()`. `targeting(OrcStateMachine<S>)` retargets to a different state machine (e.g., blocking wrapper). Builder extended with `.on(event, from, to).when(guard)`.
- **Layer 3 (future, generated):** Generated typed dispatch class with `fire(E event)` using Java pattern matching on sealed event types. Wraps any `OrcStateMachine<S>`. Emitted by code generator from YAML state machine definitions.

All layers call `transition()` on the same state machine instance, so blocking semantics (awaitState, signalAll), handlers, and CAS atomicity work uniformly regardless of which layer initiates the transition.
**Alternatives:**
- Add fire() to OrcStateMachine — mixes state management with event routing, complicates the primitive
- Separate typed EventDrivenStateMachine interface — inheritance-based, harder to compose with blocking wrapper
- Defer EventRouter entirely — strictest YAGNI but defers design validation
**Rationale:** Composition over inheritance. EventRouter wraps the state machine and calls `transition()` — blocking semantics are preserved because `DefaultBlockingOrcStateMachine.transition()` signals `stateChanged`. No modification to the primitive. The router is a ~30-line class that validates the design composes. Layer 3 (generated) follows the same pattern with typed dispatch via Java pattern matching.
**Trade-offs:** EventRouter has no consumer on this branch (scenario runner is Phase 2). Cost is ~50 lines (router + Builder extension) — validated architecture for near-zero cost.
**Sources:** First-principles analysis of state management vs event routing separation, DefaultBlockingOrcStateMachine.transition() lines 39-52 (stateChanged.signalAll)
**Exploration:** deep-analysis
**Status:** captured
