# HANDOFF — casehub-platform

*Updated: #219, #199 closed — removed from backlog.*

**Date:** 2026-07-31
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Two ACL issues closed from epic #210. First: #217 — wildcard type-level grants (`case:*`) and deny entries with specificity-based evaluation, `deniedBy()` cascade, parent chain full resolveAt. Adversarial design review (5 rounds, $17.35) significantly improved the design. 33 new contract tests. Second: #218 — new `acl-admin/` module providing REST API over the ACL SPI (`/acl/grants`, `/acl/denies`, `/acl/parents`, `/acl/check`, `/acl/accessible`). `@RolesAllowed("admin")` on mutations, self-access guard on queries. 21 REST-assured tests.

## Cross-Module

**Enabled** (we delivered, downstream work is ready):
- `casehub-work` — work#315: migrate work-notifications to platform subscription engine · L · Med
- **Domain modules** — platform#197: register preference schemas via the SPI · varies

## What's Left

- platform#220: identity propagation through PropagationContext · L · High (engine cross-repo)
- platform#221: worker rights model and authorization service SPI · XL · High (engine cross-repo)
- MongoDB backend for subject view toolkit — not yet filed · M · Med

## References

*Unchanged — `git show HEAD~1:HANDOFF.md`*
