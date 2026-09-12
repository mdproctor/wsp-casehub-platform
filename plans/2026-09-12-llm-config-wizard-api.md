# LLM Configuration Wizard API — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #291 — feat: LLM configuration wizard API — headless REST/GraphQL
**Issue group:** #291

**Goal:** Headless REST/GraphQL/MCP API for guided LLM provider configuration — admin configures vendors, wizard validates credentials against live vendor APIs, auto-registers models in ModelRegistry.

**Architecture:** New `llm-config/` module with `@McpDomain` SPI interface → auto-generated REST + GraphQL + MCP. Platform-api gains `MutableModelRegistry` extension, `LlmCredentialStore` SPI, and `ModelDescriptor.apiModelId` field. Vendor clients (Anthropic, OpenAI, Google, Ollama) validate credentials and discover models. `ConfiguredModelSourceManager` handles source lifecycle with own `@Scheduled` refresh.

**Tech Stack:** Java 21, Quarkus CDI, JAX-RS (generated), SmallRye GraphQL (generated), java.net.http.HttpClient, Jackson YAML/JSON

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA, no casehubio imports. Pure Java only.
- `platform/` contains Quarkus @DefaultBean implementations only — no domain logic.
- Every SPI in platform-api gets a @DefaultBean implementation in platform.
- No quarkus:build goal on `llm-config/`.
- Tenant-scope only (user-scope deferred per R2-01/R2-02).
- `TenancyConstants.PLATFORM_TENANT_ID` for cross-tenant indexes — no new sentinel constants.
- `PlatformRoles.ADMIN` = `"platform-admin"` for `@RolesAllowed`.

---

## Batch 1: Platform SPI Foundation

After this batch: all existing code still works, new SPIs available for llm-config. ModelDescriptor has `apiModelId`, `MutableModelRegistry` extends `ModelRegistry`, `LlmCredentialStore` SPI exists with @DefaultBean no-op.

### Task 1: ModelDescriptor.apiModelId + MutableModelRegistry + routing fix

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/model/ModelDescriptor.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/model/MutableModelRegistry.java`
- Modify: `platform/src/main/java/io/casehub/platform/model/InMemoryModelRegistry.java`
- Modify: `platform/src/main/java/io/casehub/platform/model/SeedCatalogModelSource.java`
- Modify: `agent-router/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/model/ModelDescriptorTest.java`
- Modify: `platform/src/test/java/io/casehub/platform/model/InMemoryModelRegistryTest.java`
- Modify: `platform/src/test/java/io/casehub/platform/model/SeedCatalogModelSourceTest.java`
- Modify: `agent-router/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderTest.java`

**Interfaces:**
- Produces: `ModelDescriptor(String id, String apiModelId, ...)` — new field after `id`
- Produces: `MutableModelRegistry extends ModelRegistry` with `CatalogDelta replaceSource(String sourceId, int priority, List<ModelDescriptor> models)`
- Produces: `InMemoryModelRegistry implements MutableModelRegistry`
- Produces: `RoutingAgentProvider.resolve()` uses `descriptor.apiModelId()` for config rewriting

- [ ] **Step 1: Write failing test — ModelDescriptor with apiModelId**

Add test in `ModelDescriptorTest.java`:

```java
@Test
void apiModelIdIsRequired() {
    assertThatThrownBy(() -> new ModelDescriptor(
        "tenant:id", null, "claude", "anthropic", "claude", "Test",
        ModelTier.STANDARD, Set.of(), 200000, 16384,
        ModelLocality.CLOUD, null, null, Map.of()))
    .isInstanceOf(NullPointerException.class)
    .hasMessageContaining("apiModelId");
}

