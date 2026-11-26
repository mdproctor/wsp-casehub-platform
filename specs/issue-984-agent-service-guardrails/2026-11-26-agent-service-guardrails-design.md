# Design: Declarative Agent Invocation — @AgentService + Guardrails

**Epic:** #984
**Child issues:** #983, #985, #988, #989, #990, #991, #992, #993, agency#549
**Date:** 2026-11-26
**Branch:** issue-984-agent-service-guardrails

---

## 1. Overview

Epic #984 delivers two complementary capabilities:

1. **`@AgentService`** (#983) — a type-safe declarative invocation layer. Annotated Java interfaces get compile-time proxies that resolve models, descriptors, and tools, then delegate to `AgentProvider`. Three return modes: blocking structured output, reactive streaming, and multi-turn sessions.

2. **Input/Output Guardrails** (#985) — CDI decorators on `AgentProvider` that validate prompts before they reach the LLM and responses before they reach the consumer. Cross-cutting: fires on all invocation paths — `@AgentService`, playbooks, direct calls.

Both are designed together because guardrails must fire on all paths. `@AgentService` is one invocation path; guardrails are the cross-cutting layer that wraps them all.

### Design principles

- Leverage existing infrastructure: manifests, AgentResolver, sessions, CDI decorators, simulation framework
- Two surfaces on one runtime: YAML (playbooks) + Java (`@AgentService`)
- Guardrails can't be bypassed — decorator fires on all invocation paths
- Improve on LangChain4j, don't copy it — real sessions, direct SDK, full provider capabilities
- Agnostic core, implement Quarkus, generate Spring
- `@AgentService` is not a normalisation layer — it's a type-safe entry point into a richer runtime

### Strategic context

See `docs/specs/casehub-vs-langchain4j-agent-invocation.md` for the full comparison with LangChain4j's AiServices. The key differences: CaseHub uses vendor SDKs directly (no middleware), supports real server-side sessions (Claude CLI subprocess), and places guardrails cross-cutting on `AgentProvider` rather than coupled to the proxy.

---

## 2. Module layout

| Module | Type | Contents |
|--------|------|----------|
| `agent-api` (existing) | zero-dep | `@AgentService`, `@Query` annotations. `InputGuardrail`, `OutputGuardrail`, `GuardrailResult` SPIs. `GuardrailStreamOperator` utility. `tools` field added to `AgentSessionConfig`. |
| `agent-service-generator` | APT | Generates proxy classes from `@AgentService` interfaces. Extends the `GraphQLResolverProcessor` pattern. |
| `agent-service` | Quarkus CDI | `@Produces` the generated proxy beans, wires `AgentProvider` and `AgentResolver` |
| `agent-service-spring` | generated | Auto-configuration from `agent-service`'s `@Produces` via `spring-generator` |
| `guardrail` | Quarkus CDI | Input `@Decorator @Priority(1400)` + Output `@Decorator @Priority(1600)` on `AgentProvider`. Built-in: `JsonSchemaOutputGuardrail`, `MaxTokenInputGuardrail` |
| `guardrail-spring` | hand-written | `BeanPostProcessor` wrapper (same pattern as `agent-gate-spring`) |

4 new modules + types added to existing `agent-api`. SPIs and annotations in `agent-api` remain zero **casehubio** dependencies (it already depends on Mutiny for `Multi<AgentEvent>` on `AgentProvider`).

---

## 3. @AgentService API

### Annotation

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
public @interface AgentService {
    String model() default "";
    String descriptor() default "";
    Class<?>[] tools() default {};
    String[] mcpServers() default {};
    int timeout() default 0;
    boolean simulationEligible() default false;
}
```

### Method annotation

```java
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface Query {
    String value();
}
```

### Usage

```java
@AgentService(
    model = "fast",
    descriptor = "coach",
    tools = {Calculator.class},
    mcpServers = {"filesystem"},
    timeout = 30,
    simulationEligible = true
)
public interface PlanningCoach {

    @Query("Break this goal into concrete tasks")
    List<Task> decompose(String goal);

    @Query("Stream analysis updates for ${context}")
    Multi<AgentEvent> streamAnalysis(String context);

    AgentSession openConversation();
}
```

### Return type semantics

Return type determines invocation mode per-method. No shared proxy-level session state — each method is independent. A single interface can mix all modes.

| Return type | Proxy calls | Invocation mode |
|-------------|-------------|-----------------|
| `String` | `invokeBlocking()` | Single-shot, text response |
| `T` (POJO) | `invokeBlocking()` + JSON parse | Single-shot, `ResponseFormat.json()` with schema from `T` |
| `List<T>` | `invokeBlocking()` + JSON parse | Single-shot, `ResponseFormat.json()` with array schema |
| `Multi<AgentEvent>` | `invoke()` | Streaming, cold `Multi` returned to caller |
| `AgentSession` | `openSession()` | Multi-turn, session-backed via `SessionPool` |

### Parameter interpolation

`@Query` value supports `${paramName}` interpolation. Method parameters are matched by name (requires `-parameters` compiler flag or `@Param` annotation fallback).

```java
@Query("Analyse the risk of ${trade} in market ${market}")
RiskReport analyse(@Param("trade") Trade trade, @Param("market") String market);
```

For POJO parameters, the object is serialised to JSON and appended to the prompt after the template text.

---

## 4. Guardrail SPIs

All types in `agent-api` (zero-dep).

### Input guardrails

```java
@FunctionalInterface
public interface InputGuardrail {
    GuardrailResult validate(AgentSessionConfig config);
}
```

Implementations inspect `config.userPrompt()`, `config.systemPrompt()`, or any other field. CDI-managed — activate by classpath presence.

### Output guardrails

```java
@FunctionalInterface
public interface OutputGuardrail {
    GuardrailResult validate(String response, AgentSessionConfig originalConfig);
}
```

Receives the complete response text (after stream buffering) and the original config for context (e.g., to check response against the requested `ResponseFormat`).

### Result type

```java
public sealed interface GuardrailResult
    permits GuardrailResult.Pass, GuardrailResult.Fail, GuardrailResult.Reprompt {
    record Pass() implements GuardrailResult {}
    record Fail(String reason) implements GuardrailResult {}
    record Reprompt(String repromptMessage) implements GuardrailResult {}
}
```

Sealed — exhaustive handling, no missing cases. `Reprompt` enables the output guardrail to rephrase and retry (the decorator re-invokes with the reprompt message, up to a configurable max retries).

### GuardrailStreamOperator

Utility in `agent-api` for output guardrail stream buffering. Used by both Quarkus decorator and Spring `BeanPostProcessor` — no reactive code duplication.

```java
public final class GuardrailStreamOperator {
    public static Multi<AgentEvent> validate(
            Multi<AgentEvent> source,
            List<OutputGuardrail> guardrails,
            AgentSessionConfig config,
            int maxReprompts,
            Function<String, Multi<AgentEvent>> repromptFn) {
        // Buffer source → collect text from TextDelta events
        // Run each OutputGuardrail.validate()
        // Pass → replay buffered events
        // Fail → emit failure
        // Reprompt → call repromptFn, recurse (up to maxReprompts)
    }
}
```

### Built-in guardrails (Phase 1 — platform)

| Guardrail | Type | Module | What it does |
|-----------|------|--------|-------------|
| `JsonSchemaOutputGuardrail` | Output | `guardrail` | Validates structured output against `ResponseFormat` schema |
| `MaxTokenInputGuardrail` | Input | `guardrail` | Rejects prompts exceeding configurable token limit |

Built-in guardrails for PII detection and content policy live in agency (agency#549) — domain-specific logic belongs in the domain layer, not the platform.

---

## 5. Proxy generation (APT)

The `agent-service-generator` module is an annotation processor following the `GraphQLResolverProcessor` pattern. It scans `@AgentService` interfaces via Jandex + `RoundEnvironment` and generates one proxy class per interface.

### Generated proxy structure

```java
public class PlanningCoachProxy implements PlanningCoach {

    private final AgentProvider agentProvider;
    private final AgentResolver agentResolver;

    public PlanningCoachProxy(AgentProvider agentProvider, AgentResolver agentResolver) {
        this.agentProvider = agentProvider;
        this.agentResolver = agentResolver;
    }

    @Override
    public List<Task> decompose(String goal) {
        ResolvedAgent resolved = agentResolver.resolve("coach").orElseThrow();
        AgentSessionConfig config = AgentSessionConfig.builder()
            .model("fast")
            .systemPrompt(resolved.systemPrompt())
            .userPrompt(interpolate("Break this goal into concrete tasks", Map.of("goal", goal)))
            .responseFormat(ResponseFormat.json("Task", schemaFor(Task.class)))
            .tools(toolSpecsFor(Calculator.class))
            .mcpServers(List.of("filesystem"))
            .timeout(Duration.ofSeconds(30))
            .build();
        AgentInvocationResult result = agentProvider.invokeBlocking(config, Duration.ofSeconds(30));
        return parseJson(result.text(), new TypeReference<List<Task>>() {});
    }

    @Override
    public Multi<AgentEvent> streamAnalysis(String context) {
        ResolvedAgent resolved = agentResolver.resolve("coach").orElseThrow();
        AgentSessionConfig config = AgentSessionConfig.builder()
            .model("fast")
            .systemPrompt(resolved.systemPrompt())
            .userPrompt(interpolate("Stream analysis updates for ${context}", Map.of("context", context)))
            .tools(toolSpecsFor(Calculator.class))
            .mcpServers(List.of("filesystem"))
            .timeout(Duration.ofSeconds(30))
            .build();
        return agentProvider.invoke(config);
    }

    @Override
    public AgentSession openConversation() {
        ResolvedAgent resolved = agentResolver.resolve("coach").orElseThrow();
        AgentSessionInit init = AgentSessionInit.builder()
            .model("fast")
            .systemPrompt(resolved.systemPrompt())
            .tools(toolSpecsFor(Calculator.class))
            .mcpServers(List.of("filesystem"))
            .timeout(Duration.ofSeconds(30))
            .build();
        return agentProvider.openSession(init);
    }
}
```

The generated class is framework-neutral — constructor injection, no CDI or Spring imports. The Quarkus `agent-service` module `@Produces` it as a CDI bean; the Spring `agent-service-spring` module generates auto-configuration.

### APT processor details

- Scans both Jandex indexes (from dependency JARs) and `RoundEnvironment` (current compilation unit)
- Generates `.java` source files (not bytecode) — inspectable, debuggable
- Compile-time validation: return type must be one of the supported types, `@Query` required on non-`AgentSession` methods, tool classes must have `@Tool` methods
- If `simulationEligible = true`, generates `@SimulationEligible` on the proxy class
- JSON schema generation for POJO return types via `schema-generator` module
- Skip detection: if a hand-written implementation already exists (CDI bean implementing the interface), the processor emits a NOTE and skips generation

### Processor options

- `-AgenerateAgentService` (default true)
- `-AagentServicePackage` (override generated package)

---

## 6. Decorator stack

Request flows through CDI decorators by `@Priority` — lower number = outer decorator (fires first):

```
Request
  → InputGuardrailDecorator @Priority(1400)     — validate prompt, reject before gate
    → OutputGuardrailDecorator @Priority(1600)   — wraps stream with buffer-validate-replay
      → GatedAgentProvider @Priority(2000)       — rate limit / admission control
        → ObservedAgentBackend @Priority(1900)   — Micrometer metrics
          → RoutingAgentProvider                 — resolve model → backend
            → AgentBackend.invoke()              — vendor SDK call
          ← Multi<AgentEvent>
        ← instrumented stream
      ← gated stream (semaphore released on inner stream termination)
    ← buffered, validated, replayed or failed
Consumer
```

### Input guardrail decorator

```java
@Decorator @Priority(1400)
public class InputGuardrailDecorator implements AgentProvider {
    @Inject @Delegate AgentProvider delegate;
    @Inject Instance<InputGuardrail> guardrails;

    @Override
    public Multi<AgentEvent> invoke(AgentSessionConfig config) {
        for (InputGuardrail g : sorted(guardrails)) {
            GuardrailResult result = g.validate(config);
            if (result instanceof GuardrailResult.Fail f) {
                return Multi.createFrom().failure(new GuardrailException(f.reason()));
            }
        }
        return delegate.invoke(config);
    }
}
```

### Output guardrail decorator

```java
@Decorator @Priority(1600)
public class OutputGuardrailDecorator implements AgentProvider {
    @Inject @Delegate AgentProvider delegate;
    @Inject Instance<OutputGuardrail> guardrails;

    @Override
    public Multi<AgentEvent> invoke(AgentSessionConfig config) {
        Multi<AgentEvent> stream = delegate.invoke(config);
        if (guardrails.isUnsatisfied()) {
            return stream;
        }
        return GuardrailStreamOperator.validate(
            stream,
            sorted(guardrails),
            config,
            maxReprompts,
            reprompt -> delegate.invoke(config.withUserPrompt(reprompt))
        );
    }
}
```

### Gate semaphore timing

The gate releases its semaphore via `Multi.onTermination()` — when the inner stream completes. With buffer-then-validate, the inner stream terminates during buffering (before replay to consumer). The semaphore releases milliseconds early. Under heavy concurrent load with slow consumers, this could allow one extra concurrent invocation past the limit. Acceptable: validation is local and fast, overshoot is bounded.

### Spring equivalent

`guardrail-spring` uses `BeanPostProcessor` to wrap `AgentProvider` beans — same pattern as `agent-gate-spring/AgentGateBeanPostProcessor`. Both input and output guardrail logic call `GuardrailStreamOperator` from `agent-api`.

---

## 7. Session integration

Multi-turn `@AgentService` methods (returning `AgentSession`) leverage CaseHub's real session infrastructure:

| Provider path | How sessions work |
|---------------|-------------------|
| Claude CLI subprocess | True stateful session — `connect()` then `query()`. LLM holds context server-side. No replay. |
| Anthropic HTTP API | Replay with explicit prompt caching — `CacheControlEphemeral` on system + tools. |
| OpenAI HTTP | Replay with automatic prefix caching. Explicit breakpoints once #988 ships. |
| Other providers | Standard replay — full history on each call. |

The proxy delegates to `AgentProvider.openSession(init)` which routes through `SessionPipeline` for AIMD admission, idle timeout, and leak detection via `SessionLeakReaper`. The caller manages the returned `AgentSession` lifecycle (query/close, try-with-resources).

---

## 8. Simulation integration

When `simulationEligible = true`, the APT processor generates `@SimulationEligible(name = "planning-coach")` on the proxy class. The simulation framework's `simulation-generator` APT then generates a `@Decorator` that intercepts the proxy in test profiles, returning corpus data instead of calling the real LLM.

This means: `@AgentService` interfaces can be tested with deterministic corpus data, no LLM calls, no network, no cost. The test writes a simulation YAML with expected inputs and outputs, and the generated decorator replays them.

---

## 9. Changes to existing types

### AgentSessionConfig

Add `tools` field alongside existing `mcpServers`:

```java
public record AgentSessionConfig(
    String model,
    ModelQuery modelQuery,
    String systemPrompt,
    String userPrompt,
    ResponseFormat responseFormat,
    List<AgentMcpServer> mcpServers,
    List<ToolSpecification> tools,      // NEW
    Duration timeout
) { ... }
```

Backends that support tool calling use `tools` to configure their native SDK tool execution. Backends that don't support tools ignore the field.

### AgentSessionInit

Same addition — `tools` field for session-based invocations.

---

## 10. Phased delivery

### Phase 1 — Core (this branch: #983, #985, #988)

- `@AgentService` annotation and `@Query` in `agent-api`
- `InputGuardrail`, `OutputGuardrail`, `GuardrailResult` SPIs in `agent-api`
- `GuardrailStreamOperator` utility in `agent-api`
- `tools` field on `AgentSessionConfig` and `AgentSessionInit`
- `agent-service-generator` APT processor
- `agent-service` Quarkus CDI module
- `agent-service-spring` generated auto-config
- `guardrail` Quarkus decorator module with `JsonSchemaOutputGuardrail` and `MaxTokenInputGuardrail`
- `guardrail-spring` BeanPostProcessor module
- Prompt caching parity (#988) — Anthropic auto-caching, per-message, TTL; OpenAI breakpoints

### Phase 2 — Extended capabilities

- #989 — `temperature`, `maxTokens`, `topP` per-method via `@Query` attributes
- #990 — Budget limits via `AutonomyBudgetPolicy` integration
- #991 — Retry/governance via `PolicyEnforcer` on `@Query` methods
- #992 — `fallback = OfflineCoach.class` for resilience
- #993 — `@RequiresConfirmation` composability on `@AgentService` methods
- agency#549 — `PiiInputGuardrail` and `ContentPolicyOutputGuardrail` in agency

---

## References

- `docs/specs/casehub-vs-langchain4j-agent-invocation.md` — strategic comparison
- `agent-api/AgentProvider.java` — invocation SPI
- `agent-api/AgentResolver.java` — descriptor resolution SPI
- `agent-api/AgentSessionConfig.java` — invocation config
- `agent-gate/GatedAgentProvider.java` — existing decorator pattern
- `agent-gate-core/GatedAgentProviderWrapper.java:70-71` — semaphore release on termination
- `agent-gate-spring/AgentGateBeanPostProcessor.java` — Spring decorator pattern
- `graphql-generator/GraphQLResolverProcessor.java` — APT pattern
- `agent-react-core/ToolUseLoop.java` — existing tool execution
- `agent-claude/ClaudeAgentSession.java` — real session implementation
- `agent-claude-core/LangChain4jAnthropicMapper.java` — prompt caching
- `simulation-api/SimulationEligible.java` — simulation framework
- `confirmation-generator` — `@RequiresConfirmation` APT pattern
- Issue #983 — @AgentService child issue
- Issue #985 — Guardrails child issue
- Issue #988 — Prompt caching parity
- Issues #989-#993 — Phase 2 capabilities
- agency#549 — Built-in guardrails
