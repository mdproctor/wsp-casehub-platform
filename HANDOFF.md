# HANDOFF — casehub-platform

**Date:** 2026-06-09
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Closed platform#71, #74, #76 — issues closed, branch marked, PR #81 open to `casehubio/platform` main.

- **#71** SQLite `storeAll()`: `inputs.get(0)` → `inputs.forEach()` pre-flight; JDBC transaction opens only after all tenant checks pass.
- **#74** Graphiti `eraseById()`: removed `ERASE_BY_ID` from `capabilities()`; throws `MemoryCapabilityException`. DELETE /episode/{uuid} leaves derived EntityNode/EntityEdge facts — GDPR Art.17 incomplete. ADR 0010 documents the decision. Protocol PP-20260609-9b403d formalises the rule.
- **#76** Graphiti REST: `POST /search` exposes only `group_ids/query/max_facts`. `TEMPORAL_GRAPH` correct via client-side `validAt`/`invalidAt` filtering.

Cross-repo: claudony#152 committed (fail-fast on null tenancyId). Clinical git hooks installed. engine#460 filed (CaseLedgerEntry field shadowing).

## Immediate Next Step

Merge PR #81 (`casehubio/platform`). Then merge claudony#152 branch.

## Cross-Module

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Left

- claudony#152 branch needs merge · XS · Low
- engine#460 — `CaseLedgerEntry.tenancyId` field shadowing causes Hibernate NOT NULL violation (blocks claudony test suite) · S · Med
- platform#58 — AgentSession multi-turn (v2, deferred) · L · Med
- platform#70 — Mem0 storeAll() parallel batch (deferred pending Mem0 PRs #4804/#5194) · S · Low
- platform#75 — Graphiti erase(EraseRequest) domain+caseId scoped deletion · M · High
- Workspace epic branches past deletion dates — kept by user choice

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #70 | Mem0 storeAll() parallel batch | S | Low | Deferred pending Mem0 PRs #4804/#5194 |
| #75 | Graphiti domain+caseId erasure | M | High | Graphiti REST doesn't expose group-scoped delete |

## References

- PR #81: https://github.com/casehubio/platform/pull/81
- claudony#152 branch: `issue-152-tenancyid-default-fix`
- engine#460: https://github.com/casehubio/engine/issues/460
- ADR 0010: `adr/0010-remove-erase-by-id-from-graphiti-capabilities.md`
- Blog: `blog/2026-06-09-mdp01-erasing-what-was-extracted.md`
