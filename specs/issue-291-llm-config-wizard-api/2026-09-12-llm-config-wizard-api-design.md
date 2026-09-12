# LLM Configuration Wizard API — Design Spec

**Issues:** casehubio/platform#291
**Date:** 2026-09-12
**Status:** Draft (R2 — revised post-review)

## Summary

Headless REST/GraphQL/MCP API for guided LLM provider configuration. An admin configures which LLM providers are available at tenant scope. The wizard validates credentials against the vendor's live API, persists the configuration, and auto-registers a `ModelSource` that feeds the `ModelRegistry`.

User-scope personal providers are deferred to a follow-up (see §Downstream) — the source lifecycle, model ID format, and refresh scaling require separate design work (R2-01, R2-02).

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
| `casehub-platform-api` | compile | MutableModelRegistry, ModelSource, ModelDescriptor, PreferenceStore, LlmCredentialStore SPIs |
| `casehub-platform` | test | InMemoryModelRegistry for integration tests |
| `graphql-generator` | provided | APT: `GraphQLResolverProcessor` generates REST/GraphQL endpoints from `@McpDomain` |
| `java.net.http` (JDK) | compile | HTTP client for vendor API validation |
| `jackson-databind` | compile | Parse vendor API responses |

**Note:** `graphql-generator` requires `<annotationProcessorPaths>` configuration in `llm-config/pom.xml` for the Maven compiler plugin.

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

Validators return `List<ModelDescriptor>` directly — no intermediate `DiscoveredModel` DTO. Each `VendorClient` constructs descriptors with metadata merged from the seed catalog (see §Metadata Resolution Strategy). The `apiModelId` field carries the vendor-facing identifier; the `id` field carries the tenant-scoped registry key (see §ModelDescriptor Extension).

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

`credentialRef` is no longer caller-supplied — the wizard generates it internally from `{vendorKey}-{tenancyId}` (see §Credential Ref Generation). This prevents callers from accidentally colliding with non-LLM credential refs.

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

## ModelDescriptor Extension: `apiModelId` (R1-01)

The `ModelDescriptor` record needs a new field to separate the registry lookup key from the vendor-facing model identifier. Without this, tenant-scoped IDs (used as registry keys) would be passed to vendor APIs, which would reject them.

```java
public record ModelDescriptor(
    String id,              // registry key: "claude-sonnet-5" (seed) or "anthropic:tenant-42:claude-sonnet-5" (configured)
    String apiModelId,      // vendor API identifier: always "claude-sonnet-5" — what the backend sends to the vendor
    // ... remaining fields unchanged
) {
    public ModelDescriptor {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(apiModelId, "apiModelId");
        // ... rest unchanged
    }
}
```

For seed catalog models, `apiModelId == id`. For tenant-scoped configured models, `apiModelId` is the vendor-facing identifier while `id` is the tenant-scoped registry key.

`RoutingAgentProvider.resolve()` uses `descriptor.get().apiModelId()` (not `descriptor.get().id()`) when constructing the rewritten `AgentSessionConfig`. This preserves the D1 contract from the model registry spec: "backends always receive either a specific API model identifier or null."

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

**Dispatch path (RoutingAgentProvider):** The wizard API returns tenant-scoped model IDs to callers. When a caller passes `model="anthropic:tenant-42:claude-sonnet-5"` to `AgentProvider.invoke()`, `RoutingAgentProvider.resolve()` finds the descriptor via `resolveById()` (exact match in the global registry). The descriptor's `backendKey` routes to the correct backend. The descriptor's `apiModelId` field (e.g., `"claude-sonnet-5"`) is used in the rewritten `AgentSessionConfig` — NOT the `id` field (which is the tenant-scoped registry key). This maintains the RoutingAgentProvider's D1 contract: backends receive vendor-facing model identifiers.

### Deduplication Strategy (R1-07)

When a tenant configures Anthropic, the registry contains both seed catalog models (plain IDs like `claude-sonnet-5`) and tenant-configured models (tenant-scoped IDs like `anthropic:tenant-42:claude-sonnet-5`). These are distinct registry entries for the same underlying vendor model.

