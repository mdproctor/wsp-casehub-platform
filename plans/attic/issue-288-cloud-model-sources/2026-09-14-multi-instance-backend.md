# Multi-Instance Backend Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #290 — multi-instance backend support
**Issue group:** #288, #289, #290, #292

**Goal:** Allow multiple instances of the same AgentBackend type with different configurations, enabling cross-platform invocation (Claude via API vs Vertex vs Bedrock) and multi-credential same-platform (two OpenAI API keys).

**Architecture:** New SPI types in agent-api (`BackendInstanceRegistry`, `BackendInstanceFactory`, `BackendRef`). `InMemoryBackendInstanceRegistry` in agent-router populates at startup from CDI-discovered backends + credential-store-driven factories. `RoutingAgentProvider` switches from direct `Instance<AgentBackend>` to registry-based dispatch with compound `(key, instanceId)` lookup. `ModelDescriptor` gains nullable `backendInstanceId` field.

**Tech Stack:** Java 21, Quarkus CDI, JUnit 5, AssertJ

## Global Constraints

- `agent-api/` must remain pure Java + Mutiny — no Quarkus, no CDI annotations
- `platform-api/` must remain zero-dependency — pure Java only
- All new records in `agent-api/` must use `Objects.requireNonNull` validation in compact constructors
- TDD: write failing test first, then implement

---

## Batch 1: Foundation — SPI types + ModelDescriptor

### Task 1: New SPI types in agent-api + AgentBackend.instanceId()

**Files:**
- Create: `agent-api/src/main/java/io/casehub/platform/agent/BackendRef.java`
- Create: `agent-api/src/main/java/io/casehub/platform/agent/BackendInstance.java`
- Create: `agent-api/src/main/java/io/casehub/platform/agent/BackendInstanceFactory.java`
- Create: `agent-api/src/main/java/io/casehub/platform/agent/BackendInstanceRegistry.java`
- Modify: `agent-api/src/main/java/io/casehub/platform/agent/AgentBackend.java`
- Test: `agent-api/src/test/java/io/casehub/platform/agent/BackendRefTest.java`
- Test: `agent-api/src/test/java/io/casehub/platform/agent/BackendInstanceTest.java`

**Interfaces:**
- Produces: `BackendRef(String key, String instanceId)` — compound key record
- Produces: `BackendInstance(String instanceId, AgentBackend backend)` — factory output
- Produces: `BackendInstanceFactory` — `backendKey()`, `handles(String, Map)`, `create(String, Map)`
- Produces: `BackendInstanceRegistry` — `register(AgentBackend)`, `resolve(String, String)`, `resolveByKey(String)`
- Produces: `AgentBackend.instanceId()` — default method returning `"default"`

- [ ] **Step 1: Write BackendRef tests**

```java
package io.casehub.platform.agent;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class BackendRefTest {
    @Test
    void equalityByKeyAndInstanceId() {
        var ref1 = new BackendRef("claude", "vertex");
        var ref2 = new BackendRef("claude", "vertex");
        assertThat(ref1).isEqualTo(ref2);
        assertThat(ref1.hashCode()).isEqualTo(ref2.hashCode());
    }

    @Test
    void differentInstanceIdNotEqual() {
        var ref1 = new BackendRef("claude", "default");
        var ref2 = new BackendRef("claude", "vertex");
        assertThat(ref1).isNotEqualTo(ref2);
    }

    @Test
    void nullKeyThrows() {
        assertThatThrownBy(() -> new BackendRef(null, "default"))
                .isInstanceOf(NullPointerException.class);
    }

    @Test
    void nullInstanceIdThrows() {
        assertThatThrownBy(() -> new BackendRef("claude", null))
                .isInstanceOf(NullPointerException.class);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-api -Dtest=BackendRefTest`
Expected: FAIL — `BackendRef` class not found

- [ ] **Step 3: Implement BackendRef**

```java
package io.casehub.platform.agent;

import java.util.Objects;

public record BackendRef(String key, String instanceId) {
    public BackendRef {
        Objects.requireNonNull(key, "key");
        Objects.requireNonNull(instanceId, "instanceId");
    }
}
```

- [ ] **Step 4: Run BackendRef tests to verify they pass**

Run: `mvn --batch-mode test -pl agent-api -Dtest=BackendRefTest`
Expected: PASS

- [ ] **Step 5: Write BackendInstance tests**

