# ModelRegistry → AgentProvider Bridge — Design Spec

**Issue:** casehubio/platform#298
**Date:** 2026-09-14
**Status:** Draft

## Summary

Extend `RoutingAgentProvider` to resolve model tier references (e.g., `"tier:FLAGSHIP"`) to concrete LLM models at runtime. A `ModelRef` utility class in `platform-api` encapsulates the prefix convention — typed construction for callers, typed parsing for the router. No SPI changes, no backend changes.

The consumer (fsitrading) has agents that declare `modelTier` via eidos capability descriptors. With this bridge, sentiment analysis (FLAGSHIP) uses Opus while monitoring (FAST) uses Haiku — without the consumer knowing specific model IDs.

## Architecture

```
Caller (eidos)                    RoutingAgentProvider                     Backend
─────────────                     ────────────────────                     ───────
ModelRef.forTier(FLAGSHIP)        1. isTierRef? → parseTier               config.model() =
  → "tier:FLAGSHIP"              2. query(tier=FLAGSHIP)                   "claude-opus-5"
                                  3. filter by defaultBackendKey            (or null)
AgentSessionConfig                4. select first match
  .of(prompt, up, "tier:...")     5. rewrite config with apiModelId
                                  6. delegate to backend.invoke()
```

### Resolution Precedence

The router's `resolve()` method gains a fourth step. The tier prefix check goes first because it's unambiguous (prefix-based), then the existing two-step ambiguity (model ID vs backend key):

1. **Tier reference** — `ModelRef.isTierRef(model)` → parse tier, query registry, select model
2. **Registry ID** — `modelRegistry.resolveById(model)` → resolve to backend via descriptor
3. **Backend key** — `registry.resolve(model, "default")` → use backend's default model
4. **Fail-fast** — `IllegalArgumentException` with available backends/tiers

This is documented in the router's javadoc.

## ModelRef Utility Class

In `platform-api`, package `io.casehub.platform.api.model`:

```java
public final class ModelRef {

    private static final String TIER_PREFIX = "tier:";

    public static String forTier(ModelTier tier) {
        Objects.requireNonNull(tier, "tier");
        return TIER_PREFIX + tier.name();
    }

    public static boolean isTierRef(String model) {
        return model != null && model.startsWith(TIER_PREFIX);
    }

    public static ModelTier parseTier(String model) {
        return ModelTier.valueOf(model.substring(TIER_PREFIX.length()));
    }

    private ModelRef() {}
}
```

**Design principle:** Encapsulate the format, not the field. Type safety at construction (callers) and interpretation (router), string transport at the SPI boundary. Neither callers nor the router construct or parse the prefix string directly — both go through `ModelRef`.

### Caller usage

```java
// Type-safe — takes ModelTier enum
var config = AgentSessionConfig.of(prompt, userPrompt, ModelRef.forTier(ModelTier.FLAGSHIP));
agentProvider.invoke(config);

// Config-driven (eidos reads modelTier from YAML)
String model = ModelRef.forTier(ModelTier.valueOf(yamlTierValue));
var config = AgentSessionConfig.of(prompt, userPrompt, model);
```

### Extensibility

When capability filtering is needed, add a second construction method:

```java
public static String forTier(ModelTier tier, Set<String> requiredCapabilities) {
    // format change is internal to ModelRef
}
```

Callers and the router are insulated from format changes.

## Tier Resolution in RoutingAgentProvider

### resolveTier method