**`configured()` response:** Returns both types, distinguished by ID format:
- Tenant-scoped models: the tenant's own configuration, invoked using the tenant's credentials (when credential dispatch lands — see §Known Limitations)
- Seed catalog models: platform-wide defaults, invoked using platform-level credentials

**Caller precedence:** Callers should prefer tenant-scoped model IDs when available — these represent the tenant's explicit configuration. The `configured()` response groups models by `apiModelId`, with each group showing available scopes (tenant-configured vs. seed catalog). The UI/agent can present the tenant-configured variant as the primary option.

**No silent shadowing:** Configured models do NOT suppress seed catalog entries. Both are queryable simultaneously. This is intentional — a tenant may want to compare their configuration against platform defaults, and removing seed catalog entries would break callers that reference plain model IDs.

**Security:** The tenant segment in the model ID is not an authorization mechanism — it's a partitioning scheme. A malicious caller who guesses another tenant's model ID could resolve it. For pre-release, this is acceptable: the model descriptor itself doesn't contain secrets (the credential ref is resolved at runtime by the source manager, not embedded in the descriptor). The actual credential resolution is tenant-isolated by the source's internal state.

**Post-release hardening:** Add tenant-aware query overloads to `ModelRegistry` SPI that filter by tenant context. File as a follow-up when the platform gains a tenant-aware request context framework.

## Credential Storage (R1-02, R1-11 — credentials NOT in PreferenceStore)

### Problem

`PreferenceStore` values are readable via `PreferenceResource.list()` — no namespace-level access control. Storing API keys there exposes them to any authenticated user.

### Solution: Dedicated LlmCredentialStore SPI in `platform-api`

```java
package io.casehub.platform.api.credentials;

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
- **SPI in `platform-api`** (R1-11) — follows the standard platform pattern for replaceable implementations. The Vault-backed production implementation can live in a separate module (e.g., `llm-credentials-vault/`) without coupling secrets infrastructure to `llm-config`. This avoids a future SPI promotion migration.

**`@DefaultBean` no-op (R2-03):** `NoOpLlmCredentialStore` (`@DefaultBean @ApplicationScoped`) in `platform/` — returns empty maps, no-op store/delete. Follows the universal platform pattern (48 `@DefaultBean` implementations in `platform/`). Prevents `UnsatisfiedResolutionException` when `llm-config` is not on the classpath.

**Pre-release implementation:** `InMemoryLlmCredentialStore` in `llm-config` (`@ApplicationScoped`, `ConcurrentHashMap`, lost on restart). Displaces the `@DefaultBean` no-op via standard CDI priority. Persistence added when needed (file-backed, JPA, or Vault integration in a separate module).

**For restart durability (pre-release):** `PreferenceStore` stores a `llm.credentials.{ref}.exists=true` marker (no secret values). On startup, if the marker exists but the in-memory store is empty, the wizard reports the provider as "credentials expired — reconfigure." This is acceptable for pre-release: credentials are re-entered after restart. Production deployments use Vault-backed storage.

### Credential Ref Generation (R1-06)

The `credentialRef` is generated internally — never caller-supplied. Formula:

```
{vendorKey}-{tenancyId}
Example: anthropic-tenant-42
```

One credential ref per `(vendorKey, tenancyId)` pair. When user-scope lands, the formula extends to `{vendorKey}-{tenancyId}-{actorId}` to guarantee per-user isolation.

### CredentialResolver integration (R1-04 — decorator, not alternative)

The `LlmCredentialStore` does NOT replace or decorate `CredentialResolver`. The two are independent:

- `CredentialResolver` — platform SPI for outbound endpoint credentials (unchanged)
- `LlmCredentialStore` — platform SPI for LLM API keys (new, in `platform-api`)

`ConfiguredModelSource` resolves credentials via `LlmCredentialStore.resolve(tenancyId, credentialRef)` directly. No CDI priority conflicts, no circular injection, no decorator.

### Credential Scope: Discovery vs. Invocation (R1-02)

**Per-tenant credentials are used for model discovery and periodic refresh only.** The actual model invocation path — `RoutingAgentProvider.resolve()` → `AgentBackend.invoke()` — uses platform-level backend credentials (e.g., `OpenAiAgentProperties.apiKey()`, environment variables for Claude CLI).

This is an intentional scope boundary for this branch:
- The wizard validates tenant credentials, discovers models, and registers them in the catalog
- When a tenant invokes one of those models, the platform's own backend credentials are used
- Per-tenant credential dispatch for model invocation requires extending the `AgentBackend` SPI with a credential-aware invoke path — tracked as a follow-up (see §Downstream)

This means a tenant who configures their Anthropic API key via the wizard benefits from custom model discovery (seeing exactly which models their key has access to) but invocations still use the platform's API key. The spec is explicit about this boundary to avoid misleading implementors or callers.

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

### @Startup — reconstruct from PreferenceStore (R1-04, R1-06)

The startup problem: `PreferenceQuery` requires `tenancyId`, and there's no SPI to enumerate tenants.

**Solution:** Store a global provider index in PreferenceStore under `TenancyConstants.PLATFORM_TENANT_ID`. The wizard maintains a `llm.provider-index` preference at the platform tenant scope that lists all `(tenancyId, vendorKey)` tuples:

```java
// On configure:
preferenceStore.set(TenancyConstants.PLATFORM_TENANT_ID, Path.root(), "llm", "provider-index",
    tenancyId + ":" + vendorKey, "true");