```java
package io.casehub.platform.agent;

import io.smallrye.mutiny.Multi;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class BackendInstanceTest {
    @Test
    void holdsInstanceIdAndBackend() {
        AgentBackend backend = stubBackend("openai");
        var instance = new BackendInstance("extra", backend);
        assertThat(instance.instanceId()).isEqualTo("extra");
        assertThat(instance.backend()).isSameAs(backend);
    }

    @Test
    void nullInstanceIdThrows() {
        assertThatThrownBy(() -> new BackendInstance(null, stubBackend("x")))
                .isInstanceOf(NullPointerException.class);
    }

    @Test
    void nullBackendThrows() {
        assertThatThrownBy(() -> new BackendInstance("id", null))
                .isInstanceOf(NullPointerException.class);
    }

    static AgentBackend stubBackend(String key) {
        return new AgentBackend() {
            @Override public String key() { return key; }
            @Override public Multi<AgentEvent> invoke(AgentSessionConfig c) {
                return Multi.createFrom().empty();
            }
            @Override public AgentSession openSession(AgentSessionInit i) { return null; }
        };
    }
}
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-api -Dtest=BackendInstanceTest`
Expected: FAIL — `BackendInstance` class not found

- [ ] **Step 7: Implement BackendInstance**

```java
package io.casehub.platform.agent;

import java.util.Objects;

public record BackendInstance(String instanceId, AgentBackend backend) {
    public BackendInstance {
        Objects.requireNonNull(instanceId, "instanceId");
        Objects.requireNonNull(backend, "backend");
    }
}
```

- [ ] **Step 8: Run BackendInstance tests to verify they pass**

Run: `mvn --batch-mode test -pl agent-api -Dtest=BackendInstanceTest`
Expected: PASS

- [ ] **Step 9: Implement BackendInstanceFactory interface**

```java
package io.casehub.platform.agent;

import java.util.Map;

public interface BackendInstanceFactory {
    String backendKey();
    boolean handles(String credentialRef, Map<String, String> credentials);
    BackendInstance create(String credentialRef, Map<String, String> credentials);
}
```

No tests — it's a pure interface.

- [ ] **Step 10: Implement BackendInstanceRegistry interface**

```java
package io.casehub.platform.agent;

import java.util.List;
import java.util.Optional;

public interface BackendInstanceRegistry {
    void register(AgentBackend backend);
    Optional<AgentBackend> resolve(String key, String instanceId);
    List<AgentBackend> resolveByKey(String key);
}
```

No tests — pure interface.

- [ ] **Step 11: Add instanceId() default method to AgentBackend**

Add after `key()` in `AgentBackend.java`:

```java
default String instanceId() { return "default"; }
```

- [ ] **Step 12: Verify existing AgentBackendTest still passes**

Run: `mvn --batch-mode test -pl agent-api -Dtest=AgentBackendTest`
Expected: PASS — default method is backward compatible

- [ ] **Step 13: Commit**

```bash
git add agent-api/src/main/java/io/casehub/platform/agent/BackendRef.java agent-api/src/main/java/io/casehub/platform/agent/BackendInstance.java agent-api/src/main/java/io/casehub/platform/agent/BackendInstanceFactory.java agent-api/src/main/java/io/casehub/platform/agent/BackendInstanceRegistry.java agent-api/src/main/java/io/casehub/platform/agent/AgentBackend.java agent-api/src/test/java/io/casehub/platform/agent/BackendRefTest.java agent-api/src/test/java/io/casehub/platform/agent/BackendInstanceTest.java
git commit -m "feat(#290): add multi-instance backend SPI types and AgentBackend.instanceId()"
```

### Task 2: ModelDescriptor.backendInstanceId + constructor migration

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/model/ModelDescriptor.java`
- Modify: `platform/src/main/java/io/casehub/platform/model/SeedCatalogModelSource.java:72` (constructor call)
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/AnthropicClient.java:95,100` (constructor calls)
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/OpenAiClient.java:93,98` (constructor calls)
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/GoogleClient.java:94,99` (constructor calls)
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/OllamaClient.java:86,91` (constructor calls)
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/ConfiguredModelSource.java:55` (constructor call)
- Modify: `llm-config-vertex/src/main/java/io/casehub/platform/llm/config/vertex/VertexClient.java:108,113` (constructor calls)
- Modify: `llm-config-bedrock/src/main/java/io/casehub/platform/llm/config/bedrock/BedrockClient.java:124,129` (constructor calls)
- Modify: `agent-router/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderTest.java:94` (test helper)
- Modify: all test files that construct `ModelDescriptor` (find via `ide_find_references`)
- Test: existing tests must pass after migration

**Interfaces:**
- Consumes: `ModelDescriptor` record (current 14-field constructor)
- Produces: `ModelDescriptor` with 15-field constructor (new nullable `backendInstanceId` after `backendKey`)

- [ ] **Step 1: Add backendInstanceId field to ModelDescriptor**

In `ModelDescriptor.java`, add `String backendInstanceId` after `String backendKey` in the record components. The field is nullable — do NOT add `requireNonNull` for it in the compact constructor.

Before:
```java
public record ModelDescriptor(
    String id,
    String apiModelId,
    String backendKey,
    String vendor,
```

After:
```java
public record ModelDescriptor(
    String id,
    String apiModelId,
    String backendKey,
    String backendInstanceId,
    String vendor,
```

- [ ] **Step 2: Run build to identify all broken constructor calls**

