# ResponseFormat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #636 — AgentSessionConfig.responseFormat — structured JSON output support
**Issue group:** #636, #637, #638

**Goal:** Add a `ResponseFormat` type to `agent-api` and wire it through
all four native backends (OpenAI, Ollama, Claude, Gemini) so callers can
request structured JSON output via `AgentSessionConfig`.

**Architecture:** New `ResponseFormat` record and `ResponseFormatType` enum
in `agent-api` (zero-Jackson, schema as raw JSON string). Each backend
parses the schema string at its own boundary using its existing Jackson
dependency. The LangChain4j bridge converts from LangChain4j's
`ResponseFormat` to the platform type instead of prepending schema as text.

**Tech Stack:** Java 21, agent-api (Mutiny), OpenAI Java SDK 4.50.0,
Claude Code SDK 1.0.0, Google GenAI SDK 1.65.0

## Global Constraints

- `agent-api` must remain zero-Jackson — no `JsonNode`, no `ObjectMapper`
- `ResponseFormat.schema` is a raw JSON string; backends parse at their boundary
- Pre-release platform — breaking record component changes are free
- IntelliJ MCP required for all `.java` file operations

---

## Batch 1: Foundation — ResponseFormat type + config record changes

### Task 1: ResponseFormat type in agent-api

**Files:**
- Create: `agent-api/src/main/java/io/casehub/platform/agent/ResponseFormatType.java`
- Create: `agent-api/src/main/java/io/casehub/platform/agent/ResponseFormat.java`
- Test: `agent-api/src/test/java/io/casehub/platform/agent/ResponseFormatTest.java`

**Interfaces:**
- Produces: `ResponseFormatType` enum (TEXT, JSON), `ResponseFormat` record
  (type, name, schema), factory methods `ResponseFormat.TEXT`,
  `ResponseFormat.json(String name, String schema)`,
  `ResponseFormat.jsonAny()`

- [ ] **Step 1: Write the failing test**

```java
package io.casehub.platform.agent;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class ResponseFormatTest {

    @Test
    void textConstantHasCorrectType() {
        assertThat(ResponseFormat.TEXT.type()).isEqualTo(ResponseFormatType.TEXT);
        assertThat(ResponseFormat.TEXT.name()).isNull();
        assertThat(ResponseFormat.TEXT.schema()).isNull();
    }

    @Test
    void jsonFactoryRequiresNameAndSchema() {
        var format = ResponseFormat.json("weather", "{\"type\":\"object\"}");
        assertThat(format.type()).isEqualTo(ResponseFormatType.JSON);
        assertThat(format.name()).isEqualTo("weather");
        assertThat(format.schema()).isEqualTo("{\"type\":\"object\"}");
    }

    @Test
    void jsonFactoryRejectsNullName() {
        assertThatThrownBy(() -> ResponseFormat.json(null, "{\"type\":\"object\"}"))
            .isInstanceOf(NullPointerException.class);
    }

    @Test
    void jsonFactoryRejectsNullSchema() {
        assertThatThrownBy(() -> ResponseFormat.json("weather", null))
            .isInstanceOf(NullPointerException.class);
    }

    @Test
    void jsonAnyHasNullNameAndSchema() {
        var format = ResponseFormat.jsonAny();
        assertThat(format.type()).isEqualTo(ResponseFormatType.JSON);
        assertThat(format.name()).isNull();
        assertThat(format.schema()).isNull();
    }

    @Test
    void rejectsJsonWithNameButNoSchema() {
        assertThatThrownBy(() -> new ResponseFormat(ResponseFormatType.JSON, "weather", null))
            .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void rejectsJsonWithSchemaButNoName() {
        assertThatThrownBy(() -> new ResponseFormat(ResponseFormatType.JSON, null, "{\"type\":\"object\"}"))
            .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void rejectsNullType() {
        assertThatThrownBy(() -> new ResponseFormat(null, null, null))
            .isInstanceOf(NullPointerException.class);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl agent-api -Dtest=ResponseFormatTest`
Expected: FAIL — classes don't exist

- [ ] **Step 3: Create ResponseFormatType enum**

Use `ide_create_file` or Write to create:

```java
package io.casehub.platform.agent;

public enum ResponseFormatType {
    TEXT,
    JSON
}
```

- [ ] **Step 4: Create ResponseFormat record**