// On startup:
List<PreferenceRecord> index = preferenceStore.list(
    new PreferenceQuery(TenancyConstants.PLATFORM_TENANT_ID, Path.root(), "llm"));
// Parse subKey as "tenancyId:vendorKey", reconstruct each source
```

Uses `TenancyConstants.PLATFORM_TENANT_ID` (`"platform"`) — the existing platform constant for cross-tenant data owned by the platform. This follows the established pattern: `EndpointDescriptor`, `DataSourceDescriptor`, `NotificationRetentionScheduler`, and `SubscriptionEngine` all use `PLATFORM_TENANT_ID` for platform-global operations. No new sentinel needed.

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

            // R1-03: Guard against race with concurrent unconfigure().
            // ConcurrentHashMap iteration is weakly consistent — the iterator may
            // reference a source that was concurrently removed by unconfigure().
            // If the source is no longer in activeSources after refresh, skip the
            // registry update. If we miss this check, the registry would contain
            // phantom models from a source that no longer exists in activeSources.
            if (!activeSources.containsKey(entry.getKey())) {
                continue;
            }

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

**Race condition mitigation (R1-03):** The `containsKey` check after `refresh()` prevents the race where `unconfigure()` removes a source from `activeSources` while a concurrent refresh iteration still holds a reference to it. Without this guard, `replaceSource()` would re-add the unconfigured source's models to the registry — phantom entries with no backing source that would never be refreshed again or cleaned up. A narrow TOCTOU window remains (unconfigure between the check and `replaceSource`), but `unconfigure()` also calls `registry.replaceSource(sourceId, 0, List.of())` to clear the source — if both fire, the last writer wins, and the worst case is a single extra refresh cycle before the models are removed. This is acceptable for pre-release.

Error-isolated per source. Follows the same pattern as `ModelRegistryRefresher` but for dynamically-managed sources. Default refresh interval: 1 hour (configurable).

**Rate limiting consideration:** Each configured source's `refresh()` makes a live HTTP call to the vendor API. With N tenants × M vendors, the refresh cycle makes N×M API calls per interval. For pre-release scale (single-digit tenants), this is acceptable. At scale, implement staggered refresh (jitter) and configurable per-vendor rate limits.

### ConfiguredModelSource (revised, R2-04)

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
            lastKnownModels = toTenantScoped(result.models());
            return lastKnownModels;
        }
        return lastKnownModels != null ? lastKnownModels : List.of();
    }

    /**
     * Transforms VendorClient-produced descriptors into tenant-scoped registry entries.
     * VendorClient returns descriptors with apiModelId as the vendor-facing identifier
     * (e.g., "claude-sonnet-5"). This method sets:
     *   id = "{vendorKey}:{tenancyId}:{apiModelId}" — the tenant-scoped registry key
     *   apiModelId = unchanged — the vendor-facing identifier for RoutingAgentProvider
     */
    private List<ModelDescriptor> toTenantScoped(List<ModelDescriptor> vendorModels) {
        return vendorModels.stream()
            .map(d -> new ModelDescriptor(
                vendorKey + ":" + tenancyId + ":" + d.apiModelId(),  // tenant-scoped registry key
                d.apiModelId(),       // vendor-facing identifier (unchanged)
                d.backendKey(), d.vendor(), d.family(), d.displayName(),
                d.tier(), d.capabilities(), d.contextWindow(), d.maxOutput(),
                d.locality(), d.costTier(), d.authMethod(), d.properties()))
            .toList();
    }
}
```

