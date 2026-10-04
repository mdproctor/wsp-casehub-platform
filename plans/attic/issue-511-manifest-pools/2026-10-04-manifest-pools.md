# Manifest Pools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #511 — pools section in platform manifest for declarative pool deployment
**Issue group:** #511

**Goal:** Add an optional `pools:` section to the platform manifest schema, with platform-neutral types that claudony maps to its pool provisioning system.

**Architecture:** New `PoolDeclaration` record in `agent-config-core` captures pool config with typed core fields and opaque extension maps. `Manifest` gains a `pools` map field. `ManifestLoader.merge()` uses name-keyed replace. `ManifestResult` passes pool declarations through to consumers.

**Tech Stack:** Java records, Jackson YAML, JUnit 5 + AssertJ

## Global Constraints

- `agent-config-core` must remain zero-CDI — pure Java + Jackson only
- All new records must be immutable (defensive copies in compact constructors)
- Kebab-case YAML keys via `@JsonProperty`
- Follow existing patterns in `Manifest.java`, `ManifestLoader.java`, `ManifestProcessorTest.java`

---

## Batch 1: PoolDeclaration record and Manifest integration

### Task 1: PoolDeclaration record with validation

**Files:**
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/PoolDeclaration.java`
- Test: `agent-config-core/src/test/java/io/casehub/platform/agent/config/PoolDeclarationTest.java`

**Interfaces:**
- Consumes: nothing
- Produces: `PoolDeclaration(String name, String agentId, String backend, int minActive, int maxActive, String workingDir, Map<String, Object> scaling, Map<String, Object> extensions)` — used by Task 2 (Manifest), Task 3 (merge), Task 4 (ManifestResult)

- [ ] **Step 1: Write failing tests for PoolDeclaration validation**

```java
package io.casehub.platform.agent.config;

