# HANDOFF — casehub-platform

**Date:** 2026-05-25
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Closed issue #25: normalised `jandex-maven-plugin` version from hardcoded `3.3.1` to `${jandex-maven-plugin.version}` in `platform/pom.xml` and `testing/pom.xml`. The core Jandex fix was already committed (132c9af) but the issue stayed open because the commit used `#25` not `closes #25`. Also applied `size:XS`–`size:XL` labels to all open GitHub issues.

## Immediate Next Step

`work-start` on the **GroupMembership OIDC provider** — deferred twice now, still the planned work.

## Cross-Module

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Left

- Hook install still pending on 5 repos (branches open): `casehub/aml`, `casehub/clinical`, `hortora/garden`, `md-compare`, `casehub-poc` · XS · Low
- `md-compare` has an issue-workflow `commit-msg` hook in `.git/hooks/` (old way) — migrate when branch returns · XS · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| — | GroupMembership OIDC provider | M | Med | Needs directory (Keycloak Admin/LDAP) |
| #27 | CaseMemoryStore SPI — `platform-api/` + no-op default + Memori adapter | L | Med | Spec at `docs/specs/case-memory-store.md`; open Qs: fact emission, module placement |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Parked — no UI work |

## References

- Blog: `blog/2026-05-25-mdp02-already-fixed-still-open.md` (latest)
- Memory spec: `docs/specs/case-memory-store.md` (platform#27)
- Protocols: *Unchanged — `git show HEAD~1:HANDOFF.md`*
- Garden: *Unchanged — `git show HEAD~1:HANDOFF.md`*
