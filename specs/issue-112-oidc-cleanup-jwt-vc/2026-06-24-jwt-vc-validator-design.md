# #84 — JwtVCValidator Design

## Overview

W3C VC JWT credential validation for agent identity binding. Implements
`AgentCredentialValidator` SPI in the identity module.

## Module & CDI

- **Module:** `identity/` (existing)
- **Annotation:** `@ApplicationScoped` — displaces `NoOpCredentialValidator @DefaultBean`
- **Package:** `io.casehub.platform.identity`

## Config

Extends `IdentityConfig` (`@ConfigMapping(prefix = "casehub.identity")`):

```java
Map<String, String> credentials();  // actorId → /path/to/vc.jwt
@WithDefault("1440")
int credentialCacheTtlMinutes();    // default 24h; EXPIRED never cached
```

Example:
```properties
casehub.identity.credentials."claude:reviewer@v1"=/etc/casehub/creds/reviewer.jwt
```

## Validation Flow

1. Look up credential file path for actorId in config
   - Not configured → return `Optional.empty()` (skip VC validation)
2. Read JWT from file, split on `.`, base64url-decode header + payload
3. Parse header JSON → extract `alg`, `kid`
4. Parse payload JSON → extract `iss`, `sub`, `exp`, `vc.credentialSubject`
5. Check `exp` → `EXPIRED` if past current time
6. Resolve issuer DID via `DIDResolver` → `ISSUER_UNKNOWN` if unresolvable
7. Find matching verification method by `kid` or key type → `ISSUER_UNKNOWN` if no key
8. Verify JWT signature (java.security) → `INVALID_SIGNATURE` if fails
9. Check `credentialSubject.id` matches `did` parameter → `INVALID_SIGNATURE` if mismatch
10. Return `VALID`

## Signature Verification

No external JWT library. Java 21 built-in crypto + Jackson (already in module).

| JWT `alg` | java.security algorithm | VerificationMethod type |
|-----------|------------------------|------------------------|
| `EdDSA`   | `Ed25519`              | `Ed25519VerificationKey2020` |
| `ES256`   | `SHA256withECDSA`      | `EcdsaSecp256r1VerificationKey2019` |

- JWT parsing: `Base64.getUrlDecoder()` + Jackson
- Ed25519: raw 32-byte key → X.509 via fixed 12-byte ASN.1 prefix
- ES256: raw 64-byte key (32 x + 32 y) → `ECPublicKeySpec`

## Caching

Extends `AbstractCachingIdentityProvider<CredentialValidationResult>`:

- `loadContext(key)` reads JWT file, parses, validates
- TTL-based eviction, default 24h, configurable
- `EXPIRED` → not cached (SPI contract: credentials may be renewed)
- `VALID` → cached for TTL
- `Optional.empty()` (not configured) → cached for TTL
- No dependency on ledger's `AgentKeyRotatedEvent` — TTL handles refresh

## Corrections from Issue Spec

1. **Config prefix:** `casehub.identity.credentials` (not `casehub.ledger.agent-identity.credentials`)
   — identity module uses `@ConfigMapping(prefix = "casehub.identity")`
2. **Cache invalidation:** TTL-based via `AbstractCachingIdentityProvider` (not `KeyRotationEntry`)
   — `AgentKeyRotatedEvent` is a ledger type, platform can't depend on it

## Testing

WireMock ITs (identity module already has WireMock):

1. Valid VC — Ed25519 signed, issuer resolves, all claims correct → `VALID`
2. Expired VC — valid sig but `exp` in past → `EXPIRED`
3. Tampered signature — modified payload → `INVALID_SIGNATURE`
4. Unknown issuer — issuer DID unresolvable → `ISSUER_UNKNOWN`
5. Subject mismatch — `credentialSubject.id` ≠ `did` param → `INVALID_SIGNATURE`
6. No credential configured — actorId not in config → `Optional.empty()`
7. Cache — validate twice, file read once; TTL expiry re-reads

Test helper generates Ed25519 keypair + signs JWT using `KeyPairGenerator.getInstance("Ed25519")`.
