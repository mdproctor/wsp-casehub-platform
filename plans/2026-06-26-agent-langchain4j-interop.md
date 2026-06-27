# Agent–LangChain4j Interop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement bidirectional Agent–LangChain4j interop (#105), MissingTenancyExceptionMapper (#115), and AgentProvider design rationale docs (#114) on a single branch.

**Architecture:** Three sequential deliverables: (1) ExceptionMapper in oidc module, (2) README documentation in agent-api, (3) new agent-langchain4j module with bidirectional ChatModel↔AgentProvider adapters, replacing agent-claude-langchain4j. TDD throughout.

**Tech Stack:** Java 21, Quarkus 3.32.2, LangChain4j 1.14.1, Mutiny, ArC CDI, JUnit 5, AssertJ, Mockito, Awaitility

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA, no casehubio imports
- `agent-api/` depends only on Mutiny — no Quarkus, no CDI
- Every commit references an issue
- Java 21 language level, `-parameters` javac flag enabled
- Jandex index required on all modules with CDI beans
- No quarkus:build goal on library modules (generate-code + generate-code-tests only)
- All tests use AssertJ assertions, not JUnit assertions
- Use `doReturn().when()` for generic methods (Mockito type safety)

---

### Task 1: MissingTenancyExceptionMapper (#115)

**Files:**
- Create: `oidc/src/main/java/io/casehub/platform/oidc/MissingTenancyExceptionMapper.java`
- Create: `oidc/src/test/java/io/casehub/platform/oidc/MissingTenancyExceptionMapperTest.java`

**Interfaces:**
- Consumes: `MissingTenancyException` from `platform-api` (has `actorId()` accessor)
- Produces: JAX-RS `ExceptionMapper<MissingTenancyException>` — auto-discovered by RESTEasy

- [ ] **Step 1: Write the failing test**

```java
package io.casehub.platform.oidc;

import io.casehub.platform.api.identity.MissingTenancyException;
import jakarta.json.Json;
import jakarta.json.JsonObject;
import jakarta.ws.rs.core.Response;
import org.junit.jupiter.api.Test;

import java.io.StringReader;

import static org.assertj.core.api.Assertions.*;

class MissingTenancyExceptionMapperTest {

    private final MissingTenancyExceptionMapper mapper = new MissingTenancyExceptionMapper();

    @Test
    void toResponse_returns403() {
        Response response = mapper.toResponse(new MissingTenancyException("alice"));
        assertThat(response.getStatus()).isEqualTo(403);
    }

    @Test
    void toResponse_bodyContainsErrorField() {
        Response response = mapper.toResponse(new MissingTenancyException("alice"));
        JsonObject body = Json.createReader(new StringReader((String) response.getEntity())).readObject();
        assertThat(body.getString("error")).isEqualTo("missing_tenancy");
    }

    @Test
    void toResponse_bodyContainsActorId() {
        Response response = mapper.toResponse(new MissingTenancyException("bob"));
        JsonObject body = Json.createReader(new StringReader((String) response.getEntity())).readObject();
        assertThat(body.getString("actorId")).isEqualTo("bob");
    }

    @Test
    void toResponse_bodyContainsMessage() {
        Response response = mapper.toResponse(new MissingTenancyException("alice"));
        JsonObject body = Json.createReader(new StringReader((String) response.getEntity())).readObject();
        assertThat(body.getString("message")).isEqualTo("JWT does not contain a tenancyId claim");
    }

    @Test
    void toResponse_contentTypeIsJson() {
        Response response = mapper.toResponse(new MissingTenancyException("alice"));
        assertThat(response.getMediaType().toString()).isEqualTo("application/json");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl oidc -Dtest=MissingTenancyExceptionMapperTest`
Expected: FAIL — `MissingTenancyExceptionMapper` class does not exist

- [ ] **Step 3: Write the implementation**

```java
package io.casehub.platform.oidc;

import io.casehub.platform.api.identity.MissingTenancyException;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import jakarta.ws.rs.ext.ExceptionMapper;
import jakarta.ws.rs.ext.Provider;

@Provider
public class MissingTenancyExceptionMapper implements ExceptionMapper<MissingTenancyException> {

    @Override
    public Response toResponse(MissingTenancyException exception) {
        String body = "{\"error\":\"missing_tenancy\","
            + "\"message\":\"JWT does not contain a tenancyId claim\","
            + "\"actorId\":\"" + exception.actorId().replace("\"", "\\\"") + "\"}";
        return Response.status(Response.Status.FORBIDDEN)
            .type(MediaType.APPLICATION_JSON_TYPE)
            .entity(body)
            .build();
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl oidc -Dtest=MissingTenancyExceptionMapperTest`
Expected: All 5 tests PASS

