# HANDOFF — casehub-platform

**Date:** 2026-05-21
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

`casehub-platform-oidc` shipped — new optional `@RequestScoped CurrentPrincipal`
backed by `SecurityIdentity` + `JsonWebToken`. Fixed claim names: `tenancyId`
(required, throws if absent), `crossTenantAdmin` (optional, defaults false).
Follows the `config/` optional-module pattern; displaces mock automatically.
Tested via `@InjectMock` + manual Arc request context — no HTTP, no real OIDC
server. Issues #3 and #16 closed. ADR 0004 recorded. Protocol PP-20260521-78674a
(quarkus-junit-not-junit5). Issues filed: #19 (quarkus-junit migration), #20
(jandex version property). work-end skill fixed: 8g now mandatory.

## Immediate Next Step

Pick up #6 (`persistence-jpa/` — JPA-backed scoped PreferenceProvider) or
wait for ledger#88 (ActorType migration to platform-api, unblocks `actorType()`
TODO on `CurrentPrincipal`).

## Cross-Module

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Left

- Artifacts not published to GitHub Packages (only local `.m2`) · XS · Low
- devtown not yet wired to platform-testing fixtures · S · Low
- `casehub-platform-api` dep not added to devtown pom · S · Low
- Migrate `quarkus-junit5` → `quarkus-junit` in platform/ and config/ (#19) · XS · Low
- Extract jandex version into parent pom property (#20) · XS · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #6 | `persistence-jpa/` — JPA-backed scoped PreferenceProvider | L | Med | Depends on config/ stable |
| #7 | `persistence-mongodb/` — MongoDB alternative | M | Low | Follows work-testing pattern |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Separate from read providers |
| ledger#88 | ActorType migration to platform-api | M | Med | Unblocks actorType() TODO |
| GroupMembership OIDC | GroupMembershipProvider + SecurityIdentityAugmentor | M | Med | Needs directory (Keycloak Admin/LDAP) |

## References

- DESIGN.md: `design/DESIGN.md` (workspace main — §Module Structure + §Identity API updated)
- ADR: `adr/0004-oidc-optional-module.md`
- Blog: `blog/2026-05-21-mdp02-oidc-optional-module.md`
- Deep-dive: `~/claude/casehub/parent/docs/repos/casehub-platform.md`
- Garden: GE-20260521-f50602 (oidc discovery-disabled needs jwks-path),
          GE-20260521-debce2 (@InjectMock + Arc request context technique)
- Workspace branches (all closed): epic-* (del. 2026-06-01/02/03),
  issue-17 (del. 2026-06-04), issue-3 (del. 2026-06-04)
