# HANDOFF — casehub-platform

**Date:** 2026-06-17
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Shipped platform#100 (agent-claude-langchain4j) — two LangChain4j ChatModel/StreamingChatModel adapters backed by AgentSession: `ClaudeAgentChatModel` (`@Alternative @Priority(10) @ApplicationScoped`, fresh session per call) and `AgentSessionChatModel` (plain wrapper, caller owns session). 50 tests. 7-round spec review before implementation. Key non-obvious finding: both ChatModel and StreamingChatModel declare four identical default methods — explicit overrides required for all four (diamond resolution). `engine.Agent` always forces `ResponseFormatType.JSON`; this adapter is incompatible with that path. Two follow-up issues filed (#101, #102).

## Immediate Next Step

Pick up issue #70 (Mem0 storeAll() parallel batch) — deferred pending Mem0 OSS PRs #4804/#5194. Check upstream PR status before starting work.

## Cross-Module

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Left

- `platform#70` — Mem0 storeAll() parallel batch (deferred pending Mem0 PRs #4804/#5194) · S · Low
- `platform#101` — document session.close() Mutiny callback thread ordering in ClaudeAgentChatModel · XS · Low
- `platform#102` — add SystemMessage silent-ignore note + test to AgentSessionChatModel · XS · Low
- `parent#249` — PLATFORM.md deep-dive sync for platform#88+#89 (EndpointPermissions + endpoints-config) · XS · Low
- `parent#257` — PLATFORM.md + casehub-platform deep-dive sync for platform#58 (AgentSession multi-turn) · XS · Low
- `parent#266` — sync PLATFORM.md capability ownership for agent-claude-langchain4j (#100) · XS · Low
- `parent#267` — sync casehub-platform.md agent infrastructure section for #100 · XS · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #70 | Mem0 storeAll() parallel batch | S | Low | Deferred pending Mem0 PRs — check upstream first |
| #99 | cross-tenant CaseMemoryStore.eraseEntity() — GDPR Art.17 | M | Med | |
| #98 | CloudEvent foundation in platform-api and stream modules | M | Med | |
| #90 | move ReactiveCaseMemoryStore SPI to casehub-platform-api | S | Med | |

## References

- Spec (ChatModel adapter): `docs/superpowers/specs/2026-06-16-chatmodel-agent-session-design.md`
- platform#100: https://github.com/casehubio/platform/issues/100 (closed)
- Follow-up: https://github.com/casehubio/platform/issues/101, https://github.com/casehubio/platform/issues/102