- [ ] **Step 5: Run full oidc module tests**

Run: `mvn --batch-mode test -pl oidc`
Expected: All tests PASS (existing OidcCurrentPrincipalTest + new MissingTenancyExceptionMapperTest)

- [ ] **Step 6: Commit**

```
feat(platform#115): MissingTenancyExceptionMapper — 403 + JSON body

Maps MissingTenancyException to HTTP 403 Forbidden with JSON error body
containing error code, message, and actorId from the exception. Placed in
oidc/ module — consumers get it automatically by classpath presence.

Closes casehubio/platform#115
```

---

### Task 2: AgentProvider design rationale documentation (#114)

**Files:**
- Create: `agent-api/README.md`

**Interfaces:**
- Consumes: Nothing
- Produces: Documentation consumed by developers reading the module

- [ ] **Step 1: Write the README**

```markdown
# casehub-platform-agent-api

AgentProvider SPI and API types for AI agent invocation.

## Why AgentProvider Exists

AgentProvider is the platform's agent SPI — the contract consumers inject to invoke AI agents.

LangChain4j's `ChatModel`/`StreamingChatModel` is the de facto standard Java LLM interface. AgentProvider does not replace it. AgentProvider exists because some providers have **native SDK advantages that LangChain4j can't express**:

- **Claude CLI prompt caching** — the CLI manages `cache_control` breakpoints transparently at the Anthropic API level. LangChain4j's `SystemMessage` has no `cache_control` field, and LangChain4j mediates every call, so even a native SDK behind `doChat()` loses caching control.
- **MCP server wiring** — Claude CLI accepts MCP server configurations (stdio, SSE, HTTP) per invocation. No LangChain4j equivalent.
- **Subprocess lifecycle** — Claude CLI runs as a managed subprocess with drain-on-close, semaphore-based concurrency limits, and wall-clock timeout enforcement.

Platform infrastructure (Mutiny reactive streaming, typed error taxonomy, session lifecycle management) could be layered on top of ChatModel. AgentProvider packages these coherently but they are not capabilities LangChain4j lacks.

## Two Implementation Strategies

### 1. Native SDK (bypass LangChain4j)

For providers where the native SDK offers advantages. `ClaudeAgentProvider` is the current example — it shells out to the Claude CLI subprocess, preserving prompt caching and MCP support.

### 2. LangChain4j-backed (default)

For everything else. `ChatModelAgentProvider` (in `agent-langchain4j/`) wraps any LangChain4j `ChatModel` or `StreamingChatModel` as an AgentProvider. OpenAI, Gemini, Ollama, Mistral — any model with a LangChain4j implementation works with zero provider-specific code.

## CDI Tier Structure

**AgentProvider tiers:**

| Tier | Bean | Annotation | Activates when |
|------|------|------------|----------------|
| 0 | `NoOpAgentProvider` | `@DefaultBean` | Nothing else on classpath |
| 1 | `ChatModelAgentProvider` | `@Alternative @Priority(1)` | LangChain4j ChatModel available, no native provider |
| 10 | `ClaudeAgentProvider` | `@Alternative @Priority(10)` | Claude on classpath (always wins) |

**ChatModel tiers (separate — `@DefaultBean` system):**

| Bean | Annotation | When selected |
|------|------------|---------------|
| quarkus-langchain4j ChatModel | `@DefaultBean` (implicit `@Priority(0)`) | Only non-platform ChatModel on classpath |
| `AgentProviderChatModel` | `@DefaultBean @Priority(10)` | Beats raw ChatModel when both exist; suppressed by consumer-provided non-`@DefaultBean` |

## Interop with Engine

Engine code uses `ChatModel` directly (for JSON mode, tool use, parameters). The generic `AgentProviderChatModel` adapter (in `agent-langchain4j/`) wraps any AgentProvider as a ChatModel, supporting JSON format via prompt engineering.

## AgentProviderChatModel — Restricted Adapter

`AgentProviderChatModel` intentionally does not implement the full `ChatModel` contract. AgentProvider owns session history — passing `AiMessage` from outside is a caller error.

**Supported:** Single-shot calls with `SystemMessage` + `UserMessage`.
**Unsupported:** AI Services with external `ChatMemory`, any client managing message history with `AiMessage`.

The adapter throws `IllegalArgumentException` on `AiMessage` with a message explaining why.

## API Types

- `AgentProvider` — `invoke()` (single-shot streaming) + `openSession()` (multi-turn)
- `AgentSession` — serial multi-turn: `query()`, `interrupt()`, `close()`
- `AgentSessionConfig` — single-shot config: systemPrompt, userPrompt, mcpServers, timeout, correlationId
- `AgentSessionInit` — session-open config: systemPrompt, mcpServers, timeout, correlationId
- `AgentEvent` — sealed: `TextDelta` only (tool calls are opaque)
- `AgentMcpServer` — sealed: `Stdio`, `Sse`, `Http`
- Exceptions: `AgentTimeoutException`, `AgentProcessException`, `AgentSessionLimitException`
```

