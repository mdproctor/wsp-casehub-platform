# HANDOFF — casehub-platform

*Updated: 2026-07-31 — #217 closed (wildcard type-level grants + deny entries). #198 landed by parallel session.*

**Date:** 2026-07-31
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Implemented wildcard type-level grants and deny entries for ACL (#217). Added `AclEntryType` (ALLOW/DENY), `deniedBy()` cascade on `AclAction`, specificity-based evaluation (instance > wildcard, deny before grant at same level), parent chain applies full resolveAt at each level. Renamed `GrantRequest` → `AclEntryRequest`. Flyway V3 migration. 33 new contract tests across both backends. Adversarial design review (5 rounds, 14 verified issues, $17.35) significantly improved the design — added specificity semantics, deny cascade via `deniedBy()`, parent chain full evaluation.

## Cross-Module

**Enabled** (we delivered, downstream work is ready):
- `casehub-work` — work#315: migrate work-notifications to platform subscription engine · L · Med
- **Domain modules** — platform#197: register preference schemas via the SPI · varies

## What's Left

- platform#218: ACL administration REST API · M · Med
- platform#219: wire Case Definition authorization YAML to ACL grants · L · Med (engine cross-repo)
- platform#220: identity propagation through PropagationContext · L · High (engine cross-repo)
- platform#221: worker rights model and authorization service SPI · XL · High (engine cross-repo)
- MongoDB backend for subject view toolkit — not yet filed · M · Med
- platform#199: custom/composite preference types

## References

*Unchanged — `git show HEAD~1:HANDOFF.md`*
