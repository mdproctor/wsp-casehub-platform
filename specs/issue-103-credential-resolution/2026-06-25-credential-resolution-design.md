# Tier 2 Credential Resolution — Design Spec

**Issue:** casehubio/platform#103
**Date:** 2026-06-25
**Status:** Approved

## Problem

`EndpointDescriptor.credentialRef` (shipped platform#73) stores a logical credential
name but nothing resolves it to an actual secret at runtime. Consumers that need
credentials for outbound calls (streams-poll HTTP, Camel routes, etc.) have no
platform-provided way to look up secrets by name.

The interim Tier 1.5 pattern (qhorus slack-channel) hardcodes per-module MicroProfile
Config lookups (`config.getValue("casehub.qhorus.slack-channel.credentials." + workspaceId)`).
This does not scale — every module reinvents credential resolution with its own config prefix.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Architecture | Own SPI in platform-api + Quarkus bridge deferred | platform-api is zero-dep; SPI must be pure Java. Bridge to `io.quarkus.credentials.CredentialsProvider` is mechanical once SPI exists — defer until a consumer needs Vault/AWS |
| Return type | `Map<String, String>` | Handles compound credentials (user+password, client_id+client_secret). Mirrors Quarkus CredentialsProvider for bridge compatibility |
| Integration | Pull model | Consumers inject resolver and call explicitly. No coupling to EndpointRegistry. No unnecessary secret fetches on discovery queries |
| @DefaultBean | Env-var resolver | Self-contained, always works, zero external deps. `credentialRef` → `CASEHUB_CREDENTIAL_<REF>` env var |
| Constants | USER, PASSWORD, BEARER_TOKEN, API_KEY, EXPIRES_AT | Covers database/messaging (user+password), HTTP endpoints (bearer/api-key), and rotation (expires-at) |

## SPI — `CredentialResolver`

**Package:** `io.casehub.platform.api.credentials`
**Module:** `platform-api` (zero dependencies)

```java
public interface CredentialResolver {

    String USER = "user";
    String PASSWORD = "password";
    String BEARER_TOKEN = "bearer-token";
    String API_KEY = "api-key";
    String EXPIRES_AT = "expires-at";

    /**
     * Resolve the credential properties for the given logical reference.
     *
     * @param credentialRef the logical credential name (from EndpointDescriptor.credentialRef())
     * @return credential properties keyed by standard constants, or empty map if unresolvable
     */
    Map<String, String> resolve(String credentialRef);
}
```

**Contract:**
- `resolve()` returns an empty map for null, blank, or unresolvable refs
- Never returns null — empty map is the "not found" signal
- Never throws for missing credentials — consumers decide whether absence is an error
- Implementations must be thread-safe — `@ApplicationScoped` beans are shared across request threads
- Standard constants are conventions, not enforced — implementations may add custom keys
- Constants mirror Quarkus `CredentialsProvider` naming (`user`, `password`) so a future
  bridge implementation is a trivial passthrough

## @DefaultBean — `EnvironmentCredentialResolver`

**Package:** `io.casehub.platform.credentials`
**Module:** `platform/`

```java
@DefaultBean
@ApplicationScoped
public class EnvironmentCredentialResolver implements CredentialResolver {

    @Override
    public Map<String, String> resolve(String credentialRef) {
        if (credentialRef == null || credentialRef.isBlank()) return Map.of();
        String envKey = "CASEHUB_CREDENTIAL_"
                + credentialRef.toUpperCase().replace('-', '_').replace('.', '_');
        String value = System.getenv(envKey);
        if (value == null) return Map.of();
        return Map.of(BEARER_TOKEN, value);
    }
}
```

**Naming convention:** `credentialRef: "sf-bearer-token"` → env var `CASEHUB_CREDENTIAL_SF_BEARER_TOKEN`

**Behaviour:**
- Null/blank ref → empty map
- Missing env var → empty map
- Present env var → single-entry map with `BEARER_TOKEN` key
- Returns `BEARER_TOKEN` because single env var = single secret value, and bearer token
  is the most common endpoint credential type
- A no-op @DefaultBean is unnecessary — the env-var resolver already degrades gracefully
  to empty map when no env var is configured

## Consumer Usage Pattern

```java
@Inject CredentialResolver credentialResolver;
@Inject EndpointRegistry endpointRegistry;

void callEndpoint(Path path, String tenantId) {
    EndpointDescriptor desc = endpointRegistry.resolve(path, tenantId).orElseThrow();
    Map<String, String> creds = credentialResolver.resolve(desc.credentialRef());

    String bearer = creds.get(CredentialResolver.BEARER_TOKEN);
    if (bearer != null) {
        // apply Authorization: Bearer <token> header
    }
}
```

## Test Plan

**Unit tests for `EnvironmentCredentialResolver`:**
- Null credentialRef → empty map
- Blank credentialRef → empty map
- Valid ref with env var set → map with BEARER_TOKEN entry
- Valid ref with no env var → empty map
- Ref with hyphens and dots normalised correctly (e.g. `"sf.bearer-token"` → `CASEHUB_CREDENTIAL_SF_BEARER_TOKEN`)

No @QuarkusTest needed — the resolver uses `System.getenv()` and is testable via a
test subclass that overrides env var lookup.

## Out of Scope

- **Quarkus CredentialsProvider bridge module** — deferred, filed as separate issue.
  When needed, a `credentials-quarkus/` module provides `@Alternative @Priority(1)`
  that delegates to `io.quarkus.credentials.CredentialsProvider.getCredentials(credentialRef)`
- **Vault / AWS Secrets Manager / k8s Secret integration** — deferred. These become
  available automatically once the bridge module exists and those Quarkus extensions
  are on the classpath
- **Migration of Tier 1.5 usages** — qhorus slack-channel migration to Tier 2 is a
  separate issue after this ships
- **Wiring into EndpointRegistry** — pull model; the resolver is standalone. No changes
  to EndpointRegistry or EndpointDescriptor

## References

- [Quarkus CredentialsProvider guide](https://quarkus.io/guides/credentials-provider) — the pattern this SPI mirrors
- [Quarkus Config Secrets guide](https://quarkus.io/guides/config-secrets) — SmallRye SecretKeysHandler (config-level, different layer)
- `platform-api/.../endpoints/EndpointDescriptor.java` — `credentialRef` field (nullable String)
- `endpoints-config/.../EndpointConfigLoader.java` — parses and interpolates `credentialRef` from YAML
- Garden GE-20260519-b9719e — SmallRye Config Map<String,String> injection gotcha (relevant to config-backed implementations)
