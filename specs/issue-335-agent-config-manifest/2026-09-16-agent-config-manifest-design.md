# Agent Config Manifest — Design Spec

**Issue:** casehubio/platform#335
**Date:** 2026-09-16
**Status:** Draft

## Summary

A declarative YAML manifest that drives the existing LLM infrastructure (ModelRegistry, LlmCredentialStore, BackendInstanceCoordinator, RoutingAgentProvider) at startup. A developer writes one config file and AgentProvider works — no custom code, no per-project wiring.

The manifest is not new infrastructure. It is the orchestration layer — the missing glue that connects the existing SPIs into a single declarative pipeline from config to running LLM.

## Problem

The platform has all the machinery for LLM model management:

- `ModelRegistry` / `MutableModelRegistry` — queryable model catalog
- `ModelSource` SPI — refresh-based catalog population (seed, cloud, Ollama)
- `LlmCredentialStore` — credential storage per tenant
- `BackendInstanceCoordinator` — startup wiring from credentials to backends
- `BackendInstanceRegistry` — runtime backend resolution
- `RoutingAgentProvider` — three-step model resolution (tier → ID → key)
- `LlmConfigService` — imperative REST/MCP API for vendor configuration

But no declarative path through any of it. Every consumer project hand-rolls its own setup:

- **wacky-manor:** Two backends on classpath, nothing configured for tests. NoOpAgentProvider activates by default.
- **showcase:** Custom `TestAgentProvider.claude()` wrapping CLI subprocess. No model selection, no provider abstraction.
- **Other projects:** Inline API keys, hardcoded model names, custom client construction.

The problem is adoption, not capability. The manifest provides the declarative entry point.

## Pipeline

```
    ┌─────────────────────────────────────────────────────────┐
    │                    RESOURCE CHAIN                        │
    │                                                         │
    │  classpath:models/seed-catalog.yaml       (priority  0) │
    │  file:/etc/casehub/agent-config.yaml      (priority 10) │
    │  file:~/.casehub/agent-config.yaml        (priority 20) │
    │  file:~/.casehub/agent-config-{profile}   (priority 25) │
    │  file:./agent-config.yaml                 (priority 30) │
    │  file:./agent-config-{profile}.yaml       (priority 35) │
    │  https://corp/approved-models.json        (priority 40) │
    │                                                         │
    │  Profile: CASEHUB_AGENT_PROFILE env var                 │
    │  Accumulate by model ID, highest priority wins          │
    └────────────────────────┬────────────────────────────────┘
                             │ discover + load + merge
                             ▼
    ┌─────────────────────────────────────────────────────────┐
    │                  MERGED MANIFEST                         │
    │                                                         │
    │  models: [...]       ──→ ModelRegistry                  │
    │  providers: [...]    ──→ LlmCredentialStore             │
    │                         → BackendInstanceCoordinator    │
    │  local-models: [...] ──→ OllamaModelSource.reconcile() │
    │  aliases: [...]      ──→ RoutingAgentProvider           │
    │  defaults: { ... }   ──→ RoutingAgentProvider           │
    │  sources: [...]      ──→ recursive resource loading     │
    └────────────────────────┬────────────────────────────────┘
                             │ provision + register + configure
                             ▼
    ┌─────────────────────────────────────────────────────────┐
    │              RUNNING AGENTPROVIDER                       │
    │                                                         │
    │  invoke("reasoning-heavy")                              │
    │    → alias lookup → ModelQuery                          │
    │    → ModelRegistry.query() → filtered candidates        │
    │    → prefer default backend → prefer vendor → select    │
    │    → BackendInstanceRegistry.resolve() → backend        │
    │    → backend.invoke() → response                        │
    └─────────────────────────────────────────────────────────┘
```

## Manifest Schema

Every resource in the chain uses the same schema. All sections are optional.

