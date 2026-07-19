# HANDOFF — casehub-platform

**Date:** 2026-07-19
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Delivered subject view toolkit improvements (#184) — 7 items across 5 modules, design-reviewed ($27.74, 9 rounds). Filed casehubio/work#312 for work-queues migration. Landed #186 (SubjectViewStore.delete()→boolean + CrossTenantSubjectViewStore) directly on main. Commented on engine#730 clarifying queues-are-views architecture.

## Immediate Next Step

Engine expression migration: engine#747-750 (expression type migration to platform SPI). Run `/work` to start on engine#747.

## Cross-Module

**We're blocking:**
- `casehub-engine` — engine#747-750: expression type migration to platform SPI · M · Med
- `casehub-engine` — engine#713: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-engine` — engine#730: case queue implementation (comment posted clarifying view toolkit usage) · M · Med
- `casehub-work` — work#312: work-queues migration to platform-view · L · Med
- `casehub-neocortex` — neocortex#142: wire CbrOutcomeConsumer · S · Low

## What's Left

- casehubio/neocortex#101 — bridge-only reactive implementations · M · Med
- casehubio/platform#185 — view-deletion membership cleanup · S · Med
- Domain notification bridges (work, engine, iot) — not yet filed · S · Low each
- IoT CBR spec §4-5 update for subject view toolkit — not yet filed · S · Low
- MongoDB backend for subject view toolkit — not yet filed · M · Med

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #8 | Preferences-editor module — admin UI/API | XL | High | Write path for preferences; long-standing |

## References

| Type | Path |
|------|------|
| Spec | `docs/specs/2026-07-18-subject-view-improvements-design.md` |
| Blog | `blog/2026-07-19-mdp01-seven-cuts-before-migration.md` |
| Review | `~/adr/casehub-platform/subject-view-improvements-20260718-232017/` |
| Work issue | casehubio/work#312 |
