# HANDOFF — casehub-platform

**Date:** 2026-06-09
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Closed platform#71, #74, #76 on branch `issue-71-memory-adapter-fixes`. PR #80 open.

- **#71** SQLite `storeAll()` pre-flight: replaced `inputs.get(0)` check with `inputs.forEach()` — all inputs verified before the JDBC transaction opens.
- **#74** Graphiti `eraseById()`: removed `ERASE_BY_ID` from `capabilities()`; method now throws `MemoryCapabilityException`. Graphiti `DELETE /episode/{uuid}` only removes the source `EpisodicNode`; derived entity/relationship facts persist — GDPR Art.17 completeness cannot be guaranteed.
- **#76** Graphiti REST params verified: `POST /search` exposes only `group_ids`/`query`/`max_facts`. `TEMPORAL_GRAPH` works via client-side filtering of returned `validAt`/`invalidAt` fields. `ENTITY_TYPE_FILTER` and `ENTITY_TRAVERSAL` correctly absent. Documented in `capabilities()`.

Cross-repo: claudony#152 committed on `issue-152-tenancyid-default-fix` — `ClaudonyLedgerEventCapture` no longer defaults `tenancyId` to `"default"` on null; fails fast instead. Filed engine#460 for `CaseLedgerEntry.tenancyId` field shadowing issue. Clinical git hooks installed.

## Immediate Next Step

Merge PR #80 into `casehubio/platform`. Then merge claudony#152 branch.

## Cross-Module

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Left

- claudony#152 branch needs merge
- engine#460 — `CaseLedgerEntry.tenancyId` field shadowing causes Hibernate NOT NULL violation (blocks claudony test suite)
- platform#58 — AgentSession multi-turn (v2, deferred) · L · Med
- platform#70 — Mem0 storeAll() parallel batch (deferred pending Mem0 PRs #4804/#5194) · S · Low
- platform#74 → closed by PR #80
- platform#75 — Graphiti erase(EraseRequest) domain+caseId scoped deletion · M · High
- Workspace epic branches past deletion dates — kept by user choice

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #70 | Mem0 storeAll() parallel batch | S | Low | Deferred pending Mem0 PRs #4804/#5194 |
| #75 | Graphiti domain+caseId erasure | M | High | Graphiti REST doesn't expose group-scoped delete |

## References

- PR #80: https://github.com/casehubio/platform/pull/80
- claudony#152 branch: `issue-152-tenancyid-default-fix`
- engine#460: https://github.com/casehubio/engine/issues/460
- ACL spec: `docs/specs/2026-06-01-acl-design.md`
- Blog: `blog/2026-06-08-mdp01-graphiti-temporal-memory-adapter.md`
