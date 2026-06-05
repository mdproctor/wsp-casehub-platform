# HANDOFF — casehub-platform

**Date:** 2026-06-05
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Closed platform#39 and platform#49. CDI priority fix: `InMemoryMemoryStore` elevated from
`@Priority(1)` to `@Priority(10)` — test-override tier — resolving `AmbiguousResolutionException`
in `@QuarkusTest` when a production adapter (compile) and memory-inmem (test) coexist.
Emission pattern settled: direct injection is canonical; `@ObservesAsync` is unsafe (loses
`@RequestScoped` context); `@Observes` is acceptable. `JpaMemoryStore.storeAll()` override ships
— single transaction, per-item `assertTenant`, no partial writes on `SecurityException`. Filed
platform#69 (Mem0 storeAll batch deferred — Mem0 OSS has no batch endpoint).

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
- platform#69 — Mem0 storeAll() batch (Mem0 OSS has no batch endpoint — deferred) · S · Low
- Workspace epic branches past deletion dates — kept by user choice

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #68 | Authorization model design — resolve 6 open decisions, then implement | L | High | Read spec §6.9 first; flat vs role-based is the gate |
| — | ACL SPI + `acl-jpa/` module | L | Med | Blocked on #68 decisions |
| #34 | Graphiti adapter (`memory-graphiti/`) | L | Med | |
| #69 | Mem0 storeAll() batch — if Mem0 adds batch endpoint | S | Low | Deferred pending upstream |

## References

- ACL spec: `docs/specs/2026-06-01-acl-design.md`
- Agent spec: `docs/superpowers/specs/2026-06-02-agent-module-design.md`
- Blog: `blog/2026-06-05-mdp01-storeall-contract.md`
