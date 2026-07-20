# HANDOFF — casehub-platform

**Date:** 2026-07-20
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Closed epics #137 (DataSource SPI follow-up) and #147 (notification system) — all platform children landed, verified in codebase. Implemented #185 (deleteView proactive membership cleanup with REMOVED events) and #190 (JQExpressionEngine ScalarJQExpression for scalar resultType). Design-reviewed (8 issues, all resolved). Squashed and pushed to upstream.

## Immediate Next Step

Engine expression migration: engine#747-750. Run `/work` to start on engine#747.

## Cross-Module

**Enabled** (we delivered, downstream work is ready):
- `casehub-engine` — engine#747-750: expression type migration to platform SPI · M · Med
- `casehub-engine` — engine#713: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-engine` — CaseQueueViewManager.deleteQueueView() return type update (deleteView now returns List<SubjectViewEvent>) · XS · Low
- `casehub-ras` — JqResultUnwrapper deletion (ScalarJQExpression makes it redundant) · XS · Low
- `casehub-work` — work#315: migrate work-notifications to platform subscription engine · L · Med
- `casehub-neocortex` — neocortex#142: wire CbrOutcomeConsumer · S · Low
- `casehub-connectors` — connectors#86: notification delivery bridge · M · Med
- `casehub-qhorus` — qhorus#375: migrate notification bridge to SubscribableEvent · M · Med
- `casehub-iot` — iot#67: household notifications via platform subscription engine · M · Med

## What's Left

- MongoDB backend for subject view toolkit — not yet filed · M · Med

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #8 | Preferences-editor module — admin UI/API | XL | High | Write path for preferences; long-standing |

## References

*Unchanged — `git show HEAD~1:HANDOFF.md`*
