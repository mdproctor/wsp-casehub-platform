# HANDOFF — casehub-platform

**Date:** 2026-06-08
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

*Updated: #68 closed — removed from backlog.*

---

## Last Session

Closed platform#34. `memory-graphiti/` ships as `@Alternative @Priority(2)` `GraphCaseMemoryStore`
backed by Graphiti OSS REST API (temporal knowledge graph). Added `MemoryCapability` enum +
`MemoryCapabilityException` — all adapters now self-declare capabilities, callers use
`requireCapability()` for typed exceptions. `GraphCaseMemoryStore extends CaseMemoryStore` added to
`platform-api` for graph-native `graphQuery(GraphMemoryQuery)`. `NoOpCaseMemoryStore` implements the
new interface. PR #77 open against casehubio/platform. Filed #74 (eraseById partial delete), #75
(erase domain+caseId unsupported), #76 (Graphiti REST param coverage), parent#203 (PLATFORM.md sync).

## Immediate Next Step

Fix the claudony `tenancyId` silent-default protocol violation:
`casehub/claudony/casehub/src/main/java/io/casehub/claudony/casehub/ClaudonyLedgerEventCapture.java` line 75:
```java
entry.tenancyId = event.tenancyId() != null ? event.tenancyId() : "default";
```
Falls back to `"default"` instead of failing fast — protocol violation. Fix, then begin claudony#121 (full tenancy foundation).

## Cross-Module

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Left

- **claudony**: `ClaudonyLedgerEventCapture` silently falls back to `"default"` tenancyId — protocol violation · XS · Low
- **qhorus**: large uncommitted WIP (15 modified, 5 untracked) — needs review before next session · M · Med
- Hook install pending: `casehub/clinical` only · XS · Low
- platform#58 — AgentSession multi-turn (v2, deferred) · L · Med
- platform#70 — Mem0 storeAll() parallel batch (revisit when Mem0 PRs #4804/#5194 merge) · S · Low
- platform#71 — SQLite storeAll() pre-flight checks item 0 only — cosmetic · XS · Low
- platform#74 — Graphiti eraseById() deletes episode only; derived facts persist · S · Med
- platform#75 — Graphiti erase(EraseRequest) domain+caseId scoped deletion not supported · M · High
- platform#76 — Verify Graphiti REST server exposes validAt/entityTypes in search endpoint · XS · Low
- parent#203 — PLATFORM.md / casehub-platform deep-dive needs memory-graphiti + GraphCaseMemoryStore entries · S · Low
- Workspace epic branches past deletion dates — kept by user choice

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #70 | Mem0 storeAll() parallel batch | S | Low | Deferred pending Mem0 PRs #4804/#5194 |

## References

- ACL spec: `docs/specs/2026-06-01-acl-design.md`
- Graphiti spec: `docs/superpowers/specs/2026-06-07-graphiti-memory-adapter-design.md`
- Blog: `blog/2026-06-08-mdp01-graphiti-temporal-memory-adapter.md`
- PR #77: https://github.com/casehubio/platform/pull/77
