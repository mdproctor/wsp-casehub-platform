# Cloud Model Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #288 — cloud model sources
**Issue group:** #288, #289, #290, #292

**Goal:** Platform-global ModelSource beans that auto-discover LLM models from vendor APIs, bootstrapping credentials from the environment and guiding users toward configuring missing providers.

**Architecture:** Four CloudModelSource beans (Anthropic, OpenAI, Vertex, Bedrock) wrap existing/new VendorClients. A credential bootstrap bean seeds LlmCredentialStore from env vars/SDK credential chains at startup. ModelRegistryRefresher sorts sources by priority to ensure seed enrichment works. Vertex and Bedrock VendorClients live in separate modules for clean classpath isolation.

**Tech Stack:** Java 21, Quarkus CDI, java.net.http.HttpClient, Jackson, google-auth-library-oauth2-http, software.amazon.awssdk:auth

## Global Constraints

- `platform-api/` must remain zero-dependency — no new files there
- `llm-config/` depends on platform-api, jackson, java.net.http, CDI — no Quarkus runtime
- VendorClient implementations are `@ApplicationScoped` CDI beans
- Cloud source beans use plain `apiModelId` as registry key (same as seed catalog)
- Cloud source priority: 5 (between seed=0 and configured=10)
- No quarkus:build goal in any new module
- Credential refs use `cloud-{vendorKey}` format at `TenancyConstants.PLATFORM_TENANT_ID` scope
- Tests are plain JUnit 5 + AssertJ (no @QuarkusTest) — matching existing test pattern in llm-config/

---

## Batch 1: Foundation — interfaces, HttpClient fix, refresh ordering

### Task 1: CloudModelSource interface + CloudSourceStatus DTO + HttpClient reuse

**Files:**
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/CloudModelSource.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/CloudSourceStatus.java`
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/AnthropicClient.java`
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/OpenAiClient.java`
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/GoogleClient.java`
- Test: `llm-config/src/test/java/io/casehub/platform/llm/config/AnthropicClientTest.java` (existing — verify still passes)

**Interfaces:**
- Produces: `CloudModelSource extends ModelSource` with `CloudSourceStatus status()` — used by all cloud source beans (Task 3) and LlmConfigService (Task 5)
- Produces: `CloudSourceStatus(String sourceId, String vendor, State state, String message, int modelCount)` with `enum State { ACTIVE, INACTIVE, ERROR }` — used by bootstrap (Task 4) and status API (Task 5)

- [ ] **Step 1: Create CloudModelSource interface**

```java
package io.casehub.platform.llm.config;

import io.casehub.platform.api.model.ModelSource;

public interface CloudModelSource extends ModelSource {
    CloudSourceStatus status();
}
```

- [ ] **Step 2: Create CloudSourceStatus record**

```java
package io.casehub.platform.llm.config;

public record CloudSourceStatus(
    String sourceId,
    String vendor,
    State state,
    String message,
    int modelCount
) {
    public enum State { ACTIVE, INACTIVE, ERROR }

    public static CloudSourceStatus active(String sourceId, String vendor, int modelCount) {
        return new CloudSourceStatus(sourceId, vendor, State.ACTIVE,
            modelCount + " models discovered", modelCount);
    }

    public static CloudSourceStatus inactive(String sourceId, String vendor, String guidance) {
        return new CloudSourceStatus(sourceId, vendor, State.INACTIVE, guidance, 0);
    }

    public static CloudSourceStatus error(String sourceId, String vendor, String errorMessage) {
        return new CloudSourceStatus(sourceId, vendor, State.ERROR, errorMessage, 0);
    }
}
```

- [ ] **Step 3: Fix AnthropicClient — reusable HttpClient field**

Replace `var client = HttpClient.newHttpClient();` inside `listModels()` with a `private final HttpClient httpClient` field created at construction time:

```java
private final HttpClient httpClient = HttpClient.newHttpClient();
```

Then in `listModels()`, replace `var client = HttpClient.newHttpClient();` with `var response = httpClient.send(request, ...);`.

- [ ] **Step 4: Fix OpenAiClient and GoogleClient — same HttpClient reuse**

Apply the same pattern: add `private final HttpClient httpClient = HttpClient.newHttpClient();` field, replace per-call `HttpClient.newHttpClient()` with the field.

- [ ] **Step 5: Run existing tests to verify no regressions**

Run: `mvn --batch-mode test -pl llm-config -Dtest=AnthropicClientTest,OpenAiClientTest,GoogleClientTest`
Expected: All existing tests pass.

- [ ] **Step 6: Commit**

```bash
git add llm-config/src/main/java/io/casehub/platform/llm/config/CloudModelSource.java llm-config/src/main/java/io/casehub/platform/llm/config/CloudSourceStatus.java llm-config/src/main/java/io/casehub/platform/llm/config/AnthropicClient.java llm-config/src/main/java/io/casehub/platform/llm/config/OpenAiClient.java llm-config/src/main/java/io/casehub/platform/llm/config/GoogleClient.java
git commit -m "feat(#288): add CloudModelSource interface + CloudSourceStatus DTO, fix HttpClient reuse"
```

