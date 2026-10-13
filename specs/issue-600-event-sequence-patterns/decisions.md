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
