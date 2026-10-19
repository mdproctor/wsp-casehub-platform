# EmbeddingModel Platform Abstraction — Design

**Issue:** casehubio/platform#642
**Branch:** issue-642-embedding-model
**Date:** 2026-10-19

## Overview

Add EmbeddingModel routing to the platform, following the exact pattern established by ChatModel in #640/#641. Native implementations wrap vendor SDKs behind LangChain4j's `EmbeddingModel` interface. A `RoutingEmbeddingModel` dispatches to the correct backend via `ModelRegistry`, and `EmbeddingModelBackend` provides the SPI for backend registration.

Three backends: OpenAI, Gemini, Ollama. Anthropic has no embedding API.

## Architecture

### Module Structure

Follows the ChatModel five-layer pattern:

| Layer | Module | What it contains |
|-------|--------|-----------------|
| SPI | `agent-router-core` | `EmbeddingModelBackend` interface + `SimpleEmbeddingModelBackend` record |
| Core | `agent-openai-core` | `OpenAiNativeEmbeddingModel` + `LangChain4jOpenAiEmbeddingMapper` |
| Core | `agent-gemini-core` | `GeminiNativeEmbeddingModel` + `LangChain4jGeminiEmbeddingMapper` |
| Quarkus CDI | `agent-openai`, `agent-gemini`, `agent-ollama` | `@Produces EmbeddingModelBackend` in existing `*Beans` classes |
| Spring | `agent-spring` | `*EmbeddingModelManualConfig` classes |
| Router | `agent-router-core` + `agent-router` + `agent-spring` | `RoutingEmbeddingModel` + CDI/Spring producers |

No new modules. All additions go into existing modules.

### SPI — `EmbeddingModelBackend`

```java
// In agent-router-core
public interface EmbeddingModelBackend {
    String key();
    EmbeddingModel embeddingModel();
}

public record SimpleEmbeddingModelBackend(String key, EmbeddingModel embeddingModel)
    implements EmbeddingModelBackend {}
```

Parallel to `ChatModelBackend` / `SimpleChatModelBackend`.

### RoutingEmbeddingModel

```java
// In agent-router-core
public class RoutingEmbeddingModel implements EmbeddingModel {
    // Constructor: List<EmbeddingModelBackend>, ModelRegistry, String defaultBackendKey
    // doEmbed(): resolve modelName → ModelDescriptor → backendKey → EmbeddingModelBackend
    // Fallback: defaultBackendKey if model not in registry
}
```

Same resolution logic as `RoutingChatModel`: modelName → `ModelRegistry.resolveById()` → `descriptor.backendKey()` → backend map lookup.

### Native Implementations

**`OpenAiNativeEmbeddingModel`** (in `agent-openai-core`):
- Constructor: `OpenAIClient`, `defaultModel`, `defaultDimensions` (nullable Integer)
- Overrides `doEmbed(EmbeddingRequest)`: extracts texts from inputs, builds `EmbeddingCreateParams` with model/dimensions, calls `client.embeddings().create()`, maps response via `LangChain4jOpenAiEmbeddingMapper`
- `dimension()`: returns configured dimensions or calls super (which embeds "test")
- `modelName()`: returns defaultModel

**`LangChain4jOpenAiEmbeddingMapper`** (in `agent-openai-core`):
- `toEmbeddingResponse(CreateEmbeddingResponse)` → `EmbeddingResponse` (LangChain4j)
- Maps `List<com.openai.models.Embedding>` → `List<dev.langchain4j.data.embedding.Embedding>`
- Maps `Usage` → `TokenUsage`

**`GeminiNativeEmbeddingModel`** (in `agent-gemini-core`):
- Constructor: `Client`, `defaultModel`, `defaultDimensions` (nullable Integer)
- Overrides `doEmbed(EmbeddingRequest)`: extracts texts, builds `EmbedContentConfig` with outputDimensionality + taskType mapping, calls `client.models.embedContent()`, maps response via `LangChain4jGeminiEmbeddingMapper`
- TaskType mapping: `EmbeddingInputType.QUERY` → `RETRIEVAL_QUERY`, `DOCUMENT` → `RETRIEVAL_DOCUMENT`, null → omitted

**`LangChain4jGeminiEmbeddingMapper`** (in `agent-gemini-core`):
- `toEmbeddingResponse(EmbedContentResponse)` → `EmbeddingResponse`
- Maps `List<ContentEmbedding>` → `List<Embedding>` via `values()` → `float[]`
- Maps `EmbedContentMetadata.billableCharacterCount()` → `TokenUsage` (approximate)

**Ollama**: Reuses `OpenAiNativeEmbeddingModel` with `baseUrl(host + "/v1/")` and `apiKey("ollama")` — same pattern as ChatModel.

### CDI Wiring

Add `@Produces @ApplicationScoped EmbeddingModelBackend` methods to existing beans:

- `OpenAiBeans.openAiEmbeddingModelBackend(OpenAiAgentConfig)` → `SimpleEmbeddingModelBackend("openai", ...)`
- `GeminiBeans.geminiEmbeddingModelBackend(GeminiAgentConfig)` → `SimpleEmbeddingModelBackend("gemini", ...)`
- `OllamaBeans.ollamaEmbeddingModelBackend(OllamaAgentConfig)` → `SimpleEmbeddingModelBackend("ollama", ...)`
- `RouterBeans`: `@Produces @DefaultBean EmbeddingModel routingEmbeddingModel(Instance<EmbeddingModelBackend>, ModelRegistry, ...)` → `RoutingEmbeddingModel`

### Spring Wiring

Hand-written `@AutoConfiguration` classes in `agent-spring`:

- `OpenAiEmbeddingModelManualConfig` → `@Bean EmbeddingModelBackend` with `@ConditionalOnClass(OpenAiNativeEmbeddingModel.class)`
- `GeminiEmbeddingModelManualConfig` → `@Bean EmbeddingModelBackend` with `@ConditionalOnClass(GeminiNativeEmbeddingModel.class)`
- `OllamaEmbeddingModelManualConfig` → `@Bean EmbeddingModelBackend` with `@ConditionalOnClass(OpenAiNativeEmbeddingModel.class)`
- `EmbeddingModelRouterManualConfig` → `@Bean @ConditionalOnMissingBean(EmbeddingModel.class) EmbeddingModel`

Register all in `AutoConfiguration.imports`.

### Configuration

Reuse existing agent config properties — no new config keys needed. Each backend uses its existing `api-key`, `default-model`, `default-timeout` from `casehub.platform.agent.<backend>.*`. Embedding model name comes from the request's `modelName` parameter or the backend's `defaultModel`.

Optional per-backend embedding-specific config (e.g., default dimensions) can be added later if needed — the initial implementation uses the model's native dimensions.

## Testing

- **Mapper tests** (pattern from `LangChain4jGeminiMapperTest`): test `toEmbeddingResponse()` with constructed SDK response objects for each backend
- **RoutingEmbeddingModel test**: mock backends, verify resolution logic (same pattern as `RoutingChatModel` tests if they exist)

## Migration Path (Neocortex)

No neocortex changes needed for this issue. Neocortex already injects `EmbeddingModel` via CDI. When platform's `RoutingEmbeddingModel` is on the classpath, it becomes the CDI-produced `EmbeddingModel` bean, displacing the current ONNX producer. Neocortex consumers continue to call `embed()`, `embedAll()`, `dimension()` unchanged.

The migration is: replace neocortex's `ExampleModelProducer` (which creates an ONNX `EmbeddingModel`) with a platform dependency that provides the `RoutingEmbeddingModel` bean. This is a consumer-side change tracked separately.

## Files to Create/Modify

**New files (8):**
1. `agent-router-core/.../EmbeddingModelBackend.java`
2. `agent-router-core/.../SimpleEmbeddingModelBackend.java`
3. `agent-router-core/.../RoutingEmbeddingModel.java`
4. `agent-openai-core/.../OpenAiNativeEmbeddingModel.java`
5. `agent-openai-core/.../LangChain4jOpenAiEmbeddingMapper.java`
6. `agent-gemini-core/.../GeminiNativeEmbeddingModel.java`
7. `agent-gemini-core/.../LangChain4jGeminiEmbeddingMapper.java`
8. `agent-spring/.../EmbeddingModelRouterManualConfig.java`

**Modified files (7):**
9. `agent-openai/...OpenAiBeans.java` — add EmbeddingModelBackend producer
10. `agent-gemini/...GeminiBeans.java` — add EmbeddingModelBackend producer
11. `agent-ollama/...OllamaBeans.java` — add EmbeddingModelBackend producer
12. `agent-router/...RouterBeans.java` — add RoutingEmbeddingModel producer
13. `agent-spring/...OpenAiChatModelManualConfig.java` or new file — add EmbeddingModelBackend bean
14. `agent-spring/...AutoConfiguration.imports` — register new configs
15. `CLAUDE.md` — document new types

**New test files (2-3):**
16. `agent-openai-core/...LangChain4jOpenAiEmbeddingMapperTest.java`
17. `agent-gemini-core/...LangChain4jGeminiEmbeddingMapperTest.java`

## References

- `agent-router-core/ChatModelBackend.java` — SPI pattern to replicate
- `agent-router-core/RoutingChatModel.java` — routing pattern to replicate
- `agent-openai-core/OpenAiNativeChatModel.java` — native impl pattern
- `agent-gemini-core/GeminiNativeChatModel.java` — native impl pattern
- `agent-claude/ClaudeBeans.java` — CDI producer pattern
- `agent-spring/ClaudeChatModelManualConfig.java` — Spring config pattern
- LangChain4j `EmbeddingModel` interface (v1.19.0) — `doEmbed(EmbeddingRequest)` override point
- Google GenAI SDK `Models.embedContent()` — Gemini embedding API
- OpenAI SDK `EmbeddingService.create()` — OpenAI embedding API
- casehubio/platform#640, #641 — ChatModel precedent
