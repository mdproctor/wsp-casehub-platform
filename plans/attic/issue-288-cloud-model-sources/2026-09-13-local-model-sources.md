# Local Model Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #289 — local model sources — Ollama + HuggingFace discovery and lifecycle
**Issue group:** #288, #289, #290, #292

**Goal:** Make locally-installed Ollama models discoverable, invocable, pullable, and monitorable through the platform's existing ModelRegistry and AgentProvider infrastructure.

**Architecture:** `OllamaModelSource` (priority 3) wraps the existing `OllamaClient` to auto-discover installed models. `OllamaAgentBackend` (key "ollama") extends a shared `AbstractOpenAiSdkBackend` extracted from `OpenAiAgentBackend` to invoke local models via Ollama's OpenAI-compatible API. Pull/delete/health operations extend `LlmConfigApi` and delegate to new `OllamaClient` methods.

**Tech Stack:** Java 21+, Quarkus CDI, OpenAI Java SDK 4.50.0, java.net.http.HttpClient, Mutiny Multi, JUnit 5, AssertJ, Mockito

## Global Constraints

- `platform-api/` is zero-dependency — no changes to platform-api in this plan
- `llm-config/` depends on platform-api, jackson, java.net.http only (no Quarkus runtime)
- `agent-ollama/` depends on agent-api, agent-openai (shared base), OpenAI Java SDK
- All new beans are `@ApplicationScoped` with Jandex indexing
- No `LocalModelSource` marker interface — all types use Ollama-specific naming
- Ollama host default: `http://localhost:11434`
- No quarkus:build goal on new modules (library modules)

---

## Batch 1: OllamaModelSource — discovery with no-cache-on-failure

### Task 1: OllamaModelSource + OllamaSourceStatus

**Files:**
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/OllamaModelSource.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/OllamaSourceStatus.java`
- Test: `llm-config/src/test/java/io/casehub/platform/llm/config/OllamaModelSourceTest.java`

**Interfaces:**
- Consumes: `OllamaClient.listModels(Map<String,String>)` → `ValidationResult`, `ModelSource` SPI from platform-api
- Produces: `OllamaModelSource` (implements `ModelSource`, `sourceId()` → `"local:ollama"`, `priority()` → `3`, `status()` → `OllamaSourceStatus`), `OllamaSourceStatus` record (State enum: ONLINE/OFFLINE, version, message, List<LoadedModel>), `OllamaSourceStatus.LoadedModel` record (name, sizeBytes, sizeVramBytes, quantization, expiresAt)

- [ ] **Step 1: Write OllamaSourceStatus record**

```java
// llm-config/src/main/java/io/casehub/platform/llm/config/OllamaSourceStatus.java
package io.casehub.platform.llm.config;

import java.time.Instant;
import java.util.List;

public record OllamaSourceStatus(
    State state,
    String version,
    String message,
    List<LoadedModel> loadedModels
) {

    public enum State { ONLINE, OFFLINE }

    public record LoadedModel(
        String name,
        long sizeBytes,
        long sizeVramBytes,
        String quantization,
        Instant expiresAt
    ) {}

    public static OllamaSourceStatus online(String version, List<LoadedModel> loadedModels) {
        return new OllamaSourceStatus(State.ONLINE, version,
            loadedModels.size() + " models loaded", loadedModels);
    }

    public static OllamaSourceStatus offline(String errorMessage) {
        return new OllamaSourceStatus(State.OFFLINE, null, errorMessage, List.of());
    }
}
```

- [ ] **Step 2: Write failing test for OllamaModelSource**

```java
// llm-config/src/test/java/io/casehub/platform/llm/config/OllamaModelSourceTest.java
package io.casehub.platform.llm.config;

import io.casehub.platform.api.model.CostTier;
import io.casehub.platform.api.model.ModelDescriptor;
import io.casehub.platform.api.model.ModelLocality;
import io.casehub.platform.api.model.ModelTier;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import java.util.Set;
import static org.assertj.core.api.Assertions.assertThat;

class OllamaModelSourceTest {

    private static final ModelDescriptor LLAMA3 = new ModelDescriptor(
        "llama3", "llama3", "ollama", "meta", "llama", "Llama 3",
        ModelTier.STANDARD, Set.of("text"), 0, 0,
        ModelLocality.LOCAL, CostTier.FREE, "local", Map.of());

    @Test
    void sourceIdAndPriority() {
        var source = new OllamaModelSource(stubClient(true, List.of(LLAMA3)));
        assertThat(source.sourceId()).isEqualTo("local:ollama");
        assertThat(source.priority()).isEqualTo(3);
    }

    @Test
    void refreshReturnsModelsWhenOllamaOnline() {
        var source = new OllamaModelSource(stubClient(true, List.of(LLAMA3)));
        var models = source.refresh();
        assertThat(models).hasSize(1);
        assertThat(models.get(0).id()).isEqualTo("llama3");
        assertThat(source.status().state()).isEqualTo(OllamaSourceStatus.State.ONLINE);
    }

    @Test
    void refreshReturnsEmptyWhenOllamaOffline() {
        var source = new OllamaModelSource(stubClient(false, List.of()));
        var models = source.refresh();
        assertThat(models).isEmpty();
        assertThat(source.status().state()).isEqualTo(OllamaSourceStatus.State.OFFLINE);
    }

    @Test
    void noCacheOnFailure() {
        var client = new ToggleableStubClient(List.of(LLAMA3));
        var source = new OllamaModelSource(client);

        // First refresh succeeds
        assertThat(source.refresh()).hasSize(1);

        // Ollama goes offline — returns empty, not cached
        client.setOnline(false);
        assertThat(source.refresh()).isEmpty();
        assertThat(source.status().state()).isEqualTo(OllamaSourceStatus.State.OFFLINE);
    }

