# Model Registry SPI — Design Spec

**Issues:** casehubio/platform#286, #287
**Date:** 2026-09-11
**Status:** Draft

## Summary

Queryable LLM model registry — the foundation of epic #285. Three deliverables:

1. **SPIs in platform-api** — `ModelDescriptor` (normalized model metadata with typed dimensions), `ModelRegistry` (query by dimensions, resolve by ID), `ModelSource` (pull-based refresh), `ModelQuery` (predicate record), enums (`ModelTier`, `ModelLocality`, `CostTier`), `ModelCapabilities` (string constants), `ModelCatalogChangedEvent` (CDI event on catalog change)
2. **Implementation in platform** — `InMemoryModelRegistry` (per-source maps with priority-resolved view), `ModelRegistryRefresher` (@Scheduled periodic refresh), `RoutingAgentProvider` integration (three-step model reference resolution), `DomainModelRegistry` rename (MCP naming collision)
3. **Seed catalog (#287)** — committed YAML with known models from major vendors, `SeedCatalogModelSource` implementation

The registry is a normalized cache — vendor listing APIs are the source of truth. The seed catalog provides initial data and air-gapped fallback.

## Layer Model

This work is **Layer 2: Model Selection** in the epic #285 three-layer architecture:

```
Layer 3: Agent Selection (eidos)     — "Which agent can do this task?"
Layer 2: Model Selection (THIS)      — "Which model should back this agent/task?"
Layer 1: Model Execution (existing)  — "Send this prompt to a model and get a response."
```

**Boundary rules:**
- ModelDescriptor dimensions ≠ AgentCapability dimensions (raw model capabilities vs task-level skills)
- ModelRegistry does not match tasks to models (that's eidos)
- `AgentDescriptor.modelFamily` references `ModelDescriptor.family` (Layer 3 → Layer 2 foreign key)
- RoutingAgentProvider dispatches by resolved model, not by capability query

---

## Part 1: SPIs in platform-api (#286)

All types in `io.casehub.platform.api.model`. Zero dependencies — pure Java records, interfaces, and enums.

### Enums

```java
public enum ModelTier {
    FLAGSHIP,    // Opus, GPT-4.1, Gemini Ultra
    STANDARD,    // Sonnet, GPT-4o, Gemini Pro
    FAST,        // Haiku, GPT-4o-mini, Gemini Flash
    EMBEDDING    // text-embedding-3, embedding models
}

public enum ModelLocality {
    CLOUD,
    LOCAL
}

public enum CostTier {
    FREE(0), LOW(1), MEDIUM(2), HIGH(3), PREMIUM(4);

    private final int rank;
    CostTier(int rank) { this.rank = rank; }
    public int rank() { return rank; }
}
```

### ModelCapabilities (string constants)

```java
public final class ModelCapabilities {
    public static final String TEXT = "text";
    public static final String VISION = "vision";
    public static final String TOOL_USE = "tool-use";
    public static final String CODE = "code";
    public static final String REASONING = "reasoning";

    private ModelCapabilities() {}
}
```

Capabilities use `Set<String>` with well-known constants rather than a fixed enum. New capabilities (audio, structured output, computer use, image generation, batch, realtime) emerge on a months-to-weeks cadence — a fixed enum in `platform-api` would create version pressure across the entire ecosystem. String constants provide IDE discoverability and type-safe references for well-known values while allowing `ModelSource` implementations to declare new capabilities without a `platform-api` release. This follows the `EndpointPropertyKeys` pattern established in the endpoint registry.

### ModelDescriptor

```java
public record ModelDescriptor(
    String id,                          // "claude-sonnet-5", "gpt-4.1", "llama-4-scout"
    String backendKey,                  // AgentBackend.key() → "claude", "openai", "ollama"
    String vendor,                      // "anthropic", "openai", "google", "meta"
    String family,                      // "claude", "gpt-4", "gemini", "llama"
    String displayName,                 // "Claude Sonnet 5"
    ModelTier tier,                     // FLAGSHIP, STANDARD, FAST, EMBEDDING
    Set<String> capabilities,           // ModelCapabilities.TEXT, .VISION, .TOOL_USE, etc.
    int contextWindow,                  // 200000
    int maxOutput,                      // 16384
    ModelLocality locality,             // CLOUD, LOCAL
    CostTier costTier,                  // nullable — null = unknown cost, excluded from maxCostTier queries
    String authMethod,                  // "api-key", "vertex", "bedrock", "local"
    Map<String, String> properties      // extensible vendor-specific metadata
) {
    public ModelDescriptor {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(backendKey, "backendKey");
        Objects.requireNonNull(vendor, "vendor");
        Objects.requireNonNull(family, "family");
        Objects.requireNonNull(displayName, "displayName");
        Objects.requireNonNull(tier, "tier");
        Objects.requireNonNull(locality, "locality");
        capabilities = capabilities != null ? Set.copyOf(capabilities) : Set.of();
        properties = properties != null ? Map.copyOf(properties) : Map.of();
    }
}
```

**Null semantics:** `costTier` and `authMethod` are nullable. A null `costTier` means unknown cost — excluded from `maxCostTier`-constrained queries but included in unconstrained queries (`maxCostTier = null`). A null `authMethod` means unspecified access method.

**`family`** groups models by product lineage, distinct from `vendor`:
- Anthropic: vendor=`"anthropic"`, family=`"claude"` (Haiku, Sonnet, Opus)
- OpenAI: vendor=`"openai"`, family=`"gpt-4"` or `"o3"`
- Google: vendor=`"google"`, family=`"gemini"`
- Meta: vendor=`"meta"`, family=`"llama"`

**`backendKey`** is the foreign key to `AgentBackend.key()` — the execution backend that serves this model. Each `ModelSource` knows which backend serves its models.

### ModelQuery

```java
public record ModelQuery(
    String vendor,                          // null = any
    String family,                          // null = any
    ModelTier tier,                         // null = any
    Set<String> requiredCapabilities,       // empty = any
    ModelLocality locality,                 // null = any
    CostTier maxCostTier,                   // null = any
    String authMethod                       // null = any
) {
    public ModelQuery {
        requiredCapabilities = requiredCapabilities != null
            ? Set.copyOf(requiredCapabilities) : Set.of();
    }

    public static ModelQuery all() {
        return new ModelQuery(null, null, null, Set.of(), null, null, null);
    }

    public static Builder builder() { return new Builder(); }

    public static final class Builder {
        private String vendor;
        private String family;
        private ModelTier tier;
        private Set<String> requiredCapabilities = Set.of();
        private ModelLocality locality;
        private CostTier maxCostTier;
        private String authMethod;

        public Builder vendor(String vendor) { this.vendor = vendor; return this; }
        public Builder family(String family) { this.family = family; return this; }
        public Builder tier(ModelTier tier) { this.tier = tier; return this; }
        public Builder requiredCapabilities(Set<String> caps) {
            this.requiredCapabilities = caps; return this;
        }
        public Builder locality(ModelLocality locality) { this.locality = locality; return this; }
        public Builder maxCostTier(CostTier maxCostTier) { this.maxCostTier = maxCostTier; return this; }
        public Builder authMethod(String authMethod) { this.authMethod = authMethod; return this; }
        public ModelQuery build() {
            return new ModelQuery(vendor, family, tier, requiredCapabilities,
                locality, maxCostTier, authMethod);
        }
    }
}
```

### ModelRegistry

```java
public interface ModelRegistry {
    Optional<ModelDescriptor> resolveById(String modelId);
    List<ModelDescriptor> query(ModelQuery query);
    List<ModelDescriptor> all();
}
```

`resolveById` is the fast path — O(1) lookup used by RoutingAgentProvider. `query` returns all matching descriptors. `all()` returns the full catalog.

### ModelSource

```java
public interface ModelSource {
    String sourceId();
    int priority();
    List<ModelDescriptor> refresh();
}
```

`sourceId` — stable identifier (e.g., `"seed-catalog"`, `"anthropic-api"`). `priority` — higher value wins when two sources provide the same model ID. `refresh()` — returns the complete current catalog from this source. Called periodically by the registry.

### ModelCatalogChangedEvent

```java
public record ModelCatalogChangedEvent(
    String sourceId,
    Set<String> addedIds,
    Set<String> removedIds,
    Set<String> updatedIds
) {
    public ModelCatalogChangedEvent {
        addedIds = addedIds != null ? Set.copyOf(addedIds) : Set.of();
        removedIds = removedIds != null ? Set.copyOf(removedIds) : Set.of();
        updatedIds = updatedIds != null ? Set.copyOf(updatedIds) : Set.of();
    }

    public boolean hasChanges() {
        return !addedIds.isEmpty() || !removedIds.isEmpty() || !updatedIds.isEmpty();
    }
}
```

Fired as a CDI event when a source refresh results in actual catalog changes. Carries the IDs of changed models to enable targeted cache invalidation without full-catalog diffing. Counts are trivially derived from set sizes. Follows platform's event-on-mutation pattern (`EndpointRegistered`, `DataSourceUpdated`).

---

## Part 2: Implementation in platform (#286)

### InMemoryModelRegistry

```java
@ApplicationScoped
public class InMemoryModelRegistry implements ModelRegistry {
    // Per-source storage: sourceId → (modelId → descriptor)
    private final ConcurrentHashMap<String, ConcurrentHashMap<String, ModelDescriptor>> sources
        = new ConcurrentHashMap<>();

    // Priority-ordered source list
    private final List<String> sourceOrder = new CopyOnWriteArrayList<>();

    // Cached flattened view — rebuilt on each source refresh
    private volatile Map<String, ModelDescriptor> resolvedView = Map.of();
}
```

**Storage:** `ConcurrentHashMap<sourceId, ConcurrentHashMap<modelId, ModelDescriptor>>`. Per-source maps enable atomic replacement per source without affecting others.

**Priority resolution:** Sources ordered by `ModelSource.priority()` (descending). When two sources provide the same model ID, the higher-priority source wins. The resolved view is a flattened `Map<String, ModelDescriptor>` rebuilt after each source refresh — O(1) lookups for `resolveById`.

**Query implementation:** Filters the resolved view by matching each non-null `ModelQuery` predicate. `maxCostTier` matches descriptors where `descriptor.costTier() != null && descriptor.costTier().rank() <= maxCostTier.rank()` — descriptors with null `costTier` are excluded from cost-constrained queries. `requiredCapabilities` checks `descriptor.capabilities().containsAll(required)`. `authMethod` matches descriptors with `descriptor.authMethod().equals(query.authMethod())`.

### ModelRegistryRefresher

```java
@ApplicationScoped
public class ModelRegistryRefresher {
    @Inject @Any Instance<ModelSource> sources;
    @Inject InMemoryModelRegistry registry;
    @Inject Event<ModelCatalogChangedEvent> catalogChanged;

    @Startup
    void initialRefresh() { refreshAll(); }

    @Scheduled(every = "${casehub.model.registry.refresh-interval:1h}")
    void scheduledRefresh() { refreshAll(); }

    void refreshAll() {
        for (ModelSource source : sources) {
            try {
                List<ModelDescriptor> models = source.refresh();
                var delta = registry.replaceSource(source.sourceId(), source.priority(), models);
                if (delta.hasChanges()) {
                    catalogChanged.fire(new ModelCatalogChangedEvent(
                        source.sourceId(), delta.addedIds(), delta.removedIds(), delta.updatedIds()));
                }
            } catch (Exception e) {
                LOG.warnf("Model source '%s' refresh failed: %s", source.sourceId(), e.getMessage());
            }
        }
    }
}
```

Error-isolated per source — one source failing doesn't block others. `ModelCatalogChangedEvent` fired only on actual catalog change.

### RoutingAgentProvider changes

The `resolve(String model)` method gains a three-step resolution contract with config rewriting. Resolution returns both the backend and the rewritten model string:

```java
private record ResolvedRoute(AgentBackend backend, String apiModelId) {}

private ResolvedRoute resolve(String model) {
    if (model == null) {
        if (defaultBackend == null) {
            throw new IllegalStateException(
                "No default backend configured — set casehub.platform.agent.default-backend");
        }
        return new ResolvedRoute(defaultBackend, null);
    }

    // Step 1: Registry path — model ID from descriptor, backend from backendKey
    Optional<ModelDescriptor> descriptor = modelRegistry.resolveById(model);
    if (descriptor.isPresent()) {
        AgentBackend backend = backends.get(descriptor.get().backendKey());
        if (backend == null) {
            throw new IllegalStateException(
                "ModelRegistry resolved '" + model + "' to backend '" +
                descriptor.get().backendKey() + "', but no backend with that key is available");
        }
        return new ResolvedRoute(backend, descriptor.get().id());
    }

    // Step 2: Key-based path — model nulled so backend uses its configured default
    AgentBackend backend = backends.get(model);
    if (backend != null) return new ResolvedRoute(backend, null);

    // Step 3: Fail-fast
    throw new IllegalArgumentException("No model or backend for: " + model +
        ". Available backends: " + backends.keySet());
}
```

Callers construct rewritten configs with the resolved model:

```java
@Override
public Multi<AgentEvent> invoke(AgentSessionConfig config) {
    var route = resolve(config.model());
    var rewritten = new AgentSessionConfig(
        config.systemPrompt(), config.userPrompt(), config.mcpServers(),
        config.timeout(), config.correlationId(), route.apiModelId());
    return route.backend().invoke(rewritten);
}

@Override
public AgentSession openSession(AgentSessionInit init) {
    var route = resolve(init.model());
    var rewritten = new AgentSessionInit(
        init.systemPrompt(), init.mcpServers(),
        init.timeout(), init.correlationId(), route.apiModelId());
    return route.backend().openSession(rewritten);
}
```

Config rewriting eliminates semantic overloading: backends always receive either a model-specific API identifier (e.g., `"claude-sonnet-5"` from the registry) or `null` (backend uses its configured default). The key-based path nulls the model so backends that previously read `config.model()` as both routing key and API identifier now correctly fall through to their configured default.

`ModelRegistry` injected via CDI. `InMemoryModelRegistry` is always on the classpath (it's in `platform/`). With no `ModelSource` beans, it returns empty and the router falls through to key-based dispatch (current behavior preserved).

### DomainModelRegistry rename

The existing `io.casehub.platform.mcp.ModelRegistry` (a registry of `DomainModel` objects for MCP domain-index resources) is renamed to `DomainModelRegistry` to resolve the naming collision. Five production consumers and one test reference the class:

| File | Usage |
|------|-------|
| `DomainResourceRegistrar.java` | `ModelRegistry modelRegistry` field |
| `CaseHubMcpTools.java` | `ModelRegistry registry` field |
| `ReflectiveOperationDispatcher.java` | `ModelRegistry registry` field |
| `GraphQLModelScanner.java` | `ModelRegistry registry` field |
| `DynamicToolRegistrar.java` | `ModelRegistry registry` field |
| `GraphQLModelScannerTest.java` | `ModelRegistry registry` field |

All updates are mechanical — rename the type reference in each injection site.

---

## Part 3: Seed catalog (#287)

### YAML format

`platform/src/main/resources/models/seed-catalog.yaml`:

```yaml
models:
  # --- Anthropic (Claude 5 family) ---
  - id: claude-opus-5
    backendKey: claude
    vendor: anthropic
    family: claude
    displayName: Claude Opus 5
    tier: FLAGSHIP
    capabilities: [text, vision, tool-use, code, reasoning]
    contextWindow: 200000
    maxOutput: 32768
    locality: CLOUD
    costTier: PREMIUM
    authMethod: api-key

  - id: claude-sonnet-5
    backendKey: claude
    vendor: anthropic
    family: claude
    displayName: Claude Sonnet 5
    tier: STANDARD
    capabilities: [text, vision, tool-use, code, reasoning]
    contextWindow: 200000
    maxOutput: 16384
    locality: CLOUD
    costTier: HIGH
    authMethod: api-key

  - id: claude-fable-5-1
    backendKey: claude
    vendor: anthropic
    family: claude
    displayName: Claude Fable 5.1
    tier: STANDARD
    capabilities: [text, vision, tool-use, code, reasoning]
    contextWindow: 200000
    maxOutput: 16384
    locality: CLOUD
    costTier: MEDIUM
    authMethod: api-key

  # --- Anthropic (Claude 4 family) ---
  - id: claude-opus-4-6
    backendKey: claude
    vendor: anthropic
    family: claude
    displayName: Claude Opus 4.6
    tier: FLAGSHIP
    capabilities: [text, vision, tool-use, code, reasoning]
    contextWindow: 200000
    maxOutput: 32768
    locality: CLOUD
    costTier: PREMIUM
    authMethod: api-key

  - id: claude-opus-4
    backendKey: claude
    vendor: anthropic
    family: claude
    displayName: Claude Opus 4
    tier: FLAGSHIP
    capabilities: [text, vision, tool-use, code, reasoning]
    contextWindow: 200000
    maxOutput: 32768
    locality: CLOUD
    costTier: PREMIUM
    authMethod: api-key

  - id: claude-sonnet-4
    backendKey: claude
    vendor: anthropic
    family: claude
    displayName: Claude Sonnet 4
    tier: STANDARD
    capabilities: [text, vision, tool-use, code, reasoning]
    contextWindow: 200000
    maxOutput: 16384
    locality: CLOUD
    costTier: HIGH
    authMethod: api-key

  - id: claude-haiku-4-5
    backendKey: claude
    vendor: anthropic
    family: claude
    displayName: Claude Haiku 4.5
    tier: FAST
    capabilities: [text, vision, tool-use, code]
    contextWindow: 200000
    maxOutput: 8192
    locality: CLOUD
    costTier: LOW
    authMethod: api-key

  # --- OpenAI ---
  - id: gpt-4.1
    backendKey: openai
    vendor: openai
    family: gpt-4
    displayName: GPT-4.1
    tier: STANDARD
    capabilities: [text, vision, tool-use, code, reasoning]
    contextWindow: 1048576
    maxOutput: 32768
    locality: CLOUD
    costTier: MEDIUM
    authMethod: api-key

  - id: o3
    backendKey: openai
    vendor: openai
    family: o3
    displayName: o3
    tier: FLAGSHIP
    capabilities: [text, tool-use, code, reasoning]
    contextWindow: 200000
    maxOutput: 100000
    locality: CLOUD
    costTier: PREMIUM
    authMethod: api-key

  - id: o4-mini
    backendKey: openai
    vendor: openai
    family: o4
    displayName: o4-mini
    tier: FAST
    capabilities: [text, vision, tool-use, code, reasoning]
    contextWindow: 200000
    maxOutput: 100000
    locality: CLOUD
    costTier: LOW
    authMethod: api-key

  - id: gpt-4o-mini
    backendKey: openai
    vendor: openai
    family: gpt-4
    displayName: GPT-4o mini
    tier: FAST
    capabilities: [text, vision, tool-use, code]
    contextWindow: 128000
    maxOutput: 16384
    locality: CLOUD
    costTier: LOW
    authMethod: api-key

  # --- Google ---
  - id: gemini-2.5-pro
    backendKey: gemini
    vendor: google
    family: gemini
    displayName: Gemini 2.5 Pro
    tier: STANDARD
    capabilities: [text, vision, tool-use, code, reasoning]
    contextWindow: 1048576
    maxOutput: 65536
    locality: CLOUD
    costTier: MEDIUM
    authMethod: api-key

  - id: gemini-2.5-flash
    backendKey: gemini
    vendor: google
    family: gemini
    displayName: Gemini 2.5 Flash
    tier: FAST
    capabilities: [text, vision, tool-use, code]
    contextWindow: 1048576
    maxOutput: 65536
    locality: CLOUD
    costTier: LOW
    authMethod: api-key

  # --- Meta (local) ---
  - id: llama-4-scout
    backendKey: ollama
    vendor: meta
    family: llama
    displayName: Llama 4 Scout
    tier: STANDARD
    capabilities: [text, vision, tool-use, code]
    contextWindow: 131072
    maxOutput: 16384
    locality: LOCAL
    costTier: FREE
    authMethod: local

  - id: llama-4-maverick
    backendKey: ollama
    vendor: meta
    family: llama
    displayName: Llama 4 Maverick
    tier: FLAGSHIP
    capabilities: [text, vision, tool-use, code, reasoning]
    contextWindow: 131072
    maxOutput: 16384
    locality: LOCAL
    costTier: FREE
    authMethod: local

  # --- Mistral ---
  - id: mistral-large
    backendKey: mistral
    vendor: mistral
    family: mistral
    displayName: Mistral Large
    tier: FLAGSHIP
    capabilities: [text, vision, tool-use, code, reasoning]
    contextWindow: 131072
    maxOutput: 16384
    locality: CLOUD
    costTier: MEDIUM
    authMethod: api-key

  - id: codestral
    backendKey: mistral
    vendor: mistral
    family: codestral
    displayName: Codestral
    tier: STANDARD
    capabilities: [text, tool-use, code]
    contextWindow: 262144
    maxOutput: 16384
    locality: CLOUD
    costTier: LOW
    authMethod: api-key
```

### SeedCatalogModelSource

```java
@ApplicationScoped
public class SeedCatalogModelSource implements ModelSource {

    private static final String CATALOG_PATH = "models/seed-catalog.yaml";

    @Override
    public String sourceId() { return "seed-catalog"; }

    @Override
    public int priority() { return 0; }  // lowest — live sources override

    @Override
    public List<ModelDescriptor> refresh() {
        try (InputStream is = Thread.currentThread().getContextClassLoader()
                .getResourceAsStream(CATALOG_PATH)) {
            if (is == null) return List.of();
            return parseCatalog(is);
        } catch (IOException e) {
            LOG.warnf("Failed to read seed catalog: %s", e.getMessage());
            return List.of();
        }
    }
}
```

Priority 0 — lowest. Any live API source (priority > 0) overrides seed entries for the same model ID. The seed catalog is updated manually via PRs when new models launch or specs change.

---

## Test strategy

### Part 1 — SPI types (platform-api)

1. `ModelDescriptor` — defensive copies on capabilities and properties, null validation on required fields (`id`, `backendKey`, `vendor`, `family`, `displayName`, `tier`, `locality`), nullable `costTier` and `authMethod`
2. `ModelQuery.all()` — matches everything
3. `ModelQuery.builder()` — each dimension filter works independently, including `authMethod`
4. `ModelCatalogChangedEvent` — record construction, `hasChanges()` logic, defensive copies on ID sets
5. `CostTier.rank()` — explicit rank values survive enum reordering

### Part 2 — Implementation (platform)

6. `InMemoryModelRegistry.resolveById` — returns descriptor for known ID, empty for unknown
7. `InMemoryModelRegistry.query` — filters by vendor, family, tier, capabilities, locality, maxCostTier, authMethod
8. `InMemoryModelRegistry.query` — null costTier on descriptor excluded from maxCostTier-constrained queries
9. `InMemoryModelRegistry` with zero sources — resolveById returns empty, query returns empty, all returns empty
10. `InMemoryModelRegistry.replaceSource` — atomic per-source replacement, doesn't affect other sources
11. Priority resolution — higher-priority source wins for same model ID
12. Priority shadowing — removing higher-priority entry exposes lower-priority
13. `ModelRegistryRefresher` — calls refresh on all sources, fires event with correct IDs on change, error-isolated
14. `RoutingAgentProvider` — registry path resolves model ID to backend with config rewriting, key-based fallback nulls model, fail-fast for unknown
15. `RoutingAgentProvider` — both `invoke()` and `openSession()` paths produce rewritten configs

### Part 3 — Seed catalog (platform)

16. `SeedCatalogModelSource.refresh()` — parses YAML, returns descriptors with correct fields including `authMethod`
17. Seed catalog YAML — all entries parse without error, no duplicate IDs
18. Integration — seed entries resolve via `InMemoryModelRegistry.resolveById`

---

## Files changed

### Part 1 — platform-api (new package `io.casehub.platform.api.model`)

| File | Action |
|------|--------|
| `platform-api/src/main/java/io/casehub/platform/api/model/ModelDescriptor.java` | New |
| `platform-api/src/main/java/io/casehub/platform/api/model/ModelTier.java` | New |
| `platform-api/src/main/java/io/casehub/platform/api/model/ModelCapabilities.java` | New |
| `platform-api/src/main/java/io/casehub/platform/api/model/ModelLocality.java` | New |
| `platform-api/src/main/java/io/casehub/platform/api/model/CostTier.java` | New |
| `platform-api/src/main/java/io/casehub/platform/api/model/ModelRegistry.java` | New |
| `platform-api/src/main/java/io/casehub/platform/api/model/ModelSource.java` | New |
| `platform-api/src/main/java/io/casehub/platform/api/model/ModelQuery.java` | New |
| `platform-api/src/main/java/io/casehub/platform/api/model/ModelCatalogChangedEvent.java` | New |
| `platform-api/src/test/java/io/casehub/platform/api/model/ModelDescriptorTest.java` | New |
| `platform-api/src/test/java/io/casehub/platform/api/model/ModelQueryTest.java` | New |

### Part 2 — platform (package `io.casehub.platform.model`)

| File | Action |
|------|--------|
| `platform/src/main/java/io/casehub/platform/model/InMemoryModelRegistry.java` | New |
| `platform/src/main/java/io/casehub/platform/model/ModelRegistryRefresher.java` | New |
| `platform/src/main/java/io/casehub/platform/model/SeedCatalogModelSource.java` | New |
| `platform/src/main/resources/models/seed-catalog.yaml` | New |
| `platform/src/test/java/io/casehub/platform/model/InMemoryModelRegistryTest.java` | New |
| `platform/src/test/java/io/casehub/platform/model/SeedCatalogModelSourceTest.java` | New |

### Part 2 — agent-router (modified)

| File | Action |
|------|--------|
| `agent-router/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java` | Modified — three-step resolution |
| `agent-router/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderTest.java` | Modified — registry resolution tests |

### Part 2 — mcp (rename)

| File | Action |
|------|--------|
| `mcp/src/main/java/io/casehub/platform/mcp/ModelRegistry.java` → `DomainModelRegistry.java` | Rename |
| `mcp/src/main/java/io/casehub/platform/mcp/DomainResourceRegistrar.java` | Modified — update reference |
| `mcp/src/main/java/io/casehub/platform/mcp/CaseHubMcpTools.java` | Modified — update reference |
| `mcp/src/main/java/io/casehub/platform/mcp/ReflectiveOperationDispatcher.java` | Modified — update reference |
| `mcp/src/main/java/io/casehub/platform/mcp/GraphQLModelScanner.java` | Modified — update reference |
| `mcp/src/main/java/io/casehub/platform/mcp/DynamicToolRegistrar.java` | Modified — update reference |
| `mcp/src/test/java/io/casehub/platform/mcp/GraphQLModelScannerTest.java` | Modified — update reference |

### Part 2 — architectural documentation

| File | Action |
|------|--------|
| `ARC42STORIES.MD` | Modified — §1 core capabilities, §5 building block view, §9 chapter index |

---

## Downstream (not this branch)

| Issue | Repo | Dependency |
|-------|------|------------|
| #288 | platform | Cloud model sources (Anthropic, OpenAI, Vertex, Bedrock) |
| #289 | platform | Local model sources (Ollama, HuggingFace) |
| #290 | platform | Multi-instance backend support |
| #291 | platform | Configuration wizard API |
| #292 | platform | MCP tools for model registry |
| eidos#172 | eidos | Vocabulary-based model selection |

## References

- `io.casehub.platform.agent.AgentBackend` — `key()` method, backendKey foreign key target
- `io.casehub.platform.agent.AgentProvider` — consumer SPI (Layer 1)
- `io.casehub.platform.agent.AgentSessionConfig` — `model` field semantics
- `io.casehub.platform.agent.router.RoutingAgentProvider` — current resolve() method, integration point
- `io.casehub.platform.mcp.ModelRegistry` — existing class to rename (DomainModelRegistry)
- `io.casehub.platform.mcp.DomainResourceRegistrar` — one of five production consumers of existing ModelRegistry
- casehubio/platform#285 — LLM model registry epic (layer model, boundary rules)
- casehubio/eidos AgentDescriptor — modelFamily/modelVersion fields (Layer 3 → Layer 2 binding, D6)
- Anthropic `/v1/models` API — cloud model listing reference
- OpenAI `/v1/models` API — cloud model listing reference
