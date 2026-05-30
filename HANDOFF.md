# HANDOFF — casehub-platform

**Date:** 2026-05-30
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Shipped the platform#48 SPI evolution — 10 commits resolving five consumer-feedback gaps on `CaseMemoryStore`. Key changes: `MemoryQuery` breaking change (entityId→entityIds List, MemoryOrder enum, with* fluent API), `MemoryAttributeKeys` constants + confidence helpers, `MemoryInput` blank text guard, emission pattern Javadoc (three options, deferred). Adapter updates for memory-inmem and memory-jpa. Issue #36 closed, child issue #49 created for CDI emission investigation.

## Immediate Next Step

Start on `casehub-work` — fix `WorkBroker` and `ExclusionPolicy` callers that still treat `membersOf()` as `Set<String>` (mechanical update, issues already filed there). Or begin #37 `memory-sqlite/`.

## Cross-Module

**We're blocking:**
- `casehub-work` — WorkBroker and ExclusionPolicy call `membersOf()` expecting `Set<String>`. Mechanical update; issues filed on casehub-work. · S · Low

## What's Left

- Pre-existing `erase()` logic inversion in `InMemoryMemoryStore` — filter condition inverted for null-caseId path; passes tests by coincidence. File a separate issue. · XS · Low
- Hook install pending on 5 repos: `casehub/aml`, `casehub/clinical`, `hortora/garden`, `md-compare`, `casehub-poc` · XS · Low
- `md-compare` — legacy commit-msg hook in `.git/hooks/`, migrate when branch returns · XS · Low
- `docs/PLATFORM.md` + `docs/repos/casehub-platform.md` in parent — stale for GroupMember SPI + scim/ + new memory types (parent#113 filed) · XS · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #37 | `memory-sqlite/` — SQLite adapter, durable pure-Java | M | Med | Evaluate single-writer concurrency first |
| #47 | SCIM pagination — groups >1000 members | S | Med | Deferred from #45 |
| #49 | CDI emission investigation — Options A/B/C + storeAll batch | M | Med | Needs devtown/clinical/aml app feedback first |
| #39 | CDI priority revisit when `memory-mem0/` arrives | S | Med | Blocks on #33 |
| #33 | Mem0 adapter — builds against updated SPI | L | Med | |
| #34 | Graphiti adapter — builds against updated SPI | L | Med | |
| #8 | `preferences-editor/` — admin UI/API write path | XL | High | Parked |

## References

- Spec: `docs/superpowers/specs/2026-05-30-casememorystore-consumer-feedback-design.md` (project repo)
- Plan: `plans/2026-05-30-casememorystore-consumer-feedback.md` (workspace)
- Blog: `blog/2026-05-30-mdp02-the-api-that-told-the-truth.md`
- Garden: GE-20260530-3cc195 (Locale.ROOT for format), GE-20260530-02ef50 (multi-module test grep), GE-20260530-5400f3 (Hibernate 6 native IN with List)
