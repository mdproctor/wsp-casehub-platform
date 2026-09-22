# Decisions — Runtime Orchestration Primitives

## D1: Module placement — yaml-core vs new orchestration-core

**Choice:** Split into two modules. yaml-core gets runtime evaluation interfaces (Condition, RuntimeForEach — pure contracts, zero-dep, J2CL-safe). New `orchestration-core` module gets coordination primitives (Semaphore, Latch, Signal, Channel, Mutex, StateMachine) backed by `java.util.concurrent` for thread safety.
**Alternatives:**
- Everything in yaml-core — breaks J2CL transpilability (j.u.c types don't exist in JS)
- Everything in a new module — loses the natural extension of existing yaml-core interfaces
**Rationale:** yaml-core's zero-dep J2CL constraint is load-bearing. Coordination primitives are inherently concurrent and need j.u.c. Clean separation: contracts vs thread-safe implementations.
**Trade-offs:** Two modules to depend on instead of one. Consumers need both for full orchestration.
**Sources:** yaml-core module constraint in CLAUDE.md, j.u.c availability analysis
**Exploration:** quick
**Status:** captured

## D2: Execution model — agnostic interfaces

**Choice:** Coordination primitives are defined as execution-model-agnostic interfaces. Virtual thread implementations use j.u.c directly. Async/event-driven implementations can be provided separately.
**Alternatives:**
- Virtual threads only — simpler, but locks out async consumers
- Async only — more distributed-friendly, but more complex for simple in-process scenarios
**Rationale:** We don't know what consumers will use. The interface contract (acquire/release, signal/await, send/receive) is the same regardless of execution model.
**Trade-offs:** Interface design must be careful not to leak blocking semantics that don't work in async contexts.
**Sources:** User requirement: "we don't know what we would be working on so would be both"
**Exploration:** quick
**Status:** captured

## D3: Composition vs custom keywords — pattern consolidation

**Choice:** 14 YAML keywords covering all 21 original patterns plus the new coordination layer.

**Keep as custom keywords (DX wins):**
- `when` — conditional guard
- `loop` — repeat with `count` or `until` sub-fields (merges patterns 3+4)
- `forEach` — collection iteration at runtime
- `delay` — fixed wait
- `timeout` — deadline decorator
- `on-error` — error routing
- `retry` — delegates to existing PolicyEnforcer/ExecutionPolicy (subsumes circuitBreaker)
- `trigger` — unified wait-for with type discriminator: data/time/event (merges patterns 6+7+8+17)
- `barrier` — syntactic sugar over Latch
- `quorum` — syntactic sugar over Latch with threshold
- `race` — syntactic sugar over Signal (renamed from firstWins)

**Add as coordination primitives:**
- `Semaphore` — concurrency control (subsumes rateLimit)
- `Latch` — countdown synchronization
- `Signal` — named notification
- `Channel<T>` — typed data passing
- `Mutex` — exclusive section
- `StateMachine` — state + transitions + guards (replaces if/else/branches for complex routing)

**Drop:**
- `if/else` + `branches` — `when` + `goto` for simple, `StateMachine` for complex
- `accumulator` — marginal DX, use Channel or code
- `transform` — poor DX, use @ScenarioAction code
- `circuitBreaker` — subsumed into retry policy configuration
- `rateLimit` — subsumed into Semaphore with time window
- `schedule` — subsumed into trigger type: time

**Extend existing:**
- `VariableResolver` — new runtime VariableSource for live state (no new keyword)

**Alternatives:**
- Keep all 21 as individual keywords — larger API surface, more to learn, implementation overlap
- Pure composition only (no sugar keywords) — loses the "read and instantly get it" quality
**Rationale:** Custom keywords where DX is excellent and the pattern is self-explanatory. Composition where patterns are combinations of simpler concepts. Drop where code is genuinely better.
**Trade-offs:** Developers familiar with the original 21 patterns need to learn the mapping (e.g., circuitBreaker is now a retry config field).
**Sources:** Issue #386 DX assessments, existing PolicyEnforcer/ExecutionPolicy in governance
**Exploration:** deep-analysis
**Status:** captured

## D4: Thread safety as first-class design constraint

**Choice:** All coordination primitives in orchestration-core are thread-safe by design, backed by j.u.c primitives (AQS-based Semaphore, AtomicReference CAS for StateMachine, BlockingQueue for Channel). Tests include concurrent contention scenarios.
**Alternatives:**
- Single-threaded-only primitives — useless for real coordination
- Synchronised wrapper approach — coarse-grained, poor performance under contention
**Rationale:** Coordination primitives exist to mediate concurrent execution. Thread safety is the reason they exist, not an add-on.
**Trade-offs:** j.u.c dependency means these can't run in J2CL (hence the module split in D1).
**Sources:** User requirement: "we would need to ensure thread safety in any coordination", java.util.concurrent API design
**Exploration:** quick
**Status:** captured

## D5: DX tipping-point rule

**Choice:** Every YAML keyword must pass the test: "would a developer rather write this in YAML or in a @ScenarioAction method?" If the YAML reads as intent, keep it. If it reads as instructions, push it to code. Nesting beyond 2 levels is the documented tipping point — discourage in docs, demonstrate the boundary in showcase examples.
**Alternatives:**
- No nesting limit — leads to YAML that's harder to read than Java
- Hard enforcement (reject >2 levels at parse time) — too restrictive for edge cases
**Rationale:** The value of YAML-declared orchestration is declarative readability. The moment it becomes a pseudo-programming language embedded in YAML, Java is better.
**Trade-offs:** Soft limit means developers can still write deeply nested YAML. Documentation and examples must clearly show where to delegate to code.
**Sources:** Issue #386 nesting policy, user requirement: "doesn't tip over to the point that java is easier and better"
**Exploration:** quick
**Status:** captured

## D6: Test strategy — golden path, composition, tipping point

**Choice:** Three tiers of tests per primitive:
1. **Golden path** — the simple, flat, declarative case (why this exists in YAML)
2. **Composition** — combined with one other primitive (when + loop, trigger + timeout)
3. **Tipping point** — 3-way compositions demonstrating where to stop and use code

**Alternatives:**
- Unit tests only — misses the DX evaluation that composition tests provide
- Integration tests only — too heavy for primitive-level validation
**Rationale:** The tests serve double duty: correctness AND DX documentation. The tipping-point tests are showcase examples that demonstrate the boundary.
**Trade-offs:** More tests to write and maintain. But they're cheap (unit-level) and high-value (they catch DX regressions).
**Sources:** User requirement: "we should make unit tests that cover all 21"
**Exploration:** quick
**Status:** captured
