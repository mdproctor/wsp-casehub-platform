# Scalar subjects + invoke binding simulation for playbook steps

**Issue:** casehubio/platform#726
**Date:** 2026-11-06
**Status:** Draft

## Overview

Support scalar YAML shorthand for five single-primary-param playbook step types, and auto-wire all invoke binding steps to the simulation framework so playbooks run in dry-run mode without real external calls.

## Scalar subject support

### Step types and their scalar mapping

| Step key | Primary param | Scalar example | Default for omitted params |
|----------|--------------|----------------|---------------------------|
| `agent-session-close` | `session` | `- agent-session-close: classifier` | — |
| `agent-session-clear` | `session` | `- agent-session-clear: support` | — |
| `graphql-exec` | `query` | `- graphql-exec: "{ users { id } }"` | — |
| `rest-request` | `url` | `- rest-request: /api/users` | method=GET, no headers, no body |
| `mcp-call` | `tool` | `- mcp-call: file_search` | no params |

Both scalar and map forms remain valid. Scalar is shorthand for the common single-param case.

### Layer 1: DeclarationParser (yaml-core)

`DeclarationParser.parseInvoke(Object raw)` dispatches on keys in the invoke map. For agent-session steps, the binding parse methods currently cast `raw` to `Map`. Change to handle `String`:

```java
private static InvokeBinding.SessionClose parseSessionCloseBinding(Object raw) {
    if (raw instanceof String s) return new InvokeBinding.SessionClose(s);
    Map<String, Object> map = (Map<String, Object>) raw;
    return new InvokeBinding.SessionClose((String) map.get("session"));
}
```

Same pattern for `parseSessionClearBinding`.

Add entries in `parseInvoke()` for `graphql-exec` (maps to `InvokeBinding.Graphql`) and `mcp-call` (maps to `InvokeBinding.Mcp`). Both already accept String values in their constructors. For `rest-request` when `raw instanceof String`, create `new InvokeBinding.Rest("GET", raw, Map.of(), Map.of())`.

### Layer 2: PlaybookCompiler step compilers

**AgentSessionStepCompiler** — currently rejects non-Map at line 23. Add String handling:

```java
if (stepValue instanceof String s) {
    config = Map.of("session", s);
} else if (stepValue instanceof Map) {
    config = (Map<String, Object>) stepValue;
} else {
    ctx.addDiagnostic(ERROR, stepType + " requires a string or map");
    return null;
}
```

Note: `agent-session-open` and `agent-query` share this compiler but require additional params (`system`, `user`). The scalar path only activates for `agent-session-close` and `agent-session-clear`. Add a guard: if `stepType` requires multi-param (`agent-session-open`, `agent-query`), reject scalar with a diagnostic.

**RestRequestCompiler** — currently casts `stepValue` to Map at line 20. Add String handling: scalar value = URL, method defaults to GET, no headers/body.

**New GraphqlExecStepCompiler** — register as `graphql-exec`. Scalar value = query string. Map form reads `query` key. Compiles to a `SetTask` with `_stepType: graphql-exec` and the query.

**New McpCallStepCompiler** — register as `mcp-call`. Scalar value = tool name. Map form reads `tool` and optional `params`. Compiles to a `SetTask` with `_stepType: mcp-call`, tool name, and params.

### Layer 3: JSON Schema (playbook-document.schema.json)

Change `agent-session-close` and `agent-session-clear` from:
```json
{ "type": "object", "properties": { "session": { "type": "string" } }, "required": ["session"] }
```
to:
```json
{ "oneOf": [{ "type": "string" }, { "type": "object", "properties": { "session": { "type": "string" } }, "required": ["session"] }] }
```

Same pattern for `rest-request` (existing entry). Add new entries for `graphql-exec` and `mcp-call`.

### Layer 4: Playbook file edits

Apply scalar form to all single-param usages across `examples/agent-interaction-patterns/` (14 close + 1 clear) and `playbook-catalog/src/main/playbooks/invoke-bindings/` (2 graphql-exec).

For `rest-request` and `mcp-call` playbooks: keep at least one map-form example for documentation, apply scalar form where only the primary param is used.

## Simulation auto-wiring

### Architecture: transparent Action wrapper

Simulation is a runtime concern, not a compile-time concern. A playbook compiles once and runs real or simulated based on whether a simulation overlay is active.

**SimulatingAction** wraps any `Action` created by an InvokeHandler. It is installed by `YamlDefinitionSource` around every invoke-handler action:

```
YamlDefinitionSource.loadFile():
    Action action = resolveHandler(binding).create(decl, binding);
    Action simulated = new SimulatingAction(action, binding, simulationRuntime);
    Action validated = new ValidatingAction(decl, simulated, eventSink);
```

At execution time:

```java
class SimulatingAction implements Action {
    Result execute(Map<String, Object> params, ServiceRegistry services) {
        if (simulationRuntime != null && simulationRuntime.hasActiveOverlay()) {
            String qualifiedName = extractQualifiedName(binding);
            var simResult = simulationRuntime.tryLookup(qualifiedName, extractKey(binding));
            if (simResult.isPresent()) return simResult.get();
        }
        return delegate.execute(params, services);
    }
}
```

- When simulation overlay is active + corpus match → return corpus response
- When simulation overlay is active + no match → delegate to real handler (permissive — allows mixing real and simulated calls)
- When no overlay → delegate to real handler (normal execution)

### Key extraction from InvokeBinding

Each binding type provides a natural corpus key:

| Binding type | Key | Example |
|-------------|-----|---------|
| `InvokeBinding.Rest` | `url` value | `/api/users` |
| `InvokeBinding.Graphql` | `query` value | `{ users { id } }` |
| `InvokeBinding.Mcp` | `tool` value | `file_search` |
| `InvokeBinding.SessionClose` | `session` value | `classifier` |
| `InvokeBinding.SessionClear` | `session` value | `support` |

### Corpus configuration in simulation.yaml

Follows existing `YamlSimulationConfig` pattern with `key-lookup` strategy:

```yaml
rest-request:
  strategy: key-lookup
  corpus:
    - key: { url: "/api/users" }
      response: { users: [{ id: 1, name: "Alice" }] }
      metadata: { statusCode: 200, durationMs: 15 }

graphql-exec:
  strategy: key-lookup
  corpus:
    - key: { query: "{ users { id name email } }" }
      response: { users: [{ id: 1, name: "Alice", email: "a@b.com" }] }

mcp-call:
  strategy: key-lookup
  corpus:
    - key: { tool: "file_search" }
      response: { results: [{ file: "src/auth.ts", score: 0.95 }] }
```

The qualified name for corpus lookup is the step type name (e.g., `rest-request`, `graphql-exec`). This integrates with the existing `SimulationRuntime.pushOverlay()` mechanism.

### YamlDefinitionSource changes

`YamlDefinitionSource` gains an optional `SimulationRuntime` constructor parameter. When present, every action created by an InvokeHandler is wrapped with `SimulatingAction`. When absent (e.g., unit tests that don't use simulation), actions are used directly — no wrapper overhead.

## Files affected

### New files
- `yaml-step-runtime/.../SimulatingAction.java` — transparent simulation wrapper
- `playbook-compiler/.../GraphqlExecStepCompiler.java` — graphql-exec compilation
- `playbook-compiler/.../McpCallStepCompiler.java` — mcp-call compilation

### Modified files
- `yaml-core/.../DeclarationParser.java` — String handling in parse methods + graphql-exec/mcp-call entries
- `yaml-core/.../playbook-document.schema.json` — oneOf for scalar/object forms + new entries
- `playbook-compiler/.../AgentSessionStepCompiler.java` — String stepValue handling
- `playbook-compiler/.../RestRequestCompiler.java` — String stepValue handling
- `playbook-compiler/.../PlaybookCompiler.java` — register graphql-exec and mcp-call
- `yaml-step-runtime/.../YamlDefinitionSource.java` — optional SimulationRuntime, SimulatingAction wrapping
- 8 example playbook files — scalar form edits
- 1 playbook-catalog file (graphql.playbook.yaml) — scalar form edits

### Test files
- `yaml-core/.../DeclarationParserTest.java` — scalar binding parsing
- `playbook-compiler/.../PlaybookCompilerTest.java` — scalar compilation
- `playbook-compiler/.../AgentExamplePlaybookTest.java` — exercises scalar form via parameterized tests
- `yaml-step-runtime/.../AgentExampleExecutionTest.java` — exercises scalar form via DeclarationParser path
- New test for SimulatingAction corpus interception

## References

- Walker.java:256-273 — existing scalar → `_subject` mechanism
- AgentSessionStepCompiler.java — current Map-only handling
- DeclarationParser.java:219-228 — current Map-only binding parsing
- AgentExampleExecutionTest.java:396-409 — DeclarationParser.parseInvoke() usage at execution time
- YamlDefinitionSource.java:82-90 — handler→action→definition wiring
- SimulationRuntime overlay pattern (simulation-core)
- playbook-document.schema.json — `oneOf` pattern from emit-event/run-playbook
