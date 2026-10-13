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

**Choice:** Dedicated ConsumerHandle type extending OrcPrimitive — `stop()`, `start()`, `isRunning()`. Registered in ExecutionScope by name when from: specifies `name:`. Cached by from: at setup time (one lookup). ControlStep resolves handle and calls stop()/start().
**Alternatives:**
- Reuse OrcFlag — zero new types, but limits future growth (no listener hooks, no metrics, no pause/resume) and no semantic clarity
**Rationale:** Handle can grow (metrics, listeners, LockSupport pause/resume) without touching from: or ControlStep. Cached lookup avoids per-receive scope resolution. Semantically clear — ConsumerHandle communicates intent.
**Trade-offs:** One new type in orchestration package
**Sources:** OrcFlag.java (existing boolean primitive), ExecutionScope.java (primitive registration pattern)
**Exploration:** quick
**Status:** captured

## D3: from: hardening scope

**Choice:** Combined from: hardening — #601 (until + channel close) and #602 (named consumers + stop/start) designed and implemented as a single pass on the from: receive loop
**Alternatives:**
- Separate passes (#601 first, then #602) — smaller PRs but rewrites the same method twice
**Rationale:** Both modify wrapFromSingleChannel. The receive loop has natural layering (conditions → receive → error handling → filter) that accommodates both cleanly in one pass. Avoids refactor-then-refactor-again.
**Trade-offs:** Larger single change to the from: decorator; two issues close together
**Depends on:** D2 (ConsumerHandle type used in the receive loop)
**Sources:** DecoratorChain.java:453-488 (wrapFromSingleChannel)
**Exploration:** quick
**Status:** captured

## D4: stop/start vs pause/resume

**Choice:** Single pair of operations — stop() blocks the consumer thread (via j.u.c Condition), start() wakes it. No separate pause/resume concept.
**Alternatives:**
- stop/start as non-blocking flag + separate pause/resume with LockSupport — false distinction; non-blocking stop causes busy-spin inside loop: continuous
- Defer pause/resume — unnecessary because stop must block to be correct
**Rationale:** If stop just sets a flag and returns, and from: is inside loop: continuous, the loop re-enters from: immediately → busy spin. Stop must block the thread, which IS pause. One concept, not two.
**Trade-offs:** None — eliminates unnecessary complexity
**Depends on:** D2 (ConsumerHandle type)
**Sources:** DecoratorChain.java (wrapLoop + wrapFrom interaction), issue #602
**Exploration:** quick
**Status:** captured
