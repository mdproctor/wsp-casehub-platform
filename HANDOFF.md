# HANDOFF — casehub-platform

*Updated: parent#285 closed — removed from backlog.*

**Date:** 2026-06-20
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Closed all 7 open S/XS issues on one branch (`issue-101-platform-small-batch`). The headline changes: `storeAll()` return type changed from `List<String>` to `StoreAllResult` (breaking — affects all 6 adapters and the reactive bridge, upstream consumers will see compile errors); `CbrCaseEntry` added to platform-api as the CBR Retain step schema; `@Timed` added to all 7 public CaseMemoryStore methods in inmem, jpa, and sqlite (matching pre-existing coverage in mem0 and graphiti); `SystemMessage` now rejected explicitly in `AgentSessionChatModel` rather than silently ignored; Testcontainers IT scaffold created for memory-mem0 (`@Disabled` pending Ollama in CI). All tests pass. Both remotes updated.

## Immediate Next Step

Check `parent#276` (cloudevents-core BOM) — timing: file once any of iot#19, qhorus#279, or connectors#20 starts. Also `parent#285` now has an expanded comment covering the storeAll/StoreAllResult API change, CbrCaseEntry, and @Timed observability — sync PLATFORM.md when time allows.

## Cross-Module

**We're enabling:**
- casehub-engine (engine#477/478) — CbrCaseEntry is now available for the CBR Retain step
- iot#19, qhorus#279, connectors#20 — CloudEvent adapters still unblocked from platform#98

**Callers of `storeAll()` in consumer repos** will see compile errors — the return type is now `StoreAllResult`. Migration is mechanical: `result.stored()` for the ID list. File issues on consumer repos if not already raised.

## What's Left

- `platform#101` — closed ✅
- `platform#102` — closed ✅

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| parent#276 | Add cloudevents-core:4.0.1 to BOM | XS | Low | Do when iot/qhorus/connectors adapters start |
| iot#19 | StateChangeEvent → CloudEvent adapter | S | Low | Unblocked |
| qhorus#279 | MessageReceivedEvent → CloudEvent adapter | M | Med | Also covers channel creation SPI |
| connectors#20 | InboundMessage → CloudEvent adapter | S | Low | Unblocked |

## References

- Diary: `blog/2026-06-20-mdp01-small-issues-not-small-decisions.md`
- Epic: branch `issue-101-platform-small-batch` (closed)
- Garden: GE-20260620-29b8fc (Quarkus @Disabled + @QuarkusTestResource eager load)
- Protocols: PP-20260620-e9355b (@Timed on CaseMemoryStore), PP-20260620-d9675c (SecurityException propagation)
