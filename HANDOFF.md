# HANDOFF — casehub-platform

**Date:** 2026-05-21
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Housekeeping: closed #19 (quarkus-junit5 → quarkus-junit in platform/ and
config/), #20 (jandex version into parent pom property), and #21 (CI workflow
for GitHub Packages — `distributionManagement` was configured but no workflow
existed, so nothing was ever actually published). Confirmed ledger#88 still
open. Confirmed all four platform blog entries published to mdproctor.github.io.

## Immediate Next Step

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## Cross-Module

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Left

- devtown not yet wired to platform-testing fixtures · S · Low
- `casehub-platform-api` dep not added to devtown pom · S · Low

## What's Next

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## References

- DESIGN.md: `design/DESIGN.md` (workspace main — §Module Structure + §Identity API updated)
- ADR: `adr/0004-oidc-optional-module.md`
- Blog: `blog/2026-05-21-mdp03-wiring-the-pipeline.md`
- Deep-dive: `~/claude/casehub/parent/docs/repos/casehub-platform.md`
- Garden: GE-20260521-f50602 (oidc discovery-disabled needs jwks-path),
          GE-20260521-debce2 (@InjectMock + Arc request context technique)
- Workspace branches (all closed): epic-* (del. 2026-06-01/02/03),
  issue-17/issue-3/issue-19 (del. 2026-06-04)
