# Standalone AgentProvider Factory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #628 — Standalone AgentProvider factory — manifest to provider without CDI
**Issue group:** #628

**Goal:** Enable `RoutingAgentProvider.discover(projectDir)` — one-line standalone AgentProvider creation from manifest without CDI.

**Architecture:** ServiceLoader discovers `BackendProvider` implementations on the classpath. `AgentConfigLoader.withDefaults()` loads the manifest with sensible no-op stubs. `RoutingAgentProvider.discover()` ties them together — manifest declares providers, classpath declares implementations, consumer code specifies requirements.

**Tech Stack:** Java 21, ServiceLoader, Maven multi-module, Mutiny Multi (reactive streams)

## Global Constraints

- `platform-api/` remains zero-dependency — only static factory methods with private inner impls
- `agent-api/` depends only on platform-api
- `-core` modules have no CDI imports — pure Java POJOs
- All new public classes need Javadoc on the type declaration (one line)
- Records use defensive copies for collections in compact constructors

---

## Batch 1: API contracts

### Task 1: BackendProvider SPI + ModelRegistry.empty() + InvocationComplete expansion

**Files:**
- Create: `agent-api/src/main/java/io/casehub/platform/agent/BackendProvider.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/model/ModelRegistry.java`
- Modify: `agent-api/src/main/java/io/casehub/platform/agent/AgentEvent.java` (InvocationComplete record, ~line 72)
- Test: `agent-api/src/test/java/io/casehub/platform/agent/BackendProviderTest.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/model/ModelRegistryTest.java`

**Interfaces:**
- Produces: `BackendProvider` (vendorKey() + create(Map)), `ModelRegistry.empty()`, `InvocationComplete.withRouting(String, String)`

- [ ] **Step 1: Write BackendProvider SPI**

Create `agent-api/src/main/java/io/casehub/platform/agent/BackendProvider.java`:

```java
package io.casehub.platform.agent;

import java.util.Map;

/** ServiceLoader-discovered factory for creating AgentBackend instances from manifest properties. */
public interface BackendProvider {
    String vendorKey();
    AgentBackend create(Map<String, String> properties);
}
```

- [ ] **Step 2: Add ModelRegistry.empty()**

In `platform-api/src/main/java/io/casehub/platform/api/model/ModelRegistry.java`, add after the `all()` method:

```java
static ModelRegistry empty() {
    return new ModelRegistry() {
        @Override public Optional<ModelDescriptor> resolveById(String modelId) {
            return Optional.empty();
        }
        @Override public List<ModelDescriptor> query(ModelQuery query) {
            return List.of();
        }
        @Override public List<ModelDescriptor> all() {
            return List.of();
        }
    };
}
```

- [ ] **Step 3: Expand InvocationComplete with routing fields**

In `agent-api/src/main/java/io/casehub/platform/agent/AgentEvent.java`, modify the `InvocationComplete` record (~line 72-78). Add `backendKey` and `instanceId` as the last two fields:

```java
record InvocationComplete(
        int inputTokens, int outputTokens, int thinkingTokens,
        int cacheReadTokens, int cacheWriteTokens,
        Double totalCostUsd,
        long durationMs, long apiDurationMs,
        String sessionId, int numTurns,
        boolean isError,
        String backendKey,
        String instanceId) implements AgentEvent {

    public InvocationComplete withRouting(String backendKey, String instanceId) {
        return new InvocationComplete(inputTokens, outputTokens, thinkingTokens,
                cacheReadTokens, cacheWriteTokens, totalCostUsd,
                durationMs, apiDurationMs, sessionId, numTurns, isError,
                backendKey, instanceId);
    }
}
```

- [ ] **Step 4: Fix all InvocationComplete construction sites**

Use `ide_find_references` on the `InvocationComplete` constructor to find all call sites. Each site currently passes 11 args — append `, null, null` for the new fields. Typical locations: each backend's invoke handler (agent-claude, agent-openai, agent-ollama, agent-gemini, agent-codex, agent-gemini-cli, agent-simulation, agent-langchain4j).

Pattern for each site — change:
```java
new AgentEvent.InvocationComplete(in, out, think, cacheR, cacheW, cost, dur, apiDur, sid, turns, err)
```
to:
```java
new AgentEvent.InvocationComplete(in, out, think, cacheR, cacheW, cost, dur, apiDur, sid, turns, err, null, null)
```

- [ ] **Step 5: Write tests**

Create `platform-api/src/test/java/io/casehub/platform/api/model/ModelRegistryTest.java`:

```java
package io.casehub.platform.api.model;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ModelRegistryTest {
    @Test
    void emptyRegistryResolvesNothing() {
        var registry = ModelRegistry.empty();
        assertTrue(registry.resolveById("any").isEmpty());
        assertTrue(registry.query(ModelQuery.all()).isEmpty());
        assertTrue(registry.all().isEmpty());
    }
}
```

Create `agent-api/src/test/java/io/casehub/platform/agent/InvocationCompleteTest.java`:

