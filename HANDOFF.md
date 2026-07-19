# HANDOFF — casehub-platform

**Date:** 2026-07-19
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Delivered #188 — fixed JpaViewMembershipTracker.updateMembership() EntityExistsException on same-subject re-evaluation within a transaction. Replaced JPQL bulk DELETE with entity-managed removal (SELECT + em.remove() + em.flush()). Also fielded engine design questions on label infrastructure integration (expression types, re-evaluation triggers, label storage, queue module placement).

## Immediate Next Step

Engine expression migration: engine#747-750. Run `/work` to start on engine#747.

## Cross-Module

**We're blocking:**
- `casehub-engine` — engine#747-750: expression type migration to platform SPI · M · Med
- `casehub-engine` — engine#713: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-engine` — engine#730: case queue implementation (label infrastructure + tracker fix both landed) · M · Med
- `casehub-work` — work#312: work-queues migration to platform-view (tracker fix unblocks) · L · Med
- `casehub-neocortex` — neocortex#142: wire CbrOutcomeConsumer · S · Low

## What's Left

- #185 — view-deletion membership cleanup · S · Med
- Domain notification bridges (work, engine, iot) — not yet filed · S · Low each
- IoT CBR spec §4-5 update for subject view toolkit — not yet filed · S · Low
- MongoDB backend for subject view toolkit — not yet filed · M · Med

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #8 | Preferences-editor module — admin UI/API | XL | High | Write path for preferences; long-standing |

## References

*Unchanged — `git show HEAD~1:HANDOFF.md`*
