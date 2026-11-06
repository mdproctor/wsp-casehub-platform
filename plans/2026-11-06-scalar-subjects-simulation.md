# Scalar Subjects + Invoke Binding Simulation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #726 — chore: playbook verbosity reduction — scalar subjects for single-param steps
**Issue group:** #726

**Goal:** Support scalar YAML shorthand for 5 single-primary-param playbook step types and auto-wire all invoke binding steps to the simulation framework.

**Architecture:** Two layers of change — (1) DeclarationParser + PlaybookCompiler accept String values for single-param steps, (2) a transparent `SimulatingAction` wrapper around invoke-handler actions checks simulation overlay state at execution time and returns corpus responses when active. JSON Schema and playbook files updated to match.

**Tech Stack:** Java 21, yaml-core, yaml-step-runtime, playbook-compiler, simulation-core

## Global Constraints

- `yaml-plugin-api/` and `yaml-core/` must remain zero-dependency
- `SimulatingAction` lives in yaml-step-runtime (has access to simulation-core)
- All existing tests must continue to pass — scalar form is additive, map form stays valid
- Playbook files under `examples/` and `playbook-catalog/` are tested by `AgentExamplePlaybookTest` and `PlaybookParsingTest`

---

## Batch 1: Scalar form — parsing and compilation

### Task 1: DeclarationParser scalar binding support

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/step/DeclarationParser.java:219-228` — String handling in parseSessionClearBinding + parseSessionCloseBinding
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/step/DeclarationParser.java:76-131` — add graphql-exec and mcp-call entries in parseInvoke
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/step/DeclarationParserTest.java`

**Interfaces:**
- Consumes: `InvokeBinding.SessionClose(String)`, `InvokeBinding.SessionClear(String)`, `InvokeBinding.Graphql(String)`, `InvokeBinding.Mcp(String)`, `InvokeBinding.Rest(String, String, Map, Map)` — all existing constructors
- Produces: `DeclarationParser.parseInvoke(Object)` returns correct InvokeBinding for scalar values

- [ ] **Step 1: Write failing tests for scalar session-close/clear parsing**

In `DeclarationParserTest.java`, add after line 243:

```java
@Test
void parsesSessionCloseBinding_scalarForm() {
    Map<String, Object> invoke = Map.of("agent-session-close", "classifier");
    var binding = (InvokeBinding.SessionClose) DeclarationParser.parseInvoke(invoke);
    assertThat(binding.session()).isEqualTo("classifier");
}

@Test
void parsesSessionClearBinding_scalarForm() {
    Map<String, Object> invoke = Map.of("agent-session-clear", "support");
    var binding = (InvokeBinding.SessionClear) DeclarationParser.parseInvoke(invoke);
    assertThat(binding.session()).isEqualTo("support");
}

@Test
void parsesGraphqlExecBinding() {
    Map<String, Object> invoke = Map.of("graphql-exec", "{ users { id } }");
    var binding = (InvokeBinding.Graphql) DeclarationParser.parseInvoke(invoke);
    assertThat(binding.query()).isEqualTo("{ users { id } }");
}

@Test
void parsesMcpCallBinding() {
    Map<String, Object> invoke = Map.of("mcp-call", "file_search");
    var binding = (InvokeBinding.Mcp) DeclarationParser.parseInvoke(invoke);
    assertThat(binding.tool()).isEqualTo("file_search");
}