Tenant ID is stored at construction time, not resolved from request context. The `toTenantScoped()` method is the critical bridge between VendorClient output (plain model IDs) and the registry's tenant-scoped partitioning scheme (§Tenant Isolation).

## Vendor Clients (R1-05, R1-12 — shared abstraction for #288)

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

### Metadata Resolution Strategy (R1-05)

Vendor listing APIs return minimal metadata — model IDs, creation timestamps, and type. They do NOT return `tier`, `capabilities`, `contextWindow`, `maxOutput`, `costTier`, or other `ModelDescriptor` fields. Specifically:
- Anthropic `/v1/models`: returns `id`, `type`, `display_name`, `created_at`
- OpenAI `/v1/models`: returns `id`, `created`, `owned_by`
- Ollama `/api/tags`: returns `name`, `model`, `modified_at`, `size`

**Resolution approach — two-tier:**

1. **Known models (seed catalog match):** When a vendor API returns a model ID that matches a seed catalog entry (by `apiModelId`), the VendorClient merges metadata from the seed catalog. The seed catalog is the authority for static metadata (tier, capabilities, contextWindow, maxOutput, costTier). The vendor API confirms the model is currently accessible with the given credentials.

2. **Unknown models (no seed catalog match):** Models discovered by the vendor API that don't match any seed catalog entry receive sensible defaults:
   - `tier`: `ModelTier.STANDARD`
   - `capabilities`: `Set.of(ModelCapabilities.TEXT)`
   - `contextWindow`: `0` (unknown)
   - `maxOutput`: `0` (unknown)
   - `costTier`: `null` (unknown — excluded from cost-constrained queries per `ModelDescriptor` null semantics)

   Unknown models are still registered — they're usable, just with degraded metadata. A WARN-level log message identifies each unknown model so operators can update the seed catalog.

**Implementation:** `VendorClient` receives an injected reference to the seed catalog (via `ModelRegistry` query with `vendor` filter). The `listModels()` method intersects API-discovered model IDs with seed catalog entries, copying static metadata from matches. This keeps VendorClient implementations thin — they handle HTTP and JSON parsing, not model taxonomy.

**Seed catalog updates:** When vendors release new models, the seed catalog YAML is updated. Between seed updates, new models appear with default metadata. This lag is acceptable — the model is immediately usable, just without precise capability/context-window metadata.

### Implementations

- `AnthropicClient` — `GET https://api.anthropic.com/v1/models`, backendKey=`"claude"`
- `OpenAiClient` — `GET https://api.openai.com/v1/models`, backendKey=`"openai"`
- `GoogleClient` — Gemini models endpoint, backendKey=`"gemini"`
- `OllamaClient` — `GET http://{host}/api/tags`, backendKey=`"ollama"`

CDI-discovered via `@Any Instance<VendorClient>`. `vendors()` derives the list dynamically from discovered clients (R1-13).

**No Mistral backend (R1-08):** `MistralClient` is not included in this branch — no `MistralAgentBackend` exists in the platform. Added when a Mistral backend module is created.

## Scope Model — Tenant Only (R2-01, R2-02)

Provider configurations are scoped via PreferenceStore at tenant root scope only:

