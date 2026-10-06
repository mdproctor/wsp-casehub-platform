# HANDOFF — casehub-platform

## Status

**Branch:** main (all work landed)
**Epic:** platform#520 — Playbook naming unification (platform-side complete)
**State:** platform work done; remaining work is pages-side + consumer repos

## This Session (2026-10-05)

Completed all platform-side naming unification for epic #520:

### Landed commits — platform main

1. `da7ee461` — fix(#519): rename 'CaseHub YAML' to 'CaseHub Playbook YAML' in platform docs
2. `2069de3b` — refactor(#520): rename Scenario* → StateMachine* in yaml-step-runtime
3. `0a8de66a` — refactor(#520): rename ScenarioScope → ExecutionScope

### Issues closed

- **#518** — Closed as invalid (Step* types are valid internal playbook vocabulary)
- **#519** — Done (2 files updated)

### Design decisions

- **Three naming tiers:** Playbook (top-level construct), Step* (internal execution), StateMachine* (state machine DSL)
- **ScenarioScope → ExecutionScope** — the scope manages execution lifecycle, not "scenarios"
- **Step* names stay** — StepWalker, StructuralStepEvaluator are internal components, not alternative top-level naming
- **ScenarioScope (as concept) stays** only in: `scenario:` YAML key (playbook name field), test method names using "scenario" as English

### Issues created

| # | Repo | Title | Scale |
|---|------|-------|-------|
| pages#525 | casehub-pages | Rename 14 Scenario* classes → Playbook* + directory renames | L |
| pages#526 | casehub-pages | Deprecate /scenario REST endpoints — add /playbook alias | M |
| pages#527 | casehub-pages | Terminology sweep: ~27 files CaseHub YAML → Playbook YAML | S |
| platform#521 | platform | Migrate scenario YAML — aml (6) + clinical (1) | S |
| platform#522 | platform | Epic branch cleanup: revert StepWalker→Walker + align renames | M |

## Remaining Work (tracked in issues)

| # | Repo | Title | Scale | Blocked by |
|---|------|-------|-------|------------|
| pages#520 | casehub-pages | Parser multi-doc support | M | — |
| pages#521 | casehub-pages | Migrate 13 backend YAML files | S | pages#520 |
| pages#525 | casehub-pages | 14 class renames + directory renames | L | pages#520 |
| pages#526 | casehub-pages | REST endpoint deprecation | M | pages#525 |
| pages#527 | casehub-pages | Terminology sweep (~27 files) | S | — |
| platform#521 | platform | aml + clinical YAML migration | S | pages#520, pages#521 |
| platform#522 | platform | Epic branch cleanup (revert Walker, align StateMachine/ExecutionScope) | M | — |

## Epic Branch State

`epic-502-yaml-parity` is paused with conflicting renames that need resolution (platform#522):
- Has StepWalker→Walker (should revert)
- Has Scenario*→Playbook* (should become StateMachine*)
- Has ScenarioScope references (should become ExecutionScope)

These will surface naturally on next rebase onto main.

## Slot Repos

Slot 210:
- `slots/210/platform` — main (all work landed)
- `slots/210/pages` — epic-502-yaml-parity (paused)
- `slots/210/engine` — no changes
- `slots/210/work` — no changes
