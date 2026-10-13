## D1: race: implementation strategy

**Choice:** RaceStep as a new structural step in ResolvedStep sealed hierarchy, same virtual-thread pattern as ParallelStep with early termination via CAS + future.cancel(true)
**Alternatives:**
- Extend SelectStep with BLOCK branch type — conflates channel multiplexing with computation racing
- race: as a decorator in DecoratorChain — fights the decorator model; race IS the step, not a modifier
**Rationale:** Clean separation from select (different abstraction level), proven virtual-thread + interrupt pattern already in codebase, YAML structure maps naturally to container step type
**Trade-offs:** One more variant in the sealed hierarchy (now 11 types)
**Sources:** StructuralStepEvaluator.java (SelectStep/ParallelStep patterns), DecoratorChain.java, ResolvedStep.java
**Exploration:** quick
**Status:** captured

## D2: Named consumer handle mechanism

**Choice:** Dedicated ConsumerHandle type extending OrcPrimitive — `pause()`, `resume()`, `isRunning()`. Registered in ExecutionScope by name when from: specifies `name:`. Cached by from: at setup time (one lookup). ControlStep resolves handle and calls pause()/resume().
**Alternatives:**
- Reuse OrcFlag — zero new types, but limits future growth (no listener hooks, no metrics) and no semantic clarity
**Rationale:** Handle can grow (metrics, listeners, begin/end lifecycle) without touching from: or ControlStep. Cached lookup avoids per-receive scope resolution. Semantically clear — ConsumerHandle communicates intent.
**Trade-offs:** One new type in orchestration package
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

## D4: pause/resume semantics (revised from pause/resume)

**Choice:** Use pause/resume instead of pause/resume. ConsumerHandle exposes `pause()` (blocks consumer thread via j.u.c Condition) and `resume()` (wakes it). YAML syntax: `pause: enricher` / `resume: enricher`. Leaves room for begin/end lifecycle boundaries if needed later.
**Alternatives:**
- pause/resume naming — implies hard lifecycle boundary, collides with future begin/end. "start" is ambiguous: does it mean "create" or "resume"?
- Non-blocking flag without blocking — causes busy-spin inside loop: continuous
**Rationale:** pause/resume communicates continuity — the consumer is suspended, not destroyed. Aligns with serverless workflow / BPMN lifecycle (Created → Active → Suspended → Active → Completed). begin/end can layer on top later without naming collision. Implicit begin via `from: { name: X }`, implicit end via scope close.
**Trade-offs:** None — same implementation complexity as pause/resume, better semantics
**Depends on:** D2 (ConsumerHandle type)
**Sources:** DecoratorChain.java (wrapLoop + wrapFrom interaction), issue #602, serverless workflow spec lifecycle model
**Exploration:** quick
**Status:** captured
