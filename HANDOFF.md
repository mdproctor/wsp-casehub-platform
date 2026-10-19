# HANDOFF — casehub-platform

## Last Session

Closed **platform#640** — LangChain4j ChatModel reconciliation. Landed on main.

**What was built:**
- Native ChatModel implementations for OpenAI + Anthropic (bypassing LangChain4j wrappers)
- `RoutingChatModel` — model-registry-backed ChatModel routing
- CDI + Spring wiring with proper `@DefaultBean` / `@ConditionalOnMissingBean` guards

**Engine branch superseded:** `issue-640-platform-chatmodel` was built but #1235
already replaced the entire ChatModelProvider stack with AgentProvider on engine main.
Branch stamped as superseded, not merged.

**Review fixes applied:** static ObjectMapper (2 files), @DefaultBean on CDI ChatModel,
@ConditionalOnMissingBean on Spring, `overrideWith()` for parameter preservation in engine.

## Follow-on Issues

- **#641** — Gemini/Ollama native ChatModel (S, Low — same pattern)
- **#642** — EmbeddingModel platform abstraction (M, Med — needs design)

## References

- Slot 214 has engine, neocortex, platform
- Pause stack depth: 2
