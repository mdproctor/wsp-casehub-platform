# HANDOFF — casehub-platform

**Date:** 2026-06-28
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Shipped #117, #118 on one branch. Verified InMemoryEndpointRegistry fires EndpointRegistered CDI event (was already correct — added mock-based test). Extended AgentEvent from `sealed permits TextDelta` to 5 permits: ThinkingDelta, ToolCallDelta, ToolCallComplete, ToolResult. Updated AgentProvider javadoc to make the architectural positioning explicit (platform abstraction, LangChain4j is one adapter path). Updated LangChain4j bridge to forward new event types to StreamingChatResponseHandler. Filed #119 (ClaudeAgentClient messages() upgrade) and #120 (ChatModelAgentProvider streaming upgrade) as follow-ons.

## Immediate Next Step

No blockers. Pick from What's Next — all unblocked except #85.

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #119 | ClaudeAgentClient → messages() for richer AgentEvent emission | M | Med | Depends on #118 (done). Maps SDK ToolUseBlock/ThinkingBlock to new events |
| #120 | ChatModelAgentProvider → StreamingChatModel for richer events | M | Med | Depends on #118 (done). Uses streaming path when model supports it |
| #85 | ScimDIDResolver — synthetic DID from SCIM | M | Med | Blocked by ledger#107 |
| #121 | OidcCurrentPrincipal graceful non-OIDC handling | S | Low | Unblocked |

## References

- Spec: `docs/superpowers/specs/2026-06-27-endpoint-event-agent-event-design.md`
- Blog: `blog/2026-06-28-mdp01-making-tool-calls-visible.md`
- Plan: `plans/attic/issue-117-endpoint-event-agent-event/2026-06-27-endpoint-event-agent-event.md`