- [ ] **Step 2: Commit**

```
docs(platform#114): AgentProvider design rationale in agent-api README

Documents why AgentProvider exists alongside LangChain4j ChatModel: native
SDK advantages (Claude CLI caching, MCP) that LangChain4j can't express.
Two implementation strategies (native vs LangChain4j-backed), CDI tier
structure, restricted adapter constraints.

Closes casehubio/platform#114
```

---

### Task 3: Create agent-langchain4j module scaffold + AgentProviderChatModel

This is the first code task for #105. Creates the module, POM, and the AgentProvider → ChatModel direction (replacing ClaudeAgentChatModel).

**Files:**
- Create: `agent-langchain4j/pom.xml`
- Create: `agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentLangchain4jProperties.java`
- Create: `agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/AgentProviderChatModel.java`
- Create: `agent-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/AgentProviderChatModelTest.java`
- Modify: `pom.xml` (parent) — add module, remove agent-claude-langchain4j

**Interfaces:**
- Consumes: `AgentProvider` (inject), `AgentSessionConfig`, `AgentEvent.TextDelta`, `Instance<ChatModelListener>`
- Produces: `ChatModel`, `StreamingChatModel` CDI beans (`@DefaultBean @Priority(10)`)

- [ ] **Step 1: Create module POM**

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

    <artifactId>casehub-platform-agent-langchain4j</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Agent LangChain4j</name>
    <description>Bidirectional LangChain4j interop: ChatModelAgentProvider wraps any ChatModel as
        AgentProvider; AgentProviderChatModel wraps any AgentProvider as ChatModel.
        Replaces agent-claude-langchain4j. No quarkus:build goal — library module.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-agent-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>dev.langchain4j</groupId>
            <artifactId>langchain4j-core</artifactId>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-arc</artifactId>
        </dependency>
        <!-- Test -->
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-junit5</artifactId>
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
        <dependency>
            <groupId>org.awaitility</groupId>
            <artifactId>awaitility</artifactId>
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

- [ ] **Step 2: Create AgentLangchain4jProperties**

```java
package io.casehub.platform.agent.langchain4j;

import io.smallrye.config.ConfigMapping;
import io.smallrye.config.WithDefault;
import java.time.Duration;

@ConfigMapping(prefix = "casehub.platform.agent.langchain4j")
public interface AgentLangchain4jProperties {

    @WithDefault("PT30S")
    Duration closeTimeout();

    @WithDefault("20")
    int sessionMemoryWindowSize();
}
```

- [ ] **Step 3: Write failing tests for AgentProviderChatModel**

Create `agent-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/AgentProviderChatModelTest.java`. This is a large test class — adapted from `ClaudeAgentChatModelTest` but with key differences:

1. Uses `invoke()` not `openSession()` for single-shot
2. Returns `ModelProvider.OTHER` not `ANTHROPIC`
3. JSON format prompt-engineers instead of throwing
4. `@DefaultBean @Priority(10)` not `@Alternative`

The test class uses plain unit tests (no CDI container — the bean is constructed directly with mocked dependencies). Full test code follows the pattern in `ClaudeAgentChatModelTest` with these adaptations:

- `fakeProvider()` returns an `AgentProvider` whose `invoke()` returns the given Multi (not `openSession()`)
- `provider()` asserts `ModelProvider.OTHER`
- JSON format tests verify prompt engineering output instead of `UnsupportedFeatureException`
- Session close tests are removed (invoke-based, no session to close)

Write tests covering: provider() returns OTHER, supportedCapabilities() empty, listeners injected, blocking happy path, blocking system prompt extraction, blocking no user message throws, blocking AiMessage throws, blocking multiple UserMessages throws, blocking multimodal throws, blocking AgentTimeoutException propagates, blocking JSON format prompt-engineers schema, streaming happy path, streaming error routing, streaming JSON format prompt-engineers schema.

