## D1: How to pass env vars through ClaudeAgentClient

**Choice:** Constructor env map
**Alternatives:**
- Extend ClaudeAgentProperties — mixes per-instance factory config with per-deployment config; Vertex env vars are instance-specific
- Subclass ClaudeAgentClient — buildEventStream() is package-private and complex; duplicating it is fragile
**Rationale:** Env vars are per-instance data and belong with the instance. Constructor change is backward-compatible (existing callers pass Map.of()). Refactor from fluent builder to CLIOptions.builder() is mechanical.
**Trade-offs:** Requires refactoring buildEventStream() and openSession() to use CLIOptions-based builder variant instead of fluent builder. Touches stable code.
**Sources:** ClaudeAgentClient.java:142-212, CLIOptions.java (env field), ClaudeClient.AsyncSpec (no env() method)
**Exploration:** quick
**Status:** captured

## D2: Where does the factory live?

**Choice:** In agent-claude (Quarkus wiring module)
**Alternatives:**
- New agent-claude-vertex module — only justified if significant Vertex-specific logic expected; for a factory that sets three env vars it's overkill
**Rationale:** Same pattern as OpenAiDirectBackendFactory in agent-openai. CDI-scoped factory sits alongside ClaudeAgentProvider @ApplicationScoped. No new module. agent-claude already depends on agent-claude-core (where ClaudeAgentClient lives).
**Trade-offs:** agent-claude gains a Vertex-specific class. If Vertex logic grows significantly, extraction to a separate module is a future option.
**Sources:** OpenAiDirectBackendFactory.java (pattern), agent-openai module structure
**Exploration:** quick
**Status:** captured
