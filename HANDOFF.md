# HANDOFF — casehub-platform

**Date:** 2026-07-19
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Delivered subject view toolkit improvements (#184) — 7 items across 5 modules to unblock casehub-work-queues migration. CHANGED event type, additionalConditions field, bulk membership tracker, scope-aware evaluation, SubjectViewOrchestrator (evaluator + store + tracker composition with TTL caching), InMemorySubjectViewQuerySupport. Design-reviewed ($27.74, 9 rounds, 16 issues). Filed casehubio/work#312 for the work-queues migration itself.

## Immediate Next Step

Engine expression migration remains highest priority: engine#747-750 (expression type migration to platform SPI). Run `/work` to start on engine#747.

## Cross-Module

**We're blocking:**
- `casehub-engine` — engine#747-750: expression type migration to platform SPI · M · Med
- `casehub-engine` — engine#713: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-engine` — engine#730: case queue implementation (now uses subject view toolkit) · M · Med
- `casehub-work` — work#312: work-queues migration to platform-view · L · Med
- `casehub-work` — `WorkEventTypeTest` needs updating for SubscribableEvent + marshallerKeys · S · Low
- `casehub-neocortex` — neocortex#142: wire CbrOutcomeConsumer to @CloudEventType observer · S · Low

## What's Left

- casehubio/neocortex#101 — bridge-only reactive implementations · M · Med
- Domain notification bridges (casehub-work, casehub-engine, casehub-iot) — not yet filed · S · Low each
- IoT CBR spec §4-5 update to use subject view toolkit — not yet filed · S · Low
- MongoDB backend for subject view toolkit — not yet filed · M · Med
- casehubio/platform#185 — view-deletion membership cleanup (deferred from #184 design review) · S · Med

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
