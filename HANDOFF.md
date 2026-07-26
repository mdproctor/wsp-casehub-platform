# HANDOFF — casehub-platform

*Updated: 2026-07-26 — #203/#204/#205/#206 tenant isolation closed. Parent docs synced.*

**Date:** 2026-07-26
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Two branches landed. First: #202 — retired Hibernate Reactive from acl-jpa (last reactive holdout). Second: #203-206 — closed four tenant isolation gaps found during audit: GroupMembershipProvider tenancyId, AccessControlProvider tenant-filtered queries (Flyway V2, composite PK), DeliveryAttemptStore tenant-scoped methods, webhook authentication (HMAC headers + bearer token validation). Design review (4 rounds, 15 issues) caught Flyway migration need, mutation bypass bug, and SecurityException catch ordering. Zero cross-repo callers for all SPIs. Parent docs synced (capability-ownership.md, auth.md).

## Cross-Module

**Enabled** (we delivered, downstream work is ready):
- `casehub-work` — work#315: migrate work-notifications to platform subscription engine · L · Med
- **Domain modules** — platform#197: register preference schemas via the SPI · varies

## What's Left

- MongoDB backend for subject view toolkit — not yet filed · M · Med
- platform#196: server-side preference validation using schema constraints
- platform#198: schema versioning
- platform#199: custom/composite preference types

## References

*Unchanged — `git show HEAD~1:HANDOFF.md`*