```java
package io.casehub.platform.agent;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class InvocationCompleteTest {
    @Test
    void withRoutingAddsBackendInfo() {
        var ic = new AgentEvent.InvocationComplete(
                100, 50, 0, 0, 0, 0.01, 1000L, 900L, "s1", 1, false, null, null);
        var routed = ic.withRouting("ollama", "default");
        assertEquals("ollama", routed.backendKey());
        assertEquals("default", routed.instanceId());
        assertEquals(100, routed.inputTokens());
    }
}
```

- [ ] **Step 6: Run tests and verify**

Run: `mvn --batch-mode test -pl platform-api,agent-api -am`
Expected: All tests pass including new ones.

- [ ] **Step 7: Commit**

```bash
git add platform-api/src agent-api/src
git commit -m "feat(#628): add BackendProvider SPI, ModelRegistry.empty(), InvocationComplete routing fields"
```

---

## Batch 2: Core infrastructure

### Task 2: InMemoryBackendInstanceRegistry extraction

**Files:**
- Move: `agent-router/src/main/java/io/casehub/platform/agent/router/InMemoryBackendInstanceRegistry.java` → `agent-router-core/src/main/java/io/casehub/platform/agent/router/InMemoryBackendInstanceRegistry.java` (use `ide_move_file`)
- Modify: `agent-router/src/main/java/io/casehub/platform/agent/router/quarkus/RouterBeans.java` — add `@Produces` for registry
- Test: `agent-router-core/src/test/java/io/casehub/platform/agent/router/InMemoryBackendInstanceRegistryTest.java`

**Interfaces:**
- Consumes: `BackendInstanceRegistry` (agent-api), `BackendRef` (agent-api), `AgentBackend` (agent-api)
- Produces: `InMemoryBackendInstanceRegistry` with `of(AgentBackend...)` factory in agent-router-core

- [ ] **Step 1: Write the failing test**

Create `agent-router-core/src/test/java/io/casehub/platform/agent/router/InMemoryBackendInstanceRegistryTest.java`:

```java
package io.casehub.platform.agent.router;

import io.casehub.platform.agent.AgentBackend;
import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentSession;
import io.casehub.platform.agent.AgentSessionConfig;
import io.casehub.platform.agent.AgentSessionInit;
import io.smallrye.mutiny.Multi;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class InMemoryBackendInstanceRegistryTest {

    @Test
    void ofRegistersBackendsByKey() {
        var backend = stubBackend("ollama");
        var registry = InMemoryBackendInstanceRegistry.of(backend);

        assertTrue(registry.resolve("ollama", "default").isPresent());
        assertEquals("ollama", registry.resolve("ollama", "default").get().key());
    }

    @Test
    void ofWithMultipleBackends() {
        var ollama = stubBackend("ollama");
        var claude = stubBackend("claude");
        var registry = InMemoryBackendInstanceRegistry.of(ollama, claude);

        assertTrue(registry.resolve("ollama", "default").isPresent());
        assertTrue(registry.resolve("claude", "default").isPresent());
        assertTrue(registry.resolve("unknown", "default").isEmpty());
    }

    @Test
    void resolveByKeyReturnsAllInstances() {
        var backend = stubBackend("ollama");
        var registry = InMemoryBackendInstanceRegistry.of(backend);

        assertEquals(1, registry.resolveByKey("ollama").size());
        assertEquals(0, registry.resolveByKey("unknown").size());
    }

    private AgentBackend stubBackend(String key) {
        return new AgentBackend() {
            @Override public String key() { return key; }
            @Override public Multi<AgentEvent> invoke(AgentSessionConfig config) { return Multi.createFrom().empty(); }
            @Override public AgentSession openSession(AgentSessionInit init) { throw new UnsupportedOperationException(); }
        };
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl agent-router-core -Dtest=InMemoryBackendInstanceRegistryTest`
Expected: FAIL — `InMemoryBackendInstanceRegistry` not found in agent-router-core.

- [ ] **Step 3: Move the class and strip CDI**

Use `ide_move_file` to move `InMemoryBackendInstanceRegistry.java` from `agent-router` to `agent-router-core` (same package `io.casehub.platform.agent.router`).

Then remove the `@ApplicationScoped` annotation and add the `of()` factory:

```java
package io.casehub.platform.agent.router;

import io.casehub.platform.agent.AgentBackend;
import io.casehub.platform.agent.BackendInstanceRegistry;
import io.casehub.platform.agent.BackendRef;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

/** In-memory BackendInstanceRegistry backed by ConcurrentHashMap. */
public class InMemoryBackendInstanceRegistry implements BackendInstanceRegistry {

    private final ConcurrentHashMap<BackendRef, AgentBackend> instances = new ConcurrentHashMap<>();

    public static InMemoryBackendInstanceRegistry of(AgentBackend... backends) {
        var registry = new InMemoryBackendInstanceRegistry();
        for (var backend : backends) {
            registry.register(backend);
        }
        return registry;
    }

    @Override
    public void register(AgentBackend backend) {
        instances.put(new BackendRef(backend.key(), backend.instanceId()), backend);
    }

    @Override
    public Optional<AgentBackend> resolve(String key, String instanceId) {
        return Optional.ofNullable(instances.get(new BackendRef(key, instanceId)));
    }

    @Override
    public List<AgentBackend> resolveByKey(String key) {
        return instances.entrySet().stream()
                .filter(e -> e.getKey().key().equals(key))
                .map(Map.Entry::getValue)
                .toList();
    }
}
```

