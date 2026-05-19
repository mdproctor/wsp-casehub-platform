# HANDOFF — casehub-platform

**Date:** 2026-05-19
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Two epics shipped: `epic-platform-api` (all SPIs — Path, Preferences, Identity, mocks) and `epic-platform-testing` (`FixedCurrentPrincipal`, `InMemoryGroupMembershipProvider`). Key breaking change mid-session: `PreferenceKey<T>` gained a `Function<String, T> parser` (4th record component), enabling `MockPreferenceProvider.get(key)` to return typed values from config — which eliminated `InMemoryPreferenceProvider` entirely. Both epics closed, journals merged to DESIGN.md, issues #1 and #4 closed.

## Immediate Next Step

Run `/epic` to start `epic-platform-config` — the scope-aware YAML + env var `PreferenceProvider` (Drools `ChainedProperties` equivalent). Issue #5 tracks it.

## What's Left

- `casehub-platform` artifacts not published to GitHub Packages (only local `.m2`) · XS · Low
- `PreferenceKey.parse()` Javadoc "interpolated" wording (casehubio/platform#10) · XS · Low
- `docs/repos/casehub-platform.md` deep-dive missing (casehubio/platform#11) · S · Med
- devtown not yet wired to platform-testing fixtures · S · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #5 | `config/` module — scope-aware YAML + env var PreferenceProvider | L | Med | Drools ChainedProperties; each harness ships its own YAML |
| #6 | `persistence-jpa/` — JPA-backed scoped PreferenceProvider | L | Med | Depends on config/ design |
| #7 | `persistence-mongodb/` — MongoDB alternative | M | Low | Follows work-testing pattern |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Separate from read providers |
| #9 | CurrentPrincipal @RequestScoped retrofit | S | Low | At RBAC implementation time |
| ledger#88 | ActorType migration to platform-api | M | Med | Unblocks CurrentPrincipal.actorType() |

## References

- DESIGN.md: `design/DESIGN.md` (workspace main)
- ADRs: `adr/0001` (Path split), `adr/0002` (PreferenceKey parser), `adr/0003` (null-returning get)
- Protocols updated this session: `typed-preference-keys.md`, `module-tier-structure.md`, `platform-spi-contract.md`
- Blog: `blog/2026-05-19-mdp01-laying-platform-foundation.md`
- Open issues: casehubio/platform #3, #5–#11
