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

## D2: Execution model — virtual-thread-first blocking interfaces

**Choice:** Coordination primitives use **virtual-thread-first blocking interfaces** — `acquire()`, `await()`, `receive()`, `lock()` all use `throws InterruptedException` and are designed for the virtual-thread execution model where blocking is cheap. Implementations use `java.util.concurrent` directly.
**Alternatives:**
- Execution-model-agnostic interfaces (original D2 wording) — impossible in practice, because the interface contract leaks the execution model: `throws InterruptedException` is blocking-only, and callback/CompletableFuture-based APIs are async-only. "Agnostic" means designing for the lowest common denominator, which serves neither model well.
- Async-only (CompletableFuture/reactive) — more distributed-friendly, but adds complexity for in-process orchestration where virtual threads make blocking cheap and natural.
**Rationale:** The platform runs on Java 21+ with virtual threads. In-process coordination (the scope of orchestration-core) benefits from blocking APIs: simpler code, debuggable stack traces, natural `try/finally` cleanup. Async adapters (e.g., `CompletableFuture.supplyAsync(() -> { latch.await(); return result; })`) can wrap blocking interfaces efficiently on virtual threads. The reverse (wrapping async in blocking) is inherently lossy.
**Trade-offs:** Single-threaded event loop consumers (Vert.x, Netty) cannot use these interfaces directly. If async-native coordination is needed in the future, async counterparts can be added alongside — but the current design commits to virtual threads as the primary execution model.
**Sources:** User requirement: "we don't know what we would be working on so would be both" — resolved toward virtual-thread-first after analysis showed that "agnostic" is a false economy for in-process coordination.
**Exploration:** deep-analysis
**Status:** captured (updated from original "agnostic" wording to match spec commitment)

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

**Keep but scope tightly:**
- `transform` — single-expression only (one-liner that fits on one line and reads naturally). Multi-field restructuring → @ScenarioAction. Uses existing ExpressionEngine (JQ/MVEL). The 90%-YAML scenario shouldn't force a context switch to Java for a simple data reshape.

**Drop:**
- `if/else` + `branches` — `when` + `goto` for simple, `StateMachine` for complex
- `accumulator` — marginal DX, use Channel or code
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

**Choice:** The tipping point is not about individual constructs — each one in isolation is fine in YAML. The problem is emergent: complexity accumulates through composition. A `when` is readable. A `loop` is readable. A step with both plus a `forEach`, a `trigger`, a `retry`, and a `transform` inside a `barrier` is a program written in YAML.

This cannot be solved by language design. The grammar is regular and recursive on purpose — restricting composition would make the language frustrating for cases where 2-3 decorators genuinely belong together. The solution is education, not enforcement.

Three zones on the expression spectrum:
1. **Pure intent** (when, barrier, delay) — always YAML
2. **Simple expression** (one-liner transforms, basic filters) — keep in YAML because context-switching to Java for one line in a 20-step scenario is worse than the embedded expression
3. **Complex logic** (multi-field restructuring, conditional mapping) — delegate to @ScenarioAction

The spec documents this as design philosophy with concrete signals:
- A single step has 4+ decorators → extract
- Nesting beyond 2 levels → extract
- Tracing data flow through 3+ interpolations → extract
- Expressions that need their own unit tests → extract

Showcase gallery demonstrates both the golden path and the boundary.

**Alternatives:**
- Hard enforcement (reject >2 levels at parse time) — too restrictive, frustrates legitimate composition
- No guidance at all — developers discover the tipping point through pain
**Rationale:** The value of YAML orchestration is declarative readability. Best practice documentation is the only honest answer to "when is YAML too much?" — the language can't know, the developer can.
**Trade-offs:** Soft guidance means some developers will write deeply nested YAML. But telling them "if you're debugging YAML instead of reading it, extract to code" is more useful than a hard limit they'll work around.
**Sources:** Issue #386 nesting policy, user insight: "it's not the individual constructs but how it's used in larger context — comes down to best practice and documentation to educate users"
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
