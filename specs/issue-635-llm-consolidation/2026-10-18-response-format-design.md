# AgentSessionConfig.responseFormat — Structured JSON Output Support

**Issue:** casehubio/platform#636
**Branch:** issue-635-llm-consolidation
**Date:** 2026-10-18

## Summary

Add a `ResponseFormat` type to `agent-api` so backends can pass structured
output hints through to vendor APIs natively. Currently the LangChain4j bridge
prepends the schema as text into the user prompt — this replaces that with
native vendor support (JSON mode / JSON Schema).

## New Types in `agent-api`

### `ResponseFormatType` enum

```java
public enum ResponseFormatType { TEXT, JSON }
```

### `ResponseFormat` record

```java
public record ResponseFormat(
    ResponseFormatType type,
    String name,
    String schema
) {
    public static final ResponseFormat TEXT =
        new ResponseFormat(ResponseFormatType.TEXT, null, null);

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

- `type` — TEXT (no format constraint, default) or JSON (structured output)
- `name` — schema name for the JSON response (e.g. `"weather_response"`). Required for structured JSON, null for TEXT or schemaless JSON.
- `schema` — raw JSON Schema string (Draft 2020-12). Required for structured JSON, null for TEXT or schemaless JSON. Backends parse at their boundary.
- `TEXT` constant — convenience for the common no-format case
- `json(name, schema)` — structured JSON with schema. Both name and schema required.
- `jsonAny()` — JSON mode without schema (vendor permitting)

### Compact constructor validation

```java
public ResponseFormat {
    Objects.requireNonNull(type, "type");
    if (type == ResponseFormatType.JSON && name != null && schema == null) {
        throw new IllegalArgumentException("JSON with name requires schema");
    }
    if (type == ResponseFormatType.JSON && name == null && schema != null) {
        throw new IllegalArgumentException("JSON with schema requires name");
    }
}
```

Name and schema must be both-null or both-non-null for JSON mode.

## Config Record Changes

### `AgentSessionConfig`

Add `ResponseFormat responseFormat` as a new record component after `modelChain`.
Add backward-compatible constructors that default responseFormat to null.
Add wither method:

```java
public AgentSessionConfig withResponseFormat(ResponseFormat responseFormat) {
    return new AgentSessionConfig(systemPrompt, userPrompt, mcpServers,
        timeout, correlationId, model, modelQuery, modelChain, responseFormat);
}
```

### `AgentSessionInit`

Same pattern — add `ResponseFormat responseFormat` component, backward-compatible
constructors, and `withResponseFormat()` wither.

## Backend Wiring

### OpenAI (`AbstractOpenAiSdkBackend.buildEventStream`)

In the `ChatCompletionCreateParams` builder, after adding messages:

```java
if (config.responseFormat() != null
        && config.responseFormat().type() == ResponseFormatType.JSON) {
    if (config.responseFormat().schema() != null) {
        // Structured output with schema
        var jsonSchema = ResponseFormatJsonSchema.builder()
            .name(config.responseFormat().name())
            .schema(JsonValue.from(mapper.readTree(config.responseFormat().schema())))
            .strict(true)
            .build();
        params.responseFormat(ChatCompletionCreateParams.ResponseFormat
            .ofJsonSchema(jsonSchema));
    } else {
        // Schemaless JSON mode
        params.responseFormat(ChatCompletionCreateParams.ResponseFormat
            .ofJsonObject());
    }
}
```

`AbstractOpenAiSdkBackend` needs a Jackson `ObjectMapper` field for schema
string → `JsonValue` conversion. Already available via transitive deps.

### Ollama (`OllamaAgentBackend`)

Extends `AbstractOpenAiSdkBackend` — inherits the same wiring. Ollama's
OpenAI-compatible API supports `format: json` but not JSON Schema constraints.
The schema will be passed but may be ignored by the Ollama backend.

### Claude (`ClaudeAgentClient.buildEventStream`)

In the `CLIOptions` builder, after setting systemPrompt:

```java
if (config.responseFormat() != null
        && config.responseFormat().type() == ResponseFormatType.JSON
        && config.responseFormat().schema() != null) {
    Map<String, Object> schemaMap = mapper.readValue(
        config.responseFormat().schema(),
        new TypeReference<Map<String, Object>>() {});
    optionsBuilder.jsonSchema(schemaMap);
}
```

`ClaudeAgentClient` already has Jackson on its classpath (agent-claude-core
depends on claude-code-sdk which uses Jackson).

### Gemini (`GeminiAgentBackend.buildEventStream`)

The Gemini backend's `buildEventStream` is currently a stub. Response format
wiring goes into the production path when implemented:

```java
if (config.responseFormat() != null
        && config.responseFormat().type() == ResponseFormatType.JSON) {
    configBuilder.responseMimeType("application/json");
    if (config.responseFormat().schema() != null) {
        configBuilder.responseSchema(
            Schema.fromJson(config.responseFormat().schema()));
    }
}
```

## LangChain4j Bridge Update

`AgentProviderChatModel.prependSchema` currently prepends the schema as text
into the user prompt. Replace with native conversion:

```java
static AgentSessionConfig applyResponseFormat(ChatRequest request,
                                               AgentSessionConfig config) {
    ResponseFormat format = request.responseFormat();
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

`serializeSchemaToJson` converts LangChain4j's `JsonSchema` tree to a JSON
string. The existing `serializeSchema` method (text format) is removed.

## Testing

- `ResponseFormatTest` — unit tests for the record: factory methods, validation,
  null schema/name invariants
- `AgentSessionConfigTest` — add `withResponseFormat()` round-trip test
- `AgentSessionInitTest` — same
- `AbstractOpenAiSdkBackendTest` — verify response format is wired into
  `ChatCompletionCreateParams` (structured + schemaless)
- `ClaudeAgentClientTest` — verify `CLIOptions.jsonSchema` is populated
- `AgentProviderChatModelTest` — verify LangChain4j `ResponseFormat.JSON`
  converts to platform `ResponseFormat.json()` instead of text-prepending

## Module Dependencies

No new dependencies. `agent-api` stays zero-Jackson. Each backend uses
Jackson from its own classpath to parse the schema string.

## References

- `agent-api/src/main/java/io/casehub/platform/agent/AgentSessionConfig.java` — existing config record
- `agent-api/src/main/java/io/casehub/platform/agent/AgentSessionInit.java` — existing init record
- `agent-openai-core/src/main/java/io/casehub/platform/agent/openai/AbstractOpenAiSdkBackend.java` — OpenAI backend
- `agent-claude-core/src/main/java/io/casehub/platform/agent/claude/ClaudeAgentClient.java` — Claude backend
- `agent-gemini-core/src/main/java/io/casehub/platform/agent/gemini/GeminiAgentBackend.java` — Gemini backend
- `agent-langchain4j-core/src/main/java/io/casehub/platform/agent/langchain4j/AgentProviderChatModel.java` — LangChain4j bridge
- Claude SDK `CLIOptions.jsonSchema` — structured output support in CLI
- casehubio/platform#636 — issue