Run: `mvn --batch-mode compile -pl platform-api,platform,agent-router,llm-config,llm-config-vertex,llm-config-bedrock`
Expected: FAIL — compilation errors at every `new ModelDescriptor(` call site missing the new field

- [ ] **Step 3: Fix SeedCatalogModelSource constructor call**

In `SeedCatalogModelSource.java` line 72, add `null,` after `node.get("backendKey").asText(),`:

```java
return new ModelDescriptor(
    node.get("id").asText(),
    node.get("id").asText(),
    node.get("backendKey").asText(),
    null,  // backendInstanceId — seed catalog models use default instance
    node.get("vendor").asText(),
```

- [ ] **Step 4: Fix VendorClient constructor calls**

For each VendorClient (`AnthropicClient`, `OpenAiClient`, `GoogleClient`, `OllamaClient`, `VertexClient`, `BedrockClient`), add `null,` after the `backendKey` argument in every `new ModelDescriptor(` call. These are the seed-enriched and non-seed branches.

Example pattern — in each `parseModelsResponse()` method, find both `new ModelDescriptor(` calls and add `null,` after the `backendKey` argument (3rd position).

- [ ] **Step 5: Fix ConfiguredModelSource.toTenantScoped()**

In `ConfiguredModelSource.java` line 55, add `null,` after `backendKey` in the `new ModelDescriptor(` call inside the `.map()` lambda.

- [ ] **Step 6: Fix RoutingAgentProviderTest.descriptor() helper**

In `RoutingAgentProviderTest.java` line 94, add `null,` after `backendKey`:

Before:
```java
return new ModelDescriptor(id, id, backendKey, "test-vendor", "test-family",
```

After:
```java
return new ModelDescriptor(id, id, backendKey, null, "test-vendor", "test-family",
```

- [ ] **Step 7: Find and fix remaining test constructor calls**

Run: `ide_find_references` on `ModelDescriptor` constructor with scope `project_test_files`. Fix each `new ModelDescriptor(` call by adding `null,` after the `backendKey` (3rd) argument.

- [ ] **Step 8: Build and run all tests**

