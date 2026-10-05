# HANDOFF — casehub-platform

## Status

**Branch:** main (all work landed)
**Epic:** platform#520 — Playbook naming unification (platform-side complete)
**State:** platform work done; pages#520 parser update done; remaining work is pages YAML migration + renames

## This Session (2026-10-05)

### Epic branch landed on main

Rebased `epic-502-yaml-parity` onto main, resolved all naming conflicts, landed via fast-forward merge.

Landed features (from epic branch):
- YamlMappers factory (YAML 1.2 Core Schema)
- YamlError sealed hierarchy + YamlErrorMapper
- SourceLocation on StepContext
- yaml-statemachine-generator module (typed event dispatch from YAML)
- Parsed structure / catalog resolution separation
- REMOVED_KEYS rejection + stripKeys utility on StepWalker
- Inline action resolution (match/select branches)
- Multi-document YAML front matter support on StateMachineParser
- PlaybookFrontMatter + PlaybookParser + PlaybookSchemaRegistry + playbook.schema.json
- Walker → StepWalker revert (Step* types are valid internal vocabulary)

### Pages cross-repo work

- **pages#520** — Parser multi-doc support: committed `14a33dcf` on `epic-502-yaml-parity`
  - `YamlMultiDocSplitter` (Jackson-native multi-doc + PlaybookFrontMatter extraction)
  - `ScenarioEnvelopeParser`, `ScriptDescriptorExtractor`, `ScenarioCompiler` updated
  - 86 tests pass (10 new)
  - Unblocks pages#521, pages#525, platform#521

### Issues closed

- **platform#522** — Epic branch cleanup complete (rebase + naming alignment)

### Design decisions

- **Three naming tiers:** Playbook (top-level construct), Step* (internal execution), StateMachine* (state machine DSL)
- **ScenarioScope → ExecutionScope** — the scope manages execution lifecycle, not "scenarios"
- **Step* names stay** — StepWalker, StructuralStepEvaluator are internal components, not alternative top-level naming

## Remaining Work (tracked in issues)

| # | Repo | Title | Scale | Blocked by |
|---|------|-------|-------|------------|
| pages#520 | casehub-pages | Parser multi-doc support | M | — (done, pending close) |
| pages#521 | casehub-pages | Migrate 13 backend YAML files | S | — (unblocked) |
| pages#525 | casehub-pages | 14 class renames + directory renames | L | — (unblocked) |
| pages#526 | casehub-pages | REST endpoint deprecation | M | pages#525 |
| pages#527 | casehub-pages | Terminology sweep (~27 files) | S | — |
| platform#521 | platform | aml + clinical YAML migration | S | pages#521 |

## Slot Repos

Slot 210:
- `slots/210/platform` — main (all platform work landed, epic branch stamped closed)
- `slots/210/pages` — epic-502-yaml-parity (pages#520 done, more work pending)
- `slots/210/engine` — no changes
- `slots/210/work` — no changes