    private static OllamaClient stubClient(boolean online, List<ModelDescriptor> models) {
        return new OllamaClient(q -> List.of()) {
            @Override
            public ValidationResult listModels(Map<String, String> credentials) {
                return online
                    ? ValidationResult.success(models)
                    : ValidationResult.failure("Connection refused");
            }
        };
    }

    private static class ToggleableStubClient extends OllamaClient {
        private final List<ModelDescriptor> models;
        private volatile boolean online = true;

        ToggleableStubClient(List<ModelDescriptor> models) {
            super(q -> List.of());
            this.models = models;
        }

        void setOnline(boolean online) { this.online = online; }

        @Override
        public ValidationResult listModels(Map<String, String> credentials) {
            return online
                ? ValidationResult.success(models)
                : ValidationResult.failure("Connection refused");
        }
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mvn -pl llm-config test -Dtest=OllamaModelSourceTest -Dsurefire.failIfNoSpecifiedTests=false --batch-mode`
Expected: Compilation failure — `OllamaModelSource` class does not exist

- [ ] **Step 4: Write OllamaModelSource implementation**

```java
// llm-config/src/main/java/io/casehub/platform/llm/config/OllamaModelSource.java
package io.casehub.platform.llm.config;

import io.casehub.platform.api.model.ModelDescriptor;
import io.casehub.platform.api.model.ModelSource;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.util.List;
import java.util.Map;

@ApplicationScoped
public class OllamaModelSource implements ModelSource {

    private final OllamaClient client;
    private volatile OllamaSourceStatus lastStatus;

    @Inject
    OllamaModelSource(OllamaClient client) {
        this.client = client;
        this.lastStatus = OllamaSourceStatus.offline("Not yet refreshed");
    }

    OllamaModelSource(OllamaClient client, boolean ignored) {
        this.client = client;
        this.lastStatus = OllamaSourceStatus.offline("Not yet refreshed");
    }

    @Override
    public String sourceId() { return "local:ollama"; }

    @Override
    public int priority() { return 3; }

    @Override
    public List<ModelDescriptor> refresh() {
        var result = client.listModels(Map.of());
        if (result.valid()) {
            lastStatus = OllamaSourceStatus.online(null, List.of());
            return result.models();
        }
        lastStatus = OllamaSourceStatus.offline(result.errorMessage());
        return List.of();
    }

    OllamaSourceStatus status() {
        return lastStatus;
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mvn -pl llm-config test -Dtest=OllamaModelSourceTest --batch-mode`
Expected: All 4 tests PASS

- [ ] **Step 6: Commit**

```bash
git add llm-config/src/main/java/io/casehub/platform/llm/config/OllamaModelSource.java llm-config/src/main/java/io/casehub/platform/llm/config/OllamaSourceStatus.java llm-config/src/test/java/io/casehub/platform/llm/config/OllamaModelSourceTest.java
git commit -m "feat(#289): add OllamaModelSource + OllamaSourceStatus — priority 3, no-cache-on-failure"
```

---

## Batch 2: OllamaAgentBackend — shared base class extraction + Ollama backend

### Task 2: Extract AbstractOpenAiSdkBackend from OpenAiAgentBackend

**Files:**
- Create: `agent-openai/src/main/java/io/casehub/platform/agent/openai/AbstractOpenAiSdkBackend.java`
- Modify: `agent-openai/src/main/java/io/casehub/platform/agent/openai/OpenAiAgentBackend.java`
- Modify: `agent-openai/src/main/java/io/casehub/platform/agent/openai/OpenAiEventMapper.java` — change visibility from package-private to `public`
- Test: `agent-openai/src/test/java/io/casehub/platform/agent/openai/OpenAiAgentBackendTest.java` (existing — must still pass)

**Interfaces:**
- Consumes: `AgentBackend` SPI, `AgentEvent` sealed hierarchy, OpenAI Java SDK streaming API
- Produces: `AbstractOpenAiSdkBackend` (abstract class: `invoke()`, `buildEventStream()`, `openSession()`, semaphore lifecycle, timeout coordination). Protected abstract methods: `openAiClient()` → `OpenAIClient`, `maxConcurrentSessions()` → `int`, `defaultTimeout()` → `Duration`, `defaultModel()` → `String`. `OpenAiEventMapper` becomes `public` so `agent-ollama/` can access it.

- [ ] **Step 1: Create AbstractOpenAiSdkBackend**

Extract the streaming infrastructure from `OpenAiAgentBackend` into an abstract base class. The base class owns:
- `invoke()` with semaphore gating
- `buildEventStream()` with `ChatCompletionCreateParams` construction, `StreamResponse` iteration, timeout scheduling
- `openSession()` throwing `UnsupportedOperationException`
- `shutdown()` with `@PreDestroy`
- Semaphore and ScheduledExecutorService fields
- The `streamFactory` constructor path for testing

```java
// agent-openai/src/main/java/io/casehub/platform/agent/openai/AbstractOpenAiSdkBackend.java
package io.casehub.platform.agent.openai;

import io.casehub.platform.agent.AgentBackend;
import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentProcessException;
import io.casehub.platform.agent.AgentSession;
import io.casehub.platform.agent.AgentSessionConfig;
import io.casehub.platform.agent.AgentSessionInit;
import io.casehub.platform.agent.AgentSessionLimitException;
import io.casehub.platform.agent.AgentTimeoutException;
import com.openai.core.http.StreamResponse;
import com.openai.models.ChatModel;
import com.openai.models.chat.completions.ChatCompletionChunk;
import com.openai.models.chat.completions.ChatCompletionCreateParams;
import com.openai.models.chat.completions.ChatCompletionStreamOptions;
import com.openai.models.chat.completions.ChatCompletionSystemMessageParam;
import com.openai.models.chat.completions.ChatCompletionUserMessageParam;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.infrastructure.Infrastructure;
import jakarta.annotation.PreDestroy;

import java.time.Duration;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Function;

public abstract class AbstractOpenAiSdkBackend implements AgentBackend {

    private final Semaphore semaphore;
    private final ScheduledExecutorService timeoutScheduler;
    private final Function<AgentSessionConfig, Multi<AgentEvent>> streamFactory;

    protected AbstractOpenAiSdkBackend(int maxConcurrentSessions,
                                        Function<AgentSessionConfig, Multi<AgentEvent>> streamFactory) {
        if (maxConcurrentSessions < 0) {
            throw new IllegalStateException(
                "max-concurrent-sessions must be >= 0, got " + maxConcurrentSessions);
        }
        this.semaphore = new Semaphore(
            maxConcurrentSessions == 0 ? Integer.MAX_VALUE : maxConcurrentSessions);
        this.timeoutScheduler = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "casehub-agent-" + key() + "-timeout");
            t.setDaemon(true);
            return t;
        });
        this.streamFactory = streamFactory;
    }

