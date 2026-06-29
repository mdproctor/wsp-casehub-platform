# HANDOFF — casehub-platform

**Date:** 2026-06-28
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

*Updated: #119, #121 closed — removed from backlog.*

## Last Session

Shipped #117, #118, #119, #121. ClaudeAgentClient upgraded to messages() API for richer AgentEvent emission. OidcCurrentPrincipal now handles non-OIDC SecurityIdentity gracefully.

## Immediate Next Step

No blockers. Pick from What's Next — all unblocked except #85.

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #120 | ChatModelAgentProvider → StreamingChatModel for richer events | M | Med | Depends on #118 (done). Uses streaming path when model supports it |
| #85 | ScimDIDResolver — synthetic DID from SCIM | M | Med | Blocked by ledger#107 |

## References

- Spec: `docs/superpowers/specs/2026-06-27-endpoint-event-agent-event-design.md`
- Blog: `blog/2026-06-28-mdp01-making-tool-calls-visible.md`
- Plan: `plans/attic/issue-117-endpoint-event-agent-event/2026-06-27-endpoint-event-agent-event.md`
