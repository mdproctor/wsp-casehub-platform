# HANDOFF — casehub-platform

**Date:** 2026-06-12
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Delivered platform#75: Graphiti domain-scoped erase. Changed `group_id` scheme to `{tenantId}::{entityId}::{domain}` — domain is now the partition key, enabling `DELETE /group` for complete GDPR Art.17 domain-level erasure. `erase(EraseRequest)` now returns `int` across all 9 adapters (GDPR Art.5(2) audit parity). `eraseEntity()` reinstated via `casehub.memory.graphiti.known-domains` config. Mem0 erase tests updated for pre-list pattern.

## Immediate Next Step

Check claudony#152 branch (`issue-152-tenancyid-default-fix`) — issue still open, branch needs merge. Confirm and close.

## Cross-Module

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Left

- claudony#152 — `ClaudonyLedgerEventCapture` tenancyId fail-fast fix; branch committed, issue open · XS · Low
- platform#58 — AgentSession multi-turn (v2, deferred) · L · Med
- platform#70 — Mem0 storeAll() parallel batch (deferred pending Mem0 PRs #4804/#5194) · S · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #70 | Mem0 storeAll() parallel batch | S | Low | Deferred pending Mem0 PRs #4804/#5194 |

## References

- ADR 0010: `adr/0010-remove-erase-by-id-from-graphiti-capabilities.md`
- Blog: `blog/2026-06-12-mdp01-graphiti-domain-scoped-erase.md`
- claudony#152 branch: `issue-152-tenancyid-default-fix`
