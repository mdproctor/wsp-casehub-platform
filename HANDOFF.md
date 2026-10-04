# HANDOFF — casehub-platform

## Last Session

Completed casehub-pages#498 (Scenario lifecycle state).

**Design brainstorming highlights:**
- Explored versioning (single-active vs multi-version) — concluded git handles versioning
- Explored approval workflow — concluded durable approval belongs in Serverless Workflow, not in-app
- Explored git-backed storage — deferred as scope expansion
- First-principles analysis of Temporal/Airflow/CNCF Serverless Workflow lifecycle rationale
- Key insight: LLM agents generating scripts at runtime is the primary justification for upload API + lifecycle state
- Created casehub-pages#517 (Serverless Workflow executor backend for YAML DSL)

**What was built (3 commits on pages repo):**

1. `16c559ce` — ScriptLifecycleState enum + state field on ScriptDescriptor
   - ScriptLifecycleState enum: DRAFT, ACTIVE, ARCHIVED
   - ScriptDescriptor gains `state` field (defaults to ACTIVE when null for backward compat)
   - ScriptDescriptorExtractor sets DRAFT for uploaded, ACTIVE for bundled/external
   - TS ScriptDescriptor interface gains `state: string`
   - 3 new tests

2. `2838f034` — ScriptActivated/Archived/Revised CDI event records

3. `51a41d32` — OrcStateMachine lifecycle transitions on ScriptRegistry
   - UploadedScriptSource gains per-script OrcStateMachine (DRAFT→ACTIVE→ARCHIVED)
   - ScriptRegistry.activate/archive/revise transition methods
   - ScriptRegistry.listActive filters to ACTIVE-only for execution queries
   - updateMeta restricted to DRAFT scripts only
   - ARCHIVED is terminal
   - 10 new lifecycle tests

**Pre-existing issue found:** `backend/push` has a hung surefire test
(100% CPU, ran for 3+ hours). Not related to our changes. Killed manually.

## Immediate Next Step

casehub-pages#498 is complete. Queue at position 29/33.

Next queue items:
1. **casehub-pages#508** — Complete type unification
2. **casehub-pages#514** — Delete remaining Format A types after runtime migration
3. **platform#510** — Playbook naming unification

## Slot Repos

Slot 210:
- `slots/210/platform` — no new commits this session
- `slots/210/pages` — 3 new commits on `epic-502-yaml-parity` (casehub-pages#498)
- `slots/210/engine` — no new commits
- `slots/210/work` — no new commits

## References

- `.plan` — queue at position 29/33, casehub-pages#502 active
- Design spec: `wsp-casehub-platform/specs/epic-502-yaml-parity/2026-10-04-scenario-lifecycle-state-design.md`
- Implementation plan: `wsp-casehub-platform/plans/2026-10-04-scenario-lifecycle-state.md`
- New issue: casehub-pages#517 (Serverless Workflow executor)
- Hung test: `backend/push` surefire — needs investigation separately
