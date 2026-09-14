# MCP Tools for Model Registry — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #292 — feat: MCP tools for model registry
**Issue group:** #288, #289, #290, #292

**Goal:** Expose the model registry as a `models` MCP domain with read-only browsing and forced refresh, generating GraphQL + REST endpoints via the existing APT pipeline.

**Architecture:** New `@McpDomain("models")` interface (`ModelRegistryApi`) in `platform-api` with `@PlatformQuery`/`@PlatformMutation` methods. `ModelRegistryService` in `platform/` implements the interface by delegating to `ModelRegistry` (reads) and `ModelRegistryRefresher` (refresh). The `GraphQLResolverProcessor` APT automatically generates `GeneratedModelsResolver` (GraphQL) and `GeneratedModelsResource` (REST). A `ModelRegistryEnricher` surfaces live registry state in the MCP catalog.

**Tech Stack:** Java 21, Quarkus CDI, platform-api annotations (`@McpDomain`, `@PlatformQuery`, `@PlatformMutation`), JUnit 5, AssertJ

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA, no casehubio imports. Pure Java only.
- `platform/` contains Quarkus `@ApplicationScoped` implementations only — no domain logic.
- Every commit references issue #292.

---

## Batch 1: Foundation — API types and refresher refactor

### Task 1: Create RefreshResult record and ModelRegistryApi interface in platform-api

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/model/RefreshResult.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/model/ModelRegistryApi.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/model/ModelRegistryApiTest.java`

**Interfaces:**
- Consumes: `ModelDescriptor`, `McpDomain`, `PlatformQuery`, `PlatformMutation` (all existing in platform-api)
- Produces: `ModelRegistryApi` interface (used by Task 3 `ModelRegistryService`), `RefreshResult` record (returned by `refreshRegistry()`, constructed by Task 2's `refreshAllWithResult()`)

- [ ] **Step 1: Write the test for RefreshResult**

```java
package io.casehub.platform.api.model;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class RefreshResultTest {

    @Test
    void record_components() {
        var result = new RefreshResult(3, 12, 2, 1, 0);
        assertThat(result.sourcesRefreshed()).isEqualTo(3);
        assertThat(result.totalModels()).isEqualTo(12);
        assertThat(result.added()).isEqualTo(2);
        assertThat(result.removed()).isEqualTo(1);
        assertThat(result.updated()).isEqualTo(0);
    }
}
```

- [ ] **Step 2: Write the test for ModelRegistryApi annotations**

```java
package io.casehub.platform.api.model;

import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Method;

import static org.assertj.core.api.Assertions.assertThat;

class ModelRegistryApiTest {

    @Test
    void interface_has_McpDomain_annotation() {
        McpDomain ann = ModelRegistryApi.class.getAnnotation(McpDomain.class);
        assertThat(ann).isNotNull();
        assertThat(ann.value()).isEqualTo("models");
    }

    @Test
    void listModels_has_PlatformQuery_annotation() throws Exception {
        Method method = ModelRegistryApi.class.getMethod(
            "listModels", String.class, String.class, String.class, String.class, String.class);
        assertThat(method.getAnnotation(PlatformQuery.class)).isNotNull();
    }

    @Test
    void getModel_has_PlatformQuery_annotation() throws Exception {
        Method method = ModelRegistryApi.class.getMethod("getModel", String.class);
        assertThat(method.getAnnotation(PlatformQuery.class)).isNotNull();
    }

