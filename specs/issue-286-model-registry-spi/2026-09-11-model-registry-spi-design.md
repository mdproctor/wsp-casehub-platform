# Model Registry SPI — Design Spec

**Issues:** casehubio/platform#286, #287
**Date:** 2026-09-11
**Status:** Draft

## Summary

Queryable LLM model registry — the foundation of epic #285. Three deliverables:

1. **SPIs in platform-api** — `ModelDescriptor` (normalized model metadata with typed dimensions), `ModelRegistry` (query by dimensions, resolve by ID), `ModelSource` (pull-based refresh), `ModelQuery` (predicate record), enums (`ModelTier`, `ModelCapability`, `ModelLocality`, `CostTier`), `ModelCatalogChangedEvent` (CDI event on catalog change)
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

public enum ModelCapability {
    TEXT,
    VISION,
    TOOL_USE,
    CODE,
    REASONING
}

public enum ModelLocality {
    CLOUD,
    LOCAL
}

public enum CostTier {
    FREE,
    LOW,
    MEDIUM,
    HIGH,
    PREMIUM
}
```

### ModelDescriptor

```java
public record ModelDescriptor(
    String id,                          // "claude-sonnet-5", "gpt-4.1", "llama-4-scout"
    String backendKey,                  // AgentBackend.key() → "claude", "openai", "ollama"
    String vendor,                      // "anthropic", "openai", "google", "meta"
    String family,                      // "claude", "gpt-4", "gemini", "llama"
    String displayName,                 // "Claude Sonnet 5"
    ModelTier tier,                     // FLAGSHIP, STANDARD, FAST, EMBEDDING
    Set<ModelCapability> capabilities,  // TEXT, VISION, TOOL_USE, CODE, REASONING
    int contextWindow,                  // 200000
    int maxOutput,                      // 16384
    ModelLocality locality,             // CLOUD, LOCAL
    CostTier costTier,                  // FREE, LOW, MEDIUM, HIGH, PREMIUM
    Map<String, String> properties      // extensible vendor-specific metadata
) {
    public ModelDescriptor {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(backendKey, "backendKey");
        Objects.requireNonNull(vendor, "vendor");
        Objects.requireNonNull(family, "family");
        capabilities = capabilities != null ? Set.copyOf(capabilities) : Set.of();
        properties = properties != null ? Map.copyOf(properties) : Map.of();
    }
}
```

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
    Set<ModelCapability> requiredCapabilities,  // empty = any
    ModelLocality locality,                 // null = any
    CostTier maxCostTier                   // null = any
) {
    public ModelQuery {
        requiredCapabilities = requiredCapabilities != null
            ? Set.copyOf(requiredCapabilities) : Set.of();
    }

    public static ModelQuery all() {
        return new ModelQuery(null, null, null, Set.of(), null, null);
    }

    public static Builder builder() { return new Builder(); }

    public static final class Builder {
        private String vendor;
        private String family;
        private ModelTier tier;
        private Set<ModelCapability> requiredCapabilities = Set.of();
        private ModelLocality locality;
        private CostTier maxCostTier;

        public Builder vendor(String vendor) { this.vendor = vendor; return this; }
        public Builder family(String family) { this.family = family; return this; }
        public Builder tier(ModelTier tier) { this.tier = tier; return this; }
        public Builder requiredCapabilities(Set<ModelCapability> caps) {
            this.requiredCapabilities = caps; return this;
        }
        public Builder locality(ModelLocality locality) { this.locality = locality; return this; }
        public Builder maxCostTier(CostTier maxCostTier) { this.maxCostTier = maxCostTier; return this; }
        public ModelQuery build() {
            return new ModelQuery(vendor, family, tier, requiredCapabilities, locality, maxCostTier);
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
    int added,
    int removed,
    int updated
) {}
```

Fired as a CDI event when a source refresh results in actual catalog changes. Follows platform's event-on-mutation pattern (`EndpointRegistered`, `DataSourceUpdated`).

---

## Part 2: Implementation in platform (#286)

### NoOpModelRegistry (@DefaultBean)

```java
@DefaultBean
@ApplicationScoped
public class NoOpModelRegistry implements ModelRegistry {
    @Override public Optional<ModelDescriptor> resolveById(String modelId) {
        return Optional.empty();
    }
    @Override public List<ModelDescriptor> query(ModelQuery query) {
        return List.of();
    }
    @Override public List<ModelDescriptor> all() {
        return List.of();
    }
}
```

