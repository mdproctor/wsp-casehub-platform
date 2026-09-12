# LLM Configuration Wizard API — Design Spec

**Issues:** casehubio/platform#291
**Date:** 2026-09-12
**Status:** Draft

## Summary

Headless REST/GraphQL/MCP API for guided LLM provider configuration. A tenant admin or individual user selects a vendor, provides credentials, validates them against the vendor's live API, and persists the configuration. Configured providers automatically become `ModelSource` beans that feed the `ModelRegistry`, making their models immediately queryable by `RoutingAgentProvider` and all other registry consumers.

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
│  │ Vendor     │  │ Preference   │  │ Credential       │ │
│  │ Validators │  │ Store        │  │ Resolver         │ │
│  │ (HTTP)     │  │ (config)     │  │ (secrets)        │ │
│  └────────────┘  └──────────────┘  └──────────────────┘ │
├──────────────────────────────────────────────────────────┤
│  ConfiguredModelSourceManager (@Startup + runtime)       │
│  → reads PreferenceStore, creates ConfiguredModelSource  │
│  → registers with ModelRegistry via replaceSource()      │
└──────────────────────────────────────────────────────────┘
```

## Module: `llm-config/`

New top-level module. Dependencies:

| Dependency | Scope | Purpose |
|-----------|-------|---------|
| `casehub-platform-api` | compile | ModelRegistry, ModelSource, ModelDescriptor, PreferenceStore, CredentialResolver SPIs |
| `casehub-platform` | test | InMemoryModelRegistry, NoOpPreferenceStore for integration tests |
| `java.net.http` (JDK) | compile | HTTP client for vendor API validation |
| `jackson-databind` | compile | Parse vendor API responses |

No quarkus:build goal. No Flyway migrations.

## SPI Interface

```java
package io.casehub.platform.llm.config;

@McpDomain("llm-config")
public interface LlmConfigApi {

    @PlatformQuery("List available LLM vendors with their auth requirements")
    List<VendorInfo> vendors();

    @PlatformQuery("List currently configured providers for this tenant")
    List<ProviderConfig> configured();

    @PlatformMutation("Validate credentials against a vendor's live API — returns discovered models on success")
    ValidationResult validate(ValidateRequest request);

    @PlatformMutation("Persist a validated provider configuration and register it as a ModelSource")
    ConfigureResult configure(ConfigureRequest request);

    @PlatformMutation("Remove a provider configuration and deregister its ModelSource")
    void unconfigure(String providerId);
}
```

This generates:
- `GeneratedLlmConfigResolver` — `@GraphQLApi` with `@Query`/`@Mutation` methods
- `GeneratedLlmConfigResource` — `@Path("/api/llm-config")` with `@GET`/`@POST` methods
- MCP tools via `GraphQLModelScanner` runtime discovery

## DTOs

### VendorInfo

```java
public record VendorInfo(
    String vendorKey,          // "anthropic", "openai", "google", "mistral", "ollama"
    String displayName,        // "Anthropic"
    String authMethod,         // "api-key", "vertex", "bedrock", "local"
    List<String> requiredFields // ["api-key"] or ["user", "password"] or []
) {}
```

Static catalog — the wizard knows which vendors exist and what credentials they need. This does not come from the ModelRegistry (which tracks models, not vendors). Extensible via a `VendorDescriptor` registry if more vendors are added frequently.

### ValidateRequest / ValidationResult

```java
public record ValidateRequest(
    String vendorKey,
    Map<String, String> credentials  // keyed by CredentialPropertyKeys
) {}

public record ValidationResult(
    boolean valid,
    String errorMessage,              // null on success
    List<DiscoveredModel> models      // populated on success
) {}

public record DiscoveredModel(
    String id,
    String displayName,
    ModelTier tier,
    Set<String> capabilities,
    int contextWindow,
    int maxOutput
) {}
```

### ConfigureRequest / ConfigureResult

```java
public record ConfigureRequest(
    String vendorKey,
    String credentialRef,              // logical name for CredentialResolver
    Map<String, String> credentials,   // actual credential values to persist
    String displayName                 // optional override for the provider name
) {}