Run: `mvn --batch-mode install`
Expected: PASS — all modules compile, all tests pass

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat(#290): add backendInstanceId field to ModelDescriptor"
```

---

## Batch 2: Infrastructure — Registry + Coordinator + Router

### Task 3: InMemoryBackendInstanceRegistry + InstanceWrapper

**Files:**
- Create: `agent-router/src/main/java/io/casehub/platform/agent/router/InMemoryBackendInstanceRegistry.java`
- Create: `agent-router/src/main/java/io/casehub/platform/agent/router/InstanceWrapper.java`
- Test: `agent-router/src/test/java/io/casehub/platform/agent/router/InMemoryBackendInstanceRegistryTest.java`

**Interfaces:**
- Consumes: `BackendInstanceRegistry` (SPI from agent-api, Task 1)
- Consumes: `AgentBackend` (including `instanceId()` default method, Task 1)
- Produces: `InMemoryBackendInstanceRegistry` — `@ApplicationScoped` ConcurrentHashMap implementation
- Produces: `InstanceWrapper(String key, String instanceId, AgentBackend delegate)` — delegating record

- [ ] **Step 1: Write registry tests**

```java
package io.casehub.platform.agent.router;

import io.casehub.platform.agent.AgentBackend;
import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentSession;
import io.casehub.platform.agent.AgentSessionConfig;
import io.casehub.platform.agent.AgentSessionInit;
import io.smallrye.mutiny.Multi;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class InMemoryBackendInstanceRegistryTest {

    @Test
    void registerAndResolve() {
        var registry = new InMemoryBackendInstanceRegistry();
        var backend = stubBackend("claude", "default");
        registry.register(backend);
        assertThat(registry.resolve("claude", "default")).contains(backend);
    }

    @Test
    void resolveUnknownReturnsEmpty() {
        var registry = new InMemoryBackendInstanceRegistry();
        assertThat(registry.resolve("claude", "default")).isEmpty();
    }

    @Test
    void resolveByKeyReturnsAllInstances() {
        var registry = new InMemoryBackendInstanceRegistry();
        var direct = stubBackend("claude", "default");
        var vertex = stubBackend("claude", "vertex");
        var openai = stubBackend("openai", "default");
        registry.register(direct);
        registry.register(vertex);
        registry.register(openai);
        assertThat(registry.resolveByKey("claude")).containsExactlyInAnyOrder(direct, vertex);
    }

    @Test
    void lastWriteWinsOnSameCompoundKey() {
        var registry = new InMemoryBackendInstanceRegistry();
        var first = stubBackend("openai", "default");
        var second = stubBackend("openai", "default");
        registry.register(first);
        registry.register(second);
        assertThat(registry.resolve("openai", "default")).contains(second);
    }

    @Test
    void instanceWrapperDelegatesInvoke() {
        var delegate = stubBackend("openai", "default");
        var wrapper = new InstanceWrapper("openai", "extra", delegate);
        assertThat(wrapper.key()).isEqualTo("openai");
        assertThat(wrapper.instanceId()).isEqualTo("extra");
        var events = wrapper.invoke(AgentSessionConfig.of("s", "u"))
                .collect().asList().await().indefinitely();
        assertThat(events).hasSize(1);
    }

    static AgentBackend stubBackend(String key, String instanceId) {
        return new AgentBackend() {
            @Override public String key() { return key; }
            @Override public String instanceId() { return instanceId; }
            @Override public Multi<AgentEvent> invoke(AgentSessionConfig c) {
                return Multi.createFrom().item(new AgentEvent.TextDelta("from-" + key + "-" + instanceId));
            }
            @Override public AgentSession openSession(AgentSessionInit i) { return null; }
        };
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-router -Dtest=InMemoryBackendInstanceRegistryTest`
Expected: FAIL — classes not found

- [ ] **Step 3: Implement InstanceWrapper**

```java
package io.casehub.platform.agent.router;

import io.casehub.platform.agent.AgentBackend;
import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentSession;
import io.casehub.platform.agent.AgentSessionConfig;
import io.casehub.platform.agent.AgentSessionInit;
import io.smallrye.mutiny.Multi;

record InstanceWrapper(String key, String instanceId, AgentBackend delegate) implements AgentBackend {
    @Override
    public Multi<AgentEvent> invoke(AgentSessionConfig config) {
        return delegate.invoke(config);
    }

    @Override
    public AgentSession openSession(AgentSessionInit init) {
        return delegate.openSession(init);
    }
}
```

- [ ] **Step 4: Implement InMemoryBackendInstanceRegistry**

```java
package io.casehub.platform.agent.router;

import io.casehub.platform.agent.AgentBackend;
import io.casehub.platform.agent.BackendInstanceRegistry;
import io.casehub.platform.agent.BackendRef;
import jakarta.enterprise.context.ApplicationScoped;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

@ApplicationScoped
public class InMemoryBackendInstanceRegistry implements BackendInstanceRegistry {

    private final ConcurrentHashMap<BackendRef, AgentBackend> instances = new ConcurrentHashMap<>();

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

- [ ] **Step 5: Run registry tests to verify they pass**

Run: `mvn --batch-mode test -pl agent-router -Dtest=InMemoryBackendInstanceRegistryTest`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add agent-router/src/main/java/io/casehub/platform/agent/router/InMemoryBackendInstanceRegistry.java agent-router/src/main/java/io/casehub/platform/agent/router/InstanceWrapper.java agent-router/src/test/java/io/casehub/platform/agent/router/InMemoryBackendInstanceRegistryTest.java
git commit -m "feat(#290): add InMemoryBackendInstanceRegistry and InstanceWrapper"
```

### Task 4: BackendInstanceCoordinator + RoutingAgentProvider refactor

**Files:**
- Create: `agent-router/src/main/java/io/casehub/platform/agent/router/BackendInstanceCoordinator.java`
- Modify: `agent-router/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java`
- Test: `agent-router/src/test/java/io/casehub/platform/agent/router/BackendInstanceCoordinatorTest.java`
- Modify: `agent-router/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderTest.java`

**Interfaces:**
- Consumes: `BackendInstanceRegistry` (Task 1), `InMemoryBackendInstanceRegistry` (Task 3)
- Consumes: `BackendInstanceFactory`, `BackendInstance` (Task 1)
- Consumes: `LlmCredentialStore` — `listRefs(tenancyId)`, `resolve(tenancyId, ref)`
- Produces: `BackendInstanceCoordinator` — `@Observes @Priority(75) StartupEvent`
- Produces: `RoutingAgentProvider` refactored to use `BackendInstanceRegistry`

- [ ] **Step 1: Write coordinator tests**

```java
package io.casehub.platform.agent.router;

import io.casehub.platform.agent.AgentBackend;
import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentSession;
import io.casehub.platform.agent.AgentSessionConfig;
import io.casehub.platform.agent.AgentSessionInit;
import io.casehub.platform.agent.BackendInstance;
import io.casehub.platform.agent.BackendInstanceFactory;
import io.casehub.platform.agent.BackendInstanceRegistry;
import io.casehub.platform.api.credentials.LlmCredentialStore;
import io.smallrye.mutiny.Multi;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class BackendInstanceCoordinatorTest {

    @Test
    void registersCdiBackends() {
        var registry = new InMemoryBackendInstanceRegistry();
        var backend = stubBackend("claude", "default");
        var coordinator = new BackendInstanceCoordinator(
                registry, List.of(backend), List.of(), emptyCredentialStore());
        coordinator.onStartup();
        assertThat(registry.resolve("claude", "default")).contains(backend);
    }

    @Test
    void createsFactoryInstancesFromCredentials() {
        var registry = new InMemoryBackendInstanceRegistry();
        var factory = new BackendInstanceFactory() {
            @Override public String backendKey() { return "openai"; }
            @Override public boolean handles(String ref, Map<String, String> creds) {
                return ref.contains("openai") && creds.containsKey("api-key");
            }
            @Override public BackendInstance create(String ref, Map<String, String> creds) {
                return new BackendInstance("extra", stubBackend("openai", "extra"));
            }
        };
        var store = stubCredentialStore(Map.of("extra-openai", Map.of("api-key", "sk-extra")));
        var coordinator = new BackendInstanceCoordinator(
                registry, List.of(), List.of(factory), store);
        coordinator.onStartup();
        assertThat(registry.resolve("openai", "extra")).isPresent();
    }

    @Test
    void factorySkipsNonMatchingCredentials() {
        var registry = new InMemoryBackendInstanceRegistry();
        var factory = new BackendInstanceFactory() {
            @Override public String backendKey() { return "openai"; }
            @Override public boolean handles(String ref, Map<String, String> creds) {
                return ref.contains("openai");
            }
            @Override public BackendInstance create(String ref, Map<String, String> creds) {
                return new BackendInstance("x", stubBackend("openai", "x"));
            }
        };
        var store = stubCredentialStore(Map.of("cloud-anthropic", Map.of("api-key", "sk-ant")));
        var coordinator = new BackendInstanceCoordinator(
                registry, List.of(), List.of(factory), store);
        coordinator.onStartup();
        assertThat(registry.resolve("openai", "x")).isEmpty();
    }

    static AgentBackend stubBackend(String key, String instanceId) {
        return new AgentBackend() {
            @Override public String key() { return key; }
            @Override public String instanceId() { return instanceId; }
            @Override public Multi<AgentEvent> invoke(AgentSessionConfig c) {
                return Multi.createFrom().item(new AgentEvent.TextDelta("from-" + key));
            }
            @Override public AgentSession openSession(AgentSessionInit i) { return null; }
        };
    }

    static LlmCredentialStore emptyCredentialStore() {
        return stubCredentialStore(Map.of());
    }

    static LlmCredentialStore stubCredentialStore(Map<String, Map<String, String>> entries) {
        return new LlmCredentialStore() {
            @Override public void store(String t, String r, Map<String, String> c) {}
            @Override public Map<String, String> resolve(String t, String r) {
                return entries.getOrDefault(r, Map.of());
            }
            @Override public void delete(String t, String r) {}
            @Override public List<String> listRefs(String t) {
                return List.copyOf(entries.keySet());
            }
        };
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-router -Dtest=BackendInstanceCoordinatorTest`
Expected: FAIL — `BackendInstanceCoordinator` class not found

- [ ] **Step 3: Implement BackendInstanceCoordinator**

```java
package io.casehub.platform.agent.router;

import io.casehub.platform.agent.AgentBackend;
import io.casehub.platform.agent.BackendInstance;
import io.casehub.platform.agent.BackendInstanceFactory;
import io.casehub.platform.agent.BackendInstanceRegistry;
import io.casehub.platform.api.credentials.LlmCredentialStore;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import jakarta.enterprise.inject.Any;
import jakarta.enterprise.inject.Instance;
import jakarta.annotation.Priority;
import io.quarkus.runtime.StartupEvent;
import org.jboss.logging.Logger;

import java.util.List;
import java.util.Map;

@ApplicationScoped
public class BackendInstanceCoordinator {

    private static final Logger LOG = Logger.getLogger(BackendInstanceCoordinator.class);
    private static final String PLATFORM_TENANT_ID = "__platform__";

    private final BackendInstanceRegistry registry;
    private final Iterable<AgentBackend> cdiBackends;
    private final Iterable<BackendInstanceFactory> factories;
    private final LlmCredentialStore credentialStore;

    @jakarta.inject.Inject
    public BackendInstanceCoordinator(BackendInstanceRegistry registry,
                                      @Any Instance<AgentBackend> cdiBackends,
                                      @Any Instance<BackendInstanceFactory> factories,
                                      LlmCredentialStore credentialStore) {
        this.registry = registry;
        this.cdiBackends = cdiBackends;
        this.factories = factories;
        this.credentialStore = credentialStore;
    }

    BackendInstanceCoordinator(BackendInstanceRegistry registry,
                               Iterable<AgentBackend> cdiBackends,
                               Iterable<BackendInstanceFactory> factories,
                               LlmCredentialStore credentialStore) {
        this.registry = registry;
        this.cdiBackends = cdiBackends;
        this.factories = factories;
        this.credentialStore = credentialStore;
    }

    void onStartup(@Observes @Priority(75) StartupEvent event) {
        onStartup();
    }

    void onStartup() {
        for (AgentBackend backend : cdiBackends) {
            registry.register(backend);
            LOG.infof("Registered CDI backend: %s/%s", backend.key(), backend.instanceId());
        }

        List<String> refs = credentialStore.listRefs(PLATFORM_TENANT_ID);
        for (String ref : refs) {
            Map<String, String> creds = credentialStore.resolve(PLATFORM_TENANT_ID, ref);
            if (creds.isEmpty()) continue;
            for (BackendInstanceFactory factory : factories) {
                if (factory.handles(ref, creds)) {
                    BackendInstance instance = factory.create(ref, creds);
                    registry.register(new InstanceWrapper(
                            factory.backendKey(), instance.instanceId(), instance.backend()));
                    LOG.infof("Registered factory backend: %s/%s (from %s)",
                            factory.backendKey(), instance.instanceId(), ref);
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run coordinator tests to verify they pass**

Run: `mvn --batch-mode test -pl agent-router -Dtest=BackendInstanceCoordinatorTest`
Expected: PASS

- [ ] **Step 5: Refactor RoutingAgentProvider to use BackendInstanceRegistry**

Replace the constructor and `resolve()` method. The `RoutingAgentProvider` no longer needs `Instance<AgentBackend>` — it only needs the registry:

CDI constructor — replace:
```java
@Inject
public RoutingAgentProvider(@Any Instance<AgentBackend> backends,
                            RoutingAgentProperties properties,
                            ModelRegistry modelRegistry) {
```
with:
```java
@Inject
public RoutingAgentProvider(BackendInstanceRegistry registry,
                            RoutingAgentProperties properties,
                            ModelRegistry modelRegistry) {
    this.registry = registry;
    this.defaultBackendKey = properties.defaultBackend();
    this.modelRegistry = modelRegistry;
}
```

Fields — replace:
```java
private final Map<String, AgentBackend> backends;
private final AgentBackend defaultBackend;
```
with:
```java
private final BackendInstanceRegistry registry;
private final String defaultBackendKey;
```

Test constructor — replace:
```java
RoutingAgentProvider(Iterable<AgentBackend> backends, String defaultKey, ModelRegistry modelRegistry) {
```
with:
```java
RoutingAgentProvider(BackendInstanceRegistry registry, String defaultKey, ModelRegistry modelRegistry) {
    this.registry = registry;
    this.defaultBackendKey = defaultKey;
    this.modelRegistry = modelRegistry;
}
```

`resolve()` method — replace the body:
```java
private ResolvedRoute resolve(String model) {
    if (model == null) {
        var backend = registry.resolve(defaultBackendKey, "default");
        if (backend.isEmpty()) {
            throw new IllegalStateException("No default backend configured: " + defaultBackendKey);
        }
        return new ResolvedRoute(backend.get(), null);
    }

    Optional<ModelDescriptor> descriptor = modelRegistry.resolveById(model);
    if (descriptor.isPresent()) {
        var d = descriptor.get();
        String instanceId = d.backendInstanceId() != null ? d.backendInstanceId() : "default";
        var backend = registry.resolve(d.backendKey(), instanceId);
        if (backend.isEmpty()) {
            throw new IllegalStateException(
                    "Model '" + model + "' resolved to backend " + d.backendKey()
                    + "/" + instanceId + " but no backend with that key/instance is registered");
        }
        return new ResolvedRoute(backend.get(), d.apiModelId());
    }

    var backend = registry.resolve(model, "default");
    if (backend.isPresent()) {
        return new ResolvedRoute(backend.get(), null);
    }

    throw new IllegalArgumentException("No model or backend for: " + model);
}
```

- [ ] **Step 6: Update RoutingAgentProviderTest to use registry**

Replace the test constructor calls. Each test that creates a `RoutingAgentProvider` needs to build a registry and populate it instead of passing `List.of(backends)`.

Add a helper method:
```java
static BackendInstanceRegistry registryWith(AgentBackend... backends) {
    var registry = new InMemoryBackendInstanceRegistry();
    for (var backend : backends) {
        registry.register(backend);
    }
    return registry;
}
```

Update the `descriptor()` helper — add a variant that includes `backendInstanceId`:
```java
static ModelDescriptor descriptorWithInstance(String id, String backendKey, String instanceId) {
    return new ModelDescriptor(id, id, backendKey, instanceId, "test-vendor", "test-family",
            "Test " + id, ModelTier.STANDARD, Set.of(), 128000, 16384,
            ModelLocality.CLOUD, null, null, Map.of());
}
```

Replace all `new RoutingAgentProvider(List.of(...), "claude", registry)` calls with `new RoutingAgentProvider(registryWith(...), "claude", registry)`.

Add a new test for compound key resolution:
```java
@Test
void resolvesByBackendInstanceId() {
    var vertexBackend = stubBackend("claude", "vertex");
    var defaultBackend = stubBackend("claude", "default");
    var reg = registryWith(defaultBackend, vertexBackend);
    var modelReg = registryWith(descriptorWithInstance("claude-vertex-model", "claude", "vertex"));
    var router = new RoutingAgentProvider(reg, "claude", modelReg);
    var config = AgentSessionConfig.of("sys", "user", "claude-vertex-model");
    var events = router.invoke(config).collect().asList().await().indefinitely();
    assertThat(((AgentEvent.TextDelta) events.get(0)).text()).isEqualTo("from-claude-vertex");
}

@Test
void nullInstanceIdFallsBackToDefault() {
    var defaultBackend = stubBackend("claude", "default");
    var reg = registryWith(defaultBackend);
    var modelReg = registryWith(descriptor("claude-sonnet-5", "claude"));
    var router = new RoutingAgentProvider(reg, "claude", modelReg);
    var config = AgentSessionConfig.of("sys", "user", "claude-sonnet-5");
    var events = router.invoke(config).collect().asList().await().indefinitely();
    assertThat(((AgentEvent.TextDelta) events.get(0)).text()).isEqualTo("from-claude-default");
}
```

Update `stubBackend()` to include `instanceId`:
```java
static AgentBackend stubBackend(String key, String instanceId) {
    return new AgentBackend() {
        @Override public String key() { return key; }
        @Override public String instanceId() { return instanceId; }
        @Override public Multi<AgentEvent> invoke(AgentSessionConfig config) {
            return Multi.createFrom().item(new AgentEvent.TextDelta("from-" + key + "-" + instanceId));
        }
        @Override public AgentSession openSession(AgentSessionInit init) { return null; }
    };
}
```

Keep the original `stubBackend(String key)` for backward compatibility — delegate to `stubBackend(key, "default")`.

- [ ] **Step 7: Run all router tests**

Run: `mvn --batch-mode test -pl agent-router`
Expected: PASS

- [ ] **Step 8: Run full build to verify nothing is broken**

Run: `mvn --batch-mode install`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add agent-router/src/main/java/io/casehub/platform/agent/router/BackendInstanceCoordinator.java agent-router/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java agent-router/src/test/java/io/casehub/platform/agent/router/BackendInstanceCoordinatorTest.java agent-router/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderTest.java
git commit -m "feat(#290): add BackendInstanceCoordinator, refactor RoutingAgentProvider to use registry"
```

---

## Batch 3: Proof — OpenAI Factory

### Task 5: OpenAiDirectBackendFactory + OpenAiAgentBackend constructor

**Files:**
- Create: `agent-openai/src/main/java/io/casehub/platform/agent/openai/OpenAiDirectBackendFactory.java`
- Modify: `agent-openai/src/main/java/io/casehub/platform/agent/openai/OpenAiAgentBackend.java` (add factory constructor)
- Test: `agent-openai/src/test/java/io/casehub/platform/agent/openai/OpenAiDirectBackendFactoryTest.java`

**Interfaces:**
- Consumes: `BackendInstanceFactory` (Task 1), `BackendInstance` (Task 1)
- Consumes: `OpenAiAgentBackend` (existing, adding constructor)
- Produces: `OpenAiDirectBackendFactory` — `@ApplicationScoped`, creates OpenAI backends from credential-store API keys

- [ ] **Step 1: Write factory tests**

```java
package io.casehub.platform.agent.openai;

import org.junit.jupiter.api.Test;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class OpenAiDirectBackendFactoryTest {

    private final OpenAiDirectBackendFactory factory = new OpenAiDirectBackendFactory();

    @Test
    void backendKeyIsOpenai() {
        assertThat(factory.backendKey()).isEqualTo("openai");
    }

    @Test
    void handlesOpenaiCredentialRefWithApiKey() {
        assertThat(factory.handles("cloud-openai", Map.of("api-key", "sk-test"))).isTrue();
    }

    @Test
    void doesNotHandleAnthropicRef() {
        assertThat(factory.handles("cloud-anthropic", Map.of("api-key", "sk-ant"))).isFalse();
    }

    @Test
    void doesNotHandleRefWithoutApiKey() {
        assertThat(factory.handles("cloud-openai", Map.of("region", "us-east-1"))).isFalse();
    }

    @Test
    void createProducesBackendWithCorrectInstanceId() {
        var instance = factory.create("cloud-openai", Map.of("api-key", "sk-test"));
        assertThat(instance.instanceId()).isEqualTo("default");
        assertThat(instance.backend().key()).isEqualTo("openai");
    }

    @Test
    void createDeriveNonDefaultInstanceId() {
        var instance = factory.create("extra-openai", Map.of("api-key", "sk-extra"));
        assertThat(instance.instanceId()).isEqualTo("extra");
    }

    @Test
    void createDerivesTenantInstanceId() {
        var instance = factory.create("tenant-42-openai", Map.of("api-key", "sk-t42"));
        assertThat(instance.instanceId()).isEqualTo("tenant-42");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-openai -Dtest=OpenAiDirectBackendFactoryTest`
Expected: FAIL — `OpenAiDirectBackendFactory` class not found

- [ ] **Step 3: Add factory constructor to OpenAiAgentBackend**

Add a package-private constructor that accepts a pre-built `OpenAIClient` and configuration values:

```java
OpenAiAgentBackend(com.openai.client.OpenAIClient client,
                   Duration defaultTimeout, String defaultModel,
                   int maxConcurrentSessions) {
    super(maxConcurrentSessions);
    this.openAiClient = client;
    this.properties = null;
}

private Duration factoryTimeout;
private String factoryModel;
```

Adjust `openAiClient()`, `defaultTimeout()`, and `defaultModel()` to check `properties` nullability and fall back to factory values. If `properties` is null (factory-created), use the stored factory values.

Alternatively, create a simpler implementation: since `AbstractOpenAiSdkBackend` only calls `openAiClient()`, `defaultTimeout()`, `defaultModel()` via abstract methods — the factory constructor can set private fields that these methods return:

```java
OpenAiAgentBackend(com.openai.client.OpenAIClient client,
                   Duration defaultTimeout, String defaultModel,
                   int maxConcurrentSessions) {
    super(maxConcurrentSessions);
    this.openAiClient = client;
    this.properties = null;
    this.factoryTimeout = defaultTimeout;
    this.factoryModel = defaultModel;
}

private Duration factoryTimeout;
private String factoryModel;

@Override
protected com.openai.client.OpenAIClient openAiClient() { return openAiClient; }

@Override
protected Duration defaultTimeout() {
    return properties != null ? properties.defaultTimeout() : factoryTimeout;
}

@Override
protected String defaultModel() {
    return properties != null ? properties.defaultModel() : factoryModel;
}
```

- [ ] **Step 4: Implement OpenAiDirectBackendFactory**

```java
package io.casehub.platform.agent.openai;

import com.openai.client.okhttp.OpenAIOkHttpClient;
import io.casehub.platform.agent.BackendInstance;
import io.casehub.platform.agent.BackendInstanceFactory;
import jakarta.enterprise.context.ApplicationScoped;

import java.time.Duration;
import java.util.Map;

@ApplicationScoped
public class OpenAiDirectBackendFactory implements BackendInstanceFactory {

    @Override
    public String backendKey() { return "openai"; }

    @Override
    public boolean handles(String credentialRef, Map<String, String> credentials) {
        return credentialRef.contains("openai") && credentials.containsKey("api-key");
    }

    @Override
    public BackendInstance create(String credentialRef, Map<String, String> credentials) {
        String apiKey = credentials.get("api-key");
        String instanceId = deriveInstanceId(credentialRef);

        var client = OpenAIOkHttpClient.builder()
                .apiKey(apiKey)
                .build();

        var backend = new OpenAiAgentBackend(client,
                Duration.ofSeconds(30), null, 4);
        return new BackendInstance(instanceId, backend);
    }

    String deriveInstanceId(String credentialRef) {
        if ("cloud-openai".equals(credentialRef)) return "default";
        return credentialRef.replace("-openai", "");
    }
}
```

- [ ] **Step 5: Run factory tests to verify they pass**

Run: `mvn --batch-mode test -pl agent-openai -Dtest=OpenAiDirectBackendFactoryTest`
Expected: PASS

- [ ] **Step 6: Verify existing OpenAiAgentBackendTest still passes**

Run: `mvn --batch-mode test -pl agent-openai`
Expected: PASS — CDI constructor and test constructor unchanged

- [ ] **Step 7: Run full build**

Run: `mvn --batch-mode install`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add agent-openai/src/main/java/io/casehub/platform/agent/openai/OpenAiDirectBackendFactory.java agent-openai/src/main/java/io/casehub/platform/agent/openai/OpenAiAgentBackend.java agent-openai/src/test/java/io/casehub/platform/agent/openai/OpenAiDirectBackendFactoryTest.java
git commit -m "feat(#290): add OpenAiDirectBackendFactory for credential-store-driven instances"
```

---

## References

- `specs/issue-288-cloud-model-sources/2026-09-14-multi-instance-backend-design.md` — design spec
- `specs/issue-288-cloud-model-sources/290-decisions.md` — D1-D7 design decisions
- `agent-api/src/main/java/io/casehub/platform/agent/AgentBackend.java` — current SPI
- `agent-router/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java` — current router
- `platform-api/src/main/java/io/casehub/platform/api/model/ModelDescriptor.java` — current record
- `platform-api/src/main/java/io/casehub/platform/api/credentials/LlmCredentialStore.java` — credential SPI
- `agent-openai/src/main/java/io/casehub/platform/agent/openai/OpenAiAgentBackend.java` — OpenAI backend
- `../../../../agent-openai-core/src/main/java/io/casehub/platform/agent/openai/AbstractOpenAiSdkBackend.java` — shared base class
- GE-20260810-804c58 — CaseHub AgentProvider CDI tiering
- GE-20260626-c21b02 — @DefaultBean suppressed by Instance<T> peer
- GitHub #290 — multi-instance backend support
- GitHub #285 — parent epic: LLM model registry