- [ ] **Step 4: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=AgentProviderChatModelTest`
Expected: FAIL — `AgentProviderChatModel` class does not exist

- [ ] **Step 5: Write AgentProviderChatModel**

```java
package io.casehub.platform.agent.langchain4j;

import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.data.message.ChatMessage;
import dev.langchain4j.data.message.SystemMessage;
import dev.langchain4j.data.message.UserMessage;
import dev.langchain4j.model.ModelProvider;
import dev.langchain4j.model.chat.Capability;
import dev.langchain4j.model.chat.ChatModel;
import dev.langchain4j.model.chat.StreamingChatModel;
import dev.langchain4j.model.chat.listener.ChatModelListener;
import dev.langchain4j.model.chat.request.ChatRequest;
import dev.langchain4j.model.chat.request.ChatRequestParameters;
import dev.langchain4j.model.chat.request.DefaultChatRequestParameters;
import dev.langchain4j.model.chat.request.ResponseFormat;
import dev.langchain4j.model.chat.request.ResponseFormatType;
import dev.langchain4j.model.chat.request.json.JsonObjectSchema;
import dev.langchain4j.model.chat.request.json.JsonSchema;
import dev.langchain4j.model.chat.request.json.JsonSchemaElement;
import dev.langchain4j.model.chat.response.ChatResponse;
import dev.langchain4j.model.chat.response.StreamingChatResponseHandler;
import dev.langchain4j.model.output.FinishReason;
import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentProvider;
import io.casehub.platform.agent.AgentSessionConfig;
import io.quarkus.arc.DefaultBean;
import jakarta.annotation.Priority;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Any;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.stream.Collectors;

@DefaultBean
@Priority(10)
@ApplicationScoped
public class AgentProviderChatModel implements ChatModel, StreamingChatModel {

    private final AgentProvider agentProvider;
    private final Instance<ChatModelListener> injectedListeners;
    private final AgentLangchain4jProperties properties;

    @Inject
    AgentProviderChatModel(AgentProvider agentProvider,
                           @Any Instance<ChatModelListener> listeners,
                           AgentLangchain4jProperties properties) {
        this.agentProvider = agentProvider;
        this.injectedListeners = listeners;
        this.properties = properties;
    }

    protected AgentProviderChatModel() {
        this.agentProvider = null;
        this.injectedListeners = null;
        this.properties = null;
    }

    @Override
    public ModelProvider provider() {
        return ModelProvider.OTHER;
    }

    @Override
    public Set<Capability> supportedCapabilities() {
        return Set.of();
    }

    @Override
    public List<ChatModelListener> listeners() {
        return injectedListeners.stream().toList();
    }

    @Override
    public ChatRequestParameters defaultRequestParameters() {
        return DefaultChatRequestParameters.EMPTY;
    }

    @Override
    public ChatResponse doChat(ChatRequest request) {
        String systemPrompt = extractSystemPrompt(request.messages());
        String userMessage = extractUserText(request.messages());
        String userWithSchema = prependSchema(request, userMessage);
        AgentSessionConfig config = AgentSessionConfig.of(systemPrompt, userWithSchema);
        String text = agentProvider.invoke(config)
            .filter(e -> e instanceof AgentEvent.TextDelta)
            .map(e -> ((AgentEvent.TextDelta) e).text())
            .collect().with(Collectors.joining())
            .await().atMost(properties.closeTimeout());
        return ChatResponse.builder()
            .aiMessage(AiMessage.from(text))
            .finishReason(FinishReason.STOP)
            .build();
    }

    @Override
    public void doChat(ChatRequest request, StreamingChatResponseHandler handler) {
        String systemPrompt = extractSystemPrompt(request.messages());
        String userMessage = extractUserText(request.messages());
        String userWithSchema = prependSchema(request, userMessage);
        AgentSessionConfig config = AgentSessionConfig.of(systemPrompt, userWithSchema);
        StringBuilder buffer = new StringBuilder();
        agentProvider.invoke(config)
            .subscribe().with(
                event -> {
                    if (event instanceof AgentEvent.TextDelta delta) {
                        handler.onPartialResponse(delta.text());
                        buffer.append(delta.text());
                    }
                },
                handler::onError,
                () -> handler.onCompleteResponse(ChatResponse.builder()
                    .aiMessage(AiMessage.from(buffer.toString()))
                    .finishReason(FinishReason.STOP)
                    .build())
            );
    }

    private static String extractSystemPrompt(List<ChatMessage> messages) {
        return SystemMessage.findFirst(messages).map(SystemMessage::text).orElse("");
    }

