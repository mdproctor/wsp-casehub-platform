# HANDOFF — casehub-platform

**Date:** 2026-05-22
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Short review session. A separate Claude session had landed `Path.root()` (d8d8461);
this session reviewed it, found missing tests and an unnecessary allocation on every
call, and fixed both. Six root-contract tests added, static ROOT constant introduced,
DESIGN.md updated to document the third construction path. Installed to local m2.

⚠️ `platform/pom.xml` has an uncommitted modification — investigate before next commit.

## Immediate Next Step

Resume `#7 persistence-mongodb/` — same pattern as persistence-jpa, no Flyway.
Start fresh with `work-start`. Investigate `platform/pom.xml` uncommitted change first.

## Cross-Module

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Next

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## References

- ADRs: `adr/0005` (ActorType), `adr/0006` (JPA current-only), `adr/0007` (SlaBreachPolicy in work-api)
- Blog: `blog/2026-05-22-mdp05-the-root-that-didnt-cache.md` (latest)
- Garden: GE-20260522-a69fa1 (String.matches anchor), REVISE GE-20260519-b9719e (Optional<Map> nested prefix)
- Protocol: PP-20260522-359dfc (CurrentPrincipal booleans delegate to actorType())
- casehub-work: work#212 (wiring), work#213 (SlaBreachPolicy API — full type design in issue)
