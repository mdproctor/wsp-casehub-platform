# HANDOFF — casehub-platform

**Date:** 2026-05-22
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Infrastructure housekeeping: created `mdproctor/platform` fork (was missing unlike all other casehubio repos), ran full squash (62 → 54 commits, no conflicts), pushed to both `origin` (casehubio) and `mdproctor` remotes. Added downstream CI trigger to `publish.yml` — ledger and connectors fire `upstream-published` on successful deploy, using `GH_PAT` set at org level. casehubio CI green; mdproctor Actions not enabled (opt-in required).

## Immediate Next Step

Start `#8 preferences-editor/` — admin UI/API write path for MongoDB preferences. Run `work-start` on issue #8.

## Cross-Module

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Left

- `engine#329` — fix `CaseLedgerEventCapture.java` import (`ActorType` moved to `platform-api` in ledger#88; engine fails to compile on current `0.2-SNAPSHOT`) · XS · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Primary next |
| — | GroupMembership OIDC provider | M | Med | Needs directory (Keycloak Admin/LDAP) |

## References

- ADRs: `adr/0005` (ActorType), `adr/0006` (JPA current-only), `adr/0007` (SlaBreachPolicy in work-api)
- Blog: `blog/2026-05-22-mdp07-root-scope-cdi-ladder.md` (latest — no entry written this session)
- Garden: GE-20260522-409183 (GIT_SEQUENCE_EDITOR SHA typo), GE-20260522-b9a6d4 (force-with-lease fresh fork)
- Squash backup: `backup/pre-squash-main-20260522` (local only)
