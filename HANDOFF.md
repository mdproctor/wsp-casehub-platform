# HANDOFF — casehub-platform

**Date:** 2026-05-31
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Closed #35 (reactive storeAll), #47 (SCIM pagination), #51 (erase contract test) on a single batch branch, squashed to main (e2c2a23). Closed #46 (duplicate of #47) and #50 (already done in #37 squash). Filed and closed #51 as verified. Full branch hygiene: all 20 project branches now carry `chore: branch closed` stamp; workspace branches for issue-38 and issue-41-42 marked closed (content superseded). Blogs confirmed published (all 20 up to 2026-05-31).

## Immediate Next Step

Pick up `casehub-work` — WorkBroker and ExclusionPolicy callers still treating `membersOf()` as `Set<String>`. Start a new branch with `/work`.

## Cross-Module

**We're blocking:**
- `casehub-work` — WorkBroker and ExclusionPolicy call `membersOf()` expecting `Set<String>`. Mechanical update; issues filed on casehub-work. · S · Low

## What's Left

- Hook install pending on 5 repos: `casehub/aml`, `casehub/clinical`, `hortora/garden`, `casehub/drafthouse`, `casehub-poc` · XS · Low
- parent#130 filed — `docs/PLATFORM.md` + `docs/repos/casehub-platform.md` need memory-sqlite added (peer repo, filed) · XS · Low
- Workspace epic branches pending user deletion (passed due dates): `epic-platform-api` (2026-06-01), `epic-platform-testing` (2026-06-02), `epic-quarkus-alignment` (2026-06-02), `epic-platform-config` (2026-06-03) — kept by user choice, flag for next session
- `issue-41-42-bridge-thread-housekeeping` in project repo has two `chore: branch closed` stamps (harmless, cosmetic)

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #49 | CDI emission investigation — Options A/B/C + storeAll batch | M | Med | Needs devtown/clinical/aml app feedback first |
| #39 | CDI priority revisit when `memory-mem0/` arrives | S | Med | Blocks on #33 |
| #33 | Mem0 adapter — builds against updated SPI | L | Med | |
| #34 | Graphiti adapter — builds against updated SPI | L | Med | |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Parked |

## References

- Blog: `blog/2026-05-31-mdp01-durable-memory-no-server.md`
- Spec: `docs/superpowers/specs/2026-05-31-memory-sqlite-design.md` (project repo)
- Garden: GE-20260531-2ca323 (HikariCP PropertyElf gotcha), GE-20260531-db10ab (ISO-8601 ordering), GE-20260531-20d80a (HikariCP+xerial technique), GE-20260531-df79cb (FTS5 content-table)
- Protocol: PP-20260531-91b500 (FixedCurrentPrincipal setup when casehub-platform-testing on test classpath)