public record ConfigureResult(
    String providerId,                 // generated: "{vendorKey}-{tenancyId}" or user-specified
    int modelsRegistered,
    List<String> modelIds              // IDs now queryable via ModelRegistry
) {}
```

## Implementation: LlmConfigService

`@ApplicationScoped` bean implementing `LlmConfigApi`. Injected dependencies:

- `CurrentPrincipal` — tenant isolation
- `PreferenceStore` — persist provider config metadata
- `CredentialResolver` — read credentials (for reconfiguration)
- `ConfiguredModelSourceManager` — create/remove model sources
- `VendorValidatorRegistry` — dispatch validation to vendor-specific validators

### Vendor Validators

Each vendor has a validator that knows how to call its API:

```java
public interface VendorValidator {
    String vendorKey();
    ValidationResult validate(Map<String, String> credentials);
}
```

Implementations:
- `AnthropicValidator` — calls `GET https://api.anthropic.com/v1/models` with `x-api-key` header
- `OpenAiValidator` — calls `GET https://api.openai.com/v1/models` with `Authorization: Bearer` header
- `GoogleValidator` — calls Gemini models endpoint with API key
- `OllamaValidator` — calls `GET http://{host}/api/tags` (local, no auth)

Each validator parses the vendor's response into `List<DiscoveredModel>`, mapping vendor-specific fields to the normalized model dimensions (tier, capabilities, context window, etc.).

Validators are CDI-discovered via `@Any Instance<VendorValidator>` — new vendors are added by implementing the interface.

### Credential Persistence

The wizard needs a writable credential path. `CredentialResolver` is read-only. Two options exist in the platform:

1. `QuarkusCredentialResolver` bridges to Quarkus `CredentialsProvider` — which supports Vault, AWS Secrets Manager, etc.
2. `DefaultCredentialResolver` reads from MicroProfile Config — read-only at runtime

For the wizard, credentials are persisted via `PreferenceStore` under a secured namespace (`llm.credentials.*`) and a thin `PreferenceBackedCredentialSource` provides them to `CredentialResolver`. The exact mechanism depends on which `CredentialResolver` implementation is on the classpath — the wizard writes to the config source that backs the active resolver.

For pre-release: store credentials in `PreferenceStore` under `llm.credentials.{credentialRef}.*` with scope-aware tenant isolation. The preference values are the credential properties (API_KEY, BEARER_TOKEN, etc.). A `LlmCredentialResolver` `@Alternative @Priority(50)` reads from this namespace, delegating to the existing `CredentialResolver` for non-LLM refs.

## ConfiguredModelSourceManager

```java
@ApplicationScoped
public class ConfiguredModelSourceManager {

    @Inject PreferenceStore preferenceStore;
    @Inject CurrentPrincipal principal;
    @Inject InMemoryModelRegistry registry;  // package-internal, not SPI
    @Inject VendorValidatorRegistry validators;
    @Inject Event<ModelCatalogChangedEvent> catalogChanged;

    private final ConcurrentHashMap<String, ConfiguredModelSource> activeSources
        = new ConcurrentHashMap<>();
}
```

### @Startup — reconstruct from PreferenceStore

On startup, reads all `llm.provider.*` preferences across all tenants, creates a `ConfiguredModelSource` per persisted provider, and registers each with the registry via `replaceSource()`.

### Runtime — create/remove on wizard actions

- `configure()` → creates `ConfiguredModelSource`, stores config in PreferenceStore, registers with registry, fires `ModelCatalogChangedEvent`
- `unconfigure()` → removes from PreferenceStore, calls `replaceSource(sourceId, priority, List.of())` to clear, removes from `activeSources`

### ConfiguredModelSource