```java
private ResolvedRoute resolveTier(ModelTier tier) {
    var query = ModelQuery.builder().tier(tier).build();
    var candidates = modelRegistry.query(query);

    if (candidates.isEmpty()) {
        if (modelRegistry.all().isEmpty()) {
            throw new IllegalArgumentException(
                "No model sources configured — tier resolution requires at least one "
                + "ModelSource (e.g., SeedCatalogModelSource). "
                + "Requested tier: " + tier);
        }
        var availableTiers = modelRegistry.all().stream()
                .map(ModelDescriptor::tier)
                .distinct().sorted().toList();
        throw new IllegalArgumentException(
                "No model matching tier " + tier
                + " (default backend: " + defaultBackendKey
                + "). Available tiers: " + availableTiers);
    }

    // Prefer models from the default backend
    var preferred = candidates.stream()
            .filter(d -> d.backendKey().equals(defaultBackendKey))
            .toList();

    ModelDescriptor selected;
    if (!preferred.isEmpty()) {
        selected = preferred.get(0);
    } else {
        selected = candidates.get(0);
        LOG.infof("Tier %s: no model for default backend '%s', "
                + "falling back to %s (%s)",
                tier, defaultBackendKey, selected.id(), selected.backendKey());
    }

    String instanceId = selected.backendInstanceId() != null
            ? selected.backendInstanceId() : "default";
    var backend = registry.resolve(selected.backendKey(), instanceId);
    if (backend.isEmpty()) {
        throw new IllegalStateException(
                "Model '" + selected.id() + "' resolved to backend "
                + selected.backendKey() + "/" + instanceId
                + ", but no backend with that key/instance is registered");
    }

    LOG.debugf("Tier %s resolved to model %s (backend: %s/%s)",
            tier, selected.id(), selected.backendKey(), instanceId);
    return new ResolvedRoute(backend.get(), selected.apiModelId());
}
```

### Updated resolve method

```java
private ResolvedRoute resolve(String model) {
    if (model == null) {
        var backend = registry.resolve(defaultBackendKey, "default");
        if (backend.isEmpty()) {
            throw new IllegalStateException(
                    "No default backend configured: " + defaultBackendKey);
        }
        return new ResolvedRoute(backend.get(), null);
    }

    // Step 1: Tier reference (unambiguous prefix — check first)
    if (ModelRef.isTierRef(model)) {
        return resolveTier(ModelRef.parseTier(model));
    }

    // Step 2: Registry ID
    Optional<ModelDescriptor> descriptor = modelRegistry.resolveById(model);
    if (descriptor.isPresent()) {
        var d = descriptor.get();
        String instanceId = d.backendInstanceId() != null
                ? d.backendInstanceId() : "default";
        var backend = registry.resolve(d.backendKey(), instanceId);
        if (backend.isEmpty()) {
            throw new IllegalStateException(
                    "Model '" + model + "' resolved to backend "
                    + d.backendKey() + "/" + instanceId
                    + ", but no backend with that key/instance is registered");
        }
        return new ResolvedRoute(backend.get(), d.apiModelId());
    }

    // Step 3: Backend key
    var backend = registry.resolve(model, "default");
    if (backend.isPresent()) {
        return new ResolvedRoute(backend.get(), null);
    }

    // Step 4: Fail-fast
    throw new IllegalArgumentException("No model or backend for: " + model);
}
```

### Model selection within a tier

When multiple models match a tier query for the preferred backend (e.g., `claude-opus-5`, `claude-opus-4-6`, `claude-opus-4` are all FLAGSHIP/claude), the first result from `ModelRegistry.query()` is selected. The query returns models in source-priority order; within a source, the seed catalog orders newest models first. Cloud sources typically return models in reverse chronological order.

This is a documented convention. Deterministic quality-aware ordering (by a preference rank or generation field on `ModelDescriptor`) is a refinement if the catalog grows to a point where insertion order is insufficient.

### Default backend preference

`casehub.platform.agent.default-backend` serves two meanings:
1. Which backend to use when `model` is null (existing)
2. Which backend to prefer for tier-based queries (new)

These are intentionally coupled — an admin who defaults to Claude also wants tier queries to prefer Claude. Per-tier vendor overrides (`casehub.agent.tier.flagship.vendor=anthropic`) are a one-line extension if the need arises.

## Test Strategy

### ModelRef (platform-api)

1. `forTier(FLAGSHIP)` returns `"tier:FLAGSHIP"`
2. `forTier(FAST)` returns `"tier:FAST"`
3. `forTier(null)` throws `NullPointerException`
4. `isTierRef("tier:FLAGSHIP")` returns true
5. `isTierRef("claude-sonnet-5")` returns false
6. `isTierRef(null)` returns false
7. `isTierRef("tier:")` returns true (parseTier will throw)
8. `parseTier("tier:FLAGSHIP")` returns `ModelTier.FLAGSHIP`
9. `parseTier("tier:INVALID")` throws `IllegalArgumentException`

