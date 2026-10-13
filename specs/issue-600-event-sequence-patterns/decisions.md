## D1: race: implementation strategy

**Choice:** RaceStep as a new structural step in ResolvedStep sealed hierarchy, same virtual-thread pattern as SelectStep's early termination via CAS + future.cancel(true)
**Alternatives:**
- Extend SelectStep with BLOCK branch type — conflates channel multiplexing with computation racing
- race: as a decorator in DecoratorChain — fights the decorator model; race IS the step, not a modifier
- Mode parameter on ParallelStep (`parallel: { mode: race }`) — valid but less clean YAML than `race: [...]`
**Rationale:** Clean separation from select (different abstraction level), proven virtual-thread + interrupt pattern already in SelectStep evaluator, YAML structure maps naturally to container step type
**Trade-offs:** Two new variants in the sealed hierarchy (RaceStep + ControlStep, see D5), bringing total to 12. Concurrency patterns doc needs reconciling (currently maps "race" to select:).
**Sources:** StructuralStepEvaluator.java:213-290 (evaluateSelect — early-termination pattern to reuse), ResolvedStep.java
**Exploration:** quick
**Status:** captured

## D2: Named consumer handle mechanism

**Choice:** Dedicated ConsumerHandle type extending OrcPrimitive — `pause()`, `resume()`, `isRunning()`. Registered in ExecutionScope by name when from: specifies `name:`. Cached by from: at setup time (one lookup). ControlStep resolves handle and calls pause()/resume().
**Alternatives:**
- Reuse OrcFlag (add awaitSet/awaitClear) — fewer new types but limits future growth and no semantic clarity
**Rationale:** Handle can grow (metrics, listeners, begin/end lifecycle) without touching from: or ControlStep. Cached lookup avoids per-receive scope resolution. Semantically clear — ConsumerHandle communicates intent. User preference: "I can see more being needed."
**Trade-offs:** One new type in orchestration package
**Registration race (R1-09):** ConsumerHandle must be registered synchronously in wrapFrom setup, before wrapBackground spawns the virtual thread. The decorator chain ordering (background=3, from=4.5) means from: is wrapped inside background:, so the handle registers on the background thread. Fix: register the handle eagerly during wrapFrom construction (before the returned lambda executes), not inside the receive loop.
**Sources:** OrcFlag.java (existing boolean primitive), ExecutionScope.java (primitive registration pattern)
**Exploration:** quick
**Status:** captured

## D3: from: hardening scope

**Choice:** Combined from: hardening — #601 (until + channel close) and #602 (named consumers + pause/resume) designed and implemented as a single pass on the from: receive loop
**Alternatives:**
- Separate passes (#601 first, then #602) — smaller PRs but rewrites the same method twice
**Rationale:** Both modify wrapFromSingleChannel. The receive loop has natural layering (conditions → receive → error handling → filter) that accommodates both cleanly in one pass. Avoids refactor-then-refactor-again.
**Trade-offs:** Larger single change to the from: decorator; two issues close together
**Depends on:** D2 (ConsumerHandle type used in the receive loop)
**Sources:** DecoratorChain.java:453-488 (wrapFromSingleChannel)
**Exploration:** quick
**Status:** captured

## D4: pause/resume semantics (revised from stop/start)

**Choice:** Use pause/resume instead of stop/start. ConsumerHandle exposes `pause()` and `resume()`. YAML syntax: `pause: enricher` / `resume: enricher`. Leaves room for begin/end lifecycle boundaries if needed later.
**Alternatives:**
- stop/start naming — implies hard lifecycle boundary, collides with future begin/end. "start" is ambiguous: does it mean "create" or "resume"?
**Rationale:** pause/resume communicates continuity — the consumer is suspended, not destroyed. begin/end can layer on top later without naming collision. Implicit begin via `from: { name: X }`, implicit end via scope close.
**Trade-offs:** None — same implementation complexity as stop/start, better semantics
**Depends on:** D2 (ConsumerHandle type), D6 (timed-receive determines blocking mechanism)
**Sources:** DecoratorChain.java (wrapLoop + wrapFrom interaction), issue #602, serverless workflow lifecycle model
**Exploration:** quick
**Status:** captured

## D5: ControlStep as explicit ResolvedStep variant

**Choice:** `ResolvedStep.ControlStep(String name, String target, boolean activate, Map<String, Object> decorators)` — built-in structural step for `pause:` and `resume:`. StructuralStepEvaluator dispatches: looks up ConsumerHandle by target name in ExecutionScope, calls `pause()` or `resume()`.
**Alternatives:**
- Decorator pattern (like signal:) — pause/resume are standalone operations with no inner step; decorator-without-inner-step is semantically odd
- Plugin action (`action: pause, params: { consumer: enricher }`) — hides intent behind generic action name, adds plugin registry overhead for a scope lookup + boolean flip
**Rationale:** Same category as barrier:/quorum: — coordination primitives that manipulate scope state directly. Built-in avoids overhead of plugin mechanism for what is a single method call on a cached handle.
**Trade-offs:** Sealed hierarchy grows to 12 variants (with RaceStep from D1). Growth is linear in pattern-matching cost — manageable.
**Depends on:** D2 (ConsumerHandle type)
**Sources:** ResolvedStep.java (sealed hierarchy), StructuralStepEvaluator.java (dispatch pattern)
**Exploration:** quick
**Status:** captured

## D6: from: receive loop strategy — timed-receive unification

**Choice:** When `name:` or `until:` is specified, from: uses timed receives (~100ms) instead of blocking receives. Each wakeup checks: (1) until condition, (2) handle.isRunning(), (3) channel close state. Plain `from:` (no name, no until) retains current blocking receive — zero overhead for the common case.
**Alternatives:**
- j.u.c Condition-based blocking for pause — adds complexity when timed-receive already provides bounded wakeups for the same checks
- Always use timed receives — unnecessary overhead for plain from: with no conditions to check
**Rationale:** Timed-receive for until: and pause checking are the same mechanism — periodic wakeup to evaluate conditions. Unifying them eliminates the need for Condition-based blocking on ConsumerHandle. 100ms polling when paused is negligible CPU (10 checks/sec). Simplifies implementation and testing.
**Trade-offs:** 100ms pause detection latency (vs zero-latency Condition.signal). Acceptable for pipeline control operations.
**Backpressure note (R1-10):** When a consumer is paused, its channel continues to buffer. Bounded channels may block producers. This is expected behavior — pause intentionally creates backpressure. Document in spec.
**Depends on:** D3 (combined from: hardening), D4 (pause/resume semantics)
**Sources:** DecoratorChain.java:453-488 (current wrapFromSingleChannel), issue #601 (timed-receive for until:)
**Exploration:** quick
**Status:** captured

## D7: Channel close as graceful termination

**Choice:** Null return from `channel.receive()` → stream-ended success (from: exits cleanly). `channel.isErrorClosed()` → failure with cause. This makes channel close an implicit signal to all consumers.
**Alternatives:**
- Treat null as error — breaks graceful shutdown patterns
- Ignore close state — consumers hang forever on closed channels (current behavior)
**Rationale:** Channel close as a termination signal is the standard pattern (Go channels, CSP). Any code that closes a channel now implicitly signals all consumers to exit. This coupling is intentional and should be documented.
**Trade-offs:** Closing a channel now has side effects on all consumers — must be treated as a coordination operation, not just cleanup.
**Sources:** OrcChannel.java (close/isErrorClosed API), issue #601
**Exploration:** quick
**Status:** captured
