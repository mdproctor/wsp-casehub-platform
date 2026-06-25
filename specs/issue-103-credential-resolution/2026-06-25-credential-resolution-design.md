# Tier 2 Credential Resolution — Design Spec

**Issue:** casehubio/platform#103
**Date:** 2026-06-25
**Status:** Approved (revised after review)

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
| Constants | Separate `CredentialPropertyKeys` class | Follows platform pattern: `EndpointPropertyKeys`, `MemoryAttributeKeys` — `final class`, `private constructor`, vocabulary for `Map<String, String>` return types |
| Integration | Pull model | Consumers inject resolver and call explicitly. No coupling to EndpointRegistry. No unnecessary secret fetches on discovery queries |
| @DefaultBean | MicroProfile Config resolver | Uses `Config.getOptionalValue()` — resolves from env vars, system properties, AND `application.properties` with `%test.`/`%dev.` profile support. Follows the configurable mock @DefaultBean pattern established by `MockCurrentPrincipal` |

## SPI — `CredentialResolver`

**Package:** `io.casehub.platform.api.credentials`
**Module:** `platform-api` (zero dependencies)

```java
/**
 * Resolves outbound endpoint credentials by logical reference name.
 *
 * <p>This is for outbound credential resolution (endpoint secrets, API tokens,
 * service passwords) — not to be confused with inbound Verifiable Credential
 * validation in {@code io.casehub.platform.api.identity}.
 *
 * <p>Implementations must be thread-safe — {@code @ApplicationScoped} beans
 * are shared across request threads.
 */
public interface CredentialResolver {

    /**
     * Resolve the credential properties for the given logical reference.
     *
     * @param credentialRef the logical credential name
     *        (from {@link io.casehub.platform.api.endpoints.EndpointDescriptor#credentialRef()})
     * @return credential properties keyed by {@link CredentialPropertyKeys} constants,
     *         or empty map if unresolvable
     */
    Map<String, String> resolve(String credentialRef);
}
```

**Contract:**
- `resolve()` returns an empty map for null, blank, or unresolvable refs
- Never returns null — empty map is the "not found" signal
- Never throws for missing credentials — consumers decide whether absence is an error
- Implementations must be thread-safe — `@ApplicationScoped` beans are shared across request threads

## `CredentialPropertyKeys`

**Package:** `io.casehub.platform.api.credentials`
**Module:** `platform-api` (zero dependencies)

```java
/**
 * Reserved property keys for credential maps returned by {@link CredentialResolver#resolve}.
 *
 * <p>Standard keys use <b>kebab-case</b>. Values mirror Quarkus
 * {@code io.quarkus.credentials.CredentialsProvider} naming for bridge compatibility.
 *
 * <p>These keys are conventions, not enforced constraints. Implementations may
 * return additional custom keys. Consumers should use the constants for standard
 * credential extraction.
 */
public final class CredentialPropertyKeys {

    /** Username for basic auth, SASL, or compound credentials. */
    public static final String USER = "user";

    /** Password for basic auth, SASL, or compound credentials. */
    public static final String PASSWORD = "password";

    /** OAuth/JWT bearer token — the most common HTTP endpoint credential type. */
    public static final String BEARER_TOKEN = "bearer-token";

    /** API key for header-based authentication (e.g. X-Api-Key). */
    public static final String API_KEY = "api-key";

    /** ISO-8601 expiration timestamp for time-limited credentials. */
    public static final String EXPIRES_AT = "expires-at";

    private CredentialPropertyKeys() {}
}
```

## @DefaultBean — `DefaultCredentialResolver`

**Package:** `io.casehub.platform.credentials`
**Module:** `platform/`

Uses MicroProfile Config with prefix `casehub.credentials.` — resolves from env vars,
system properties, and `application.properties` via SmallRye's standard config source
chain. No custom env var naming convention — SmallRye's automatic mapping handles it.

### Two resolution modes

**Compound credentials** — checked first. Sub-keys under `casehub.credentials.<ref>.*`:

```properties
# application.properties or env vars
casehub.credentials.db-primary.user=admin
casehub.credentials.db-primary.password=secret
casehub.credentials.db-primary.expires-at=2026-07-01T00:00:00Z
```

Resolver checks for each `CredentialPropertyKeys` constant as a sub-key. If **any**
sub-key is found, returns the compound map. The bare key is **not** consulted — compound
or simple, never both.

**Simple credentials** — fallback when no sub-keys match:

```properties
# Single token value
casehub.credentials.sf-bearer-token=xoxb-real-token-value
```

Returns `Map.of(CredentialPropertyKeys.BEARER_TOKEN, value)`. The `BEARER_TOKEN` key
is the default because `EndpointDescriptor.credentialRef` exists primarily for HTTP
endpoints, where bearer tokens are the dominant credential type. Compound credentials
(user+password, client_id+client_secret) use explicit sub-keys.

### SmallRye env var mapping (automatic)

