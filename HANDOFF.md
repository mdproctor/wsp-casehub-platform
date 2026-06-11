# HANDOFF — casehub-platform

**Date:** 2026-06-11
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Delivered the XS/S correctness batch (platform#54,62,64,72,79) and a follow-up (platform#82). All merged.

- **#62** `ScimActorDIDProvider`: test constructor `requireHttps=false`; `authToken` blank → hard fail at `@PostConstruct`
- **#79** `MemoryPermissions` 3-arg async-aware `assertTenant`; all adapters updated; `@ActivateRequestContext` on 5 `@QuarkusTest` classes
- **#72** `eraseEntity()` `void` → `int` count across all adapters + reactive bridge
- **#64** `eraseById(memoryId, entityId, tenantId)` — entityId param added; Mem0 preflight GET; entity mismatch = silent no-op
- **#82** 5-arg `ScimActorDIDProvider` test constructor with explicit `requireHttps` — closes HTTPS enforcement test gap
- **#54** already resolved; issue closed

engine#460 (CaseLedgerEntry.tenancyId shadowing) closed independently in the engine repo on 2026-06-10.

## Immediate Next Step

Check claudony#152 branch (`issue-152-tenancyid-default-fix`) — issue still open, branch likely needs merge. Confirm and close.

## Cross-Module

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Left

- claudony#152 — `ClaudonyLedgerEventCapture` tenancyId fail-fast fix; branch committed, issue open · XS · Low
- platform#58 — AgentSession multi-turn (v2, deferred) · L · Med
- platform#70 — Mem0 storeAll() parallel batch (deferred pending Mem0 PRs #4804/#5194) · S · Low
- platform#75 — Graphiti erase(EraseRequest) domain+caseId scoped deletion · M · High

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #70 | Mem0 storeAll() parallel batch | S | Low | Deferred pending Mem0 PRs #4804/#5194 |
| #75 | Graphiti domain+caseId erasure | M | High | Graphiti REST doesn't expose group-scoped delete |

## References

- ADR 0010: `adr/0010-remove-erase-by-id-from-graphiti-capabilities.md`
- Blog: `blog/2026-06-10-mdp01-the-missing-entity.md`
- claudony#152 branch: `issue-152-tenancyid-default-fix`