- [ ] **Step 4: Update RouterBeans to produce the registry**

In `agent-router/src/main/java/io/casehub/platform/agent/router/quarkus/RouterBeans.java`, add a producer method for the registry:

```java
@Produces
@ApplicationScoped
@DefaultBean
public InMemoryBackendInstanceRegistry backendInstanceRegistry() {
    return new InMemoryBackendInstanceRegistry();
}
```

Remove the `@Inject BackendInstanceRegistry registry` field and update the `routingAgentProvider` method to take `BackendInstanceRegistry registry` as a parameter (CDI will inject the produced bean).

- [ ] **Step 5: Run tests**

Run: `mvn --batch-mode test -pl agent-router-core,agent-router -am`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add agent-router-core/src agent-router/src
git commit -m "refactor(#628): extract InMemoryBackendInstanceRegistry to agent-router-core"
```

### Task 3: ManifestResult expansion + AgentConfigLoader.withDefaults()

**Files:**
- Modify: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestResult.java`
- Modify: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestProcessor.java` (~line 110-121)
- Modify: `agent-config-core/src/main/java/io/casehub/platform/agent/config/AgentConfigLoader.java`
- Test: `agent-config-core/src/test/java/io/casehub/platform/agent/config/ManifestResultTest.java`
- Test: `agent-config-core/src/test/java/io/casehub/platform/agent/config/AgentConfigLoaderTest.java`

**Interfaces:**
- Consumes: `LlmCredentialStore` (platform-api), `MutableModelRegistry` (platform-api), `CredentialResolver` (platform-api), `DIDResolver` (platform-api)
- Produces: `ManifestResult.providers()` → `Map<String, Map<String, String>>`, `AgentConfigLoader.withDefaults(Path)`, `AgentConfigLoader.modelRegistry()`

- [ ] **Step 1: Write the failing test for ManifestResult**

Create `agent-config-core/src/test/java/io/casehub/platform/agent/config/ManifestResultTest.java`:

```java
package io.casehub.platform.agent.config;

import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

class ManifestResultTest {
    @Test
    void emptyHasEmptyProviders() {
        var result = ManifestResult.empty();
        assertNotNull(result.providers());
        assertTrue(result.providers().isEmpty());
    }

