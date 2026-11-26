## D1: Guardrail interception point

**Choice:** Separate `@Decorator` on `AgentProvider`, not merged into `GatedAgentProvider`
**Alternatives:**
- Merge into GatedAgentProvider — violates SRP, couples rate limiting to content validation, can't activate independently
- Decorator on AgentBackend — fires per-backend not per-invocation, wrong abstraction level for content validation
**Rationale:** Independent concerns, composable, classpath-activated. Input guardrails at `@Priority(1400)`, output guardrails at `@Priority(1600)`, both fire before the gate at `@Priority(2000)` — rejected prompts don't consume rate limit tokens.
**Trade-offs:** Two decorators on the same SPI; ordering matters but is explicit via `@Priority`
**Sources:** `agent-gate/GatedAgentProvider.java`, `platform-observability/ObservedAgentBackend.java`
**Exploration:** quick
**Status:** captured

## D2: Code generation approach

**Choice:** APT (annotation processing) — agnostic core, implement Quarkus, generate Spring
**Alternatives:**
- Quarkus Build Extension (augmentation) — more powerful but Quarkus-only, Spring needs separate mechanism entirely
- Runtime CDI extension — dynamic but not debuggable, no source to inspect
**Rationale:** Follows the established three-tier pattern (core/Quarkus/Spring). One processor generates framework-neutral proxy source that both frameworks wire. Matches `GraphQLResolverProcessor` pattern already proven in the codebase.
**Trade-offs:** APT can't inspect the full CDI bean graph; self-describing interfaces make this unnecessary
**Sources:** `graphql-generator/GraphQLResolverProcessor.java`, platform CLAUDE.md Core Module Architecture table
**Exploration:** quick
**Status:** captured

## D3: Agent/descriptor resolution

**Choice:** Resolve via `AgentResolver` SPI (`resolve(agentId) → ResolvedAgent`)
**Alternatives:**
- Resolve via eidos directly — couples platform to agency, wrong dependency direction
- Hardcoded system prompt in annotation — no separation of contract from personality
**Rationale:** Clean dependency direction: platform defines SPI, eidos/agency provides implementation. The proxy doesn't care where the system prompt came from. Same interface, different personalities via different descriptors.
**Trade-offs:** Extra indirection; resolution failure at runtime not compile time
**Sources:** `agent-api/AgentResolver.java`, `agent-api/ResolvedAgent.java`
**Exploration:** quick
**Status:** captured

## D4: Supported return types

**Choice:** All three — blocking (`String`/`T`/`List<T>`), reactive (`Multi<AgentEvent>`), session (`AgentSession`)
**Alternatives:**
- Blocking only — leaves streaming and multi-turn to imperative API, undermines declarative value
- Blocking + reactive — excludes sessions, wastes CaseHub's true session advantage
**Rationale:** Each return type maps 1:1 to an existing `AgentProvider` method. Excluding any forces developers to drop to imperative for capabilities the platform already supports. `@AgentService` should be the complete declarative surface.
**Trade-offs:** More complex APT generation; session lifecycle management on the returned `AgentSession` rather than the proxy
**Mixed interfaces (from review):** Return type determines invocation mode per-method. Single-shot methods (`String`, `T`, `Multi<AgentEvent>`) use `invoke()`. Session methods (`AgentSession`) use `openSession()`. No shared proxy-level session state — each method is independent. A single interface can mix both modes.
**Sources:** `agent-api/AgentProvider.java` (invoke, openSession), `agent-api/AgentSession.java`
**Exploration:** quick
**Status:** revised (review finding: mixed interface semantics clarified)

## D5: Multi-turn session model

**Choice:** Session-backed via `SessionPool` — real server-side sessions where available (Claude CLI subprocess), cached replay as fallback (Anthropic HTTP with `CacheControlEphemeral`)
**Alternatives:**
- Stateless replay like LangChain4j — wastes CaseHub's true session infrastructure, no cost/latency advantage
**Rationale:** CaseHub has genuine session infrastructure that LangChain4j doesn't. Claude CLI subprocess holds full context server-side with no replay. Anthropic HTTP path uses explicit prompt caching. `@AgentService` should leverage both. HTTP caching parity filed as #988.
**Trade-offs:** Provider-dependent behavior — sessions behave differently per backend. Acceptable because the abstraction is at the invocation level, not the vendor level.
**Sources:** `agent-claude/ClaudeAgentSession.java` (subprocess), `agent-claude-core/LangChain4jAnthropicMapper.java` (CacheControlEphemeral), LangChain4j latest (stateless replay confirmed)
**Exploration:** deep-analysis
**Status:** captured

## D6: Tool binding