    protected AbstractOpenAiSdkBackend() {
        this.semaphore = null;
        this.timeoutScheduler = null;
        this.streamFactory = null;
    }

    protected abstract com.openai.client.OpenAIClient openAiClient();
    protected abstract Duration defaultTimeout();
    protected abstract String defaultModel();

    int availablePermits() {
        return semaphore.availablePermits();
    }

    @Override
    public Multi<AgentEvent> invoke(AgentSessionConfig config) {
        if (!semaphore.tryAcquire()) {
            return Multi.createFrom().failure(
                new AgentSessionLimitException(semaphore.availablePermits()));
        }
        try {
            Multi<AgentEvent> stream = streamFactory != null
                ? streamFactory.apply(config)
                : buildEventStream(config);
            return stream
                .runSubscriptionOn(Infrastructure.getDefaultWorkerPool())
                .onCompletion().invoke(semaphore::release)
                .onFailure().invoke(t -> semaphore.release())
                .onCancellation().invoke(semaphore::release);
        } catch (Exception e) {
            semaphore.release();
            return Multi.createFrom().failure(e);
        }
    }

    @Override
    public AgentSession openSession(AgentSessionInit init) {
        throw new UnsupportedOperationException(key() + " multi-turn sessions not yet implemented");
    }

    Multi<AgentEvent> buildEventStream(AgentSessionConfig config) {
        Duration effectiveTimeout = config.timeout() != null
            ? config.timeout()
            : defaultTimeout();

        String modelId = config.model() != null ? config.model() : defaultModel();
        long startTimeMs = System.currentTimeMillis();

        ChatCompletionCreateParams params = ChatCompletionCreateParams.builder()
            .model(ChatModel.of(modelId))
            .addMessage(ChatCompletionSystemMessageParam.builder()
                .content(config.systemPrompt())
                .build())
            .addMessage(ChatCompletionUserMessageParam.builder()
                .content(config.userPrompt())
                .build())
            .streamOptions(ChatCompletionStreamOptions.builder().includeUsage(true).build())
            .build();

        return Multi.createFrom().emitter(emitter -> {
            AtomicReference<StreamResponse<ChatCompletionChunk>> streamRef = new AtomicReference<>();
            AtomicBoolean timedOut = new AtomicBoolean(false);

            ScheduledFuture<?> timeoutFuture = timeoutScheduler.schedule(() -> {
                if (timedOut.compareAndSet(false, true)) {
                    StreamResponse<?> s = streamRef.get();
                    if (s != null) {
                        try { s.close(); } catch (Exception ignored) {}
                    }
                }
            }, effectiveTimeout.toMillis(), TimeUnit.MILLISECONDS);

            try {
                StreamResponse<ChatCompletionChunk> stream =
                    openAiClient().chat().completions().createStreaming(params);
                streamRef.set(stream);
                stream.stream().forEach(chunk ->
                    OpenAiEventMapper.toEvents(chunk, startTimeMs).forEach(emitter::emit));
                emitter.complete();
            } catch (Exception e) {
                if (timedOut.get()) {
                    emitter.fail(new AgentTimeoutException(effectiveTimeout));
                } else {
                    emitter.fail(new AgentProcessException(
                        java.util.Objects.toString(e.getMessage(), e.getClass().getSimpleName()), e));
                }
            } finally {
                timeoutFuture.cancel(false);
                StreamResponse<?> s = streamRef.get();
                if (s != null) {
                    try { s.close(); } catch (Exception ignored) {}
                }
            }
        });
    }

    @PreDestroy
    void shutdown() {
        if (timeoutScheduler != null) {
            timeoutScheduler.shutdownNow();
        }
    }
}
```

- [ ] **Step 2: Change OpenAiEventMapper visibility to public**

Change `final class OpenAiEventMapper` to `public final class OpenAiEventMapper` and `static List<AgentEvent> toEvents` to `public static List<AgentEvent> toEvents` in `agent-openai/src/main/java/io/casehub/platform/agent/openai/OpenAiEventMapper.java`.

- [ ] **Step 3: Rewrite OpenAiAgentBackend to extend AbstractOpenAiSdkBackend**

```java
// agent-openai/src/main/java/io/casehub/platform/agent/openai/OpenAiAgentBackend.java
package io.casehub.platform.agent.openai;

import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentSessionConfig;
import io.smallrye.mutiny.Multi;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.time.Duration;
import java.util.function.Function;

@ApplicationScoped
public class OpenAiAgentBackend extends AbstractOpenAiSdkBackend {

