# Model Registry SPI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #286 — ModelRegistry + ModelDescriptor + ModelSource SPI
**Issue group:** #286, #287

**Goal:** Build the queryable LLM model registry — SPIs, in-memory implementation, seed catalog, and RoutingAgentProvider integration.

**Architecture:** Layer 2 (Model Selection) in epic #285. SPIs in `platform-api/` (zero-dep), implementation in `platform/` (InMemoryModelRegistry + SeedCatalogModelSource), integration in `agent-router/` (three-step resolution with config rewriting), and MCP rename (`ModelRegistry` → `DomainModelRegistry`).

**Tech Stack:** Pure Java (SPIs), Quarkus CDI (registry impl), Jackson YAML (seed catalog), JUnit 5, AssertJ

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA, no casehubio imports
- New SPI package: `io.casehub.platform.api.model`
- New impl package: `io.casehub.platform.model`
- Capabilities use `Set<String>` with constants (not enum) — new capabilities emerge on weeks cadence
- `costTier` and `authMethod` are nullable on `ModelDescriptor`
- `ModelRegistry` injected as `@ApplicationScoped` — always on classpath, returns empty with no sources
- Existing `io.casehub.platform.mcp.ModelRegistry` renamed to `DomainModelRegistry` via `ide_refactor_rename`
- RoutingAgentProvider: fail-fast for unknown model (no silent langchain4j fallback for non-null refs)

---

## Batch 1: SPIs in platform-api

### Task 1: Enums + ModelCapabilities + ModelDescriptor

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/model/ModelTier.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/model/ModelLocality.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/model/CostTier.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/model/ModelCapabilities.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/model/ModelDescriptor.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/model/ModelDescriptorTest.java`

**Interfaces:**
- Consumes: nothing — foundation types
- Produces: `ModelTier` (enum: FLAGSHIP, STANDARD, FAST, EMBEDDING), `ModelLocality` (enum: CLOUD, LOCAL), `CostTier` (enum with `rank()`: FREE(0), LOW(1), MEDIUM(2), HIGH(3), PREMIUM(4)), `ModelCapabilities` (string constants: TEXT, VISION, TOOL_USE, CODE, REASONING), `ModelDescriptor` (record: id, backendKey, vendor, family, displayName, tier, capabilities, contextWindow, maxOutput, locality, costTier, authMethod, properties)

- [ ] **Step 1: Write failing tests**

Create `ModelDescriptorTest.java` using `ide_create_file`:

```java
package io.casehub.platform.api.model;