    @Test
    void providersAreDefensivelyCopied() {
        var providers = new java.util.HashMap<>(Map.of("ollama", Map.of("host", "localhost:11434")));
        var result = new ManifestResult(Map.of(), null, java.util.List.of(), providers);
        assertThrows(UnsupportedOperationException.class, () -> result.providers().put("new", Map.of()));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl agent-config-core -Dtest=ManifestResultTest`
Expected: FAIL — constructor mismatch (4 args vs 3).

- [ ] **Step 3: Expand ManifestResult**

Modify `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestResult.java`. Add `providers` field:

```java
public record ManifestResult(
        Map<String, ModelChain> aliases,
        String defaultBackendKey,
        List<PoolDeclaration> pools,
        Map<String, Map<String, String>> providers
) {
    public ManifestResult {
        aliases = aliases != null ? Map.copyOf(aliases) : Map.of();
        pools = pools != null ? List.copyOf(pools) : List.of();
        providers = providers != null
                ? providers.entrySet().stream().collect(
                    java.util.stream.Collectors.toUnmodifiableMap(
                        Map.Entry::getKey,
                        e -> Map.copyOf(e.getValue())))
                : Map.of();
    }

    public static ManifestResult empty() {
        return new ManifestResult(Map.of(), null, List.of(), Map.of());
    }
}
```

- [ ] **Step 4: Fix all ManifestResult construction sites**

Use `ide_find_references` on `ManifestResult` constructor. Each existing call passes 3 args — add `Map.of()` (or the actual providers map) as the 4th argument.

Key location: `ManifestProcessor.processAliasesAndDefaults()` (~line 110-121) — this is where providers are extracted and should be retained.

In `processAliasesAndDefaults`, build the providers map from `manifest.providers()`:

```java
private ManifestResult processAliasesAndDefaults(Manifest manifest) {
    var aliases = new LinkedHashMap<String, ModelChain>();
    for (var entry : manifest.aliases().entrySet()) {
        aliases.put(entry.getKey(), toModelChain(entry.getValue()));
    }
    String defaultBackend = manifest.defaults() != null ? manifest.defaults().backend() : null;
    var pools = new java.util.ArrayList<>(manifest.pools().values());

    var providers = new LinkedHashMap<String, Map<String, String>>();
    for (var pd : manifest.providers()) {
        var props = new LinkedHashMap<String, String>();
        if (pd.host() != null) props.put("host", pd.host());
        if (pd.hasScalarCredential()) props.put("credential", pd.scalarCredential());
        providers.put(pd.vendor(), props);
    }

    return new ManifestResult(aliases, defaultBackend, pools, providers);
}
```

Also fix any other construction sites found by `ide_find_references` (tests, factory methods).

- [ ] **Step 5: Run ManifestResult test**

Run: `mvn --batch-mode test -pl agent-config-core -Dtest=ManifestResultTest`
Expected: PASS.

- [ ] **Step 6: Write the failing test for AgentConfigLoader.withDefaults()**

Create `agent-config-core/src/test/java/io/casehub/platform/agent/config/AgentConfigLoaderDefaultsTest.java`:

```java
package io.casehub.platform.agent.config;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.nio.file.Files;
import java.nio.file.Path;
import static org.junit.jupiter.api.Assertions.*;

class AgentConfigLoaderDefaultsTest {

    @TempDir Path tempDir;

    @Test
    void withDefaultsCreatesLoaderWithoutExplicitDeps() {
        var loader = AgentConfigLoader.withDefaults(tempDir);
        assertNotNull(loader);
        assertNotNull(loader.modelRegistry());
    }

    @Test
    void withDefaultsLoadsEmptyManifest() {
        var loader = AgentConfigLoader.withDefaults(tempDir);
        var result = loader.load();
        assertNotNull(result);
        assertTrue(result.providers().isEmpty());
    }

    @Test
    void withDefaultsLoadsManifestWithProvider() throws Exception {
        Files.writeString(tempDir.resolve("agent-config.yaml"), """
                providers:
                  - vendor: ollama
                    host: localhost:11434
                """);
        var loader = AgentConfigLoader.withDefaults(tempDir);
        var result = loader.load();
        assertTrue(result.providers().containsKey("ollama"));
        assertEquals("localhost:11434", result.providers().get("ollama").get("host"));
    }
}
```

- [ ] **Step 7: Run test to verify it fails**

Run: `mvn --batch-mode test -pl agent-config-core -Dtest=AgentConfigLoaderDefaultsTest`
Expected: FAIL — `withDefaults` method not found.

- [ ] **Step 8: Implement AgentConfigLoader.withDefaults()**

In `agent-config-core/src/main/java/io/casehub/platform/agent/config/AgentConfigLoader.java`, add after the constructor (~line 45):

```java
public MutableModelRegistry modelRegistry() {
    return modelRegistry;
}

public static AgentConfigLoader withDefaults(Path projectDir) {
    return withDefaults(projectDir, null);
}

public static AgentConfigLoader withDefaults(Path projectDir, String profile) {
    return new AgentConfigLoader(
            new MapLlmCredentialStore(),
            new MapMutableModelRegistry(),
            ref -> Map.of(),
            Map.of(),
            model -> {},
            profile,
            projectDir,
            did -> java.util.Optional.empty(),
            false
    );
}
```

Add package-private inner classes at end of file:

```java
static final class MapLlmCredentialStore implements LlmCredentialStore {
    private final java.util.concurrent.ConcurrentHashMap<String, Map<String, String>> store =
            new java.util.concurrent.ConcurrentHashMap<>();

    @Override public void store(String tenancyId, String credentialRef, Map<String, String> credentials) {
        store.put(tenancyId + "::" + credentialRef, credentials);
    }
    @Override public Map<String, String> resolve(String tenancyId, String credentialRef) {
        return store.getOrDefault(tenancyId + "::" + credentialRef, Map.of());
    }
    @Override public void delete(String tenancyId, String credentialRef) {
        store.remove(tenancyId + "::" + credentialRef);
    }
    @Override public List<String> listRefs(String tenancyId) {
        return store.keySet().stream()
                .filter(k -> k.startsWith(tenancyId + "::"))
                .map(k -> k.substring(k.indexOf("::") + 2))
                .toList();
    }
}

static final class MapMutableModelRegistry implements MutableModelRegistry {
    private final java.util.concurrent.ConcurrentHashMap<String, ModelDescriptor> models =
            new java.util.concurrent.ConcurrentHashMap<>();
    private volatile String lastSourceId;

    @Override public Optional<ModelDescriptor> resolveById(String modelId) {
        return Optional.ofNullable(models.get(modelId));
    }
    @Override public List<ModelDescriptor> query(ModelQuery query) {
        return models.values().stream()
                .filter(d -> query.vendor() == null || query.vendor().equals(d.vendor()))
                .filter(d -> query.tier() == null || query.tier() == d.tier())
                .filter(d -> query.locality() == null || query.locality() == d.locality())
                .filter(d -> d.capabilities().containsAll(query.requiredCapabilities()))
                .toList();
    }
    @Override public List<ModelDescriptor> all() { return List.copyOf(models.values()); }
    @Override public CatalogDelta replaceSource(String sourceId, int priority, List<ModelDescriptor> newModels) {
        var oldIds = models.keySet().stream().collect(java.util.stream.Collectors.toSet());
        models.clear();
        newModels.forEach(m -> models.put(m.id(), m));
        var newIds = models.keySet().stream().collect(java.util.stream.Collectors.toSet());
        lastSourceId = sourceId;
        var added = new java.util.HashSet<>(newIds); added.removeAll(oldIds);
        var removed = new java.util.HashSet<>(oldIds); removed.removeAll(newIds);
        return new CatalogDelta(added, removed, Set.of());
    }
}
```

- [ ] **Step 9: Run tests**

Run: `mvn --batch-mode test -pl agent-config-core -am`
Expected: All tests pass.

- [ ] **Step 10: Commit**

```bash
git add agent-config-core/src
git commit -m "feat(#628): expand ManifestResult with providers, add AgentConfigLoader.withDefaults()"
```

---

## Batch 3: Routing + discovery

### Task 4: RoutingAgentProvider.of() + discover()

**Files:**
- Modify: `agent-router-core/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java`
- Test: `agent-router-core/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderFactoryTest.java`

**Interfaces:**
- Consumes: `InMemoryBackendInstanceRegistry.of()` (Task 2), `ModelRegistry.empty()` (Task 1), `BackendProvider` (Task 1), `AgentConfigLoader.withDefaults()` (Task 3), `ManifestResult.providers()` (Task 3)
- Produces: `RoutingAgentProvider.of(AgentBackend...)`, `RoutingAgentProvider.of(List, ManifestResult)`, `RoutingAgentProvider.of(List, ManifestResult, ModelRegistry)`, `RoutingAgentProvider.discover(Path)`, `RoutingAgentProvider.discover(Path, String)`

- [ ] **Step 1: Write failing tests for of() factories**

Create `agent-router-core/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderFactoryTest.java`:

```java
package io.casehub.platform.agent.router;

import io.casehub.platform.agent.AgentBackend;
import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentSession;
import io.casehub.platform.agent.AgentSessionConfig;
import io.casehub.platform.agent.AgentSessionInit;
import io.casehub.platform.agent.config.ManifestResult;
import io.smallrye.mutiny.Multi;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class RoutingAgentProviderFactoryTest {

    @Test
    void ofSingleBackend() {
        var backend = stubBackend("ollama");
        var provider = RoutingAgentProvider.of(backend);
        assertNotNull(provider);
    }

    @Test
    void ofMultipleBackends() {
        var provider = RoutingAgentProvider.of(
                stubBackend("ollama"), stubBackend("claude"));
        assertNotNull(provider);
    }

    @Test
    void ofWithManifest() {
        var manifest = ManifestResult.empty();
        var provider = RoutingAgentProvider.of(
                java.util.List.of(stubBackend("ollama")), manifest);
        assertNotNull(provider);
    }

    private AgentBackend stubBackend(String key) {
        return new AgentBackend() {
            @Override public String key() { return key; }
            @Override public Multi<AgentEvent> invoke(AgentSessionConfig config) {
                return Multi.createFrom().empty();
            }
            @Override public AgentSession openSession(AgentSessionInit init) {
                throw new UnsupportedOperationException();
            }
        };
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl agent-router-core -Dtest=RoutingAgentProviderFactoryTest`
Expected: FAIL — `of()` methods not found.

- [ ] **Step 3: Implement of() factories**

In `RoutingAgentProvider.java`, add the escape-hatch factories:

```java
public static RoutingAgentProvider of(AgentBackend... backends) {
    return of(java.util.List.of(backends), ManifestResult.empty());
}

public static RoutingAgentProvider of(java.util.List<AgentBackend> backends, ManifestResult manifest) {
    return of(backends, manifest, ModelRegistry.empty());
}

public static RoutingAgentProvider of(java.util.List<AgentBackend> backends,
        ManifestResult manifest, ModelRegistry modelRegistry) {
    var registry = InMemoryBackendInstanceRegistry.of(backends.toArray(AgentBackend[]::new));
    String defaultKey = manifest.defaultBackendKey() != null
            ? manifest.defaultBackendKey()
            : (backends.isEmpty() ? null : backends.get(0).key());
    return new RoutingAgentProvider(registry, defaultKey, modelRegistry,
            manifest.aliases());
}
```

- [ ] **Step 4: Run of() tests**

Run: `mvn --batch-mode test -pl agent-router-core -Dtest=RoutingAgentProviderFactoryTest`
Expected: PASS.

- [ ] **Step 5: Write failing test for discover()**

Add to `RoutingAgentProviderFactoryTest.java`:

```java
@Test
void discoverWithEmptyDirReturnsProvider(@TempDir java.nio.file.Path tempDir) {
    var provider = RoutingAgentProvider.discover(tempDir);
    assertNotNull(provider);
}

@Test
void discoverWithProfileReturnsProvider(@TempDir java.nio.file.Path tempDir) {
    var provider = RoutingAgentProvider.discover(tempDir, "test");
    assertNotNull(provider);
}
```

Add `import org.junit.jupiter.api.io.TempDir;` to imports.

- [ ] **Step 6: Implement discover()**

In `RoutingAgentProvider.java`, add:

```java
import io.casehub.platform.agent.BackendProvider;
import io.casehub.platform.agent.config.AgentConfigLoader;
import java.nio.file.Path;
import java.util.ServiceLoader;

private static final org.jboss.logging.Logger LOG =
        org.jboss.logging.Logger.getLogger(RoutingAgentProvider.class);

public static RoutingAgentProvider discover(Path projectDir) {
    return discover(projectDir, null);
}

public static RoutingAgentProvider discover(Path projectDir, String profile) {
    var loader = AgentConfigLoader.withDefaults(projectDir, profile);
    var manifest = loader.load();

    var backendProviders = ServiceLoader.load(BackendProvider.class);
    var registry = new InMemoryBackendInstanceRegistry();

    for (var entry : manifest.providers().entrySet()) {
        var vendorKey = entry.getKey();
        var properties = entry.getValue();
        backendProviders.stream()
                .map(ServiceLoader.Provider::get)
                .filter(p -> p.vendorKey().equals(vendorKey))
                .findFirst()
                .ifPresentOrElse(
                        p -> registry.register(p.create(properties)),
                        () -> LOG.warnf("No BackendProvider found for vendor '%s' — skipping", vendorKey));
    }

    return create(registry,
            manifest.defaultBackendKey() != null ? manifest.defaultBackendKey() : "claude",
            loader.modelRegistry(),
            java.util.Optional.of(manifest));
}
```

- [ ] **Step 7: Add routing annotation to invoke stream**

In `RoutingAgentProvider`'s resolve-and-invoke flow, after the backend is resolved but before the result stream is returned, map `InvocationComplete` events to include routing info. Find the method that calls `backend.invoke()` (likely `attemptInvoke` or `resolveAndInvokeWithRetry`) and wrap:

```java
// After resolving backend with key and instanceId:
Multi<AgentEvent> result = resolvedBackend.invoke(config);
return result.map(event -> {
    if (event instanceof AgentEvent.InvocationComplete ic && ic.backendKey() == null) {
        return ic.withRouting(resolvedBackend.key(), resolvedBackend.instanceId());
    }
    return event;
});
```

The exact insertion point depends on the resolve flow structure — use `ide_find_references` on `invoke(AgentSessionConfig)` within RoutingAgentProvider to find the call site.

- [ ] **Step 8: Run all tests**

Run: `mvn --batch-mode test -pl agent-router-core -am`
Expected: All tests pass.

- [ ] **Step 9: Commit**

```bash
git add agent-router-core/src
git commit -m "feat(#628): add RoutingAgentProvider.of() and discover() factories"
```

### Task 5: BackendProvider implementations + ServiceLoader registration

**Files:**
- Create: `agent-ollama-core/src/main/java/io/casehub/platform/agent/ollama/OllamaBackendProvider.java`
- Create: `agent-ollama-core/src/main/resources/META-INF/services/io.casehub.platform.agent.BackendProvider`
- Create: `agent-openai-core/src/main/java/io/casehub/platform/agent/openai/OpenAiBackendProvider.java`
- Create: `agent-openai-core/src/main/resources/META-INF/services/io.casehub.platform.agent.BackendProvider`
- Create: `agent-gemini-core/src/main/java/io/casehub/platform/agent/gemini/GeminiBackendProvider.java`
- Create: `agent-gemini-core/src/main/resources/META-INF/services/io.casehub.platform.agent.BackendProvider`
- Create: `agent-claude-core/src/main/java/io/casehub/platform/agent/claude/ClaudeBackendProvider.java`
- Create: `agent-claude-core/src/main/resources/META-INF/services/io.casehub.platform.agent.BackendProvider`
- Create: `agent-codex-core/src/main/java/io/casehub/platform/agent/codex/CodexBackendProvider.java`
- Create: `agent-codex-core/src/main/resources/META-INF/services/io.casehub.platform.agent.BackendProvider`
- Create: `agent-gemini-cli-core/src/main/java/io/casehub/platform/agent/gemini/cli/GeminiCliBackendProvider.java`
- Create: `agent-gemini-cli-core/src/main/resources/META-INF/services/io.casehub.platform.agent.BackendProvider`
- Test: `agent-ollama-core/src/test/java/io/casehub/platform/agent/ollama/OllamaBackendProviderTest.java`
- Test: `agent-router-core/src/test/java/io/casehub/platform/agent/router/DiscoverIntegrationTest.java`

**Interfaces:**
- Consumes: `BackendProvider` (Task 1), `OllamaAgentProperties` / `OpenAiAgentProperties` / etc., `SubprocessRuntime` (agent-runtime-core)
- Produces: ServiceLoader-discoverable `BackendProvider` implementations for all 6 backends

- [ ] **Step 1: Write failing test for OllamaBackendProvider**

Create `agent-ollama-core/src/test/java/io/casehub/platform/agent/ollama/OllamaBackendProviderTest.java`:

```java
package io.casehub.platform.agent.ollama;

import io.casehub.platform.agent.BackendProvider;
import org.junit.jupiter.api.Test;
import java.util.Map;
import java.util.ServiceLoader;

import static org.junit.jupiter.api.Assertions.*;

class OllamaBackendProviderTest {

    @Test
    void vendorKeyIsOllama() {
        var provider = new OllamaBackendProvider();
        assertEquals("ollama", provider.vendorKey());
    }

    @Test
    void createReturnsOllamaBackend() {
        var provider = new OllamaBackendProvider();
        var backend = provider.create(Map.of("host", "http://localhost:11434"));
        assertNotNull(backend);
        assertEquals("ollama", backend.key());
    }

    @Test
    void createWithDefaultHost() {
        var provider = new OllamaBackendProvider();
        var backend = provider.create(Map.of());
        assertNotNull(backend);
    }

    @Test
    void discoveredViaServiceLoader() {
        var providers = ServiceLoader.load(BackendProvider.class);
        var ollama = providers.stream()
                .map(ServiceLoader.Provider::get)
                .filter(p -> "ollama".equals(p.vendorKey()))
                .findFirst();
        assertTrue(ollama.isPresent());
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl agent-ollama-core -Dtest=OllamaBackendProviderTest`
Expected: FAIL — class not found.

- [ ] **Step 3: Implement OllamaBackendProvider**

Create `agent-ollama-core/src/main/java/io/casehub/platform/agent/ollama/OllamaBackendProvider.java`:

```java
package io.casehub.platform.agent.ollama;

import io.casehub.platform.agent.AgentBackend;
import io.casehub.platform.agent.BackendProvider;
import java.util.Map;

/** ServiceLoader-discovered factory for Ollama backends. */
public class OllamaBackendProvider implements BackendProvider {

    @Override
    public String vendorKey() {
        return "ollama";
    }

    @Override
    public AgentBackend create(Map<String, String> properties) {
        return new OllamaAgentBackend(new OllamaAgentProperties() {
            @Override public String host() {
                return properties.getOrDefault("host", "http://localhost:11434");
            }
            @Override public String defaultModel() {
                return properties.getOrDefault("default-model", "llama3.2");
            }
            @Override public int defaultTimeout() {
                return Integer.parseInt(properties.getOrDefault("default-timeout", "120"));
            }
            @Override public int maxConcurrentSessions() {
                return Integer.parseInt(properties.getOrDefault("max-concurrent-sessions", "4"));
            }
        });
    }
}
```

Create `agent-ollama-core/src/main/resources/META-INF/services/io.casehub.platform.agent.BackendProvider`:

```
io.casehub.platform.agent.ollama.OllamaBackendProvider
```

- [ ] **Step 4: Run Ollama tests**

Run: `mvn --batch-mode test -pl agent-ollama-core -Dtest=OllamaBackendProviderTest`
Expected: PASS.

- [ ] **Step 5: Implement remaining SDK BackendProviders**

**OpenAiBackendProvider** (`agent-openai-core`):

```java
package io.casehub.platform.agent.openai;

import io.casehub.platform.agent.AgentBackend;
import io.casehub.platform.agent.BackendProvider;
import java.util.Map;
import java.util.Optional;

public class OpenAiBackendProvider implements BackendProvider {
    @Override public String vendorKey() { return "openai"; }
    @Override public AgentBackend create(Map<String, String> properties) {
        return new OpenAiAgentBackend(new OpenAiAgentProperties() {
            @Override public Optional<String> apiKey() {
                return Optional.ofNullable(properties.get("api-key"));
            }
            @Override public String defaultModel() {
                return properties.getOrDefault("default-model", "gpt-4o");
            }
            @Override public String promptCacheRetention() {
                return properties.getOrDefault("prompt-cache-retention", "auto");
            }
            @Override public int defaultTimeout() {
                return Integer.parseInt(properties.getOrDefault("default-timeout", "120"));
            }
            @Override public int maxConcurrentSessions() {
                return Integer.parseInt(properties.getOrDefault("max-concurrent-sessions", "4"));
            }
        });
    }
}
```

ServiceLoader file: `agent-openai-core/src/main/resources/META-INF/services/io.casehub.platform.agent.BackendProvider`
```
io.casehub.platform.agent.openai.OpenAiBackendProvider
```

**GeminiBackendProvider** (`agent-gemini-core`):

```java
package io.casehub.platform.agent.gemini;

import io.casehub.platform.agent.AgentBackend;
import io.casehub.platform.agent.BackendProvider;
import java.util.Map;
import java.util.Optional;

public class GeminiBackendProvider implements BackendProvider {
    @Override public String vendorKey() { return "gemini"; }
    @Override public AgentBackend create(Map<String, String> properties) {
        return new GeminiAgentBackend(new GeminiAgentProperties() {
            @Override public Optional<String> apiKey() {
                return Optional.ofNullable(properties.get("api-key"));
            }
            @Override public String defaultModel() {
                return properties.getOrDefault("default-model", "gemini-2.0-flash");
            }
            @Override public String cacheTtl() {
                return properties.getOrDefault("cache-ttl", "300");
            }
            @Override public int defaultTimeout() {
                return Integer.parseInt(properties.getOrDefault("default-timeout", "120"));
            }
            @Override public int maxConcurrentSessions() {
                return Integer.parseInt(properties.getOrDefault("max-concurrent-sessions", "4"));
            }
        });
    }
}
```

ServiceLoader file: `agent-gemini-core/src/main/resources/META-INF/services/io.casehub.platform.agent.BackendProvider`
```
io.casehub.platform.agent.gemini.GeminiBackendProvider
```

- [ ] **Step 6: Implement CLI BackendProviders**

**ClaudeBackendProvider** (`agent-claude-core`):

```java
package io.casehub.platform.agent.claude;

import io.casehub.platform.agent.AgentBackend;
import io.casehub.platform.agent.AgentRuntime;
import io.casehub.platform.agent.BackendProvider;
import java.util.Map;
import java.util.Optional;

public class ClaudeBackendProvider implements BackendProvider {
    @Override public String vendorKey() { return "claude"; }
    @Override public AgentBackend create(Map<String, String> properties) {
        var runtime = createRuntime();
        var client = new ClaudeAgentClient(new ClaudeAgentProperties() {
            @Override public Optional<String> binaryPath() {
                return Optional.ofNullable(properties.get("binary-path"));
            }
            @Override public int defaultTimeout() {
                return Integer.parseInt(properties.getOrDefault("default-timeout", "300"));
            }
            @Override public int maxConcurrentSessions() {
                return Integer.parseInt(properties.getOrDefault("max-concurrent-sessions", "2"));
            }
        }, runtime);
        return new ClaudeAgentProvider(client);
    }

    private AgentRuntime createRuntime() {
        try {
            var clazz = Class.forName("io.casehub.platform.agent.runtime.SubprocessRuntime");
            return (AgentRuntime) clazz.getDeclaredConstructor().newInstance();
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException(
                    "agent-runtime-core must be on the classpath for Claude CLI backend", e);
        }
    }
}
```

ServiceLoader file: `agent-claude-core/src/main/resources/META-INF/services/io.casehub.platform.agent.BackendProvider`
```
io.casehub.platform.agent.claude.ClaudeBackendProvider
```

**CodexBackendProvider** (`agent-codex-core`) — same pattern, key `"codex"`, uses `CodexAgentBackend(CodexAgentProperties, AgentRuntime)`.

**GeminiCliBackendProvider** (`agent-gemini-cli-core`) — same pattern, key `"gemini-cli"`, uses `GeminiCliAgentBackend(GeminiCliAgentProperties, AgentRuntime)`.

For codex and gemini-cli: follow the exact same `createRuntime()` pattern, with properties interfaces specific to each backend. Create the corresponding `META-INF/services` files.

- [ ] **Step 7: Write discover integration test**

Create `agent-router-core/src/test/java/io/casehub/platform/agent/router/DiscoverIntegrationTest.java`:

```java
package io.casehub.platform.agent.router;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

class DiscoverIntegrationTest {

    @TempDir Path tempDir;

    @Test
    void discoverWithNoManifestReturnsEmptyProvider() {
        var provider = RoutingAgentProvider.discover(tempDir);
        assertNotNull(provider);
    }

    @Test
    void discoverSkipsUnresolvableProviders() throws Exception {
        Files.writeString(tempDir.resolve("agent-config.yaml"), """
                providers:
                  - vendor: nonexistent-vendor
                    host: localhost:9999
                """);
        var provider = RoutingAgentProvider.discover(tempDir);
        assertNotNull(provider);
    }
}
```

- [ ] **Step 8: Run all tests**

Run: `mvn --batch-mode test -pl agent-ollama-core,agent-openai-core,agent-gemini-core,agent-claude-core,agent-codex-core,agent-gemini-cli-core,agent-router-core -am`
Expected: All tests pass.

- [ ] **Step 9: Full build verification**

Run: `mvn --batch-mode install`
Expected: Full build succeeds including all modules.

- [ ] **Step 10: Commit**

```bash
git add agent-ollama-core/src agent-openai-core/src agent-gemini-core/src agent-claude-core/src agent-codex-core/src agent-gemini-cli-core/src agent-router-core/src
git commit -m "feat(#628): add BackendProvider implementations with ServiceLoader discovery"
```

---

## References

- [2026-10-17-standalone-agent-provider-design.md] — design spec this plan implements
- [agent-api/src/main/java/io/casehub/platform/agent/AgentEvent.java:72] — InvocationComplete record
- [agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestResult.java] — record expansion
- [agent-config-core/src/main/java/io/casehub/platform/agent/config/AgentConfigLoader.java] — 9-arg constructor
- [agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestProcessor.java:110] — processAliasesAndDefaults
- [agent-router-core/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java] — existing create() factories
- [agent-router/src/main/java/io/casehub/platform/agent/router/InMemoryBackendInstanceRegistry.java] — extraction source
- [agent-ollama-core/src/main/java/io/casehub/platform/agent/ollama/OllamaAgentBackend.java] — backend construction
- [platform-api/src/main/java/io/casehub/platform/api/model/ModelRegistry.java] — empty() addition
- [GitHub #628] — Standalone AgentProvider factory — manifest to provider without CDI
