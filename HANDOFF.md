# HANDOFF — casehub-platform

**Date:** 2026-05-22
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Implemented `persistence-mongodb/` (issue #7) end-to-end — brainstorm, TDD,
`@Alternative @Priority(1)` CDI activation, compound `_id` natural key, `Filters.in()`
for scope query, startup index bean. Code review caught missing scope index and
query-string syntax risk; both fixed. Branch closed, merged to main, published.

## Immediate Next Step

Start `#8 preferences-editor/` — admin UI/API write path for MongoDB preferences.
Run `work-start` on issue #8.

## Cross-Module

*Unchanged — `git show HEAD~2:HANDOFF.md`*

## What's Left

- platform#26: root-scope contract tests for both JPA and MongoDB providers · S · Low
- casehubio/parent#44: CDI persistence-backend priority protocol (pending) · S · Low
- casehubio/parent#45/#46: PLATFORM.md Repository Map + Capability Ownership updates · S · Low
- casehubio/work#217: link WorkItemStore Javadoc to parent#44 protocol (pending parent) · XS · Low
- devtown not yet wired to platform-testing fixtures · S · Low
- `casehub-platform-api` dep not added to devtown pom · S · Low
- quarkus-junit5 → quarkus-junit migration across all modules (#19) · XS · Low
- jandex version extracted to parent pom property (#20) · XS · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Consumers of MongoDB write path |
| ledger#88 | ActorType migration to platform-api | M | Med | Unblocks actorType() TODO |
| — | GroupMembership OIDC provider | M | Med | Needs directory (Keycloak Admin/LDAP) |

## References

- ADRs: `adr/0005` (ActorType), `adr/0006` (JPA current-only), `adr/0007` (SlaBreachPolicy in work-api)
- Blog: `blog/2026-05-22-mdp06-mongodb-preferences-missing-rung.md` (latest)
- Garden: GE-20260522-8df6a6 (Panache MongoDB Filters.in), GE-20260522-483b67 (compound @BsonId), GE-20260522-e570ee (@Startup index)
- Spec: `specs/issue-007-persistence-mongodb/2026-05-22-persistence-mongodb-design.md`
- casehub-work: work#212 (wiring), work#213 (SlaBreachPolicy API)
