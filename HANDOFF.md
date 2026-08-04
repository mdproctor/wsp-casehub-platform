# HANDOFF — casehub-platform

**Date:** 2026-08-04
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Closed #223 and #220 on one branch. #223: registered 4 remaining preference schemas (first BooleanPreference — `ENGAGEMENT_ENABLED`), migrated 6 beans across 4 modules from @ConfigProperty to PreferenceProvider. Platform now has 10 registered preference schemas. #220: resolved ACL spec §14 design decision (actorId on CaseInstance + PropagationContext), filed engine#865/#866/#867 for implementation.

## Cross-Module

**Enabled** (we delivered, downstream ready):
- `casehub-engine` — engine#865/#866/#867: identity propagation wiring (PropagationContext + CaseInstance actorId + dispatch identity) · M · Med
- `casehub-work` — work#328: register work preference schemas · S · Low
- `casehub-engine` — engine#864: register TrustRoutingPolicyKeys schemas · XS · Low
- `casehub-work` — work#315: migrate work-notifications to platform subscription engine · L · Med

## What's Left

- platform#221: worker rights model and authorization service SPI · XL · High (engine cross-repo)
- MongoDB backend for subject view toolkit — not yet filed · M · Med

## References

*Unchanged — `git show HEAD~1:HANDOFF.md`*
