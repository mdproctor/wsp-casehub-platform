# Manifest-Driven Model Chains Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #623 — feat: manifest-driven model chains — tier-based capability routing with provider fallback

**Goal:** Make LLM selection entirely manifest-driven with chain fallback and simulation as the zero-dependency floor.

**Architecture:** Chain aliases in the manifest resolve to `ModelChain` (not single `ModelQuery`). The router's existing chain resolution handles fallback. `SimulatedAgentBackend` becomes CDI-discoverable with key `"simulation"` and works without a corpus. No simulation-specific routing — `defaults.backend` and `backendKey` filtering handle selection.

**Tech Stack:** Java 21, Quarkus CDI, Jackson, Mutiny, JUnit 5

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA, no casehubio imports
- `agent-config-core/` depends on platform-api + Jackson + jboss-logging
- `agent-router-core/` depends on platform-api + agent-api + Mutiny + jboss-logging
- `agent-simulation-core/` depends on agent-api + simulation-core
- All tests: JUnit 5 + AssertJ. Use `@QuarkusTest` only in CDI integration modules.
- Every commit references issue #623

---

## Batch 1: Foundation — ModelQuery backendKey filter

### Task 1: Add `backendKey` to `ModelQuery` and `InMemoryModelRegistry`

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/model/ModelQuery.java`
- Modify: `platform/src/main/java/io/casehub/platform/model/InMemoryModelRegistry.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/model/ModelQueryTest.java`
- Test: `platform/src/test/java/io/casehub/platform/model/InMemoryModelRegistryTest.java`

**Interfaces:**
- Produces: `ModelQuery.backendKey()` accessor (nullable String), `ModelQuery.Builder.backendKey(String)` method

- [ ] **Step 1: Write failing test for `ModelQuery.backendKey`**

```java
@Test
void builderSetsBackendKey() {
    var query = ModelQuery.builder()
            .tier(ModelTier.FAST)
            .backendKey("simulation")
            .build();
    assertThat(query.backendKey()).isEqualTo("simulation");
    assertThat(query.tier()).isEqualTo(ModelTier.FAST);
}