```java
class ConfiguredModelSource implements ModelSource {
    private final String sourceId;      // "configured:{vendorKey}:{tenancyId}"
    private final String vendorKey;
    private final String credentialRef;
    private final VendorValidator validator;
    private volatile List<ModelDescriptor> lastKnownModels;

    @Override
    public String sourceId() { return sourceId; }

    @Override
    public int priority() { return 10; }  // above seed catalog (0), below live API sources

    @Override
    public List<ModelDescriptor> refresh() {
        var result = validator.validate(resolveCredentials());
        if (result.valid()) {
            lastKnownModels = toDescriptors(result.models());
            return lastKnownModels;
        }
        return lastKnownModels != null ? lastKnownModels : List.of();
    }
}
```

Priority 10 — above seed catalog (0) so configured models override seed entries. If a live API source (#288) is later added at priority 100, it overrides configured entries. On refresh failure, returns the last known good set — avoids models disappearing due to transient network issues.

## Scope Model — Tenant + User

Provider configurations are scoped:

| Scope | Who writes | Visibility |
|-------|-----------|------------|
| Tenant root (`/`) | Admin (`@RolesAllowed(ADMIN)`) | All users in tenant |
| User scope (`/users/{actorId}`) | The user themselves | That user only |

PreferenceStore's scope-aware resolution handles inheritance: a user-scoped provider overrides a tenant-scoped provider for the same vendor.

The `ConfiguredModelSourceManager` creates separate `ConfiguredModelSource` instances per (vendor, tenancy, scope) tuple. Tenant-scoped sources are visible to all users in that tenant. User-scoped sources are visible only to that user's agent sessions (enforced at the `RoutingAgentProvider` level via `CurrentPrincipal`).

## PreferenceStore Namespace

Provider config stored under namespace `llm.provider`:

| Key pattern | Value | Example |
|-------------|-------|---------|
| `llm.provider.{vendorKey}.enabled` | `"true"` | `llm.provider.anthropic.enabled=true` |
| `llm.provider.{vendorKey}.credential-ref` | credential logical name | `llm.provider.anthropic.credential-ref=anthropic-prod` |
| `llm.provider.{vendorKey}.display-name` | optional override | `llm.provider.anthropic.display-name=Anthropic (Production)` |
| `llm.provider.{vendorKey}.priority` | source priority | `llm.provider.anthropic.priority=10` |

Credentials stored under namespace `llm.credentials`:

| Key pattern | Value | Example |
|------------|-------|---------|
| `llm.credentials.{ref}.api-key` | API key value | `llm.credentials.anthropic-prod.api-key=sk-ant-...` |
| `llm.credentials.{ref}.bearer-token` | Bearer token | `llm.credentials.openai-prod.bearer-token=sk-...` |

## Test Strategy

1. `LlmConfigApi` — SPI contract: vendors() returns static catalog, configure/unconfigure lifecycle
2. `LlmConfigService` — tenant isolation: admin can configure at tenant scope, user can configure at user scope, cross-tenant blocked
3. `VendorValidator` — per-vendor: mock HTTP responses, verify model parsing (tier, capabilities, context window mapping)
4. `ConfiguredModelSourceManager` — startup: persisted configs create sources; runtime: configure creates source, unconfigure removes
5. `ConfiguredModelSource.refresh()` — success returns fresh models, failure returns last known good
6. `LlmCredentialResolver` — reads from PreferenceStore namespace, delegates non-LLM refs to existing resolver
7. Integration — full flow: validate → configure → ModelRegistry.query() returns configured models → unconfigure → models gone
8. Scope resolution — tenant default + user override: user's provider overrides tenant's for same vendor

## Files Changed

### New module: `llm-config/`

| File | Action |
|------|--------|
| `llm-config/pom.xml` | New |
| `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigApi.java` | New — @McpDomain SPI |
| `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigService.java` | New — @ApplicationScoped impl |
| `llm-config/src/main/java/io/casehub/platform/llm/config/VendorInfo.java` | New — DTO |
| `llm-config/src/main/java/io/casehub/platform/llm/config/ValidateRequest.java` | New — DTO |
| `llm-config/src/main/java/io/casehub/platform/llm/config/ValidationResult.java` | New — DTO |
| `llm-config/src/main/java/io/casehub/platform/llm/config/DiscoveredModel.java` | New — DTO |
| `llm-config/src/main/java/io/casehub/platform/llm/config/ConfigureRequest.java` | New — DTO |
| `llm-config/src/main/java/io/casehub/platform/llm/config/ConfigureResult.java` | New — DTO |
| `llm-config/src/main/java/io/casehub/platform/llm/config/VendorValidator.java` | New — SPI |
| `llm-config/src/main/java/io/casehub/platform/llm/config/VendorValidatorRegistry.java` | New — CDI discovery |
| `llm-config/src/main/java/io/casehub/platform/llm/config/AnthropicValidator.java` | New |
| `llm-config/src/main/java/io/casehub/platform/llm/config/OpenAiValidator.java` | New |
| `llm-config/src/main/java/io/casehub/platform/llm/config/GoogleValidator.java` | New |
| `llm-config/src/main/java/io/casehub/platform/llm/config/OllamaValidator.java` | New |
| `llm-config/src/main/java/io/casehub/platform/llm/config/ConfiguredModelSourceManager.java` | New — @Startup + runtime |
| `llm-config/src/main/java/io/casehub/platform/llm/config/ConfiguredModelSource.java` | New — ModelSource impl |
| `llm-config/src/main/java/io/casehub/platform/llm/config/LlmCredentialResolver.java` | New — @Alternative @Priority(50) |
| `llm-config/src/test/java/io/casehub/platform/llm/config/LlmConfigServiceTest.java` | New |
| `llm-config/src/test/java/io/casehub/platform/llm/config/ConfiguredModelSourceManagerTest.java` | New |
| `llm-config/src/test/java/io/casehub/platform/llm/config/AnthropicValidatorTest.java` | New |

### Modified

| File | Action |
|------|--------|
| `pom.xml` (root) | Modified — add `llm-config` to modules list |
| `graphql-generator/` | Modified — REST generation PoC (already committed on this branch) |

## Downstream (not this branch)

| Issue | Repo | Dependency |
|-------|------|------------|
| #288 | platform | Cloud model sources (Anthropic, OpenAI, Vertex, Bedrock) — may share validator HTTP logic |
| #290 | platform | Multi-instance backend support — the wizard configures one instance per vendor; multi-instance extends to multiple configs per vendor |
| #295 | platform | Unified API generation epic — productionise the REST generation PoC |

## References

- `io.casehub.platform.api.model.ModelRegistry` — consumer SPI for model catalog queries
- `io.casehub.platform.api.model.ModelSource` — pull-based model catalog source SPI
- `io.casehub.platform.api.model.ModelDescriptor` — normalized model metadata record
- `io.casehub.platform.model.InMemoryModelRegistry` — implementation with replaceSource() and CatalogDelta
- `io.casehub.platform.model.ModelRegistryRefresher` — @Startup + @Scheduled refresh
- `io.casehub.platform.api.credentials.CredentialResolver` — outbound credential resolution SPI
- `io.casehub.platform.api.credentials.CredentialPropertyKeys` — API_KEY, BEARER_TOKEN constants
- `io.casehub.platform.api.preferences.PreferenceStore` — scope-aware config persistence SPI
- `io.casehub.platform.preferences.editor.PreferenceResource` — existing REST pattern reference
- `io.casehub.platform.graphql.generator.GraphQLResolverProcessor` — APT for GraphQL + REST generation
- `io.casehub.platform.api.mcp.McpDomain` — domain annotation for MCP + generation
- `io.casehub.platform.api.mcp.PlatformQuery` / `PlatformMutation` — operation annotations
- casehubio/platform#285 — parent epic (LLM model registry)
- casehubio/platform#286 — ModelRegistry SPI (dependency, landed)
- casehubio/platform#295 — unified API generation epic
- Anthropic `/v1/models` API — vendor validation target
- OpenAI `/v1/models` API — vendor validation target
