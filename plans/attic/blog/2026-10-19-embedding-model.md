# EmbeddingModel Platform Abstraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #642 — Design EmbeddingModel platform abstraction
**Issue group:** #642

**Goal:** Add EmbeddingModel routing to platform — native implementations for OpenAI, Gemini, Ollama behind LangChain4j's EmbeddingModel interface, with RoutingEmbeddingModel dispatching via ModelRegistry.

**Architecture:** Follows the ChatModel five-layer pattern from #640/#641. `EmbeddingModelBackend` SPI in agent-router-core, native `*NativeEmbeddingModel` implementations in core modules, CDI + Spring wiring, `RoutingEmbeddingModel` for model-registry-backed dispatch.

**Tech Stack:** LangChain4j 1.19.0 (EmbeddingModel interface), OpenAI Java SDK 4.50.0, Google GenAI SDK 1.65.0, Quarkus CDI, Spring Boot auto-configuration.

## Global Constraints

- `agent-*-core` modules must remain framework-neutral (no CDI, no Spring)
- `platform-api` must remain zero-dependency
- Mappers are package-private, static methods, private constructor
- Static final ObjectMapper for JSON serialization
- No Anthropic embedding backend (Claude doesn't offer embeddings)
- Ollama reuses OpenAI SDK with custom baseUrl — no separate core implementation

---

## Batch 1: SPI + Router Foundation

### Task 1: EmbeddingModelBackend SPI and RoutingEmbeddingModel

**Files:**
- Create: `agent-router-core/src/main/java/io/casehub/platform/agent/router/EmbeddingModelBackend.java`
- Create: `agent-router-core/src/main/java/io/casehub/platform/agent/router/SimpleEmbeddingModelBackend.java`
- Create: `agent-router-core/src/main/java/io/casehub/platform/agent/router/RoutingEmbeddingModel.java`
- Test: `agent-router-core/src/test/java/io/casehub/platform/agent/router/RoutingEmbeddingModelTest.java`

**Interfaces:**
- Produces: `EmbeddingModelBackend` (interface: `key()` + `embeddingModel()`), `SimpleEmbeddingModelBackend` (record), `RoutingEmbeddingModel` (implements `dev.langchain4j.model.embedding.EmbeddingModel`)

- [ ] **Step 1: Create EmbeddingModelBackend interface**

Use `ide_create_file`:

```java
package io.casehub.platform.agent.router;

import dev.langchain4j.model.embedding.EmbeddingModel;

public interface EmbeddingModelBackend {
    String key();
    EmbeddingModel embeddingModel();
}
```

- [ ] **Step 2: Create SimpleEmbeddingModelBackend record**

Use `ide_create_file`:

```java
package io.casehub.platform.agent.router;

import dev.langchain4j.model.embedding.EmbeddingModel;

public record SimpleEmbeddingModelBackend(String key, EmbeddingModel embeddingModel)
    implements EmbeddingModelBackend {}
```

- [ ] **Step 3: Write failing test for RoutingEmbeddingModel**

Use `ide_create_file`:

```java
package io.casehub.platform.agent.router;

import dev.langchain4j.data.embedding.Embedding;
import dev.langchain4j.model.embedding.EmbeddingModel;
import dev.langchain4j.model.embedding.request.EmbeddingRequest;
import dev.langchain4j.model.embedding.response.EmbeddingResponse;
import dev.langchain4j.model.embedding.response.EmbeddingResponseMetadata;
import io.casehub.platform.api.model.ModelDescriptor;
import io.casehub.platform.api.model.ModelRegistry;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class RoutingEmbeddingModelTest {

    @Test
    void routesToBackendViaModelRegistry() {
        var openAiModel = stubEmbeddingModel("openai-result");
        var geminiModel = stubEmbeddingModel("gemini-result");
        var backends = List.<EmbeddingModelBackend>of(
                new SimpleEmbeddingModelBackend("openai", openAiModel),
                new SimpleEmbeddingModelBackend("gemini", geminiModel));

        var registry = mock(ModelRegistry.class);
        var descriptor = mock(ModelDescriptor.class);
        when(descriptor.backendKey()).thenReturn("gemini");
        when(registry.resolveById("text-embedding-004")).thenReturn(Optional.of(descriptor));

        var router = new RoutingEmbeddingModel(backends, registry, "openai");

        var request = EmbeddingRequest.builder().input("test").modelName("text-embedding-004").build();
        var response = router.doEmbed(request);

        assertThat(response.metadata().modelName()).isEqualTo("gemini-result");
    }

    @Test
    void fallsBackToDefaultWhenModelNotInRegistry() {
        var openAiModel = stubEmbeddingModel("openai-result");
        var backends = List.<EmbeddingModelBackend>of(
                new SimpleEmbeddingModelBackend("openai", openAiModel));

        var registry = mock(ModelRegistry.class);
        when(registry.resolveById("unknown-model")).thenReturn(Optional.empty());

        var router = new RoutingEmbeddingModel(backends, registry, "openai");

        var request = EmbeddingRequest.builder().input("test").modelName("unknown-model").build();
        var response = router.doEmbed(request);

        assertThat(response.metadata().modelName()).isEqualTo("openai-result");
    }

    @Test
    void throwsWhenNoBackendAvailable() {
        var registry = mock(ModelRegistry.class);
        var router = new RoutingEmbeddingModel(List.of(), registry, "openai");

        var request = EmbeddingRequest.builder().input("test").build();
        assertThatThrownBy(() -> router.doEmbed(request))
                .isInstanceOf(IllegalStateException.class);
    }

    private static EmbeddingModel stubEmbeddingModel(String modelName) {
        return new EmbeddingModel() {
            @Override
            public EmbeddingResponse doEmbed(EmbeddingRequest request) {
                return EmbeddingResponse.builder()
                        .embeddings(List.of(Embedding.from(new float[]{1.0f, 2.0f, 3.0f})))
                        .metadata(EmbeddingResponseMetadata.builder().modelName(modelName).build())
                        .build();
            }
        };
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `mvn --batch-mode -pl agent-router-core -am test -Dtest=RoutingEmbeddingModelTest`
Expected: FAIL — `RoutingEmbeddingModel` does not exist

- [ ] **Step 5: Implement RoutingEmbeddingModel**

Use `ide_create_file`:

```java
package io.casehub.platform.agent.router;

import dev.langchain4j.model.embedding.EmbeddingModel;
import dev.langchain4j.model.embedding.request.EmbeddingRequest;
import dev.langchain4j.model.embedding.response.EmbeddingResponse;
import io.casehub.platform.api.model.ModelDescriptor;
import io.casehub.platform.api.model.ModelRegistry;
import org.jboss.logging.Logger;

import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.function.Function;
import java.util.stream.Collectors;

public class RoutingEmbeddingModel implements EmbeddingModel {

    private static final Logger LOG = Logger.getLogger(RoutingEmbeddingModel.class);

    private final Map<String, EmbeddingModelBackend> backends;
    private final ModelRegistry modelRegistry;
    private final String defaultBackendKey;

    public RoutingEmbeddingModel(List<EmbeddingModelBackend> backends, ModelRegistry modelRegistry,
                                  String defaultBackendKey) {
        this.backends = backends.stream()
                .collect(Collectors.toMap(EmbeddingModelBackend::key, Function.identity()));
        this.modelRegistry = Objects.requireNonNull(modelRegistry, "modelRegistry");
        this.defaultBackendKey = defaultBackendKey;
        LOG.infof("EmbeddingModel router initialized with %d backends, default=%s",
                this.backends.size(), defaultBackendKey);
    }

    @Override
    public EmbeddingResponse doEmbed(EmbeddingRequest request) {
        String modelName = request.modelName();
        EmbeddingModelBackend backend = resolveBackend(modelName);
        return backend.embeddingModel().doEmbed(request);
    }

    private EmbeddingModelBackend resolveBackend(String modelName) {
        if (modelName != null) {
            Optional<ModelDescriptor> descriptor = modelRegistry.resolveById(modelName);
            if (descriptor.isPresent()) {
                EmbeddingModelBackend backend = backends.get(descriptor.get().backendKey());
                if (backend != null) {
                    return backend;
                }
                LOG.warnf("No EmbeddingModel backend for key '%s' (model '%s'), falling back to default",
                        descriptor.get().backendKey(), modelName);
            }
        }

        EmbeddingModelBackend defaultBackend = backends.get(defaultBackendKey);
        if (defaultBackend == null) {
            throw new IllegalStateException(
                    "No EmbeddingModel backend available. Requested model: " + modelName
                    + ", default backend: " + defaultBackendKey
                    + ", available: " + backends.keySet());
        }
        return defaultBackend;
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mvn --batch-mode -pl agent-router-core -am test -Dtest=RoutingEmbeddingModelTest`
Expected: PASS — all 3 tests green

- [ ] **Step 7: Verify agent-router-core compiles with langchain4j-core**

`agent-router-core` already depends on `langchain4j-core` (for ChatModel). Verify EmbeddingModel import resolves.

Run: `mvn --batch-mode -pl agent-router-core -am compile`
Expected: BUILD SUCCESS

- [ ] **Step 8: Commit**

```bash
git add agent-router-core/src/main/java/io/casehub/platform/agent/router/EmbeddingModelBackend.java \
       agent-router-core/src/main/java/io/casehub/platform/agent/router/SimpleEmbeddingModelBackend.java \
       agent-router-core/src/main/java/io/casehub/platform/agent/router/RoutingEmbeddingModel.java \
       agent-router-core/src/test/java/io/casehub/platform/agent/router/RoutingEmbeddingModelTest.java
git commit -m "feat(#642): EmbeddingModelBackend SPI + RoutingEmbeddingModel"
```

---

## Batch 2: Native Implementations (OpenAI + Gemini)

### Task 2: OpenAI Native EmbeddingModel

**Files:**
- Create: `agent-openai-core/src/main/java/io/casehub/platform/agent/openai/OpenAiNativeEmbeddingModel.java`
- Create: `agent-openai-core/src/main/java/io/casehub/platform/agent/openai/LangChain4jOpenAiEmbeddingMapper.java`
- Test: `agent-openai-core/src/test/java/io/casehub/platform/agent/openai/LangChain4jOpenAiEmbeddingMapperTest.java`

**Interfaces:**
- Consumes: `com.openai.client.OpenAIClient`, `com.openai.models.EmbeddingCreateParams`, LangChain4j `EmbeddingRequest`/`EmbeddingResponse`
- Produces: `OpenAiNativeEmbeddingModel` (implements `dev.langchain4j.model.embedding.EmbeddingModel`), `LangChain4jOpenAiEmbeddingMapper`

- [ ] **Step 1: Write failing mapper test**

Use `ide_create_file` for `LangChain4jOpenAiEmbeddingMapperTest.java`:

```java
package io.casehub.platform.agent.openai;

import com.openai.models.CreateEmbeddingResponse;
import dev.langchain4j.model.embedding.response.EmbeddingResponse;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class LangChain4jOpenAiEmbeddingMapperTest {

    @Test
    void mapsEmbeddingResponse() {
        var openAiResponse = CreateEmbeddingResponse.builder()
                .data(java.util.List.of(
                        com.openai.models.Embedding.builder()
                                .embedding(java.util.List.of(0.1f, 0.2f, 0.3f))
                                .index(0)
                                .build()))
                .model("text-embedding-3-small")
                .usage(CreateEmbeddingResponse.Usage.builder()
                        .promptTokens(5)
                        .totalTokens(5)
                        .build())
                .build();

        EmbeddingResponse response = LangChain4jOpenAiEmbeddingMapper.toEmbeddingResponse(openAiResponse);

        assertThat(response.embeddings()).hasSize(1);
        assertThat(response.embeddings().get(0).vector()).containsExactly(0.1f, 0.2f, 0.3f);
        assertThat(response.metadata().modelName()).isEqualTo("text-embedding-3-small");
        assertThat(response.metadata().tokenUsage().inputTokenCount()).isEqualTo(5);
    }

    @Test
    void mapsBatchEmbeddingResponse() {
        var openAiResponse = CreateEmbeddingResponse.builder()
                .data(java.util.List.of(
                        com.openai.models.Embedding.builder()
                                .embedding(java.util.List.of(0.1f, 0.2f))
                                .index(0).build(),
                        com.openai.models.Embedding.builder()
                                .embedding(java.util.List.of(0.3f, 0.4f))
                                .index(1).build()))
                .model("text-embedding-3-small")
                .usage(CreateEmbeddingResponse.Usage.builder()
                        .promptTokens(10).totalTokens(10).build())
                .build();

        EmbeddingResponse response = LangChain4jOpenAiEmbeddingMapper.toEmbeddingResponse(openAiResponse);
        assertThat(response.embeddings()).hasSize(2);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode -pl agent-openai-core -am test -Dtest=LangChain4jOpenAiEmbeddingMapperTest`
Expected: FAIL

- [ ] **Step 3: Implement LangChain4jOpenAiEmbeddingMapper**

Use `ide_create_file`:

```java
package io.casehub.platform.agent.openai;

import com.openai.models.CreateEmbeddingResponse;
import dev.langchain4j.data.embedding.Embedding;
import dev.langchain4j.model.embedding.response.EmbeddingResponse;
import dev.langchain4j.model.embedding.response.EmbeddingResponseMetadata;
import dev.langchain4j.model.output.TokenUsage;

import java.util.List;

final class LangChain4jOpenAiEmbeddingMapper {

    private LangChain4jOpenAiEmbeddingMapper() {}

    static EmbeddingResponse toEmbeddingResponse(CreateEmbeddingResponse response) {
        List<Embedding> embeddings = response.data().stream()
                .map(e -> {
                    List<Float> floats = e.embedding();
                    float[] vector = new float[floats.size()];
                    for (int i = 0; i < floats.size(); i++) {
                        vector[i] = floats.get(i);
                    }
                    return Embedding.from(vector);
                })
                .toList();

        TokenUsage tokenUsage = new TokenUsage(
                (int) response.usage().promptTokens(),
                0,
                (int) response.usage().totalTokens());

        return EmbeddingResponse.builder()
                .embeddings(embeddings)
                .metadata(EmbeddingResponseMetadata.builder()
                        .modelName(response.model())
                        .tokenUsage(tokenUsage)
                        .build())
                .build();
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode -pl agent-openai-core -am test -Dtest=LangChain4jOpenAiEmbeddingMapperTest`
Expected: PASS

- [ ] **Step 5: Implement OpenAiNativeEmbeddingModel**

Use `ide_create_file`:

```java
package io.casehub.platform.agent.openai;

import com.openai.client.OpenAIClient;
import com.openai.models.EmbeddingCreateParams;
import dev.langchain4j.model.embedding.EmbeddingModel;
import dev.langchain4j.model.embedding.request.EmbeddingRequest;
import dev.langchain4j.model.embedding.response.EmbeddingResponse;

import java.util.Objects;

public class OpenAiNativeEmbeddingModel implements EmbeddingModel {

    private final OpenAIClient client;
    private final String defaultModel;
    private final Integer defaultDimensions;

    public OpenAiNativeEmbeddingModel(OpenAIClient client, String defaultModel, Integer defaultDimensions) {
        this.client = Objects.requireNonNull(client, "client");
        this.defaultModel = Objects.requireNonNull(defaultModel, "defaultModel");
        this.defaultDimensions = defaultDimensions;
    }

    @Override
    public EmbeddingResponse doEmbed(EmbeddingRequest request) {
        String modelName = request.modelName() != null ? request.modelName() : defaultModel;

        var texts = request.inputs().stream()
                .map(input -> input.text())
                .toList();

        var paramsBuilder = EmbeddingCreateParams.builder()
                .model(com.openai.models.EmbeddingModel.of(modelName))
                .inputOfArrayOfStrings(texts);

        Integer dimensions = request.dimensions() != null ? request.dimensions() : defaultDimensions;
        if (dimensions != null) {
            paramsBuilder.dimensions(dimensions.longValue());
        }

        var response = client.embeddings().create(paramsBuilder.build());
        return LangChain4jOpenAiEmbeddingMapper.toEmbeddingResponse(response);
    }

    @Override
    public String modelName() { return defaultModel; }
}
```

- [ ] **Step 6: Compile all**

Run: `mvn --batch-mode -pl agent-openai-core -am compile`
Expected: BUILD SUCCESS

- [ ] **Step 7: Commit**

```bash
git add agent-openai-core/src/main/java/io/casehub/platform/agent/openai/OpenAiNativeEmbeddingModel.java \
       agent-openai-core/src/main/java/io/casehub/platform/agent/openai/LangChain4jOpenAiEmbeddingMapper.java \
       agent-openai-core/src/test/java/io/casehub/platform/agent/openai/LangChain4jOpenAiEmbeddingMapperTest.java
git commit -m "feat(#642): OpenAI native EmbeddingModel + mapper"
```

### Task 3: Gemini Native EmbeddingModel

**Files:**
- Create: `agent-gemini-core/src/main/java/io/casehub/platform/agent/gemini/GeminiNativeEmbeddingModel.java`
- Create: `agent-gemini-core/src/main/java/io/casehub/platform/agent/gemini/LangChain4jGeminiEmbeddingMapper.java`
- Test: `agent-gemini-core/src/test/java/io/casehub/platform/agent/gemini/LangChain4jGeminiEmbeddingMapperTest.java`

**Interfaces:**
- Consumes: `com.google.genai.Client`, `com.google.genai.types.EmbedContentConfig`, LangChain4j `EmbeddingRequest`/`EmbeddingResponse`, `EmbeddingInputType`
- Produces: `GeminiNativeEmbeddingModel` (implements `dev.langchain4j.model.embedding.EmbeddingModel`), `LangChain4jGeminiEmbeddingMapper`

- [ ] **Step 1: Write failing mapper test**

Use `ide_create_file` for `LangChain4jGeminiEmbeddingMapperTest.java`:

```java
package io.casehub.platform.agent.gemini;

import com.google.genai.types.ContentEmbedding;
import com.google.genai.types.EmbedContentMetadata;
import com.google.genai.types.EmbedContentResponse;
import dev.langchain4j.model.embedding.response.EmbeddingResponse;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class LangChain4jGeminiEmbeddingMapperTest {

    @Test
    void mapsEmbeddingResponse() {
        var geminiResponse = EmbedContentResponse.builder()
                .embeddings(List.of(
                        ContentEmbedding.builder()
                                .values(List.of(0.1f, 0.2f, 0.3f))
                                .build()))
                .metadata(EmbedContentMetadata.builder()
                        .billableCharacterCount(25)
                        .build())
                .build();

        EmbeddingResponse response = LangChain4jGeminiEmbeddingMapper.toEmbeddingResponse(
                geminiResponse, "text-embedding-004");

        assertThat(response.embeddings()).hasSize(1);
        assertThat(response.embeddings().get(0).vector()).containsExactly(0.1f, 0.2f, 0.3f);
        assertThat(response.metadata().modelName()).isEqualTo("text-embedding-004");
    }

    @Test
    void mapsBatchEmbeddingResponse() {
        var geminiResponse = EmbedContentResponse.builder()
                .embeddings(List.of(
                        ContentEmbedding.builder().values(List.of(0.1f, 0.2f)).build(),
                        ContentEmbedding.builder().values(List.of(0.3f, 0.4f)).build()))
                .build();

        EmbeddingResponse response = LangChain4jGeminiEmbeddingMapper.toEmbeddingResponse(
                geminiResponse, "text-embedding-004");
        assertThat(response.embeddings()).hasSize(2);
    }

    @Test
    void mapsTaskType() {
        assertThat(LangChain4jGeminiEmbeddingMapper.toGeminiTaskType(
                dev.langchain4j.model.embedding.request.EmbeddingInputType.QUERY))
                .isEqualTo("RETRIEVAL_QUERY");
        assertThat(LangChain4jGeminiEmbeddingMapper.toGeminiTaskType(
                dev.langchain4j.model.embedding.request.EmbeddingInputType.DOCUMENT))
                .isEqualTo("RETRIEVAL_DOCUMENT");
        assertThat(LangChain4jGeminiEmbeddingMapper.toGeminiTaskType(null)).isNull();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode -pl agent-gemini-core -am test -Dtest=LangChain4jGeminiEmbeddingMapperTest`
Expected: FAIL

- [ ] **Step 3: Implement LangChain4jGeminiEmbeddingMapper**

Use `ide_create_file`:

```java
package io.casehub.platform.agent.gemini;

import com.google.genai.types.ContentEmbedding;
import com.google.genai.types.EmbedContentResponse;
import dev.langchain4j.data.embedding.Embedding;
import dev.langchain4j.model.embedding.request.EmbeddingInputType;
import dev.langchain4j.model.embedding.response.EmbeddingResponse;
import dev.langchain4j.model.embedding.response.EmbeddingResponseMetadata;
import dev.langchain4j.model.output.TokenUsage;

import java.util.List;

final class LangChain4jGeminiEmbeddingMapper {

    private LangChain4jGeminiEmbeddingMapper() {}

    static EmbeddingResponse toEmbeddingResponse(EmbedContentResponse response, String modelName) {
        List<Embedding> embeddings = response.embeddings()
                .orElse(List.of())
                .stream()
                .map(ce -> {
                    List<Float> values = ce.values().orElse(List.of());
                    float[] vector = new float[values.size()];
                    for (int i = 0; i < values.size(); i++) {
                        vector[i] = values.get(i);
                    }
                    return Embedding.from(vector);
                })
                .toList();

        TokenUsage tokenUsage = null;
        if (response.metadata().isPresent()) {
            int chars = response.metadata().get().billableCharacterCount().orElse(0);
            tokenUsage = new TokenUsage(chars, 0);
        }

        return EmbeddingResponse.builder()
                .embeddings(embeddings)
                .metadata(EmbeddingResponseMetadata.builder()
                        .modelName(modelName)
                        .tokenUsage(tokenUsage)
                        .build())
                .build();
    }

    static String toGeminiTaskType(EmbeddingInputType inputType) {
        if (inputType == null) return null;
        return switch (inputType) {
            case QUERY -> "RETRIEVAL_QUERY";
            case DOCUMENT -> "RETRIEVAL_DOCUMENT";
        };
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode -pl agent-gemini-core -am test -Dtest=LangChain4jGeminiEmbeddingMapperTest`
Expected: PASS

- [ ] **Step 5: Implement GeminiNativeEmbeddingModel**

Use `ide_create_file`:

```java
package io.casehub.platform.agent.gemini;

import com.google.genai.Client;
import com.google.genai.types.EmbedContentConfig;
import dev.langchain4j.model.embedding.EmbeddingModel;
import dev.langchain4j.model.embedding.request.EmbeddingRequest;
import dev.langchain4j.model.embedding.response.EmbeddingResponse;

import java.util.Objects;

public class GeminiNativeEmbeddingModel implements EmbeddingModel {

    private final Client client;
    private final String defaultModel;
    private final Integer defaultDimensions;

    public GeminiNativeEmbeddingModel(Client client, String defaultModel, Integer defaultDimensions) {
        this.client = Objects.requireNonNull(client, "client");
        this.defaultModel = Objects.requireNonNull(defaultModel, "defaultModel");
        this.defaultDimensions = defaultDimensions;
    }

    @Override
    public EmbeddingResponse doEmbed(EmbeddingRequest request) {
        String modelName = request.modelName() != null ? request.modelName() : defaultModel;

        var texts = request.inputs().stream()
                .map(input -> input.text())
                .toList();

        var configBuilder = EmbedContentConfig.builder();

        Integer dimensions = request.dimensions() != null ? request.dimensions() : defaultDimensions;
        if (dimensions != null) {
            configBuilder.outputDimensionality(dimensions);
        }

        String taskType = LangChain4jGeminiEmbeddingMapper.toGeminiTaskType(request.inputType());
        if (taskType != null) {
            configBuilder.taskType(taskType);
        }

        var response = client.models.embedContent(modelName, texts, configBuilder.build());
        return LangChain4jGeminiEmbeddingMapper.toEmbeddingResponse(response, modelName);
    }

    @Override
    public String modelName() { return defaultModel; }
}
```

- [ ] **Step 6: Compile all**

Run: `mvn --batch-mode -pl agent-gemini-core -am compile`
Expected: BUILD SUCCESS

- [ ] **Step 7: Commit**

```bash
git add agent-gemini-core/src/main/java/io/casehub/platform/agent/gemini/GeminiNativeEmbeddingModel.java \
       agent-gemini-core/src/main/java/io/casehub/platform/agent/gemini/LangChain4jGeminiEmbeddingMapper.java \
       agent-gemini-core/src/test/java/io/casehub/platform/agent/gemini/LangChain4jGeminiEmbeddingMapperTest.java
git commit -m "feat(#642): Gemini native EmbeddingModel + mapper with taskType support"
```

---

## Batch 3: CDI + Spring Wiring

### Task 4: CDI Producers + Spring Auto-Configuration

**Files:**
- Modify: `agent-openai/src/main/java/io/casehub/platform/agent/openai/quarkus/OpenAiBeans.java` — add EmbeddingModelBackend producer
- Modify: `agent-gemini/src/main/java/io/casehub/platform/agent/gemini/quarkus/GeminiBeans.java` — add EmbeddingModelBackend producer
- Modify: `agent-ollama/src/main/java/io/casehub/platform/agent/ollama/quarkus/OllamaBeans.java` — add EmbeddingModelBackend producer
- Modify: `agent-router/src/main/java/io/casehub/platform/agent/router/quarkus/RouterBeans.java` — add RoutingEmbeddingModel producer
- Create: `agent-spring/src/main/java/io/casehub/platform/agent/openai/spring/OpenAiEmbeddingModelManualConfig.java`
- Create: `agent-spring/src/main/java/io/casehub/platform/agent/gemini/spring/GeminiEmbeddingModelManualConfig.java`
- Create: `agent-spring/src/main/java/io/casehub/platform/agent/ollama/spring/OllamaEmbeddingModelManualConfig.java`
- Create: `agent-spring/src/main/java/io/casehub/platform/agent/router/spring/EmbeddingModelRouterManualConfig.java`
- Modify: `agent-spring/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` — register new configs

**Interfaces:**
- Consumes: `EmbeddingModelBackend`, `SimpleEmbeddingModelBackend`, `RoutingEmbeddingModel`, `OpenAiNativeEmbeddingModel`, `GeminiNativeEmbeddingModel`, `OpenAiNativeChatModel` (for Ollama reuse)

- [ ] **Step 1: Add EmbeddingModelBackend producer to OpenAiBeans**

Use `ide_insert_member` on `OpenAiBeans`, position `after` anchor `openAiChatModelBackend`:

```java
@Produces
@ApplicationScoped
public io.casehub.platform.agent.router.EmbeddingModelBackend openAiEmbeddingModelBackend(OpenAiAgentConfig config) {
    var clientBuilder = com.openai.client.okhttp.OpenAIOkHttpClient.builder();
    config.apiKey().ifPresent(clientBuilder::apiKey);
    OpenAiNativeEmbeddingModel embeddingModel = new OpenAiNativeEmbeddingModel(
            clientBuilder.build(), "text-embedding-3-small", null);
    return new io.casehub.platform.agent.router.SimpleEmbeddingModelBackend("openai", embeddingModel);
}
```

Add import: `io.casehub.platform.agent.openai.OpenAiNativeEmbeddingModel`

- [ ] **Step 2: Add EmbeddingModelBackend producer to GeminiBeans**

Use `ide_insert_member` on `GeminiBeans`, position `after` anchor `geminiChatModelBackend`:

```java
@Produces
@ApplicationScoped
public io.casehub.platform.agent.router.EmbeddingModelBackend geminiEmbeddingModelBackend(GeminiAgentConfig config) {
    var clientBuilder = com.google.genai.Client.builder();
    config.apiKey().ifPresent(clientBuilder::apiKey);
    io.casehub.platform.agent.gemini.GeminiNativeEmbeddingModel embeddingModel =
            new io.casehub.platform.agent.gemini.GeminiNativeEmbeddingModel(
                    clientBuilder.build(), "text-embedding-004", null);
    return new io.casehub.platform.agent.router.SimpleEmbeddingModelBackend("gemini", embeddingModel);
}
```

- [ ] **Step 3: Add EmbeddingModelBackend producer to OllamaBeans**

Use `ide_insert_member` on `OllamaBeans`, position `after` anchor `ollamaChatModelBackend`:

```java
@Produces
@ApplicationScoped
public io.casehub.platform.agent.router.EmbeddingModelBackend ollamaEmbeddingModelBackend(OllamaAgentConfig config) {
    var client = com.openai.client.okhttp.OpenAIOkHttpClient.builder()
            .baseUrl(config.host() + "/v1/")
            .apiKey("ollama")
            .build();
    io.casehub.platform.agent.openai.OpenAiNativeEmbeddingModel embeddingModel =
            new io.casehub.platform.agent.openai.OpenAiNativeEmbeddingModel(
                    client, config.defaultModel(), null);
    return new io.casehub.platform.agent.router.SimpleEmbeddingModelBackend("ollama", embeddingModel);
}
```

- [ ] **Step 4: Add RoutingEmbeddingModel producer to RouterBeans**

Use `ide_insert_member` on `RouterBeans`, position `after` anchor `routingChatModel`. Add field injection for `Instance<EmbeddingModelBackend>` via `ide_insert_member` with position `after` anchor `chatModelBackends`.

Field:
```java
@Inject
@Any
Instance<io.casehub.platform.agent.router.EmbeddingModelBackend> embeddingModelBackends;
```

Producer:
```java
@Produces
@ApplicationScoped
@io.quarkus.arc.DefaultBean
public dev.langchain4j.model.embedding.EmbeddingModel routingEmbeddingModel(RoutingAgentConfig config) {
    List<io.casehub.platform.agent.router.EmbeddingModelBackend> backendList = new ArrayList<>();
    embeddingModelBackends.forEach(backendList::add);
    return new io.casehub.platform.agent.router.RoutingEmbeddingModel(
            backendList, modelRegistry, config.defaultBackend());
}
```

- [ ] **Step 5: Create Spring auto-configurations**

Use `ide_create_file` for each:

**OpenAiEmbeddingModelManualConfig.java:**
```java
package io.casehub.platform.agent.openai.spring;

import io.casehub.platform.agent.openai.OpenAiAgentProperties;
import io.casehub.platform.agent.openai.OpenAiNativeEmbeddingModel;
import io.casehub.platform.agent.router.EmbeddingModelBackend;
import io.casehub.platform.agent.router.SimpleEmbeddingModelBackend;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.context.annotation.Bean;

@AutoConfiguration
@ConditionalOnClass(OpenAiNativeEmbeddingModel.class)
public class OpenAiEmbeddingModelManualConfig {
    @Bean
    public EmbeddingModelBackend openAiEmbeddingModelBackend(OpenAiAgentProperties properties) {
        var clientBuilder = com.openai.client.okhttp.OpenAIOkHttpClient.builder();
        properties.apiKey().ifPresent(clientBuilder::apiKey);
        OpenAiNativeEmbeddingModel embeddingModel = new OpenAiNativeEmbeddingModel(
                clientBuilder.build(), "text-embedding-3-small", null);
        return new SimpleEmbeddingModelBackend("openai", embeddingModel);
    }
}
```

**GeminiEmbeddingModelManualConfig.java:**
```java
package io.casehub.platform.agent.gemini.spring;

import io.casehub.platform.agent.gemini.GeminiAgentProperties;
import io.casehub.platform.agent.gemini.GeminiNativeEmbeddingModel;
import io.casehub.platform.agent.router.EmbeddingModelBackend;
import io.casehub.platform.agent.router.SimpleEmbeddingModelBackend;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.context.annotation.Bean;

@AutoConfiguration
@ConditionalOnClass(GeminiNativeEmbeddingModel.class)
public class GeminiEmbeddingModelManualConfig {
    @Bean
    public EmbeddingModelBackend geminiEmbeddingModelBackend(GeminiAgentProperties properties) {
        var clientBuilder = com.google.genai.Client.builder();
        properties.apiKey().ifPresent(clientBuilder::apiKey);
        GeminiNativeEmbeddingModel embeddingModel = new GeminiNativeEmbeddingModel(
                clientBuilder.build(), "text-embedding-004", null);
        return new SimpleEmbeddingModelBackend("gemini", embeddingModel);
    }
}
```

**OllamaEmbeddingModelManualConfig.java:**
```java
package io.casehub.platform.agent.ollama.spring;

import io.casehub.platform.agent.ollama.OllamaAgentProperties;
import io.casehub.platform.agent.openai.OpenAiNativeEmbeddingModel;
import io.casehub.platform.agent.router.EmbeddingModelBackend;
import io.casehub.platform.agent.router.SimpleEmbeddingModelBackend;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.context.annotation.Bean;

@AutoConfiguration
@ConditionalOnClass(OpenAiNativeEmbeddingModel.class)
public class OllamaEmbeddingModelManualConfig {
    @Bean
    public EmbeddingModelBackend ollamaEmbeddingModelBackend(OllamaAgentProperties properties) {
        var client = com.openai.client.okhttp.OpenAIOkHttpClient.builder()
                .baseUrl(properties.host() + "/v1/")
                .apiKey("ollama")
                .build();
        OpenAiNativeEmbeddingModel embeddingModel = new OpenAiNativeEmbeddingModel(
                client, properties.defaultModel(), null);
        return new SimpleEmbeddingModelBackend("ollama", embeddingModel);
    }
}
```

**EmbeddingModelRouterManualConfig.java:**
```java
package io.casehub.platform.agent.router.spring;

import dev.langchain4j.model.embedding.EmbeddingModel;
import io.casehub.platform.agent.router.EmbeddingModelBackend;
import io.casehub.platform.agent.router.RoutingEmbeddingModel;
import io.casehub.platform.api.model.ModelRegistry;
import java.util.List;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.Bean;

@AutoConfiguration
@ConditionalOnClass(RoutingEmbeddingModel.class)
public class EmbeddingModelRouterManualConfig {
    @Bean
    @ConditionalOnMissingBean(EmbeddingModel.class)
    public EmbeddingModel routingEmbeddingModel(
            List<EmbeddingModelBackend> backends,
            ModelRegistry modelRegistry,
            @Value("${casehub.platform.agent.default-backend:openai}") String defaultBackend) {
        return new RoutingEmbeddingModel(backends, modelRegistry, defaultBackend);
    }
}
```

- [ ] **Step 6: Register in AutoConfiguration.imports**

Use `ide_replace_text_in_file` to add 4 lines before the router ChatModel config:

```
io.casehub.platform.agent.openai.spring.OpenAiEmbeddingModelManualConfig
io.casehub.platform.agent.gemini.spring.GeminiEmbeddingModelManualConfig
io.casehub.platform.agent.ollama.spring.OllamaEmbeddingModelManualConfig
io.casehub.platform.agent.router.spring.EmbeddingModelRouterManualConfig
```

- [ ] **Step 7: Compile all changed modules**

Run: `mvn --batch-mode -pl agent-openai,agent-gemini,agent-ollama,agent-router,agent-spring -am compile`
Expected: BUILD SUCCESS

- [ ] **Step 8: Commit**

```bash
git add agent-openai/src agent-gemini/src agent-ollama/src agent-router/src \
       agent-spring/src
git commit -m "feat(#642): CDI + Spring wiring for EmbeddingModel routing"
```

### Task 5: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` — update module entries for agent-router-core, agent-openai-core, agent-gemini-core, agent-openai, agent-gemini, agent-ollama, agent-router, agent-spring

- [ ] **Step 1: Update module descriptions**

Add EmbeddingModel types to the relevant module entries in the module table. Key additions:
- `agent-router-core`: add `EmbeddingModelBackend`, `SimpleEmbeddingModelBackend`, `RoutingEmbeddingModel`
- `agent-openai-core`: add `OpenAiNativeEmbeddingModel`, `LangChain4jOpenAiEmbeddingMapper`
- `agent-gemini-core`: add `GeminiNativeEmbeddingModel`, `LangChain4jGeminiEmbeddingMapper`
- CDI modules: add `EmbeddingModelBackend` producer mention
- `agent-spring`: add embedding model manual configs (from 5 to 9 hand-written configs)

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(#642): update CLAUDE.md for EmbeddingModel abstraction

Closes #642"
```

## References

- [2026-10-19-embedding-model-design.md] — design spec this plan implements
- [agent-router-core/ChatModelBackend.java] — SPI pattern replicated for EmbeddingModel
- [agent-router-core/RoutingChatModel.java] — routing pattern replicated
- [agent-openai-core/OpenAiNativeChatModel.java] — native impl pattern
- [agent-gemini-core/GeminiNativeChatModel.java] — native impl pattern
- [agent-router/RouterBeans.java] — CDI producer pattern
- [agent-spring/ChatModelRouterManualConfig.java] — Spring config pattern
- [GitHub #640] — ChatModel reconciliation (established pattern)
- [GitHub #641] — Gemini/Ollama ChatModel (validated pattern for these backends)