### Task 2: ModelRegistryRefresher — sort sources by priority ascending

**Files:**
- Modify: `platform/src/main/java/io/casehub/platform/model/ModelRegistryRefresher.java:35-48`
- Test: `platform/src/test/java/io/casehub/platform/model/ModelRegistryRefresherTest.java` (create or extend)

**Interfaces:**
- Consumes: `ModelSource.priority()` — existing SPI method
- Produces: Sources refreshed in priority-ascending order — ensures seed (0) populates before cloud (5) before configured (10)

- [ ] **Step 1: Write the failing test**

Create test that verifies refresh order:

```java
package io.casehub.platform.model;

import io.casehub.platform.api.model.ModelDescriptor;
import io.casehub.platform.api.model.ModelSource;
import jakarta.enterprise.inject.Instance;
import org.junit.jupiter.api.Test;
import java.util.ArrayList;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;

class ModelRegistryRefresherTest {

    @Test
    void refreshAll_sortsSourcesByPriorityAscending() {
        var refreshOrder = new ArrayList<String>();
        var high = stubSource("high", 10, refreshOrder);
        var low = stubSource("low", 0, refreshOrder);
        var mid = stubSource("mid", 5, refreshOrder);

        var registry = new InMemoryModelRegistry();
        var refresher = new ModelRegistryRefresher();
        refresher.sources = TestInstance.of(high, low, mid);
        refresher.registry = registry;
        refresher.catalogChanged = new NoOpEvent<>();

        refresher.refreshAll();

        assertThat(refreshOrder).containsExactly("low", "mid", "high");
    }

    private ModelSource stubSource(String id, int priority, List<String> order) {
        return new ModelSource() {
            @Override public String sourceId() { return id; }
            @Override public int priority() { return priority; }
            @Override public List<ModelDescriptor> refresh() {
                order.add(id);
                return List.of();
            }
        };
    }
}
```

