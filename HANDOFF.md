# HANDOFF — casehub-platform

**Date:** 2026-06-23
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Closed three XS/S CloudEvent conformance issues (#107, #108, #109). Key finding: GE rule 3 (`.exceptionally()` for CloudEvent dispatch) must NOT be applied in Kafka/AMQP processors that chain `.thenCompose(message.ack())` — it would silently ack messages on dispatch failure. Updated GE-20260621-629712; filed protocol PP-20260623-a0fe15.

## Immediate Next Step

No blockers. Pick from What's Next — all four unblocked.

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #103 | Credential resolution — secrets backend for `credentialRef` | M | Med | Unblocked |
| #85 | ScimDIDResolver — synthetic DID from SCIM | M | Med | Unblocked |
| #105 | LangChain4j AgentProvider bridge (provider-agnostic) | M | Med | Unblocked |
| #84 | JwtVCValidator — W3C VC JWT credential validation | M | High | Unblocked |

## References

- Diary: `blog/2026-06-23-mdp01-cloudevent-conformance.md`
- Garden: GE-20260621-629712 (updated — rule 3 ack-chain exception)
- Protocol: PP-20260623-a0fe15 (reactive-messaging-ack-chain-whenComplete)
