# HANDOFF — casehub-platform

## Status

**Platform:** main — playbook infrastructure landed (#510 partial: front matter, schema registry, schema JSON)
**Pages:** `epic-502-yaml-parity` branch — parser + migration + sweep done, NOT merged to main, no PR open
**Epic #520 (Playbook naming):** platform-side foundation done; pages TS + Java parser + migrations + sweep on branch
**Epic #502 (YAML parity):** Batches 1–4 done; Batch 5 (pages#502 YAML ops sub-epic) open

## Previous Session

Landed epic-502 branch content on platform main (15 commits — playbook infrastructure, state machine generator, error hierarchy, front matter parser). Rebased, resolved naming conflicts (StateMachine* kept, Walker→StepWalker reverted), fast-forward merged. Closed platform#522.

On pages `epic-502-yaml-parity` branch: added YamlMultiDocSplitter (pages#520), migrated 48 TS files (pages#518), 13 backend files (pages#521), swept terminology (pages#527). Branch pushed to GitHub but no PR created, issues still OPEN.

## Key Decision

Jackson `readTree()` silently drops multi-doc YAML — garden entry GE-20261005-fadf75 captures this. `readValues()` with explicit parser is the fix.

## Work Queue (priority order)

### Phase 1 — Land pages branch (unblocks everything)

| # | Repo | Title | Scale | Status |
|---|------|-------|-------|--------|
| pages#518 | casehub-pages | TS front matter parser + 48-file migration | M | Done on branch |
| pages#520 | casehub-pages | Java backend multi-doc parser support | M | Done on branch |
| pages#521 | casehub-pages | Migrate 13 backend YAML files | S | Done on branch |
| pages#522 | casehub-pages | TS PlaybookParser non-map guard | XS | Done on branch |
| pages#527 | casehub-pages | Terminology sweep (CaseHub YAML → Playbook YAML) | S | Done on branch |

All five are on `epic-502-yaml-parity` — need PR + merge + issue close.

### Phase 2 — Remaining #510 platform work

| # | Repo | Title | Scale | Status |
|---|------|-------|-------|--------|
| platform#510 | platform | Schema composition/extension mechanism | M | Open — front matter + registry landed, composition TBD |

### Phase 3 — Pages renames + deprecation

| # | Repo | Title | Scale | Status |
|---|------|-------|-------|--------|
| pages#525 | casehub-pages | 14 Scenario→Playbook class renames + dir renames | L | Open |
| pages#526 | casehub-pages | Deprecate /scenario REST → /playbook alias | M | Open |

### Phase 4 — Consumer repo migration

| # | Repo | Title | Scale | Blocked by |
|---|------|-------|-------|------------|
| platform#521 | platform | aml (6) + clinical (1) YAML migration | S | Phase 1 |

## References

- Blog: `wsp-casehub-platform/blog/2026-10-05-mdp01-landing-the-epic.md`
- Garden: `~/.hortora/garden/jvm/GE-20261005-fadf75.md`
