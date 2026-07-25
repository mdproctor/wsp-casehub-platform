# HANDOFF — casehub-platform

*Updated: 2026-07-25 — #202 ACL reactive retirement (last piece of #384). ARC42 stale scan cleaned reactive references.*

**Date:** 2026-07-25
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Completed #202 — retired Hibernate Reactive from the ACL subsystem, the last reactive holdout in the platform repo. Converted `AccessControlProvider` SPI from `CompletionStage` to blocking returns, swapped `acl-jpa` from Hibernate Reactive Panache to standard Hibernate ORM Panache with `@Transactional`, stripped `CompletableFuture` wrappers from `acl-inmem`. Zero cross-repo callers — fully self-contained. ARC42STORIES.MD cleaned of stale reactive references (`BlockingToReactiveBridge`, reactive bridge mentions).

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