@Test
void parsesRestRequestBinding_scalarForm() {
    Map<String, Object> invoke = Map.of("rest-request", "/api/users");
    var binding = (InvokeBinding.Rest) DeclarationParser.parseInvoke(invoke);
    assertThat(binding.url()).isEqualTo("/api/users");
    assertThat(binding.method()).isEqualTo("GET");
    assertThat(binding.headers()).isEmpty();
    assertThat(binding.body()).isEmpty();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-core test -Dtest=DeclarationParserTest -Dsurefire.failIfNoSpecifiedTests=false --batch-mode -q`
Expected: 5 failures (ClassCastException for session-close/clear, IllegalArgumentException for graphql-exec/mcp-call/rest-request)

- [ ] **Step 3: Implement scalar handling in DeclarationParser**

Modify `parseSessionCloseBinding` (line 225):
```java
private static InvokeBinding.SessionClose parseSessionCloseBinding(Object raw) {
    if (raw instanceof String s) return new InvokeBinding.SessionClose(s);
    Map<String, Object> map = (Map<String, Object>) raw;
    return new InvokeBinding.SessionClose((String) map.get("session"));
}
```

Modify `parseSessionClearBinding` (line 219):
```java
private static InvokeBinding.SessionClear parseSessionClearBinding(Object raw) {
    if (raw instanceof String s) return new InvokeBinding.SessionClear(s);
    Map<String, Object> map = (Map<String, Object>) raw;
    return new InvokeBinding.SessionClear((String) map.get("session"));
}
```

In `parseInvoke`, add entries before the `throw` at line 127:
```java
if (invokeMap.containsKey("graphql-exec")) {
    Object val = invokeMap.get("graphql-exec");
    if (val instanceof String s) return new InvokeBinding.Graphql(s);
    Map<String, Object> map = (Map<String, Object>) val;
    return new InvokeBinding.Graphql((String) map.get("query"));
}
if (invokeMap.containsKey("mcp-call")) {
    Object val = invokeMap.get("mcp-call");
    if (val instanceof String s) return new InvokeBinding.Mcp(s);
    Map<String, Object> map = (Map<String, Object>) val;
    return new InvokeBinding.Mcp((String) map.get("tool"));
}
if (invokeMap.containsKey("rest-request")) {
    Object val = invokeMap.get("rest-request");
    if (val instanceof String s) return new InvokeBinding.Rest("GET", s, Map.of(), Map.of());
    return parseRestBinding(val);
}
```

Update the error message to include the new keys.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn -pl yaml-core test -Dtest=DeclarationParserTest --batch-mode -q`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/step/DeclarationParser.java yaml-core/src/test/java/io/casehub/yaml/core/step/DeclarationParserTest.java
git commit -m "feat(yaml-core): scalar binding support in DeclarationParser for session-close/clear, graphql-exec, mcp-call, rest-request

Refs #726"
```

### Task 2: PlaybookCompiler scalar step values

**Files:**
- Modify: `playbook-compiler/src/main/java/io/casehub/platform/compiler/AgentSessionStepCompiler.java:21-35` — accept String stepValue
- Modify: `playbook-compiler/src/main/java/io/casehub/platform/compiler/RestRequestCompiler.java:18-20` — accept String stepValue
- Create: `playbook-compiler/src/main/java/io/casehub/platform/compiler/GraphqlExecStepCompiler.java`
- Create: `playbook-compiler/src/main/java/io/casehub/platform/compiler/McpCallStepCompiler.java`
- Modify: `playbook-compiler/src/main/java/io/casehub/platform/compiler/PlaybookCompiler.java:56` — register graphql-exec and mcp-call
- Test: `playbook-compiler/src/test/java/io/casehub/platform/compiler/PlaybookCompilerTest.java`

**Interfaces:**
- Consumes: `StepCompiler.compile(String stepKey, Object stepValue, Map<String,Object> fullStep, CompilationContext ctx)` — existing interface
- Produces: `TaskItem` for each step type's scalar and map forms

- [ ] **Step 1: Write failing tests for scalar compilation**

Add to `PlaybookCompilerTest.java`:

```java
@Test
void compile_agentSessionClose_scalarForm() {
    var content = Map.<String, Object>of("steps", List.of(
            Map.of("agent-session-close", "classifier")));
    CompilationOutcome outcome = compiler.compile("test", content);
    assertThat(outcome).isInstanceOf(CompilationOutcome.Success.class);
    var result = ((CompilationOutcome.Success) outcome).result();
    assertThat(result.workflow().getDo()).hasSize(1);
    assertThat(result.workflow().getDo().getFirst().getTask().getSetTask()).isNotNull();
}

@Test
void compile_agentSessionClear_scalarForm() {
    var content = Map.<String, Object>of("steps", List.of(
            Map.of("agent-session-clear", "support")));
    CompilationOutcome outcome = compiler.compile("test", content);
    assertThat(outcome).isInstanceOf(CompilationOutcome.Success.class);
}

@Test
void compile_agentSessionOpen_scalarForm_rejected() {
    var content = Map.<String, Object>of("steps", List.of(
            Map.of("agent-session-open", "analyst")));
    CompilationOutcome outcome = compiler.compile("test", content);
    assertThat(outcome).isInstanceOf(CompilationOutcome.Failure.class);
}

@Test
void compile_restRequest_scalarForm() {
    var content = Map.<String, Object>of("steps", List.of(
            Map.of("rest-request", "/api/users")));
    CompilationOutcome outcome = compiler.compile("test", content);
    assertThat(outcome).isInstanceOf(CompilationOutcome.Success.class);
}

@Test
void compile_graphqlExec_scalarForm() {
    var content = Map.<String, Object>of("steps", List.of(
            Map.of("graphql-exec", "{ users { id } }")));
    CompilationOutcome outcome = compiler.compile("test", content);
    assertThat(outcome).isInstanceOf(CompilationOutcome.Success.class);
}

@Test
void compile_graphqlExec_mapForm() {
    var content = Map.<String, Object>of("steps", List.of(
            Map.of("graphql-exec", Map.of("query", "{ users { id } }"))));
    CompilationOutcome outcome = compiler.compile("test", content);
    assertThat(outcome).isInstanceOf(CompilationOutcome.Success.class);
}

@Test
void compile_mcpCall_scalarForm() {
    var content = Map.<String, Object>of("steps", List.of(
            Map.of("mcp-call", "file_search")));
    CompilationOutcome outcome = compiler.compile("test", content);
    assertThat(outcome).isInstanceOf(CompilationOutcome.Success.class);
}

@Test
void compile_mcpCall_mapForm() {
    var content = Map.<String, Object>of("steps", List.of(
            Map.of("mcp-call", Map.of("tool", "file_search", "params", Map.of("q", "auth")))));
    CompilationOutcome outcome = compiler.compile("test", content);
    assertThat(outcome).isInstanceOf(CompilationOutcome.Success.class);
}
```

- [ ] **Step 2: Run tests to verify failures**

Run: `mvn -pl playbook-compiler test -Dtest=PlaybookCompilerTest --batch-mode -q`
Expected: failures for scalar forms, graphql-exec, and mcp-call (unknown step type or ClassCastException)

- [ ] **Step 3: Implement AgentSessionStepCompiler scalar handling**

Replace the Map check at lines 23-27 with:

```java
Map<String, Object> config;
if (stepValue instanceof String s) {
    if ("agent-session-open".equals(stepType) || "agent-query".equals(stepType)) {
        ctx.addDiagnostic(CompilationDiagnostic.Severity.ERROR,
                stepType + " requires a map (multiple parameters needed)");
        return null;
    }
    config = Map.of("session", s);
} else if (stepValue instanceof Map) {
    config = (Map<String, Object>) stepValue;
} else {
    ctx.addDiagnostic(CompilationDiagnostic.Severity.ERROR,
            stepType + " requires a string or map");
    return null;
}
```

- [ ] **Step 4: Implement RestRequestCompiler scalar handling**

Replace line 20 with:

```java
Map<String, Object> config;
if (stepValue instanceof String s) {
    config = Map.of("url", s, "method", "GET");
} else if (stepValue instanceof Map) {
    config = (Map<String, Object>) stepValue;
} else {
    return null;
}
```

- [ ] **Step 5: Create GraphqlExecStepCompiler**

Use `ide_create_file` to create `playbook-compiler/src/main/java/io/casehub/platform/compiler/GraphqlExecStepCompiler.java`:

```java
package io.casehub.platform.compiler;

import io.serverlessworkflow.api.types.Set;
import io.serverlessworkflow.api.types.SetTask;
import io.serverlessworkflow.api.types.SetTaskConfiguration;
import io.serverlessworkflow.api.types.Task;
import io.serverlessworkflow.api.types.TaskItem;

import java.util.Map;

class GraphqlExecStepCompiler implements StepCompiler {

    @Override
    @SuppressWarnings("unchecked")
    public TaskItem compile(String stepKey, Object stepValue, Map<String, Object> fullStep,
                            CompilationContext ctx) {
        String query;
        if (stepValue instanceof String s) {
            query = s;
        } else if (stepValue instanceof Map) {
            Map<String, Object> config = (Map<String, Object>) stepValue;
            query = (String) config.get("query");
            if (query == null) {
                ctx.addDiagnostic(CompilationDiagnostic.Severity.ERROR,
                        "graphql-exec missing required field: query");
                return null;
            }
        } else {
            ctx.addDiagnostic(CompilationDiagnostic.Severity.ERROR,
                    "graphql-exec requires a string or map");
            return null;
        }

        String taskName = ctx.generateName("graphql-exec");
        var setConfig = new SetTaskConfiguration()
                .withAdditionalProperty("_stepType", "graphql-exec")
                .withAdditionalProperty("query", query);

        return new TaskItem(taskName, new Task().withSetTask(
                new SetTask().withSet(new Set().withSetTaskConfiguration(setConfig))));
    }
}
```

- [ ] **Step 6: Create McpCallStepCompiler**

Use `ide_create_file` to create `playbook-compiler/src/main/java/io/casehub/platform/compiler/McpCallStepCompiler.java`:

```java
package io.casehub.platform.compiler;

import io.serverlessworkflow.api.types.Set;
import io.serverlessworkflow.api.types.SetTask;
import io.serverlessworkflow.api.types.SetTaskConfiguration;
import io.serverlessworkflow.api.types.Task;
import io.serverlessworkflow.api.types.TaskItem;

import java.util.Map;

class McpCallStepCompiler implements StepCompiler {

    @Override
    @SuppressWarnings("unchecked")
    public TaskItem compile(String stepKey, Object stepValue, Map<String, Object> fullStep,
                            CompilationContext ctx) {
        String tool;
        Map<String, Object> params = Map.of();

        if (stepValue instanceof String s) {
            tool = s;
        } else if (stepValue instanceof Map) {
            Map<String, Object> config = (Map<String, Object>) stepValue;
            tool = (String) config.get("tool");
            if (tool == null) {
                ctx.addDiagnostic(CompilationDiagnostic.Severity.ERROR,
                        "mcp-call missing required field: tool");
                return null;
            }
            if (config.containsKey("params")) {
                params = (Map<String, Object>) config.get("params");
            }
        } else {
            ctx.addDiagnostic(CompilationDiagnostic.Severity.ERROR,
                    "mcp-call requires a string or map");
            return null;
        }

        String taskName = ctx.generateName("mcp-call");
        var setConfig = new SetTaskConfiguration()
                .withAdditionalProperty("_stepType", "mcp-call")
                .withAdditionalProperty("tool", tool);
        if (!params.isEmpty()) {
            setConfig.withAdditionalProperty("params", params);
        }

        return new TaskItem(taskName, new Task().withSetTask(
                new SetTask().withSet(new Set().withSetTaskConfiguration(setConfig))));
    }
}
```

- [ ] **Step 7: Register new compilers in PlaybookCompiler**

Add after line 56 in PlaybookCompiler constructor:

```java
register("graphql-exec", new GraphqlExecStepCompiler());
register("mcp-call", new McpCallStepCompiler());
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `mvn -pl playbook-compiler test -Dtest=PlaybookCompilerTest --batch-mode -q`
Expected: all PASS

- [ ] **Step 9: Commit**

```bash
git add playbook-compiler/
git commit -m "feat(playbook-compiler): scalar step values for session-close/clear, rest-request + new graphql-exec, mcp-call compilers

Refs #726"
```

### Task 3: JSON Schema + playbook file edits

**Files:**
- Modify: `yaml-core/src/main/resources/schema/playbook-document.schema.json:177-226` — oneOf for scalar/object forms + new entries
- Modify: 8 files in `examples/agent-interaction-patterns/` — scalar form for agent-session-close/clear
- Modify: `playbook-catalog/src/main/playbooks/invoke-bindings/graphql.playbook.yaml` — scalar form for graphql-exec
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/handler/AgentExamplePlaybookTest.java` (existing parameterized tests)
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/PlaybookParsingTest.java` (existing parsing tests)

**Interfaces:**
- Consumes: DeclarationParser scalar support (Task 1), PlaybookCompiler scalar support (Task 2)
- Produces: Updated playbook files using scalar form, valid schema

- [ ] **Step 1: Update JSON Schema**

Change `agent-session-close` (lines 223-227) to:
```json
"agent-session-close": {
  "oneOf": [
    { "type": "string", "description": "Session name to close." },
    { "type": "object", "properties": { "session": { "type": "string" } }, "required": ["session"] }
  ]
}
```

Change `agent-session-clear` (lines 218-222) to:
```json
"agent-session-clear": {
  "oneOf": [
    { "type": "string", "description": "Session name to clear." },
    { "type": "object", "properties": { "session": { "type": "string" } }, "required": ["session"] }
  ]
}
```

Change `rest-request` (lines 177-186) to:
```json
"rest-request": {
  "oneOf": [
    { "type": "string", "description": "Shorthand: URL with GET method." },
    {
      "type": "object",
      "properties": {
        "method": { "type": "string" },
        "url": { "type": "string" },
        "headers": { "type": "object" },
        "body": {}
      },
      "required": ["url"]
    }
  ]
}
```

Add after `agent-session-close` entry:
```json
"graphql-exec": {
  "oneOf": [
    { "type": "string", "description": "Shorthand: GraphQL query string." },
    { "type": "object", "properties": { "query": { "type": "string" } }, "required": ["query"] }
  ]
},
"mcp-call": {
  "oneOf": [
    { "type": "string", "description": "Shorthand: MCP tool name." },
    {
      "type": "object",
      "properties": {
        "tool": { "type": "string" },
        "params": { "type": "object" }
      },
      "required": ["tool"]
    }
  ]
}
```

- [ ] **Step 2: Apply scalar form to example playbooks**

For each of the 8 files in `examples/agent-interaction-patterns/`, replace:
```yaml
- agent-session-close:
    session: <name>
```
with:
```yaml
- agent-session-close: <name>
```

In `03-session-with-clear.yaml`, also replace:
```yaml
- agent-session-clear:
    session: support
```
with:
```yaml
- agent-session-clear: support
```

Files: `01-direct-invoke.yaml`, `02-session-conversation.yaml`, `03-session-with-clear.yaml`, `04-parallel-queries.yaml`, `05-pool-backed.yaml`, `06-multi-channel.yaml`, `07-salience-priority.yaml`, `08-structured-output.yaml`

- [ ] **Step 3: Apply scalar form to graphql playbook**

In `playbook-catalog/src/main/playbooks/invoke-bindings/graphql.playbook.yaml`, replace both:
```yaml
- graphql-exec:
    query: "{ users { id name email } }"
```
with:
```yaml
- graphql-exec: "{ users { id name email } }"
```

And:
```yaml
- graphql-exec:
    query: "mutation { createUser(name: \"Alice\") { id } }"
```
with:
```yaml
- graphql-exec: "mutation { createUser(name: \"Alice\") { id } }"
```

- [ ] **Step 4: Run existing compilation tests (verify scalar form compiles)**

Run: `mvn -pl playbook-compiler test -Dtest=AgentExamplePlaybookTest --batch-mode -q`
Expected: all 8 examples PASS (they compile the YAML files directly)

- [ ] **Step 5: Run parsing tests**

Run: `mvn -pl yaml-step-runtime test -Dtest=PlaybookParsingTest --batch-mode -q`
Expected: PASS

- [ ] **Step 6: Run execution tests**

Run: `mvn -pl yaml-step-runtime test -Dtest=AgentExampleExecutionTest --batch-mode -q`
Expected: all PASS (these use `DeclarationParser.parseInvoke(step)` which now handles scalar)

- [ ] **Step 7: Commit**

```bash
git add yaml-core/src/main/resources/schema/playbook-document.schema.json examples/ playbook-catalog/
git commit -m "feat: scalar form for playbook steps — schema + 17 playbook edits

Refs #726"
```

## Batch 2: Simulation auto-wiring

### Task 4: SimulatingAction wrapper

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/SimulatingAction.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/YamlDefinitionSource.java` — optional SimulationRuntime, wrap actions
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/SimulatingActionTest.java`

**Interfaces:**
- Consumes: `Action` (yaml-plugin-api), `SimulationRuntime.strategyFor(String)` → `Optional<SimulationStrategy>`, `SimulationRuntime.hasActiveOverlay()`, `InvokeBinding` sealed interface
- Produces: `SimulatingAction implements Action` — transparent wrapper that checks simulation state before delegating

- [ ] **Step 1: Write failing test for SimulatingAction**

Create `yaml-step-runtime/src/test/java/io/casehub/yaml/step/SimulatingActionTest.java`:

```java
package io.casehub.yaml.step;

import io.casehub.platform.simulation.SimulationRuntime;
import io.casehub.platform.simulation.SimulationOverlay;
import io.casehub.platform.simulation.InMemorySimulationCorpus;
import io.casehub.platform.simulation.MapSimulationConfig;
import io.casehub.yaml.core.step.InvokeBinding;
import io.casehub.yaml.plugin.api.Action;
import io.casehub.yaml.plugin.api.Result;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class SimulatingActionTest {

    @Test
    void delegatesToRealAction_whenNoOverlayActive() {
        var runtime = new SimulationRuntime(MapSimulationConfig.builder().build(),
                new InMemorySimulationCorpus());
        Action real = (params, services) -> Result.of(Map.of("real", true), Map.of());
        var binding = new InvokeBinding.Rest("GET", "/api/users", Map.of(), Map.of());

        var simulating = new SimulatingAction(real, binding, runtime);
        var result = simulating.execute(Map.of(), null);

        assertThat(result).isInstanceOf(Result.Success.class);
        assertThat(((Result.Success) result).output()).containsEntry("real", true);
    }

    @Test
    void returnsCorpusResponse_whenOverlayHasMatch() {
        var corpus = new InMemorySimulationCorpus();
        var config = MapSimulationConfig.builder()
                .strategy("rest-request", "key-lookup")
                .build();
        var runtime = new SimulationRuntime(MapSimulationConfig.builder().build(),
                new InMemorySimulationCorpus());

        var overlayCorpus = new InMemorySimulationCorpus();
        overlayCorpus.record("rest-request", null, "/api/users",
                Map.of("url", "/api/users"),
                Map.of("users", java.util.List.of(Map.of("id", 1))));

        runtime.pushOverlay(config, overlayCorpus);

        Action real = (params, services) -> Result.of(Map.of("real", true), Map.of());
        var binding = new InvokeBinding.Rest("GET", "/api/users", Map.of(), Map.of());
        var simulating = new SimulatingAction(real, binding, runtime);

        var result = simulating.execute(Map.of(), null);
        assertThat(result).isInstanceOf(Result.Success.class);
        assertThat(((Result.Success) result).output()).containsKey("users");
    }

    @Test
    void delegatesToRealAction_whenOverlayHasNoMatch() {
        var config = MapSimulationConfig.builder()
                .strategy("rest-request", "key-lookup")
                .build();
        var runtime = new SimulationRuntime(MapSimulationConfig.builder().build(),
                new InMemorySimulationCorpus());
        runtime.pushOverlay(config, new InMemorySimulationCorpus());

        Action real = (params, services) -> Result.of(Map.of("real", true), Map.of());
        var binding = new InvokeBinding.Rest("GET", "/api/users", Map.of(), Map.of());
        var simulating = new SimulatingAction(real, binding, runtime);

        var result = simulating.execute(Map.of(), null);
        assertThat(result).isInstanceOf(Result.Success.class);
        assertThat(((Result.Success) result).output()).containsEntry("real", true);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl yaml-step-runtime test -Dtest=SimulatingActionTest --batch-mode -q`
Expected: FAIL (class not found)

- [ ] **Step 3: Implement SimulatingAction**

Use `ide_create_file` to create `yaml-step-runtime/src/main/java/io/casehub/yaml/step/SimulatingAction.java`:

```java
package io.casehub.yaml.step;

import io.casehub.platform.simulation.SimulationRuntime;
import io.casehub.platform.simulation.SimulationStrategy;
import io.casehub.yaml.core.step.InvokeBinding;
import io.casehub.yaml.plugin.api.Action;
import io.casehub.yaml.plugin.api.Result;
import io.casehub.yaml.plugin.api.ServiceRegistry;

import java.util.Map;
import java.util.Optional;

public class SimulatingAction implements Action {

    private final Action delegate;
    private final InvokeBinding binding;
    private final SimulationRuntime runtime;
    private final String qualifiedName;
    private final String lookupKey;

    public SimulatingAction(Action delegate, InvokeBinding binding, SimulationRuntime runtime) {
        this.delegate = delegate;
        this.binding = binding;
        this.runtime = runtime;
        this.qualifiedName = qualifiedNameFor(binding);
        this.lookupKey = keyFor(binding);
    }

    @Override
    @SuppressWarnings("unchecked")
    public Result execute(Map<String, Object> params, ServiceRegistry services) {
        if (runtime.hasActiveOverlay() && lookupKey != null) {
            Optional<SimulationStrategy<Object, Object>> strategy =
                    runtime.strategyFor(qualifiedName);
            if (strategy.isPresent()) {
                var simulated = strategy.get().resolve(lookupKey);
                if (simulated != null) {
                    Map<String, Object> output = simulated instanceof Map
                            ? (Map<String, Object>) simulated
                            : Map.of("response", simulated);
                    runtime.recordJournal(qualifiedName, null, lookupKey, output,
                            io.casehub.platform.simulation.api.DataRealism.CORPUS);
                    return Result.of(output, Map.of("simulated", true));
                }
            }
        }
        return delegate.execute(params, services);
    }

    private static String qualifiedNameFor(InvokeBinding binding) {
        return switch (binding) {
            case InvokeBinding.Rest r -> "rest-request";
            case InvokeBinding.Graphql g -> "graphql-exec";
            case InvokeBinding.Mcp m -> "mcp-call";
            case InvokeBinding.SessionClose c -> "agent-session-close";
            case InvokeBinding.SessionClear c -> "agent-session-clear";
            default -> binding.getClass().getSimpleName().toLowerCase();
        };
    }

    private static String keyFor(InvokeBinding binding) {
        return switch (binding) {
            case InvokeBinding.Rest r -> r.url();
            case InvokeBinding.Graphql g -> g.query();
            case InvokeBinding.Mcp m -> m.tool();
            case InvokeBinding.SessionClose c -> c.session();
            case InvokeBinding.SessionClear c -> c.session();
            default -> null;
        };
    }
}
```

Note: The exact imports for `DataRealism` and `SimulationStrategy.resolve()` may need adjustment based on the actual API — verify against `SimulationStrategy` interface and `DataRealism` enum location. If `SimulationStrategy.resolve(key)` is not the correct method signature, use `strategyFor` + the appropriate invocation method from the simulation-core API. The test in Step 1 will validate the contract.

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -pl yaml-step-runtime test -Dtest=SimulatingActionTest --batch-mode -q`
Expected: PASS (may need import/API adjustments — iterate until green)

- [ ] **Step 5: Wire SimulatingAction into YamlDefinitionSource**

Add an optional `SimulationRuntime` field to `YamlDefinitionSource`:

```java
private final SimulationRuntime simulationRuntime;

public YamlDefinitionSource(List<String> definitionFiles,
                            List<InvokeHandler> handlers,
                            Consumer<ActionExecutionEvent> eventSink) {
    this(definitionFiles, handlers, eventSink, null);
}

public YamlDefinitionSource(List<String> definitionFiles,
                            List<InvokeHandler> handlers,
                            Consumer<ActionExecutionEvent> eventSink,
                            SimulationRuntime simulationRuntime) {
    this.definitionFiles = definitionFiles;
    this.handlers = handlers;
    this.eventSink = eventSink;
    this.simulationRuntime = simulationRuntime;
}
```

In `loadFile()`, wrap the action when simulation is available (line 82-83):

```java
Action action = resolveHandler(binding).create(decl, binding);
if (simulationRuntime != null) {
    action = new SimulatingAction(action, binding, simulationRuntime);
}
Action validated = new ValidatingAction(decl, action, eventSink);
```

- [ ] **Step 6: Run full yaml-step-runtime test suite**

Run: `mvn -pl yaml-step-runtime test --batch-mode -q`
Expected: all PASS (existing tests use the original 3-arg constructor — no SimulationRuntime)

- [ ] **Step 7: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/SimulatingAction.java yaml-step-runtime/src/test/java/io/casehub/yaml/step/SimulatingActionTest.java yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/YamlDefinitionSource.java
git commit -m "feat(yaml-step-runtime): SimulatingAction wrapper for invoke binding simulation

Transparent action wrapper checks simulation overlay at execution time.
When corpus has a match, returns simulated response without calling real handler.
Wired into YamlDefinitionSource via optional SimulationRuntime constructor param.

Refs #726"
```

### Task 5: Full build verification

**Files:**
- No new files — verification only

**Interfaces:**
- Consumes: all changes from Tasks 1-4

- [ ] **Step 1: Run full project build**

Run: `mvn --batch-mode install -q`
Expected: BUILD SUCCESS

- [ ] **Step 2: Verify example playbook execution tests**

Run: `mvn -pl yaml-step-runtime test -Dtest=AgentExampleExecutionTest --batch-mode -q`
Expected: all 8 example tests PASS with scalar form playbooks

- [ ] **Step 3: Commit any fixups if needed**

If any test failures were found and fixed in steps 1-2, commit:
```bash
git add -u
git commit -m "fix: address build issues from scalar subjects + simulation wiring

Refs #726"
```

## References

- [2026-11-06-scalar-subjects-simulation-design.md] — design spec this plan implements
- [yaml-core/.../DeclarationParser.java:219-228] — current Map-only binding parsing
- [yaml-core/.../InvokeBinding.java] — sealed interface with all binding types
- [playbook-compiler/.../AgentSessionStepCompiler.java] — current Map-only step compilation
- [playbook-compiler/.../RestRequestCompiler.java] — current Map-only REST compilation
- [playbook-compiler/.../PlaybookCompiler.java:40-57] — step compiler registration
- [yaml-step-runtime/.../YamlDefinitionSource.java:82-90] — handler→action→definition wiring
- [yaml-step-runtime/.../AgentExampleExecutionTest.java:396-409] — DeclarationParser.parseInvoke() runtime usage
- [simulation-core/.../SimulationRuntime.java:52-66] — strategyFor() overlay lookup
- [yaml-core/.../playbook-document.schema.json:177-227] — current schema definitions
- [GitHub #726] — focal issue