    private final OpenAiAgentProperties properties;
    private final com.openai.client.OpenAIClient openAiClient;

    @Inject
    public OpenAiAgentBackend(OpenAiAgentProperties properties) {
        super(properties.maxConcurrentSessions(), null);
        this.properties = properties;
        com.openai.client.okhttp.OpenAIOkHttpClient.Builder clientBuilder =
            com.openai.client.okhttp.OpenAIOkHttpClient.builder();
        properties.apiKey().ifPresent(clientBuilder::apiKey);
        this.openAiClient = clientBuilder.build();
    }

    protected OpenAiAgentBackend() {
        super();
        this.properties = null;
        this.openAiClient = null;
    }

    public OpenAiAgentBackend(OpenAiAgentProperties properties,
                              Function<AgentSessionConfig, Multi<AgentEvent>> streamFactory) {
        super(properties.maxConcurrentSessions(), streamFactory);
        this.properties = properties;
        this.openAiClient = null;
    }

    @Override public String key() { return "openai"; }
    @Override protected com.openai.client.OpenAIClient openAiClient() { return openAiClient; }
    @Override protected Duration defaultTimeout() { return properties.defaultTimeout(); }
    @Override protected String defaultModel() { return properties.defaultModel(); }
}
```

- [ ] **Step 4: Run existing OpenAiAgentBackendTest to verify no regression**

Run: `mvn -pl agent-openai test -Dtest=OpenAiAgentBackendTest --batch-mode`
Expected: All 7 tests PASS (keyIsOpenai, invokeStreamsEventsFromFactory, semaphoreReleasedOnCompletion, semaphoreReleasedOnFailure, semaphoreReleasedOnCancellation, semaphoreLimitRejectsExcessCalls, openSessionThrowsUnsupported, zeroMaxSessionsMeansUnlimited, negativeMaxSessionsThrows)

- [ ] **Step 5: Commit**

```bash
git add agent-openai/src/main/java/io/casehub/platform/agent/openai/AbstractOpenAiSdkBackend.java agent-openai/src/main/java/io/casehub/platform/agent/openai/OpenAiAgentBackend.java agent-openai/src/main/java/io/casehub/platform/agent/openai/OpenAiEventMapper.java
git commit -m "refactor(#289): extract AbstractOpenAiSdkBackend from OpenAiAgentBackend"
```

### Task 3: OllamaAgentBackend module + bean

**Files:**
- Create: `agent-ollama/pom.xml`
- Create: `agent-ollama/src/main/java/io/casehub/platform/agent/ollama/OllamaAgentBackend.java`
- Create: `agent-ollama/src/main/java/io/casehub/platform/agent/ollama/OllamaAgentProperties.java`
- Modify: `pom.xml` (root) — add `agent-ollama` module
- Test: `agent-ollama/src/test/java/io/casehub/platform/agent/ollama/OllamaAgentBackendTest.java`

**Interfaces:**
- Consumes: `AbstractOpenAiSdkBackend` from agent-openai, `OpenAiEventMapper` (public), OpenAI Java SDK
- Produces: `OllamaAgentBackend` (key: `"ollama"`, extends `AbstractOpenAiSdkBackend`), `OllamaAgentProperties` (config: host, defaultModel, defaultTimeout, maxConcurrentSessions)

- [ ] **Step 1: Create agent-ollama/pom.xml**

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

    <artifactId>casehub-platform-agent-ollama</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Agent Ollama</name>
    <description>Ollama agent backend — OpenAI-compatible local model invocation.
        No quarkus:build goal — library module.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-agent-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-agent-openai</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-arc</artifactId>
        </dependency>
        <!-- Test -->
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.mockito</groupId>
            <artifactId>mockito-core</artifactId>
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
            <plugin>
                <groupId>io.quarkus</groupId>
                <artifactId>quarkus-maven-plugin</artifactId>
                <version>${quarkus.platform.version}</version>
                <extensions>true</extensions>
                <executions>
                    <execution>
                        <goals>
                            <goal>generate-code</goal>
                            <goal>generate-code-tests</goal>
                        </goals>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Create OllamaAgentProperties**

```java
// agent-ollama/src/main/java/io/casehub/platform/agent/ollama/OllamaAgentProperties.java
package io.casehub.platform.agent.ollama;

import io.smallrye.config.ConfigMapping;
import io.smallrye.config.WithDefault;
import java.time.Duration;

@ConfigMapping(prefix = "casehub.platform.agent.ollama")
public interface OllamaAgentProperties {

    @WithDefault("http://localhost:11434")
    String host();

    @WithDefault("llama3")
    String defaultModel();

    @WithDefault("PT120S")
    Duration defaultTimeout();

