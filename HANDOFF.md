# HANDOFF — casehub-platform

**Date:** 2026-07-01
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Closed #132 (ScimAgentLookup HTTPS validation consolidation). One-line production change: `validate()` called lazily in `loadContext()` after the `isConfigured()` guard. Deleted duplicate `ScimActorDIDProviderValidationTest`, consolidated into `ScimAgentLookupTest`. Net -37 lines.

## Immediate Next Step

Pick from What's Next — ledger#165 is the most urgent (downstream fix, XS), but lives in the ledger repo. For platform work, #131 (base58btc encoding, M/Med) is next.

## What's Left

- casehubio/ledger#161 — update DIDResolver callers for actorId parameter · S · Low
- casehubio/ledger#165 — IdentityCacheInvalidator: use invalidate() instead of instanceof · XS · Low
- #131 — did:key base58btc vs base64url encoding deviation · M · Med

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #131 | did:key base58btc encoding (W3C spec compliance) | M | Med | no interop impact until external DIDs |
| #133 | secp256k1 did:key support | M | High | requires BouncyCastle or manual curve params |

## References

| Type | Path |
|------|------|
| Design spec | `docs/superpowers/specs/2026-06-30-did-key-multicodec-composite-actor-design.md` |
| ARC42STORIES | `ARC42STORIES.MD` |
| Garden entry | `GE-20260630-1594e0` (secp256k1 JDK removal) |
