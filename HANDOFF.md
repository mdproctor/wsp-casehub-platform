# HANDOFF — casehub-platform

**Date:** 2026-05-20
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Five epics completed: `epic-platform-api` (SPIs), `epic-platform-testing` (test fixtures), `epic-quarkus-alignment` (Path ParamConverter, SecurityIdentityAugmentor pattern, Javadoc), `epic-platform-config` (ConfigFilePreferenceProvider — scope-aware YAML + SmallRye Config, 20 tests). Quarkus integration research produced `docs/repos/casehub-platform.md`. Key architecture: `PreferenceKey<T>` carries a `Function<String, T> parser` (Drools pattern), enabling `MockPreferenceProvider.get(key)` to return typed values — eliminating `InMemoryPreferenceProvider`. The `config/` module reads YAML at `@PostConstruct`, resolves scope hierarchy, SmallRye Config overrides win. Issues #1, #4, #5, #10, #11, #12, #13, #15 closed.

## Immediate Next Step

devtown wires up `casehub-platform-api` in its own repo. Next platform work: `persistence-jpa/` (issue #6) when the time comes — no action needed immediately.

## What's Left

- Artifacts not published to GitHub Packages (only local `.m2`) · XS · Low
- devtown not yet wired to platform-testing fixtures · S · Low
- `casehub-platform-api` dependency not yet added to devtown pom · S · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #6 | `persistence-jpa/` — JPA-backed scoped PreferenceProvider | L | Med | Depends on config/ being stable |
| #7 | `persistence-mongodb/` — MongoDB alternative | M | Low | Follows work-testing pattern |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Separate from read providers |
| #9 | CurrentPrincipal @RequestScoped retrofit | S | Low | At RBAC implementation time |
| #14 | TenantContext → SettingsScope bridge | S | Med | Deferred — needs quarkiverse multitenancy adoption |
| ledger#88 | ActorType migration to platform-api | M | Med | Unblocks CurrentPrincipal.actorType() TODO |

## References

- DESIGN.md: `design/DESIGN.md` (workspace main)
- Deep-dive: `~/claude/casehub/parent/docs/repos/casehub-platform.md`
- ADRs: `adr/0001` (Path split), `adr/0002` (PreferenceKey parser+default), `adr/0003` (null-returning get)
- Protocols: `typed-preference-keys.md`, `module-tier-structure.md`, `platform-spi-contract.md`
- Blog: `blog/2026-05-20-mdp01-preferences-drools-cascade.md`
- Open issues: casehubio/platform #3, #6–#9, #14
- Workspace branches retained (all closed): epic-platform-api (del. 2026-06-01), epic-platform-testing (del. 2026-06-02), epic-quarkus-alignment (del. 2026-06-02), epic-platform-config (del. 2026-06-03)
