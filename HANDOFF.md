# HANDOFF — casehub-platform

**Date:** 2026-05-28
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Shipped `CaseMemoryStore` SPI (platform#27 — closed). Full cycle: brainstorm → spec (4 review rounds) → TDD implementation → code review → work-end. Key deliverables: `CaseMemoryStore` blocking SPI + `MemoryDomain`/`MemoryInput`/`Memory`/`MemoryQuery`/`EraseRequest`/`MemoryPermissions` value types in `platform-api`; `ReactiveCaseMemoryStore` interface + `NoOpCaseMemoryStore @DefaultBean` + `BlockingToReactiveBridge @DefaultBean` in `platform`. ADR-0008 records adapter repo placement (separate `casehub-memory` repo). Platform issues #31–36 track adapters + CDI emission.

## Immediate Next Step

`work-start` on **GroupMembership OIDC provider** — deferred three times now.

## Cross-Module

No active blockers. Note: consumer adoption for CaseMemoryStore is tracked in devtown#43, clinical#33, aml#32 — no action required from platform side.

## What's Left

- Hook install still pending on 5 repos (branches open): `casehub/aml`, `casehub/clinical`, `hortora/garden`, `md-compare`, `casehub-poc` · XS · Low
- `md-compare` has an issue-workflow `commit-msg` hook in `.git/hooks/` (old way) — migrate when branch returns · XS · Low
- `casehub-parent/docs/repos/casehub-platform.md` deep-dive needs CaseMemoryStore sync (parent#85 filed) · XS · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| — | GroupMembership OIDC provider | M | Med | Needs directory (Keycloak Admin/LDAP) |
| #31 | Create `casehub-memory` repo — parent POM, CI, initial structure | S | Low | Prerequisite for adapters #32–34 |
| #32 | Memori adapter (`memory-memori/`) — Tier 1, SQL-native | L | Med | Blocked by #31 |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Parked — no UI work |

## References

- Spec: `docs/specs/2026-05-27-case-memory-store-design.md` (platform#27)
- ADR: `adr/0008-casememory-adapter-repository-placement.md`
- Blog: `blog/2026-05-28-mdp01-teaching-platform-to-remember.md`
- Garden: GE-20260528-74914d (@Blocking gotcha), GE-20260528-f0a75c (bridge pattern), GE-20260528-55a526 (MemoryPermissions)
- Protocol: PP-20260528-557f5c (spi-deletion-default-throws)