Passthrough when no sources are on the classpath.

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

**Query implementation:** Filters the resolved view by matching each non-null `ModelQuery` predicate. `maxCostTier` matches descriptors with `costTier.ordinal() <= maxCostTier.ordinal()`. `requiredCapabilities` checks `descriptor.capabilities().containsAll(required)`.

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
                        source.sourceId(), delta.added(), delta.removed(), delta.updated()));
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

The `resolve(String model)` method gains a three-step resolution contract:

```java
private AgentBackend resolve(String model, AgentSessionConfig config) {
    if (model == null) {
        if (defaultBackend == null) {
            throw new IllegalStateException(
                "No default backend configured — set casehub.platform.agent.default-backend");
        }
        return defaultBackend;
    }

    // Step 1: Registry path
    Optional<ModelDescriptor> descriptor = modelRegistry.resolveById(model);
    if (descriptor.isPresent()) {
        AgentBackend backend = backends.get(descriptor.get().backendKey());
        if (backend == null) {
            throw new IllegalStateException(
                "ModelRegistry resolved '" + model + "' to backend '" +
                descriptor.get().backendKey() + "', but no backend with that key is available");
        }
        return backend;
    }

    // Step 2: Key-based path
    AgentBackend backend = backends.get(model);
    if (backend != null) return backend;

    // Step 3: Fail-fast
    throw new IllegalArgumentException("No model or backend for: " + model +
        ". Available backends: " + backends.keySet());
}
```

Config rewriting: when registry resolves, the original `AgentSessionConfig` is rebuilt with the model-specific API identifier from the descriptor (backends receive the specific model ID, not the routing reference). When key-based path matches, `model` is set to `null` so backends use their configured default.

`ModelRegistry` injected via CDI — when no `InMemoryModelRegistry` is on the classpath, the `@DefaultBean NoOpModelRegistry` returns empty and the router falls back to key-based dispatch (current behavior preserved).

### DomainModelRegistry rename

The existing `io.casehub.platform.mcp.ModelRegistry` (consumed by `DomainResourceRegistrar` for MCP domain-index resources) is renamed to `DomainModelRegistry` to resolve the naming collision. One consumer update + one test update.

---

## Part 3: Seed catalog (#287)

### YAML format

`platform/src/main/resources/models/seed-catalog.yaml`:

```yaml
models:
  # --- Anthropic ---
  - id: claude-opus-4
    backendKey: claude
    vendor: anthropic
    family: claude
    displayName: Claude Opus 4
    tier: FLAGSHIP
    capabilities: [TEXT, VISION, TOOL_USE, CODE, REASONING]
    contextWindow: 200000
    maxOutput: 32768
    locality: CLOUD
    costTier: PREMIUM

  - id: claude-sonnet-4
    backendKey: claude
    vendor: anthropic
    family: claude
    displayName: Claude Sonnet 4
    tier: STANDARD
    capabilities: [TEXT, VISION, TOOL_USE, CODE, REASONING]
    contextWindow: 200000
    maxOutput: 16384
    locality: CLOUD
    costTier: HIGH

  - id: claude-haiku-4-5
    backendKey: claude
    vendor: anthropic
    family: claude
    displayName: Claude Haiku 4.5
    tier: FAST
    capabilities: [TEXT, VISION, TOOL_USE, CODE]
    contextWindow: 200000
    maxOutput: 8192
    locality: CLOUD
    costTier: LOW

  # --- OpenAI ---
  - id: gpt-4.1
    backendKey: openai
    vendor: openai
    family: gpt-4
    displayName: GPT-4.1
    tier: STANDARD
    capabilities: [TEXT, VISION, TOOL_USE, CODE, REASONING]
    contextWindow: 1048576
    maxOutput: 32768
    locality: CLOUD
    costTier: MEDIUM

  - id: o3
    backendKey: openai
    vendor: openai
    family: o3
    displayName: o3
    tier: FLAGSHIP
    capabilities: [TEXT, TOOL_USE, CODE, REASONING]
    contextWindow: 200000
    maxOutput: 100000
    locality: CLOUD
    costTier: PREMIUM

  - id: gpt-4o-mini
    backendKey: openai
    vendor: openai
    family: gpt-4
    displayName: GPT-4o mini
    tier: FAST
    capabilities: [TEXT, VISION, TOOL_USE, CODE]
    contextWindow: 128000
    maxOutput: 16384
    locality: CLOUD
    costTier: LOW

  # --- Google ---
  - id: gemini-2.5-pro
    backendKey: gemini
    vendor: google
    family: gemini
    displayName: Gemini 2.5 Pro
    tier: STANDARD
    capabilities: [TEXT, VISION, TOOL_USE, CODE, REASONING]
    contextWindow: 1048576
    maxOutput: 65536
    locality: CLOUD
    costTier: MEDIUM

  - id: gemini-2.5-flash
    backendKey: gemini
    vendor: google
    family: gemini
    displayName: Gemini 2.5 Flash
    tier: FAST
    capabilities: [TEXT, VISION, TOOL_USE, CODE]
    contextWindow: 1048576
    maxOutput: 65536
    locality: CLOUD
    costTier: LOW

  # --- Meta (local) ---
  - id: llama-4-scout
    backendKey: ollama
    vendor: meta
    family: llama
    displayName: Llama 4 Scout
    tier: STANDARD
    capabilities: [TEXT, VISION, TOOL_USE, CODE]
    contextWindow: 131072
    maxOutput: 16384
    locality: LOCAL
    costTier: FREE

  - id: llama-4-maverick
    backendKey: ollama
    vendor: meta
    family: llama
    displayName: Llama 4 Maverick
    tier: FLAGSHIP
    capabilities: [TEXT, VISION, TOOL_USE, CODE, REASONING]
    contextWindow: 131072
    maxOutput: 16384
    locality: LOCAL
    costTier: FREE
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

1. `ModelDescriptor` — defensive copies on capabilities and properties, null validation on required fields
2. `ModelQuery.all()` — matches everything
3. `ModelQuery.builder()` — each dimension filter works independently
4. `ModelCatalogChangedEvent` — record construction

### Part 2 — Implementation (platform)

5. `NoOpModelRegistry` — resolveById returns empty, query returns empty, all returns empty
6. `InMemoryModelRegistry.resolveById` — returns descriptor for known ID, empty for unknown
7. `InMemoryModelRegistry.query` — filters by vendor, family, tier, capabilities, locality, maxCostTier
8. `InMemoryModelRegistry.replaceSource` — atomic per-source replacement, doesn't affect other sources
9. Priority resolution — higher-priority source wins for same model ID
10. Priority shadowing — removing higher-priority entry exposes lower-priority
11. `ModelRegistryRefresher` — calls refresh on all sources, fires event on change, error-isolated
12. `RoutingAgentProvider` — registry path resolves model ID to backend, key-based fallback, fail-fast for unknown

### Part 3 — Seed catalog (platform)

13. `SeedCatalogModelSource.refresh()` — parses YAML, returns descriptors with correct fields
14. Seed catalog YAML — all entries parse without error, no duplicate IDs
15. Integration — seed entries resolve via `InMemoryModelRegistry.resolveById`

---

## Files changed

### Part 1 — platform-api (new package `io.casehub.platform.api.model`)

| File | Action |
|------|--------|
| `platform-api/src/main/java/io/casehub/platform/api/model/ModelDescriptor.java` | New |
| `platform-api/src/main/java/io/casehub/platform/api/model/ModelTier.java` | New |
| `platform-api/src/main/java/io/casehub/platform/api/model/ModelCapability.java` | New |
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
| `platform/src/main/java/io/casehub/platform/model/NoOpModelRegistry.java` | New |
| `platform/src/main/java/io/casehub/platform/model/InMemoryModelRegistry.java` | New |
| `platform/src/main/java/io/casehub/platform/model/ModelRegistryRefresher.java` | New |
| `platform/src/main/java/io/casehub/platform/model/SeedCatalogModelSource.java` | New |
| `platform/src/main/resources/models/seed-catalog.yaml` | New |
| `platform/src/test/java/io/casehub/platform/model/NoOpModelRegistryTest.java` | New |
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
- `io.casehub.platform.mcp.DomainResourceRegistrar` — sole consumer of existing ModelRegistry
- casehubio/platform#285 — LLM model registry epic (layer model, boundary rules)
- casehubio/eidos AgentDescriptor — modelFamily/modelVersion fields (Layer 3 → Layer 2 binding, D6)
- Anthropic `/v1/models` API — cloud model listing reference
- OpenAI `/v1/models` API — cloud model listing reference