### RoutingAgentProvider tier resolution (agent-router-core)

10. `resolve("tier:FLAGSHIP")` with default-backend=claude → selects claude FLAGSHIP model, routes to claude backend with resolved apiModelId
11. `resolve("tier:FAST")` with default-backend=claude → selects claude FAST model
12. `resolve("tier:FLAGSHIP")` with no claude FLAGSHIP but openai FLAGSHIP exists → falls back to openai model, logs info
13. `resolve("tier:FLAGSHIP")` with empty registry → throws `IllegalArgumentException` mentioning "no model sources configured"
14. `resolve("tier:FLAGSHIP")` with models but no FLAGSHIP → throws `IllegalArgumentException` listing available tiers
15. `resolve("tier:FLAGSHIP")` with matching model but missing backend → throws `IllegalStateException`
16. Tier prefix checked before registry ID — a model ID starting with `"tier:"` is treated as a tier reference (pathological but deterministic)
17. Existing resolution paths (null, model ID, backend key) unchanged — regression tests pass
18. Both `invoke()` and `openSession()` paths produce rewritten configs with resolved apiModelId from tier resolution

### Integration

19. End-to-end: `AgentSessionConfig.of(prompt, up, ModelRef.forTier(FLAGSHIP))` → router resolves → backend receives rewritten config with `apiModelId = "claude-opus-5"` and `model` field carrying that ID

## Files Changed

### platform-api (new file)

| File | Action |
|------|--------|
| `platform-api/src/main/java/io/casehub/platform/api/model/ModelRef.java` | New |
| `platform-api/src/test/java/io/casehub/platform/api/model/ModelRefTest.java` | New |

### agent-router-core (modified)

| File | Action |
|------|--------|
| `agent-router-core/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java` | Modified — add tier prefix check + `resolveTier()` method |

### agent-router (modified — tests)

| File | Action |
|------|--------|
| `agent-router/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderTest.java` | Modified — add tier resolution tests |

### Unchanged

- `AgentSessionConfig` — no changes
- `AgentSessionInit` — no changes
- `AgentProvider` — no changes
- `AgentBackend` — no changes
- All backend implementations (claude, openai, ollama, gemini, gemini-cli, codex, langchain4j) — no changes
- `GatedAgentProvider` — no changes
- `NoOpAgentProvider` — no changes

## Downstream (not this branch)

| Item | Description |
|------|-------------|
| Capability-filtered tier refs | `ModelRef.forTier(FLAGSHIP, Set.of("vision"))` — when capability differences within a tier matter |
| Per-tier vendor overrides | `casehub.agent.tier.flagship.vendor=anthropic` config — when different vendors needed per tier |
| Deterministic quality ordering | Preference rank on `ModelDescriptor` for same-tier same-backend selection |
| eidos integration | `AgentDescriptor.modelTier` → `ModelRef.forTier()` bridge in the eidos capability resolver |

## References

- `agent-router-core/.../RoutingAgentProvider.java` — existing four-step resolve method
- `platform-api/.../ModelRegistry.java` — `query(ModelQuery)` method
- `platform-api/.../ModelQuery.java` — tier filter
- `platform-api/.../ModelTier.java` — FLAGSHIP/STANDARD/FAST/EMBEDDING enum
- `platform-api/.../ModelDescriptor.java` — backendKey, backendInstanceId, apiModelId fields
- `agent-api/.../AgentSessionConfig.java` — model field (unchanged)
- `agent-api/.../BackendInstanceRegistry.java` — resolve(key, instanceId)
- `platform/src/main/resources/models/seed-catalog.yaml` — three FLAGSHIP Anthropic models, o3 lacks vision
- Issue #286 spec — model registry SPI design, three-step resolution contract
- Issue #288 spec — cloud model sources, priority model
- Issue #298 — this issue, fsitrading consumer context
