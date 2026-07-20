# HANDOFF — casehub-platform

**Date:** 2026-07-20
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Cherry-picked orphaned `StringExpressionEvaluator` commit from closed branch to main (casehub-ras#46). Fixed handover skill's Cross-Module section — three buckets (Blocking / Enabled / Blocked by) instead of two. Mapped notification delivery gap: platform has no external deliverers, connectors has the outbound SPI. Filed connector bridge (connectors#86) and domain migration issues (work#315, qhorus#375, iot#67).

## Immediate Next Step

Engine expression migration: engine#747-750. Run `/work` to start on engine#747.

## Cross-Module

**Enabled** (we delivered, downstream work is ready):
- `casehub-engine` — engine#747-750: expression type migration to platform SPI · M · Med
- `casehub-engine` — engine#713: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-engine` — engine#730: case queue implementation · M · Med
- `casehub-work` — work#312: work-queues migration to platform-view · L · Med
- `casehub-work` — work#315: migrate work-notifications to platform subscription engine · L · Med
- `casehub-neocortex` — neocortex#142: wire CbrOutcomeConsumer · S · Low
- `casehub-connectors` — connectors#86: notification delivery bridge · M · Med
- `casehub-qhorus` — qhorus#375: migrate notification bridge to SubscribableEvent · M · Med
- `casehub-iot` — iot#67: household notifications via platform subscription engine · M · Med

## What's Left

- #185 — view-deletion membership cleanup · S · Med
- MongoDB backend for subject view toolkit — not yet filed · M · Med

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #8 | Preferences-editor module — admin UI/API | XL | High | Write path for preferences; long-standing |

## References

*Unchanged — `git show HEAD~1:HANDOFF.md`*
