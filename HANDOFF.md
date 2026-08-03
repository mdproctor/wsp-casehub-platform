# HANDOFF — casehub-platform

**Date:** 2026-08-03
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Closed #197 — preference schema registration. Full @ConfigProperty audit across 79 platform values identified 6 retention settings as per-tenant preference candidates. Defined `PlatformPreferenceKeys` (6 `IntPreference` constants in platform-api), created `PlatformPreferenceRegistrar` (@Startup bean in platform/), migrated 3 retention schedulers (notifications-jpa, acl-jpa, delivery-tracking-jpa) from @ConfigProperty to PreferenceProvider reads. Filed follow-up #223 for remaining candidates, plus work#328 and engine#864 for downstream schema registration.

## Cross-Module

**Enabled** (we delivered, downstream work is ready):
- `casehub-work` — work#328: register work preference schemas via PreferenceSchemaRegistry · S · Low
- `casehub-engine` — engine#864: register TrustRoutingPolicyKeys schemas · XS · Low
- `casehub-work` — work#315: migrate work-notifications to platform subscription engine · L · Med

## What's Left

- platform#223: register remaining platform preference schemas (engagement toggle, retry, digest, view cache) · S · Low
- platform#220: identity propagation through PropagationContext · L · High (engine cross-repo)
- platform#221: worker rights model and authorization service SPI · XL · High (engine cross-repo)
- MongoDB backend for subject view toolkit — not yet filed · M · Med

## References

*Unchanged — `git show HEAD~1:HANDOFF.md`*