```java
package io.casehub.platform.agent;

import java.util.Objects;

public record ResponseFormat(
        ResponseFormatType type,
        String name,
        String schema
) {
    public static final ResponseFormat TEXT =
            new ResponseFormat(ResponseFormatType.TEXT, null, null);

    public ResponseFormat {
        Objects.requireNonNull(type, "type");
        if (type == ResponseFormatType.JSON && name != null && schema == null) {
            throw new IllegalArgumentException("JSON with name requires schema");
        }
        if (type == ResponseFormatType.JSON && name == null && schema != null) {
            throw new IllegalArgumentException("JSON with schema requires name");
        }
    }

    public static ResponseFormat json(String name, String schema) {
        return new ResponseFormat(ResponseFormatType.JSON,
                Objects.requireNonNull(name, "name"),
                Objects.requireNonNull(schema, "schema"));
    }

    public static ResponseFormat jsonAny() {
        return new ResponseFormat(ResponseFormatType.JSON, null, null);
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mvn --batch-mode test -pl agent-api -Dtest=ResponseFormatTest`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add agent-api/src/main/java/io/casehub/platform/agent/ResponseFormatType.java \
       agent-api/src/main/java/io/casehub/platform/agent/ResponseFormat.java \
       agent-api/src/test/java/io/casehub/platform/agent/ResponseFormatTest.java
