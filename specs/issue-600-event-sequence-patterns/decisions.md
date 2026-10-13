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
