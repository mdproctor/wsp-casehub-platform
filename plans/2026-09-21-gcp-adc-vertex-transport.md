# GCP-ADC Vertex Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #376 — Support gcp-adc auth method in Claude backend — Vertex AI transport
**Issue group:** #376

**Goal:** Enable Claude backend to use Vertex AI transport via GCP Application Default Credentials when `project-id` and `region` credentials are present in `LlmCredentialStore`.

**Architecture:** Add `Map<String, String> env` constructor parameter to `ClaudeAgentClient` and refactor to `CLIOptions`-based builder. Create `ClaudeVertexBackendFactory` in `agent-claude` following the `OpenAiDirectBackendFactory` pattern. Extend `SeedCatalogModelSource` to support optional `apiModelId`/`instanceId` fields and add Vertex model entries.

**Tech Stack:** Java 21, Quarkus CDI, claude-code-sdk (CLIOptions), JUnit 5, AssertJ

## Global Constraints

- `agent-claude-core` must remain framework-neutral — no CDI, no Spring imports
- `agent-claude` is the Quarkus CDI wiring module — `@ApplicationScoped` beans go here
- `BackendInstanceFactory` SPI is in `agent-api` (already a dependency)
- Existing `ClaudeAgentClient` tests use the `streamFactory` constructor for unit testing (no real CLI process)

---

## Batch 1: ClaudeAgentClient env var support

### Task 1: Add env parameter to ClaudeAgentClient and refactor to CLIOptions builder

**Files:**
- Modify: `agent-claude-core/src/main/java/io/casehub/platform/agent/claude/ClaudeAgentClient.java`
- Modify: `agent-claude-core/src/main/java/io/casehub/platform/agent/claude/ClaudeAgentProvider.java`
- Modify: `agent-claude-core/src/test/java/io/casehub/platform/agent/claude/ClaudeAgentClientTest.java`
- Modify: `agent-claude/src/main/java/io/casehub/platform/agent/claude/quarkus/ClaudeBeans.java`

**Interfaces:**
- Produces: `ClaudeAgentClient(ClaudeAgentProperties, Map<String, String>)` — new constructor accepting env vars
- Produces: `ClaudeAgentClient(ClaudeAgentProperties)` — existing constructor, delegates with `Map.of()`
- Produces: `ClaudeAgentClient(ClaudeAgentProperties, Function<AgentSessionConfig, Multi<AgentEvent>>)` — existing test constructor, delegates with `Map.of()`
- Produces: `ClaudeAgentProvider(ClaudeAgentClient)` — unchanged

- [ ] **Step 1: Write failing test — env vars passed through to CLIOptions**

Add a test to `ClaudeAgentClientTest` that verifies env vars are available when the client is constructed with a non-empty env map. Since `buildEventStream` is package-private, test via the `streamFactory` constructor path — assert the client can be constructed with env vars and that the existing behavior (semaphore, lifecycle) is unchanged.

```java
@Test
void constructorAcceptsEnvMap() {
    var env = Map.of("CLAUDE_CODE_USE_VERTEX", "1", "ANTHROPIC_VERTEX_PROJECT_ID", "my-project");
    client = new ClaudeAgentClient(props(2), env);
    assertThat(client.availablePermits()).isEqualTo(2);
}

@Test
void emptyEnvMap_backwardCompatible() {
    client = new ClaudeAgentClient(props(2), Map.of());
    assertThat(client.availablePermits()).isEqualTo(2);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl agent-claude-core test -Dtest=ClaudeAgentClientTest#constructorAcceptsEnvMap+emptyEnvMap_backwardCompatible --batch-mode -q`
Expected: compilation failure — no constructor accepting `Map<String, String>`

- [ ] **Step 3: Add env field and new constructor to ClaudeAgentClient**

Add a `private final Map<String, String> env` field. Add a new primary constructor `ClaudeAgentClient(ClaudeAgentProperties, Map<String, String>)`. Update the existing single-arg constructor to delegate with `Map.of()`. Update the test constructor to accept and store env (or delegate with `Map.of()`).

