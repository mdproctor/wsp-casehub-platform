# HANDOFF — casehub-platform

**Date:** 2026-05-21
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Multi-tenancy foundation landed: `TenancyConstants` (DEFAULT_TENANT_ID UUID,
PLATFORM_TENANT_ID), `tenancyId()` and `isCrossTenantAdmin()` added to
`CurrentPrincipal` as abstract methods — compile-time enforcement on every
implementor. Mock reads both from `@ConfigProperty`; `FixedCurrentPrincipal`
gets setters and `reset()` support. Two protocols: no conditional tenancy
filtering (PP-20260520-439daf), bind tenancyId in data access layer only
(PP-20260520-e6a5f0). Issues closed: #17 (multi-tenancy foundation), #14
(TenantContext bridge — won't do until needed), #9 (defaultValue — Drools
convention, keep as-is), #18 (pom.xml module registration).
Consumer issues filed: engine#299, claudony#121.

## Immediate Next Step

Wait for parent to finish its cross-cutting concern, then engine#299 and
claudony#121 can start (tenancyId on entities, scoped repository pattern).
Platform itself has no blocking work — next platform issue is #16 (OIDC
CurrentPrincipal) when auth lands, or #6 (persistence-jpa/) when needed.

## Cross-Module

**We're blocking:**
- `engine` — tenancyId on entities + scoped repository pattern (engine#299) · L · Med
- `claudony` — same (claudony#121) · L · Med

## What's Left

- Artifacts not published to GitHub Packages (only local `.m2`) · XS · Low
- devtown not yet wired to platform-testing fixtures · S · Low
- `casehub-platform-api` dependency not yet added to devtown pom · S · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #16 | OIDC CurrentPrincipal — Keycloak/quarkus-oidc | M | Med | Deferred until auth lands |
| #6 | `persistence-jpa/` — JPA-backed scoped PreferenceProvider | L | Med | Depends on config/ stable |
| #7 | `persistence-mongodb/` — MongoDB alternative | M | Low | Follows work-testing pattern |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Separate from read providers |
| #3 | CurrentPrincipal @RequestScoped retrofit | S | Low | At RBAC implementation time |
| ledger#88 | ActorType migration to platform-api | M | Med | Unblocks actorType() TODO |

## References

- DESIGN.md: `design/DESIGN.md` (workspace main — §Identity API updated)
- Deep-dive: `~/claude/casehub/parent/docs/repos/casehub-platform.md`
- Protocols: `docs/protocols/casehub/` — FOUNDATION-INDEX.md, no-conditional-tenancy-filtering.md, tenancy-repository-pattern.md
- Blog: `blog/2026-05-21-mdp01-tenancy-id-before-the-fields.md`
- Open issues: casehubio/platform #3, #6–#8, #16
- Garden: GE-20260521-aba9c9 (assertNotNull on primitive boolean — autoboxing trap)
- Workspace branches (all closed): epic-* (del. 2026-06-01/02/03), issue-17 (del. 2026-06-04)