    static String extractUserText(List<ChatMessage> messages) {
        for (ChatMessage m : messages) {
            if (m instanceof AiMessage) {
                throw new IllegalArgumentException(
                    "AgentProvider-backed ChatModel does not accept AiMessage — " +
                    "session history is managed opaquely by the agent. " +
                    "Each call must supply only a SystemMessage + UserMessage.");
            }
        }
        List<UserMessage> userMessages = messages.stream()
            .filter(m -> m instanceof UserMessage)
            .map(m -> (UserMessage) m)
            .toList();
        if (userMessages.size() > 1) {
            throw new IllegalArgumentException(
                "AgentProvider-backed ChatModel accepts exactly one UserMessage per call.");
        }
        if (userMessages.isEmpty()) {
            throw new IllegalArgumentException("ChatRequest must contain at least one UserMessage");
        }
        try {
            return userMessages.get(0).singleText();
        } catch (RuntimeException e) {
            throw new IllegalArgumentException(
                "This adapter supports text-only UserMessage; " +
                "multimodal content is not supported.", e);
        }
    }

    static String prependSchema(ChatRequest request, String userText) {
        ResponseFormat format = request.responseFormat();
        if (format == null || format.type() != ResponseFormatType.JSON || format.jsonSchema() == null) {
            return userText;
        }
        return serializeSchema(format.jsonSchema()) + "\n\n" + userText;
    }

    static String serializeSchema(JsonSchema schema) {
        StringBuilder sb = new StringBuilder();
        sb.append("Respond with JSON matching schema \"").append(schema.name()).append("\":\n{\n");
        JsonSchemaElement root = schema.rootElement();
        if (root instanceof JsonObjectSchema obj) {
            Map<String, JsonSchemaElement> props = obj.properties();
            List<String> required = obj.required() != null ? obj.required() : List.of();
            new TreeMap<>(props).forEach((name, element) -> {
                String typeName = element.getClass().getSimpleName()
                    .replace("Json", "").replace("Schema", "").toLowerCase();
                String reqLabel = required.contains(name) ? " (required)" : "";
                sb.append("  \"").append(name).append("\": ").append(typeName).append(reqLabel).append(",\n");
            });
            if (!props.isEmpty()) {
                sb.setLength(sb.length() - 2);
                sb.append('\n');
            }
        }
        sb.append('}');
        return sb.toString();
    }
}
```

- [ ] **Step 6: Update parent POM — add agent-langchain4j module**

In `pom.xml`, replace `<module>agent-claude-langchain4j</module>` with `<module>agent-langchain4j</module>`.

- [ ] **Step 7: Run tests**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=AgentProviderChatModelTest`
Expected: All tests PASS

- [ ] **Step 8: Commit**

```
feat(platform#105): AgentProviderChatModel — generic AgentProvider → ChatModel adapter

@DefaultBean @Priority(10) ChatModel/StreamingChatModel backed by any
AgentProvider. Uses invoke() for single-shot (not openSession()). JSON
format via prompt engineering (not rejection). ModelProvider.OTHER.
Replaces ClaudeAgentChatModel and OpenClawChatModel.

Refs casehubio/platform#105
```

---

### Task 4: Move AgentSessionChatModel to agent-langchain4j

**Files:**
- Move: `agent-claude-langchain4j/src/main/java/.../AgentSessionChatModel.java` → `agent-langchain4j/src/main/java/.../AgentSessionChatModel.java`
- Move: `agent-claude-langchain4j/src/test/java/.../AgentSessionChatModelTest.java` → `agent-langchain4j/src/test/java/.../AgentSessionChatModelTest.java`
- Modify: `AgentSessionChatModel.java` — JSON format: prompt engineering replaces `UnsupportedFeatureException`

**Interfaces:**
- Consumes: `AgentSession` (constructor), `AgentEvent.TextDelta`
- Produces: `ChatModel`, `StreamingChatModel` (plain class, not CDI)

- [ ] **Step 1: Copy source files to new module**

Copy `AgentSessionChatModel.java` and `AgentSessionChatModelTest.java` from `agent-claude-langchain4j/` to `agent-langchain4j/` (same package path).

- [ ] **Step 2: Modify AgentSessionChatModel — replace JSON rejection with prompt engineering**

Replace `validateNoJsonFormat()` calls with `prependSchema()` from `AgentProviderChatModel`. Change:

```java
// In doChat(ChatRequest):
validateNoJsonFormat(request);
String userMessage = extractLastUserText(request.messages());
```
to:
```java
String userMessage = extractLastUserText(request.messages());
userMessage = AgentProviderChatModel.prependSchema(request, userMessage);
```