git commit -m "feat(#636): add ResponseFormat type to agent-api"
```

### Task 2: Add responseFormat to AgentSessionConfig and AgentSessionInit

**Files:**
- Modify: `agent-api/src/main/java/io/casehub/platform/agent/AgentSessionConfig.java`
- Modify: `agent-api/src/main/java/io/casehub/platform/agent/AgentSessionInit.java`
- Modify: `agent-api/src/test/java/io/casehub/platform/agent/AgentSessionConfigTest.java`
- Modify: `agent-api/src/test/java/io/casehub/platform/agent/AgentSessionInitTest.java`

**Interfaces:**
- Consumes: `ResponseFormat` record from Task 1
- Produces: `AgentSessionConfig.responseFormat()` accessor,
  `AgentSessionConfig.withResponseFormat(ResponseFormat)` wither,
  `AgentSessionInit.responseFormat()` accessor,
  `AgentSessionInit.withResponseFormat(ResponseFormat)` wither

- [ ] **Step 1: Write the failing test for AgentSessionConfig**

Add to `AgentSessionConfigTest`:

```java
@Test
void withResponseFormatSetsFormat() {
    var config = AgentSessionConfig.of("system", "user");
    assertThat(config.responseFormat()).isNull();

    var format = ResponseFormat.json("weather", "{\"type\":\"object\"}");
    var updated = config.withResponseFormat(format);
    assertThat(updated.responseFormat()).isEqualTo(format);
    assertThat(updated.systemPrompt()).isEqualTo("system");
    assertThat(updated.userPrompt()).isEqualTo("user");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl agent-api -Dtest=AgentSessionConfigTest#withResponseFormatSetsFormat`
Expected: FAIL — no `responseFormat` component or `withResponseFormat` method

- [ ] **Step 3: Add responseFormat to AgentSessionConfig**

Use `ide_edit_member` to replace the `AgentSessionConfig` record declaration.
Add `ResponseFormat responseFormat` as the last component. Update the
compact constructor (no validation needed — null is valid). Add backward-
compatible constructors that pass `null` for responseFormat. Add wither:

```java
public AgentSessionConfig withResponseFormat(ResponseFormat responseFormat) {
    return new AgentSessionConfig(systemPrompt, userPrompt, mcpServers,
            timeout, correlationId, model, modelQuery, modelChain, responseFormat);
}
```

Update all existing constructors and factory methods to pass `null` for
the new component. Update existing `withModel` and `withModelChain`
methods to preserve `responseFormat`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl agent-api -Dtest=AgentSessionConfigTest`
Expected: PASS (all existing tests + new test)

- [ ] **Step 5: Write the failing test for AgentSessionInit**

Add to `AgentSessionInitTest`:

```java
@Test
void withResponseFormatSetsFormat() {
    var init = AgentSessionInit.of("system");
    assertThat(init.responseFormat()).isNull();

    var format = ResponseFormat.json("weather", "{\"type\":\"object\"}");
    var updated = init.withResponseFormat(format);
    assertThat(updated.responseFormat()).isEqualTo(format);
    assertThat(updated.systemPrompt()).isEqualTo("system");
}
```

- [ ] **Step 6: Add responseFormat to AgentSessionInit**

Same pattern as AgentSessionConfig. Use `ide_edit_member` to replace
the record declaration. Add `ResponseFormat responseFormat` as last
component. Backward-compatible constructors pass `null`. Add wither.

- [ ] **Step 7: Run all agent-api tests**

Run: `mvn --batch-mode test -pl agent-api`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add agent-api/
git commit -m "feat(#636): add responseFormat to AgentSessionConfig and AgentSessionInit"
```

---

## Batch 2: Backend wiring — OpenAI/Ollama + Claude

### Task 3: Wire responseFormat into AbstractOpenAiSdkBackend

**Files:**
- Modify: `agent-openai-core/src/main/java/io/casehub/platform/agent/openai/AbstractOpenAiSdkBackend.java`
- Modify: `agent-openai-core/src/test/java/io/casehub/platform/agent/openai/OpenAiAgentBackendTest.java` (or create if not exists)

**Interfaces:**
- Consumes: `AgentSessionConfig.responseFormat()` from Task 2
- Produces: `ChatCompletionCreateParams` with `response_format` when
  `config.responseFormat()` is JSON

- [ ] **Step 1: Write the failing test**

Add a test that verifies the stream factory receives config with
responseFormat and the built `ChatCompletionCreateParams` includes the
response format. Use the existing `streamFactory` constructor to capture
the config:

```java
@Test
void buildEventStreamSetsResponseFormat() {
    var captured = new AtomicReference<AgentSessionConfig>();
    var backend = new TestOpenAiBackend(1,
        config -> {
            captured.set(config);
            return Multi.createFrom().empty();
        });

    var format = ResponseFormat.json("weather",
        "{\"type\":\"object\",\"properties\":{\"temp\":{\"type\":\"number\"}}}");
    var config = AgentSessionConfig.of("system", "user")
        .withResponseFormat(format);

    backend.invoke(config).collect().asList().await().indefinitely();
    assertThat(captured.get().responseFormat()).isEqualTo(format);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl agent-openai-core -Dtest=OpenAiAgentBackendTest#buildEventStreamSetsResponseFormat`
Expected: FAIL (or compilation error if test references missing features)

- [ ] **Step 3: Wire response format into buildEventStream**

In `AbstractOpenAiSdkBackend.buildEventStream()`, after building the
`ChatCompletionCreateParams`, add response format handling:

```java
var paramsBuilder = ChatCompletionCreateParams.builder()
    .model(ChatModel.of(modelId))
    .addMessage(ChatCompletionSystemMessageParam.builder()
        .content(config.systemPrompt()).build())
    .addMessage(ChatCompletionUserMessageParam.builder()
        .content(config.userPrompt()).build())
    .streamOptions(ChatCompletionStreamOptions.builder()
        .includeUsage(true).build());

if (config.responseFormat() != null
        && config.responseFormat().type() == ResponseFormatType.JSON) {
    if (config.responseFormat().schema() != null) {
        var objectMapper = new com.fasterxml.jackson.databind.ObjectMapper();
        var schemaNode = objectMapper.readTree(config.responseFormat().schema());
        var jsonSchema = com.openai.models.chat.completions
            .ChatCompletionCreateParams.ResponseFormat.JsonSchema.builder()
            .name(config.responseFormat().name())
            .schema(com.openai.core.JsonValue.from(
                objectMapper.convertValue(schemaNode, java.util.Map.class)))
            .strict(true)
            .build();
        paramsBuilder.responseFormat(
            ChatCompletionCreateParams.ResponseFormat.ofJsonSchema(jsonSchema));
    } else {
        paramsBuilder.responseFormat(
            ChatCompletionCreateParams.ResponseFormat.ofJsonObject());
    }
}

ChatCompletionCreateParams params = paramsBuilder.build();
```

Note: `ObjectMapper` is available transitively via the OpenAI SDK's
Jackson dependency. Check the exact OpenAI SDK API for `ResponseFormat`
builder — the field names above are illustrative; verify against the
SDK's actual types.

- [ ] **Step 4: Run tests**

Run: `mvn --batch-mode test -pl agent-openai-core`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add agent-openai-core/
git commit -m "feat(#636): wire responseFormat into OpenAI/Ollama backend"
```

### Task 4: Wire responseFormat into ClaudeAgentClient

**Files:**
- Modify: `agent-claude-core/src/main/java/io/casehub/platform/agent/claude/ClaudeAgentClient.java`
- Modify: `agent-claude-core/src/test/java/io/casehub/platform/agent/claude/ClaudeAgentClientTest.java`

**Interfaces:**
- Consumes: `AgentSessionConfig.responseFormat()` from Task 2
- Produces: `CLIOptions.jsonSchema` populated when format is JSON with schema

- [ ] **Step 1: Write the failing test**

Add to `ClaudeAgentClientTest`:

```java
@Test
void buildEventStreamSetsJsonSchema() {
    var captured = new AtomicReference<AgentSessionConfig>();
    var client = new ClaudeAgentClient(testProperties(),
        config -> {
            captured.set(config);
            return Multi.createFrom().empty();
        });

    var format = ResponseFormat.json("weather",
        "{\"type\":\"object\",\"properties\":{\"temp\":{\"type\":\"number\"}}}");
    var config = AgentSessionConfig.of("system", "user")
        .withResponseFormat(format);

    client.run(config).collect().asList().await().indefinitely();
    assertThat(captured.get().responseFormat()).isEqualTo(format);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl agent-claude-core -Dtest=ClaudeAgentClientTest#buildEventStreamSetsJsonSchema`
Expected: FAIL

- [ ] **Step 3: Wire response format into buildEventStream**

In `ClaudeAgentClient.buildEventStream()`, after building `CLIOptions`,
add the jsonSchema field:

```java
if (config.responseFormat() != null
        && config.responseFormat().type() == ResponseFormatType.JSON
        && config.responseFormat().schema() != null) {
    var objectMapper = new com.fasterxml.jackson.databind.ObjectMapper();
    Map<String, Object> schemaMap = objectMapper.readValue(
        config.responseFormat().schema(),
        new com.fasterxml.jackson.core.type.TypeReference<Map<String, Object>>() {});
    optionsBuilder.jsonSchema(schemaMap);
}
```

Jackson is already on the classpath via claude-code-sdk.

- [ ] **Step 4: Run tests**

Run: `mvn --batch-mode test -pl agent-claude-core`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add agent-claude-core/
git commit -m "feat(#636): wire responseFormat into Claude backend"
```

---

## Batch 3: Gemini backend + LangChain4j bridge update

### Task 5: Wire responseFormat into GeminiAgentBackend

**Files:**
- Modify: `agent-gemini-core/src/main/java/io/casehub/platform/agent/gemini/GeminiAgentBackend.java`
- Modify: `agent-gemini-core/src/test/java/io/casehub/platform/agent/gemini/GeminiAgentBackendTest.java`

**Interfaces:**
- Consumes: `AgentSessionConfig.responseFormat()` from Task 2
- Produces: Gemini `GenerateContentConfig` with `responseMimeType` and
  `responseSchema` when format is JSON

- [ ] **Step 1: Write the failing test**

Add to `GeminiAgentBackendTest`:

```java
@Test
void buildEventStreamSetsResponseFormat() {
    var captured = new AtomicReference<AgentSessionConfig>();
    var backend = new GeminiAgentBackend(testProperties(),
        config -> {
            captured.set(config);
            return Multi.createFrom().empty();
        });

    var format = ResponseFormat.json("weather",
        "{\"type\":\"object\",\"properties\":{\"temp\":{\"type\":\"number\"}}}");
    var config = AgentSessionConfig.of("system", "user")
        .withResponseFormat(format);

    backend.invoke(config).collect().asList().await().indefinitely();
    assertThat(captured.get().responseFormat()).isEqualTo(format);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl agent-gemini-core -Dtest=GeminiAgentBackendTest#buildEventStreamSetsResponseFormat`
Expected: FAIL

- [ ] **Step 3: Wire response format into buildEventStream**

The Gemini backend's `buildEventStream` is currently a stub (throws
"requires API key"). The response format wiring goes into the production
path. For now, the test captures the config via `streamFactory` — the
format will be consumed when the production Gemini path is implemented.

If the production path exists:

```java
var configBuilder = GenerateContentConfig.builder();
if (config.responseFormat() != null
        && config.responseFormat().type() == ResponseFormatType.JSON) {
    configBuilder.responseMimeType("application/json");
    if (config.responseFormat().schema() != null) {
        configBuilder.responseSchema(
            Schema.fromJson(config.responseFormat().schema()));
    }
}
```

Verify the Gemini SDK's `Schema.fromJson()` API exists. If not, parse
the JSON string with Jackson and construct the Schema manually.

- [ ] **Step 4: Run tests**

Run: `mvn --batch-mode test -pl agent-gemini-core`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add agent-gemini-core/
git commit -m "feat(#636): wire responseFormat into Gemini backend"
```

### Task 6: Update LangChain4j bridge to use native ResponseFormat

**Files:**
- Modify: `agent-langchain4j-core/src/main/java/io/casehub/platform/agent/langchain4j/AgentProviderChatModel.java`
- Modify: `agent-langchain4j-core/src/test/java/io/casehub/platform/agent/langchain4j/AgentProviderChatModelTest.java`
- Modify: `agent-langchain4j-core/src/test/java/io/casehub/platform/agent/langchain4j/AgentSessionChatModelTest.java`

**Interfaces:**
- Consumes: `ResponseFormat` from Task 1, `AgentSessionConfig.withResponseFormat()`
  from Task 2
- Produces: Updated `AgentProviderChatModel` that converts LangChain4j
  `ResponseFormat` to platform `ResponseFormat` and sets on config,
  replacing the text-prepend approach

- [ ] **Step 1: Write the failing test**

Update the existing test that verifies JSON schema is prepended as text.
Change it to verify that `AgentSessionConfig.responseFormat()` is set
instead:

```java
@Test
void jsonResponseFormatSetsNativeResponseFormat() {
    // Build a ChatRequest with LangChain4j ResponseFormat.JSON + JsonSchema
    // Verify the AgentSessionConfig passed to invoke() has
    // responseFormat().type() == JSON and responseFormat().schema() contains
    // the serialized schema
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl agent-langchain4j-core -Dtest=AgentProviderChatModelTest#jsonResponseFormatSetsNativeResponseFormat`
Expected: FAIL

- [ ] **Step 3: Replace prependSchema with native conversion**

In `AgentProviderChatModel`, replace or supplement `prependSchema()` with
a method that converts LangChain4j's `ResponseFormat` to the platform type:

```java
static AgentSessionConfig applyResponseFormat(ChatRequest request,
                                               AgentSessionConfig config) {
    dev.langchain4j.model.chat.request.ResponseFormat format = request.responseFormat();
    if (format == null || format.type() != ResponseFormatType.JSON) {
        return config;
    }
    if (format.jsonSchema() == null) {
        return config.withResponseFormat(
            io.casehub.platform.agent.ResponseFormat.jsonAny());
    }
    String schemaJson = serializeSchemaToJson(format.jsonSchema());
    return config.withResponseFormat(
        io.casehub.platform.agent.ResponseFormat.json(
            format.jsonSchema().name(), schemaJson));
}
```

`serializeSchemaToJson` converts LangChain4j's `JsonSchema` element tree
to a JSON string. Use Jackson `ObjectMapper` (already on classpath).

Update the `chat()` method to call `applyResponseFormat()` instead of
`prependSchema()`.

- [ ] **Step 4: Update AgentSessionChatModel similarly**

Apply the same conversion in `AgentSessionChatModel` if it also uses
`prependSchema`.

- [ ] **Step 5: Run all langchain4j tests**

Run: `mvn --batch-mode test -pl agent-langchain4j-core`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add agent-langchain4j-core/
git commit -m "feat(#636): convert LangChain4j ResponseFormat to native platform type"
```

---

## Batch 4: Build verification + CLAUDE.md update

### Task 7: Full build verification and CLAUDE.md update

**Files:**
- Modify: `CLAUDE.md` (update agent-api package structure and module descriptions)

- [ ] **Step 1: Run full build**

Run: `mvn --batch-mode install`
Expected: PASS — all modules compile and tests pass

- [ ] **Step 2: Update CLAUDE.md**

Add `ResponseFormat` and `ResponseFormatType` to the `## Package Structure
(platform-api)` section under the agent-api description. Also update the
`agent-api/` module description to mention responseFormat.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(#636): update CLAUDE.md with ResponseFormat types"
```

## References

- [2026-10-18-response-format-design.md] — design spec this plan implements
- [agent-api/src/main/java/io/casehub/platform/agent/AgentSessionConfig.java] — existing config
- [agent-api/src/main/java/io/casehub/platform/agent/AgentSessionInit.java] — existing init
- [agent-openai-core/src/main/java/io/casehub/platform/agent/openai/AbstractOpenAiSdkBackend.java] — OpenAI backend
- [agent-claude-core/src/main/java/io/casehub/platform/agent/claude/ClaudeAgentClient.java] — Claude backend
- [agent-gemini-core/src/main/java/io/casehub/platform/agent/gemini/GeminiAgentBackend.java] — Gemini backend
- [agent-langchain4j-core/src/main/java/io/casehub/platform/agent/langchain4j/AgentProviderChatModel.java] — LangChain4j bridge
- [Claude SDK CLIOptions.jsonSchema] — structured output support
- [GitHub #636] — focal issue
