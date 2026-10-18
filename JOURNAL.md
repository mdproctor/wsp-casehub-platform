# Design Journal — issue-635-llm-consolidation

## 2026-10-18 — #636 ResponseFormat + #637 invokeBlocking

Added structured JSON output support to the agent API. `ResponseFormat` record
in agent-api carries type (TEXT/JSON), schema name, and raw JSON Schema string.
Chose String over JsonNode to keep agent-api zero-Jackson — backends parse at
their boundary.

Wired through all four backends. OpenAI uses `ResponseFormatJsonSchema` with
strict mode. Claude uses `CLIOptions.jsonSchema(Map)`. Gemini is a stub pass-through.
Updated LangChain4j bridge to convert via `JsonSchemaElementJsonUtils.toMap()`
instead of text-prepending — `AgentSessionChatModel` retains text-prepend as
fallback since the session API has no per-query format.

Also added `invokeBlocking()` — default method on `AgentProvider` that collects
the streaming Multi, joins TextDelta, and returns `AgentInvocationResult`. Simple
convenience that eliminates 10+ lines of boilerplate per call site.

Next: #638 — deprecate and remove agent-langchain4j-core module.