import java.util.Map;
import java.util.Set;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ModelDescriptorTest {

    @Test
    void requiredFieldsValidated() {
        assertThatThrownBy(() -> new ModelDescriptor(
            null, "claude", "anthropic", "claude", "Claude", ModelTier.STANDARD,
            Set.of(), 200000, 16384, ModelLocality.CLOUD, CostTier.MEDIUM, "api-key", Map.of()))
            .isInstanceOf(NullPointerException.class)
            .hasMessageContaining("id");
    }

    @Test
    void capabilitiesDefensiveCopy() {
        var caps = new java.util.HashSet<>(Set.of(ModelCapabilities.TEXT));
        var desc = new ModelDescriptor("m1", "claude", "anthropic", "claude", "Claude",
            ModelTier.STANDARD, caps, 200000, 16384, ModelLocality.CLOUD, CostTier.MEDIUM, "api-key", Map.of());
        caps.add(ModelCapabilities.VISION);
        assertThat(desc.capabilities()).doesNotContain(ModelCapabilities.VISION);
    }

    @Test
    void propertiesDefensiveCopy() {
        var props = new java.util.HashMap<>(Map.of("key", "val"));
        var desc = new ModelDescriptor("m1", "claude", "anthropic", "claude", "Claude",
            ModelTier.STANDARD, Set.of(), 200000, 16384, ModelLocality.CLOUD, CostTier.MEDIUM, "api-key", props);
        props.put("new", "val2");
        assertThat(desc.properties()).doesNotContainKey("new");
    }

    @Test
    void nullCapabilitiesDefaultsToEmpty() {
        var desc = new ModelDescriptor("m1", "claude", "anthropic", "claude", "Claude",
            ModelTier.STANDARD, null, 200000, 16384, ModelLocality.CLOUD, null, null, null);
        assertThat(desc.capabilities()).isEmpty();
        assertThat(desc.properties()).isEmpty();
    }

    @Test
    void costTierNullable() {
        var desc = new ModelDescriptor("m1", "claude", "anthropic", "claude", "Claude",
            ModelTier.STANDARD, Set.of(), 200000, 16384, ModelLocality.CLOUD, null, null, Map.of());
        assertThat(desc.costTier()).isNull();
        assertThat(desc.authMethod()).isNull();
    }

    @Test
    void costTierRankOrdering() {
        assertThat(CostTier.FREE.rank()).isLessThan(CostTier.LOW.rank());
        assertThat(CostTier.LOW.rank()).isLessThan(CostTier.MEDIUM.rank());
        assertThat(CostTier.MEDIUM.rank()).isLessThan(CostTier.HIGH.rank());
        assertThat(CostTier.HIGH.rank()).isLessThan(CostTier.PREMIUM.rank());
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl platform-api test -Dtest=ModelDescriptorTest --batch-mode`
Expected: Compilation failure — types not found.

- [ ] **Step 3: Create enums and ModelCapabilities**

Create 4 files using `ide_create_file`:

`ModelTier.java`:
```java
package io.casehub.platform.api.model;

public enum ModelTier {
    FLAGSHIP,
    STANDARD,
    FAST,
    EMBEDDING
}
```

`ModelLocality.java`:
```java
package io.casehub.platform.api.model;

public enum ModelLocality {
    CLOUD,
    LOCAL
}
```

`CostTier.java`:
```java
package io.casehub.platform.api.model;

public enum CostTier {
    FREE(0), LOW(1), MEDIUM(2), HIGH(3), PREMIUM(4);

    private final int rank;
    CostTier(int rank) { this.rank = rank; }
    public int rank() { return rank; }
}
```

`ModelCapabilities.java`:
```java
package io.casehub.platform.api.model;

public final class ModelCapabilities {
    public static final String TEXT = "text";
    public static final String VISION = "vision";
    public static final String TOOL_USE = "tool-use";
    public static final String CODE = "code";
    public static final String REASONING = "reasoning";

    private ModelCapabilities() {}
}
```

- [ ] **Step 4: Create ModelDescriptor**

Create `ModelDescriptor.java` using `ide_create_file`:

```java
package io.casehub.platform.api.model;

import java.util.Map;
import java.util.Objects;
import java.util.Set;

public record ModelDescriptor(
    String id,
    String backendKey,
    String vendor,
    String family,
    String displayName,
    ModelTier tier,
    Set<String> capabilities,
    int contextWindow,
    int maxOutput,
    ModelLocality locality,
    CostTier costTier,
    String authMethod,
    Map<String, String> properties
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

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -pl platform-api test -Dtest=ModelDescriptorTest --batch-mode`
Expected: All 6 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/model/ platform-api/src/test/java/io/casehub/platform/api/model/ModelDescriptorTest.java
git commit -m "feat(#286): add ModelDescriptor, enums, and ModelCapabilities constants

Foundation types for the LLM model registry — ModelTier, ModelLocality,
CostTier (ranked), ModelCapabilities string constants, ModelDescriptor record
with typed dimensions and extensible properties.

Refs #286"
```

### Task 2: ModelRegistry + ModelSource + ModelQuery + ModelCatalogChangedEvent

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/model/ModelRegistry.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/model/ModelSource.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/model/ModelQuery.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/model/ModelCatalogChangedEvent.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/model/ModelQueryTest.java`

**Interfaces:**
- Consumes: `ModelDescriptor`, `ModelTier`, `ModelLocality`, `CostTier` from Task 1
- Produces: `ModelRegistry` (SPI: `resolveById(String)`, `query(ModelQuery)`, `all()`), `ModelSource` (SPI: `sourceId()`, `priority()`, `refresh()`), `ModelQuery` (record with builder), `ModelCatalogChangedEvent` (CDI event record)

- [ ] **Step 1: Write failing tests**

Create `ModelQueryTest.java` using `ide_create_file`:

```java
package io.casehub.platform.api.model;

import java.util.Set;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class ModelQueryTest {

    @Test
    void allQuery_hasNullFilters() {
        var query = ModelQuery.all();
        assertThat(query.vendor()).isNull();
        assertThat(query.family()).isNull();
        assertThat(query.tier()).isNull();
        assertThat(query.requiredCapabilities()).isEmpty();
        assertThat(query.locality()).isNull();
        assertThat(query.maxCostTier()).isNull();
        assertThat(query.authMethod()).isNull();
    }

    @Test
    void builderSetsFields() {
        var query = ModelQuery.builder()
            .vendor("anthropic")
            .family("claude")
            .tier(ModelTier.STANDARD)
            .requiredCapabilities(Set.of(ModelCapabilities.VISION))
            .locality(ModelLocality.CLOUD)
            .maxCostTier(CostTier.HIGH)
            .authMethod("api-key")
            .build();
        assertThat(query.vendor()).isEqualTo("anthropic");
        assertThat(query.family()).isEqualTo("claude");
        assertThat(query.tier()).isEqualTo(ModelTier.STANDARD);
        assertThat(query.requiredCapabilities()).containsExactly(ModelCapabilities.VISION);
        assertThat(query.locality()).isEqualTo(ModelLocality.CLOUD);
        assertThat(query.maxCostTier()).isEqualTo(CostTier.HIGH);
        assertThat(query.authMethod()).isEqualTo("api-key");
    }

    @Test
    void requiredCapabilities_defensiveCopy() {
        var caps = new java.util.HashSet<>(Set.of(ModelCapabilities.TEXT));
        var query = new ModelQuery(null, null, null, caps, null, null, null);
        caps.add(ModelCapabilities.VISION);
        assertThat(query.requiredCapabilities()).doesNotContain(ModelCapabilities.VISION);
    }

    @Test
    void catalogChangedEvent_hasChanges() {
        var event = new ModelCatalogChangedEvent("src",
            Set.of("added"), Set.of(), Set.of());
        assertThat(event.hasChanges()).isTrue();
    }

    @Test
    void catalogChangedEvent_noChanges() {
        var event = new ModelCatalogChangedEvent("src",
            Set.of(), Set.of(), Set.of());
        assertThat(event.hasChanges()).isFalse();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl platform-api test -Dtest=ModelQueryTest --batch-mode`
Expected: Compilation failure.

- [ ] **Step 3: Create ModelRegistry, ModelSource, ModelQuery, ModelCatalogChangedEvent**

Create 4 files using `ide_create_file`:

`ModelRegistry.java`:
```java
package io.casehub.platform.api.model;

import java.util.List;
import java.util.Optional;

public interface ModelRegistry {
    Optional<ModelDescriptor> resolveById(String modelId);
    List<ModelDescriptor> query(ModelQuery query);
    List<ModelDescriptor> all();
}
```

`ModelSource.java`:
```java
package io.casehub.platform.api.model;

import java.util.List;

public interface ModelSource {
    String sourceId();
    int priority();
    List<ModelDescriptor> refresh();
}
```

`ModelQuery.java`:
```java
package io.casehub.platform.api.model;

import java.util.Set;

public record ModelQuery(
    String vendor,
    String family,
    ModelTier tier,
    Set<String> requiredCapabilities,
    ModelLocality locality,
    CostTier maxCostTier,
    String authMethod
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

`ModelCatalogChangedEvent.java`:
```java
package io.casehub.platform.api.model;

import java.util.Set;

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

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn -pl platform-api test -Dtest=ModelQueryTest --batch-mode`
Expected: All 5 tests PASS.

- [ ] **Step 5: Run full platform-api test suite**

Run: `mvn -pl platform-api test --batch-mode`
Expected: All tests PASS.

- [ ] **Step 6: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/model/ModelRegistry.java platform-api/src/main/java/io/casehub/platform/api/model/ModelSource.java platform-api/src/main/java/io/casehub/platform/api/model/ModelQuery.java platform-api/src/main/java/io/casehub/platform/api/model/ModelCatalogChangedEvent.java platform-api/src/test/java/io/casehub/platform/api/model/ModelQueryTest.java
git commit -m "feat(#286): add ModelRegistry, ModelSource, ModelQuery, ModelCatalogChangedEvent SPIs

Queryable model registry SPI with predicate-based ModelQuery (builder pattern),
pull-based ModelSource refresh contract, and CDI event on catalog change.

Refs #286"
```

---

## Batch 2: Registry implementation + seed catalog

### Task 3: InMemoryModelRegistry + ModelRegistryRefresher

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/model/InMemoryModelRegistry.java`
- Create: `platform/src/main/java/io/casehub/platform/model/ModelRegistryRefresher.java`
- Test: `platform/src/test/java/io/casehub/platform/model/InMemoryModelRegistryTest.java`

**Interfaces:**
- Consumes: `ModelRegistry`, `ModelSource`, `ModelDescriptor`, `ModelQuery`, `ModelCatalogChangedEvent` from Tasks 1-2
- Produces: `InMemoryModelRegistry` (@ApplicationScoped, `replaceSource(sourceId, priority, models)` → `CatalogDelta`), `ModelRegistryRefresher` (@Startup + @Scheduled)

- [ ] **Step 1: Write failing tests**

Create `InMemoryModelRegistryTest.java` using `ide_create_file`:

```java
package io.casehub.platform.model;

import io.casehub.platform.api.model.CostTier;
import io.casehub.platform.api.model.ModelCapabilities;
import io.casehub.platform.api.model.ModelDescriptor;
import io.casehub.platform.api.model.ModelLocality;
import io.casehub.platform.api.model.ModelQuery;
import io.casehub.platform.api.model.ModelTier;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class InMemoryModelRegistryTest {

    private ModelDescriptor desc(String id, String vendor, String family, ModelTier tier,
            Set<String> caps, ModelLocality locality, CostTier cost, String authMethod) {
        return new ModelDescriptor(id, "backend", vendor, family, id, tier,
            caps, 200000, 16384, locality, cost, authMethod, Map.of());
    }

    private ModelDescriptor claudeSonnet() {
        return desc("claude-sonnet-5", "anthropic", "claude", ModelTier.STANDARD,
            Set.of(ModelCapabilities.TEXT, ModelCapabilities.VISION), ModelLocality.CLOUD,
            CostTier.HIGH, "api-key");
    }

    private ModelDescriptor gpt4() {
        return desc("gpt-4.1", "openai", "gpt-4", ModelTier.STANDARD,
            Set.of(ModelCapabilities.TEXT, ModelCapabilities.VISION, ModelCapabilities.CODE),
            ModelLocality.CLOUD, CostTier.MEDIUM, "api-key");
    }

    private ModelDescriptor llama() {
        return desc("llama-4-scout", "meta", "llama", ModelTier.STANDARD,
            Set.of(ModelCapabilities.TEXT), ModelLocality.LOCAL, CostTier.FREE, "local");
    }

    @Test
    void resolveById_returnsDescriptor() {
        var registry = new InMemoryModelRegistry();
        registry.replaceSource("src", 1, List.of(claudeSonnet()));
        assertThat(registry.resolveById("claude-sonnet-5")).isPresent();
        assertThat(registry.resolveById("claude-sonnet-5").get().vendor()).isEqualTo("anthropic");
    }

    @Test
    void resolveById_unknownReturnsEmpty() {
        var registry = new InMemoryModelRegistry();
        assertThat(registry.resolveById("nonexistent")).isEmpty();
    }

    @Test
    void query_filtersByVendor() {
        var registry = new InMemoryModelRegistry();
        registry.replaceSource("src", 1, List.of(claudeSonnet(), gpt4(), llama()));
        var results = registry.query(ModelQuery.builder().vendor("anthropic").build());
        assertThat(results).hasSize(1);
        assertThat(results.get(0).id()).isEqualTo("claude-sonnet-5");
    }

    @Test
    void query_filtersByFamily() {
        var registry = new InMemoryModelRegistry();
        registry.replaceSource("src", 1, List.of(claudeSonnet(), gpt4()));
        var results = registry.query(ModelQuery.builder().family("claude").build());
        assertThat(results).hasSize(1);
        assertThat(results.get(0).id()).isEqualTo("claude-sonnet-5");
    }

    @Test
    void query_filtersByCapabilities() {
        var registry = new InMemoryModelRegistry();
        registry.replaceSource("src", 1, List.of(claudeSonnet(), gpt4(), llama()));
        var results = registry.query(ModelQuery.builder()
            .requiredCapabilities(Set.of(ModelCapabilities.VISION)).build());
        assertThat(results).hasSize(2);
    }

    @Test
    void query_filtersByMaxCostTier() {
        var registry = new InMemoryModelRegistry();
        registry.replaceSource("src", 1, List.of(claudeSonnet(), gpt4(), llama()));
        var results = registry.query(ModelQuery.builder().maxCostTier(CostTier.MEDIUM).build());
        assertThat(results).extracting(ModelDescriptor::id)
            .containsExactlyInAnyOrder("gpt-4.1", "llama-4-scout");
    }

    @Test
    void query_nullCostTierExcludedFromCostConstrainedQuery() {
        var registry = new InMemoryModelRegistry();
        var noCost = desc("unknown-model", "vendor", "fam", ModelTier.STANDARD,
            Set.of(), ModelLocality.CLOUD, null, null);
        registry.replaceSource("src", 1, List.of(noCost, llama()));
        var results = registry.query(ModelQuery.builder().maxCostTier(CostTier.MEDIUM).build());
        assertThat(results).extracting(ModelDescriptor::id).containsExactly("llama-4-scout");
    }

    @Test
    void query_filtersByLocality() {
        var registry = new InMemoryModelRegistry();
        registry.replaceSource("src", 1, List.of(claudeSonnet(), llama()));
        var results = registry.query(ModelQuery.builder().locality(ModelLocality.LOCAL).build());
        assertThat(results).hasSize(1);
        assertThat(results.get(0).id()).isEqualTo("llama-4-scout");
    }

    @Test
    void query_filtersByAuthMethod() {
        var registry = new InMemoryModelRegistry();
        registry.replaceSource("src", 1, List.of(claudeSonnet(), llama()));
        var results = registry.query(ModelQuery.builder().authMethod("local").build());
        assertThat(results).hasSize(1);
        assertThat(results.get(0).id()).isEqualTo("llama-4-scout");
    }

    @Test
    void emptyRegistry_returnsEmpty() {
        var registry = new InMemoryModelRegistry();
        assertThat(registry.resolveById("any")).isEmpty();
        assertThat(registry.query(ModelQuery.all())).isEmpty();
        assertThat(registry.all()).isEmpty();
    }

    @Test
    void replaceSource_atomicPerSource() {
        var registry = new InMemoryModelRegistry();
        registry.replaceSource("src1", 1, List.of(claudeSonnet()));
        registry.replaceSource("src2", 1, List.of(gpt4()));
        assertThat(registry.all()).hasSize(2);
        registry.replaceSource("src1", 1, List.of());
        assertThat(registry.all()).hasSize(1);
        assertThat(registry.resolveById("gpt-4.1")).isPresent();
    }

    @Test
    void priorityResolution_higherPriorityWins() {
        var registry = new InMemoryModelRegistry();
        var seedModel = desc("claude-sonnet-5", "anthropic", "claude", ModelTier.STANDARD,
            Set.of(), ModelLocality.CLOUD, CostTier.MEDIUM, "api-key");
        var liveModel = desc("claude-sonnet-5", "anthropic", "claude", ModelTier.STANDARD,
            Set.of(ModelCapabilities.TEXT, ModelCapabilities.VISION), ModelLocality.CLOUD,
            CostTier.HIGH, "api-key");
        registry.replaceSource("seed", 0, List.of(seedModel));
        registry.replaceSource("live", 10, List.of(liveModel));
        var resolved = registry.resolveById("claude-sonnet-5").orElseThrow();
        assertThat(resolved.costTier()).isEqualTo(CostTier.HIGH);
        assertThat(resolved.capabilities()).contains(ModelCapabilities.VISION);
    }

    @Test
    void priorityShadowing_removingHigherExposesLower() {
        var registry = new InMemoryModelRegistry();
        var seedModel = desc("claude-sonnet-5", "anthropic", "claude", ModelTier.STANDARD,
            Set.of(), ModelLocality.CLOUD, CostTier.MEDIUM, "api-key");
        var liveModel = desc("claude-sonnet-5", "anthropic", "claude", ModelTier.STANDARD,
            Set.of(ModelCapabilities.VISION), ModelLocality.CLOUD, CostTier.HIGH, "api-key");
        registry.replaceSource("seed", 0, List.of(seedModel));
        registry.replaceSource("live", 10, List.of(liveModel));
        registry.replaceSource("live", 10, List.of());
        var resolved = registry.resolveById("claude-sonnet-5").orElseThrow();
        assertThat(resolved.costTier()).isEqualTo(CostTier.MEDIUM);
    }

    @Test
    void replaceSource_returnsDelta() {
        var registry = new InMemoryModelRegistry();
        var delta1 = registry.replaceSource("src", 1, List.of(claudeSonnet(), gpt4()));
        assertThat(delta1.addedIds()).containsExactlyInAnyOrder("claude-sonnet-5", "gpt-4.1");
        assertThat(delta1.removedIds()).isEmpty();

        var delta2 = registry.replaceSource("src", 1, List.of(claudeSonnet(), llama()));
        assertThat(delta2.addedIds()).containsExactly("llama-4-scout");
        assertThat(delta2.removedIds()).containsExactly("gpt-4.1");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl platform-api install -DskipTests --batch-mode && mvn -pl platform test -Dtest=InMemoryModelRegistryTest --batch-mode`
Expected: Compilation failure — `InMemoryModelRegistry` not found.

- [ ] **Step 3: Implement InMemoryModelRegistry**

Create `InMemoryModelRegistry.java` using `ide_create_file`:

```java
package io.casehub.platform.model;

import io.casehub.platform.api.model.CostTier;
import io.casehub.platform.api.model.ModelDescriptor;
import io.casehub.platform.api.model.ModelQuery;
import io.casehub.platform.api.model.ModelRegistry;
import jakarta.enterprise.context.ApplicationScoped;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.TreeSet;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;

@ApplicationScoped
public class InMemoryModelRegistry implements ModelRegistry {

    private final ConcurrentHashMap<String, ConcurrentHashMap<String, ModelDescriptor>> sources
        = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, Integer> sourcePriorities = new ConcurrentHashMap<>();
    private volatile Map<String, ModelDescriptor> resolvedView = Map.of();

    public record CatalogDelta(Set<String> addedIds, Set<String> removedIds, Set<String> updatedIds) {
        public boolean hasChanges() {
            return !addedIds.isEmpty() || !removedIds.isEmpty() || !updatedIds.isEmpty();
        }
    }

    public CatalogDelta replaceSource(String sourceId, int priority, List<ModelDescriptor> models) {
        var oldEntries = sources.getOrDefault(sourceId, new ConcurrentHashMap<>());
        var newEntries = new ConcurrentHashMap<String, ModelDescriptor>();
        for (ModelDescriptor model : models) {
            newEntries.put(model.id(), model);
        }

        Set<String> added = new TreeSet<>();
        Set<String> removed = new TreeSet<>();
        Set<String> updated = new TreeSet<>();

        for (String id : newEntries.keySet()) {
            if (!oldEntries.containsKey(id)) {
                added.add(id);
            } else if (!newEntries.get(id).equals(oldEntries.get(id))) {
                updated.add(id);
            }
        }
        for (String id : oldEntries.keySet()) {
            if (!newEntries.containsKey(id)) {
                removed.add(id);
            }
        }

        if (newEntries.isEmpty()) {
            sources.remove(sourceId);
            sourcePriorities.remove(sourceId);
        } else {
            sources.put(sourceId, newEntries);
            sourcePriorities.put(sourceId, priority);
        }

        rebuildView();
        return new CatalogDelta(added, removed, updated);
    }

    private void rebuildView() {
        var sorted = new ArrayList<>(sourcePriorities.entrySet());
        sorted.sort(Comparator.comparingInt(Map.Entry<String, Integer>::getValue).reversed());

        var view = new LinkedHashMap<String, ModelDescriptor>();
        for (var entry : sorted) {
            var sourceEntries = sources.get(entry.getKey());
            if (sourceEntries != null) {
                for (var modelEntry : sourceEntries.entrySet()) {
                    view.putIfAbsent(modelEntry.getKey(), modelEntry.getValue());
                }
            }
        }
        resolvedView = Map.copyOf(view);
    }

    @Override
    public Optional<ModelDescriptor> resolveById(String modelId) {
        return Optional.ofNullable(resolvedView.get(modelId));
    }

    @Override
    public List<ModelDescriptor> query(ModelQuery query) {
        return resolvedView.values().stream()
            .filter(d -> query.vendor() == null || d.vendor().equals(query.vendor()))
            .filter(d -> query.family() == null || d.family().equals(query.family()))
            .filter(d -> query.tier() == null || d.tier() == query.tier())
            .filter(d -> query.requiredCapabilities().isEmpty()
                || d.capabilities().containsAll(query.requiredCapabilities()))
            .filter(d -> query.locality() == null || d.locality() == query.locality())
            .filter(d -> query.maxCostTier() == null
                || (d.costTier() != null && d.costTier().rank() <= query.maxCostTier().rank()))
            .filter(d -> query.authMethod() == null
                || (d.authMethod() != null && d.authMethod().equals(query.authMethod())))
            .toList();
    }

    @Override
    public List<ModelDescriptor> all() {
        return List.copyOf(resolvedView.values());
    }
}
```

- [ ] **Step 4: Create ModelRegistryRefresher**

Create `ModelRegistryRefresher.java` using `ide_create_file`:

```java
package io.casehub.platform.model;

import io.casehub.platform.api.model.ModelCatalogChangedEvent;
import io.casehub.platform.api.model.ModelDescriptor;
import io.casehub.platform.api.model.ModelSource;
import io.quarkus.runtime.Startup;
import io.quarkus.scheduler.Scheduled;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Event;
import jakarta.enterprise.inject.Any;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;
import java.util.List;
import org.jboss.logging.Logger;

@ApplicationScoped
public class ModelRegistryRefresher {

    private static final Logger LOG = Logger.getLogger(ModelRegistryRefresher.class);

    @Inject @Any Instance<ModelSource> sources;
    @Inject InMemoryModelRegistry registry;
    @Inject Event<ModelCatalogChangedEvent> catalogChanged;

    @Startup
    void initialRefresh() {
        refreshAll();
    }

    @Scheduled(every = "${casehub.model.registry.refresh-interval:1h}")
    void scheduledRefresh() {
        refreshAll();
    }

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

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -pl platform-api install -DskipTests --batch-mode && mvn -pl platform test -Dtest=InMemoryModelRegistryTest --batch-mode`
Expected: All 14 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add platform/src/main/java/io/casehub/platform/model/InMemoryModelRegistry.java platform/src/main/java/io/casehub/platform/model/ModelRegistryRefresher.java platform/src/test/java/io/casehub/platform/model/InMemoryModelRegistryTest.java
git commit -m "feat(#286): add InMemoryModelRegistry + ModelRegistryRefresher

Per-source ConcurrentHashMap storage with priority-resolved view. Atomic
per-source replacement. @Startup initial refresh + @Scheduled periodic.
Error-isolated per source. CDI event on catalog change.

Refs #286"
```

### Task 4: SeedCatalogModelSource + seed-catalog.yaml

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/model/SeedCatalogModelSource.java`
- Create: `platform/src/main/resources/models/seed-catalog.yaml`
- Test: `platform/src/test/java/io/casehub/platform/model/SeedCatalogModelSourceTest.java`

**Interfaces:**
- Consumes: `ModelSource`, `ModelDescriptor` from Tasks 1-2
- Produces: `SeedCatalogModelSource` (@ApplicationScoped, priority 0, reads classpath YAML)

- [ ] **Step 1: Write failing tests**

Create `SeedCatalogModelSourceTest.java` using `ide_create_file`:

```java
package io.casehub.platform.model;

import io.casehub.platform.api.model.ModelCapabilities;
import io.casehub.platform.api.model.ModelLocality;
import io.casehub.platform.api.model.ModelTier;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class SeedCatalogModelSourceTest {

    private final SeedCatalogModelSource source = new SeedCatalogModelSource();

    @Test
    void sourceId() {
        assertThat(source.sourceId()).isEqualTo("seed-catalog");
    }

    @Test
    void priority_isLowest() {
        assertThat(source.priority()).isEqualTo(0);
    }

    @Test
    void refresh_returnsModels() {
        var models = source.refresh();
        assertThat(models).isNotEmpty();
    }

    @Test
    void refresh_noDuplicateIds() {
        var models = source.refresh();
        var ids = models.stream().map(m -> m.id()).toList();
        assertThat(ids).doesNotHaveDuplicates();
    }

    @Test
    void refresh_claudeSonnet5Present() {
        var models = source.refresh();
        var sonnet = models.stream()
            .filter(m -> m.id().equals("claude-sonnet-5"))
            .findFirst().orElseThrow();
        assertThat(sonnet.vendor()).isEqualTo("anthropic");
        assertThat(sonnet.family()).isEqualTo("claude");
        assertThat(sonnet.backendKey()).isEqualTo("claude");
        assertThat(sonnet.tier()).isEqualTo(ModelTier.STANDARD);
        assertThat(sonnet.capabilities()).contains(ModelCapabilities.TEXT, ModelCapabilities.VISION);
        assertThat(sonnet.locality()).isEqualTo(ModelLocality.CLOUD);
    }

    @Test
    void refresh_localModelPresent() {
        var models = source.refresh();
        var local = models.stream()
            .filter(m -> m.locality() == ModelLocality.LOCAL)
            .findFirst().orElseThrow();
        assertThat(local.vendor()).isEqualTo("meta");
    }

    @Test
    void integration_registryResolvesFromSeed() {
        var registry = new InMemoryModelRegistry();
        var models = source.refresh();
        registry.replaceSource(source.sourceId(), source.priority(), models);
        assertThat(registry.resolveById("claude-sonnet-5")).isPresent();
        assertThat(registry.resolveById("gpt-4.1")).isPresent();
        assertThat(registry.resolveById("llama-4-scout")).isPresent();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl platform test -Dtest=SeedCatalogModelSourceTest --batch-mode`
Expected: Compilation failure.

- [ ] **Step 3: Create seed-catalog.yaml**

Copy the seed catalog YAML from the spec verbatim to `platform/src/main/resources/models/seed-catalog.yaml`. The spec contains the complete YAML with entries for Anthropic (Claude 5 family + Claude 4 family), OpenAI (GPT-4.1, o3, o4-mini, GPT-4o-mini), Google (Gemini 2.5 Pro/Flash), Meta (Llama 4 Scout/Maverick), and Mistral (Large, Codestral).

- [ ] **Step 4: Implement SeedCatalogModelSource**

Create `SeedCatalogModelSource.java` using `ide_create_file`:

```java
package io.casehub.platform.model;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import io.casehub.platform.api.model.CostTier;
import io.casehub.platform.api.model.ModelDescriptor;
import io.casehub.platform.api.model.ModelLocality;
import io.casehub.platform.api.model.ModelSource;
import io.casehub.platform.api.model.ModelTier;
import jakarta.enterprise.context.ApplicationScoped;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.jboss.logging.Logger;

@ApplicationScoped
public class SeedCatalogModelSource implements ModelSource {

    private static final Logger LOG = Logger.getLogger(SeedCatalogModelSource.class);
    private static final String CATALOG_PATH = "models/seed-catalog.yaml";
    private final ObjectMapper yaml = new ObjectMapper(new YAMLFactory());

    @Override
    public String sourceId() { return "seed-catalog"; }

    @Override
    public int priority() { return 0; }

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

    private List<ModelDescriptor> parseCatalog(InputStream is) throws IOException {
        JsonNode root = yaml.readTree(is);
        JsonNode models = root.path("models");
        if (!models.isArray()) return List.of();

        List<ModelDescriptor> result = new ArrayList<>();
        for (JsonNode node : models) {
            result.add(parseModel(node));
        }
        return result;
    }

    private ModelDescriptor parseModel(JsonNode node) {
        Set<String> capabilities = new HashSet<>();
        JsonNode capsNode = node.path("capabilities");
        if (capsNode.isArray()) {
            capsNode.forEach(n -> capabilities.add(n.asText()));
        }

        Map<String, String> properties = new LinkedHashMap<>();
        JsonNode propsNode = node.path("properties");
        if (propsNode.isObject()) {
            propsNode.fields().forEachRemaining(e -> properties.put(e.getKey(), e.getValue().asText()));
        }

        return new ModelDescriptor(
            node.get("id").asText(),
            node.get("backendKey").asText(),
            node.get("vendor").asText(),
            node.get("family").asText(),
            node.get("displayName").asText(),
            ModelTier.valueOf(node.get("tier").asText()),
            capabilities,
            node.get("contextWindow").asInt(),
            node.get("maxOutput").asInt(),
            ModelLocality.valueOf(node.get("locality").asText()),
            node.has("costTier") && !node.get("costTier").isNull()
                ? CostTier.valueOf(node.get("costTier").asText()) : null,
            node.has("authMethod") ? node.get("authMethod").asText(null) : null,
            properties
        );
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -pl platform test -Dtest=SeedCatalogModelSourceTest --batch-mode`
Expected: All 7 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add platform/src/main/java/io/casehub/platform/model/SeedCatalogModelSource.java platform/src/main/resources/models/seed-catalog.yaml platform/src/test/java/io/casehub/platform/model/SeedCatalogModelSourceTest.java
git commit -m "feat(#287): add SeedCatalogModelSource + seed-catalog.yaml

Priority 0 (lowest) seed catalog with 17 models from Anthropic, OpenAI,
Google, Meta, and Mistral. Parsed from classpath YAML. Air-gapped fallback.

Refs #287"
```

---

## Batch 3: Integration

### Task 5: DomainModelRegistry rename

**Files:**
- Rename: `mcp/src/main/java/io/casehub/platform/mcp/ModelRegistry.java` → `DomainModelRegistry.java` (use `ide_refactor_rename`)
- Modified by rename: `DomainResourceRegistrar.java`, `CaseHubMcpTools.java`, `ReflectiveOperationDispatcher.java`, `GraphQLModelScanner.java`, `DynamicToolRegistrar.java`, `GraphQLModelScannerTest.java`

**Interfaces:**
- Consumes: nothing new
- Produces: `DomainModelRegistry` (same class, new name — all 6 references updated automatically by IDE)

- [ ] **Step 1: Rename via IntelliJ**

Run: `ide_refactor_rename` on `mcp/src/main/java/io/casehub/platform/mcp/ModelRegistry.java` → `DomainModelRegistry`

This is an IntelliJ semantic rename — all 5 production consumers and 1 test reference are updated automatically.

- [ ] **Step 2: Verify no compilation errors**

Run: `ide_diagnostics` on the MCP module, then:
Run: `mvn -pl mcp test --batch-mode`
Expected: All tests PASS with renamed class.

- [ ] **Step 3: Commit**

```bash
git add mcp/
git commit -m "refactor(#286): rename ModelRegistry → DomainModelRegistry in MCP module

Resolves naming collision with the new ModelRegistry SPI in platform-api.
Six references updated via IDE refactor-rename.

Refs #286"
```

### Task 6: RoutingAgentProvider three-step resolution

**Files:**
- Modify: `agent-router/pom.xml` — add `casehub-platform-api` compile dependency
- Modify: `agent-router/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java`
- Modify: `agent-router/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderTest.java`

**Interfaces:**
- Consumes: `ModelRegistry` (SPI from Task 2), `InMemoryModelRegistry` (impl from Task 3)
- Produces: Modified `RoutingAgentProvider` with three-step resolution: registry → key → fail-fast. Config rewriting so backends receive model-specific API ID or null.

- [ ] **Step 1: Write failing tests**

Add tests to `RoutingAgentProviderTest.java` using `ide_insert_member`:

```java
@Test
void registryPath_resolvesModelIdToBackend() {
    var registry = new InMemoryModelRegistry();
    registry.replaceSource("test", 1, List.of(
        new ModelDescriptor("claude-sonnet-5", "claude", "anthropic", "claude",
            "Claude Sonnet 5", ModelTier.STANDARD, Set.of(), 200000, 16384,
            ModelLocality.CLOUD, CostTier.HIGH, "api-key", Map.of())
    ));
    var router = new RoutingAgentProvider(
        List.of(stubBackend("claude")), "claude", registry);
    var config = AgentSessionConfig.of("sys", "user", "claude-sonnet-5");
    var events = router.invoke(config).collect().asList().await().indefinitely();
    assertThat(((AgentEvent.TextDelta) events.get(0)).text()).isEqualTo("from-claude");
}

@Test
void registryPath_missingBackendThrows() {
    var registry = new InMemoryModelRegistry();
    registry.replaceSource("test", 1, List.of(
        new ModelDescriptor("claude-sonnet-5", "claude", "anthropic", "claude",
            "Claude Sonnet 5", ModelTier.STANDARD, Set.of(), 200000, 16384,
            ModelLocality.CLOUD, CostTier.HIGH, "api-key", Map.of())
    ));
    var router = new RoutingAgentProvider(
        List.of(stubBackend("openai")), "openai", registry);
    var config = AgentSessionConfig.of("sys", "user", "claude-sonnet-5");
    assertThatThrownBy(() -> router.invoke(config))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageContaining("claude");
}

@Test
void keyPath_fallsBackWhenNotInRegistry() {
    var registry = new InMemoryModelRegistry();
    var router = new RoutingAgentProvider(
        List.of(stubBackend("claude")), "claude", registry);
    var config = AgentSessionConfig.of("sys", "user", "claude");
    var events = router.invoke(config).collect().asList().await().indefinitely();
    assertThat(((AgentEvent.TextDelta) events.get(0)).text()).isEqualTo("from-claude");
}

@Test
void failFast_unknownModelThrows() {
    var registry = new InMemoryModelRegistry();
    var router = new RoutingAgentProvider(
        List.of(stubBackend("claude")), "claude", registry);
    var config = AgentSessionConfig.of("sys", "user", "nonexistent-model");
    assertThatThrownBy(() -> router.invoke(config))
        .isInstanceOf(IllegalArgumentException.class)
        .hasMessageContaining("nonexistent-model");
}

@Test
void emptyRegistry_existingBehaviorPreserved() {
    var registry = new InMemoryModelRegistry();
    var router = new RoutingAgentProvider(
        List.of(stubBackend("claude"), stubBackend("openai")), "claude", registry);
    var config = AgentSessionConfig.of("sys", "user");
    var events = router.invoke(config).collect().asList().await().indefinitely();
    assertThat(((AgentEvent.TextDelta) events.get(0)).text()).isEqualTo("from-claude");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl platform-api,platform install -DskipTests --batch-mode && mvn -pl agent-router test --batch-mode`
Expected: Compilation failure — new constructor not found.

- [ ] **Step 3: Add platform-api dependency to agent-router pom.xml**

Add to `agent-router/pom.xml` dependencies:

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-api</artifactId>
    <version>${project.version}</version>
</dependency>
```

- [ ] **Step 4: Modify RoutingAgentProvider**

Use `ide_edit_member` to update `RoutingAgentProvider`:

1. Add `ModelRegistry` field and new test constructor accepting it
2. Replace `resolve(String model)` with three-step resolution returning `ResolvedRoute`
3. Update `invoke()` and `openSession()` to use config rewriting

Add `ResolvedRoute` record:
```java
private record ResolvedRoute(AgentBackend backend, String apiModelId) {}
```

New test constructor:
```java
RoutingAgentProvider(Iterable<AgentBackend> backends, String defaultKey, ModelRegistry modelRegistry) {
    this.backends = new HashMap<>();
    this.modelRegistry = modelRegistry;
    AgentBackend fallback = null;
    for (AgentBackend backend : backends) {
        this.backends.put(backend.key(), backend);
        if (backend.key().equals(defaultKey)) {
            fallback = backend;
        }
    }
    this.defaultBackend = fallback;
}
```

Updated `resolve()`:
```java
private ResolvedRoute resolve(String model) {
    if (model == null) {
        if (defaultBackend == null) {
            throw new IllegalStateException(
                "No default backend configured — set casehub.platform.agent.default-backend");
        }
        return new ResolvedRoute(defaultBackend, null);
    }

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

    AgentBackend backend = backends.get(model);
    if (backend != null) return new ResolvedRoute(backend, null);

    throw new IllegalArgumentException("No model or backend for: " + model +
        ". Available backends: " + backends.keySet());
}
```

Updated `invoke()` and `openSession()`:
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

Update CDI constructor to inject `ModelRegistry`:
```java
@Inject
public RoutingAgentProvider(@Any Instance<AgentBackend> backends,
                            RoutingAgentProperties properties,
                            ModelRegistry modelRegistry) {
    this.modelRegistry = modelRegistry;
    // ... rest unchanged
}
```

- [ ] **Step 5: Update existing tests for new constructor**

Update existing tests in `RoutingAgentProviderTest.java` to pass an empty `InMemoryModelRegistry` as the third constructor argument:

```java
// Replace all occurrences of:
new RoutingAgentProvider(List.of(...), "claude")
// With:
new RoutingAgentProvider(List.of(...), "claude", new InMemoryModelRegistry())
```

Update `unknownKeyWithCatchAllFallsThrough` — the langchain4j fallback is removed for non-null model refs. This test should now expect `IllegalArgumentException` instead of langchain4j fallback (or remove it and rely on `failFast_unknownModelThrows`).

- [ ] **Step 6: Run all agent-router tests**

Run: `mvn -pl platform-api,platform install -DskipTests --batch-mode && mvn -pl agent-router test --batch-mode`
Expected: All tests PASS (old + new).

- [ ] **Step 7: Run full platform build**

Run: `mvn --batch-mode install`
Expected: Full build succeeds.

- [ ] **Step 8: Commit**

```bash
git add agent-router/
git commit -m "feat(#286): RoutingAgentProvider three-step model resolution

Registry → key → fail-fast resolution with config rewriting. Backends
receive model-specific API ID or null (default). ModelRegistry injected
via CDI — empty registry preserves existing key-based behavior.

Refs #286"
```

---

## References

- [2026-09-11-model-registry-spi-design.md] — design spec this plan implements
- [agent-api/src/main/java/io/casehub/platform/agent/AgentBackend.java] — key() method
- [agent-api/src/main/java/io/casehub/platform/agent/AgentSessionConfig.java] — model field
- [agent-router/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java] — resolve() method
- [agent-router/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderTest.java] — existing test patterns
- [agent-router/pom.xml] — dependency to modify
- [mcp/src/main/java/io/casehub/platform/mcp/ModelRegistry.java] — class to rename
- [GitHub #285] — LLM model registry epic
- [GitHub #286] — ModelRegistry SPI
- [GitHub #287] — Seed catalog
