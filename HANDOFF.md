# HANDOFF — casehub-platform

## Last Session (2026-10-22)

Closed **platform#654** (AimdAdmissionStrategy consolidation deadlock). Landed on branch `issue-650-elastic-session-scheduler` (fast-forward merge from `issue-654-aimd-consolidation-deadlock`).

**#654 — Consolidation deadlock fix (S/Med):**
- `AimdAdmissionStrategy.availablePermits()` — missing accessor
- `SessionPipeline.companionAdmission(name, ceiling)` — independent AIMD strategies per execution context
- `ParallelLlmExecutor` extracted from neocortex to `agent-session-core` — companion admission baked in, prevents deadlock by design
- `isCapacityError` made public for cross-class access
- 14 new tests (6 deadlock + 8 executor), 172 total pass

**Follow-ups filed on neocortex:**
- neocortex#618 — migrate to platform's ParallelLlmExecutor (delete neocortex copy)
- neocortex#619 — BeliefRevisionPhase: replace agentProvider.invoke() with SessionPipeline

## Previous Session

Completed **platform#643** (ReAct tool-use loop) and **platform#645** (integration tests). Both landed on main as `e5a4bf00`.

**#643 — agent-react-core module (M/Med):**
- `ToolUseLoop` — blocking loop over ChatModel (observe-think-act cycle)
- `Tool` record with `Builder` — hides LangChain4j schema types from consumers
- `ToolExecutor`, `ToolUseConfig`, `ToolUseResult`, `ToolUseListener` (per-cycle observability)
- Error-as-result for LLM self-correction, 0-based cycleIndex

**#645 — Integration tests (S/Low):**
- Anthropic mock test (full type chain through AnthropicNativeChatModel + mapper)
- Ollama live IT (real qwen3:8b, end-to-end tool call verified)

**Cross-repo: engine#1245** — migrated engine's ReActWorkerFunctionHandler to use platform's ToolUseLoop. Branch `issue-1245-react-platform-migration` pushed, 604 tests pass. Engine's LangChain4j footprint reduced to 2 stable interfaces (ChatModel + EmbeddingModel). Redundant langchain4j-core dep removed.

**Architecture decision:** LangChain4j types (ChatModel, EmbeddingModel) are the shared interface vocabulary. Implementation details (ToolSpecification, JsonObjectSchema, ChatRequest, etc.) are hidden inside platform. Consumers use `Tool.Builder` to define tools declaratively.

## Follow-on Issues

- **engine#1245** — branch pushed, needs merge to main (604 tests green)
- **engine#1252** — AiServices test fixture cleanup in flow module (XS/Low)
- **platform#644** — LangChain4j version alignment across repos (XS/Low)
- **neocortex#611** — Consume platform's RoutingEmbeddingModel and RoutingChatModel (S/Low)

## References

- Slot 214 has engine, neocortex, platform
- Design spec: `wsp-casehub-platform/specs/issue-643-react-tool-use-loop/`
- Decisions: D1 (LangChain4j lingua franca), D2 (blocking loop), D3 (callback observability), D4 (error-as-result), D5 (single loop both frameworks)
