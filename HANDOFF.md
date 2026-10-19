# HANDOFF — casehub-platform

## Last Session

Closed **platform#641** and **platform#642** in sequence. Both landed on main.

**#641 — Gemini/Ollama native ChatModel (S/Low):**
- `GeminiNativeChatModel` + `LangChain4jGeminiMapper` (Google GenAI SDK)
- Ollama ChatModel via reused `OpenAiNativeChatModel`
- CDI + Spring wiring for both backends
- 13 mapper tests

**#642 — EmbeddingModel platform abstraction (M/Med):**
- `EmbeddingModelBackend` SPI + `RoutingEmbeddingModel` in agent-router-core (3 routing tests)
- `OpenAiNativeEmbeddingModel` + mapper (2 tests) — batch embedding, configurable dimensions
- `GeminiNativeEmbeddingModel` + mapper (3 tests) — taskType mapping (QUERY/DOCUMENT)
- Ollama reuses OpenAI embedding model via `/v1/`
- CDI producers in OpenAiBeans, GeminiBeans, OllamaBeans, RouterBeans
- 4 Spring auto-configs + EmbeddingModelRouterManualConfig

**Cross-repo LangChain4j audit** — found two major split-brain issues:
1. Engine's ReAct loop uses LangChain4j ChatModel directly (not AgentProvider) — filed platform#643 + engine#1243
2. Neocortex injects EmbeddingModel/ChatModel directly (not through platform routing) — filed neocortex#611
3. Version skew: engine + neocortex on LangChain4j 1.14.1 vs platform 1.19.0 — filed platform#644

Platform now has full ChatModel + EmbeddingModel routing across all 4 backends.

## Follow-on Issues

- **platform#643** — ReAct tool-use loop: move from engine to platform (M/Med)
- **engine#1243** — Migrate ReAct to platform's agent-react-core (S/Low, blocked by #643)
- **platform#644** — Bump LangChain4j to 1.19.0 across engine and neocortex (XS/Low)
- **neocortex#611** — Consume platform's RoutingEmbeddingModel and RoutingChatModel (S/Low)

## References

- Slot 214 has engine, neocortex, platform
- Pause stack: empty (cleared — #528 and #569 were already closed)
- Engine compilation errors from commit 302888636 (#1235) — expects AgentInvocationResult, ResponseFormat, invokeBlocking() in platform agent-api (version mismatch, not a platform bug)
