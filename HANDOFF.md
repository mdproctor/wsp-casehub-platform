# HANDOFF — casehub-platform

**Date:** 2026-06-01
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

ACL design session. Researched all Quarkus-available options (Keycloak AuthZ, @PermissionsAllowed, OpenFGA, SpiceDB, jCasbin, OPA) and decided on custom flat JPA with implicit inheritance. Case is the natural ACL boundary — every engine entity traces to caseId in one hop. Multi-tenancy stays as a data layer filter (tenancyId already on all engine entities). Worker use cases (quarkus-flow, drools) arriving within 24 hours held implementation — spec written at `docs/specs/2026-06-01-acl-design.md`.

## Immediate Next Step

quarkus-flow and drools workers are landing imminently. Read the new worker use cases and answer the open questions in §6.5 of `docs/specs/2026-06-01-acl-design.md` before filing a GitHub issue or writing any ACL code.

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
| — | ACL SPI + acl-jpa/ module | L | Med | Blocked on worker use cases — read spec §6.5 first |
| #49 | CDI emission investigation — Options A/B/C + storeAll batch | M | Med | Needs devtown/clinical/aml app feedback first |
| #39 | CDI priority revisit when `memory-mem0/` arrives | S | Med | Blocks on #33 |
| #33 | Mem0 adapter | L | Med | |
| #34 | Graphiti adapter | L | Med | |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Parked |

## References

- ACL spec: `docs/specs/2026-06-01-acl-design.md`
- Blog: `blog/2026-06-01-mdp03-the-permission-layer.md`
- Prior blog: `blog/2026-06-01-mdp02-oom-hiding-config-bug.md`