@Test
void apiModelIdPreserved() {
    var desc = new ModelDescriptor(
        "anthropic:t1:claude-sonnet-5", "claude-sonnet-5",
        "claude", "anthropic", "claude", "Claude Sonnet 5",
        ModelTier.STANDARD, Set.of(), 200000, 16384,
        ModelLocality.CLOUD, CostTier.HIGH, "api-key", Map.of());
    assertThat(desc.apiModelId()).isEqualTo("claude-sonnet-5");
    assertThat(desc.id()).isEqualTo("anthropic:t1:claude-sonnet-5");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn test -pl platform-api -Dtest=ModelDescriptorTest -q`
Expected: compilation failure — `apiModelId` parameter doesn't exist

- [ ] **Step 3: Add apiModelId to ModelDescriptor**

Use `ide_replace_member` to update the record. Add `String apiModelId` as the second component:

```java
public record ModelDescriptor(
    String id,
    String apiModelId,
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
        Objects.requireNonNull(apiModelId, "apiModelId");
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

- [ ] **Step 4: Fix all existing ModelDescriptor construction sites**

Use `ide_find_references` on `ModelDescriptor` constructor to find all call sites. Each needs the new `apiModelId` parameter. For seed catalog and existing tests, `apiModelId` equals `id`:

- `SeedCatalogModelSource.parseModel()`: add `node.get("id").asText()` as second arg (apiModelId = id for seed models)
- `InMemoryModelRegistryTest`: update all `new ModelDescriptor(...)` calls — add the id value again as apiModelId
- `SeedCatalogModelSourceTest`: update construction calls
- `RoutingAgentProviderTest`: update construction calls
- `ModelDescriptorTest`: update all existing test constructions

- [ ] **Step 5: Run tests to verify apiModelId works**

Run: `mvn test -pl platform-api -Dtest=ModelDescriptorTest -q`
Expected: PASS

- [ ] **Step 6: Create MutableModelRegistry interface**

Use `ide_create_file` or Write:

```java
package io.casehub.platform.api.model;

import java.util.List;
import java.util.Set;

public interface MutableModelRegistry extends ModelRegistry {

    record CatalogDelta(Set<String> addedIds, Set<String> removedIds, Set<String> updatedIds) {
        public boolean hasChanges() {
            return !addedIds.isEmpty() || !removedIds.isEmpty() || !updatedIds.isEmpty();
        }
    }

    CatalogDelta replaceSource(String sourceId, int priority, List<ModelDescriptor> models);
}
```

- [ ] **Step 7: Update InMemoryModelRegistry to implement MutableModelRegistry**

Use `ide_edit_member` to change the class declaration and move `CatalogDelta` from the inner class to the SPI:

```java
@ApplicationScoped
public class InMemoryModelRegistry implements MutableModelRegistry {
    // Remove the inner CatalogDelta record — it's now on MutableModelRegistry
    // replaceSource() signature unchanged, return type now from SPI
```

- [ ] **Step 8: Update RoutingAgentProvider to use apiModelId**

Use `ide_replace_member` on `resolve()` — change line 103 from `descriptor.get().id()` to `descriptor.get().apiModelId()`:

```java
return new ResolvedRoute(backend, descriptor.get().apiModelId());
```

- [ ] **Step 9: Update RoutingAgentProvider test constructor calls**

Fix all `new ModelDescriptor(...)` calls in `RoutingAgentProviderTest` — add `apiModelId` parameter (same as `id` for test fixtures).

- [ ] **Step 10: Run full build for affected modules**

Run: `mvn test -pl platform-api,platform,agent-router -q`
Expected: all tests PASS

- [ ] **Step 11: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src agent-router/src platform/src
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#291): add ModelDescriptor.apiModelId + MutableModelRegistry SPI + routing fix

ModelDescriptor gains apiModelId field separating registry key from vendor
API identifier. MutableModelRegistry extends ModelRegistry with
replaceSource(). RoutingAgentProvider uses apiModelId for config rewriting.

Refs #291"
```

---

### Task 2: LlmCredentialStore SPI + @DefaultBean no-op

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/credentials/LlmCredentialStore.java`
- Create: `platform/src/main/java/io/casehub/platform/credentials/NoOpLlmCredentialStore.java`
- Test: `platform/src/test/java/io/casehub/platform/credentials/NoOpLlmCredentialStoreTest.java`

**Interfaces:**
- Produces: `LlmCredentialStore { store(tenancyId, credRef, creds), resolve(tenancyId, credRef), delete(tenancyId, credRef), listRefs(tenancyId) }`
- Produces: `NoOpLlmCredentialStore @DefaultBean` — empty map returns, no-op store/delete

- [ ] **Step 1: Write failing test for NoOpLlmCredentialStore**

```java
package io.casehub.platform.credentials;

import io.casehub.platform.api.credentials.LlmCredentialStore;
import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class NoOpLlmCredentialStoreTest {

    private final LlmCredentialStore store = new NoOpLlmCredentialStore();

    @Test
    void resolveReturnsEmptyMap() {
        assertThat(store.resolve("tenant-1", "ref-1")).isEmpty();
    }

    @Test
    void storeIsNoOp() {
        store.store("tenant-1", "ref-1", Map.of("api-key", "secret"));
        assertThat(store.resolve("tenant-1", "ref-1")).isEmpty();
    }

    @Test
    void deleteIsNoOp() {
        store.delete("tenant-1", "ref-1");
    }

    @Test
    void listRefsReturnsEmptyList() {
        assertThat(store.listRefs("tenant-1")).isEmpty();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn test -pl platform -Dtest=NoOpLlmCredentialStoreTest -q`
Expected: compilation failure — `LlmCredentialStore` doesn't exist

- [ ] **Step 3: Create LlmCredentialStore SPI in platform-api**

```java
package io.casehub.platform.api.credentials;

import java.util.List;
import java.util.Map;

public interface LlmCredentialStore {
    void store(String tenancyId, String credentialRef, Map<String, String> credentials);
    Map<String, String> resolve(String tenancyId, String credentialRef);
    void delete(String tenancyId, String credentialRef);
    List<String> listRefs(String tenancyId);
}
```

- [ ] **Step 4: Create NoOpLlmCredentialStore @DefaultBean in platform**

```java
package io.casehub.platform.credentials;

import io.casehub.platform.api.credentials.LlmCredentialStore;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;
import java.util.List;
import java.util.Map;

@DefaultBean
@ApplicationScoped
public class NoOpLlmCredentialStore implements LlmCredentialStore {

    @Override
    public void store(String tenancyId, String credentialRef, Map<String, String> credentials) {}

    @Override
    public Map<String, String> resolve(String tenancyId, String credentialRef) {
        return Map.of();
    }

    @Override
    public void delete(String tenancyId, String credentialRef) {}

    @Override
    public List<String> listRefs(String tenancyId) {
        return List.of();
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mvn test -pl platform-api,platform -Dtest=NoOpLlmCredentialStoreTest -q`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src platform/src
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#291): add LlmCredentialStore SPI + NoOp @DefaultBean

Tenant-explicit credential storage for LLM API keys. Separate from
CredentialResolver (which handles outbound endpoint credentials).
NoOpLlmCredentialStore in platform/ follows @DefaultBean pattern.

Refs #291"
```

---

## Batch 2: llm-config Module Core

After this batch: new module exists with DTOs, SPI interfaces, credential store, and model source management. ConfiguredModelSourceManager handles lifecycle with @Startup reconstruction and @Scheduled refresh. No vendor clients yet — those come in Batch 3.

### Task 3: Module scaffold + DTOs + SPI interfaces

**Files:**
- Create: `llm-config/pom.xml`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigApi.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/VendorClient.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/VendorInfo.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/ValidateRequest.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/ValidationResult.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/ConfigureRequest.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/ConfigureResult.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/ProviderConfig.java`
- Modify: `pom.xml` (root) — add `llm-config` module

**Interfaces:**
- Produces: `LlmConfigApi` — `@McpDomain("llm-config")` with `@PlatformQuery`/`@PlatformMutation` methods
- Produces: `VendorClient` — `vendorKey()`, `backendKey()`, `displayName()`, `authMethod()`, `requiredFields()`, `listModels(Map<String,String> credentials)`
- Produces: All DTO records (VendorInfo, ValidateRequest, ValidationResult, ConfigureRequest, ConfigureResult, ProviderConfig)

- [ ] **Step 1: Create llm-config/pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-llm-config</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform LLM Config</name>
    <description>Headless LLM provider configuration wizard — REST/GraphQL/MCP from @McpDomain SPI</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>com.fasterxml.jackson.core</groupId>
            <artifactId>jackson-databind</artifactId>
        </dependency>

        <!-- Test -->
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>io.smallrye</groupId>
                <artifactId>jandex-maven-plugin</artifactId>
                <version>${jandex-maven-plugin.version}</version>
                <executions>
                    <execution>
                        <id>make-index</id>
                        <goals><goal>jandex</goal></goals>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Add llm-config to root pom.xml modules**

Use `ide_replace_text_in_file` to add `<module>llm-config</module>` after the last existing module in the `<modules>` section.

- [ ] **Step 3: Create all DTO records**

Create each record in `llm-config/src/main/java/io/casehub/platform/llm/config/`:

`VendorInfo.java`:
```java
package io.casehub.platform.llm.config;
import java.util.List;
public record VendorInfo(String vendorKey, String backendKey, String displayName,
                         String authMethod, List<String> requiredFields) {}
```

`ValidateRequest.java`:
```java
package io.casehub.platform.llm.config;
import java.util.Map;
public record ValidateRequest(String vendorKey, Map<String, String> credentials) {}
```

`ValidationResult.java`:
```java
package io.casehub.platform.llm.config;
import io.casehub.platform.api.model.ModelDescriptor;
import java.util.List;
public record ValidationResult(boolean valid, String errorMessage, List<ModelDescriptor> models) {}
```

`ConfigureRequest.java`:
```java
package io.casehub.platform.llm.config;
import java.util.Map;
public record ConfigureRequest(String vendorKey, Map<String, String> credentials, String displayName) {}
```

`ConfigureResult.java`:
```java
package io.casehub.platform.llm.config;
import java.util.List;
public record ConfigureResult(String providerId, int modelsRegistered, List<String> modelIds) {}
```

`ProviderConfig.java`:
```java
package io.casehub.platform.llm.config;
import java.time.Instant;
public record ProviderConfig(String providerId, String vendorKey, String backendKey,
                             String displayName, int modelCount, Instant configuredAt) {}
```

- [ ] **Step 4: Create VendorClient SPI**

```java
package io.casehub.platform.llm.config;
import java.util.List;
import java.util.Map;

public interface VendorClient {
    String vendorKey();
    String backendKey();
    String displayName();
    String authMethod();
    List<String> requiredFields();
    ValidationResult listModels(Map<String, String> credentials);
}
```

- [ ] **Step 5: Create LlmConfigApi @McpDomain interface**

```java
package io.casehub.platform.llm.config;

import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import java.util.List;

@McpDomain("llm-config")
public interface LlmConfigApi {

    @PlatformQuery("List available LLM vendors with their auth requirements")
    List<VendorInfo> vendors();

    @PlatformQuery("List currently configured providers for the caller's tenant")
    List<ProviderConfig> configured();

    @PlatformMutation("Validate credentials against a vendor's live API — returns discovered models on success")
    ValidationResult validate(ValidateRequest request);

    @PlatformMutation("Validate, persist, and register a provider configuration as a ModelSource")
    ConfigureResult configure(ConfigureRequest request);

    @PlatformMutation("Remove a provider configuration and deregister its ModelSource")
    void unconfigure(String providerId);
}
```

- [ ] **Step 6: Verify module compiles**

Run: `mvn compile -pl llm-config -q`
Expected: PASS (no tests yet, just compilation)

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add llm-config/ pom.xml
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#291): scaffold llm-config module + DTOs + SPI interfaces

New module with @McpDomain LlmConfigApi, VendorClient SPI, and all
DTO records (VendorInfo, ValidateRequest, ValidationResult,
ConfigureRequest, ConfigureResult, ProviderConfig).

Refs #291"
```

---

### Task 4: InMemoryLlmCredentialStore + ConfiguredModelSource + ConfiguredModelSourceManager

**Files:**
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/InMemoryLlmCredentialStore.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/ConfiguredModelSource.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/ConfiguredModelSourceManager.java`
- Test: `llm-config/src/test/java/io/casehub/platform/llm/config/InMemoryLlmCredentialStoreTest.java`
- Test: `llm-config/src/test/java/io/casehub/platform/llm/config/ConfiguredModelSourceManagerTest.java`

**Interfaces:**
- Consumes: `LlmCredentialStore` (from platform-api, Task 2)
- Consumes: `MutableModelRegistry.replaceSource()` (from Task 1)
- Consumes: `VendorClient.listModels()` (from Task 3)
- Consumes: `PreferenceStore` (from platform-api, existing)
- Consumes: `TenancyConstants.PLATFORM_TENANT_ID` (from platform-api, existing)
- Produces: `InMemoryLlmCredentialStore` — `@ApplicationScoped`, `ConcurrentHashMap`, tenant-isolated
- Produces: `ConfiguredModelSource` — `implements ModelSource`, tenant-scoped IDs, last-known-good on failure
- Produces: `ConfiguredModelSourceManager` — `configure(tenancyId, vendorKey, credRef, models)`, `unconfigure(tenancyId, vendorKey)`, `refreshAll()`, `reconstructFromPreferences()`

- [ ] **Step 1: Write failing test for InMemoryLlmCredentialStore**

```java
package io.casehub.platform.llm.config;

import io.casehub.platform.api.credentials.LlmCredentialStore;
import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class InMemoryLlmCredentialStoreTest {

    private final LlmCredentialStore store = new InMemoryLlmCredentialStore();

    @Test
    void storeAndResolve() {
        store.store("t1", "ref-1", Map.of("api-key", "sk-123"));
        assertThat(store.resolve("t1", "ref-1")).containsEntry("api-key", "sk-123");
    }

    @Test
    void resolveUnknownReturnsEmpty() {
        assertThat(store.resolve("t1", "unknown")).isEmpty();
    }

    @Test
    void tenantIsolation() {
        store.store("t1", "ref-1", Map.of("api-key", "t1-key"));
        store.store("t2", "ref-1", Map.of("api-key", "t2-key"));
        assertThat(store.resolve("t1", "ref-1")).containsEntry("api-key", "t1-key");
        assertThat(store.resolve("t2", "ref-1")).containsEntry("api-key", "t2-key");
    }

    @Test
    void deleteRemovesCredentials() {
        store.store("t1", "ref-1", Map.of("api-key", "sk-123"));
        store.delete("t1", "ref-1");
        assertThat(store.resolve("t1", "ref-1")).isEmpty();
    }

    @Test
    void listRefsReturnsStoredRefs() {
        store.store("t1", "ref-a", Map.of("api-key", "a"));
        store.store("t1", "ref-b", Map.of("api-key", "b"));
        store.store("t2", "ref-c", Map.of("api-key", "c"));
        assertThat(store.listRefs("t1")).containsExactlyInAnyOrder("ref-a", "ref-b");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn test -pl llm-config -Dtest=InMemoryLlmCredentialStoreTest -q`
Expected: compilation failure

- [ ] **Step 3: Implement InMemoryLlmCredentialStore**

```java
package io.casehub.platform.llm.config;

import io.casehub.platform.api.credentials.LlmCredentialStore;
import jakarta.enterprise.context.ApplicationScoped;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

@ApplicationScoped
public class InMemoryLlmCredentialStore implements LlmCredentialStore {

    private final ConcurrentHashMap<String, Map<String, String>> store = new ConcurrentHashMap<>();

    @Override
    public void store(String tenancyId, String credentialRef, Map<String, String> credentials) {
        store.put(key(tenancyId, credentialRef), Map.copyOf(credentials));
    }

    @Override
    public Map<String, String> resolve(String tenancyId, String credentialRef) {
        return store.getOrDefault(key(tenancyId, credentialRef), Map.of());
    }

    @Override
    public void delete(String tenancyId, String credentialRef) {
        store.remove(key(tenancyId, credentialRef));
    }

    @Override
    public List<String> listRefs(String tenancyId) {
        String prefix = tenancyId + ":";
        return store.keySet().stream()
            .filter(k -> k.startsWith(prefix))
            .map(k -> k.substring(prefix.length()))
            .toList();
    }

    private static String key(String tenancyId, String credentialRef) {
        return tenancyId + ":" + credentialRef;
    }
}
```

- [ ] **Step 4: Run credential store tests**

Run: `mvn test -pl llm-config -Dtest=InMemoryLlmCredentialStoreTest -q`
Expected: PASS

- [ ] **Step 5: Write failing test for ConfiguredModelSourceManager**

```java
package io.casehub.platform.llm.config;

import io.casehub.platform.api.credentials.LlmCredentialStore;
import io.casehub.platform.api.model.*;
import io.casehub.platform.model.InMemoryModelRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.assertj.core.api.Assertions.assertThat;

class ConfiguredModelSourceManagerTest {

    private InMemoryModelRegistry registry;
    private InMemoryLlmCredentialStore credentialStore;
    private ConfiguredModelSourceManager manager;

    @BeforeEach
    void setUp() {
        registry = new InMemoryModelRegistry();
        credentialStore = new InMemoryLlmCredentialStore();
        manager = new ConfiguredModelSourceManager(registry, credentialStore);
    }

    @Test
    void configureRegistersModelsInRegistry() {
        List<ModelDescriptor> models = List.of(testDescriptor("claude-sonnet-5"));

        manager.configure("tenant-1", "anthropic", "anthropic-tenant-1", models);

        assertThat(registry.resolveById("anthropic:tenant-1:claude-sonnet-5")).isPresent();
        var resolved = registry.resolveById("anthropic:tenant-1:claude-sonnet-5").get();
        assertThat(resolved.apiModelId()).isEqualTo("claude-sonnet-5");
    }

    @Test
    void unconfigureRemovesModelsFromRegistry() {
        List<ModelDescriptor> models = List.of(testDescriptor("claude-sonnet-5"));
        manager.configure("tenant-1", "anthropic", "anthropic-tenant-1", models);

        manager.unconfigure("tenant-1", "anthropic");

        assertThat(registry.resolveById("anthropic:tenant-1:claude-sonnet-5")).isEmpty();
    }

    @Test
    void tenantIsolationInRegistry() {
        manager.configure("t1", "anthropic", "ref-t1", List.of(testDescriptor("claude-sonnet-5")));
        manager.configure("t2", "anthropic", "ref-t2", List.of(testDescriptor("claude-sonnet-5")));

        assertThat(registry.resolveById("anthropic:t1:claude-sonnet-5")).isPresent();
        assertThat(registry.resolveById("anthropic:t2:claude-sonnet-5")).isPresent();
        assertThat(registry.resolveById("anthropic:t1:claude-sonnet-5").get().id())
            .isNotEqualTo(registry.resolveById("anthropic:t2:claude-sonnet-5").get().id());
    }

    private ModelDescriptor testDescriptor(String id) {
        return new ModelDescriptor(id, id, "claude", "anthropic", "claude",
            "Test Model", ModelTier.STANDARD, Set.of("text"), 200000, 16384,
            ModelLocality.CLOUD, CostTier.HIGH, "api-key", Map.of());
    }
}
```

- [ ] **Step 6: Implement ConfiguredModelSource**

```java
package io.casehub.platform.llm.config;

import io.casehub.platform.api.credentials.LlmCredentialStore;
import io.casehub.platform.api.model.ModelDescriptor;
import io.casehub.platform.api.model.ModelSource;
import org.jboss.logging.Logger;
import java.util.List;
import java.util.Map;

class ConfiguredModelSource implements ModelSource {

    private static final Logger LOG = Logger.getLogger(ConfiguredModelSource.class);

    private final String sourceId;
    private final String tenancyId;
    private final String vendorKey;
    private final String credentialRef;
    private final VendorClient client;
    private final LlmCredentialStore credentialStore;
    private volatile List<ModelDescriptor> lastKnownModels;

    ConfiguredModelSource(String tenancyId, String vendorKey, String credentialRef,
                          VendorClient client, LlmCredentialStore credentialStore) {
        this.sourceId = "configured:" + vendorKey + ":" + tenancyId;
        this.tenancyId = tenancyId;
        this.vendorKey = vendorKey;
        this.credentialRef = credentialRef;
        this.client = client;
        this.credentialStore = credentialStore;
    }

    @Override public String sourceId() { return sourceId; }
    @Override public int priority() { return 10; }

    @Override
    public List<ModelDescriptor> refresh() {
        Map<String, String> creds = credentialStore.resolve(tenancyId, credentialRef);
        if (creds.isEmpty()) {
            LOG.warnf("Credentials missing for %s — returning last known models", sourceId);
            return lastKnownModels != null ? lastKnownModels : List.of();
        }
        var result = client.listModels(creds);
        if (result.valid()) {
            lastKnownModels = toTenantScoped(result.models());
            return lastKnownModels;
        }
        return lastKnownModels != null ? lastKnownModels : List.of();
    }

    List<ModelDescriptor> toTenantScoped(List<ModelDescriptor> vendorModels) {
        return vendorModels.stream()
            .map(d -> new ModelDescriptor(
                vendorKey + ":" + tenancyId + ":" + d.apiModelId(),
                d.apiModelId(),
                d.backendKey(), d.vendor(), d.family(), d.displayName(),
                d.tier(), d.capabilities(), d.contextWindow(), d.maxOutput(),
                d.locality(), d.costTier(), d.authMethod(), d.properties()))
            .toList();
    }

    String tenancyId() { return tenancyId; }
    String vendorKey() { return vendorKey; }
    String credentialRef() { return credentialRef; }
}
```

- [ ] **Step 7: Implement ConfiguredModelSourceManager**

```java
package io.casehub.platform.llm.config;

import io.casehub.platform.api.credentials.LlmCredentialStore;
import io.casehub.platform.api.model.MutableModelRegistry;
import io.casehub.platform.api.model.ModelDescriptor;
import org.jboss.logging.Logger;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;

public class ConfiguredModelSourceManager {

    private static final Logger LOG = Logger.getLogger(ConfiguredModelSourceManager.class);

    private final MutableModelRegistry registry;
    private final LlmCredentialStore credentialStore;
    private final ConcurrentHashMap<String, ConfiguredModelSource> activeSources = new ConcurrentHashMap<>();

    public ConfiguredModelSourceManager(MutableModelRegistry registry, LlmCredentialStore credentialStore) {
        this.registry = registry;
        this.credentialStore = credentialStore;
    }

    public void configure(String tenancyId, String vendorKey, String credentialRef,
                          List<ModelDescriptor> validatedModels) {
        String sourceKey = vendorKey + ":" + tenancyId;
        var source = new ConfiguredModelSource(tenancyId, vendorKey, credentialRef, null, credentialStore);
        List<ModelDescriptor> tenantScoped = source.toTenantScoped(validatedModels);
        activeSources.put(sourceKey, source);
        registry.replaceSource(source.sourceId(), source.priority(), tenantScoped);
    }

    public void unconfigure(String tenancyId, String vendorKey) {
        String sourceKey = vendorKey + ":" + tenancyId;
        ConfiguredModelSource removed = activeSources.remove(sourceKey);
        if (removed != null) {
            registry.replaceSource(removed.sourceId(), removed.priority(), List.of());
        }
    }

    public boolean isConfigured(String tenancyId, String vendorKey) {
        return activeSources.containsKey(vendorKey + ":" + tenancyId);
    }

    public void refreshAll() {
        for (var entry : activeSources.entrySet()) {
            try {
                ConfiguredModelSource source = entry.getValue();
                List<ModelDescriptor> models = source.refresh();
                if (!activeSources.containsKey(entry.getKey())) {
                    continue;
                }
                registry.replaceSource(source.sourceId(), source.priority(), models);
            } catch (Exception e) {
                LOG.warnf("Configured source '%s' refresh failed: %s", entry.getKey(), e.getMessage());
            }
        }
    }
}
```

- [ ] **Step 8: Run all tests**

Run: `mvn test -pl llm-config -q`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add llm-config/src
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#291): add InMemoryLlmCredentialStore + ConfiguredModelSource + manager

Tenant-isolated in-memory credential store. ConfiguredModelSource
produces tenant-scoped model IDs. Manager handles configure/unconfigure
lifecycle with race-condition-safe refresh.

Refs #291"
```

---

## Batch 3: Vendor Clients + Service Wiring

After this batch: full wizard functional — vendors(), validate(), configure(), configured(), unconfigure() all work end-to-end. Generated REST + GraphQL + MCP endpoints available.

### Task 5: Vendor client implementations

**Files:**
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/AnthropicClient.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/OpenAiClient.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/GoogleClient.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/OllamaClient.java`
- Test: `llm-config/src/test/java/io/casehub/platform/llm/config/AnthropicClientTest.java`
- Test: `llm-config/src/test/java/io/casehub/platform/llm/config/OpenAiClientTest.java`

**Interfaces:**
- Consumes: `VendorClient` SPI (from Task 3)
- Consumes: `ModelDescriptor` with `apiModelId` (from Task 1)
- Consumes: `ModelRegistry.query()` for seed catalog metadata merge
- Produces: `AnthropicClient`, `OpenAiClient`, `GoogleClient`, `OllamaClient` — each implementing `VendorClient`

- [ ] **Step 1: Write failing test for AnthropicClient**

Test with a mock HTTP response matching Anthropic's `/v1/models` format:

```java
package io.casehub.platform.llm.config;

import io.casehub.platform.api.model.*;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import java.util.Set;
import static org.assertj.core.api.Assertions.assertThat;

class AnthropicClientTest {

    @Test
    void vendorMetadata() {
        var client = new AnthropicClient(ModelRegistry::all);
        assertThat(client.vendorKey()).isEqualTo("anthropic");
        assertThat(client.backendKey()).isEqualTo("claude");
        assertThat(client.authMethod()).isEqualTo("api-key");
        assertThat(client.requiredFields()).containsExactly("api-key");
    }

    @Test
    void parsesAnthropicModelsResponse() {
        String json = """
            {"data": [
                {"id": "claude-sonnet-5", "type": "model", "display_name": "Claude Sonnet 5", "created_at": "2025-01-01T00:00:00Z"},
                {"id": "claude-haiku-4-5", "type": "model", "display_name": "Claude Haiku 4.5", "created_at": "2025-01-01T00:00:00Z"}
            ]}
            """;

        // Provide seed catalog for metadata merge
        var seedSonnet = new ModelDescriptor("claude-sonnet-5", "claude-sonnet-5",
            "claude", "anthropic", "claude", "Claude Sonnet 5",
            ModelTier.STANDARD, Set.of("text", "vision", "tool-use", "code", "reasoning"),
            200000, 16384, ModelLocality.CLOUD, CostTier.HIGH, "api-key", Map.of());

        var client = new AnthropicClient(query -> List.of(seedSonnet));
        List<ModelDescriptor> models = client.parseModelsResponse(json);

        assertThat(models).hasSize(2);
        var sonnet = models.stream().filter(m -> m.apiModelId().equals("claude-sonnet-5")).findFirst().orElseThrow();
        assertThat(sonnet.tier()).isEqualTo(ModelTier.STANDARD);
        assertThat(sonnet.capabilities()).contains("vision", "tool-use");
        assertThat(sonnet.contextWindow()).isEqualTo(200000);
    }

    @Test
    void invalidKeyReturnsFailure() {
        var client = new AnthropicClient(query -> List.of());
        var result = client.listModels(Map.of("api-key", "invalid"));
        assertThat(result.valid()).isFalse();
        assertThat(result.errorMessage()).isNotBlank();
    }
}
```

- [ ] **Step 2: Implement AnthropicClient**

HTTP client calls `GET https://api.anthropic.com/v1/models` with `x-api-key` header. Parses response, merges with seed catalog metadata. Similar structure for each vendor — implement AnthropicClient fully, then follow the pattern for OpenAi, Google, Ollama.

Key implementation detail: inject a `java.util.function.Function<ModelQuery, List<ModelDescriptor>>` (or `ModelRegistry` directly) to look up seed catalog entries for metadata merge. Package-private `parseModelsResponse(String json)` method for testability without HTTP calls.

- [ ] **Step 3: Implement OpenAiClient, GoogleClient, OllamaClient**

Each follows the AnthropicClient pattern with vendor-specific:
- HTTP endpoint URL
- Auth header format
- JSON response structure
- backendKey mapping

- [ ] **Step 4: Write tests for OpenAiClient**

Similar to AnthropicClient tests — verify vendor metadata, JSON parsing with seed catalog merge, invalid key handling.

- [ ] **Step 5: Run all vendor client tests**

Run: `mvn test -pl llm-config -Dtest="*ClientTest" -q`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add llm-config/src
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#291): add vendor client implementations — Anthropic, OpenAI, Google, Ollama

Each VendorClient validates credentials via live API, parses vendor
response, merges with seed catalog metadata for full ModelDescriptor
construction. Shared parsing pattern with #288 cloud model sources.

Refs #291"
```

---

### Task 6: LlmConfigService + integration tests

**Files:**
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigService.java`
- Test: `llm-config/src/test/java/io/casehub/platform/llm/config/LlmConfigServiceTest.java`

**Interfaces:**
- Consumes: `LlmConfigApi` (from Task 3)
- Consumes: `ConfiguredModelSourceManager` (from Task 4)
- Consumes: `VendorClient` (from Task 5)
- Consumes: `LlmCredentialStore` (from Task 2/4)
- Consumes: `PreferenceStore` (from platform-api, existing)
- Consumes: `CurrentPrincipal` (from platform-api, existing)
- Consumes: `TenancyConstants.PLATFORM_TENANT_ID` (from platform-api, existing)
- Produces: `LlmConfigService @ApplicationScoped implements LlmConfigApi` — full wizard orchestration

- [ ] **Step 1: Write failing test for LlmConfigService.vendors()**

```java
package io.casehub.platform.llm.config;

import org.junit.jupiter.api.Test;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;

class LlmConfigServiceTest {

    @Test
    void vendorsDerivedFromDiscoveredClients() {
        // Setup with a stub VendorClient
        var stubClient = new StubVendorClient("test-vendor", "test-backend", "Test Vendor");
        var service = createService(List.of(stubClient));

        List<VendorInfo> vendors = service.vendors();

        assertThat(vendors).hasSize(1);
        assertThat(vendors.get(0).vendorKey()).isEqualTo("test-vendor");
        assertThat(vendors.get(0).backendKey()).isEqualTo("test-backend");
    }
}
```

- [ ] **Step 2: Implement LlmConfigService**

```java
@ApplicationScoped
public class LlmConfigService implements LlmConfigApi {

    @Inject CurrentPrincipal principal;
    @Inject ConfiguredModelSourceManager sourceManager;
    @Inject LlmCredentialStore credentialStore;
    @Inject PreferenceStore preferenceStore;
    @Inject @Any Instance<VendorClient> vendorClients;

    @Override
    public List<VendorInfo> vendors() {
        // Derive from CDI-discovered VendorClient beans
    }

    @RolesAllowed(PlatformRoles.ADMIN)
    @Override
    public ConfigureResult configure(ConfigureRequest request) {
        String tenancyId = principal.tenancyId();
        // 1. Find VendorClient for vendorKey
        // 2. Re-validate credentials (listModels)
        // 3. Store credentials in LlmCredentialStore
        // 4. Store config metadata in PreferenceStore
        // 5. Register with ConfiguredModelSourceManager
        // 6. Write provider-index entry for startup reconstruction
        // 7. Return ConfigureResult
    }

    // ... remaining methods
}
```

- [ ] **Step 3: Write integration test — full configure → query → unconfigure flow**

```java
@Test
void fullLifecycle_configure_query_unconfigure() {
    var service = createServiceWithStubVendor();

    // Configure
    var result = service.configure(new ConfigureRequest("test-vendor",
        Map.of("api-key", "valid-key"), null));
    assertThat(result.modelsRegistered()).isGreaterThan(0);

    // Query — configured() returns the provider
    List<ProviderConfig> configs = service.configured();
    assertThat(configs).hasSize(1);
    assertThat(configs.get(0).vendorKey()).isEqualTo("test-vendor");

    // Models queryable in registry
    for (String modelId : result.modelIds()) {
        assertThat(registry.resolveById(modelId)).isPresent();
    }

    // Unconfigure
    service.unconfigure(result.providerId());
    assertThat(service.configured()).isEmpty();
    for (String modelId : result.modelIds()) {
        assertThat(registry.resolveById(modelId)).isEmpty();
    }
}
```

- [ ] **Step 4: Write test for admin authorization**

Verify that `configure()` and `unconfigure()` require admin role, while `vendors()` and `configured()` do not.

- [ ] **Step 5: Run all tests**

Run: `mvn test -pl llm-config -q`
Expected: all PASS

- [ ] **Step 6: Run full project build**

Run: `mvn install -q`
Expected: PASS — all modules compile and tests pass

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add llm-config/src
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#291): add LlmConfigService — full wizard orchestration

vendors(), validate(), configure(), configured(), unconfigure() all
wired. Admin authorization via @RolesAllowed(PlatformRoles.ADMIN).
Tenant isolation via CurrentPrincipal. Provider index for startup
reconstruction via PLATFORM_TENANT_ID.

Closes #291"
```

---

## References

- [2026-09-12-llm-config-wizard-api-design.md] — design spec this plan implements
- [platform-api/src/main/java/io/casehub/platform/api/model/ModelDescriptor.java] — record to extend with apiModelId
- [platform-api/src/main/java/io/casehub/platform/api/model/ModelRegistry.java] — base SPI for MutableModelRegistry
- [platform/src/main/java/io/casehub/platform/model/InMemoryModelRegistry.java] — implementation to update
- [platform/src/main/java/io/casehub/platform/model/SeedCatalogModelSource.java] — update for apiModelId
- [agent-router/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java:103] — resolve() apiModelId fix
- [platform-api/src/main/java/io/casehub/platform/api/credentials/CredentialResolver.java] — reference (unchanged)
- [platform-api/src/main/java/io/casehub/platform/api/credentials/CredentialPropertyKeys.java] — API_KEY constant
- [platform/src/main/java/io/casehub/platform/credentials/DefaultCredentialResolver.java] — reference (unchanged)
- [decisions.md] — 10 design decisions captured during brainstorming
- [tracker.md] — standard review findings and resolutions
- GitHub #285 — parent epic
- GitHub #286 — ModelRegistry SPI (dependency, landed)
- GitHub #291 — focal issue
- GitHub #295 — unified API generation epic
