# HANDOFF — casehub-platform

## Status

**Platform:** main — playbook infrastructure landed (#510 partial: front matter, schema registry, schema JSON)
**Pages:** main — epic-502-yaml-parity squash-merged as bdd7f366, branch stamped closed
**Epic #520 (Playbook naming):** Phase 1 complete (5 issues closed); Phase 2 active (#510)
**Epic #502 (YAML parity):** Batches 1–4 done; Batch 5 (pages#502 YAML ops sub-epic) open

## This Session

Squash-merged `epic-502-yaml-parity` (43 commits) onto pages main as bdd7f366. Resolved 13 conflicts against 15 commits that landed on main since the branch diverged (DeliveryHandler SPI #516, ESLint strict-type-checked #515). Pushed to both mdproctor and casehubio remotes. Closed pages#518, #520, #521, #522, #527.

Phase 1 of the .plan is complete. Phase 2 (#510 schema composition) is now active.

## Key Decision

Jackson `readTree()` silently drops multi-doc YAML — garden entry GE-20261005-fadf75 captures this. `readValues()` with explicit parser is the fix.

## Work Queue (priority order)

### Phase 1 — Land pages branch ✓

All 5 issues closed. Landed as bdd7f366 on pages main.

### Phase 2 — Remaining #510 platform work ← active

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
| platform#521 | platform | aml (6) + clinical (1) YAML migration | S | Unblocked |

## References

- Blog: `wsp-casehub-platform/blog/2026-10-05-mdp01-landing-the-epic.md`
- Garden: `~/.hortora/garden/jvm/GE-20261005-fadf75.md`
