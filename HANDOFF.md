# HANDOFF — casehub-platform

## Status

**Platform:** main — epic branch content landed
**Pages:** `epic-502-yaml-parity` — parser + migration + sweep done, pushed to GitHub
**Epic #520:** platform-side complete; pages parser + migration + terminology done

## This Session

Landed the `epic-502-yaml-parity` branch on platform main (15 commits — playbook infrastructure, state machine generator, error hierarchy, front matter parser). Rebased onto main, resolved naming conflicts (StateMachine* kept, Walker→StepWalker reverted), fast-forward merged.

Cross-repo: added `YamlMultiDocSplitter` to pages backend (Jackson `readValues()` for multi-doc YAML), migrated 13 YAML files to playbook format, swept 48 "CaseHub YAML" → "CaseHub Playbook YAML" across 32 files.

Closed: platform#522. Pages#520, #521, #527 done (pending close on epic merge).

## Key Decision

Jackson `readTree()` silently drops multi-doc YAML — garden entry GE-20261005-fadf75 captures this. `readValues()` with explicit parser is the fix.

## Remaining (epic #520)

| # | Repo | Title | Scale |
|---|------|-------|-------|
| pages#525 | casehub-pages | 14 class renames + directory renames | L |
| pages#526 | casehub-pages | REST endpoint deprecation | M |
| platform#521 | platform | aml + clinical YAML migration | S |

## References

- Blog: `wsp-casehub-platform/blog/2026-10-05-mdp01-landing-the-epic.md`
- Garden: `~/.hortora/garden/jvm/GE-20261005-fadf75.md`
