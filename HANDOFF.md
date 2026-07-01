# HANDOFF — casehub-platform

**Date:** 2026-07-01
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Closed #130 (KeyDIDResolver multicodec) and #128 (composite ActorDIDProvider) on one branch. Design review ($20, 7 rounds) caught two correctness bugs — alsoKnownAs missing from did:key documents (would cause IDENTITY_MISMATCH) and P-256 sign selection (~50% wrong decompression). Filed #131 (base58btc), #132 (HTTPS validation), #133 (secp256k1), ledger#165 (IdentityCacheInvalidator). Garden entry GE-20260630-1594e0 (secp256k1 JDK removal).

## Immediate Next Step

Pick from What's Next — ledger#165 is the most urgent (downstream fix, XS).

## What's Left

- casehubio/ledger#161 — update DIDResolver callers for actorId parameter · S · Low
- casehubio/ledger#165 — IdentityCacheInvalidator: use invalidate() instead of instanceof · XS · Low
- #131 — did:key base58btc vs base64url encoding deviation · M · Med
- #132 — ScimAgentLookup HTTPS validation consolidation · S · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #131 | did:key base58btc encoding (W3C spec compliance) | M | Med | pre-existing deviation; no interop impact until external DIDs |
| #132 | ScimAgentLookup HTTPS validation consolidation | S | Low | PostConstruct removed from ScimActorDIDProvider; validation should move to lookup |
| #133 | secp256k1 did:key support | M | High | requires BouncyCastle or manual curve params; JDK 15+ removed from SunEC |

## References

| Type | Path |
|------|------|
| Design spec | `docs/superpowers/specs/2026-06-30-did-key-multicodec-composite-actor-design.md` |
| ARC42STORIES | `ARC42STORIES.MD` |
| Garden entry | `GE-20260630-1594e0` (secp256k1 JDK removal) |