    @WithDefault("4")
    int maxConcurrentSessions();
}
```

- [ ] **Step 3: Write failing test for OllamaAgentBackend**

```java
// agent-ollama/src/test/java/io/casehub/platform/agent/ollama/OllamaAgentBackendTest.java
package io.casehub.platform.agent.ollama;

import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentSessionConfig;
import io.casehub.platform.agent.AgentSessionInit;
import io.smallrye.mutiny.Multi;
import org.junit.jupiter.api.Test;

import java.time.Duration;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class OllamaAgentBackendTest {

    @Test
    void keyIsOllama() {
        var backend = backend(1, config -> Multi.createFrom().empty());
        assertThat(backend.key()).isEqualTo("ollama");
    }

    @Test
    void invokeStreamsEventsFromFactory() {
        var backend = backend(4, config -> Multi.createFrom().items(
            new AgentEvent.TextDelta("hello "),
            new AgentEvent.TextDelta("local")));

        var config = AgentSessionConfig.of("sys", "user", "llama3");
        var events = backend.invoke(config).collect().asList()
            .await().atMost(Duration.ofSeconds(5));

        assertThat(events).hasSize(2);
        assertThat(((AgentEvent.TextDelta) events.get(0)).text()).isEqualTo("hello ");
        assertThat(((AgentEvent.TextDelta) events.get(1)).text()).isEqualTo("local");
    }

    @Test
    void semaphoreReleasedOnCompletion() {
        var backend = backend(1, config ->
            Multi.createFrom().item(new AgentEvent.TextDelta("ok")));

        backend.invoke(AgentSessionConfig.of("sys", "user"))
            .collect().asList().await().atMost(Duration.ofSeconds(5));

        assertThat(backend.availablePermits()).isEqualTo(1);
    }

    @Test
    void openSessionThrowsUnsupported() {
        var backend = backend(1, config -> Multi.createFrom().empty());
        assertThatThrownBy(() -> backend.openSession(AgentSessionInit.of("sys")))
            .isInstanceOf(UnsupportedOperationException.class);
    }

    private static OllamaAgentBackend backend(int maxSessions,
            java.util.function.Function<AgentSessionConfig, Multi<AgentEvent>> factory) {
        var props = mock(OllamaAgentProperties.class);
        when(props.host()).thenReturn("http://localhost:11434");
        when(props.defaultModel()).thenReturn("llama3");
        when(props.defaultTimeout()).thenReturn(Duration.ofMinutes(2));
        when(props.maxConcurrentSessions()).thenReturn(maxSessions);
        return new OllamaAgentBackend(props, factory);
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `mvn -pl agent-ollama test -Dtest=OllamaAgentBackendTest -Dsurefire.failIfNoSpecifiedTests=false --batch-mode`
Expected: Compilation failure — `OllamaAgentBackend` class does not exist

- [ ] **Step 5: Write OllamaAgentBackend implementation**

```java
// agent-ollama/src/main/java/io/casehub/platform/agent/ollama/OllamaAgentBackend.java
package io.casehub.platform.agent.ollama;

import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentSessionConfig;
import io.casehub.platform.agent.openai.AbstractOpenAiSdkBackend;
import io.smallrye.mutiny.Multi;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.time.Duration;
import java.util.function.Function;

@ApplicationScoped
public class OllamaAgentBackend extends AbstractOpenAiSdkBackend {

    private final OllamaAgentProperties properties;
    private final com.openai.client.OpenAIClient openAiClient;

    @Inject
    public OllamaAgentBackend(OllamaAgentProperties properties) {
        super(properties.maxConcurrentSessions(), null);
        this.properties = properties;
        this.openAiClient = com.openai.client.okhttp.OpenAIOkHttpClient.builder()
            .baseUrl(properties.host() + "/v1/")
            .apiKey("ollama")
            .build();
    }

    protected OllamaAgentBackend() {
        super();
        this.properties = null;
        this.openAiClient = null;
    }

    public OllamaAgentBackend(OllamaAgentProperties properties,
                              Function<AgentSessionConfig, Multi<AgentEvent>> streamFactory) {
        super(properties.maxConcurrentSessions(), streamFactory);
        this.properties = properties;
        this.openAiClient = null;
    }

    @Override public String key() { return "ollama"; }
    @Override protected com.openai.client.OpenAIClient openAiClient() { return openAiClient; }
    @Override protected Duration defaultTimeout() { return properties.defaultTimeout(); }
    @Override protected String defaultModel() { return properties.defaultModel(); }
}
```

- [ ] **Step 6: Add agent-ollama module to root pom.xml**

Add `<module>agent-ollama</module>` after `<module>agent-openai</module>` in the root `pom.xml`.

- [ ] **Step 7: Run test to verify it passes**

Run: `mvn -pl agent-ollama test -Dtest=OllamaAgentBackendTest --batch-mode`
Expected: All 4 tests PASS

- [ ] **Step 8: Run full build to verify no regressions**

Run: `mvn --batch-mode install -pl agent-openai,agent-ollama -am`
Expected: BUILD SUCCESS — both modules compile and test

- [ ] **Step 9: Commit**

```bash
git add agent-ollama/ pom.xml
git commit -m "feat(#289): add agent-ollama module — OllamaAgentBackend extending AbstractOpenAiSdkBackend"
```

---

## Batch 3: OllamaClient extensions + pull/delete/health in LlmConfigApi

### Task 4: Extend OllamaClient with ps(), version(), pull(), delete(), isReachable()

**Files:**
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/OllamaClient.java`
- Test: `llm-config/src/test/java/io/casehub/platform/llm/config/OllamaClientExtensionsTest.java`

**Interfaces:**
- Consumes: java.net.http.HttpClient, Ollama REST API (`GET /`, `GET /api/ps`, `GET /api/version`, `POST /api/pull`, `DELETE /api/delete`)
- Produces: `OllamaClient.isReachable()` → `boolean`, `OllamaClient.version()` → `String`, `OllamaClient.ps()` → `List<OllamaSourceStatus.LoadedModel>`, `OllamaClient.pull(String modelRef)` → `Multi<PullProgress>` (streaming), `OllamaClient.delete(String modelName)` → `boolean`

- [ ] **Step 1: Write failing tests for OllamaClient extensions**

```java
// llm-config/src/test/java/io/casehub/platform/llm/config/OllamaClientExtensionsTest.java
package io.casehub.platform.llm.config;

import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class OllamaClientExtensionsTest {

    @Test
    void parsePsResponseExtractsLoadedModels() {
        String json = """
            {"models":[{
              "name":"llama3:latest",
              "model":"llama3:latest",
              "size":4661224676,
              "size_vram":4661224676,
              "digest":"sha256:abc123",
              "details":{"quantization_level":"Q4_0"},
              "expires_at":"2026-09-13T02:00:00Z"
            }]}""";
        var client = new OllamaClient(q -> List.of());
        var models = client.parsePsResponse(json);
        assertThat(models).hasSize(1);
        assertThat(models.get(0).name()).isEqualTo("llama3:latest");
        assertThat(models.get(0).sizeVramBytes()).isEqualTo(4661224676L);
        assertThat(models.get(0).quantization()).isEqualTo("Q4_0");
        assertThat(models.get(0).expiresAt()).isNotNull();
    }

    @Test
    void parsePsResponseHandlesEmptyModels() {
        var client = new OllamaClient(q -> List.of());
        var models = client.parsePsResponse("{\"models\":[]}");
        assertThat(models).isEmpty();
    }

    @Test
    void parsePsResponseHandlesMalformedJson() {
        var client = new OllamaClient(q -> List.of());
        var models = client.parsePsResponse("not json");
        assertThat(models).isEmpty();
    }

    @Test
    void parseVersionResponse() {
        var client = new OllamaClient(q -> List.of());
        var version = client.parseVersionResponse("{\"version\":\"0.33.3\"}");
        assertThat(version).isEqualTo("0.33.3");
    }

    @Test
    void parseVersionResponseHandlesMissing() {
        var client = new OllamaClient(q -> List.of());
        var version = client.parseVersionResponse("{}");
        assertThat(version).isNull();
    }

    @Test
    void parsePullProgressLine() {
        String line = "{\"status\":\"pulling abc123\",\"digest\":\"sha256:abc123\",\"total\":4000000000,\"completed\":1500000000}";
        var client = new OllamaClient(q -> List.of());
        var progress = client.parsePullProgressLine(line);
        assertThat(progress).isNotNull();
        assertThat(progress.totalBytes()).isEqualTo(4000000000L);
        assertThat(progress.completedBytes()).isEqualTo(1500000000L);
        assertThat(progress.digest()).isEqualTo("sha256:abc123");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl llm-config test -Dtest=OllamaClientExtensionsTest -Dsurefire.failIfNoSpecifiedTests=false --batch-mode`
Expected: Compilation failure — `parsePsResponse`, `parseVersionResponse`, `parsePullProgressLine` methods do not exist

- [ ] **Step 3: Add parsing methods to OllamaClient**

Add to `OllamaClient.java`:

```java
List<OllamaSourceStatus.LoadedModel> parsePsResponse(String json) {
    try {
        JsonNode root = MAPPER.readTree(json);
        JsonNode models = root.path("models");
        if (!models.isArray()) return List.of();

        List<OllamaSourceStatus.LoadedModel> result = new ArrayList<>();
        for (JsonNode node : models) {
            String name = node.path("name").asText();
            long size = node.path("size").asLong(0);
            long sizeVram = node.path("size_vram").asLong(0);
            String quant = node.path("details").path("quantization_level").asText(null);
            Instant expiresAt = node.has("expires_at")
                ? Instant.parse(node.get("expires_at").asText())
                : null;
            result.add(new OllamaSourceStatus.LoadedModel(name, size, sizeVram, quant, expiresAt));
        }
        return result;
    } catch (Exception e) {
        return List.of();
    }
}

String parseVersionResponse(String json) {
    try {
        JsonNode root = MAPPER.readTree(json);
        return root.has("version") ? root.get("version").asText() : null;
    } catch (Exception e) {
        return null;
    }
}

PullProgressData parsePullProgressLine(String line) {
    try {
        JsonNode node = MAPPER.readTree(line);
        String status = node.path("status").asText("");
        String digest = node.path("digest").asText(null);
        long total = node.path("total").asLong(0);
        long completed = node.path("completed").asLong(0);
        return new PullProgressData(status, digest, total, completed);
    } catch (Exception e) {
        return null;
    }
}

record PullProgressData(String status, String digest, long totalBytes, long completedBytes) {}
```

Add import for `java.time.Instant`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -pl llm-config test -Dtest=OllamaClientExtensionsTest --batch-mode`
Expected: All 6 tests PASS

- [ ] **Step 5: Commit**

```bash
git add llm-config/src/main/java/io/casehub/platform/llm/config/OllamaClient.java llm-config/src/test/java/io/casehub/platform/llm/config/OllamaClientExtensionsTest.java
git commit -m "feat(#289): extend OllamaClient — ps, version, pull progress parsing"
```

### Task 5: Pull/delete/health API in LlmConfigApi + LlmConfigService

**Files:**
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/PullRequest.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/PullOperation.java`
- Create: `llm-config/src/main/java/io/casehub/platform/llm/config/PullProgress.java`
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigApi.java`
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigService.java`
- Test: `llm-config/src/test/java/io/casehub/platform/llm/config/LlmConfigServiceLocalTest.java`

**Interfaces:**
- Consumes: `OllamaModelSource.status()`, `OllamaClient.parsePsResponse()`, `OllamaClient.parseVersionResponse()`, `OllamaClient.PullProgressData`
- Produces: `PullRequest` (record: modelRef), `PullOperation` (record: operationId, modelRef, PullStatus), `PullOperation.PullStatus` (enum: PULLING, COMPLETED, FAILED, CANCELLED), `PullProgress` (record: operationId, modelRef, status, totalBytes, completedBytes, digest, errorMessage). `LlmConfigApi` gains: `ollamaStatus()`, `pullModel(PullRequest)`, `pullStatus(String)`, `cancelPull(String)`, `deleteModel(String)`.

- [ ] **Step 1: Create data records**

```java
// llm-config/src/main/java/io/casehub/platform/llm/config/PullRequest.java
package io.casehub.platform.llm.config;

public record PullRequest(String modelRef) {}
```

```java
// llm-config/src/main/java/io/casehub/platform/llm/config/PullOperation.java
package io.casehub.platform.llm.config;

public record PullOperation(String operationId, String modelRef, PullStatus status) {
    public enum PullStatus { PULLING, COMPLETED, FAILED, CANCELLED }
}
```

```java
// llm-config/src/main/java/io/casehub/platform/llm/config/PullProgress.java
package io.casehub.platform.llm.config;

public record PullProgress(
    String operationId,
    String modelRef,
    PullOperation.PullStatus status,
    long totalBytes,
    long completedBytes,
    String digest,
    String errorMessage
) {}
```

- [ ] **Step 2: Add API methods to LlmConfigApi**

Add to `LlmConfigApi.java`:

```java
@PlatformQuery("Ollama runtime status — reachability, version, loaded models with VRAM")
OllamaSourceStatus ollamaStatus();

@PlatformMutation("Pull a model into Ollama — accepts library names or hf.co/ references")
PullOperation pullModel(PullRequest request);

@PlatformQuery("Check pull operation progress")
PullProgress pullStatus(String operationId);

@PlatformMutation("Cancel an in-progress pull operation")
void cancelPull(String operationId);

@PlatformMutation("Delete a model from Ollama")
void deleteModel(String modelName);
```

- [ ] **Step 3: Write failing test for LlmConfigService local operations**

```java
// llm-config/src/test/java/io/casehub/platform/llm/config/LlmConfigServiceLocalTest.java
package io.casehub.platform.llm.config;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class LlmConfigServiceLocalTest {

    private LlmConfigService service;
    private OllamaModelSource ollamaSource;

    @BeforeEach
    void setUp() {
        var stubClient = new OllamaClient(q -> java.util.List.of()) {
            @Override
            public ValidationResult listModels(java.util.Map<String, String> credentials) {
                return ValidationResult.success(java.util.List.of());
            }
        };
        ollamaSource = new OllamaModelSource(stubClient, true);
        ollamaSource.refresh();

        service = new LlmConfigService(
            new LlmConfigServiceTest.StubPrincipal("tenant-1"),
            new ConfiguredModelSourceManager(
                new io.casehub.platform.model.InMemoryModelRegistry(),
                new InMemoryLlmCredentialStore()),
            new InMemoryLlmCredentialStore(),
            new LlmConfigServiceTest.StubPreferenceStore(),
            java.util.List.of(),
            java.util.List.of(),
            ollamaSource);
    }

    @Test
    void ollamaStatusReflectsSourceState() {
        var status = service.ollamaStatus();
        assertThat(status).isNotNull();
        assertThat(status.state()).isEqualTo(OllamaSourceStatus.State.ONLINE);
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `mvn -pl llm-config test -Dtest=LlmConfigServiceLocalTest -Dsurefire.failIfNoSpecifiedTests=false --batch-mode`
Expected: Compilation failure — `ollamaStatus()` method does not exist on `LlmConfigService`

- [ ] **Step 5: Implement ollamaStatus() in LlmConfigService**

Add `OllamaModelSource` as a constructor parameter (CDI `@Inject` and test constructor). Add the `ollamaStatus()` implementation that delegates to `ollamaSource.status()`. Also add stub implementations for `pullModel()`, `pullStatus()`, `cancelPull()`, `deleteModel()` — the pull lifecycle internals (background thread, ConcurrentHashMap tracking, HTTP connection management) will be wired in a follow-up commit once the API surface compiles and the status test passes.

- [ ] **Step 6: Run test to verify it passes**

Run: `mvn -pl llm-config test -Dtest=LlmConfigServiceLocalTest --batch-mode`
Expected: PASS

- [ ] **Step 7: Run full llm-config test suite for regressions**

Run: `mvn -pl llm-config test --batch-mode`
Expected: All existing tests pass + new test passes

- [ ] **Step 8: Commit**

```bash
git add llm-config/src/main/java/io/casehub/platform/llm/config/PullRequest.java llm-config/src/main/java/io/casehub/platform/llm/config/PullOperation.java llm-config/src/main/java/io/casehub/platform/llm/config/PullProgress.java llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigApi.java llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigService.java llm-config/src/test/java/io/casehub/platform/llm/config/LlmConfigServiceLocalTest.java
git commit -m "feat(#289): add pull/delete/health API to LlmConfigApi + ollamaStatus()"
```

### Task 6: Pull lifecycle implementation — background tracking + cancel

**Files:**
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigService.java`
- Modify: `llm-config/src/main/java/io/casehub/platform/llm/config/OllamaClient.java`
- Test: `llm-config/src/test/java/io/casehub/platform/llm/config/PullLifecycleTest.java`

**Interfaces:**
- Consumes: `OllamaClient.PullProgressData`, `PullRequest`, `PullOperation`, `PullProgress`
- Produces: Full pull lifecycle: `pullModel()` starts a virtual thread that reads Ollama's streaming pull response, updates a `ConcurrentHashMap<operationId, PullProgress>`, and triggers registry refresh on completion. `cancelPull()` closes the tracked HTTP connection. `pullStatus()` reads from the map.

- [ ] **Step 1: Write failing test for pull lifecycle**

```java
// llm-config/src/test/java/io/casehub/platform/llm/config/PullLifecycleTest.java
package io.casehub.platform.llm.config;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class PullLifecycleTest {

    @Test
    void pullModelReturnsOperationWithPullingStatus() {
        var service = buildService();
        var op = service.pullModel(new PullRequest("llama3"));
        assertThat(op.operationId()).isNotNull();
        assertThat(op.modelRef()).isEqualTo("llama3");
        assertThat(op.status()).isEqualTo(PullOperation.PullStatus.PULLING);
    }

    @Test
    void pullStatusReturnsProgressForKnownOperation() {
        var service = buildService();
        var op = service.pullModel(new PullRequest("llama3"));
        var progress = service.pullStatus(op.operationId());
        assertThat(progress).isNotNull();
        assertThat(progress.operationId()).isEqualTo(op.operationId());
        assertThat(progress.modelRef()).isEqualTo("llama3");
    }

    @Test
    void pullStatusReturnsNullForUnknownOperation() {
        var service = buildService();
        var progress = service.pullStatus("nonexistent");
        assertThat(progress).isNull();
    }

    @Test
    void cancelPullUpdatesStatusToCancelled() {
        var service = buildService();
        var op = service.pullModel(new PullRequest("llama3"));
        service.cancelPull(op.operationId());
        var progress = service.pullStatus(op.operationId());
        assertThat(progress.status()).isEqualTo(PullOperation.PullStatus.CANCELLED);
    }

    private LlmConfigService buildService() {
        // Construct with a stub OllamaClient that simulates slow pull
        // (returns a blocking InputStream that never completes)
        var stubClient = new OllamaClient(q -> java.util.List.of()) {
            @Override
            public ValidationResult listModels(java.util.Map<String, String> credentials) {
                return ValidationResult.success(java.util.List.of());
            }
        };
        var ollamaSource = new OllamaModelSource(stubClient, true);

        return new LlmConfigService(
            new LlmConfigServiceTest.StubPrincipal("tenant-1"),
            new ConfiguredModelSourceManager(
                new io.casehub.platform.model.InMemoryModelRegistry(),
                new InMemoryLlmCredentialStore()),
            new InMemoryLlmCredentialStore(),
            new LlmConfigServiceTest.StubPreferenceStore(),
            java.util.List.of(),
            java.util.List.of(),
            ollamaSource);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl llm-config test -Dtest=PullLifecycleTest -Dsurefire.failIfNoSpecifiedTests=false --batch-mode`
Expected: Failures — `pullModel()` returns stub/null, `cancelPull()` not wired

- [ ] **Step 3: Implement pull lifecycle in LlmConfigService**

Add to `LlmConfigService`:
- `ConcurrentHashMap<String, PullProgress> pullOperations` field
- `ConcurrentHashMap<String, java.net.http.HttpClient> pullConnections` field (for cancel)
- `pullModel()`: generates UUID operation ID, stores initial `PullProgress` with PULLING status, starts a virtual thread that calls Ollama `POST /api/pull` with streaming, reads progress lines, updates the map, sets COMPLETED/FAILED on finish
- `pullStatus()`: reads from `pullOperations` map
- `cancelPull()`: retrieves the `HttpClient` from `pullConnections`, shuts it down (interrupting the streaming read), updates status to CANCELLED
- `deleteModel()`: calls Ollama `DELETE /api/delete` with `{"name": modelName}`

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -pl llm-config test -Dtest=PullLifecycleTest --batch-mode`
Expected: All 4 tests PASS

- [ ] **Step 5: Run full test suite**

Run: `mvn -pl llm-config test --batch-mode`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigService.java llm-config/src/main/java/io/casehub/platform/llm/config/OllamaClient.java llm-config/src/test/java/io/casehub/platform/llm/config/PullLifecycleTest.java
git commit -m "feat(#289): implement pull lifecycle — background tracking, cancel, delete"
```

---

## Batch 4: Integration verification + CLAUDE.md update

### Task 7: Full build verification + CLAUDE.md module table update

**Files:**
- Modify: `CLAUDE.md` — add `agent-ollama/` module entry to Modules table

**Interfaces:**
- Consumes: All prior tasks
- Produces: Updated CLAUDE.md, verified full build

- [ ] **Step 1: Run full project build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile and test, including new `agent-ollama/`

- [ ] **Step 2: Update CLAUDE.md modules table**

Add after the `agent-codex/` entry in the Modules table:

```markdown
| `agent-ollama/` | `casehub-platform-agent-ollama` | `OllamaAgentBackend @ApplicationScoped implements AgentBackend` (key: "ollama") — local model invocation via Ollama's OpenAI-compatible API. Extends `AbstractOpenAiSdkBackend` from agent-openai. Config: casehub.platform.agent.ollama.{host, default-model, default-timeout, max-concurrent-sessions}. No quarkus:build goal |
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(#289): add agent-ollama module to CLAUDE.md"
```

## References

- [2026-09-13-local-model-sources-design.md] — design spec this plan implements
- [289-decisions.md] — 8 design decisions (D1–D8)
- `llm-config/src/main/java/io/casehub/platform/llm/config/OllamaClient.java` — existing Ollama HTTP client
- `agent-openai/src/main/java/io/casehub/platform/agent/openai/OpenAiAgentBackend.java` — base for extraction
- `agent-openai/src/main/java/io/casehub/platform/agent/openai/OpenAiEventMapper.java` — shared event mapping
- `agent-openai/src/test/java/io/casehub/platform/agent/openai/OpenAiAgentBackendTest.java` — regression test
- `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigApi.java` — API to extend
- `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigService.java` — service to extend
- GE-20260614-337397 — langchain4j-ollama CDI clash (avoid langchain4j)
- GE-20260614-1ece0f — Ollama timeout too short for local LLMs (120s default)
- GitHub #289 — focal issue
- GitHub #285 — parent epic