    @Test
    void refreshRegistry_has_PlatformMutation_annotation() throws Exception {
        Method method = ModelRegistryApi.class.getMethod("refreshRegistry");
        assertThat(method.getAnnotation(PlatformMutation.class)).isNotNull();
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn test -pl platform-api -Dtest="RefreshResultTest,ModelRegistryApiTest" --batch-mode`
Expected: Compilation failure — `RefreshResult` and `ModelRegistryApi` don't exist yet.

- [ ] **Step 4: Create RefreshResult record**

Create `platform-api/src/main/java/io/casehub/platform/api/model/RefreshResult.java`:

```java
package io.casehub.platform.api.model;

public record RefreshResult(
    int sourcesRefreshed,
    int totalModels,
    int added,
    int removed,
    int updated
) {}
```

- [ ] **Step 5: Create ModelRegistryApi interface**

Create `platform-api/src/main/java/io/casehub/platform/api/model/ModelRegistryApi.java`:

```java
package io.casehub.platform.api.model;

import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import java.util.List;

@McpDomain("models")
public interface ModelRegistryApi {

    @PlatformQuery("List available models — filter by vendor, family, tier, locality, or cost tier. All params optional.")
    List<ModelDescriptor> listModels(String vendor, String family,
                                     String tier, String locality,
                                     String maxCostTier);

    @PlatformQuery("Get detailed model info by registry ID")
    ModelDescriptor getModel(String modelId);

    @PlatformMutation("Force refresh from all model sources — returns what changed")
    RefreshResult refreshRegistry();
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn test -pl platform-api -Dtest="RefreshResultTest,ModelRegistryApiTest" --batch-mode`
Expected: All 5 tests PASS.

- [ ] **Step 7: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/model/RefreshResult.java \
       platform-api/src/main/java/io/casehub/platform/api/model/ModelRegistryApi.java \
       platform-api/src/test/java/io/casehub/platform/api/model/RefreshResultTest.java \
       platform-api/src/test/java/io/casehub/platform/api/model/ModelRegistryApiTest.java
git commit -m "feat(#292): add ModelRegistryApi interface and RefreshResult record in platform-api"
```

### Task 2: Refactor ModelRegistryRefresher to add refreshAllWithResult()

**Files:**
- Modify: `platform/src/main/java/io/casehub/platform/model/ModelRegistryRefresher.java`
- Modify: `platform/src/test/java/io/casehub/platform/model/ModelRegistryRefresherTest.java`

**Interfaces:**
- Consumes: `RefreshResult` (from Task 1)
- Produces: `refreshAllWithResult()` method (used by Task 3 `ModelRegistryService.refreshRegistry()`)

- [ ] **Step 1: Write the failing test for refreshAllWithResult()**

Add to `ModelRegistryRefresherTest.java`:

```java
@Test
void refreshAllWithResult_aggregatesDeltas() {
    var sourceA = new ModelSource() {
        @Override public String sourceId() { return "a"; }
        @Override public int priority() { return 0; }
        @Override public List<ModelDescriptor> refresh() {
            return List.of(
                new ModelDescriptor("a:m1", "m1", "openai", null, "openai", "gpt-4", "GPT-4",
                    ModelTier.FLAGSHIP, Set.of(), 128000, 4096, ModelLocality.CLOUD, CostTier.HIGH, null, Map.of()),
                new ModelDescriptor("a:m2", "m2", "openai", null, "openai", "gpt-4", "GPT-4 Mini",
                    ModelTier.FAST, Set.of(), 128000, 4096, ModelLocality.CLOUD, CostTier.LOW, null, Map.of())
            );
        }
    };
    var sourceB = new ModelSource() {
        @Override public String sourceId() { return "b"; }
        @Override public int priority() { return 10; }
        @Override public List<ModelDescriptor> refresh() {
            return List.of(
                new ModelDescriptor("b:m1", "m1", "anthropic", null, "anthropic", "claude", "Claude",
                    ModelTier.FLAGSHIP, Set.of(), 200000, 8192, ModelLocality.CLOUD, CostTier.HIGH, null, Map.of())
            );
        }
    };

    var refresher = new ModelRegistryRefresher();
    refresher.sources = listInstance(List.of(sourceA, sourceB));
    refresher.registry = new InMemoryModelRegistry();
    refresher.catalogChanged = noOpEvent();

    RefreshResult result = refresher.refreshAllWithResult();

    assertThat(result.sourcesRefreshed()).isEqualTo(2);
    assertThat(result.totalModels()).isEqualTo(3);
    assertThat(result.added()).isEqualTo(3);
    assertThat(result.removed()).isEqualTo(0);
    assertThat(result.updated()).isEqualTo(0);
}

@Test
void refreshAllWithResult_countsFailedSourcesAsZero() {
    var good = new ModelSource() {
        @Override public String sourceId() { return "good"; }
        @Override public int priority() { return 0; }
        @Override public List<ModelDescriptor> refresh() {
            return List.of(
                new ModelDescriptor("g:m1", "m1", "openai", null, "openai", "gpt-4", "GPT-4",
                    ModelTier.FLAGSHIP, Set.of(), 128000, 4096, ModelLocality.CLOUD, CostTier.HIGH, null, Map.of())
            );
        }
    };
    var bad = new ModelSource() {
        @Override public String sourceId() { return "bad"; }
        @Override public int priority() { return 10; }
        @Override public List<ModelDescriptor> refresh() { throw new RuntimeException("boom"); }
    };

    var refresher = new ModelRegistryRefresher();
    refresher.sources = listInstance(List.of(good, bad));
    refresher.registry = new InMemoryModelRegistry();
    refresher.catalogChanged = noOpEvent();

    RefreshResult result = refresher.refreshAllWithResult();

    assertThat(result.sourcesRefreshed()).isEqualTo(1);
    assertThat(result.totalModels()).isEqualTo(1);
    assertThat(result.added()).isEqualTo(1);
}
```

Add these imports to the test file:
```java
import io.casehub.platform.api.model.CostTier;
import io.casehub.platform.api.model.ModelLocality;
import io.casehub.platform.api.model.ModelTier;
import io.casehub.platform.api.model.RefreshResult;
import java.util.Map;
import java.util.Set;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn test -pl platform -Dtest="ModelRegistryRefresherTest#refreshAllWithResult*" --batch-mode`
Expected: Compilation failure — `refreshAllWithResult()` doesn't exist.

- [ ] **Step 3: Implement refreshAllWithResult() and refactor refreshAll()**

In `ModelRegistryRefresher.java`, extract the source-sorting logic into a helper, add `refreshAllWithResult()`, and make `refreshAll()` delegate:

Replace the `refreshAll()` method body with:

```java
void refreshAll() {
    refreshAllWithResult();
}

RefreshResult refreshAllWithResult() {
    var sortedSources = new java.util.ArrayList<ModelSource>();
    sources.forEach(sortedSources::add);
    sortedSources.sort(java.util.Comparator.comparingInt(ModelSource::priority));

    int sourcesRefreshed = 0, added = 0, removed = 0, updated = 0;

    for (ModelSource source : sortedSources) {
        try {
            List<ModelDescriptor> models = source.refresh();
            var delta = registry.replaceSource(source.sourceId(), source.priority(), models);
            sourcesRefreshed++;
            added += delta.addedIds().size();
            removed += delta.removedIds().size();
            updated += delta.updatedIds().size();
            if (delta.hasChanges()) {
                catalogChanged.fire(new ModelCatalogChangedEvent(
                        source.sourceId(), delta.addedIds(), delta.removedIds(), delta.updatedIds()));
            }
        } catch (Exception e) {
            LOG.warnf("Model source '%s' refresh failed: %s", source.sourceId(), e.getMessage());
        }
    }

    return new RefreshResult(sourcesRefreshed, registry.all().size(), added, removed, updated);
}
```

Add import: `import io.casehub.platform.api.model.RefreshResult;`

- [ ] **Step 4: Run all refresher tests to verify they pass**

Run: `mvn test -pl platform -Dtest="ModelRegistryRefresherTest" --batch-mode`
Expected: All 4 tests PASS (2 existing + 2 new). Existing tests still pass because `refreshAll()` delegates to `refreshAllWithResult()`.

- [ ] **Step 5: Commit**

```bash
git add platform/src/main/java/io/casehub/platform/model/ModelRegistryRefresher.java \
       platform/src/test/java/io/casehub/platform/model/ModelRegistryRefresherTest.java
git commit -m "feat(#292): add refreshAllWithResult() to ModelRegistryRefresher"
```

## Batch 2: Service + Enricher — working MCP domain

### Task 3: ModelRegistryService implementation

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/model/ModelRegistryService.java`
- Test: `platform/src/test/java/io/casehub/platform/model/ModelRegistryServiceTest.java`

**Interfaces:**
- Consumes: `ModelRegistryApi` (from Task 1), `ModelRegistry` (existing SPI), `ModelRegistryRefresher.refreshAllWithResult()` (from Task 2)
- Produces: `ModelRegistryService` bean — CDI discovers it as the `ModelRegistryApi` implementation. The APT-generated `GeneratedModelsResolver` injects `ModelRegistryApi` and delegates.

- [ ] **Step 1: Write the failing tests**

Create `platform/src/test/java/io/casehub/platform/model/ModelRegistryServiceTest.java`:

```java
package io.casehub.platform.model;

import io.casehub.platform.api.model.CostTier;
import io.casehub.platform.api.model.ModelDescriptor;
import io.casehub.platform.api.model.ModelLocality;
import io.casehub.platform.api.model.ModelQuery;
import io.casehub.platform.api.model.ModelTier;
import io.casehub.platform.api.model.RefreshResult;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ModelRegistryServiceTest {

    private InMemoryModelRegistry registry;
    private StubRefresher refresher;
    private ModelRegistryService service;

    @BeforeEach
    void setUp() {
        registry = new InMemoryModelRegistry();
        registry.replaceSource("seed", 0, List.of(
            new ModelDescriptor("claude-sonnet", "claude-sonnet-4-20250514", "claude", null,
                "anthropic", "claude", "Claude Sonnet",
                ModelTier.STANDARD, Set.of("text", "vision"), 200000, 8192,
                ModelLocality.CLOUD, CostTier.MEDIUM, null, Map.of()),
            new ModelDescriptor("gpt-4o", "gpt-4o", "openai", null,
                "openai", "gpt-4", "GPT-4o",
                ModelTier.FLAGSHIP, Set.of("text", "vision"), 128000, 4096,
                ModelLocality.CLOUD, CostTier.HIGH, null, Map.of()),
            new ModelDescriptor("llama3", "llama3:8b", "ollama", null,
                "meta", "llama", "Llama 3 8B",
                ModelTier.FAST, Set.of("text"), 8192, 2048,
                ModelLocality.LOCAL, CostTier.FREE, null, Map.of())
        ));
        refresher = new StubRefresher();
        service = new ModelRegistryService(registry, refresher);
    }

    @Test
    void listModels_noFilters_returnsAll() {
        var result = service.listModels(null, null, null, null, null);
        assertThat(result).hasSize(3);
    }

    @Test
    void listModels_filterByVendor() {
        var result = service.listModels("anthropic", null, null, null, null);
        assertThat(result).hasSize(1);
        assertThat(result.get(0).id()).isEqualTo("claude-sonnet");
    }

    @Test
    void listModels_filterByTier() {
        var result = service.listModels(null, null, "FLAGSHIP", null, null);
        assertThat(result).hasSize(1);
        assertThat(result.get(0).id()).isEqualTo("gpt-4o");
    }

    @Test
    void listModels_filterByLocality() {
        var result = service.listModels(null, null, null, "LOCAL", null);
        assertThat(result).hasSize(1);
        assertThat(result.get(0).id()).isEqualTo("llama3");
    }

    @Test
    void listModels_filterByMaxCostTier() {
        var result = service.listModels(null, null, null, null, "LOW");
        assertThat(result).hasSize(1);
        assertThat(result.get(0).id()).isEqualTo("llama3");
    }

    @Test
    void listModels_caseInsensitiveEnums() {
        var result = service.listModels(null, null, "flagship", null, null);
        assertThat(result).hasSize(1);
    }

    @Test
    void listModels_invalidTier_throws() {
        assertThatThrownBy(() -> service.listModels(null, null, "BOGUS", null, null))
            .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void listModels_blankParamsTreatedAsNull() {
        var result = service.listModels("", " ", "", "", "");
        assertThat(result).hasSize(3);
    }

    @Test
    void getModel_found() {
        var result = service.getModel("claude-sonnet");
        assertThat(result.displayName()).isEqualTo("Claude Sonnet");
    }

    @Test
    void getModel_notFound_throws() {
        assertThatThrownBy(() -> service.getModel("nonexistent"))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("Unknown model: nonexistent");
    }

    @Test
    void refreshRegistry_delegatesToRefresher() {
        refresher.result = new RefreshResult(2, 5, 1, 0, 0);
        var result = service.refreshRegistry();
        assertThat(result.sourcesRefreshed()).isEqualTo(2);
        assertThat(result.totalModels()).isEqualTo(5);
        assertThat(refresher.called).isTrue();
    }

    static class StubRefresher extends ModelRegistryRefresher {
        RefreshResult result = new RefreshResult(0, 0, 0, 0, 0);
        boolean called = false;

        @Override
        RefreshResult refreshAllWithResult() {
            called = true;
            return result;
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn test -pl platform -Dtest="ModelRegistryServiceTest" --batch-mode`
Expected: Compilation failure — `ModelRegistryService` doesn't exist.

- [ ] **Step 3: Create ModelRegistryService**

Create `platform/src/main/java/io/casehub/platform/model/ModelRegistryService.java`:

```java
package io.casehub.platform.model;

import io.casehub.platform.api.model.CostTier;
import io.casehub.platform.api.model.ModelDescriptor;
import io.casehub.platform.api.model.ModelLocality;
import io.casehub.platform.api.model.ModelQuery;
import io.casehub.platform.api.model.ModelRegistry;
import io.casehub.platform.api.model.ModelRegistryApi;
import io.casehub.platform.api.model.ModelTier;
import io.casehub.platform.api.model.RefreshResult;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.util.List;

@ApplicationScoped
public class ModelRegistryService implements ModelRegistryApi {

    private final ModelRegistry registry;
    private final ModelRegistryRefresher refresher;

    @Inject
    ModelRegistryService(ModelRegistry registry, ModelRegistryRefresher refresher) {
        this.registry = registry;
        this.refresher = refresher;
    }

    ModelRegistryService(InMemoryModelRegistry registry, ModelRegistryRefresher refresher) {
        this.registry = registry;
        this.refresher = refresher;
    }

    @Override
    public List<ModelDescriptor> listModels(String vendor, String family,
                                             String tier, String locality,
                                             String maxCostTier) {
        var builder = ModelQuery.builder();
        if (vendor != null && !vendor.isBlank()) builder.vendor(vendor);
        if (family != null && !family.isBlank()) builder.family(family);
        if (tier != null && !tier.isBlank()) builder.tier(ModelTier.valueOf(tier.toUpperCase()));
        if (locality != null && !locality.isBlank()) builder.locality(ModelLocality.valueOf(locality.toUpperCase()));
        if (maxCostTier != null && !maxCostTier.isBlank()) builder.maxCostTier(CostTier.valueOf(maxCostTier.toUpperCase()));
        return registry.query(builder.build());
    }

    @Override
    public ModelDescriptor getModel(String modelId) {
        return registry.resolveById(modelId)
            .orElseThrow(() -> new IllegalArgumentException("Unknown model: " + modelId));
    }

    @Override
    public RefreshResult refreshRegistry() {
        return refresher.refreshAllWithResult();
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn test -pl platform -Dtest="ModelRegistryServiceTest" --batch-mode`
Expected: All 11 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add platform/src/main/java/io/casehub/platform/model/ModelRegistryService.java \
       platform/src/test/java/io/casehub/platform/model/ModelRegistryServiceTest.java
git commit -m "feat(#292): add ModelRegistryService implementing ModelRegistryApi"
```

### Task 4: ModelRegistryEnricher

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/model/ModelRegistryEnricher.java`
- Test: `platform/src/test/java/io/casehub/platform/model/ModelRegistryEnricherTest.java`

**Interfaces:**
- Consumes: `ModelEnricher` (existing SPI), `ModelRegistry` (existing SPI)
- Produces: `ModelRegistryEnricher` bean — CDI discovers it via `@McpDomain("models")`, `GraphQLModelScanner` picks it up as the enricher for the `models` domain.

- [ ] **Step 1: Write the failing tests**

Create `platform/src/test/java/io/casehub/platform/model/ModelRegistryEnricherTest.java`:

```java
package io.casehub.platform.model;

import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.model.CostTier;
import io.casehub.platform.api.model.ModelDescriptor;
import io.casehub.platform.api.model.ModelLocality;
import io.casehub.platform.api.model.ModelTier;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class ModelRegistryEnricherTest {

    @Test
    void has_McpDomain_models_annotation() {
        McpDomain ann = ModelRegistryEnricher.class.getAnnotation(McpDomain.class);
        assertThat(ann).isNotNull();
        assertThat(ann.value()).isEqualTo("models");
    }

    @Test
    void summary_is_non_empty() {
        var enricher = new ModelRegistryEnricher();
        enricher.registry = new InMemoryModelRegistry();
        assertThat(enricher.summary()).isNotBlank();
    }

    @Test
    @SuppressWarnings("unchecked")
    void state_contains_modelCount_and_vendors() {
        var registry = new InMemoryModelRegistry();
        registry.replaceSource("seed", 0, List.of(
            new ModelDescriptor("m1", "m1", "openai", null, "openai", "gpt-4", "GPT-4",
                ModelTier.FLAGSHIP, Set.of(), 128000, 4096, ModelLocality.CLOUD, CostTier.HIGH, null, Map.of()),
            new ModelDescriptor("m2", "m2", "claude", null, "anthropic", "claude", "Claude",
                ModelTier.STANDARD, Set.of(), 200000, 8192, ModelLocality.CLOUD, CostTier.MEDIUM, null, Map.of())
        ));

        var enricher = new ModelRegistryEnricher();
        enricher.registry = registry;

        Map<String, Object> state = enricher.state();
        assertThat(state.get("modelCount")).isEqualTo(2);
        assertThat((List<String>) state.get("vendors")).containsExactly("anthropic", "openai");
    }

    @Test
    void state_empty_registry() {
        var enricher = new ModelRegistryEnricher();
        enricher.registry = new InMemoryModelRegistry();

        Map<String, Object> state = enricher.state();
        assertThat(state.get("modelCount")).isEqualTo(0);
        assertThat((List<?>) state.get("vendors")).isEmpty();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn test -pl platform -Dtest="ModelRegistryEnricherTest" --batch-mode`
Expected: Compilation failure — `ModelRegistryEnricher` doesn't exist.

- [ ] **Step 3: Create ModelRegistryEnricher**

Create `platform/src/main/java/io/casehub/platform/model/ModelRegistryEnricher.java`:

```java
package io.casehub.platform.model;

import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.ModelEnricher;
import io.casehub.platform.api.model.ModelDescriptor;
import io.casehub.platform.api.model.ModelRegistry;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.util.Map;

@McpDomain("models")
@ApplicationScoped
public class ModelRegistryEnricher implements ModelEnricher {

    @Inject
    ModelRegistry registry;

    @Override
    public String summary() {
        return "Model registry — query available LLM models across vendors, tiers, and capabilities";
    }

    @Override
    public Map<String, Object> state() {
        var all = registry.all();
        var vendors = all.stream().map(ModelDescriptor::vendor).distinct().sorted().toList();
        return Map.of(
            "modelCount", all.size(),
            "vendors", vendors
        );
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn test -pl platform -Dtest="ModelRegistryEnricherTest" --batch-mode`
Expected: All 4 tests PASS.

- [ ] **Step 5: Run full platform module tests**

Run: `mvn test -pl platform --batch-mode`
Expected: All existing tests still pass — no regressions.

- [ ] **Step 6: Commit**

```bash
git add platform/src/main/java/io/casehub/platform/model/ModelRegistryEnricher.java \
       platform/src/test/java/io/casehub/platform/model/ModelRegistryEnricherTest.java
git commit -m "feat(#292): add ModelRegistryEnricher for models MCP domain"
```

- [ ] **Step 7: Run full build**

Run: `mvn --batch-mode install`
Expected: Full build passes. The `GraphQLResolverProcessor` APT generates `GeneratedModelsResolver` and `GeneratedModelsResource` in any consumer module that depends on `platform-api` and has the processor on its annotation processor path.

## References

- [2026-09-14-mcp-model-registry-tools-design.md] — design spec this plan implements
- `platform-api/src/main/java/io/casehub/platform/api/model/ModelRegistry.java` — SPI being exposed
- `platform-api/src/main/java/io/casehub/platform/api/model/ModelDescriptor.java` — return type
- `platform-api/src/main/java/io/casehub/platform/api/model/ModelQuery.java` — query construction
- `platform-api/src/main/java/io/casehub/platform/api/model/ModelTier.java` — tier enum
- `platform-api/src/main/java/io/casehub/platform/api/model/ModelLocality.java` — locality enum
- `platform-api/src/main/java/io/casehub/platform/api/model/CostTier.java` — cost tier enum
- `platform/src/main/java/io/casehub/platform/model/ModelRegistryRefresher.java` — refresh refactor target
- `platform/src/test/java/io/casehub/platform/model/ModelRegistryRefresherTest.java` — existing test patterns
- `platform/src/main/java/io/casehub/platform/model/InMemoryModelRegistry.java` — registry impl
- `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigApi.java` — @McpDomain interface pattern
- `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigService.java` — implementation pattern
- GE-20260818-c2f072 — testing MCP domain dispatch without CDI
- GitHub #292 — focal issue
- GitHub #285 — parent epic
