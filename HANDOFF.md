# HANDOFF — casehub-platform

*Updated: 2026-07-30 — #208 CI fix landed. Epic #210 S-batch closed: #211-#216 (action hierarchy, bulk grant/revoke, retention purges, pagination, inherited children). Parent docs synced.*

**Date:** 2026-07-30
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Fixed jackson-jq CI compilation failure (#208 — generic return type ambiguity with Scope.setValue overloads). Then filed epic #210 with 11 child issues for ACL completion, implemented all 6 S-sized items in one branch: action hierarchy (AclAction.satisfiedBy()), bulk grant/revoke (GrantRequest + grantBatch/revokeBatch), expired entry and audit log retention purges (AclRetentionPurge @Scheduled), accessibleResources pagination (AclQuery/AclPage), and inherited children in accessibleResources (recursive CTE). 45 contract tests across both backends.

## Cross-Module

**Enabled** (we delivered, downstream work is ready):
- `casehub-work` — work#315: migrate work-notifications to platform subscription engine · L · Med
- **Domain modules** — platform#197: register preference schemas via the SPI · varies

## What's Left

- platform#217: wildcard type-level grants (`case:*`) · M · Med
- platform#218: ACL administration REST API · M · Med
- platform#219: wire Case Definition authorization YAML to ACL grants · L · Med (engine cross-repo)
- platform#220: identity propagation through PropagationContext · L · High (engine cross-repo)
- platform#221: worker rights model and authorization service SPI · XL · High (engine cross-repo)
- MongoDB backend for subject view toolkit — not yet filed · M · Med
- platform#196: server-side preference validation using schema constraints
- platform#198: schema versioning
- platform#199: custom/composite preference types

## References

*Unchanged — `git show HEAD~1:HANDOFF.md`*