| Config property | Env var (SmallRye auto-maps) |
|-|-|
| `casehub.credentials.sf-bearer-token` | `CASEHUB_CREDENTIALS_SF_BEARER_TOKEN` |
| `casehub.credentials.db-primary.user` | `CASEHUB_CREDENTIALS_DB_PRIMARY_USER` |
| `casehub.credentials.db-primary.password` | `CASEHUB_CREDENTIALS_DB_PRIMARY_PASSWORD` |

### Dev/test usage

```properties
# application.properties — works for dev and test profiles
%test.casehub.credentials.sf-bearer-token=test-token-123
%dev.casehub.credentials.sf-bearer-token=dev-token-456
```

### Implementation sketch

```java
@DefaultBean
@ApplicationScoped
public class DefaultCredentialResolver implements CredentialResolver {

    private final Config config;

    @Inject
    DefaultCredentialResolver(Config config) {
        this.config = config;
    }

    @Override
    public Map<String, String> resolve(String credentialRef) {
        if (credentialRef == null || credentialRef.isBlank()) return Map.of();
        String prefix = "casehub.credentials." + credentialRef;

        // Compound: check sub-keys first
        Map<String, String> compound = new LinkedHashMap<>();
        checkSubKey(prefix, CredentialPropertyKeys.USER, compound);
        checkSubKey(prefix, CredentialPropertyKeys.PASSWORD, compound);
        checkSubKey(prefix, CredentialPropertyKeys.BEARER_TOKEN, compound);
        checkSubKey(prefix, CredentialPropertyKeys.API_KEY, compound);
        checkSubKey(prefix, CredentialPropertyKeys.EXPIRES_AT, compound);
        if (!compound.isEmpty()) return Map.copyOf(compound);

        // Simple: bare key → BEARER_TOKEN
        return config.getOptionalValue(prefix, String.class)
                .map(v -> Map.of(CredentialPropertyKeys.BEARER_TOKEN, v))
                .orElse(Map.of());
    }

    private void checkSubKey(String prefix, String key, Map<String, String> target) {
        config.getOptionalValue(prefix + "." + key, String.class)
                .ifPresent(v -> target.put(key, v));
    }
}
```

### No separate NoOp @DefaultBean needed

The Config-based resolver degrades gracefully: no config keys → empty map. A separate
no-op that always returns empty is indistinguishable.

## Consumer Usage Pattern

```java
@Inject CredentialResolver credentialResolver;
@Inject EndpointRegistry endpointRegistry;

void callEndpoint(Path path, String tenantId) {
    EndpointDescriptor desc = endpointRegistry.resolve(path, tenantId).orElseThrow();
    Map<String, String> creds = credentialResolver.resolve(desc.credentialRef());

    String bearer = creds.get(CredentialPropertyKeys.BEARER_TOKEN);
    if (bearer != null) {
        // apply Authorization: Bearer <token> header
    }
}
```

## Test Plan

**Unit tests for `DefaultCredentialResolver`:**
- Null credentialRef → empty map
- Blank credentialRef → empty map
- Simple: single config key set → map with BEARER_TOKEN entry
- Simple: config key absent → empty map
- Compound: user + password sub-keys set → map with both entries
- Compound: partial sub-keys (only user) → map with only USER entry
- Compound + bare key both set → compound wins, bare key ignored
- Ref with hyphens and dots normalised correctly via SmallRye mapping

Tests inject `Config` via constructor — no subclassing needed. Use
`SmallRyeConfigBuilder` to construct Config with programmatic properties for isolation.

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
- **Async variant** — the SPI is sync-only. `Config.getOptionalValue()` is non-blocking.
  The future bridge module will need to address async for Vault calls
  (Quarkus CredentialsProvider has no async variant either; this is a known gap)
- **Batch resolution** — `resolveAll(Set<String>)` is a predictable evolution point
  when Vault-backed implementations face N round-trips for N endpoints. The SPI can
  add a default method later without breaking existing implementations

## CLAUDE.md Updates

After implementation, add to the modules table:

```
No new module — SPI in platform-api, @DefaultBean in platform/
```

Update package structure:

```
io.casehub.platform.api
  .credentials   — CredentialResolver (SPI: resolve(credentialRef) → Map<String, String>),
                   CredentialPropertyKeys (reserved keys: USER, PASSWORD, BEARER_TOKEN, API_KEY, EXPIRES_AT)
```

## References

- [Quarkus CredentialsProvider guide](https://quarkus.io/guides/credentials-provider) — the pattern this SPI mirrors
- [Quarkus Config Secrets guide](https://quarkus.io/guides/config-secrets) — SmallRye SecretKeysHandler (config-level, different layer)
- `platform-api/.../endpoints/EndpointDescriptor.java` — `credentialRef` field (nullable String)
- `platform-api/.../endpoints/EndpointPropertyKeys.java` — established keys-class pattern
- `platform-api/.../memory/MemoryAttributeKeys.java` — established keys-class pattern
- `platform/.../mock/MockCurrentPrincipal.java` — established @DefaultBean configurable mock pattern
- `endpoints-config/.../EndpointConfigLoader.java` — parses and interpolates `credentialRef` from YAML
- Garden GE-20260519-b9719e — SmallRye Config Map injection gotcha (avoided by using `getOptionalValue()`)
