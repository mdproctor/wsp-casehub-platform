# HANDOFF — casehub-platform

## Last Session

Implemented pages#390 (Scenario format refinements) — 7/9 tasks complete.
Design review ran first (3 dimensions, 38 issues, $105, all resolved),
then writing-plans produced a 9-task plan, then executing-plans ran
through Batches 1-4.

**What was built (6 commits on pages repo, 1 on platform workspace):**

1. `12f03003` — CompactStep + ScenarioEnvelope records (new types
   replacing HierarchicalStep + HierarchicalScenario)
2. `9876ffc9` — ScenarioEnvelopeParser (compact YAML parsing, decorator
   extraction, step name derivation, target/actor defaults)
3. `1052919e` — CompactStepAdapter + ScenarioCompiler rewrite (forEach
   expansion with CompactStep, inlineCalls removed)
4. `14f9a065` — ScenarioOrchestrator wire protocol rewrite (commands[]
   → flat action+params, AtomicBoolean callback guard)
5. `877e336c` — ScenarioExecutorClient rewrite (single-action dispatch,
   stop control, speed≤0 guard)
6. `9521a106` — Walker DECORATOR_KEYS + parser.ts WALKER_KNOWN_KEYS
   (8 scenario decorator keys added)

**Test results:** 129 Java scenario tests pass, 7 partitioner tests pass,
22 executor tests pass, 50 Walker TS tests pass, 32 parser TS tests pass.

## Immediate Next Step

Resume executing-plans from **Task 7** (scenario-handler.ts dispatch rewrite):

1. **Task 7 — scenario-handler.ts dispatch rewrite** (Batch 4)
   - Rewrite DispatchStep interface (remove commands[], add action+params)
   - Single-action dispatch logic with AriaTarget from flat params
   - Add 'stop' to ExecutorControl + onControl handler
   - Speed ≤ 0 guard before delay computation
   - Add TS step name derivation from label decorator
   - 919 lines, substantial rewrite

2. **Task 8 — Migrate YAML files** (Batch 5)
   - Test fixtures: foreach-csv-inline, parameterized-onboard already done
   - Remaining: graphql-inject-chat, hybrid-helpdesk-demo, caller-script,
     callee-create-user, cyclic-a/b, environment-setup
   - Production: META-INF/scenarios/ (3 files)
   - Tutorials: check 3 tutorial.yaml files

3. **Task 9 — Delete old types + tests** (Batch 5)
   - ScenarioParser, HierarchicalParser, ScenarioStep, ScenarioCommand,
     HierarchicalStep, HierarchicalScenario, AriaTarget, CallGraphValidator,
     Scenario + their test files
   - Use ide_refactor_safe_delete, verify zero references first

## Key Design Decisions

- **Orchestrator is format-agnostic** — no step-type discrimination, no
  ARIA element extraction. All params flat, executor reconstructs AriaTarget.
- **Speed ≤ 0 sentinel** for "no pacing" (both Java and TS executors guard)
- **Envelope parser applies defaults** — target: "browser", actor inherited
- **Step name derivation** — step: → slugify(label:) → {action}-{index}
- **AtomicBoolean callback guard** prevents double completion callback
- **Walker key sets intentionally asymmetric** — TS Walker gets scenario
  decorators, Java StepWalker does not (different step domains)

## Slot Repos

Slot 210:
- `slots/210/pages` — 6 new commits on `epic-502-yaml-parity` (pages#390)
- `slots/210/platform` — no new commits this session (design + plan in workspace)
- `slots/210/engine` — no new commits
- `slots/210/work` — no new commits

## References

- `.plan` — queue at position 24/31, active issue pages#390, 7/9 tasks done
- pages#390 spec: `specs/epic-502-yaml-parity/2026-10-02-scenario-format-refinements-design.md`
- Implementation plan: `plans/2026-10-03-scenario-format-refinements.md`
- Design review: 3 workspaces under `~/reviews/casehub-slots/scenario-format-refinements-*`
- Decisions D18-D26: `specs/epic-502-yaml-parity/decisions.md`
