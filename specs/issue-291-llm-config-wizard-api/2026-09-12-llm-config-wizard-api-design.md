# LLM Configuration Wizard API — Design Spec

**Issues:** casehubio/platform#291
**Date:** 2026-09-12
**Status:** Draft (R2 — revised post-review)

## Summary

Headless REST/GraphQL/MCP API for guided LLM provider configuration. An admin configures which LLM providers are available system-wide; users can add personal providers at user scope. The wizard validates credentials against the vendor's live API, persists the configuration, and auto-registers a `ModelSource` that feeds the `ModelRegistry`.

Three API surfaces (REST, GraphQL, MCP) are generated from a single `@McpDomain` SPI interface — no hand-written endpoints.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Clients (CLI, UI, MCP agent)                            │
├──────────────────┬───────────────────┬───────────────────┤
│  Generated REST  │  Generated GraphQL│  MCP (runtime)    │
│  @Path("/api/    │  @GraphQLApi      │  GraphQLModel     │
│   llm-config")   │                   │  Scanner          │
├──────────────────┴───────────────────┴───────────────────┤
│  LlmConfigApi (@McpDomain SPI interface)                 │
├──────────────────────────────────────────────────────────┤
│  LlmConfigService (@ApplicationScoped implementation)    │
│  ┌────────────┐  ┌──────────────┐  ┌──────────────────┐ │
│  │ Vendor     │  │ Preference   │  │ LlmCredential    │ │
│  │ Clients    │  │ Store        │  │ Store (new SPI)  │ │
│  │ (HTTP)     │  │ (config)     │  │ (secrets)        │ │
│  └────────────┘  └──────────────┘  └──────────────────┘ │
├──────────────────────────────────────────────────────────┤
│  ConfiguredModelSourceManager (@Startup + @Scheduled)    │
│  → reads PreferenceStore, creates ConfiguredModelSource  │
│  → registers with ModelRegistry via replaceSource()      │
│  → own @Scheduled refresh cycle for configured sources   │
└──────────────────────────────────────────────────────────┘
```

## Module: `llm-config/`

New top-level module. Dependencies:

| Dependency | Scope | Purpose |
|-----------|-------|---------|
| `casehub-platform-api` | compile | ModelRegistry, ModelSource, ModelDescriptor, PreferenceStore SPIs |
| `casehub-platform` | compile | InMemoryModelRegistry (for replaceSource()), see §MutableModelRegistry |
| `java.net.http` (JDK) | compile | HTTP client for vendor API validation |
| `jackson-databind` | compile | Parse vendor API responses |

No quarkus:build goal. No Flyway migrations.

### MutableModelRegistry — reducing coupling (R1-10)

`InMemoryModelRegistry.replaceSource()` is not on the `ModelRegistry` SPI. To avoid `llm-config` depending on the concrete implementation, add `MutableModelRegistry` as an extension interface in `platform-api`:

```java
public interface MutableModelRegistry extends ModelRegistry {
    CatalogDelta replaceSource(String sourceId, int priority, List<ModelDescriptor> models);
}
```

`InMemoryModelRegistry` implements `MutableModelRegistry`. `ConfiguredModelSourceManager` injects `MutableModelRegistry`. This keeps `llm-config` coupled to SPIs only, and `casehub-platform` becomes a test-only dependency.

## SPI Interface

```java
package io.casehub.platform.llm.config;

@McpDomain("llm-config")
public interface LlmConfigApi {

    @PlatformQuery("List available LLM vendors with their auth requirements")
    List<VendorInfo> vendors();

    @PlatformQuery("List currently configured providers for the caller's context")
    List<ProviderConfig> configured();

    @PlatformMutation("Validate credentials against a vendor's live API — returns discovered models on success")
    ValidationResult validate(ValidateRequest request);

    @PlatformMutation("Validate, persist, and register a provider configuration as a ModelSource")
    ConfigureResult configure(ConfigureRequest request);

    @PlatformMutation("Remove a provider configuration and deregister its ModelSource")
    void unconfigure(String providerId);
}
```

`configure()` re-validates internally before persisting (R1-14) — no separate validation step required, though `validate()` remains available for dry-run preview.

This generates:
- `GeneratedLlmConfigResolver` — `@GraphQLApi` with `@Query`/`@Mutation` methods
- `GeneratedLlmConfigResource` — `@Path("/api/llm-config")` with `@GET`/`@POST` methods
- MCP tools via `GraphQLModelScanner` runtime discovery

**Known limitation (R1-11):** `unconfigure()` generates `POST` not `DELETE` — the REST generator PoC maps all `@PlatformMutation` to `POST`. Tracked under #295 for the productionised generator.

## DTOs

### VendorInfo (R1-13 — derived from validators)

```java
public record VendorInfo(
    String vendorKey,          // "anthropic", "openai", "google", "ollama"
    String backendKey,         // "claude", "openai", "gemini", "ollama" (R1-08)
    String displayName,        // "Anthropic"
    String authMethod,         // "api-key", "vertex", "bedrock", "local"
    List<String> requiredFields // ["api-key"] or ["user", "password"] or []
) {}
```

`vendors()` derives `VendorInfo` from CDI-discovered `VendorClient` beans — not a static catalog. Adding a new vendor means implementing `VendorClient`; the vendor list updates automatically.

`backendKey` is exposed explicitly so callers see the mapping between vendor identity and execution backend (R1-08).

### ValidateRequest / ValidationResult (R1-07 — returns ModelDescriptor directly)

```java
public record ValidateRequest(
    String vendorKey,
    Map<String, String> credentials  // keyed by CredentialPropertyKeys
) {}

public record ValidationResult(
    boolean valid,
    String errorMessage,                // null on success
    List<ModelDescriptor> models        // full descriptors on success (R1-07)
) {}
```

Validators return `List<ModelDescriptor>` directly — no intermediate `DiscoveredModel` DTO. Each `VendorClient` knows its `backendKey`, `vendor`, `family`, and `locality`, so it constructs complete descriptors. Eliminates the lossy conversion.

### ConfigureRequest / ConfigureResult

```java
public record ConfigureRequest(
    String vendorKey,
    Map<String, String> credentials,   // actual credential values to persist
    String displayName                 // optional override for the provider name
) {}

public record ConfigureResult(
    String providerId,                 // generated unique ID
    int modelsRegistered,
    List<String> modelIds              // IDs now queryable via ModelRegistry
) {}
```

`credentialRef` is no longer caller-supplied — the wizard generates it internally from vendorKey + tenancyId + scope hash. This prevents callers from accidentally colliding with non-LLM credential refs.

### ProviderConfig (for `configured()` response)

```java
public record ProviderConfig(
    String providerId,
    String vendorKey,
    String backendKey,
    String displayName,
    int modelCount,
    Instant configuredAt
) {}
```

## Tenant Isolation (R1-01)

### Problem

`ModelRegistry` is a global flat map — `resolveById()` and `query()` have no tenant parameter. If Tenant A configures Anthropic, Tenant B can see and use those models. `RoutingAgentProvider` has no `CurrentPrincipal` injection and performs no tenant filtering.

### Solution: Tenant-prefixed model IDs + provider-level registry scoping

Configured model sources produce descriptors with tenant-scoped IDs:

```
Model ID format: {vendorId}:{tenancyId}:{apiModelId}
Example:         anthropic:tenant-42:claude-sonnet-5
```

Seed catalog models retain plain IDs (`claude-sonnet-5`) — they are available to all tenants.

**Query path (wizard API):** `LlmConfigService.configured()` queries `ModelRegistry` and filters results by matching the `tenancyId` segment in the source ID. Seed catalog models (no tenant segment) are included for all callers.

**Dispatch path (RoutingAgentProvider):** The wizard API returns tenant-scoped model IDs to callers. When a caller passes `model="anthropic:tenant-42:claude-sonnet-5"` to `AgentProvider.invoke()`, `RoutingAgentProvider.resolve()` finds the descriptor via `resolveById()` (exact match in the global registry). The descriptor's `backendKey` routes to the correct backend, and the descriptor's `id` field contains the API model ID for the backend (extracted from the tenant-scoped ID by `ConfiguredModelSource.toDescriptors()`).

**Security:** The tenant segment in the model ID is not an authorization mechanism — it's a partitioning scheme. A malicious caller who guesses another tenant's model ID could resolve it. For pre-release, this is acceptable: the model descriptor itself doesn't contain secrets (the credential ref is resolved at runtime by the source manager, not embedded in the descriptor). The actual credential resolution is tenant-isolated by the source's internal state.

**Post-release hardening:** Add tenant-aware query overloads to `ModelRegistry` SPI that filter by tenant context. File as a follow-up when the platform gains a tenant-aware request context framework.

## Credential Storage (R1-02 — credentials NOT in PreferenceStore)

### Problem

`PreferenceStore` values are readable via `PreferenceResource.list()` — no namespace-level access control. Storing API keys there exposes them to any authenticated user.

### Solution: Dedicated LlmCredentialStore SPI

```java
package io.casehub.platform.llm.config;

public interface LlmCredentialStore {
    void store(String tenancyId, String credentialRef, Map<String, String> credentials);
    Map<String, String> resolve(String tenancyId, String credentialRef);
    void delete(String tenancyId, String credentialRef);
    List<String> listRefs(String tenancyId);
}
```

**Key design points:**
- Tenant-explicit methods — no `CurrentPrincipal` dependency (R1-05). Works at `@Startup` and `@Scheduled`.
- Not exposed via `PreferenceResource` — credentials are never in the preference namespace.
- Separate from `CredentialResolver` — `CredentialResolver` is for outbound endpoint credentials. LLM credentials are a distinct concern with different lifecycle (user-managed, validated, revocable).

**Pre-release implementation:** `InMemoryLlmCredentialStore` (`@ApplicationScoped`, `ConcurrentHashMap`, lost on restart). Persistence added when needed (file-backed, JPA, or Vault integration).

**For restart durability (pre-release):** `PreferenceStore` stores a `llm.credentials.{ref}.exists=true` marker (no secret values). On startup, if the marker exists but the in-memory store is empty, the wizard reports the provider as "credentials expired — reconfigure." This is acceptable for pre-release: credentials are re-entered after restart. Production deployments use Vault-backed storage.

### CredentialResolver integration (R1-04 — decorator, not alternative)

The `LlmCredentialStore` is internal to `llm-config`. It does NOT replace or decorate `CredentialResolver`. The two are independent:

- `CredentialResolver` — platform SPI for outbound endpoint credentials (unchanged)
- `LlmCredentialStore` — module-internal SPI for LLM API keys (new)

`ConfiguredModelSource` resolves credentials via `LlmCredentialStore.resolve(tenancyId, credentialRef)` directly. No CDI priority conflicts, no circular injection, no decorator.

## ConfiguredModelSourceManager (R1-03, R1-05, R1-06)

```java
@ApplicationScoped
public class ConfiguredModelSourceManager {

    @Inject PreferenceStore preferenceStore;
    @Inject MutableModelRegistry registry;
    @Inject LlmCredentialStore credentialStore;
    @Inject Event<ModelCatalogChangedEvent> catalogChanged;

    private final ConcurrentHashMap<String, ConfiguredModelSource> activeSources
        = new ConcurrentHashMap<>();
}
```

No `CurrentPrincipal` injection — tenant ID is passed explicitly to all methods (R1-05).

### @Startup — reconstruct from PreferenceStore (R1-06)

The startup problem: `PreferenceQuery` requires `tenancyId`, and there's no SPI to enumerate tenants.

**Solution:** Store a global provider index in PreferenceStore under a well-known tenant-independent key. The wizard maintains a `llm.provider-index` preference at the system scope that lists all `(tenancyId, vendorKey)` tuples:

```java
// On configure:
preferenceStore.set(SYSTEM_TENANT, Path.root(), "llm", "provider-index",
    tenancyId + ":" + vendorKey, "true");

// On startup:
List<PreferenceRecord> index = preferenceStore.list(
    new PreferenceQuery(SYSTEM_TENANT, Path.root(), "llm"));
// Parse subKey as "tenancyId:vendorKey", reconstruct each source
```

`SYSTEM_TENANT` is a well-known tenant ID (e.g., `"__system__"`) used for cross-tenant indexes. This follows the pattern of `PlatformPreferenceRegistrar` which registers system-wide preference schemas at startup.

### @Scheduled — refresh configured sources (R1-03)

`ModelRegistryRefresher` only refreshes CDI-managed `ModelSource` beans. Dynamically created `ConfiguredModelSource` instances are invisible to it.

**Solution:** `ConfiguredModelSourceManager` runs its own `@Scheduled` refresh cycle:

```java
@Scheduled(every = "${casehub.llm.config.refresh-interval:1h}")
void refreshConfiguredSources() {
    for (var entry : activeSources.entrySet()) {
        try {
            ConfiguredModelSource source = entry.getValue();
            List<ModelDescriptor> models = source.refresh();
            var delta = registry.replaceSource(source.sourceId(), source.priority(), models);
            if (delta.hasChanges()) {
                catalogChanged.fire(new ModelCatalogChangedEvent(
                    source.sourceId(), delta.addedIds(), delta.removedIds(), delta.updatedIds()));
            }
        } catch (Exception e) {
            LOG.warnf("Configured source '%s' refresh failed: %s", entry.getKey(), e.getMessage());
        }
    }
}
```

Error-isolated per source. Follows the same pattern as `ModelRegistryRefresher` but for dynamically-managed sources. Default refresh interval: 1 hour (configurable).

**Rate limiting consideration:** Each configured source's `refresh()` makes a live HTTP call to the vendor API. With N tenants × M vendors, the refresh cycle makes N×M API calls per interval. For pre-release scale (single-digit tenants), this is acceptable. At scale, implement staggered refresh (jitter) and configurable per-vendor rate limits.

### ConfiguredModelSource (revised)

```java
class ConfiguredModelSource implements ModelSource {
    private final String sourceId;      // "configured:{vendorKey}:{tenancyId}"
    private final String tenancyId;     // explicit — no CurrentPrincipal needed (R1-05)
    private final String vendorKey;
    private final String credentialRef;
    private final VendorClient client;
    private volatile List<ModelDescriptor> lastKnownModels;

    @Override public String sourceId() { return sourceId; }
    @Override public int priority() { return 10; }

    @Override
    public List<ModelDescriptor> refresh() {
        Map<String, String> creds = credentialStore.resolve(tenancyId, credentialRef);
        if (creds.isEmpty()) {
            LOG.warnf("Credentials missing for %s — returning last known models", sourceId);
            return lastKnownModels != null ? lastKnownModels : List.of();
        }
        var result = client.listModels(creds);
        if (result.valid()) {
            lastKnownModels = result.models();
            return lastKnownModels;
        }
        return lastKnownModels != null ? lastKnownModels : List.of();
    }
}
```

Tenant ID is stored at construction time, not resolved from request context.

## Vendor Clients (R1-12 — shared abstraction for #288)

Renamed from `VendorValidator` to `VendorClient` — the same class serves both validation (wizard) and periodic refresh (ModelSource). This is the shared abstraction that #288 (cloud model sources) will also use.

```java
public interface VendorClient {
    String vendorKey();
    String backendKey();      // "claude", "openai", "gemini", "ollama" (R1-08)
    String displayName();
    String authMethod();
    List<String> requiredFields();
    ValidationResult listModels(Map<String, String> credentials);
}
```

`listModels()` replaces `validate()` — validation IS listing models. If the call succeeds and returns models, the credentials are valid. If it fails, the error message explains why.

Implementations:
- `AnthropicClient` — `GET https://api.anthropic.com/v1/models`, backendKey=`"claude"`
- `OpenAiClient` — `GET https://api.openai.com/v1/models`, backendKey=`"openai"`
- `GoogleClient` — Gemini models endpoint, backendKey=`"gemini"`
- `OllamaClient` — `GET http://{host}/api/tags`, backendKey=`"ollama"`

CDI-discovered via `@Any Instance<VendorClient>`. `vendors()` derives the list dynamically from discovered clients (R1-13).

**No Mistral backend (R1-08):** `MistralClient` is not included in this branch — no `MistralAgentBackend` exists in the platform. Added when a Mistral backend module is created.

## Scope Model — Tenant + User (simplified)

Provider configurations are scoped via PreferenceStore:

| Scope | Who writes | What's stored |
|-------|-----------|---------------|
| Tenant root (`/`) | Admin (`@RolesAllowed(ADMIN)`) | Provider config metadata |
| User scope (`/users/{actorId}`) | The user themselves | Provider config metadata |

Credentials are scoped by `(tenancyId, credentialRef)` in `LlmCredentialStore` — separate from PreferenceStore.

The `ConfiguredModelSourceManager` creates separate `ConfiguredModelSource` instances per `(vendorKey, tenancyId)` tuple. Model IDs are tenant-prefixed for isolation (see §Tenant Isolation).

## PreferenceStore Namespace (revised — no credentials)

Provider config only — no secrets:

| Key pattern | Value | Example |
|-------------|-------|---------|
| `llm.provider.{vendorKey}.enabled` | `"true"` | `llm.provider.anthropic.enabled=true` |
| `llm.provider.{vendorKey}.credential-ref` | logical name | `llm.provider.anthropic.credential-ref=anthropic-tenant42` |
| `llm.provider.{vendorKey}.display-name` | optional override | `llm.provider.anthropic.display-name=Production` |
| `llm.provider.{vendorKey}.configured-at` | ISO-8601 | `llm.provider.anthropic.configured-at=2026-09-12T10:00:00Z` |

Provider index (system scope, for startup enumeration):

| Key pattern | Value | Example |
|-------------|-------|---------|
| `llm.provider-index.{tenancyId}:{vendorKey}` | `"true"` | `llm.provider-index.tenant-42:anthropic=true` |

## Known Limitations

1. **Multi-instance (#290):** One provider configuration per vendor per tenant. A user who wants "Claude via API key" AND "Claude via Vertex" cannot configure both. Filed as #290 dependency; this branch implements single-instance only (R1-09).
2. **REST DELETE verb:** `unconfigure()` generates `POST` not `DELETE`. Tracked under #295 (R1-11).
3. **Tenant isolation is partitioning, not authorization:** Tenant-prefixed model IDs prevent accidental cross-tenant use but don't enforce it cryptographically. Post-release: add tenant-aware query overloads to `ModelRegistry` SPI (R1-01).
4. **Credentials lost on restart (pre-release):** `InMemoryLlmCredentialStore` is volatile. Providers show as "credentials expired" after restart and require reconfiguration. Production: Vault-backed store.

## Test Strategy

1. `LlmConfigApi` — SPI contract: `vendors()` returns CDI-derived catalog, `configure`/`unconfigure` lifecycle
2. `LlmConfigService` — tenant isolation: admin configures at tenant scope, user at user scope, cross-tenant blocked
3. `LlmConfigService.configure()` — re-validates internally before persisting (R1-14)
4. `VendorClient` — per-vendor: mock HTTP responses, verify `ModelDescriptor` construction (backendKey, vendor, family, locality, tier, capabilities)
5. `ConfiguredModelSourceManager` — startup: provider index → reconstruct sources; runtime: configure/unconfigure lifecycle
6. `ConfiguredModelSourceManager` — `@Scheduled` refresh: refreshes all active sources, error-isolated per source
7. `ConfiguredModelSource.refresh()` — success returns fresh models, failure returns last known good, missing credentials returns last known good with warning
8. `LlmCredentialStore` — tenant-isolated store/resolve/delete, `listRefs` per tenant
9. Tenant isolation — tenant-prefixed model IDs: Tenant A's models not returned by Tenant B's `configured()` query
10. Integration — full flow: validate → configure → `ModelRegistry.resolveById()` finds tenant-scoped model → unconfigure → model gone
11. `MutableModelRegistry` — `replaceSource()` on SPI extension, `CatalogDelta` computation

## Files Changed

### platform-api (SPI extension)

| File | Action |
|------|--------|
| `platform-api/.../model/MutableModelRegistry.java` | New — extends ModelRegistry with replaceSource() |

### New module: `llm-config/`

| File | Action |
|------|--------|
| `llm-config/pom.xml` | New |
| `llm-config/src/main/java/.../LlmConfigApi.java` | New — @McpDomain SPI |
| `llm-config/src/main/java/.../LlmConfigService.java` | New — @ApplicationScoped impl |
| `llm-config/src/main/java/.../VendorInfo.java` | New — DTO |
| `llm-config/src/main/java/.../ValidateRequest.java` | New — DTO |
| `llm-config/src/main/java/.../ValidationResult.java` | New — DTO |
| `llm-config/src/main/java/.../ConfigureRequest.java` | New — DTO |
| `llm-config/src/main/java/.../ConfigureResult.java` | New — DTO |
| `llm-config/src/main/java/.../ProviderConfig.java` | New — DTO |
| `llm-config/src/main/java/.../VendorClient.java` | New — SPI (shared with #288) |
| `llm-config/src/main/java/.../AnthropicClient.java` | New |
| `llm-config/src/main/java/.../OpenAiClient.java` | New |
| `llm-config/src/main/java/.../GoogleClient.java` | New |
| `llm-config/src/main/java/.../OllamaClient.java` | New |
| `llm-config/src/main/java/.../LlmCredentialStore.java` | New — SPI |
| `llm-config/src/main/java/.../InMemoryLlmCredentialStore.java` | New — volatile impl |
| `llm-config/src/main/java/.../ConfiguredModelSourceManager.java` | New — @Startup + @Scheduled |
| `llm-config/src/main/java/.../ConfiguredModelSource.java` | New — ModelSource impl |
| `llm-config/src/test/java/.../LlmConfigServiceTest.java` | New |
| `llm-config/src/test/java/.../ConfiguredModelSourceManagerTest.java` | New |
| `llm-config/src/test/java/.../AnthropicClientTest.java` | New |

### Modified

| File | Action |
|------|--------|
| `pom.xml` (root) | Modified — add `llm-config` to modules list |
| `platform/...InMemoryModelRegistry.java` | Modified — implements MutableModelRegistry |
| `graphql-generator/` | Modified — REST generation PoC (already committed) |

## Downstream (not this branch)

| Issue | Repo | Dependency |
|-------|------|------------|
| #288 | platform | Cloud model sources — uses VendorClient abstraction from this branch |
| #290 | platform | Multi-instance backend — extends wizard to support N configs per vendor |
| #295 | platform | Unified API generation — productionise REST generator PoC |

## Review History

- **R1 (light):** 14 findings (7 HIGH, 5 MEDIUM, 2 LOW). All HIGH addressed in R2.
- **R2 (revision):** Spec rewritten. Key changes: dedicated LlmCredentialStore (R1-02/04/05), tenant-prefixed model IDs (R1-01), own @Scheduled refresh (R1-03), provider index for startup enumeration (R1-06), validators return ModelDescriptor directly (R1-07), MutableModelRegistry SPI extension (R1-10), VendorClient shared abstraction (R1-12/13), configure re-validates (R1-14).

## References

- `io.casehub.platform.api.model.ModelRegistry` — consumer SPI for model catalog queries
- `io.casehub.platform.api.model.ModelSource` — pull-based model catalog source SPI
- `io.casehub.platform.api.model.ModelDescriptor` — normalized model metadata record
- `io.casehub.platform.model.InMemoryModelRegistry` — implementation with replaceSource() and CatalogDelta
- `io.casehub.platform.model.ModelRegistryRefresher` — @Startup + @Scheduled refresh
- `io.casehub.platform.api.credentials.CredentialResolver` — outbound credential resolution SPI (unchanged)
- `io.casehub.platform.api.credentials.CredentialPropertyKeys` — API_KEY, BEARER_TOKEN constants
- `io.casehub.platform.api.preferences.PreferenceStore` — scope-aware config persistence SPI
- `io.casehub.platform.graphql.generator.GraphQLResolverProcessor` — APT for GraphQL + REST generation
- `io.casehub.platform.api.mcp.McpDomain` — domain annotation for MCP + generation
- casehubio/platform#285 — parent epic (LLM model registry)
- casehubio/platform#286 — ModelRegistry SPI (dependency, landed)
- casehubio/platform#290 — multi-instance backend (known limitation)
- casehubio/platform#295 — unified API generation epic
- Anthropic `/v1/models` API — vendor validation target
- OpenAI `/v1/models` API — vendor validation target
- Light review findings: `/Users/mdproctor/reviews/casehub-platform/issue-291-llm-config-wizard-20260912-105717/`