Use `ide_edit_member` to modify the class. The field:

```java
private final Map<String, String> env;
```

New primary constructor:

```java
public ClaudeAgentClient(ClaudeAgentProperties properties, Map<String, String> env) {
    this.properties = properties;
    this.env = env != null ? Map.copyOf(env) : Map.of();
    int maxSessions = properties.maxConcurrentSessions();
    if (maxSessions < 0) {
        throw new IllegalStateException(
            "casehub.platform.agent.claude.max-concurrent-sessions must be >= 0, got " + maxSessions);
    }
    this.semaphore = new Semaphore(maxSessions == 0 ? Integer.MAX_VALUE : maxSessions);
    this.activeSessions = new CopyOnWriteArraySet<>();
    this.timeoutScheduler = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread t = new Thread(r, "casehub-agent-timeout");
        t.setDaemon(true);
        return t;
    });
    this.streamFactory = null;
}
```

Existing single-arg constructor becomes:

```java
public ClaudeAgentClient(ClaudeAgentProperties properties) {
    this(properties, Map.of());
}
```

Test constructor becomes:

```java
public ClaudeAgentClient(ClaudeAgentProperties properties,
                         Function<AgentSessionConfig, Multi<AgentEvent>> streamFactory) {
    this.properties = properties;
    this.env = Map.of();
    int maxSessions = properties.maxConcurrentSessions();
    if (maxSessions < 0) {
        throw new IllegalStateException(
            "casehub.platform.agent.claude.max-concurrent-sessions must be >= 0, got " + maxSessions);
    }
    this.semaphore = new Semaphore(maxSessions == 0 ? Integer.MAX_VALUE : maxSessions);
    this.activeSessions = new CopyOnWriteArraySet<>();
    this.timeoutScheduler = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread t = new Thread(r, "casehub-agent-timeout");
        t.setDaemon(true);
        return t;
    });
    this.streamFactory = streamFactory;
}
```

- [ ] **Step 4: Refactor buildEventStream to use CLIOptions builder**

Replace the `ClaudeClient.async()` fluent builder with `CLIOptions.builder()` + `ClaudeClient.async(CLIOptions)` in the `buildEventStream()` method. Add import for `org.springaicommunity.claude.agent.sdk.transport.CLIOptions`.

Before (lines 151-162):
```java
ClaudeClient.AsyncSpec builder = ClaudeClient.async()
    .workingDirectory(Path.of(System.getProperty("user.dir")))
    .systemPrompt(config.systemPrompt());

properties.binaryPath().ifPresent(builder::claudePath);

Map<String, McpServerConfig> sdkMcpServers = toSdkMcpServers(config.mcpServers());
if (!sdkMcpServers.isEmpty()) {
    builder.mcpServers(sdkMcpServers);
}

ClaudeAsyncClient sdkClient = builder.build();
```

After:
```java
var optionsBuilder = CLIOptions.builder()
    .systemPrompt(config.systemPrompt());

Map<String, McpServerConfig> sdkMcpServers = toSdkMcpServers(config.mcpServers());
if (!sdkMcpServers.isEmpty()) {
    optionsBuilder.mcpServers(sdkMcpServers);
}
if (!env.isEmpty()) {
    optionsBuilder.env(new HashMap<>(env));
}
CLIOptions cliOptions = optionsBuilder.build();

var sessionBuilder = ClaudeClient.async(cliOptions)
    .workingDirectory(Path.of(System.getProperty("user.dir")));
properties.binaryPath().ifPresent(sessionBuilder::claudePath);

ClaudeAsyncClient sdkClient = sessionBuilder.build();
```

Add import: `import org.springaicommunity.claude.agent.sdk.transport.CLIOptions;`

- [ ] **Step 5: Refactor openSession to use CLIOptions builder**

Apply the same pattern to the `openSession()` method (lines 267-274):

