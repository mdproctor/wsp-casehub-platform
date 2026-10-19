## D1: SPI approach — implement LangChain4j EmbeddingModel directly

**Choice:** Native implementations implement `dev.langchain4j.model.embedding.EmbeddingModel` (override `doEmbed(EmbeddingRequest)`), following the exact ChatModel pattern from #640/#641.
**Alternatives:**
- Own platform SPI — more control but requires neocortex migration and parallel type hierarchy
- Thin wrapper — extra indirection with unclear benefit
**Rationale:** Neocortex already injects `EmbeddingModel` via CDI. Using the same interface means zero consumer changes. The ChatModel pattern proved this works cleanly with native SDK calls behind LangChain4j's interface.
**Trade-offs:** Coupled to LangChain4j's EmbeddingModel evolution (but they're on 1.19.0 and the new API is stable since 1.18.0).
**Sources:** agent-claude-core/AnthropicNativeChatModel.java, agent-openai-core/OpenAiNativeChatModel.java, LangChain4j EmbeddingModel interface (1.19.0)
**Exploration:** quick
**Status:** captured

## D2: Backend coverage — OpenAI + Gemini + Ollama

**Choice:** Implement native EmbeddingModel for all three backends with embedding APIs. Ollama reuses OpenAI SDK (same as OllamaAgentBackend and Ollama ChatModel).
**Alternatives:**
- OpenAI + Ollama only — smaller scope but Gemini embedding is straightforward given existing SDK usage
- OpenAI only — too minimal, Ollama is free since it reuses OpenAI
**Rationale:** Anthropic has no embedding API. All other backends are covered. Gemini is mechanical given the mapper pattern from #641.
**Trade-offs:** None significant — all three follow the same pattern.
**Sources:** Google GenAI SDK 1.65.0 embedContent(), OpenAI SDK 4.50.0 EmbeddingService, Anthropic SDK (confirmed no embedding support)
**Exploration:** quick
**Status:** captured

## D3: Task type handling — pass through LangChain4j inputType

**Choice:** Map LangChain4j's `EmbeddingInputType` (QUERY, DOCUMENT) to Google's `taskType` in the Gemini mapper. OpenAI/Ollama backends ignore it.
**Alternatives:**
- Platform-level enum — adds a type consumers must learn with no clear benefit over LangChain4j's existing type
- Ignore entirely — simpler but degrades Gemini asymmetric retrieval quality
**Rationale:** LangChain4j already models this concept. The Gemini mapper is the right place to translate. No platform abstraction needed.
**Trade-offs:** Google's richer taskType (SEMANTIC_SIMILARITY, CLASSIFICATION, CLUSTERING) isn't exposed — only QUERY/DOCUMENT. Acceptable since neocortex only does retrieval.
**Sources:** Google GenAI EmbedContentConfig.taskType(), LangChain4j EmbeddingInputType enum
**Exploration:** quick
**Status:** captured
