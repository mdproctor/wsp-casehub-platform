# HANDOFF — casehub-platform

**Date:** 2026-07-18
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Delivered the subject view toolkit (#175) — generalized casehub-work-queues' filtered view pattern into reusable platform infrastructure. Three new modules: platform-view (evaluator), platform-view-inmem, platform-view-jpa (Criteria API query helper). Design spec went through 5-round adversarial review ($16.59, 28 issues verified). PR #183 updated on casehubio/platform.

## Immediate Next Step

Engine migration remains the highest priority: engine#747-750 (expression type migration to platform SPI). These are the next in-order items from the prior session's handover. Run `/work` to start on engine#747.

## Cross-Module

**We're blocking:**
- `casehub-engine` — engine#747-750: expression type migration to platform SPI · M · Med
- `casehub-engine` — engine#713: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-engine` — engine#730: case queue implementation (now uses subject view toolkit) · M · Med
- `casehub-work` — `WorkEventTypeTest` needs updating for SubscribableEvent + marshallerKeys · S · Low
- `casehub-work` — work-queues migration to platform-view (future issue, not yet filed) · L · Med
- `casehub-neocortex` — neocortex#142: wire CbrOutcomeConsumer to @CloudEventType observer · S · Low

## What's Left

- casehubio/neocortex#101 — bridge-only reactive implementations · M · Med
- Domain notification bridges (casehub-work, casehub-engine, casehub-iot) — not yet filed · S · Low each
- IoT CBR spec §4-5 update to use subject view toolkit — not yet filed · S · Low
- MongoDB backend for subject view toolkit — not yet filed · M · Med

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #8 | Preferences-editor module — admin UI/API | XL | High | Write path for preferences; long-standing |

## References

| Type | Path |
|------|------|
| Spec | `docs/specs/2026-07-18-subject-view-toolkit-design.md` |
| Blog | `blog/2026-07-18-mdp01-the-queue-that-wasnt.md` |
| PR | casehubio/platform#183 |
| Review | `~/adr/casehub-platform/subject-view-toolkit-20260718-032257/` |