Note: `TestInstance` is a test helper wrapping a list as `Instance<ModelSource>`. `NoOpEvent` is a test helper for `Event<>`. Create these as inner classes or package-private helpers.

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform -Dtest=ModelRegistryRefresherTest`
Expected: FAIL — sources iterated in CDI-determined order, not priority order.

- [ ] **Step 3: Implement priority sorting in refreshAll()**

Change `ModelRegistryRefresher.refreshAll()` to sort sources by priority ascending before iterating:

```java
void refreshAll() {
    var sortedSources = new java.util.ArrayList<ModelSource>();
    sources.forEach(sortedSources::add);
    sortedSources.sort(java.util.Comparator.comparingInt(ModelSource::priority));

    for (ModelSource source : sortedSources) {
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl platform -Dtest=ModelRegistryRefresherTest`
Expected: PASS

- [ ] **Step 5: Run full platform module tests**

Run: `mvn --batch-mode test -pl platform`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add platform/src/main/java/io/casehub/platform/model/ModelRegistryRefresher.java platform/src/test/java/io/casehub/platform/model/ModelRegistryRefresherTest.java
git commit -m "feat(#288): sort ModelSource refresh by priority ascending — seed enrichment ordering"
```

---

## Batch 2: Anthropic + OpenAI cloud sources

### Task 3: AnthropicCloudModelSource + OpenAiCloudModelSource

**Files:**
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/AnthropicCloudModelSource.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/OpenAiCloudModelSource.java`
- Test: `llm-config/src/test/java/io/casehub/platform/llm/config/AnthropicCloudModelSourceTest.java`
- Test: `llm-config/src/test/java/io/casehub/platform/llm/config/OpenAiCloudModelSourceTest.java`

**Interfaces:**
- Consumes: `CloudModelSource` interface (Task 1), `CloudSourceStatus` (Task 1), `VendorClient.listModels()`, `LlmCredentialStore.resolve()`, `TenancyConstants.PLATFORM_TENANT_ID`
- Produces: CDI-discovered `ModelSource` beans at priority 5, `status()` returning `CloudSourceStatus`

- [ ] **Step 1: Write the AnthropicCloudModelSource test**

```java
package io.casehub.platform.llm.config;

import io.casehub.platform.api.model.ModelDescriptor;
import io.casehub.platform.api.model.ModelLocality;
import io.casehub.platform.api.model.ModelTier;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import java.util.Set;
import static org.assertj.core.api.Assertions.assertThat;

class AnthropicCloudModelSourceTest {

    private static final ModelDescriptor SAMPLE_MODEL = new ModelDescriptor(
        "claude-sonnet-5", "claude-sonnet-5", "claude", "anthropic", "claude",
        "Claude Sonnet 5", ModelTier.FLAGSHIP, Set.of("text", "vision"),
        200000, 8192, ModelLocality.CLOUD, null, "api-key", Map.of());

    @Test
    void refresh_withCredentials_returnsModels() {
        var client = stubClient(ValidationResult.success(List.of(SAMPLE_MODEL)));
        var store = stubStore(Map.of("api-key", "sk-test"));
        var source = new AnthropicCloudModelSource(client, store);

        var result = source.refresh();

        assertThat(result).hasSize(1);
        assertThat(result.get(0).id()).isEqualTo("claude-sonnet-5");
    }

    @Test
    void refresh_withoutCredentials_returnsEmpty() {
        var client = stubClient(ValidationResult.success(List.of(SAMPLE_MODEL)));
        var store = stubStore(Map.of());
        var source = new AnthropicCloudModelSource(client, store);

        assertThat(source.refresh()).isEmpty();
    }

    @Test
    void refresh_afterFailure_returnsLastKnownGood() {
        var client = new ToggleClient(
            ValidationResult.success(List.of(SAMPLE_MODEL)),
            ValidationResult.failure("timeout"));
        var store = stubStore(Map.of("api-key", "sk-test"));
        var source = new AnthropicCloudModelSource(client, store);

        source.refresh(); // success — caches
        var result = source.refresh(); // failure — returns cache

        assertThat(result).hasSize(1);
    }

    @Test
    void refresh_credentialsAbsentWithCache_returnsCache() {
        var client = stubClient(ValidationResult.success(List.of(SAMPLE_MODEL)));
        var toggleStore = new ToggleStore(
            Map.of("api-key", "sk-test"), Map.of());
        var source = new AnthropicCloudModelSource(client, toggleStore);

        source.refresh(); // creds present — success
        var result = source.refresh(); // creds absent — returns cache

        assertThat(result).hasSize(1);
    }

    @Test
    void sourceId_returnsCloudAnthropicPrefix() {
        var source = new AnthropicCloudModelSource(
            stubClient(ValidationResult.success(List.of())),
            stubStore(Map.of()));
        assertThat(source.sourceId()).isEqualTo("cloud:anthropic");
    }

    @Test
    void priority_isFive() {
        var source = new AnthropicCloudModelSource(
            stubClient(ValidationResult.success(List.of())),
            stubStore(Map.of()));
        assertThat(source.priority()).isEqualTo(5);
    }

    @Test
    void status_active_showsModelCount() {
        var client = stubClient(ValidationResult.success(List.of(SAMPLE_MODEL)));
        var store = stubStore(Map.of("api-key", "sk-test"));
        var source = new AnthropicCloudModelSource(client, store);
        source.refresh();

        var status = source.status();
        assertThat(status.state()).isEqualTo(CloudSourceStatus.State.ACTIVE);
        assertThat(status.modelCount()).isEqualTo(1);
    }

    @Test
    void status_inactive_showsGuidance() {
        var source = new AnthropicCloudModelSource(
            stubClient(ValidationResult.success(List.of())),
            stubStore(Map.of()));

        var status = source.status();
        assertThat(status.state()).isEqualTo(CloudSourceStatus.State.INACTIVE);
        assertThat(status.message()).contains("ANTHROPIC_API_KEY");
    }

    // --- test helpers ---

    private VendorClient stubClient(ValidationResult result) {
        return new VendorClient() {
            @Override public String vendorKey() { return "anthropic"; }
            @Override public String backendKey() { return "claude"; }
            @Override public String displayName() { return "Anthropic"; }
            @Override public String authMethod() { return "api-key"; }
            @Override public List<String> requiredFields() { return List.of("api-key"); }
            @Override public ValidationResult listModels(Map<String, String> creds) { return result; }
        };
    }

    // ToggleClient, ToggleStore, stubStore — simple test doubles
    // (implementation omitted for brevity — same pattern as existing tests)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl llm-config -Dtest=AnthropicCloudModelSourceTest`
Expected: FAIL — class not found.

- [ ] **Step 3: Implement AnthropicCloudModelSource**

```java
package io.casehub.platform.llm.config;

import io.casehub.platform.api.credentials.LlmCredentialStore;
import io.casehub.platform.api.identity.TenancyConstants;
import io.casehub.platform.api.model.ModelDescriptor;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;
import java.util.List;
import java.util.Map;

@ApplicationScoped
public class AnthropicCloudModelSource implements CloudModelSource {

    private static final Logger LOG = Logger.getLogger(AnthropicCloudModelSource.class);
    private static final String SOURCE_ID = "cloud:anthropic";
    private static final String CREDENTIAL_REF = "cloud-anthropic";

    private final VendorClient client;
    private final LlmCredentialStore credentialStore;
    private volatile List<ModelDescriptor> lastKnownModels;
    private volatile CloudSourceStatus lastStatus;

    @Inject
    AnthropicCloudModelSource(AnthropicClient client, LlmCredentialStore credentialStore) {
        this((VendorClient) client, credentialStore);
    }

    AnthropicCloudModelSource(VendorClient client, LlmCredentialStore credentialStore) {
        this.client = client;
        this.credentialStore = credentialStore;
        this.lastStatus = CloudSourceStatus.inactive(SOURCE_ID, "Anthropic",
            "set ANTHROPIC_API_KEY");
    }

    @Override public String sourceId() { return SOURCE_ID; }
    @Override public int priority() { return 5; }

    @Override
    public List<ModelDescriptor> refresh() {
        Map<String, String> creds = credentialStore.resolve(
            TenancyConstants.PLATFORM_TENANT_ID, CREDENTIAL_REF);
        if (creds.isEmpty()) {
            if (lastKnownModels != null) {
                return lastKnownModels;
            }
            lastStatus = CloudSourceStatus.inactive(SOURCE_ID, "Anthropic",
                "set ANTHROPIC_API_KEY");
            return List.of();
        }
        var result = client.listModels(creds);
        if (result.valid()) {
            lastKnownModels = result.models();
            lastStatus = CloudSourceStatus.active(SOURCE_ID, "Anthropic",
                lastKnownModels.size());
            return lastKnownModels;
        }
        LOG.warnf("Cloud source %s refresh failed: %s", SOURCE_ID, result.errorMessage());
        lastStatus = CloudSourceStatus.error(SOURCE_ID, "Anthropic", result.errorMessage());
        return lastKnownModels != null ? lastKnownModels : List.of();
    }

    @Override
    public CloudSourceStatus status() {
        return lastStatus;
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl llm-config -Dtest=AnthropicCloudModelSourceTest`
Expected: PASS

- [ ] **Step 5: Write OpenAiCloudModelSource (same pattern)**

Create `OpenAiCloudModelSource.java` — identical structure, different constants:
- `SOURCE_ID = "cloud:openai"`, `CREDENTIAL_REF = "cloud-openai"`
- Injects `OpenAiClient` in CDI constructor
- Guidance message: `"set OPENAI_API_KEY"`

Create `OpenAiCloudModelSourceTest.java` — same test cases with OpenAI constants.

- [ ] **Step 6: Run all llm-config tests**

Run: `mvn --batch-mode test -pl llm-config`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add llm-config/src/main/java/io/casehub/platform/llm/config/AnthropicCloudModelSource.java llm-config/src/main/java/io/casehub/platform/llm/config/OpenAiCloudModelSource.java llm-config/src/test/java/io/casehub/platform/llm/config/AnthropicCloudModelSourceTest.java llm-config/src/test/java/io/casehub/platform/llm/config/OpenAiCloudModelSourceTest.java
git commit -m "feat(#288): add Anthropic + OpenAI cloud model sources with last-known-good caching"
```

---

## Batch 3: Credential bootstrap + status API

### Task 4: CloudSourceCredentialBootstrap

**Files:**
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/CloudSourceCredentialBootstrap.java`
- Test: `llm-config/src/test/java/io/casehub/platform/llm/config/CloudSourceCredentialBootstrapTest.java`

**Interfaces:**
- Consumes: `LlmCredentialStore.store()`, `LlmCredentialStore.resolve()`, `TenancyConstants.PLATFORM_TENANT_ID`
- Produces: Seeded credentials in LlmCredentialStore at platform scope. Runs at `@Priority(50)` before ModelRegistryRefresher.

- [ ] **Step 1: Write the failing test**

```java
package io.casehub.platform.llm.config;

import io.casehub.platform.api.identity.TenancyConstants;
import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class CloudSourceCredentialBootstrapTest {

    @Test
    void bootstrap_detectsAnthropicApiKey() {
        var store = new InMemoryLlmCredentialStore();
        var envVars = Map.of("ANTHROPIC_API_KEY", "sk-test-123");
        var bootstrap = new CloudSourceCredentialBootstrap(store, envVars::get);

        bootstrap.detectAndSeed();

        var creds = store.resolve(TenancyConstants.PLATFORM_TENANT_ID, "cloud-anthropic");
        assertThat(creds).containsEntry("api-key", "sk-test-123");
    }

    @Test
    void bootstrap_detectsOpenAiApiKey() {
        var store = new InMemoryLlmCredentialStore();
        var envVars = Map.of("OPENAI_API_KEY", "sk-openai-456");
        var bootstrap = new CloudSourceCredentialBootstrap(store, envVars::get);

        bootstrap.detectAndSeed();

        var creds = store.resolve(TenancyConstants.PLATFORM_TENANT_ID, "cloud-openai");
        assertThat(creds).containsEntry("api-key", "sk-openai-456");
    }

    @Test
    void bootstrap_doesNotOverwriteExistingCredentials() {
        var store = new InMemoryLlmCredentialStore();
        store.store(TenancyConstants.PLATFORM_TENANT_ID, "cloud-anthropic",
            Map.of("api-key", "admin-configured-key"));
        var envVars = Map.of("ANTHROPIC_API_KEY", "env-key");
        var bootstrap = new CloudSourceCredentialBootstrap(store, envVars::get);

        bootstrap.detectAndSeed();

        var creds = store.resolve(TenancyConstants.PLATFORM_TENANT_ID, "cloud-anthropic");
        assertThat(creds).containsEntry("api-key", "admin-configured-key");
    }

    @Test
    void bootstrap_noEnvVars_storesNothing() {
        var store = new InMemoryLlmCredentialStore();
        var bootstrap = new CloudSourceCredentialBootstrap(store, k -> null);

        bootstrap.detectAndSeed();

        assertThat(store.resolve(TenancyConstants.PLATFORM_TENANT_ID, "cloud-anthropic")).isEmpty();
        assertThat(store.resolve(TenancyConstants.PLATFORM_TENANT_ID, "cloud-openai")).isEmpty();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl llm-config -Dtest=CloudSourceCredentialBootstrapTest`
Expected: FAIL — class not found.

- [ ] **Step 3: Implement CloudSourceCredentialBootstrap**

```java
package io.casehub.platform.llm.config;

import io.casehub.platform.api.credentials.LlmCredentialStore;
import io.casehub.platform.api.identity.TenancyConstants;
import jakarta.annotation.Priority;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import jakarta.inject.Inject;
import io.quarkus.runtime.StartupEvent;
import org.jboss.logging.Logger;
import java.util.Map;
import java.util.function.Function;

@ApplicationScoped
public class CloudSourceCredentialBootstrap {

    private static final Logger LOG = Logger.getLogger(CloudSourceCredentialBootstrap.class);
    private static final String TENANT = TenancyConstants.PLATFORM_TENANT_ID;

    private final LlmCredentialStore credentialStore;
    private final Function<String, String> envLookup;

    @Inject
    CloudSourceCredentialBootstrap(LlmCredentialStore credentialStore) {
        this(credentialStore, System::getenv);
    }

    CloudSourceCredentialBootstrap(LlmCredentialStore credentialStore,
                                   Function<String, String> envLookup) {
        this.credentialStore = credentialStore;
        this.envLookup = envLookup;
    }

    void onStartup(@Observes @Priority(50) StartupEvent event) {
        detectAndSeed();
    }

    void detectAndSeed() {
        seedApiKey("ANTHROPIC_API_KEY", "cloud-anthropic", "anthropic");
        seedApiKey("OPENAI_API_KEY", "cloud-openai", "openai");
        logSummary();
    }

    private void seedApiKey(String envVar, String credentialRef, String vendorName) {
        if (!credentialStore.resolve(TENANT, credentialRef).isEmpty()) {
            LOG.debugf("  %s: credentials already configured — skipping env detection", vendorName);
            return;
        }
        String value = envLookup.apply(envVar);
        if (value != null && !value.isBlank()) {
            credentialStore.store(TENANT, credentialRef, Map.of("api-key", value));
            LOG.infof("  %s: active (%s detected)", vendorName, envVar);
        } else {
            LOG.infof("  %s: inactive — set %s", vendorName, envVar);
        }
    }

    private void logSummary() {
        LOG.info("Cloud model sources credential bootstrap complete");
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl llm-config -Dtest=CloudSourceCredentialBootstrapTest`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add llm-config/src/main/java/io/casehub/platform/llm/config/CloudSourceCredentialBootstrap.java llm-config/src/test/java/io/casehub/platform/llm/config/CloudSourceCredentialBootstrapTest.java
git commit -m "feat(#288): add CloudSourceCredentialBootstrap — env var detection + LlmCredentialStore seeding"
```

### Task 5: cloudSourceStatus() query in LlmConfigApi + LlmConfigService

**Files:**
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigApi.java`
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigService.java`
- Test: `llm-config/src/test/java/io/casehub/platform/llm/config/CloudSourceStatusQueryTest.java`

**Interfaces:**
- Consumes: `CloudModelSource.status()` (Task 1/3), `Instance<CloudModelSource>` CDI injection
- Produces: `List<CloudSourceStatus> cloudSourceStatus()` on `LlmConfigApi` — queryable via REST/GraphQL/MCP

- [ ] **Step 1: Write the failing test**

```java
package io.casehub.platform.llm.config;

import org.junit.jupiter.api.Test;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;

class CloudSourceStatusQueryTest {

    @Test
    void cloudSourceStatus_returnsStatusFromAllSources() {
        var activeSource = stubCloudSource("cloud:anthropic", "Anthropic",
            CloudSourceStatus.active("cloud:anthropic", "Anthropic", 3));
        var inactiveSource = stubCloudSource("cloud:openai", "OpenAI",
            CloudSourceStatus.inactive("cloud:openai", "OpenAI", "set OPENAI_API_KEY"));

        // LlmConfigService constructor needs adaptation to accept Instance<CloudModelSource>
        // For unit test, use a list-based wrapper
        var service = createServiceWithCloudSources(List.of(activeSource, inactiveSource));

        var statuses = service.cloudSourceStatus();

        assertThat(statuses).hasSize(2);
        assertThat(statuses.get(0).state()).isEqualTo(CloudSourceStatus.State.ACTIVE);
        assertThat(statuses.get(1).state()).isEqualTo(CloudSourceStatus.State.INACTIVE);
    }

    // ... stub helpers
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — method not found on LlmConfigApi/LlmConfigService.

- [ ] **Step 3: Add cloudSourceStatus() to LlmConfigApi**

```java
@PlatformQuery("List cloud model source status — active, inactive, or error with guidance")
List<CloudSourceStatus> cloudSourceStatus();
```

- [ ] **Step 4: Implement in LlmConfigService**

Add `@Inject @Any Instance<CloudModelSource> cloudSources` field. Implement:

```java
@Override
public List<CloudSourceStatus> cloudSourceStatus() {
    var statuses = new ArrayList<CloudSourceStatus>();
    for (CloudModelSource source : cloudSources) {
        statuses.add(source.status());
    }
    return statuses;
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mvn --batch-mode test -pl llm-config -Dtest=CloudSourceStatusQueryTest`
Expected: PASS

- [ ] **Step 6: Run all llm-config tests**

Run: `mvn --batch-mode test -pl llm-config`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigApi.java llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigService.java llm-config/src/test/java/io/casehub/platform/llm/config/CloudSourceStatusQueryTest.java
git commit -m "feat(#288): add cloudSourceStatus() query API for onboarding guidance"
```

---

## Batch 4: Vertex module

### Task 6: llm-config-vertex module + VertexClient + VertexCloudModelSource

**Files:**
- Create: `llm-config-vertex/pom.xml`
- Create: `llm-config-vertex/src/main/java/io/casehub/platform/llm/config/vertex/VertexClient.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/VertexCloudModelSource.java`
- Test: `llm-config-vertex/src/test/java/io/casehub/platform/llm/config/vertex/VertexClientTest.java`
- Test: `llm-config/src/test/java/io/casehub/platform/llm/config/VertexCloudModelSourceTest.java`
- Modify: `pom.xml` (root) — add `llm-config-vertex` to modules list
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/CloudSourceCredentialBootstrap.java` — add Vertex detection

**Interfaces:**
- Consumes: `VendorClient` interface (from llm-config), `google-auth-library` ADC, `ModelRegistry` for seed enrichment
- Produces: `VertexClient @ApplicationScoped VendorClient` with `vendorKey()="vertex"`, `backendKey()="claude"`, `authMethod()="gcp-adc"`, `requiredFields()=["project-id", "region"]`

- [ ] **Step 1: Create llm-config-vertex/pom.xml**

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
    <artifactId>casehub-platform-llm-config-vertex</artifactId>
    <name>CaseHub Platform LLM Config — Vertex AI</name>
    <description>Vertex AI (Anthropic) VendorClient — Google Cloud ADC auth</description>
    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-llm-config</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>com.google.auth</groupId>
            <artifactId>google-auth-library-oauth2-http</artifactId>
            <version>1.29.0</version>
        </dependency>
        <!-- provided -->
        <dependency>
            <groupId>jakarta.enterprise</groupId>
            <artifactId>jakarta.enterprise.cdi-api</artifactId>
            <scope>provided</scope>
        </dependency>
        <dependency>
            <groupId>org.jboss.logging</groupId>
            <artifactId>jboss-logging</artifactId>
            <scope>provided</scope>
        </dependency>
        <!-- test -->
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
</project>
```

- [ ] **Step 2: Add llm-config-vertex to root pom.xml modules**

Add `<module>llm-config-vertex</module>` after `llm-config` in the root `pom.xml` `<modules>` section.

- [ ] **Step 3: Write VertexClient test**

Test with mocked HTTP responses — verify model list parsing, seed enrichment, ADC token usage, Anthropic provider filtering.

- [ ] **Step 4: Implement VertexClient**

```java
package io.casehub.platform.llm.config.vertex;

import com.google.auth.oauth2.GoogleCredentials;
import io.casehub.platform.llm.config.VendorClient;
import io.casehub.platform.llm.config.ValidationResult;
// ... imports

@ApplicationScoped
public class VertexClient implements VendorClient {

    private final HttpClient httpClient = HttpClient.newHttpClient();
    private final Function<ModelQuery, List<ModelDescriptor>> seedLookup;

    @Inject
    VertexClient(ModelRegistry registry) {
        this.seedLookup = registry::query;
    }

    @Override public String vendorKey() { return "vertex"; }
    @Override public String backendKey() { return "claude"; }
    @Override public String displayName() { return "Vertex AI (Anthropic)"; }
    @Override public String authMethod() { return "gcp-adc"; }
    @Override public List<String> requiredFields() { return List.of("project-id", "region"); }

    @Override
    public ValidationResult listModels(Map<String, String> credentials) {
        String projectId = credentials.get("project-id");
        String region = credentials.getOrDefault("region", "us-central1");
        if (projectId == null || projectId.isBlank()) {
            return ValidationResult.failure("project-id is required");
        }
        try {
            GoogleCredentials googleCreds = GoogleCredentials.getApplicationDefault()
                .createScoped("https://www.googleapis.com/auth/cloud-platform");
            googleCreds.refreshIfExpired();
            String token = googleCreds.getAccessToken().getTokenValue();

            String url = String.format(
                "https://%s-aiplatform.googleapis.com/v1/projects/%s/locations/%s/publishers/anthropic/models",
                region, projectId, region);

            var request = HttpRequest.newBuilder()
                .uri(URI.create(url))
                .header("Authorization", "Bearer " + token)
                .GET().build();
            var response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());

            if (response.statusCode() != 200) {
                return ValidationResult.failure("Vertex AI returned status " + response.statusCode());
            }
            return ValidationResult.success(parseModelsResponse(response.body()));
        } catch (Exception e) {
            return ValidationResult.failure("Failed to connect to Vertex AI: " + e.getMessage());
        }
    }

    // parseModelsResponse — same seed enrichment pattern as AnthropicClient
}
```

- [ ] **Step 5: Write VertexCloudModelSource (in llm-config/)**

Same pattern as AnthropicCloudModelSource but injects VendorClient via `@Any Instance<VendorClient>` and matches by `vendorKey()`:

```java
@ApplicationScoped
public class VertexCloudModelSource implements CloudModelSource {
    private static final String SOURCE_ID = "cloud:vertex";
    private static final String CREDENTIAL_REF = "cloud-vertex";
    // ... same refresh/status pattern, inject via Instance<VendorClient>
    // If no VertexClient on classpath, Instance is empty → refresh returns List.of()
}
```

- [ ] **Step 6: Add Vertex detection to CloudSourceCredentialBootstrap**

Add method to detect Google Cloud credentials:

```java
private void seedVertexCredentials() {
    if (!credentialStore.resolve(TENANT, "cloud-vertex").isEmpty()) return;
    String projectId = envLookup.apply("GOOGLE_CLOUD_PROJECT");
    if (projectId == null || projectId.isBlank()) return;
    try {
        GoogleCredentials.getApplicationDefault();
        String region = envLookup.apply("CLOUD_ML_REGION");
        credentialStore.store(TENANT, "cloud-vertex", Map.of(
            "project-id", projectId,
            "region", region != null ? region : "us-central1"));
        LOG.infof("  vertex: active (GOOGLE_CLOUD_PROJECT + ADC detected)");
    } catch (Exception e) {
        LOG.infof("  vertex: inactive — set GOOGLE_APPLICATION_CREDENTIALS + GOOGLE_CLOUD_PROJECT");
    }
}
```

Note: This method uses `GoogleCredentials` — if google-auth is not on classpath, it throws `NoClassDefFoundError`. Wrap in try/catch `Throwable` (not just Exception) in the bootstrap to handle absent SDKs gracefully.

- [ ] **Step 7: Run all tests**

Run: `mvn --batch-mode test -pl llm-config,llm-config-vertex`
Expected: All tests pass.

- [ ] **Step 8: Commit**

```bash
git add llm-config-vertex/ pom.xml llm-config/src/main/java/io/casehub/platform/llm/config/VertexCloudModelSource.java llm-config/src/main/java/io/casehub/platform/llm/config/CloudSourceCredentialBootstrap.java llm-config/src/test/java/io/casehub/platform/llm/config/VertexCloudModelSourceTest.java
git commit -m "feat(#288): add llm-config-vertex module + VertexClient + VertexCloudModelSource"
```

---

## Batch 5: Bedrock module

### Task 7: llm-config-bedrock module + BedrockClient + BedrockCloudModelSource

**Files:**
- Create: `llm-config-bedrock/pom.xml`
- Create: `llm-config-bedrock/src/main/java/io/casehub/platform/llm/config/bedrock/BedrockClient.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/BedrockCloudModelSource.java`
- Test: `llm-config-bedrock/src/test/java/io/casehub/platform/llm/config/bedrock/BedrockClientTest.java`
- Test: `llm-config/src/test/java/io/casehub/platform/llm/config/BedrockCloudModelSourceTest.java`
- Modify: `pom.xml` (root) — add `llm-config-bedrock` to modules list
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/CloudSourceCredentialBootstrap.java` — add Bedrock detection

**Interfaces:**
- Consumes: `VendorClient` interface, `software.amazon.awssdk:auth` for credential chain + SigV4
- Produces: `BedrockClient @ApplicationScoped VendorClient` with `vendorKey()="bedrock"`, `backendKey()="claude"`, `authMethod()="aws-sigv4"`, `requiredFields()=["region"]`

- [ ] **Step 1: Create llm-config-bedrock/pom.xml**

Same structure as llm-config-vertex, with AWS SDK dependencies:

```xml
<dependency>
    <groupId>software.amazon.awssdk</groupId>
    <artifactId>auth</artifactId>
    <version>2.31.1</version>
</dependency>
<dependency>
    <groupId>software.amazon.awssdk</groupId>
    <artifactId>regions</artifactId>
    <version>2.31.1</version>
</dependency>
```

- [ ] **Step 2: Add llm-config-bedrock to root pom.xml modules**

- [ ] **Step 3: Write BedrockClient test**

Test with mocked HTTP responses — verify model list parsing, Anthropic provider filtering, seed enrichment, SigV4 signing.

- [ ] **Step 4: Implement BedrockClient**

```java
package io.casehub.platform.llm.config.bedrock;

import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.auth.signer.Aws4Signer;
// ... imports

@ApplicationScoped
public class BedrockClient implements VendorClient {

    private final HttpClient httpClient = HttpClient.newHttpClient();
    private final Function<ModelQuery, List<ModelDescriptor>> seedLookup;

    @Override public String vendorKey() { return "bedrock"; }
    @Override public String backendKey() { return "claude"; }
    @Override public String displayName() { return "Amazon Bedrock (Anthropic)"; }
    @Override public String authMethod() { return "aws-sigv4"; }
    @Override public List<String> requiredFields() { return List.of("region"); }

    @Override
    public ValidationResult listModels(Map<String, String> credentials) {
        String region = credentials.getOrDefault("region", "us-east-1");
        try {
            var awsCreds = DefaultCredentialsProvider.create().resolveCredentials();
            // Build SigV4-signed GET request to:
            // https://bedrock.{region}.amazonaws.com/foundation-models
            // Filter response to providerName == "Anthropic"
            // Parse, seed-enrich, return ModelDescriptors
        } catch (Exception e) {
            return ValidationResult.failure("Failed to connect to Bedrock: " + e.getMessage());
        }
    }
}
```

- [ ] **Step 5: Write BedrockCloudModelSource (in llm-config/)**

Same Instance<VendorClient> pattern as VertexCloudModelSource:
- `SOURCE_ID = "cloud:bedrock"`, `CREDENTIAL_REF = "cloud-bedrock"`
- Guidance: `"configure AWS credentials + AWS_REGION"`

- [ ] **Step 6: Add Bedrock detection to CloudSourceCredentialBootstrap**

```java
private void seedBedrockCredentials() {
    if (!credentialStore.resolve(TENANT, "cloud-bedrock").isEmpty()) return;
    String region = envLookup.apply("AWS_REGION");
    if (region == null || region.isBlank()) return;
    try {
        DefaultCredentialsProvider.create().resolveCredentials();
        credentialStore.store(TENANT, "cloud-bedrock", Map.of("region", region));
        LOG.infof("  bedrock: active (AWS credentials + AWS_REGION detected)");
    } catch (Exception e) {
        LOG.infof("  bedrock: inactive — configure AWS credentials + AWS_REGION");
    }
}
```

Same `catch Throwable` pattern as Vertex for absent SDK.

- [ ] **Step 7: Run all tests**

Run: `mvn --batch-mode test -pl llm-config,llm-config-vertex,llm-config-bedrock`
Expected: All tests pass.

- [ ] **Step 8: Full build verification**

Run: `mvn --batch-mode install`
Expected: Clean build across all modules.

- [ ] **Step 9: Commit**

```bash
git add llm-config-bedrock/ pom.xml llm-config/src/main/java/io/casehub/platform/llm/config/BedrockCloudModelSource.java llm-config/src/main/java/io/casehub/platform/llm/config/CloudSourceCredentialBootstrap.java llm-config/src/test/java/io/casehub/platform/llm/config/BedrockCloudModelSourceTest.java
git commit -m "feat(#288): add llm-config-bedrock module + BedrockClient + BedrockCloudModelSource"
```

---

## References

- `specs/issue-288-cloud-model-sources/2026-09-12-cloud-model-sources-design.md` — design spec this plan implements
- `llm-config/src/main/java/io/casehub/platform/llm/config/VendorClient.java` — shared VendorClient interface
- `llm-config/src/main/java/io/casehub/platform/llm/config/AnthropicClient.java` — existing VendorClient pattern to follow
- `llm-config/src/main/java/io/casehub/platform/llm/config/ConfiguredModelSource.java` — resilience pattern (lastKnownModels)
- `platform/src/main/java/io/casehub/platform/model/ModelRegistryRefresher.java` — refresh cycle, priority sorting target
- `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigApi.java` — SPI interface to extend
- `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigService.java` — implementation to extend
- GitHub #288 — focal issue
- GitHub #285 — parent epic (LLM model registry)
- GitHub #291 — predecessor (LLM config wizard API)