```yaml
# Models — contributes descriptors to the catalog
models:
  - id: my-fine-tune
    apiModelId: ft:gpt-4-0613:my-org::abc123  # defaults to id if omitted
    backendKey: openai
    backendInstanceId: default                  # optional — defaults to null (→ "default" at resolution)
    vendor: openai
    family: gpt-4
    displayName: My Fine-Tuned GPT-4
    tier: STANDARD
    capabilities: [text, code]
    contextWindow: 128000
    maxOutput: 16384
    locality: CLOUD
    costTier: MEDIUM
    authMethod: api-key

# Providers — activates vendor access with credential references
providers:
  - vendor: anthropic
    credential: env:ANTHROPIC_API_KEY           # shorthand for single-field vendor

  - vendor: vertex
    credential:                                  # explicit fields for multi-field vendor
      project-id: env:GOOGLE_CLOUD_PROJECT
      location: env:GOOGLE_CLOUD_LOCATION
      service-account-json: env:GOOGLE_APPLICATION_CREDENTIALS

  - vendor: ollama
    host: localhost:11434                         # no credential needed

# Sources — additional resources to load (recursive)
sources:
  - uri: https://internal.corp/approved-models.json
    priority: 40

# Aliases — named constraint sets for model selection
aliases:
  reasoning-heavy:
    tier: FLAGSHIP
    capabilities: [reasoning, code]
    min-context: 128000
  cheap-fast:
    tier: FAST
    max-cost: LOW
  vision-capable:
    capabilities: [vision]
    prefer-vendor: anthropic

# Local models — desired state, reconciled at startup
local-models:
  - id: llama-4-scout
    ensure: present

# Defaults
defaults:
  backend: claude
```

### Credential Reference Types

Manifest credential fields are references, never raw values.

| Prefix | Resolves via | Deployment tier |
|--------|-------------|-----------------|
| `env:VAR_NAME` | `System.getenv()` | Dev, CI |
| `file:/path` | File contents | Kubernetes mounted secrets |
| `ref:credential-ref` | `CredentialResolver` SPI → Quarkus `CredentialsProvider` → Vault/AWS/GCP | Production |

The existing `credentials-quarkus/` module bridges `CredentialResolver.resolve()` to Quarkus `CredentialsProvider`. `ManifestCredentialResolver` delegates `ref:` prefixes to `CredentialResolver` (platform-api SPI), which routes through the Quarkus bridge when `credentials-quarkus/` is on the classpath. Adding a Vault extension makes `ref:vault/anthropic-key` work automatically.

Outside Quarkus (Spring, standalone), only `env:` and `file:` are available unless a `CredentialResolver` implementation is provided — correct for those contexts.

### Provider Credential Resolution

Each vendor declares required fields via `VendorInfo.requiredFields()`:

| Vendor | Required fields | Shorthand |
|--------|----------------|-----------|
| anthropic | `api-key` | `credential: env:ANTHROPIC_API_KEY` |
| openai | `api-key` | `credential: env:OPENAI_API_KEY` |
| google | `api-key` | `credential: env:GOOGLE_AI_API_KEY` |
| ollama | (none) | no credential section |
| bedrock | `access-key`, `secret-key`, `region` | explicit map required |
| vertex | `project-id`, `location`, `service-account-json` | explicit map required |

Single-field vendors accept scalar credential references (shorthand). Multi-field vendors require an explicit map.

### Model Selection — String or Constraints

The `model` field (in aliases, eidos definitions, org descriptors) is a union type: string or ModelConstraints object.

**String forms:**
- `"claude-opus-5"` — model ID (resolved via ModelRegistry)
- `"tier:FLAGSHIP"` — tier reference (resolved via ModelRef)
- `"reasoning-heavy"` — alias (resolved via alias registry)
- `"openai"` — backend key (resolved via BackendInstanceRegistry)

**ModelConstraints object:**
```yaml
model:
  tier: FLAGSHIP
  capabilities: [vision, reasoning]
  locality: CLOUD
  max-cost: HIGH
  min-context: 128000
  min-output: 32000
  prefer-vendor: anthropic
```