Before:
```java
final ClaudeClient.AsyncSpec builder = ClaudeClient.async()
    .workingDirectory(Path.of(System.getProperty("user.dir")))
    .systemPrompt(init.systemPrompt());
properties.binaryPath().ifPresent(builder::claudePath);
final Map<String, McpServerConfig> sdkMcpServers = toSdkMcpServers(init.mcpServers());
if (!sdkMcpServers.isEmpty()) builder.mcpServers(sdkMcpServers);

final ClaudeAsyncClient sdkClient = builder.build();
```

After:
```java
var optionsBuilder = CLIOptions.builder()
    .systemPrompt(init.systemPrompt());
final Map<String, McpServerConfig> sdkMcpServers = toSdkMcpServers(init.mcpServers());
if (!sdkMcpServers.isEmpty()) optionsBuilder.mcpServers(sdkMcpServers);
if (!env.isEmpty()) optionsBuilder.env(new HashMap<>(env));
CLIOptions cliOptions = optionsBuilder.build();

var sessionBuilder = ClaudeClient.async(cliOptions)
    .workingDirectory(Path.of(System.getProperty("user.dir")));
properties.binaryPath().ifPresent(sessionBuilder::claudePath);

final ClaudeAsyncClient sdkClient = sessionBuilder.build();
```

- [ ] **Step 6: Update ClaudeBeans CDI producer**

In `ClaudeBeans.claudeAgentClient()`, the existing constructor call `new ClaudeAgentClient(config)` still works because the single-arg constructor now delegates to `this(properties, Map.of())`. No code change needed in ClaudeBeans — verify it still compiles.

- [ ] **Step 7: Run all existing tests**

Run: `mvn -pl agent-claude-core test --batch-mode -q`
Expected: all existing tests pass — the refactor is behavior-preserving

- [ ] **Step 8: Commit**

```bash
git add agent-claude-core/src/main/java/io/casehub/platform/agent/claude/ClaudeAgentClient.java
git add agent-claude-core/src/test/java/io/casehub/platform/agent/claude/ClaudeAgentClientTest.java
git commit -m "feat(#376): add env var support to ClaudeAgentClient

Refactor buildEventStream and openSession to use CLIOptions builder,
enabling environment variable injection for Vertex transport.

Refs #376

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 2: ClaudeVertexBackendFactory + seed catalog

### Task 2: Create ClaudeVertexBackendFactory

**Files:**
- Create: `agent-claude/src/main/java/io/casehub/platform/agent/claude/ClaudeVertexBackendFactory.java`
- Create: `agent-claude/src/main/java/io/casehub/platform/agent/claude/DefaultClaudeAgentProperties.java`
- Create: `agent-claude/src/test/java/io/casehub/platform/agent/claude/ClaudeVertexBackendFactoryTest.java`

**Interfaces:**
- Consumes: `ClaudeAgentClient(ClaudeAgentProperties, Map<String, String>)` from Task 1
- Consumes: `ClaudeAgentProvider(ClaudeAgentClient)` from agent-claude-core
- Produces: `ClaudeVertexBackendFactory` — `@ApplicationScoped implements BackendInstanceFactory`, CDI-discovered by `BackendInstanceCoordinator`

- [ ] **Step 1: Write failing tests for the factory**

```java
package io.casehub.platform.agent.claude;

