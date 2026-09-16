# ModelRef Utility + Tier Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #298 — ModelRegistry → AgentProvider bridge: resolve model tier to LLM client at runtime
**Issue group:** #298

**Goal:** Enable callers to request a model by tier (e.g., FLAGSHIP, FAST) and have the RoutingAgentProvider resolve it to a concrete LLM model at runtime.

**Architecture:** A `ModelRef` utility class in `platform-api` encapsulates the `"tier:"` prefix convention — typed construction for callers, typed parsing for the router. `RoutingAgentProvider` gains a `resolveTier()` method that queries `ModelRegistry`, prefers the default backend's models, and fails fast with diagnostic errors. No SPI changes, no backend changes.

**Tech Stack:** Java 21 (records, pattern matching), JUnit 5, AssertJ, Mutiny

## Global Constraints

- `platform-api/` must remain zero-dependency — pure Java only
- `ModelRef` goes in `platform-api` package `io.casehub.platform.api.model`
- No changes to `AgentSessionConfig`, `AgentProvider`, `AgentBackend`, or any backend implementation
- TDD: write failing test first, then implement

---

## Batch 1: ModelRef utility + tier resolution

### Task 1: ModelRef utility class in platform-api

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/model/ModelRef.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/model/ModelRefTest.java`

**Interfaces:**
- Consumes: `ModelTier` enum (existing in same package)
- Produces: `ModelRef.forTier(ModelTier)` → String, `ModelRef.isTierRef(String)` → boolean, `ModelRef.parseTier(String)` → ModelTier — used by Task 2

- [ ] **Step 1: Write ModelRefTest**

```java
package io.casehub.platform.api.model;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ModelRefTest {

    @Test
    void forTier_flagship_returnsPrefixedString() {
        assertThat(ModelRef.forTier(ModelTier.FLAGSHIP)).isEqualTo("tier:FLAGSHIP");
    }

    @Test
    void forTier_fast_returnsPrefixedString() {
        assertThat(ModelRef.forTier(ModelTier.FAST)).isEqualTo("tier:FAST");
    }

    @Test
    void forTier_standard_returnsPrefixedString() {
        assertThat(ModelRef.forTier(ModelTier.STANDARD)).isEqualTo("tier:STANDARD");
    }

    @Test
    void forTier_embedding_returnsPrefixedString() {
        assertThat(ModelRef.forTier(ModelTier.EMBEDDING)).isEqualTo("tier:EMBEDDING");
    }

    @Test
    void forTier_null_throwsNpe() {
        assertThatThrownBy(() -> ModelRef.forTier(null))
                .isInstanceOf(NullPointerException.class);
    }

    @Test
    void isTierRef_validPrefix_returnsTrue() {
        assertThat(ModelRef.isTierRef("tier:FLAGSHIP")).isTrue();
    }

    @Test
    void isTierRef_modelId_returnsFalse() {
        assertThat(ModelRef.isTierRef("claude-sonnet-5")).isFalse();
    }

    @Test
    void isTierRef_null_returnsFalse() {
        assertThat(ModelRef.isTierRef(null)).isFalse();
    }

    @Test
    void isTierRef_emptyAfterPrefix_returnsTrue() {
        assertThat(ModelRef.isTierRef("tier:")).isTrue();
    }

    @Test
    void parseTier_flagship_returnsEnum() {
        assertThat(ModelRef.parseTier("tier:FLAGSHIP")).isEqualTo(ModelTier.FLAGSHIP);
    }

    @Test
    void parseTier_fast_returnsEnum() {
        assertThat(ModelRef.parseTier("tier:FAST")).isEqualTo(ModelTier.FAST);
    }

    @Test
    void parseTier_invalid_throwsIllegalArgument() {
        assertThatThrownBy(() -> ModelRef.parseTier("tier:INVALID"))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void parseTier_emptyAfterPrefix_throwsIllegalArgument() {
        assertThatThrownBy(() -> ModelRef.parseTier("tier:"))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void roundTrip_allTiers() {
        for (ModelTier tier : ModelTier.values()) {
            String ref = ModelRef.forTier(tier);
            assertThat(ModelRef.isTierRef(ref)).isTrue();
            assertThat(ModelRef.parseTier(ref)).isEqualTo(tier);
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform-api -Dtest=ModelRefTest`
Expected: FAIL — `ModelRef` class does not exist

- [ ] **Step 3: Implement ModelRef**

Create `platform-api/src/main/java/io/casehub/platform/api/model/ModelRef.java`:

```java
package io.casehub.platform.api.model;

import java.util.Objects;

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

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform-api -Dtest=ModelRefTest`
Expected: All 14 tests PASS

- [ ] **Step 5: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/model/ModelRef.java platform-api/src/test/java/io/casehub/platform/api/model/ModelRefTest.java
git commit -m "feat(#298): add ModelRef utility for tier-based model references"
```

### Task 2: Tier resolution in RoutingAgentProvider

**Files:**
- Modify: `agent-router-core/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java`
- Modify: `agent-router/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderTest.java`

**Interfaces:**
- Consumes: `ModelRef.isTierRef(String)`, `ModelRef.parseTier(String)` (from Task 1), `ModelRegistry.query(ModelQuery)`, `ModelRegistry.all()`, `ModelQuery.builder().tier(ModelTier).build()`
- Produces: tier-based model resolution via existing `AgentProvider.invoke()` / `openSession()` — callers pass `ModelRef.forTier(FLAGSHIP)` as the model string

- [ ] **Step 1: Enhance the test's `registryWith` helper to support tier-aware queries**

The existing `registryWith` helper returns ALL descriptors for any `query()` call regardless of query parameters. Tier resolution needs a registry that filters by tier. Add a new helper and a descriptor factory that accepts a tier. Append to `RoutingAgentProviderTest.java`:

```java
    static ModelDescriptor descriptorWithTier(String id, String apiModelId,
                                              String backendKey, ModelTier tier) {
        return new ModelDescriptor(id, apiModelId, backendKey, null, "test-vendor", "test-family",
                "Test " + id, tier, Set.of(), 128000, 16384,
                ModelLocality.CLOUD, null, null, Map.of());
    }

    static ModelRegistry tierAwareRegistry(ModelDescriptor... descriptors) {
        Map<String, ModelDescriptor> map = new HashMap<>();
        List<ModelDescriptor> all = List.of(descriptors);
        for (var d : descriptors) map.put(d.id(), d);
        return new ModelRegistry() {
            @Override
            public Optional<ModelDescriptor> resolveById(String id) {
                return Optional.ofNullable(map.get(id));
            }

            @Override
            public List<ModelDescriptor> query(ModelQuery query) {
                return all.stream()
                    .filter(d -> query.tier() == null || d.tier() == query.tier())
                    .filter(d -> query.vendor() == null || d.vendor().equals(query.vendor()))
                    .filter(d -> query.family() == null || d.family().equals(query.family()))
                    .toList();
            }

            @Override
            public List<ModelDescriptor> all() { return all; }
        };
    }
```

- [ ] **Step 2: Write tier resolution tests**

Append to `RoutingAgentProviderTest.java`:

```java
    // --- Tier-based resolution ---

    @Test
    void tierRef_resolvesToDefaultBackendModel() {
        var configCapture = new AtomicReference<AgentSessionConfig>();
        var initCapture = new AtomicReference<AgentSessionInit>();
        var registry = tierAwareRegistry(
                descriptorWithTier("claude-opus-5", "claude-opus-5", "claude", ModelTier.FLAGSHIP),
                descriptorWithTier("gpt-4.1", "gpt-4.1", "openai", ModelTier.STANDARD));
        var router = new RoutingAgentProvider(
                backendRegistry(capturingBackend("claude", configCapture, initCapture),
                                stubBackend("openai")),
                "claude", registry);

        var config = AgentSessionConfig.of("sys", "user", "tier:FLAGSHIP");
        router.invoke(config).collect().asList().await().indefinitely();
        assertThat(configCapture.get().model()).isEqualTo("claude-opus-5");
    }

    @Test
    void tierRef_prefersDefaultBackend() {
        var configCapture = new AtomicReference<AgentSessionConfig>();
        var initCapture = new AtomicReference<AgentSessionInit>();
        var registry = tierAwareRegistry(
                descriptorWithTier("o3", "o3", "openai", ModelTier.FLAGSHIP),
                descriptorWithTier("claude-opus-5", "claude-opus-5", "claude", ModelTier.FLAGSHIP));
        var router = new RoutingAgentProvider(
                backendRegistry(capturingBackend("claude", configCapture, initCapture),
                                stubBackend("openai")),
                "claude", registry);

        var config = AgentSessionConfig.of("sys", "user", "tier:FLAGSHIP");
        router.invoke(config).collect().asList().await().indefinitely();
        assertThat(configCapture.get().model()).isEqualTo("claude-opus-5");
    }

    @Test
    void tierRef_fallsBackToNonDefaultBackend() {
        var configCapture = new AtomicReference<AgentSessionConfig>();
        var initCapture = new AtomicReference<AgentSessionInit>();
        var registry = tierAwareRegistry(
                descriptorWithTier("o3", "o3", "openai", ModelTier.FLAGSHIP));
        var router = new RoutingAgentProvider(
                backendRegistry(stubBackend("claude"),
                                capturingBackend("openai", configCapture, initCapture)),
                "claude", registry);

        var config = AgentSessionConfig.of("sys", "user", "tier:FLAGSHIP");
        router.invoke(config).collect().asList().await().indefinitely();
        assertThat(configCapture.get().model()).isEqualTo("o3");
    }

    @Test
    void tierRef_emptyRegistry_throwsWithNoSourcesMessage() {
        var router = new RoutingAgentProvider(
                backendRegistry(stubBackend("claude")), "claude", emptyRegistry());
        var config = AgentSessionConfig.of("sys", "user", "tier:FLAGSHIP");
        assertThatThrownBy(() -> router.invoke(config))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("No model sources configured");
    }

    @Test
    void tierRef_noMatchingTier_throwsWithAvailableTiers() {
        var registry = tierAwareRegistry(
                descriptorWithTier("claude-haiku", "claude-haiku", "claude", ModelTier.FAST));
        var router = new RoutingAgentProvider(
                backendRegistry(stubBackend("claude")), "claude", registry);
        var config = AgentSessionConfig.of("sys", "user", "tier:FLAGSHIP");
        assertThatThrownBy(() -> router.invoke(config))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("FLAGSHIP")
                .hasMessageContaining("FAST");
    }

    @Test
    void tierRef_missingBackend_throwsIllegalState() {
        var registry = tierAwareRegistry(
                descriptorWithTier("gemini-pro", "gemini-pro", "gemini", ModelTier.FLAGSHIP));
        var router = new RoutingAgentProvider(
                backendRegistry(stubBackend("claude")), "claude", registry);
        var config = AgentSessionConfig.of("sys", "user", "tier:FLAGSHIP");
        assertThatThrownBy(() -> router.invoke(config))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("gemini");
    }

    @Test
    void tierRef_openSession_resolvesToCorrectModel() {
        var configCapture = new AtomicReference<AgentSessionConfig>();
        var initCapture = new AtomicReference<AgentSessionInit>();
        var registry = tierAwareRegistry(
                descriptorWithTier("claude-haiku", "claude-haiku", "claude", ModelTier.FAST));
        var router = new RoutingAgentProvider(
                backendRegistry(capturingBackend("claude", configCapture, initCapture)),
                "claude", registry);

        var init = AgentSessionInit.of("sys", "tier:FAST");
        router.openSession(init);
        assertThat(initCapture.get().model()).isEqualTo("claude-haiku");
    }

    @Test
    void tierRef_checkedBeforeRegistryId() {
        // A model with ID "tier:FLAGSHIP" exists in registry — tier prefix takes precedence
        var configCapture = new AtomicReference<AgentSessionConfig>();
        var initCapture = new AtomicReference<AgentSessionInit>();
        var registry = tierAwareRegistry(
                descriptorWithTier("tier:FLAGSHIP", "literal-id", "claude", ModelTier.STANDARD),
                descriptorWithTier("real-flagship", "real-flagship", "claude", ModelTier.FLAGSHIP));
        var router = new RoutingAgentProvider(
                backendRegistry(capturingBackend("claude", configCapture, initCapture)),
                "claude", registry);

        var config = AgentSessionConfig.of("sys", "user", "tier:FLAGSHIP");
        router.invoke(config).collect().asList().await().indefinitely();
        // Tier resolution picks real-flagship (FLAGSHIP tier), not the literal "tier:FLAGSHIP" model
        assertThat(configCapture.get().model()).isEqualTo("real-flagship");
    }

    @Test
    void tierRef_invalidTierName_throwsIllegalArgument() {
        var registry = tierAwareRegistry(
                descriptorWithTier("claude-opus-5", "claude-opus-5", "claude", ModelTier.FLAGSHIP));
        var router = new RoutingAgentProvider(
                backendRegistry(stubBackend("claude")), "claude", registry);
        var config = AgentSessionConfig.of("sys", "user", "tier:INVALID");
        assertThatThrownBy(() -> router.invoke(config))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void tierRef_existingResolutionPaths_unchanged() {
        // Verify model ID and backend key paths still work alongside tier
        var configCapture = new AtomicReference<AgentSessionConfig>();
        var initCapture = new AtomicReference<AgentSessionInit>();
        var registry = tierAwareRegistry(
                descriptorWithTier("claude-sonnet-5", "claude-sonnet-5", "claude", ModelTier.STANDARD));
        var router = new RoutingAgentProvider(
                backendRegistry(capturingBackend("claude", configCapture, initCapture)),
                "claude", registry);

        // Model ID path still works
        var config = AgentSessionConfig.of("sys", "user", "claude-sonnet-5");
        router.invoke(config).collect().asList().await().indefinitely();
        assertThat(configCapture.get().model()).isEqualTo("claude-sonnet-5");
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-router -Dtest=RoutingAgentProviderTest`
Expected: FAIL — new tests fail because `resolveTier` does not exist. Existing tests should still pass.

- [ ] **Step 4: Implement tier resolution in RoutingAgentProvider**

Add `ModelRef` import and the `resolveTier` method to `RoutingAgentProvider.java`. Modify the `resolve` method to check the tier prefix first.

Add import:
```java
import io.casehub.platform.api.model.ModelRef;
import io.casehub.platform.api.model.ModelQuery;
import io.casehub.platform.api.model.ModelTier;
```

Add `resolveTier` method:
```java
    private ResolvedRoute resolveTier(ModelTier tier) {
        var query = ModelQuery.builder().tier(tier).build();
        var candidates = modelRegistry.query(query);

        if (candidates.isEmpty()) {
            if (modelRegistry.all().isEmpty()) {
                throw new IllegalArgumentException(
                        "No model sources configured — tier resolution requires at least one "
                        + "ModelSource (e.g., SeedCatalogModelSource). Requested tier: " + tier);
            }
            var availableTiers = modelRegistry.all().stream()
                    .map(ModelDescriptor::tier)
                    .distinct().sorted().toList();
            throw new IllegalArgumentException(
                    "No model matching tier " + tier
                    + " (default backend: " + defaultBackendKey
                    + "). Available tiers: " + availableTiers);
        }

        var preferred = candidates.stream()
                .filter(d -> d.backendKey().equals(defaultBackendKey))
                .toList();

        ModelDescriptor selected;
        if (!preferred.isEmpty()) {
            selected = preferred.get(0);
        } else {
            selected = candidates.get(0);
            LOG.infof("Tier %s: no model for default backend '%s', falling back to %s (%s)",
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

Modify the `resolve` method — insert the tier check as the first step after the null check:

Replace the body of `resolve(String model)` starting after the null-model block:

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
            var    d          = descriptor.get();
            String instanceId = d.backendInstanceId() != null ? d.backendInstanceId() : "default";
            var    backend    = registry.resolve(d.backendKey(), instanceId);
            if (backend.isEmpty()) {
                throw new IllegalStateException(
                        "Model '" + model + "' resolved to backend " + d.backendKey()
                        + "/" + instanceId + ", but no backend with that key/instance is registered");
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

- [ ] **Step 5: Run all tests to verify they pass**

Run: `mvn --batch-mode test -pl agent-router -Dtest=RoutingAgentProviderTest`
Expected: ALL tests PASS (new tier tests + existing regression tests)

- [ ] **Step 6: Run full build to verify no regressions**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 7: Commit**

```bash
git add agent-router-core/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java agent-router/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderTest.java
git commit -m "feat(#298): add tier-based model resolution to RoutingAgentProvider

Extends resolve() with a tier prefix check (step 1) before existing
registry ID and backend key paths. ModelRef.isTierRef() detects tier
references, resolveTier() queries ModelRegistry and prefers the default
backend's models. Fails fast with diagnostic messages distinguishing
empty registry from no-match."
```

---

## References

- `specs/issue-298-model-tier-agent-bridge/2026-09-14-model-tier-agent-bridge-design.md` — design spec
- `agent-router-core/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java` — existing resolve method
- `agent-router/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderTest.java` — existing test patterns
- `platform-api/src/main/java/io/casehub/platform/api/model/ModelTier.java` — FLAGSHIP/STANDARD/FAST/EMBEDDING enum
- `platform-api/src/main/java/io/casehub/platform/api/model/ModelRegistry.java` — query(ModelQuery) method
- `platform-api/src/main/java/io/casehub/platform/api/model/ModelQuery.java` — tier filter + builder
- `platform-api/src/main/java/io/casehub/platform/api/model/ModelDescriptor.java` — backendKey, apiModelId, backendInstanceId
- GitHub #298 — focal issue
