# HANDOFF — casehub-platform

## Last Session

Completed 10 issues on `issue-459-state-machine-matchpattern` (9 squashed commits landed on main), then ran a coherence audit and fixed 8 findings on main directly.

**Branch work (10 issues):** AnyOfPattern + EventRouter MatchPattern dispatch (#459), ADR 0011 keyword reservation (#460), StepWalker depth limit (#462), maxOutputBytes enforcement (#461), nesting path errors (#468), hardening (#467). Then runtime evaluation stack: StructuralStepEvaluator for block/if-else/match/parallel (#465), DecoratorChain for all 12 decorator positions (#466), try/catch/finally (#463), CSP select (#464). 217 tests in yaml-step-runtime.

**Post-landing coherence audit (8 fixes):**
1. Integration gap — StructuralStepEvaluator now composes with DecoratorChain (decorators() applied to all steps)
2. Extracted resolveCondition() helper (duplicate condition paths)
3. evaluateParallel uses Future[] pattern (consistency with evaluateSelect)
4. on-error returns success with fallback routing info (was swallowing fallback name)
5. SelectBranchType enum replaces magic strings
6. ScopeUtils.pushScope() extracts duplicated map-drill pattern (4 call sites)
7. StepWalker warns on try without catch or finally
8. 5 composition tests verifying decorators apply to structural + leaf steps

## Immediate Next Step

Start #469 (barrier/quorum sugar + StepResultStore wiring). M-scale — needs StepResultStore recording in the evaluator, OrcLatch sugar parsing in StepWalker, and ${result.<step>} variable resolution. The OrcLatch primitive and StepResultStore interface already exist in yaml-core.

## Queue State

`.plan` has 2 issues (#469, #470). Both on main — no feature branch yet.

## References

- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/` — StructuralStepEvaluator, DecoratorChain, ScopeUtils, StepRunner, DecoratedExecution
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/` — OrcLatch, StepResultStore, ScenarioScope (all exist, need wiring)
- `specs/issue-386-runtime-orchestration/2026-09-22-runtime-orchestration-primitives-design.md` — section 2.2 Latch (barrier/quorum spec)