import io.casehub.platform.agent.BackendInstance;
import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class ClaudeVertexBackendFactoryTest {

    private final ClaudeVertexBackendFactory factory = new ClaudeVertexBackendFactory();

    @Test
    void backendKey_isClaude() {
        assertThat(factory.backendKey()).isEqualTo("claude");
    }

    @Test
    void handles_vertexRefWithProjectId() {
        assertThat(factory.handles("cloud-vertex",
            Map.of("project-id", "my-proj", "region", "us-east1"))).isTrue();
    }

    @Test
    void handles_rejectsNonVertexRef() {
        assertThat(factory.handles("cloud-anthropic",
            Map.of("api-key", "sk-xxx"))).isFalse();
    }

    @Test
    void handles_rejectsMissingProjectId() {
        assertThat(factory.handles("cloud-vertex",
            Map.of("region", "us-east1"))).isFalse();
    }

    @Test
    void create_returnsBackendInstance() {
        BackendInstance instance = factory.create("cloud-vertex",
            Map.of("project-id", "my-proj", "region", "us-east1"));
        assertThat(instance.instanceId()).isEqualTo("vertex");
        assertThat(instance.backend()).isInstanceOf(ClaudeAgentProvider.class);
        assertThat(instance.backend().key()).isEqualTo("claude");
    }

    @Test
    void create_defaultsRegionToUsCentral1() {
        BackendInstance instance = factory.create("cloud-vertex",
            Map.of("project-id", "my-proj"));
        assertThat(instance).isNotNull();
    }

    @Test
    void deriveInstanceId_cloudVertex() {
        assertThat(factory.deriveInstanceId("cloud-vertex")).isEqualTo("vertex");
    }

    @Test
    void deriveInstanceId_customRef() {
        assertThat(factory.deriveInstanceId("cloud-staging-vertex")).isEqualTo("staging-vertex");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl agent-claude test -Dtest=ClaudeVertexBackendFactoryTest --batch-mode -q`
Expected: compilation failure — classes don't exist yet

- [ ] **Step 3: Create DefaultClaudeAgentProperties**

```java
package io.casehub.platform.agent.claude;

import java.time.Duration;
import java.util.Optional;

record DefaultClaudeAgentProperties(
        Optional<String> binaryPath,
        Duration defaultTimeout,
        int maxConcurrentSessions
) implements ClaudeAgentProperties {

    DefaultClaudeAgentProperties() {
        this(Optional.empty(), Duration.ofMinutes(5), 4);
    }
}
```

- [ ] **Step 4: Create ClaudeVertexBackendFactory**

```java
package io.casehub.platform.agent.claude;

import io.casehub.platform.agent.BackendInstance;
import io.casehub.platform.agent.BackendInstanceFactory;
import jakarta.enterprise.context.ApplicationScoped;
import java.util.Map;

@ApplicationScoped
public class ClaudeVertexBackendFactory implements BackendInstanceFactory {

    @Override
    public String backendKey() { return "claude"; }

    @Override
    public boolean handles(String credentialRef, Map<String, String> credentials) {
        return credentialRef.contains("vertex")
            && credentials.containsKey("project-id");
    }

    @Override
    public BackendInstance create(String credentialRef, Map<String, String> credentials) {
        String projectId = credentials.get("project-id");
        String region = credentials.getOrDefault("region", "us-central1");
        String instanceId = deriveInstanceId(credentialRef);

        Map<String, String> env = Map.of(
            "CLAUDE_CODE_USE_VERTEX", "1",
            "ANTHROPIC_VERTEX_PROJECT_ID", projectId,
            "ANTHROPIC_VERTEX_REGION", region
        );

        var properties = new DefaultClaudeAgentProperties();
        var client = new ClaudeAgentClient(properties, env);
        var backend = new ClaudeAgentProvider(client);
        return new BackendInstance(instanceId, backend);
    }

    String deriveInstanceId(String credentialRef) {
        if ("cloud-vertex".equals(credentialRef)) return "vertex";
        return credentialRef.replace("cloud-", "");
    }
}
```

- [ ] **Step 5: Run factory tests**

Run: `mvn -pl agent-claude test -Dtest=ClaudeVertexBackendFactoryTest --batch-mode -q`
Expected: all tests pass

- [ ] **Step 6: Add integration test to BackendInstanceCoordinatorTest**

Add a test case to the existing `BackendInstanceCoordinatorTest` that verifies the factory integrates with the coordinator. Use the real `ClaudeVertexBackendFactory`.

```java
@Test
void vertexFactoryRegistersWhenVertexCredentialsPresent() {
    var registry = new InMemoryBackendInstanceRegistry();
    var factory = new ClaudeVertexBackendFactory();
    var store = stubCredentialStore(Map.of(
        "cloud-vertex", Map.of("project-id", "my-proj", "region", "us-east1")));
    var coordinator = new BackendInstanceCoordinator(
            registry, List.of(), List.of(factory), store);
    coordinator.onStartup();
    assertThat(registry.resolve("claude", "vertex")).isPresent();
    assertThat(registry.resolve("claude", "vertex").get().key()).isEqualTo("claude");
}

@Test
void vertexFactoryIgnoresNonVertexCredentials() {
    var registry = new InMemoryBackendInstanceRegistry();
    var factory = new ClaudeVertexBackendFactory();
    var store = stubCredentialStore(Map.of(
        "cloud-anthropic", Map.of("api-key", "sk-xxx")));
    var coordinator = new BackendInstanceCoordinator(
            registry, List.of(), List.of(factory), store);
    coordinator.onStartup();
    assertThat(registry.resolve("claude", "vertex")).isEmpty();
}
```

- [ ] **Step 7: Run coordinator tests**

Run: `mvn -pl agent-router test -Dtest=BackendInstanceCoordinatorTest --batch-mode -q`
Expected: all tests pass (including the new ones)

- [ ] **Step 8: Commit**

```bash
git add agent-claude/src/main/java/io/casehub/platform/agent/claude/ClaudeVertexBackendFactory.java
git add agent-claude/src/main/java/io/casehub/platform/agent/claude/DefaultClaudeAgentProperties.java
git add agent-claude/src/test/java/io/casehub/platform/agent/claude/ClaudeVertexBackendFactoryTest.java
git add agent-router/src/test/java/io/casehub/platform/agent/router/BackendInstanceCoordinatorTest.java
git commit -m "feat(#376): add ClaudeVertexBackendFactory for gcp-adc auth

Creates Vertex-configured ClaudeAgentClient instances when
LlmCredentialStore contains cloud-vertex credentials with
project-id and region.

Refs #376

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 3: Extend seed catalog with Vertex model entries

**Files:**
- Modify: `platform/src/main/java/io/casehub/platform/model/SeedCatalogModelSource.java`
- Modify: `platform/src/main/resources/models/seed-catalog.yaml`
- Modify: `platform/src/test/java/io/casehub/platform/model/SeedCatalogModelSourceTest.java`

**Interfaces:**
- Consumes: `ModelDescriptor(id, apiModelId, backendKey, instanceId, ...)` constructor — 4th param is `backendInstanceId`
- Produces: Seed catalog entries with `apiModelId` and `instanceId` fields parsed correctly

- [ ] **Step 1: Write failing tests for new seed catalog fields**

```java
@Test
void refresh_vertexSonnetPresent() {
    var models = source.refresh();
    var vertexSonnet = models.stream()
        .filter(m -> m.id().equals("claude-sonnet-5-vertex"))
        .findFirst().orElseThrow();
    assertThat(vertexSonnet.apiModelId()).isEqualTo("claude-sonnet-5");
    assertThat(vertexSonnet.backendInstanceId()).isEqualTo("vertex");
    assertThat(vertexSonnet.backendKey()).isEqualTo("claude");
    assertThat(vertexSonnet.authMethod()).isEqualTo("gcp-adc");
    assertThat(vertexSonnet.vendor()).isEqualTo("anthropic");
}

@Test
void refresh_existingModelsRetainDefaults() {
    var models = source.refresh();
    var directSonnet = models.stream()
        .filter(m -> m.id().equals("claude-sonnet-5"))
        .findFirst().orElseThrow();
    assertThat(directSonnet.apiModelId()).isEqualTo("claude-sonnet-5");
    assertThat(directSonnet.backendInstanceId()).isNull();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl platform test -Dtest=SeedCatalogModelSourceTest#refresh_vertexSonnetPresent+refresh_existingModelsRetainDefaults --batch-mode -q`
Expected: FAIL — no `claude-sonnet-5-vertex` entry exists, and `apiModelId` may not parse correctly

- [ ] **Step 3: Update SeedCatalogModelSource.parseModel() for optional fields**

Modify the `parseModel()` method to read optional `apiModelId` and `instanceId` fields:

```java
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

    String id = node.get("id").asText();
    String apiModelId = node.has("apiModelId") ? node.get("apiModelId").asText() : id;
    String instanceId = node.has("instanceId") ? node.get("instanceId").asText(null) : null;

    return new ModelDescriptor(
        id,
        apiModelId,
        node.get("backendKey").asText(),
        instanceId,
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
```

- [ ] **Step 4: Add Vertex model entries to seed-catalog.yaml**

Append to the end of `seed-catalog.yaml`, before the last line:

```yaml

  # --- Anthropic via Vertex AI ---
  - id: claude-opus-5-vertex
    apiModelId: claude-opus-5
    backendKey: claude
    instanceId: vertex
    vendor: anthropic
    family: claude
    displayName: Claude Opus 5 (Vertex)
    tier: FLAGSHIP
    capabilities: [text, vision, tool-use, code, reasoning]
    contextWindow: 200000
    maxOutput: 32768
    locality: CLOUD
    costTier: PREMIUM
    authMethod: gcp-adc

  - id: claude-sonnet-5-vertex
    apiModelId: claude-sonnet-5
    backendKey: claude
    instanceId: vertex
    vendor: anthropic
    family: claude
    displayName: Claude Sonnet 5 (Vertex)
    tier: STANDARD
    capabilities: [text, vision, tool-use, code, reasoning]
    contextWindow: 200000
    maxOutput: 16384
    locality: CLOUD
    costTier: HIGH
    authMethod: gcp-adc

  - id: claude-haiku-4-5-vertex
    apiModelId: claude-haiku-4-5
    backendKey: claude
    instanceId: vertex
    vendor: anthropic
    family: claude
    displayName: Claude Haiku 4.5 (Vertex)
    tier: FAST
    capabilities: [text, vision, tool-use, code]
    contextWindow: 200000
    maxOutput: 8192
    locality: CLOUD
    costTier: LOW
    authMethod: gcp-adc
```

- [ ] **Step 5: Run seed catalog tests**

Run: `mvn -pl platform test -Dtest=SeedCatalogModelSourceTest --batch-mode -q`
Expected: all tests pass including the new vertex assertions

- [ ] **Step 6: Run full build**

Run: `mvn --batch-mode install -q`
Expected: full build succeeds — all modules compile, all tests pass

- [ ] **Step 7: Commit**

```bash
git add platform/src/main/java/io/casehub/platform/model/SeedCatalogModelSource.java
git add platform/src/main/resources/models/seed-catalog.yaml
git add platform/src/test/java/io/casehub/platform/model/SeedCatalogModelSourceTest.java
git commit -m "feat(#376): add Vertex model entries to seed catalog

Support optional apiModelId and instanceId fields in seed-catalog.yaml.
Add 3 Vertex-auth Claude model entries (opus-5, sonnet-5, haiku-4.5)
with instanceId=vertex binding to the factory backend.

Refs #376

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## References

- [2026-09-21-gcp-adc-vertex-transport-design.md] — design spec this plan implements
- [agent-api/.../BackendInstanceFactory.java] — SPI contract
- [agent-router/.../BackendInstanceCoordinator.java:52-76] — startup factory iteration
- [agent-openai/.../OpenAiDirectBackendFactory.java] — existing factory pattern to follow
- [agent-claude-core/.../ClaudeAgentClient.java:142-212] — buildEventStream refactor target
- [agent-claude-core/.../ClaudeAgentClient.java:252-285] — openSession refactor target
- [agent-claude/.../ClaudeBeans.java] — CDI producer (no changes needed)
- [platform/.../SeedCatalogModelSource.java:59-91] — parseModel extension point
- [platform/.../seed-catalog.yaml] — model entries
- [agent-router/.../RoutingAgentProvider.java:103-105,148-149] — instanceId routing confirmed
- [GitHub #376] — focal issue
