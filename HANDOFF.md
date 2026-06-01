# HANDOFF — casehub-platform

**Date:** 2026-06-01
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Three fixes landed on main: (1) Jandex index added to `casehub-platform-api` (#54) — SPI jar was missing `META-INF/jandex.idx`, breaking ARC type resolution in consumers. (2) Keycloak DevServices disabled in SCIM tests (#54) — `quarkus-oidc-client` was spinning up a full Keycloak container even with static token auth; fixing this surfaced a `SRCFG00050` config gap (`member-page-size` not declared in `ScimConfig`), both fixed, SCIM tests now run in 5s. (3) `ScimActorDIDProvider` constructor and `validateEndpoint` widened to public (#53 prep). `AgentIdentityVerificationService` / `ReactiveAgentIdentityVerificationService` with primitive signature added to `casehub-platform-identity` (#53 — now closed). ledger#113 also closed.

## Immediate Next Step

Platform#53 and ledger#113 are both closed — identity extraction is complete. Next: pick from What's Next. #49 (CDI emission) needs app feedback first; #39 blocks on #33. Alternatives: hook installs on 5 repos (What's Left) or start #33 (Mem0 adapter).

## Cross-Module

**We're blocking:**
- Unknown repo — `WorkBroker` and `ExclusionPolicy` call `membersOf()` expecting `Set<String>`. Identify correct repo and file issue. · S · Low

## What's Left

- Hook install pending on 5 repos: `casehub/aml`, `casehub/clinical`, `hortora/garden`, `casehub/drafthouse`, `casehub-poc` · XS · Low
- parent#130 filed — `docs/PLATFORM.md` + `docs/repos/casehub-platform.md` need `memory-sqlite` added · XS · Low
- Workspace epic branches past deletion dates: `epic-platform-api`, `epic-platform-testing`, `epic-quarkus-alignment`, `epic-platform-config` — kept by user choice

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #49 | CDI emission investigation — Options A/B/C + storeAll batch | M | Med | Needs devtown/clinical/aml app feedback first |
| #39 | CDI priority revisit when `memory-mem0/` arrives | S | Med | Blocks on #33 |
| #33 | Mem0 adapter | L | Med | |
| #34 | Graphiti adapter | L | Med | |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Parked |

## References

- Blog: `blog/2026-06-01-mdp02-oom-hiding-config-bug.md`
- Prior blog: `blog/2026-06-01-mdp01-five-closes-one-gotcha.md`
- Garden: GE-20260601-08a351 (quarkus-oidc-client triggers Keycloak DevServices even with static token auth), revise GE-20260529-5a8158 (OOMKill masks SRCFG00050)
- Protocols: PP-20260601-b600ee (configmapping-prefix-ownership), revised library-jars-require-jandex to include SPI supertypes