All constraint fields are optional (null = don't care). Range fields (`min-context`, `min-output`) are filters — a model either meets the threshold or doesn't. `prefer-vendor` is a tiebreaker among matching models, not a filter.

### JSON Schema

`model-selection.schema.json` defines the union type:

```json
{
  "$id": "model-selection",
  "oneOf": [
    { "type": "string" },
    { "$ref": "#/$defs/ModelConstraints" }
  ],
  "$defs": {
    "ModelConstraints": {
      "type": "object",
      "properties": {
        "vendor":        { "type": "string" },
        "family":        { "type": "string" },
        "tier":          { "enum": ["FLAGSHIP", "STANDARD", "FAST", "EMBEDDING"] },
        "capabilities":  { "type": "array", "items": { "enum": ["text", "vision", "tool-use", "code", "reasoning"] } },
        "locality":      { "enum": ["CLOUD", "LOCAL"] },
        "max-cost":      { "enum": ["FREE", "LOW", "MEDIUM", "HIGH", "PREMIUM"] },
        "min-context":   { "type": "integer", "minimum": 0 },
        "min-output":    { "type": "integer", "minimum": 0 },
        "prefer-vendor": { "type": "string" }
      },
      "additionalProperties": false
    }
  }
}
```

yaml-codegen generates a `ModelConstraints` Java record from this schema. The same schema powers IDE autocompletion in YAML files and web app form rendering. Published as a Maven artifact resource for cross-repo `$ref`.

## Resource Discovery

### Implicit Local Chain

The loader walks a fixed hierarchy, checking for files at each level:

| Level | Path | Priority | Loaded when |
|-------|------|----------|-------------|
| Platform | `classpath:models/seed-catalog.yaml` | 0 | Always |
| System | `/etc/casehub/agent-config.yaml` | 10 | If exists |
| User | `~/.casehub/agent-config.yaml` | 20 | If exists |
| User profile | `~/.casehub/agent-config-{profile}.yaml` | 25 | If exists and profile matches |
| Project | `./agent-config.yaml` | 30 | If exists |
| Project profile | `./agent-config-{profile}.yaml` | 35 | If exists and profile matches |

Profile determined by `CASEHUB_AGENT_PROFILE` env var. In Quarkus environments, falls back to `QUARKUS_PROFILE` if `CASEHUB_AGENT_PROFILE` is unset — a convenience default for deployments where agent config aligns with the application profile. When the two diverge (e.g., `QUARKUS_PROFILE=dev` but agent tests target CI Ollama), set `CASEHUB_AGENT_PROFILE` explicitly.

Outside Quarkus (Spring Boot, standalone), only `CASEHUB_AGENT_PROFILE` is checked — no framework-specific fallback. If no profile env var is set, profile-specific config files are ignored (base config applies).

### Explicit Remote Sources

Any manifest can declare additional sources:

```yaml
sources:
  - uri: https://internal.corp/approved-models.json
    priority: 40
```

Remote sources are fetched at startup and accumulated into the merged manifest. Last-known-good caching (already built for CloudModelSource) handles network failures.

#### Recursive Loading Guards

Source loading is recursive — a loaded manifest can declare more sources. Guards:

| Guard | Value | Behavior |
|-------|-------|----------|
| Cycle detection | URI set | If a URI is already in the loading stack, skip with warning |
| Max depth | 3 | Sources nested deeper than 3 levels are ignored with warning |
| Fetch timeout | 10 seconds | Per-fetch HTTP timeout; unreachable source uses last-known-good or is skipped |
| Max total sources | 20 | After 20 unique source URIs are loaded, additional sources are ignored with warning |

All guards log warnings — a misconfigured source chain should degrade, not crash startup.

#### Security

Remote sources use HTTPS for transport-level integrity and confidentiality. Authentication headers (bearer tokens, mTLS) and content integrity verification (checksums) are follow-on concerns — tracked as a separate issue. The initial implementation trusts HTTPS endpoints and caches last-known-good snapshots.

### Accumulation Rules

- **Models:** by `id`. Higher priority wins. A project manifest can override a seed catalog model's properties.
- **Providers:** by `vendor`. Higher priority wins. A project profile can switch the anthropic credential source.
- **Aliases:** by name. Higher priority wins. A project can redefine what `reasoning-heavy` means.
- **Defaults:** last writer wins. Profile defaults override base defaults.
- **Sources:** union by URI. If the same URI appears in multiple manifests, the highest priority wins. Duplicate URIs are fetched only once.
- **Local models:** union of all `ensure: present` declarations.

## Startup Processing

### Startup Ordering

`AgentConfigBeans` observes `StartupEvent` at `@Priority(50)` — before `BackendInstanceCoordinator` (75) and `ModelRegistryRefresher` (default CDI priority). This follows the established priority sequence from the cloud-model-sources design:

| Priority | Bean | Responsibility |
|----------|------|----------------|
| 50 | `AgentConfigBeans` | Load manifest, store credentials, prepare aliases + defaults |
| 75 | `BackendInstanceCoordinator` | Discover credentials → create backend instances |
| default | `ModelRegistryRefresher` | Refresh all model sources (seed, cloud, configured) |

`AgentConfigBeans` replaces `CloudSourceCredentialBootstrap`'s credential seeding role — the manifest handles env var detection declaratively. `CloudSourceCredentialBootstrap` is disabled via `@IfBuildProperty(name = "casehub.agent.manifest.enabled", stringValue = "true", enableIfMissing = false)` and deprecated in this issue.

### ManifestProcessor Pipeline

ManifestProcessor drives existing SPIs from the merged manifest. It receives vendor field requirements as a constructor parameter (`Map<String, List<String>>`, extracted from `VendorClient` beans by the Quarkus wiring layer), keeping `agent-config-core` free of `llm-config` dependencies.

#### Step 1 — Providers → Credentials

For each provider in the merged manifest:
1. Resolve credential references (`env:`, `file:`, `ref:`) → plain values
2. Validate against vendor required fields (injected map) — fail fast if missing
3. Store in `LlmCredentialStore.store(PLATFORM_TENANT_ID, "cloud-{vendorKey}", credentials)`

The credential ref follows the existing `"cloud-{vendorKey}"` convention (e.g., `"cloud-openai"`, `"cloud-anthropic"`). This is the contract that `BackendInstanceFactory` implementations pattern-match against — `OpenAiDirectBackendFactory.deriveInstanceId("cloud-openai")` returns `"default"`. Using a bare vendor key would produce incorrect instance IDs.

After step 1, `BackendInstanceCoordinator` runs its normal startup sequence at `@Priority(75)` — discovers credentials in the store, uses `BackendInstanceFactory` to create backend instances, registers with `BackendInstanceRegistry`.

#### Step 2 — Models → Registry

1. Collect all model descriptors from the merged manifest
2. If `apiModelId` is omitted on a model entry, default to the model's `id` (matching `SeedCatalogModelSource` behavior)
3. Register via `MutableModelRegistry.replaceSource("manifest", priority, models)`
4. Normal `ModelRegistryRefresher` cycle keeps cloud-discovered models current

#### Step 3 — Local Models → Reconciliation

For each local model with `ensure: present`:
1. Check availability via OllamaModelSource
2. If missing: trigger pull via `LlmConfigService.pullModel()`
3. If missing: warn and continue (non-blocking) — model will be available after pull completes, subsequent invocations will find it

#### Step 4 — Aliases + Defaults → ManifestResult

1. Parse each alias: `ModelConstraints` → `ModelQuery` (filter fields) + optional `preferVendor` (tiebreaker)
2. Determine effective default backend: manifest `defaults.backend` if declared, else fall back to `RoutingAgentConfig.defaultBackend()` (which defaults to `"claude"` via `@WithDefault`)
3. Produce `ManifestResult` record: `Map<String, ModelQuery> aliases`, `Map<String, String> aliasVendorPreferences`, `String defaultBackendKey`

`ManifestResult` is a CDI bean produced by `AgentConfigBeans`. `RouterBeans` consumes it as an optional dependency — if present, its aliases and default backend key override config-property values. `RoutingAgentProvider` gains a new constructor accepting aliases:

```java
public RoutingAgentProvider(BackendInstanceRegistry registry,
                            String defaultBackendKey,
                            ModelRegistry modelRegistry,
                            Map<String, ModelQuery> aliases,
                            Map<String, String> aliasVendorPreferences)
```

After step 4, `agentProvider.invoke()` works. No custom code.

## Router Extension

`RoutingAgentProvider.resolve()` gains one new step (alias lookup) at the top:

```
resolve(model):
  0. Alias? → lookup in alias map → ModelQuery → query registry → tiebreak → model
  1. Tier ref? → ModelRef.parseTier() → query registry → tiebreak → model
  2. Registry ID? → ModelRegistry.resolveById() → backend
  3. Backend key? → BackendInstanceRegistry.resolve() → backend
  4. Fail fast
```

Tiebreaking (steps 0 and 1): among matching models, prefer (1) default backend, then (2) `aliasVendorPreferences.get(aliasName)` for step 0 (carried separately from the ModelQuery, not as a field on it — see §ModelQuery Extension), then (3) first match.

`prefer-vendor` is a tiebreaking hint, not a filter. It lives in a separate `Map<String, String> aliasVendorPreferences` (alias name → vendor), not in `ModelQuery`. This keeps `ModelQuery` purely about filtering — `InMemoryModelRegistry.query()` doesn't need to know about tiebreaking semantics.

## ModelQuery Extension

Two new filter fields added to `ModelQuery`:

```java
public record ModelQuery(
    String vendor,
    String family,
    ModelTier tier,
    Set<String> requiredCapabilities,
    ModelLocality locality,
    CostTier maxCostTier,
    String authMethod,
    Integer minContextWindow,    // NEW — null = no minimum
    Integer minMaxOutput         // NEW — null = no minimum
) { ... }
```

`InMemoryModelRegistry.query()` gains two additional filter lines:

```java
.filter(d -> query.minContextWindow() == null || d.contextWindow() >= query.minContextWindow())
.filter(d -> query.minMaxOutput() == null || d.maxOutput() >= query.minMaxOutput())
```

Pure filtering, no scoring. Deterministic.

### ModelConstraints → ModelQuery Conversion

`ModelConstraints` (generated from `model-selection.schema.json`) is the YAML/JSON representation. `ModelQuery` is the runtime type. The conversion:

| ModelConstraints field | ModelQuery field | Notes |
|---|---|---|
| `vendor` | `vendor` | Direct |
| `family` | `family` | Direct |
| `tier` | `tier` | Enum parse |
| `capabilities` | `requiredCapabilities` | Direct |
| `locality` | `locality` | Enum parse |
| `max-cost` | `maxCostTier` | Enum parse |
| `min-context` | `minContextWindow` | Direct |
| `min-output` | `minMaxOutput` | Direct |
| `prefer-vendor` | *(not in ModelQuery)* | Carried in `aliasVendorPreferences` map |
| *(not in schema)* | `authMethod` | Not exposed in manifest — set to null |

`prefer-vendor` is intentionally NOT added to `ModelQuery`. `ModelQuery` is a pure filter type — every field participates in `InMemoryModelRegistry.query()` filtering. `prefer-vendor` is a tiebreaking hint (preference among models that already match the filter), not a filter predicate. Mixing filter and tiebreaking semantics in one type creates ambiguity — "does `preferVendor` narrow results or rank them?" Keeping them separate makes both types honest about what they do.

The two types serve different layers: `ModelConstraints` is the schema-generated YAML record; `ModelQuery` is the platform runtime filter. They overlap in fields because filtering IS the primary purpose of model selection constraints — but they are not duplicates. `ModelConstraints` carries `prefer-vendor` (a user-facing concept for the manifest schema); `ModelQuery` carries `authMethod` (a platform-internal filter). Neither is a superset of the other.

## Module Structure

Following the established core/Quarkus pattern:

### `agent-config-core` (new)

Framework-neutral. Pure Java + Jackson. Depends on `platform-api` (zero-dependency SPI layer — gives access to `CredentialResolver`, `LlmCredentialStore`, `ModelQuery`, `ModelRegistry`).

| Type | Purpose |
|------|---------|
| `Manifest` | Parsed manifest record (models, providers, sources, aliases, localModels, defaults) |
| `ProviderDeclaration` | Record: vendor, credential references, host |
| `AliasDeclaration` | Record: name, ModelConstraints |
| `LocalModelDeclaration` | Record: id, ensure |
| `SourceDeclaration` | Record: uri, priority |
| `CredentialRef` | Sealed interface: EnvRef, FileRef, ExternalRef — parsed from prefix |
| `ManifestLoader` | Discovers resources from hierarchy, parses YAML, merges. Cycle detection via URI set, max depth 3, 10s timeout per remote fetch, max 20 total sources. |
| `ManifestProcessor` | Drives existing SPIs from merged manifest. Accepts vendor required fields as `Map<String, List<String>>` constructor parameter (injected by Quarkus layer from `VendorClient` beans). |
| `ManifestResult` | Record: `Map<String, ModelQuery> aliases`, `Map<String, String> aliasVendorPreferences`, `String defaultBackendKey` |
| `ManifestCredentialResolver` | Resolves CredentialRef to plain values. Handles `env:` and `file:` directly; delegates `ref:` to `CredentialResolver` SPI (from platform-api, injected via constructor). |

The resolver is named `ManifestCredentialResolver` (not `CredentialRefResolver`) to avoid confusion with the existing `CredentialResolver` SPI in `platform-api`. `CredentialResolver` resolves credentials by logical name; `ManifestCredentialResolver` resolves credential references with `env:`/`file:`/`ref:` prefixes. Different operation, distinct name.

`VendorInfo` stays in `llm-config/` — `agent-config-core` does not depend on `llm-config`. Instead, ManifestProcessor accepts vendor field requirements as a parameter (`Map<String, List<String>>`), and the Quarkus wiring layer extracts this from `VendorClient` beans.

### `agent-config` (new)

Quarkus wiring. Thin.

| Type | Purpose |
|------|---------|
| `AgentConfigBeans` | `@Observes @Priority(50) StartupEvent` — runs ManifestLoader + ManifestProcessor, produces `ManifestResult` as CDI bean. Collects `VendorClient` beans to extract vendor required fields for ManifestProcessor. |

No separate `QuarkusCredentialRefResolver` — `ManifestCredentialResolver` in agent-config-core handles all three prefixes via `CredentialResolver` SPI injection.

### `agent-config-spring` (generated)

Spring Boot auto-configuration. Generated by `spring-generator` from `AgentConfigBeans`.

## Tenancy

Manifests operate at platform scope (`PLATFORM_TENANT_ID`). They configure what models and credentials are available to the deployment.

Per-tenant model configuration (restricting models per tenant, tenant-specific API keys) remains `LlmConfigService`'s domain via its REST API.

This is the correct separation: the manifest answers "what does this deployment have access to?" (platform-scope bootstrap). LlmConfigService answers "what can this tenant use?" (runtime, per-tenant).

## Consumer Integration

### AgentSessionConfig Extension

`AgentSessionConfig` gains a `withModel()` method for fluent model override:

```java
public record AgentSessionConfig(...) {
    public AgentSessionConfig withModel(String model) {
        return new AgentSessionConfig(systemPrompt, userPrompt, mcpServers, timeout, correlationId, model);
    }
}
```

### Java code
```java
@Inject AgentProvider agentProvider;

// By alias
var config = AgentSessionConfig.of("You are an analyst.", "Analyze this.");
agentProvider.invoke(config.withModel("reasoning-heavy"));

// By tier
agentProvider.invoke(config.withModel("tier:FAST"));

// By model ID
agentProvider.invoke(config.withModel("claude-opus-5"));

// No model — uses default backend
agentProvider.invoke(config);
```

### YAML (eidos case definition)
```yaml
tasks:
  analyze:
    agent:
      model: reasoning-heavy
  triage:
    agent:
      model:
        tier: FAST
        max-cost: LOW
        locality: LOCAL
```

### Tests
```java
@Inject AgentProvider agentProvider;

@Test
void testAnalysis() {
    var events = agentProvider.invoke(
        AgentSessionConfig.of("You are a test agent.", "Analyze this", "tier:FAST")
    ).collect().asList().await().indefinitely();
    assertFalse(events.isEmpty());
}
```

Test environment configured via:
- `~/.casehub/agent-config.yaml` (developer's credentials)
- `./agent-config-ci.yaml` (CI uses Ollama)

### Web app
1. Loads static JSON dump of seed catalog + vendor info (~6KB)
2. User browses models, selects vendors, enters credential references
3. App produces `agent-config.yaml` — download or save to `~/.casehub/`
4. In live mode, calls `LlmConfigService` REST endpoints for validation

### MCP tools (agent self-configuration)
Existing `ModelRegistryApi` (listModels, getModel, refreshRegistry) and `LlmConfigApi` (vendors, configure, validate) — unchanged.

## Example Configurations

### Developer machine

```yaml
# ~/.casehub/agent-config.yaml
providers:
  - vendor: anthropic
    credential: env:ANTHROPIC_API_KEY
  - vendor: ollama
aliases:
  reasoning-heavy:
    tier: FLAGSHIP
    capabilities: [reasoning]
  cheap-fast:
    tier: FAST
    max-cost: LOW
defaults:
  backend: claude
```

### CI environment

```yaml
# ./agent-config-ci.yaml
providers:
  - vendor: ollama
local-models:
  - id: llama-4-scout
    ensure: present
defaults:
  backend: ollama
```

CI sets `CASEHUB_AGENT_PROFILE=ci`. The CI manifest overrides the developer's providers and defaults. Tests run against Ollama.

### Production with Vault

```yaml
# /etc/casehub/agent-config.yaml
providers:
  - vendor: anthropic
    credential: ref:vault/casehub/anthropic-api-key
  - vendor: vertex
    credential:
      project-id: ref:vault/casehub/gcp-project
      location: ref:vault/casehub/gcp-location
      service-account-json: ref:vault/casehub/gcp-service-account
sources:
  - uri: https://internal.corp/approved-models.json
    priority: 40
defaults:
  backend: claude
```

### Project with corporate catalog and custom models

```yaml
# ./agent-config.yaml
sources:
  - uri: https://models.acme.corp/catalog.json
    priority: 40
models:
  - id: acme-legal-ft
    apiModelId: ft:gpt-4-0613:acme:legal:abc123
    backendKey: openai
    vendor: openai
    family: gpt-4
    displayName: ACME Legal Fine-Tune
    tier: STANDARD
    capabilities: [text]
    contextWindow: 128000
    maxOutput: 16384
    locality: CLOUD
    costTier: MEDIUM
    authMethod: api-key
aliases:
  legal-analysis:
    vendor: openai
    family: gpt-4
    capabilities: [text]
```

## Unification

The manifest unifies existing independent mechanisms:

| Before (independent) | After (manifest-driven) |
|---|---|
| SeedCatalogModelSource (hardcoded classpath) | `classpath:` resource in chain (priority 0) |
| CloudModelSource (hardcoded per-vendor) | Activated by `providers:` section |
| ConfiguredModelSource (from REST calls) | Activated by `providers:` section |
| OllamaModelSource (hardcoded local) | Activated by `providers:` + reconciled by `local-models:` |
| CloudSourceCredentialBootstrap (hardcoded env detection) | `credential: env:VAR` in manifest |
| LlmConfigService.configure() (imperative) | `providers:` section (declarative). LlmConfigService stays for runtime/tenant-scoped use. |
| ModelRef.forTier() (single dimension) | Aliases (multi-constraint, environment-varying) |

## What's New vs What's Extended vs What's Unchanged

**New (the glue layer):**
- `Manifest` record type
- `ManifestLoader` — discovers, parses, merges resources (with cycle detection, depth limits)
- `ManifestProcessor` — drives existing SPIs from merged manifest
- `ManifestResult` — CDI-produced record carrying aliases, vendor preferences, default backend
- `ManifestCredentialResolver` — prefix-based credential reference resolution
- `model-selection.schema.json` — JSON Schema for type-safe YAML
- Alias registry + vendor preference map in RoutingAgentProvider

**Extended:**
- `ModelQuery` — add `minContextWindow`, `minMaxOutput`
- `RoutingAgentProvider` — new constructor with aliases + vendor preferences; `resolve()` gains alias lookup step
- `AgentSessionConfig` — add `withModel(String)` method

**Deprecated:**
- `CloudSourceCredentialBootstrap` — disabled when manifest processing is active; superseded by manifest `providers:` section

**Unchanged:**
- ModelSource, ModelRegistry, MutableModelRegistry
- LlmCredentialStore, BackendInstanceRegistry, BackendInstanceCoordinator
- All AgentBackend implementations (Claude, OpenAI, Ollama, Gemini, etc.)
- LlmConfigService (stays as imperative API)
- SeedCatalogModelSource, CloudModelSource, OllamaModelSource

## Downstream

- **CloudSourceCredentialBootstrap** is disabled when manifest processing is active (`@IfBuildProperty(name = "casehub.agent.manifest.enabled", stringValue = "true", enableIfMissing = false)`) and deprecated. Note: `CloudSourceCredentialBootstrap.detectAndSeed()` is currently not wired to any startup observer in production code (only called from tests), so there is no runtime coexistence conflict. The manifest subsumes its function entirely — credential detection via `providers:` section replaces the hardcoded env var detection.
- **Eidos integration** — eidos case definitions `$ref` the model-selection schema for task-level model requirements. Follow-on issue after schema is published.
- **Org descriptor integration** — org roles reference model selection for agent assignment. Follow-on issue.
- **Web app implementation** — separate issue. This spec defines the schema and pipeline it consumes.

## References

- `platform-api/src/main/java/io/casehub/platform/api/model/` — ModelDescriptor, ModelQuery, ModelRef, ModelSource, ModelRegistry, MutableModelRegistry
- `platform-api/src/main/java/io/casehub/platform/api/credentials/LlmCredentialStore.java` — credential store SPI
- `platform-api/src/main/java/io/casehub/platform/api/credentials/CredentialResolver.java` — credential resolution SPI
- `agent-router-core/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java` — model resolution
- `agent-router/src/main/java/io/casehub/platform/agent/router/BackendInstanceCoordinator.java` — startup backend wiring
- `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigService.java` — imperative config API
- `credentials-quarkus/` — CredentialResolver → Quarkus CredentialsProvider bridge
- `platform/src/main/resources/models/seed-catalog.yaml` — seed catalog (17 models, 5 vendors)
- `schema-generator/src/main/java/io/casehub/schema/generator/module/ShorthandModule.java` — string-or-object union support
- Spec: `issue-286-model-registry-spi/2026-09-11-model-registry-spi-design.md`
- Spec: `issue-291-llm-config-wizard-api/2026-09-12-llm-config-wizard-api-design.md`
- Spec: `issue-298-model-tier-agent-bridge/2026-09-14-model-tier-agent-bridge-design.md`
- Spec: `issue-288-cloud-model-sources/2026-09-12-cloud-model-sources-design.md`
