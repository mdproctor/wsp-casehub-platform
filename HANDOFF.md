# HANDOFF — casehub-platform

**Date:** 2026-06-07
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Closed platform#69. `Mem0CaseMemoryStore.storeAll()` now overrides the SPI default with
pre-flight `assertTenant` for all inputs before any REST call — sequential, fail-fast.
Same partial-write bug fixed in `InMemoryMemoryStore` (SPI default was leaving item 0
stored when item 1 failed tenant check). Contract test gap closed: the `[good, bad]`
mixed-tenant case was never tested; added to `CaseMemoryStoreContractTest`. Protocol
`memory-storeall-transactional-contract.md` updated with REST adapter clause. Filed
platform#70 (parallel storeAll revisit when Mem0 batch PRs merge) and platform#71
(SQLite pre-flight checks item 0 only — cosmetic, not broken).

## Immediate Next Step

Fix the claudony `tenancyId` null-guard protocol violation — still unresolved:
`casehub/src/main/java/io/casehub/claudony/casehub/ClaudonyLedgerEventCapture.java` line 67:
```java
entry.tenancyId = Objects.requireNonNull(event.tenancyId(), "tenancyId missing from CaseLifecycleEvent");
```
Then begin claudony#121 (full tenancy foundation).

## Cross-Module

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Left

- **claudony**: `ClaudonyLedgerEventCapture` null-guard protocol violation · XS · Low
- **qhorus**: local main diverged from casehubio upstream · S · Med
- Hook install pending: `casehub/aml`, `casehub/clinical`, `hortora/garden` · XS · Low
- platform#58 — AgentSession multi-turn (v2, deferred) · L · Med
- platform#68 — ACL/authorization model: 6 open decisions before design can start (see spec §6.9) · L · High
- platform#70 — Mem0 storeAll() parallel batch (revisit when Mem0 PRs #4804/#5194 merge) · S · Low
- platform#71 — SQLite storeAll() pre-flight checks item 0 only — cosmetic, not broken · XS · Low
- Workspace epic branches past deletion dates — kept by user choice

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #68 | Authorization model design — resolve 6 open decisions, then implement | L | High | Read spec §6.9 first; flat vs role-based is the gate |
| — | ACL SPI + `acl-jpa/` module | L | Med | Blocked on #68 decisions |
| #34 | Graphiti adapter (`memory-graphiti/`) | L | Med | |
| #70 | Mem0 storeAll() parallel batch | S | Low | Deferred pending Mem0 PRs #4804/#5194 |

## References

- ACL spec: `docs/specs/2026-06-01-acl-design.md`
- storeAll spec: `docs/superpowers/specs/2026-06-06-mem0-storeall-design.md`
- Blog: `blog/2026-06-07-mdp01-storeall-preflight.md`