@Test
void allQueryHasNullBackendKey() {
    assertThat(ModelQuery.all().backendKey()).isNull();
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform-api -Dtest=ModelQueryTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation error — `backendKey` doesn't exist

- [ ] **Step 3: Add `backendKey` field to `ModelQuery`**

Add `String backendKey` as the 10th record component, after `preferVendor`:

```java
public record ModelQuery(
        String vendor,
        String family,
        ModelTier tier,
        Set<String> requiredCapabilities,
        ModelLocality locality,
        CostTier maxCostTier,
        Integer minContextWindow,
        Integer minMaxOutput,
        String preferVendor,
        String backendKey
) {
```

Update `all()` factory — add `null` as 10th arg:
```java
public static ModelQuery all() {
    return new ModelQuery(null, null, null, Set.of(), null, null, null, null, null, null);
}
```

Add Builder field + method:
```java
private String backendKey;

public Builder backendKey(String backendKey) {
    this.backendKey = backendKey;
    return this;
}
```

Update `Builder.build()` — add `backendKey` as 10th arg:
```java
public ModelQuery build() {
    return new ModelQuery(vendor, family, tier, requiredCapabilities,
                          locality, maxCostTier, minContextWindow, minMaxOutput,
                          preferVendor, backendKey);
}
```

- [ ] **Step 4: Fix all compilation errors**

Every call to `new ModelQuery(...)` or `ModelQuery.builder()...build()` in the codebase needs updating. Find all usages:

Key files to update (add `null` as 10th arg or leave builder unchanged):
- `agent-config-core/.../ManifestProcessor.java` — `toModelQuery()` builder: add `.backendKey(null)` or leave unchanged (builder defaults to null)
- `agent-router-core/.../RoutingAgentProvider.java` — `resolveTier()` builder: unchanged (builder defaults)
- Test files creating `ModelQuery` directly: add `null` as 10th arg

Run: `mvn --batch-mode compile -pl platform-api,platform,agent-config-core,agent-router-core`
Expected: compilation succeeds

- [ ] **Step 5: Run ModelQuery test to verify it passes**

Run: `mvn --batch-mode test -pl platform-api -Dtest=ModelQueryTest`
Expected: PASS

- [ ] **Step 6: Write failing test for `InMemoryModelRegistry` backendKey filtering**

In `InMemoryModelRegistryTest.java`:

```java
@Test
void queryWithBackendKeyFiltersToMatchingBackend() {
    var ollamaModel = descriptorBuilder("gemma3", "ollama").tier(ModelTier.FAST).build();
    var simModel = descriptorBuilder("sim-fast", "simulation").tier(ModelTier.FAST).build();
    registry.replaceSource("test", 1, List.of(ollamaModel, simModel));

    var query = ModelQuery.builder().tier(ModelTier.FAST).backendKey("simulation").build();
    var results = registry.query(query);

    assertThat(results).hasSize(1);
    assertThat(results.get(0).id()).isEqualTo("sim-fast");
}

@Test
void queryWithoutBackendKeyReturnsAll() {
    var ollamaModel = descriptorBuilder("gemma3", "ollama").tier(ModelTier.FAST).build();
    var simModel = descriptorBuilder("sim-fast", "simulation").tier(ModelTier.FAST).build();
    registry.replaceSource("test", 1, List.of(ollamaModel, simModel));

    var query = ModelQuery.builder().tier(ModelTier.FAST).build();
    var results = registry.query(query);

    assertThat(results).hasSize(2);
}
```

- [ ] **Step 7: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform -Dtest=InMemoryModelRegistryTest#queryWithBackendKeyFiltersToMatchingBackend`
Expected: FAIL — returns 2 results instead of 1

- [ ] **Step 8: Add `backendKey` filter to `InMemoryModelRegistry.query()`**

In the stream filter chain inside `query()`, add:

```java
.filter(d -> query.backendKey() == null || query.backendKey().equals(d.backendKey()))
```

- [ ] **Step 9: Run all registry tests**

Run: `mvn --batch-mode test -pl platform -Dtest=InMemoryModelRegistryTest`
Expected: all PASS

- [ ] **Step 10: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/model/ModelQuery.java \
       platform/src/main/java/io/casehub/platform/model/InMemoryModelRegistry.java \
       platform-api/src/test/ platform/src/test/
git commit -m "$(cat <<'EOF'
feat(#623): add backendKey filter to ModelQuery and InMemoryModelRegistry

ModelQuery gains a nullable backendKey field for hard filtering by
backend (unlike preferVendor which is a tiebreaker). InMemoryModelRegistry
respects this field in query() — only models on the matching backend
are returned.

Refs #623

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Batch 2: Chain Aliases — manifest to router pipeline

### Task 2: ChainEntry + AliasDeclaration chain field + ManifestProcessor

**Files:**
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ChainEntry.java`
- Modify: `agent-config-core/src/main/java/io/casehub/platform/agent/config/AliasDeclaration.java`
- Modify: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestProcessor.java`
- Modify: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestResult.java`
- Test: `agent-config-core/src/test/java/io/casehub/platform/agent/config/ManifestProcessorTest.java`
- Test: `agent-config-core/src/test/java/io/casehub/platform/agent/config/ChainEntryTest.java`

**Interfaces:**
- Consumes: `ModelQuery.backendKey()` from Task 1, `ModelChain`, `ModelChainEntry.Named`, `ModelChainEntry.Queried`
- Produces: `ManifestResult.aliases()` returns `Map<String, ModelChain>`, `ChainEntry` record, `ManifestProcessor.toModelChain(AliasDeclaration)`

- [ ] **Step 1: Write failing test for ChainEntry → ModelChainEntry conversion**

```java
// ChainEntryTest.java
@Test
void queriedEntryConvertsToModelQuery() {
    var entry = new ChainEntry(null, "FAST", List.of(), "LOCAL", null, null, null, null, "simulation");
    assertThat(entry.model()).isNull();
    assertThat(entry.tier()).isEqualTo("FAST");
    assertThat(entry.backendKey()).isEqualTo("simulation");
}

@Test
void namedEntryHasModelRef() {
    var entry = new ChainEntry("claude-opus-5", null, List.of(), null, null, null, null, null, null);
    assertThat(entry.model()).isEqualTo("claude-opus-5");
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: compilation error — `ChainEntry` doesn't exist

- [ ] **Step 3: Create ChainEntry record**

```java
package io.casehub.platform.agent.config;

import com.fasterxml.jackson.annotation.JsonProperty;
import java.util.List;

public record ChainEntry(
        String model,
        String tier,
        List<String> capabilities,
        String locality,
        @JsonProperty("max-cost") String maxCost,
        @JsonProperty("min-context") Integer minContext,
        @JsonProperty("min-output") Integer minOutput,
        @JsonProperty("prefer-vendor") String preferVendor,
        @JsonProperty("backend-key") String backendKey
) {
    public ChainEntry {
        capabilities = capabilities != null ? List.copyOf(capabilities) : List.of();
    }
}
```

- [ ] **Step 4: Run ChainEntry test**

Run: `mvn --batch-mode test -pl agent-config-core -Dtest=ChainEntryTest`
Expected: PASS

- [ ] **Step 5: Write failing test for AliasDeclaration with chain**

```java
// ManifestProcessorTest.java
@Test
void chainAliasProducesModelChain() {
    var entry1 = new ChainEntry(null, "FAST", List.of(), "LOCAL", null, null, null, null, null);
    var entry2 = new ChainEntry(null, "FAST", List.of(), "CLOUD", null, null, null, null, null);
    var alias = new AliasDeclaration(null, List.of(), null, null, null, null, null, null, List.of(entry1, entry2));

    var chain = ManifestProcessor.toModelChain(alias);

    assertThat(chain.entries()).hasSize(2);
    assertThat(chain.entries().get(0)).isInstanceOf(ModelChain.ModelChainEntry.Queried.class);
    var q1 = (ModelChain.ModelChainEntry.Queried) chain.entries().get(0);
    assertThat(q1.query().tier()).isEqualTo(ModelTier.FAST);
    assertThat(q1.query().locality()).isEqualTo(ModelLocality.LOCAL);
}

@Test
void singleQueryAliasProducesSingleEntryChain() {
    var alias = new AliasDeclaration("FAST", List.of(), null, null, null, null, null, null, null);

    var chain = ManifestProcessor.toModelChain(alias);

    assertThat(chain.entries()).hasSize(1);
    var q = (ModelChain.ModelChainEntry.Queried) chain.entries().get(0);
    assertThat(q.query().tier()).isEqualTo(ModelTier.FAST);
}

@Test
void chainWithNamedEntryProducesNamedChainEntry() {
    var entry = new ChainEntry("claude-opus-5", null, List.of(), null, null, null, null, null, null);
    var alias = new AliasDeclaration(null, List.of(), null, null, null, null, null, null, List.of(entry));

    var chain = ManifestProcessor.toModelChain(alias);

    assertThat(chain.entries()).hasSize(1);
    assertThat(chain.entries().get(0)).isInstanceOf(ModelChain.ModelChainEntry.Named.class);
    var n = (ModelChain.ModelChainEntry.Named) chain.entries().get(0);
    assertThat(n.modelRef()).isEqualTo("claude-opus-5");
}

@Test
void chainWithBackendKeyProducesQueryWithBackendKey() {
    var entry = new ChainEntry(null, "FAST", List.of(), null, null, null, null, null, "simulation");
    var alias = new AliasDeclaration(null, List.of(), null, null, null, null, null, null, List.of(entry));

    var chain = ManifestProcessor.toModelChain(alias);

    var q = (ModelChain.ModelChainEntry.Queried) chain.entries().get(0);
    assertThat(q.query().backendKey()).isEqualTo("simulation");
}

@Test
void chainAndQueryFieldsMutuallyExclusive() {
    var entry = new ChainEntry(null, "FAST", List.of(), null, null, null, null, null, null);
    var alias = new AliasDeclaration("STANDARD", List.of(), null, null, null, null, null, null, List.of(entry));

    assertThatThrownBy(() -> ManifestProcessor.toModelChain(alias))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("mutually exclusive");
}

@Test
void emptyChainRejected() {
    var alias = new AliasDeclaration(null, List.of(), null, null, null, null, null, null, List.of());

    assertThatThrownBy(() -> ManifestProcessor.toModelChain(alias))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("empty");
}
```

- [ ] **Step 6: Run test to verify it fails**

Expected: compilation error — `AliasDeclaration` doesn't have `chain` field, `ManifestProcessor.toModelChain()` doesn't exist

- [ ] **Step 7: Add `backendKey` and `chain` fields to AliasDeclaration**

```java
public record AliasDeclaration(
        String tier,
        List<String> capabilities,
        String locality,
        @JsonProperty("max-cost") String maxCost,
        @JsonProperty("min-context") Integer minContext,
        @JsonProperty("min-output") Integer minOutput,
        @JsonProperty("prefer-vendor") String preferVendor,
        @JsonProperty("backend-key") String backendKey,
        List<ChainEntry> chain
) {
    public AliasDeclaration {
        capabilities = capabilities != null ? List.copyOf(capabilities) : List.of();
        chain = chain != null ? List.copyOf(chain) : List.of();
    }
}
```

- [ ] **Step 8: Fix existing `AliasDeclaration` construction sites**

Find all places creating `AliasDeclaration` and add `null, null` (or `null, List.of()`) for the two new fields. Key test files:
- `ManifestProcessorTest.java` — existing test constructors
- `AgentConfigLoaderTest.java` — YAML deserialization (auto-handled by Jackson defaults)

- [ ] **Step 9: Implement `ManifestProcessor.toModelChain()` and update `processAliasesAndDefaults()`**

Add static method `toModelChain`:

```java
static ModelChain toModelChain(AliasDeclaration alias) {
    boolean hasQueryFields = alias.tier() != null || !alias.capabilities().isEmpty()
            || alias.locality() != null || alias.maxCost() != null
            || alias.minContext() != null || alias.minOutput() != null
            || alias.preferVendor() != null || alias.backendKey() != null;
    boolean hasChain = !alias.chain().isEmpty();

    if (hasQueryFields && hasChain) {
        throw new IllegalArgumentException(
                "Alias has both 'chain' and query fields — these are mutually exclusive");
    }
    if (hasChain) {
        if (alias.chain().isEmpty()) {
            throw new IllegalArgumentException("Alias 'chain' must not be empty");
        }
        return ModelChain.of(alias.chain().stream()
                .map(ManifestProcessor::toChainEntry)
                .toList());
    }
    return ModelChain.of(List.of(new ModelChain.ModelChainEntry.Queried(toModelQuery(alias))));
}

private static ModelChain.ModelChainEntry toChainEntry(ChainEntry entry) {
    if (entry.model() != null) {
        return new ModelChain.ModelChainEntry.Named(entry.model());
    }
    var query = ModelQuery.builder()
            .tier(entry.tier() != null ? ModelTier.valueOf(entry.tier()) : null)
            .requiredCapabilities(entry.capabilities() != null ? Set.copyOf(entry.capabilities()) : Set.of())
            .locality(entry.locality() != null ? ModelLocality.valueOf(entry.locality()) : null)
            .maxCostTier(entry.maxCost() != null ? CostTier.valueOf(entry.maxCost()) : null)
            .minContextWindow(entry.minContext())
            .minMaxOutput(entry.minOutput())
            .preferVendor(entry.preferVendor())
            .backendKey(entry.backendKey())
            .build();
    return new ModelChain.ModelChainEntry.Queried(query);
}
```

Update existing `toModelQuery` to also set backendKey:
```java
static ModelQuery toModelQuery(AliasDeclaration alias) {
    return ModelQuery.builder()
            .tier(alias.tier() != null ? ModelTier.valueOf(alias.tier()) : null)
            .requiredCapabilities(alias.capabilities() != null ? Set.copyOf(alias.capabilities()) : Set.of())
            .locality(alias.locality() != null ? ModelLocality.valueOf(alias.locality()) : null)
            .maxCostTier(alias.maxCost() != null ? CostTier.valueOf(alias.maxCost()) : null)
            .minContextWindow(alias.minContext())
            .minMaxOutput(alias.minOutput())
            .preferVendor(alias.preferVendor())
            .backendKey(alias.backendKey())
            .build();
}
```

Update `processAliasesAndDefaults()`:
```java
private ManifestResult processAliasesAndDefaults(Manifest manifest) {
    var aliases = new LinkedHashMap<String, ModelChain>();
    for (var entry : manifest.aliases().entrySet()) {
        aliases.put(entry.getKey(), toModelChain(entry.getValue()));
    }
    String defaultBackend = manifest.defaults() != null ? manifest.defaults().backend() : null;
    var pools = new java.util.ArrayList<>(manifest.pools().values());
    LOG.infof("Manifest processed: %d aliases, %d pools, default backend: %s",
            aliases.size(), pools.size(), defaultBackend != null ? defaultBackend : "(not set)");
    return new ManifestResult(aliases, defaultBackend, pools);
}
```

- [ ] **Step 10: Update `ManifestResult` type**

```java
import io.casehub.platform.api.model.ModelChain;

public record ManifestResult(Map<String, ModelChain> aliases, String defaultBackendKey, List<PoolDeclaration> pools) {
    public ManifestResult {
        aliases = aliases != null ? Map.copyOf(aliases) : Map.of();
        pools = pools != null ? List.copyOf(pools) : List.of();
    }

    public static ManifestResult empty() {
        return new ManifestResult(Map.of(), null, List.of());
    }
}
```

- [ ] **Step 11: Fix compilation errors in dependent modules**

The type change from `Map<String, ModelQuery>` to `Map<String, ModelChain>` breaks:
- `RoutingAgentProvider` constructors and factory methods — update `aliases` field type (done in Task 3)
- `RouterBeans` — passes `result.aliases()` which is now `Map<String, ModelChain>` (done in Task 3)
- Test files constructing `ManifestResult` directly

For now, update test files in `agent-config-core` only. Router changes are Task 3.

Run: `mvn --batch-mode test -pl agent-config-core`
Expected: PASS

- [ ] **Step 12: Write YAML deserialization test**

```java
// AgentConfigLoaderTest.java or ManifestProcessorTest.java
@Test
void yamlChainAliasDeserializesCorrectly() throws Exception {
    var yaml = """
            aliases:
              fast-local:
                chain:
                  - tier: FAST
                    locality: LOCAL
                  - tier: FAST
                    locality: CLOUD
              embedding:
                tier: EMBEDDING
            defaults:
              backend: claude
            """;
    Files.writeString(tempDir.resolve("agent-config.yaml"), yaml);

    var result = loader.load(tempDir, null);

    assertThat(result.aliases()).containsKeys("fast-local", "embedding");
    assertThat(result.aliases().get("fast-local").entries()).hasSize(2);
    assertThat(result.aliases().get("embedding").entries()).hasSize(1);
}

@Test
void yamlChainWithBackendKeyDeserializes() throws Exception {
    var yaml = """
            aliases:
              fast-fallback:
                chain:
                  - tier: FAST
                    locality: LOCAL
                  - tier: FAST
                    backend-key: simulation
            defaults:
              backend: ollama
            """;
    Files.writeString(tempDir.resolve("agent-config.yaml"), yaml);

    var result = loader.load(tempDir, null);

    var chain = result.aliases().get("fast-fallback");
    assertThat(chain.entries()).hasSize(2);
    var q2 = (ModelChain.ModelChainEntry.Queried) chain.entries().get(1);
    assertThat(q2.query().backendKey()).isEqualTo("simulation");
}

@Test
void yamlMixedChainWithNamedModel() throws Exception {
    var yaml = """
            aliases:
              mixed:
                chain:
                  - model: claude-opus-5
                  - tier: FLAGSHIP
            defaults:
              backend: claude
            """;
    Files.writeString(tempDir.resolve("agent-config.yaml"), yaml);

    var result = loader.load(tempDir, null);

    var chain = result.aliases().get("mixed");
    assertThat(chain.entries().get(0)).isInstanceOf(ModelChain.ModelChainEntry.Named.class);
    assertThat(chain.entries().get(1)).isInstanceOf(ModelChain.ModelChainEntry.Queried.class);
}
```

- [ ] **Step 13: Run full test suite and verify**

Run: `mvn --batch-mode test -pl agent-config-core`
Expected: all PASS

- [ ] **Step 14: Commit**

```bash
git add agent-config-core/src/
git commit -m "$(cat <<'EOF'
feat(#623): chain aliases in manifest — AliasDeclaration, ChainEntry, ManifestProcessor

AliasDeclaration gains chain and backendKey fields. ChainEntry supports
both named model refs and query constraints. ManifestProcessor.toModelChain()
converts aliases to ModelChain — single-query aliases become one-entry
chains for uniform handling. ManifestResult.aliases type changes to
Map<String, ModelChain>.

Refs #623

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 3: RoutingAgentProvider alias → chain resolution

**Files:**
- Modify: `agent-router-core/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java`
- Modify: `agent-router/src/main/java/io/casehub/platform/agent/router/quarkus/RouterBeans.java`
- Test: `agent-router-core/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderTest.java`
- Test: `agent-router-core/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderChainTest.java`
- Test: `agent-router-core/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderCreateTest.java`
- Test: `agent-router-core/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderRetryTest.java`

**Interfaces:**
- Consumes: `ManifestResult.aliases()` returns `Map<String, ModelChain>` from Task 2
- Produces: `RoutingAgentProvider` resolves alias names to chain fallback (invoke + openSession)

- [ ] **Step 1: Write failing tests for alias → chain resolution**

```java
// RoutingAgentProviderTest.java
@Test
void aliasWithChainResolvesFirstEntry() {
    var chain = ModelChain.of(List.of(
            new ModelChain.ModelChainEntry.Queried(ModelQuery.builder().tier(ModelTier.FAST).build()),
            new ModelChain.ModelChainEntry.Queried(ModelQuery.builder().tier(ModelTier.STANDARD).build())
    ));
    var aliases = Map.of("fast", chain);
    var provider = new RoutingAgentProvider(backendRegistry, "claude", modelRegistry, aliases);

    // Register a FAST model
    modelRegistry.replaceSource("test", 1, List.of(
            descriptor("haiku", "claude", ModelTier.FAST)));

    var route = resolveViaInvoke(provider, "fast");
    assertThat(route).isEqualTo("haiku");
}

@Test
void aliasChainFallsToSecondEntryWhenFirstFails() {
    var chain = ModelChain.of(List.of(
            new ModelChain.ModelChainEntry.Queried(ModelQuery.builder().tier(ModelTier.FAST).locality(ModelLocality.LOCAL).build()),
            new ModelChain.ModelChainEntry.Queried(ModelQuery.builder().tier(ModelTier.FAST).locality(ModelLocality.CLOUD).build())
    ));
    var aliases = Map.of("fast", chain);
    var provider = new RoutingAgentProvider(backendRegistry, "claude", modelRegistry, aliases);

    // Only register a CLOUD model — no LOCAL
    modelRegistry.replaceSource("test", 1, List.of(
            descriptor("haiku", "claude", ModelTier.FAST, ModelLocality.CLOUD)));

    var route = resolveViaInvoke(provider, "fast");
    assertThat(route).isEqualTo("haiku");
}

@Test
void aliasChainWithBackendKeyFiltersCorrectly() {
    var chain = ModelChain.of(List.of(
            new ModelChain.ModelChainEntry.Queried(ModelQuery.builder().tier(ModelTier.FAST).backendKey("simulation").build())
    ));
    var aliases = Map.of("fast", chain);
    var provider = new RoutingAgentProvider(backendRegistry, "simulation", modelRegistry, aliases);

    modelRegistry.replaceSource("test", 1, List.of(
            descriptor("gemma3", "ollama", ModelTier.FAST),
            descriptor("sim-fast", "simulation", ModelTier.FAST)));
    backendRegistry.register("simulation", "default", simulationBackend);

    var route = resolveViaInvoke(provider, "fast");
    assertThat(route).isEqualTo("sim-fast");
}

@Test
void singleQueryAliasStillWorks() {
    // backwards compatibility: alias without chain still works
    var chain = ModelChain.of(List.of(
            new ModelChain.ModelChainEntry.Queried(ModelQuery.builder().tier(ModelTier.FAST).build())
    ));
    var aliases = Map.of("fast", chain);
    var provider = new RoutingAgentProvider(backendRegistry, "claude", modelRegistry, aliases);

    modelRegistry.replaceSource("test", 1, List.of(
            descriptor("haiku", "claude", ModelTier.FAST)));

    var route = resolveViaInvoke(provider, "fast");
    assertThat(route).isEqualTo("haiku");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: compilation error — constructors take `Map<String, ModelQuery>`, not `Map<String, ModelChain>`

- [ ] **Step 3: Update `RoutingAgentProvider` field and constructors**

Change the `aliases` field type:
```java
private final Map<String, ModelChain> aliases;
```

Update ALL constructors to take `Map<String, ModelChain> aliases` instead of `Map<String, ModelQuery> aliases`.

Update both `create()` factory methods to pass `result.aliases()` (already `Map<String, ModelChain>` from Task 2).

- [ ] **Step 4: Update `invoke()` to handle alias → chain**

Add alias chain detection at the top of `invoke()`:

```java
@Override
public Multi<AgentEvent> invoke(AgentSessionConfig config) {
    // Alias → chain resolution
    if (config.model() != null && aliases.containsKey(config.model())) {
        var aliasChain = aliases.get(config.model());
        var chainConfig = config.withModelChain(aliasChain);
        return resolveAndInvokeWithRetry(chainConfig);
    }
    if (config.modelChain() != null && !config.modelChain().isEmpty()) {
        return resolveAndInvokeWithRetry(config);
    }
    var route = config.modelQuery() != null ? resolveQuery(config.modelQuery()) : resolve(config.model());
    var rewritten = new AgentSessionConfig(
            config.systemPrompt(), config.userPrompt(), config.mcpServers(),
            config.timeout(), config.correlationId(), route.apiModelId());
    if (poolRegistry != null) {
        var pool = poolRegistry.findPool(route.backend().key(), rewritten.model());
        if (pool.isPresent()) {
            return pool.get().invokeViaSession(rewritten);
        }
    }
    return route.backend().invoke(rewritten);
}
```

- [ ] **Step 5: Update `resolveFromInit()` and `resolveFromConfig()` for alias → chain**

```java
private ResolvedRoute resolveFromInit(AgentSessionInit init) {
    // Alias → chain resolution
    if (init.model() != null && aliases.containsKey(init.model())) {
        return resolveChain(aliases.get(init.model()), availabilityFilter);
    }
    if (init.modelChain() != null && !init.modelChain().isEmpty()) {
        return resolveChain(init.modelChain(), availabilityFilter);
    }
    return init.modelQuery() != null
           ? resolveQuery(init.modelQuery())
           : resolve(init.model());
}

private ResolvedRoute resolveFromConfig(AgentSessionConfig config) {
    // Alias → chain resolution
    if (config.model() != null && aliases.containsKey(config.model())) {
        return resolveChain(aliases.get(config.model()), availabilityFilter);
    }
    if (config.modelChain() != null && !config.modelChain().isEmpty()) {
        return resolveChain(config.modelChain(), availabilityFilter);
    }
    return config.modelQuery() != null
           ? resolveQuery(config.modelQuery())
           : resolve(config.model());
}
```

- [ ] **Step 6: Remove alias handling from `resolve()` Step 0**

Remove the alias block from `resolve()` since aliases are now handled at the caller level:

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

    // Step 1: Tier reference
    if (ModelRef.isTierRef(model)) {
        return resolveTier(ModelRef.parseTier(model));
    }

    // Step 2: Registry ID
    // ... (unchanged)
```

- [ ] **Step 7: Update `RouterBeans`**

The `RouterBeans` passes `result.aliases()` to `RoutingAgentProvider.create()`. Since `ManifestResult.aliases()` now returns `Map<String, ModelChain>` and the factory accepts that type, this should compile with no code change. Verify.

- [ ] **Step 8: Fix all existing test compilation errors**

Update all test files creating `RoutingAgentProvider` with aliases:
- Where tests pass `Map<String, ModelQuery>`, convert to `Map<String, ModelChain>`:
  ```java
  // Before:
  Map.of("fast", ModelQuery.builder().tier(ModelTier.FAST).build())
  // After:
  Map.of("fast", ModelChain.of(List.of(
      new ModelChain.ModelChainEntry.Queried(ModelQuery.builder().tier(ModelTier.FAST).build()))))
  ```

Create a test helper:
```java
private static ModelChain singleQuery(ModelQuery query) {
    return ModelChain.of(List.of(new ModelChain.ModelChainEntry.Queried(query)));
}
```

- [ ] **Step 9: Run full router test suite**

Run: `mvn --batch-mode test -pl agent-router-core,agent-router`
Expected: all PASS

- [ ] **Step 10: Run full build to catch any remaining breakage**

Run: `mvn --batch-mode test -pl platform-api,platform,agent-config-core,agent-router-core,agent-router`
Expected: all PASS

- [ ] **Step 11: Commit**

```bash
git add agent-router-core/src/ agent-router/src/
git commit -m "$(cat <<'EOF'
feat(#623): alias → chain resolution in RoutingAgentProvider

Aliases now resolve to ModelChain instead of single ModelQuery. invoke()
and openSession() detect alias names and delegate to chain resolution
(resolveAndInvokeWithRetry for reactive, resolveChain for synchronous).
Alias handling removed from resolve() to prevent shadowing Named chain
entries.

Refs #623

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Batch 3: Simulation Backend — routable with canned-response fallback

### Task 4: SimulatedAgentBackend — key rename, nullable runtime, canned response, openSession, CDI

**Files:**
- Modify: `agent-simulation-core/src/main/java/io/casehub/platform/agent/simulation/SimulatedAgentBackend.java`
- Create: `agent-simulation-core/src/main/java/io/casehub/platform/agent/simulation/SimulationAgentSession.java`
- Modify: `simulation-config/src/main/java/io/casehub/platform/simulation/quarkus/SimulationConfigBeans.java`
- Test: `agent-simulation-core/src/test/java/io/casehub/platform/agent/simulation/SimulatedAgentBackendTest.java`
- Test: `agent-simulation-core/src/test/java/io/casehub/platform/agent/simulation/SimulationAgentSessionTest.java`

**Interfaces:**
- Consumes: `AgentBackend`, `AgentSession`, `AgentEvent.TextDelta`, `AgentEvent.InvocationComplete`, `SimulationRuntime`
- Produces: `SimulatedAgentBackend` with key `"simulation"`, CDI-discoverable, works without corpus

- [ ] **Step 1: Write failing tests for key rename and canned response**

```java
// SimulatedAgentBackendTest.java
@Test
void keyIsSimulation() {
    var backend = new SimulatedAgentBackend(null);
    assertThat(backend.key()).isEqualTo("simulation");
}

@Test
void invokeWithoutRuntimeReturnsCannedResponse() {
    var backend = new SimulatedAgentBackend(null);
    var config = AgentSessionConfig.of("system", "hello").withModel("sim-fast");

    var events = backend.invoke(config).collect().asList().await().indefinitely();

    assertThat(events).hasSize(2);
    assertThat(events.get(0)).isInstanceOf(AgentEvent.TextDelta.class);
    var text = ((AgentEvent.TextDelta) events.get(0)).text();
    assertThat(text).contains("sim-fast");
    assertThat(events.get(1)).isInstanceOf(AgentEvent.InvocationComplete.class);
    var complete = (AgentEvent.InvocationComplete) events.get(1);
    assertThat(complete.isError()).isFalse();
}

@Test
void invokeWithRuntimeButNoStrategyReturnsCannedResponse() {
    var runtime = mock(SimulationRuntime.class);
    when(runtime.strategyFor(any())).thenReturn(Optional.empty());

    var backend = new SimulatedAgentBackend(runtime);
    var config = AgentSessionConfig.of("system", "hello").withModel("sim-fast");

    var events = backend.invoke(config).collect().asList().await().indefinitely();

    assertThat(events).hasSize(2);
    assertThat(events.get(0)).isInstanceOf(AgentEvent.TextDelta.class);
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: compilation error or assertion failure — key is `"simulated"`, constructor requires non-null runtime

- [ ] **Step 3: Update `SimulatedAgentBackend`**

```java
public class SimulatedAgentBackend implements AgentBackend {

    private final SimulationRuntime simulation;

    public SimulatedAgentBackend(final SimulationRuntime simulation) {
        this.simulation = simulation;
    }

    @Override
    public String key() {
        return "simulation";
    }

    @Override
    @SuppressWarnings("unchecked")
    public Multi<AgentEvent> invoke(final AgentSessionConfig config) {
        if (simulation != null) {
            final Optional<SimulationStrategy<AgentSimulationInput, List<AgentEvent>>> strategy =
                    simulation.strategyFor(AgentProviderQN.INVOKE);
            if (strategy.isPresent()) {
                final AgentSimulationInput input = AgentSimulationInput.from(config);
                if (strategy.get().canResolve(input)) {
                    final List<AgentEvent> events = strategy.get().resolve(input);
                    return Multi.createFrom().iterable(events);
                }
            }
        }
        return cannedResponse(config);
    }

    private Multi<AgentEvent> cannedResponse(AgentSessionConfig config) {
        String modelId = config.model() != null ? config.model() : "unknown";
        return Multi.createFrom().items(
                new AgentEvent.TextDelta("Simulated response from " + modelId),
                new AgentEvent.InvocationComplete(0, 0, 0, 0, 0, 0.0, 0L, 0L, null, 0, false)
        );
    }

    @Override
    public AgentSession openSession(final AgentSessionInit init) {
        return new SimulationAgentSession(init.model());
    }

    // ... existing helper methods unchanged
}
```

- [ ] **Step 4: Run tests to verify key rename and canned response pass**

Run: `mvn --batch-mode test -pl agent-simulation-core -Dtest=SimulatedAgentBackendTest`
Expected: PASS

- [ ] **Step 5: Write failing test for `openSession()`**

```java
// SimulationAgentSessionTest.java
@Test
void sessionQueryReturnsCannedResponse() {
    var backend = new SimulatedAgentBackend(null);
    var session = backend.openSession(AgentSessionInit.of("system prompt", "sim-fast"));

    var events = session.query("hello").collect().asList().await().indefinitely();

    assertThat(events).hasSize(2);
    assertThat(events.get(0)).isInstanceOf(AgentEvent.TextDelta.class);
    assertThat(((AgentEvent.TextDelta) events.get(0)).text()).contains("sim-fast");
}

@Test
void sessionCloseIsIdempotent() {
    var backend = new SimulatedAgentBackend(null);
    var session = backend.openSession(AgentSessionInit.of("system prompt", "sim-fast"));

    assertThatNoException().isThrownBy(() -> {
        session.close(Duration.ofSeconds(5));
        session.close(Duration.ofSeconds(5));
    });
}
```

- [ ] **Step 6: Run test to verify it fails**

Expected: `SimulationAgentSession` doesn't exist

- [ ] **Step 7: Create `SimulationAgentSession`**

```java
package io.casehub.platform.agent.simulation;

import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentSession;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import java.time.Duration;
import java.util.concurrent.atomic.AtomicBoolean;

class SimulationAgentSession implements AgentSession {

    private final String modelId;
    private final AtomicBoolean closed = new AtomicBoolean(false);

    SimulationAgentSession(String modelId) {
        this.modelId = modelId != null ? modelId : "unknown";
    }

    @Override
    public Multi<AgentEvent> query(String userMessage) {
        if (closed.get()) {
            return Multi.createFrom().failure(
                    new IllegalStateException("Session is closed"));
        }
        return Multi.createFrom().items(
                new AgentEvent.TextDelta("Simulated response from " + modelId),
                new AgentEvent.InvocationComplete(0, 0, 0, 0, 0, 0.0, 0L, 0L, null, 0, false)
        );
    }

    @Override
    public Uni<Void> interrupt() {
        return Uni.createFrom().voidItem();
    }

    @Override
    public void close(Duration timeout) {
        closed.set(true);
    }

    @Override
    public void clear() {}
}
```

- [ ] **Step 8: Run session tests**

Run: `mvn --batch-mode test -pl agent-simulation-core -Dtest=SimulationAgentSessionTest`
Expected: PASS

- [ ] **Step 9: Add CDI wiring in `SimulationConfigBeans`**

Add a `@Produces` method:

```java
@Produces
@ApplicationScoped
SimulatedAgentBackend simulationBackend(Instance<SimulationRuntime> runtime) {
    return new SimulatedAgentBackend(
            runtime.isResolvable() ? runtime.get() : null
    );
}
```

Add necessary imports: `jakarta.enterprise.inject.Instance`, the `SimulatedAgentBackend` import, and `io.casehub.platform.agent.simulation.SimulatedAgentBackend`.

- [ ] **Step 10: Fix any remaining references to old key `"simulated"`**

Search for string `"simulated"` in test files:

Run: `grep -r '"simulated"' agent-simulation-core/src/ simulation-config/src/ --include='*.java' -l`

Update all references to `"simulation"`.

- [ ] **Step 11: Run full test suite**

Run: `mvn --batch-mode test -pl agent-simulation-core,simulation-config`
Expected: all PASS

- [ ] **Step 12: Run full project build**

Run: `mvn --batch-mode install -DskipTests && mvn --batch-mode test`
Expected: all modules compile and all tests pass

- [ ] **Step 13: Commit**

```bash
git add agent-simulation-core/src/ simulation-config/src/
git commit -m "$(cat <<'EOF'
feat(#623): simulation backend — routable CDI bean with canned-response fallback

SimulatedAgentBackend key renamed from "simulated" to "simulation"
(noun convention matching claude, openai, ollama, gemini). Constructor
accepts nullable SimulationRuntime — when null or no corpus match,
returns canned response with model ID. openSession() implemented via
SimulationAgentSession. CDI @Produces added in SimulationConfigBeans
for router discovery.

Refs #623

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## References

- [2026-10-15-manifest-model-chains-design.md] — design spec this plan implements
- `platform-api/src/main/java/io/casehub/platform/api/model/ModelQuery.java` — 9-field record, gains backendKey
- `platform-api/src/main/java/io/casehub/platform/api/model/ModelChain.java` — sealed entry types: Named, Queried
- `platform/src/main/java/io/casehub/platform/model/InMemoryModelRegistry.java` — stream-filter query()
- `agent-config-core/src/main/java/io/casehub/platform/agent/config/AliasDeclaration.java` — 7-field record, gains chain + backendKey
- `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestProcessor.java` — toModelQuery() + processAliasesAndDefaults()
- `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestResult.java` — Map<String, ModelQuery> → Map<String, ModelChain>
- `agent-router-core/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java` — 5 constructors + resolve() Step 0
- `agent-simulation-core/src/main/java/io/casehub/platform/agent/simulation/SimulatedAgentBackend.java` — key "simulated", requires SimulationRuntime
- `agent-api/src/main/java/io/casehub/platform/agent/AgentEvent.java` — InvocationComplete: 11 fields
- `agent-api/src/main/java/io/casehub/platform/agent/AgentSession.java` — query/interrupt/close/clear
- `simulation-config/src/main/java/io/casehub/platform/simulation/quarkus/SimulationConfigBeans.java` — CDI producer
- GitHub #623 — manifest-driven model chains issue
