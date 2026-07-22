# HANDOFF — casehub-platform

**Date:** 2026-07-21
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Branch stamp audit (parent#390): discovered 48 branches across 12 repos with false "landed on main" stamps. Recovered stranded CloudEventType + MVEL POJO content (51f282d). Landed DestinationResolver SPI (1db72c6). Fixed work-end skill with verify_stamp.py content gate. Re-stamped all 48 branches. Files-only audit of 796 old-format stamps — structural migration noise, no genuinely lost content.

## Immediate Next Step

Engine expression migration: engine#747-750. Run `/work` to start on engine#747.

## Cross-Module

**Enabled** (we delivered, downstream work is ready):
- `casehub-engine` — engine#747-750: expression type migration to platform SPI · M · Med
- `casehub-engine` — engine#713: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-neocortex` — neocortex#142: wire CbrOutcomeConsumer (unblocked by CloudEventType recovery) · S · Low
- `casehub-connectors` — connectors#86: DestinationResolver now published · M · Med
- `casehub-ras` — JqResultUnwrapper deletion (ScalarJQExpression makes it redundant) · XS · Low
- `casehub-work` — work#315: migrate work-notifications to platform subscription engine · L · Med
- `casehub-qhorus` — qhorus#375: migrate notification bridge to SubscribableEvent · M · Med
- `casehub-iot` — iot#67: household notifications via platform subscription engine · M · Med

## What's Left

- MongoDB backend for subject view toolkit — not yet filed · M · Med

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #193 | Preferences-editor REST API module | L | Med | Write surface for preferences; split from #8. Blocks blocks-ui#92 |

## References

*Unchanged — `git show HEAD~1:HANDOFF.md`*