| Scope | Who writes | What's stored |
|-------|-----------|---------------|
| Tenant root (`/`) | Admin (`@RolesAllowed(PlatformRoles.ADMIN)`) | Provider config metadata |

Credentials are scoped by `(tenancyId, credentialRef)` in `LlmCredentialStore` — separate from PreferenceStore.

The `ConfiguredModelSourceManager` creates one `ConfiguredModelSource` per `(vendorKey, tenancyId)` tuple. Each source has a single `credentialRef` mapping to the admin-configured credential. Model IDs are tenant-prefixed for isolation (see §Tenant Isolation).

**User-scope deferred (R2-01, R2-02):** User-scope personal providers require per-`(vendorKey, tenancyId, actorId)` source isolation, user-scoped model IDs (a fourth segment in the ID format), and N×M×U refresh scaling. These concerns need separate design — the tenant-scope source lifecycle doesn't extend to user scope without significant rework. Tracked in §Downstream.

### Authorization Flow (R1-09, R2-01, R2-05)

`LlmConfigService` injects `CurrentPrincipal` for request-scoped authorization. This is safe in an `@ApplicationScoped` bean — CDI client proxies delegate to the correct contextual instance per request (see `CurrentPrincipal` Javadoc).

```java
@ApplicationScoped
public class LlmConfigService implements LlmConfigApi {

    @Inject CurrentPrincipal principal;    // request-scoped via CDI proxy
    @Inject ConfiguredModelSourceManager sourceManager;
    // ... other injections

    @RolesAllowed(PlatformRoles.ADMIN)
    @Override
    public ConfigureResult configure(ConfigureRequest request) {
        String tenancyId = principal.tenancyId();
        // ... tenant-scope write
    }

    @RolesAllowed(PlatformRoles.ADMIN)
    @Override
    public void unconfigure(String providerId) {
        String tenancyId = principal.tenancyId();
        // ... tenant-scope delete
    }
}
```

**Authorization enforcement points:**
1. **Writes** (`configure`, `unconfigure`): `@RolesAllowed(PlatformRoles.ADMIN)` on service methods. `PlatformRoles.ADMIN = "platform-admin"` — the platform constant used across the codebase (e.g., `AclResource`, `CallbackRegistrationResource`). Quarkus SecurityInterceptor enforces via `CurrentPrincipal.roles()`.
2. **Reads** (`vendors`, `configured`): No role restriction. Any authenticated user can list vendors and see configured providers.
3. **Validate** (`validate`): No role restriction — any authenticated user can test credentials before requesting admin configuration. The server makes HTTP calls only to hardcoded vendor API endpoints (§Implementations), not caller-controlled URLs. (R3-02)
4. **Tenant ID extraction**: Always from `CurrentPrincipal.tenancyId()` — never from user input. This is a platform invariant documented on `CurrentPrincipal`: "must never be sourced from user-supplied input."
5. **Generated endpoints**: The `GraphQLResolverProcessor` does not generate `@RolesAllowed` annotations — authorization is enforced at the service layer. The generated REST/GraphQL endpoints delegate directly to `LlmConfigService`, where the security interceptor fires.

**Distinction from `ConfiguredModelSourceManager`:** The manager does NOT inject `CurrentPrincipal` because it runs at `@Startup` and `@Scheduled` — no request context exists. All manager methods take explicit `tenancyId` parameters. `LlmConfigService` bridges the gap: it extracts `tenancyId` from `CurrentPrincipal` and passes it to the manager.

## PreferenceStore Namespace (revised — no credentials)

Provider config only — no secrets:

| Key pattern | Value | Example |
|-------------|-------|---------|
| `llm.provider.{vendorKey}.enabled` | `"true"` | `llm.provider.anthropic.enabled=true` |
| `llm.provider.{vendorKey}.credential-ref` | logical name | `llm.provider.anthropic.credential-ref=anthropic-tenant42` |
| `llm.provider.{vendorKey}.display-name` | optional override | `llm.provider.anthropic.display-name=Production` |
| `llm.provider.{vendorKey}.configured-at` | ISO-8601 | `llm.provider.anthropic.configured-at=2026-09-12T10:00:00Z` |

