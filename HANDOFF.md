# HANDOFF — casehub-platform

**Date:** 2026-05-22
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Cleared all S/XS What's Left items. parent#44 (CDI priority protocol written to garden,
PLATFORM.md updated), parent#45/#46 (Repository Map + Capability Ownership), work#217
(WorkItemStore/AuditEntryStore Javadoc links), devtown#39 (platform-api + platform-testing
deps), platform#26 (root-scope ancestors() bug fixed + 5 contract tests each provider).
Branch `issue-26-batch-housekeeping` closed and merged to platform main.

## Immediate Next Step

Start `#8 preferences-editor/` — admin UI/API write path for MongoDB preferences.
Run `work-start` on issue #8.

## Cross-Module

*Unchanged — `git show HEAD~2:HANDOFF.md`*

## What's Left

Nothing — all trailing items from previous sessions are resolved.

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Primary next |
| ledger#88 | ActorType migration to platform-api | M | Med | Unblocks actorType() TODO |
| — | GroupMembership OIDC provider | M | Med | Needs directory (Keycloak Admin/LDAP) |

## References

- ADRs: `adr/0005` (ActorType), `adr/0006` (JPA current-only), `adr/0007` (SlaBreachPolicy in work-api)
- Blog: `blog/2026-05-22-mdp07-root-scope-cdi-ladder.md` (latest)
- Garden: GE-20260522-a87fd7 (Path.parent null for single-segment paths)
- Protocol: `casehub-garden/docs/protocols/universal/persistence-backend-cdi-priority.md` (new this session)