**Choice:** Explicit annotation attribute — `@AgentService(tools = {Calculator.class, Calendar.class})`
**Alternatives:**
- Auto-discovery of all `@Tool` CDI beans — implicit, can't tell from the interface which tools an agent uses
**Rationale:** Tool binding is part of the contract. The interface declaration tells you everything about the agent's capabilities. Auto-discovery leads to "which tools does this agent actually use?" ambiguity.
**Trade-offs:** More verbose annotation; adding a tool requires recompilation
**Wiring (from review):** `AgentSessionConfig` currently has no field for tool specs — only `mcpServers`. Add `tools` to `AgentSessionConfig` alongside `mcpServers`. The backend then handles tool execution via its native SDK. The proxy cannot use `ToolUseLoop` directly (ChatModel path) because that would bypass `AgentProvider` and its decorators (guardrails, gate), violating D1.
**Sources:** `agent-react-core/ToolUseLoop.java`, `agent-react-core/Tool.java`, `agent-api/AgentSessionConfig.java`
**Exploration:** quick
**Status:** revised (review finding: tool wiring path clarified)

## D7: Module layout

**Choice:** Consolidated (option B) — 4 new modules + types in existing `agent-api`
**Alternatives:**
- Minimal with -core separation (6 new modules) — cleaner separation but too many modules for the value
- Monolithic single module — violates the Quarkus/Spring three-tier pattern
**Rationale:** The APT-generated proxy class IS framework-neutral source code — no separate `-core` needed. Guardrail iteration logic is small enough to inline in both the Quarkus decorator and Spring BeanPostProcessor. SPIs and `@AgentService` annotation go in existing `agent-api` (zero-dep).
**Layout:**
- `agent-api` (existing) — `@AgentService` annotation + `InputGuardrail`/`OutputGuardrail`/`GuardrailResult` SPIs
- `agent-service-generator` — APT processor
- `agent-service` — Quarkus CDI wiring (`@Produces` proxy beans)
- `agent-service-spring` — generated auto-config
- `guardrail` — Quarkus Input `@Decorator @Priority(1400)` + Output `@Decorator @Priority(1600)` on AgentProvider
- `guardrail-spring` — hand-written BeanPostProcessor (same pattern as `agent-gate-spring`)
**Trade-offs:** Input guardrail loop is ~10 lines, genuinely trivial to duplicate. Output guardrail buffer-then-validate on `Multi<AgentEvent>` is 30-50 lines of reactive code — not trivially small.
**Duplication mitigation (from review):** `agent-api` already depends on Mutiny (`Multi<AgentEvent>` is AgentProvider's return type). Add a `GuardrailStreamOperator` utility in `agent-api` that buffers, validates with `OutputGuardrail` list, and replays. Both Quarkus decorator and Spring BeanPostProcessor call this utility — no reactive code duplication.
**Sources:** `agent-gate/GatedAgentProvider.java`, `agent-gate-spring/AgentGateBeanPostProcessor.java`, platform CLAUDE.md module table
**Exploration:** quick
**Status:** revised (review finding: output guardrail duplication addressed via shared utility)

## D8: Output guardrail streaming strategy

**Choice:** Buffer-then-validate — decorator buffers the stream, collects complete text, validates, then replays or fails
**Alternatives:**
- Pass-through with tail validation — stream events in real-time, validate on completion, emit failure event after partial output. Preserves streaming latency but consumer must handle mid-stream failure — a new failure mode that complicates the contract.
**Rationale:** Simpler consumer contract — the response either passes entirely or doesn't. No partial output followed by a failure event. Matches the guardrail promise that invalid content doesn't reach the consumer. Latency cost is acceptable because guardrail validation is fast (local check, not another LLM call).
**Trade-offs:** Consumer doesn't see streaming events until output validation completes. For long responses, this adds noticeable latency. Acceptable trade-off: guardrails are a safety mechanism, not a performance feature.
**Gate interaction (from review):** The gate releases its semaphore via `Multi.onTermination()` — when the inner stream completes. With buffer-then-validate, the inner stream terminates during buffering (before replay to consumer). The semaphore releases milliseconds early — during validation + replay, not at consumer delivery. Under heavy concurrent load with slow consumers, this could allow one extra concurrent invocation past the limit. Acceptable: validation is fast (local), and the overshoot is bounded to the validation + replay window.
**Depends on:** D1 (guardrail interception on AgentProvider)
**Sources:** Issue #985 (`Multi` operator design), `agent-gate/GatedAgentProvider.java` (existing stream wrapping pattern), `agent-gate-core/GatedAgentProviderWrapper.java:70-71` (onTermination semaphore release)
**Exploration:** quick
**Status:** revised (review finding: semaphore timing documented)

## D9: Built-in guardrail location

**Choice:** Split across platform and agency by concern
**Alternatives:**
- All in platform — couples platform to domain-specific detection logic (PII patterns, content policies)
- All in agency — puts structural validators (`ResponseFormat` schema checking) in the wrong layer
**Rationale:** Guardrails that validate against platform types belong in platform. Guardrails that carry domain-specific detection logic belong in agency.
**Split:**
- Platform (`guardrail` module): `JsonSchemaOutputGuardrail` (validates structured output against `ResponseFormat`), `MaxTokenInputGuardrail` (prevents oversized inputs)
- Agency: `PiiInputGuardrail` (PII pattern detection), `ContentPolicyOutputGuardrail` (configurable content policy)
**Trade-offs:** Built-ins in two repos; consumers need both on classpath for full coverage. Acceptable — agency already depends on platform.
**Sources:** Issue #985 built-in guardrails list, `agent-api/ResponseFormat.java`
**Exploration:** quick
**Status:** captured
