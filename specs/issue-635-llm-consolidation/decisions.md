# Decisions — #636 AgentSessionConfig.responseFormat

## D1: Schema representation type

**Choice:** Raw JSON `String`
**Alternatives:**
- `JsonNode` — richer type but adds jackson-databind dependency to agent-api, violating its zero-Jackson constraint
- `Map<String, Object>` — no new deps but lossy for nested schemas, awkward to construct
**Rationale:** agent-api depends only on platform-api + Mutiny. Keeping it zero-Jackson is a standing constraint. Backends already have Jackson on their classpath and parse at their boundary.
**Trade-offs:** Callers must construct valid JSON strings; no compile-time schema structure validation
**Sources:** agent-api/pom.xml (dependency constraint), CLAUDE.md (module rules)
**Exploration:** quick
**Status:** captured

## D2: Scope — AgentSessionConfig and AgentSessionInit

**Choice:** Add `responseFormat` to both `AgentSessionConfig` (single-shot) and `AgentSessionInit` (multi-turn)
**Alternatives:**
- Config only — limits multi-turn sessions from requesting structured output
- Config + per-query — adds responseFormat to `AgentSession.query()`, more flexible but larger change
**Rationale:** Both types carry the same model-selection fields. Multi-turn sessions may also need structured output. Per-query format is a future extension.
**Trade-offs:** None significant — same pattern as model/modelQuery/modelChain fields
**Sources:** AgentSessionConfig.java, AgentSessionInit.java
**Exploration:** quick
**Status:** captured

## D3: ResponseFormatType enum values

**Choice:** `TEXT` and `JSON` — two modes
**Alternatives:**
- TEXT + JSON + JSON_ANY — three modes with explicit schemaless JSON. Unnecessary granularity; null schema on JSON achieves the same.
- TEXT + JSON_SCHEMA — rename avoids ambiguity but JSON is the established industry term (OpenAI, Gemini all call it JSON)
**Rationale:** JSON with non-null name+schema = structured output. JSON with null name+schema = schemaless JSON mode. TEXT = no format constraint. Matches vendor terminology.
**Trade-offs:** Callers must know that JSON with null schema means "any JSON" — but factory methods (`json()`, `jsonAny()`) make this explicit
**Sources:** OpenAI API docs (json_schema), Gemini API docs (responseMimeType)
**Exploration:** quick
**Status:** captured

## D4: Backend wiring scope

**Choice:** Wire all four native backends (OpenAI, Ollama, Gemini, Claude)
**Alternatives:**
- OpenAI + Ollama only — other backends are stubs
- Type only, no backend wiring — defers all integration
**Rationale:** All four SDKs already support structured output natively. The vendor integrations exist; this is just threading a parameter through.
**Depends on:** D1 (schema as String — backends parse at their boundary)
**Trade-offs:** Gemini backend's `buildEventStream` is currently a stub (fails with "requires API key") — response format wiring will also be conditional on API key presence
**Sources:** CLIOptions.java (Claude SDK — jsonSchema field), AbstractOpenAiSdkBackend.java (OpenAI), GeminiAgentBackend.java (Gemini)
**Exploration:** quick
**Status:** captured

## D5: LangChain4j bridge update

**Choice:** Update `AgentProviderChatModel` to convert LangChain4j's `ResponseFormat` to platform's `ResponseFormat` and set on `AgentSessionConfig`, replacing text-prepending
**Alternatives:**
- Keep text-prepending — simpler but doesn't use native structured output
- Separate issue — defers the bridge update
**Rationale:** The bridge currently prepends schema as text into the user prompt. With native backend support, it should convert and pass through for better model compliance. The code already exists in the bridge.
**Depends on:** D1 (schema type), D4 (backend wiring)
**Trade-offs:** None — strictly better than text-prepending
**Sources:** AgentProviderChatModel.java:prependSchema()
**Exploration:** quick
**Status:** captured

---

# Decisions — #637 AgentProvider.invokeBlocking()

## D6: invokeBlocking placement

**Choice:** Default method on `AgentProvider` interface
**Alternatives:**
- Static utility class `AgentInvocation.blocking(provider, config, timeout)` — keeps SPI slim
**Rationale:** AgentProvider already depends on Mutiny. Default method is the most ergonomic API — callers just call `provider.invokeBlocking()` without extra class imports.
**Trade-offs:** Slightly wider SPI surface, but no new implementations needed (default method)
**Sources:** AgentProvider.java
**Exploration:** quick
**Status:** captured