Provider index (`PLATFORM_TENANT_ID` scope, for startup enumeration):

| Key pattern | Value | Example |
|-------------|-------|---------|
| `llm.provider-index.{tenancyId}:{vendorKey}` | `"true"` | `llm.provider-index.tenant-42:anthropic=true` |

## Known Limitations

1. **Multi-instance (#290):** One provider configuration per vendor per tenant. A user who wants "Claude via API key" AND "Claude via Vertex" cannot configure both. Filed as #290 dependency; this branch implements single-instance only (R1-09).
2. **REST DELETE verb:** `unconfigure()` generates `POST` not `DELETE`. Tracked under #295 (R1-11).
3. **Tenant isolation is partitioning, not authorization:** Tenant-prefixed model IDs prevent accidental cross-tenant use but don't enforce it cryptographically. Post-release: add tenant-aware query overloads to `ModelRegistry` SPI (R1-01).
4. **Credentials lost on restart (pre-release):** `InMemoryLlmCredentialStore` is volatile. Providers show as "credentials expired" after restart and require reconfiguration. Production: Vault-backed store.
5. **Per-tenant credential dispatch for invocation (R1-02):** Configured credentials are used for model discovery and refresh only. Model invocation uses platform-level backend credentials. Per-tenant credential dispatch requires extending `AgentBackend` SPI — tracked as a follow-up (see §Downstream).
6. **User-scope personal providers deferred (R2-01, R2-02):** Only tenant-scope admin configuration in this branch. User-scope requires per-user source lifecycle, user-scoped model IDs, and O(N×M×U) refresh scaling — tracked in §Downstream.

## Test Strategy

1. `LlmConfigApi` — SPI contract: `vendors()` returns CDI-derived catalog, `configure`/`unconfigure` lifecycle
2. `LlmConfigService` — tenant isolation: admin configures at tenant scope, cross-tenant blocked, non-admin blocked
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

### platform-api (SPI extensions)

| File | Action |
|------|--------|
| `platform-api/.../model/MutableModelRegistry.java` | New — extends ModelRegistry with replaceSource() |
| `platform-api/.../model/ModelDescriptor.java` | Modified — add `apiModelId` field (R1-01) |
| `platform-api/.../credentials/LlmCredentialStore.java` | New — SPI for LLM credential storage (R1-11) |

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
| `llm-config/src/main/java/.../InMemoryLlmCredentialStore.java` | New — volatile impl of LlmCredentialStore (SPI in platform-api) |
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
| `platform/...SeedCatalogModelSource.java` | Modified — add `apiModelId` parameter (= `id` for seed catalog models) (R3-01) |
| `platform/.../credentials/NoOpLlmCredentialStore.java` | New — `@DefaultBean` no-op impl (R2-03) |
| `agent-router/...RoutingAgentProvider.java` | Modified — use `descriptor.apiModelId()` instead of `descriptor.id()` (R1-01) |
| `graphql-generator/` | Modified — REST generation PoC (already committed) |

## Downstream (not this branch)

| Issue | Repo | Dependency |
|-------|------|------------|
| #288 | platform | Cloud model sources — uses VendorClient abstraction from this branch |
| #290 | platform | Multi-instance backend — extends wizard to support N configs per vendor |
| #295 | platform | Unified API generation — productionise REST generator PoC |
| TBD | platform | Per-tenant credential dispatch — extend `AgentBackend` SPI for credential-aware invocation (R1-02) |
| TBD | platform | User-scope personal providers — per-user source lifecycle, user-scoped model IDs, refresh scaling (R2-01, R2-02) |

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
- `io.casehub.platform.api.credentials.LlmCredentialStore` — LLM credential storage SPI (new, in platform-api)
- `io.casehub.platform.api.identity.TenancyConstants` — `PLATFORM_TENANT_ID` for cross-tenant indexes
- `io.casehub.platform.api.identity.CurrentPrincipal` — request-scoped identity (injected into LlmConfigService)
- `io.casehub.platform.api.identity.PlatformRoles` — `ADMIN = "platform-admin"` role constant
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
