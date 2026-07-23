# HANDOFF — casehub-platform

*Updated: #193 closed — removed from What's Next.*

**Date:** 2026-07-23
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Delivered #193: PreferenceStore SPI + tenancyId on SettingsScope (breaking change) + JPA/MongoDB backends + preferences-editor REST module. Adversarial design review (19 issues, all resolved) shaped the spec — varargs ambiguity catch, tenant assertion pattern, fireAsync for change events, safe Flyway multi-step migration. Split from original #8 which moved UI to blocks-ui#92.

## Immediate Next Step

Engine expression migration: engine#747-750. Run `/work` to start on engine#747.

## Cross-Module

**Enabled** (we delivered, downstream work is ready):
- `casehub-engine` — engine#747-750: expression type migration to platform SPI · M · Med
- `casehub-engine` — engine#713: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-neocortex` — neocortex#142: wire CbrOutcomeConsumer · S · Low
- `casehub-connectors` — connectors#86: DestinationResolver now published · M · Med
- `casehub-ras` — JqResultUnwrapper deletion · XS · Low
- `casehub-work` — work#315: migrate work-notifications to platform subscription engine · L · Med
- `casehub-qhorus` — qhorus#375: migrate notification bridge to SubscribableEvent · M · Med
- `casehub-iot` — iot#67: household notifications via platform subscription engine · M · Med
- `casehub-blocks-ui` — blocks-ui#92: preferences editor UI component (now unblocked by #193) · L · Med
- **All consuming repos** — SettingsScope tenancyId breaking change: engine, work, qhorus, ras, neocortex need callers updated · S · Low per repo

## What's Left

- MongoDB backend for subject view toolkit — not yet filed · M · Med

## What's Next

*No platform-local issues queued. Next work is cross-module: engine#747-750, then downstream consumer migrations.*

## References

*Unchanged — `git show HEAD~1:HANDOFF.md`*