Same change in the streaming `doChat()`.

Remove the `validateNoJsonFormat()` method entirely.

Change `provider()` to return `ModelProvider.OTHER` instead of `ModelProvider.ANTHROPIC`.

- [ ] **Step 3: Update tests for JSON format behavior**

In `AgentSessionChatModelTest`, change the JSON format tests from expecting `UnsupportedFeatureException` to expecting the schema prepended to the user text. Change `provider()` test to expect `ModelProvider.OTHER`.

- [ ] **Step 4: Run tests**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=AgentSessionChatModelTest`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```
feat(platform#105): move AgentSessionChatModel to agent-langchain4j

Moved from agent-claude-langchain4j. JSON format now prompt-engineered
(not rejected). provider() returns ModelProvider.OTHER.

Refs casehubio/platform#105
```

---

### Task 5: ChatModelAgentProvider (ChatModel → AgentProvider)

**Files:**
- Create: `agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/ChatModelAgentProvider.java`
- Create: `agent-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/ChatModelAgentProviderTest.java`

**Interfaces:**
- Consumes: `Instance<ChatModel>` (CDI dynamic lookup), `AgentLangchain4jProperties`
- Produces: `AgentProvider` CDI bean (`@Alternative @Priority(1)`)

- [ ] **Step 1: Write failing tests**

Tests cover: invoke happy path (blocking ChatModel → TextDelta stream), invoke with system prompt, invoke with timeout enforcement, invoke when disabled (returns failed Multi), openSession returns ChatModelAgentSession, MCP servers logged as warning, graceful deactivation when no real ChatModel.

Use a mock `ChatModel` returning `ChatResponse` with known text. Verify that `invoke()` returns a `Multi<AgentEvent>` emitting `TextDelta` with the response text.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=ChatModelAgentProviderTest`
Expected: FAIL — class does not exist

- [ ] **Step 3: Write ChatModelAgentProvider**

```java
package io.casehub.platform.agent.langchain4j;

import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.data.message.SystemMessage;
import dev.langchain4j.data.message.UserMessage;
import dev.langchain4j.model.chat.ChatModel;
import dev.langchain4j.model.chat.request.ChatRequest;
import dev.langchain4j.model.chat.response.ChatResponse;
import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentProvider;
import io.casehub.platform.agent.AgentSession;
import io.casehub.platform.agent.AgentSessionConfig;
import io.casehub.platform.agent.AgentSessionInit;
import io.casehub.platform.agent.AgentTimeoutException;
import io.smallrye.mutiny.Multi;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.Priority;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Alternative;
import jakarta.enterprise.inject.Any;
import jakarta.enterprise.inject.Default;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;

import java.util.List;

@Alternative
@Priority(1)
@ApplicationScoped
public class ChatModelAgentProvider implements AgentProvider {

    private static final Logger LOG = Logger.getLogger(ChatModelAgentProvider.class);

    @Inject @Any Instance<ChatModel> chatModels;
    @Inject AgentLangchain4jProperties properties;

    private ChatModel chatModel;
    private boolean disabled;

    protected ChatModelAgentProvider() {}

    @PostConstruct
    void init() {
        List<ChatModel> candidates = chatModels.select(Default.Literal.INSTANCE).stream()
            .filter(m -> !(m instanceof AgentProviderChatModel))
            .toList();
        if (candidates.isEmpty()) {
            LOG.warn("ChatModelAgentProvider: no ChatModel bean available — " +
                     "add a quarkus-langchain4j provider to activate. " +
                     "AgentProvider calls will fail until a ChatModel is present.");
            disabled = true;
            return;
        }
        chatModel = candidates.get(0);
    }

    @Override
    public Multi<AgentEvent> invoke(AgentSessionConfig config) {
        if (disabled) {
            return Multi.createFrom().failure(new IllegalStateException(
                "ChatModelAgentProvider is inactive — no ChatModel bean available. " +
                "Add a quarkus-langchain4j provider (e.g. quarkus-langchain4j-openai) " +
                "to the classpath."));
        }
        return Multi.createFrom().item(() -> {
            ChatRequest request = ChatRequest.builder()
                .messages(config.systemPrompt().isEmpty()
                    ? List.of(UserMessage.from(config.userPrompt()))
                    : List.of(SystemMessage.from(config.systemPrompt()),
                              UserMessage.from(config.userPrompt())))
                .build();
            ChatResponse response = chatModel.chat(request);
            String text = response.aiMessage().text();
            return (AgentEvent) new AgentEvent.TextDelta(text != null ? text : "");
        });
    }

    @Override
    public AgentSession openSession(AgentSessionInit init) {
        if (disabled) {
            throw new IllegalStateException(
                "ChatModelAgentProvider is inactive — no ChatModel bean available.");
        }
        return new ChatModelAgentSession(chatModel, init, properties);
    }
}
```

- [ ] **Step 4: Run tests**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=ChatModelAgentProviderTest`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```
feat(platform#105): ChatModelAgentProvider — ChatModel → AgentProvider adapter

@Alternative @Priority(1) AgentProvider backed by any LangChain4j
ChatModel. Graceful deactivation when no ChatModel available. @Default
selection with AgentProviderChatModel filtering prevents circular deps.

Refs casehubio/platform#105
```

---

### Task 6: ChatModelAgentSession (multi-turn)

**Files:**
- Create: `agent-langchain4j/src/main/java/io/casehub/platform/agent/langchain4j/ChatModelAgentSession.java`
- Create: `agent-langchain4j/src/test/java/io/casehub/platform/agent/langchain4j/ChatModelAgentSessionTest.java`

**Interfaces:**
- Consumes: `ChatModel` (LangChain4j), `AgentSessionInit`, `AgentLangchain4jProperties`
- Produces: `AgentSession` implementation

- [ ] **Step 1: Write failing tests**

Tests cover: query happy path (text → TextDelta stream), multi-turn conversation memory (second query includes first exchange), query on CLOSED throws, concurrent query throws, interrupt is no-op, close sets CLOSED state, close idempotent.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=ChatModelAgentSessionTest`
Expected: FAIL — class does not exist

- [ ] **Step 3: Write ChatModelAgentSession**

```java
package io.casehub.platform.agent.langchain4j;

import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.data.message.ChatMessage;
import dev.langchain4j.data.message.SystemMessage;
import dev.langchain4j.data.message.UserMessage;
import dev.langchain4j.memory.ChatMemory;
import dev.langchain4j.memory.chat.MessageWindowChatMemory;
import dev.langchain4j.model.chat.ChatModel;
import dev.langchain4j.model.chat.request.ChatRequest;
import dev.langchain4j.model.chat.response.ChatResponse;
import io.casehub.platform.agent.AgentEvent;
import io.casehub.platform.agent.AgentSession;
import io.casehub.platform.agent.AgentSessionInit;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;

class ChatModelAgentSession implements AgentSession {

    private enum State { IDLE, ACTIVE, CLOSED }

    private final ChatModel chatModel;
    private final String systemPrompt;
    private final ChatMemory memory;
    private final AtomicReference<State> state = new AtomicReference<>(State.IDLE);

    ChatModelAgentSession(ChatModel chatModel, AgentSessionInit init,
                          AgentLangchain4jProperties properties) {
        this.chatModel = chatModel;
        this.systemPrompt = init.systemPrompt();
        this.memory = MessageWindowChatMemory.withMaxMessages(properties.sessionMemoryWindowSize());
    }

    @Override
    public Multi<AgentEvent> query(String prompt) {
        if (!state.compareAndSet(State.IDLE, State.ACTIVE)) {
            State current = state.get();
            throw new IllegalStateException(current == State.CLOSED
                ? "session is closed"
                : "a turn is already active — wait for it to complete or call interrupt()");
        }
        return Multi.createFrom().item(() -> {
            memory.add(UserMessage.from(prompt));
            List<ChatMessage> messages = new ArrayList<>();
            if (!systemPrompt.isEmpty()) {
                messages.add(SystemMessage.from(systemPrompt));
            }
            messages.addAll(memory.messages());
            ChatRequest request = ChatRequest.builder().messages(messages).build();
            ChatResponse response = chatModel.chat(request);
            String text = response.aiMessage().text();
            memory.add(AiMessage.from(text != null ? text : ""));
            return (AgentEvent) new AgentEvent.TextDelta(text != null ? text : "");
        }).onTermination().invoke(() -> state.compareAndSet(State.ACTIVE, State.IDLE));
    }

    @Override
    public Uni<Void> interrupt() {
        return Uni.createFrom().voidItem();
    }

    @Override
    public void close(Duration maxWait) {
        state.set(State.CLOSED);
    }
}
```

- [ ] **Step 4: Run tests**

Run: `mvn --batch-mode test -pl agent-langchain4j -Dtest=ChatModelAgentSessionTest`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```
feat(platform#105): ChatModelAgentSession — multi-turn via ChatMemory

AgentSession backed by ChatModel + MessageWindowChatMemory. IDLE/ACTIVE/
CLOSED state machine matching ClaudeAgentSession contract. Replays full
history on each query. interrupt() is no-op (no subprocess).

Refs casehubio/platform#105
```

---

### Task 7: Update ClaudeAgentProvider + NoOpAgentProvider + delete agent-claude-langchain4j

**Files:**
- Modify: `agent-claude/src/main/java/.../ClaudeAgentProvider.java` — `@ApplicationScoped` → `@Alternative @Priority(10) @ApplicationScoped`
- Modify: `platform/src/main/java/.../NoOpAgentProvider.java` — update log message
- Delete: `agent-claude-langchain4j/` directory

**Interfaces:**
- Consumes: Nothing new
- Produces: Updated CDI tier annotations

- [ ] **Step 1: Update ClaudeAgentProvider annotation**

Change:
```java
@ApplicationScoped
public class ClaudeAgentProvider implements AgentProvider {
```
to:
```java
@Alternative
@Priority(10)
@ApplicationScoped
public class ClaudeAgentProvider implements AgentProvider {
```

Add imports: `jakarta.annotation.Priority`, `jakarta.enterprise.inject.Alternative`.

Update the javadoc CDI tier list to reflect the new three-tier structure.

- [ ] **Step 2: Update NoOpAgentProvider log message**

Change both log messages from:
```java
"NoOpAgentProvider is active — add casehub-platform-agent-claude " +
"to the classpath to get real Claude output"
```
to:
```java
"NoOpAgentProvider is active — add casehub-platform-agent-claude " +
"(native Claude) or casehub-platform-agent-langchain4j " +
"(any LangChain4j model) to the classpath"
```

- [ ] **Step 3: Delete agent-claude-langchain4j directory**

Remove the entire `agent-claude-langchain4j/` directory.

- [ ] **Step 4: Run full build**

Run: `mvn --batch-mode install`
Expected: All modules compile and all tests pass. `agent-claude-langchain4j` is gone, `agent-langchain4j` has replaced it.

- [ ] **Step 5: Commit**

```
feat(platform#105): CDI tier migration + delete agent-claude-langchain4j

ClaudeAgentProvider: @ApplicationScoped → @Alternative @Priority(10).
NoOpAgentProvider: log message updated for both agent modules.
agent-claude-langchain4j deleted — replaced by agent-langchain4j.

Refs casehubio/platform#105
```

---

### Task 8: Update CLAUDE.md, ARC42STORIES.MD, file consumer issues

**Files:**
- Modify: `CLAUDE.md` — module table: remove agent-claude-langchain4j, add agent-langchain4j
- Modify: `ARC42STORIES.MD` — L8 layer taxonomy row

**Interfaces:**
- Consumes: Nothing
- Produces: Updated docs

- [ ] **Step 1: Update CLAUDE.md module table**

Replace the `agent-claude-langchain4j` entry with:

```
| `agent-langchain4j/` | `casehub-platform-agent-langchain4j` | Bidirectional LangChain4j interop: `ChatModelAgentProvider` wraps any ChatModel as AgentProvider (@Alternative @Priority(1)); `AgentProviderChatModel` wraps any AgentProvider as ChatModel (@DefaultBean @Priority(10)). `AgentSessionChatModel` (plain wrapper for caller-managed sessions). No quarkus:build goal |
```

- [ ] **Step 2: Update ARC42STORIES.MD L8**

Change L8 module list from `agent-api/`, `agent-claude/`, `agent-claude-langchain4j/` to `agent-api/`, `agent-claude/`, `agent-langchain4j/`.

Change L8 description from "AgentProvider SPI + Claude subprocess execution + LangChain4j ChatModel/StreamingChatModel bridge" to "AgentProvider SPI + Claude subprocess execution + bidirectional LangChain4j interop".

- [ ] **Step 3: File consumer issues**

For any consumer repo currently depending on `casehub-platform-agent-claude-langchain4j`: file a GitHub issue noting the dependency change to `casehub-platform-agent-langchain4j`.

Check which consumers have the dependency:
```
gh search code "casehub-platform-agent-claude-langchain4j" --owner casehubio --filename pom.xml
```

- [ ] **Step 4: Commit**

```
docs(platform#105): update CLAUDE.md + ARC42STORIES.MD for agent-langchain4j

Module table and L8 layer taxonomy updated. Consumer migration issues
filed where applicable.

Closes casehubio/platform#105
```

- [ ] **Step 5: Final full build verification**

Run: `mvn --batch-mode install`
Expected: All modules compile, all tests pass, zero warnings related to missing module.