import java.util.Map;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class PoolDeclarationTest {

    @Test
    void validDeclaration() {
        var pool = new PoolDeclaration("review-pool", "code-reviewer", "claudony",
                2, 8, "~/workspace/reviews",
                Map.of("type", "target-tracking", "target", 0.7),
                Map.of("model-chain", java.util.List.of("opus", "sonnet")));
        assertThat(pool.name()).isEqualTo("review-pool");
        assertThat(pool.agentId()).isEqualTo("code-reviewer");
        assertThat(pool.backend()).isEqualTo("claudony");
        assertThat(pool.minActive()).isEqualTo(2);
        assertThat(pool.maxActive()).isEqualTo(8);
        assertThat(pool.workingDir()).isEqualTo("~/workspace/reviews");
        assertThat(pool.scaling()).containsEntry("type", "target-tracking");
        assertThat(pool.extensions()).containsKey("model-chain");
    }

    @Test
    void nullAgentIdThrows() {
        assertThatThrownBy(() -> new PoolDeclaration("p", null, null, 0, 1, null, null, null))
                .isInstanceOf(NullPointerException.class)
                .hasMessageContaining("agent-id");
    }

    @Test
    void negativeMinActiveThrows() {
        assertThatThrownBy(() -> new PoolDeclaration("p", "a", null, -1, 1, null, null, null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("min-active");
    }

    @Test
    void zeroMaxActiveThrows() {
        assertThatThrownBy(() -> new PoolDeclaration("p", "a", null, 0, 0, null, null, null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("max-active");
    }

    @Test
    void maxActiveLessThanMinActiveThrows() {
        assertThatThrownBy(() -> new PoolDeclaration("p", "a", null, 5, 3, null, null, null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("max-active");
    }

    @Test
    void nullScalingDefaultsToEmptyMap() {
        var pool = new PoolDeclaration("p", "a", null, 0, 1, null, null, null);
        assertThat(pool.scaling()).isEmpty();
        assertThat(pool.extensions()).isEmpty();
    }

    @Test
    void scalingAndExtensionsAreDefensivelyCopied() {
        var scaling = new java.util.HashMap<String, Object>();
        scaling.put("type", "none");
        var pool = new PoolDeclaration("p", "a", null, 0, 1, null, scaling, null);
        assertThatThrownBy(() -> pool.scaling().put("x", "y"))
                .isInstanceOf(UnsupportedOperationException.class);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -f agent-config-core/pom.xml -Dtest=PoolDeclarationTest -pl agent-config-core`
Expected: Compilation failure — `PoolDeclaration` does not exist

- [ ] **Step 3: Implement PoolDeclaration**

```java
package io.casehub.platform.agent.config;

import com.fasterxml.jackson.annotation.JsonProperty;
import java.util.Map;
import java.util.Objects;

public record PoolDeclaration(
        String name,
        @JsonProperty("agent-id") String agentId,
        String backend,
        @JsonProperty("min-active") int minActive,
        @JsonProperty("max-active") int maxActive,
        @JsonProperty("working-dir") String workingDir,
        Map<String, Object> scaling,
        Map<String, Object> extensions
) {
    public PoolDeclaration {
        Objects.requireNonNull(agentId, "agent-id is required");
        if (minActive < 0) throw new IllegalArgumentException("min-active must be >= 0");
        if (maxActive < 1) throw new IllegalArgumentException("max-active must be >= 1");
        if (maxActive < minActive) throw new IllegalArgumentException("max-active must be >= min-active");
        scaling = scaling != null ? Map.copyOf(scaling) : Map.of();
        extensions = extensions != null ? Map.copyOf(extensions) : Map.of();
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -f agent-config-core/pom.xml -Dtest=PoolDeclarationTest -pl agent-config-core`
Expected: All 7 tests PASS

- [ ] **Step 5: Commit**

```bash
git add agent-config-core/src/main/java/io/casehub/platform/agent/config/PoolDeclaration.java agent-config-core/src/test/java/io/casehub/platform/agent/config/PoolDeclarationTest.java
git commit -m "feat(#511): add PoolDeclaration record with validation"
```

### Task 2: Add pools to Manifest and ManifestResult

**Files:**
- Modify: `agent-config-core/src/main/java/io/casehub/platform/agent/config/Manifest.java`
- Modify: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestResult.java`
- Modify: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestProcessor.java`
- Modify: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestLoader.java` (merge + emptyManifest)
- Modify: `agent-config-core/src/test/java/io/casehub/platform/agent/config/ManifestLoaderTest.java`
- Modify: `agent-config-core/src/test/java/io/casehub/platform/agent/config/ManifestProcessorTest.java`

**Interfaces:**
- Consumes: `PoolDeclaration` from Task 1
- Produces: `Manifest.pools()` returns `Map<String, PoolDeclaration>`, `ManifestResult.pools()` returns `List<PoolDeclaration>`

- [ ] **Step 1: Write failing test for YAML pool parsing**

Add to `ManifestLoaderTest.java`:

```java
@Test
void loadFileParsesPools(@TempDir Path tempDir) throws IOException {
    var file = tempDir.resolve("agent-config.yaml");
    Files.writeString(file, """
            pools:
              review-pool:
                agent-id: code-reviewer
                backend: claudony
                min-active: 2
                max-active: 8
                working-dir: ~/workspace/reviews
                scaling:
                  type: target-tracking
                  target: 0.7
            """);
    var manifest = loader.loadFile(file);
    assertThat(manifest).isNotNull();
    assertThat(manifest.pools()).hasSize(1);
    assertThat(manifest.pools()).containsKey("review-pool");
    var pool = manifest.pools().get("review-pool");
    assertThat(pool.name()).isEqualTo("review-pool");
    assertThat(pool.agentId()).isEqualTo("code-reviewer");
    assertThat(pool.backend()).isEqualTo("claudony");
    assertThat(pool.minActive()).isEqualTo(2);
    assertThat(pool.maxActive()).isEqualTo(8);
    assertThat(pool.workingDir()).isEqualTo("~/workspace/reviews");
    assertThat(pool.scaling()).containsEntry("type", "target-tracking");
}

@Test
void loadFileNoPoolsSectionReturnsEmptyMap(@TempDir Path tempDir) throws IOException {
    var file = tempDir.resolve("agent-config.yaml");
    Files.writeString(file, """
            providers:
              - vendor: openai
                credential: env:OPENAI_KEY
            """);
    var manifest = loader.loadFile(file);
    assertThat(manifest).isNotNull();
    assertThat(manifest.pools()).isEmpty();
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -f agent-config-core/pom.xml -Dtest=ManifestLoaderTest#loadFileParsesPools -pl agent-config-core`
Expected: Compilation failure — `Manifest` has no `pools` field

- [ ] **Step 3: Add pools field to Manifest**

Modify `Manifest.java` — add `Map<String, PoolDeclaration> pools` as the last parameter. Update the compact constructor to inject pool names from map keys and make defensive copy. Update `ManifestLoader.emptyManifest()` and all existing `new Manifest(...)` calls to pass `Map.of()` as the new parameter.

Updated `Manifest.java`:

```java
public record Manifest(
        List<ModelDescriptor> models,
        List<ProviderDeclaration> providers,
        List<SourceDeclaration> sources,
        Map<String, AliasDeclaration> aliases,
        @JsonProperty("local-models") List<LocalModelDeclaration> localModels,
        ManifestDefaults defaults,
        Map<String, PoolDeclaration> pools
) {
    public Manifest {
        models = models != null ? List.copyOf(models) : List.of();
        providers = providers != null ? List.copyOf(providers) : List.of();
        sources = sources != null ? List.copyOf(sources) : List.of();
        aliases = aliases != null ? Map.copyOf(aliases) : Map.of();
        localModels = localModels != null ? List.copyOf(localModels) : List.of();
        if (pools != null) {
            var injected = new java.util.LinkedHashMap<String, PoolDeclaration>();
            for (var e : pools.entrySet()) {
                var p = e.getValue();
                injected.put(e.getKey(), new PoolDeclaration(
                        e.getKey(), p.agentId(), p.backend(), p.minActive(), p.maxActive(),
                        p.workingDir(), p.scaling(), p.extensions()));
            }
            pools = Map.copyOf(injected);
        } else {
            pools = Map.of();
        }
    }
}
```

Update `ManifestLoader.emptyManifest()`:

```java
private static Manifest emptyManifest() {
    return new Manifest(List.of(), List.of(), List.of(), Map.of(), List.of(), null, Map.of());
}
```

Update `ManifestLoader.merge()` return statement and add pools merge logic:

```java
Manifest merge(List<PrioritizedManifest> entries) {
    entries.sort(Comparator.comparingInt(PrioritizedManifest::priority));

    var models = new LinkedHashMap<String, ModelDescriptor>();
    var providers = new LinkedHashMap<String, ProviderDeclaration>();
    var aliases = new LinkedHashMap<String, AliasDeclaration>();
    var localModels = new LinkedHashMap<String, LocalModelDeclaration>();
    var sources = new LinkedHashMap<String, SourceDeclaration>();
    var pools = new LinkedHashMap<String, PoolDeclaration>();
    ManifestDefaults defaults = null;

    for (var entry : entries) {
        var m = entry.manifest;
        for (var model : m.models()) models.put(model.id(), model);
        for (var provider : m.providers()) providers.put(provider.vendor(), provider);
        for (var alias : m.aliases().entrySet()) aliases.put(alias.getKey(), alias.getValue());
        for (var local : m.localModels()) localModels.put(local.id(), local);
        for (var source : m.sources()) sources.put(source.uri(), source);
        pools.putAll(m.pools());
        if (m.defaults() != null) defaults = m.defaults();
    }

    return new Manifest(
            new ArrayList<>(models.values()),
            new ArrayList<>(providers.values()),
            new ArrayList<>(sources.values()),
            aliases,
            new ArrayList<>(localModels.values()),
            defaults,
            pools
    );
}
```

Update `ManifestLoaderTest.manifestWith()`:

```java
private Manifest manifestWith(List<ModelDescriptor> models, List<ProviderDeclaration> providers,
                              Map<String, AliasDeclaration> aliases) {
    return new Manifest(models, providers, List.of(), aliases, List.of(), null, Map.of());
}
```

Fix all other `new Manifest(...)` calls in test files (`ManifestLoaderTest`, `ManifestProcessorTest`) to include the 7th `Map.of()` argument.

- [ ] **Step 4: Run ManifestLoaderTest to verify pool parsing tests pass**

Run: `mvn --batch-mode test -f agent-config-core/pom.xml -Dtest=ManifestLoaderTest -pl agent-config-core`
Expected: All tests PASS (existing + 2 new)

- [ ] **Step 5: Write failing test for pool merge (name-keyed replace)**

Add to `ManifestLoaderTest.java`:

```java
@Test
void mergeHigherPriorityWinsForPools() {
    var p1 = new PoolDeclaration("review-pool", "agent-a", "claudony", 1, 4, null, null, null);
    var p2 = new PoolDeclaration("review-pool", "agent-b", "claudony", 2, 8, null, null, null);
    var p3 = new PoolDeclaration("other-pool", "agent-c", "claudony", 0, 2, null, null, null);

    var entries = new ArrayList<ManifestLoader.PrioritizedManifest>();
    entries.add(new ManifestLoader.PrioritizedManifest(
            new Manifest(List.of(), List.of(), List.of(), Map.of(), List.of(), null,
                    Map.of("review-pool", p1, "other-pool", p3)), 10));
    entries.add(new ManifestLoader.PrioritizedManifest(
            new Manifest(List.of(), List.of(), List.of(), Map.of(), List.of(), null,
                    Map.of("review-pool", p2)), 30));

    var merged = loader.merge(entries);
    assertThat(merged.pools()).hasSize(2);
    assertThat(merged.pools().get("review-pool").agentId()).isEqualTo("agent-b");
    assertThat(merged.pools().get("other-pool").agentId()).isEqualTo("agent-c");
}
```

- [ ] **Step 6: Run merge test to verify it passes (merge logic already implemented in Step 3)**

Run: `mvn --batch-mode test -f agent-config-core/pom.xml -Dtest=ManifestLoaderTest#mergeHigherPriorityWinsForPools -pl agent-config-core`
Expected: PASS

- [ ] **Step 7: Write failing test for ManifestProcessor pool passthrough**

Add to `ManifestProcessorTest.java`:

```java
@Test
void processPassesPoolsToResult() {
    var pool = new PoolDeclaration("review-pool", "code-reviewer", "claudony",
            2, 8, "~/reviews", Map.of("type", "target-tracking"), Map.of());
    var manifest = new Manifest(List.of(), List.of(), List.of(), Map.of(), List.of(), null,
            Map.of("review-pool", pool));

    var result = processor(Map.of()).process(manifest);
    assertThat(result.pools()).hasSize(1);
    assertThat(result.pools().get(0).name()).isEqualTo("review-pool");
    assertThat(result.pools().get(0).agentId()).isEqualTo("code-reviewer");
}

@Test
void processEmptyPoolsReturnsEmptyList() {
    var manifest = new Manifest(List.of(), List.of(), List.of(), Map.of(), List.of(), null, Map.of());
    var result = processor(Map.of()).process(manifest);
    assertThat(result.pools()).isEmpty();
}
```

- [ ] **Step 8: Update ManifestResult and ManifestProcessor to pass pools through**

Modify `ManifestResult.java`:

```java
public record ManifestResult(Map<String, ModelQuery> aliases, String defaultBackendKey, List<PoolDeclaration> pools) {

    public ManifestResult {
        aliases = aliases != null ? Map.copyOf(aliases) : Map.of();
        pools = pools != null ? List.copyOf(pools) : List.of();
    }

    public static ManifestResult empty() {
        return new ManifestResult(Map.of(), null, List.of());
    }
}
```

Modify `ManifestProcessor.processAliasesAndDefaults()` to collect pools:

```java
private ManifestResult processAliasesAndDefaults(Manifest manifest) {
    var aliases = new LinkedHashMap<String, ModelQuery>();
    for (var entry : manifest.aliases().entrySet()) {
        aliases.put(entry.getKey(), toModelQuery(entry.getValue()));
    }

    String defaultBackend = manifest.defaults() != null ? manifest.defaults().backend() : null;
    var pools = new ArrayList<>(manifest.pools().values());
    LOG.infof("Manifest processed: %d aliases, %d pools, default backend: %s",
            aliases.size(), pools.size(), defaultBackend != null ? defaultBackend : "(not set)");
    return new ManifestResult(aliases, defaultBackend, pools);
}
```

- [ ] **Step 9: Run all agent-config-core tests**

Run: `mvn --batch-mode test -f agent-config-core/pom.xml -pl agent-config-core`
Expected: All tests PASS

- [ ] **Step 10: Commit**

```bash
git add agent-config-core/
git commit -m "feat(#511): add pools section to Manifest, ManifestLoader merge, and ManifestResult"
```

## Batch 2: JSON Schema and documentation

### Task 3: Pool declaration JSON Schema

**Files:**
- Create: `agent-config-core/src/main/resources/schema/pool-declaration.schema.json`

**Interfaces:**
- Consumes: `PoolDeclaration` field names from Task 1
- Produces: JSON Schema resource for documentation and external validation

- [ ] **Step 1: Create pool-declaration.schema.json**

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "pool-declaration",
  "description": "Declarative agent pool definition within a platform manifest",
  "type": "object",
  "required": ["agent-id"],
  "properties": {
    "agent-id": {
      "type": "string",
      "description": "Agent definition identifier"
    },
    "backend": {
      "type": "string",
      "description": "Which backend provisions this pool (e.g. claudony)"
    },
    "min-active": {
      "type": "integer",
      "minimum": 0,
      "default": 0,
      "description": "Minimum active pool members"
    },
    "max-active": {
      "type": "integer",
      "minimum": 1,
      "default": 10,
      "description": "Maximum active pool members"
    },
    "working-dir": {
      "type": "string",
      "description": "Filesystem path for agent working directories"
    },
    "scaling": {
      "type": "object",
      "description": "Scaling configuration — consumer-interpreted (e.g. target-tracking, step, demand-pressure)"
    },
    "extensions": {
      "type": "object",
      "description": "Consumer-specific configuration (e.g. model-chain, budget, eviction)"
    }
  },
  "additionalProperties": false
}
```

- [ ] **Step 2: Verify the schema resource is on the classpath**

Run: `mvn --batch-mode compile -f agent-config-core/pom.xml -pl agent-config-core`
Expected: BUILD SUCCESS, file at `agent-config-core/target/classes/schema/pool-declaration.schema.json`

- [ ] **Step 3: Update CLAUDE.md agent-config-core module description**

Add `pool-declaration.schema.json` mention to the `agent-config-core/` module row in CLAUDE.md's module table.

- [ ] **Step 4: Commit**

```bash
git add agent-config-core/src/main/resources/schema/pool-declaration.schema.json CLAUDE.md
git commit -m "feat(#511): add pool-declaration JSON Schema and update CLAUDE.md"
```

### Task 4: Full build verification

**Files:**
- No new files — verification only

**Interfaces:**
- Consumes: all changes from Tasks 1-3
- Produces: verified green build

- [ ] **Step 1: Run full Maven install**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile, all tests pass. The `Manifest` constructor change propagates through all consumers. If any module fails due to the new 7th parameter, fix the call site.

- [ ] **Step 2: Commit any fixups**

If any call sites needed updating (e.g. in `agent-config/` Quarkus module or test YAML fixtures), commit them:

```bash
git add -u
git commit -m "fix(#511): update Manifest constructor call sites for pools parameter"
```

## References

- [specs/issue-511-manifest-pools/2026-10-04-manifest-pools-design.md] — design spec
- [agent-config-core/src/main/java/io/casehub/platform/agent/config/Manifest.java] — existing manifest record
- [agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestLoader.java:341-376] — merge method
- [agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestResult.java] — processor output
- [agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestProcessor.java:109-131] — aliases/defaults processing
- [agent-config-core/src/test/java/io/casehub/platform/agent/config/ManifestLoaderTest.java] — existing test patterns
- [claudony/casehub/fleet/AgentPoolDefinition.java] — claudony consumer reference
- [GitHub #511] — focal issue
