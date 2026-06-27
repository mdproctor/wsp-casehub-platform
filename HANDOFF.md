# HANDOFF — casehub-platform

**Date:** 2026-06-27
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Shipped #114, #115, #105 — three issues on one branch. MissingTenancyExceptionMapper in oidc (403 + JSON body). AgentProvider design rationale documented in agent-api README. New `agent-langchain4j/` module with bidirectional ChatModel↔AgentProvider adapters, replacing `agent-claude-langchain4j/`. Key design decision: `@DefaultBean @Priority(10)` not `@Alternative` — because `@Alternative` suppresses quarkus-langchain4j's `@DefaultBean` ChatModel entirely.

## Immediate Next Step

No blockers. Pick from What's Next — both unblocked.

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #85 | ScimDIDResolver — synthetic DID from SCIM | M | Med | Unblocked |
| #118 | AgentEvent extension — ToolCall, ToolResult, ThinkingDelta | M | Med | Deferred from #105. Additive (new sealed permits) |

## References

- Spec: `docs/superpowers/specs/2026-06-26-agent-langchain4j-interop-design.md`
- Blog: `blog/2026-06-27-mdp01-two-abstractions-one-architecture.md`
- Plan: `plans/attic/issue-114-agent-docs-mapper-bridge/2026-06-26-agent-langchain4j-interop.md`
- Garden: GE-20260627-51e402 (@Alternative suppresses @DefaultBean)
- Consumer docs issue: casehubio/parent#313
