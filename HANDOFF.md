# HANDOFF — casehub-platform

**Date:** 2026-06-24
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Closed #111 (OidcCurrentPrincipal `@Alternative @Priority(100)` + `MissingTenancyException`) and #110 (publish.yml dispatch list expanded from 4 to 12 repos). Filed #112 (consumer cleanup post-#111) and #113 (5 repos need `repository_dispatch` trigger).

## Immediate Next Step

No blockers. Pick from What's Next — all four unblocked.

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #103 | Credential resolution — secrets backend for `credentialRef` | M | Med | Unblocked |
| #85 | ScimDIDResolver — synthetic DID from SCIM | M | Med | Unblocked |
| #105 | LangChain4j AgentProvider bridge (provider-agnostic) | M | Med | Unblocked |
| #84 | JwtVCValidator — W3C VC JWT credential validation | M | High | Unblocked |
| #112 | Consumer cleanup — remove exclude-types workarounds, update oidc-harness-wiring-checklist | S | Low | Blocked by #111 (now shipped) |
| #113 | CI dispatch trigger gap — 5 repos need `repository_dispatch` | S | Low | Unblocked |

## References

*Unchanged — `git show HEAD~1:HANDOFF.md`*
