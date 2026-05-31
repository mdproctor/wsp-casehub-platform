# HANDOFF — casehub-platform

**Date:** 2026-05-31
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Shipped #37 `memory-sqlite/` — SQLite CaseMemoryStore adapter with HikariCP (WAL mode), FTS5 content table, programmatic Flyway, and full contract test suite (28 tests). Prerequisite: extracted `CaseMemoryStoreContractTest` abstract base from `testing/`; both `memory-inmem` and `memory-jpa` now extend it. Branch closed, squashed to 3 commits on main.

## Immediate Next Step

Fix `casehub-work` — WorkBroker and ExclusionPolicy callers still treating `membersOf()` as `Set<String>`. Issues already filed there. Mechanical update; start a new branch with `/work`.

## Cross-Module

**We're blocking:**
- `casehub-work` — WorkBroker and ExclusionPolicy call `membersOf()` expecting `Set<String>`. Mechanical update; issues filed on casehub-work. · S · Low

## What's Left

- `erase()` logic inversion in `InMemoryMemoryStore` — null-caseId filter inverted for null-caseId path; passes tests by coincidence. File a separate issue · XS · Low
- Hook install pending on 5 repos: `casehub/aml`, `casehub/clinical`, `hortora/garden`, `md-compare`, `casehub-poc` · XS · Low
- `md-compare` — legacy commit-msg hook in `.git/hooks/`, migrate when branch returns · XS · Low
- parent#130 filed — `docs/PLATFORM.md` + `docs/repos/casehub-platform.md` need memory-sqlite added (peer repo, filed) · XS · Low
- platform#50 filed — `fts.enabled=false` test profile for `memory-sqlite` · XS · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #47 | SCIM pagination — groups >1000 members | S | Med | Deferred from #45 |
| #49 | CDI emission investigation — Options A/B/C + storeAll batch | M | Med | Needs devtown/clinical/aml app feedback first |
| #39 | CDI priority revisit when `memory-mem0/` arrives | S | Med | Blocks on #33 |
| #33 | Mem0 adapter — builds against updated SPI | L | Med | |
| #34 | Graphiti adapter — builds against updated SPI | L | Med | |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Parked |

## References

- Blog: `blog/2026-05-31-mdp01-durable-memory-no-server.md`
- Spec: `docs/superpowers/specs/2026-05-31-memory-sqlite-design.md` (project repo)
- Plan: `plans/attic/issue-37-memory-sqlite/2026-05-31-memory-sqlite.md`
- Garden: GE-20260531-2ca323 (HikariCP PropertyElf gotcha), GE-20260531-db10ab (ISO-8601 ordering), GE-20260531-20d80a (HikariCP+xerial technique), GE-20260531-df79cb (FTS5 content-table)
- Protocol: PP-20260531-91b500 (FixedCurrentPrincipal setup when casehub-platform-testing on test classpath)
