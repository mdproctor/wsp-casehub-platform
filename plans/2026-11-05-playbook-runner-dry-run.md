# Playbook Runner with Dry-Run Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #708 — feat: playbook dry-run mode via simulation layer
**Issue group:** #708

**Goal:** Extract a reusable PlaybookRunnerCore from RunPlaybookPlugin, add step tracing with a StepTraceNode tree, expose via @McpDomain("playbooks") and CLI --dry-run flag.

**Architecture:** PlaybookRunnerCore (yaml-test-core) extracts the parse → resolve → evaluate pipeline from RunPlaybookPlugin. A StepExecutionListener on StructuralStepEvaluator captures step-level trace data into a StepTraceNode tree. Dry-run pushes a simulation overlay before execution. CLI extends YamlTestCli; MCP surface uses @McpDomain("playbooks") with graphql-generator APT.

**Tech Stack:** Java 21+, yaml-test-core, yaml-step-runtime, simulation-core, mcp-api (annotations only), JUnit 5, AssertJ

## Global Constraints

- yaml-test-core remains framework-neutral — no CDI, no Spring, no Quarkus imports
- mcp-api is zero-dependency annotations — safe to add to yaml-test-core
- StepTraceNode and StepOutcome are shared types — no test-specific or playbook-specific fields
- Backward compatibility: RunPlaybookPlugin's output map structure (`succeeded`, `stepCount`, `duration`, `stepEvents`, `output`, `error`) must be preserved
- All orchestration primitives use j.u.c locks — never `synchronized`

---

## Batch 1: StepTraceNode model + StepExecutionListener

Foundation types and the tracing hook on StructuralStepEvaluator. After this batch, the trace infrastructure exists and can be tested independently.

### Task 1: StepTraceNode, StepOutcome, and StepExecutionListener types

**Files:**
- Create: `yaml-test-core/src/main/java/io/casehub/yaml/test/StepTraceNode.java`
- Create: `yaml-test-core/src/main/java/io/casehub/yaml/test/StepOutcome.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StepExecutionListener.java`
- Test: `yaml-test-core/src/test/java/io/casehub/yaml/test/StepTraceNodeTest.java`

**Interfaces:**
- Consumes: nothing (foundation types)
- Produces: `StepTraceNode(int index, String name, String type, String action, StepOutcome outcome, long durationMs, Map<String, Object> detail, List<StepTraceNode> children)`, `StepOutcome` enum (`EXECUTED, SKIPPED, SIMULATED, FAILED, ERROR`), `StepExecutionListener` functional interface

- [ ] **Step 1: Write StepTraceNode flatten test**

```java
package io.casehub.yaml.test;

import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class StepTraceNodeTest {

    @Test
    void flattenProducesDepthFirstList() {
        var child1 = StepTraceNode.leaf(0, "step-a", "plugin", "agent-invoke",
                StepOutcome.SIMULATED, 5, Map.of("strategy", "key-lookup"));
        var child2 = StepTraceNode.leaf(1, "step-b", "plugin", "assertThat",
                StepOutcome.EXECUTED, 2, Map.of());
        var root = new StepTraceNode(0, "block", "block", null,
                StepOutcome.EXECUTED, 10, Map.of(), List.of(child1, child2));

        var flat = root.flatten();

        assertThat(flat).hasSize(3);
        assertThat(flat.get(0).depth()).isEqualTo(0);
        assertThat(flat.get(0).node()).isEqualTo(root);
        assertThat(flat.get(1).depth()).isEqualTo(1);
        assertThat(flat.get(1).node()).isEqualTo(child1);
        assertThat(flat.get(2).depth()).isEqualTo(1);
        assertThat(flat.get(2).node()).isEqualTo(child2);
    }

    @Test
    void leafHasEmptyChildren() {
        var leaf = StepTraceNode.leaf(0, "s", "plugin", "act",
                StepOutcome.EXECUTED, 1, Map.of());
        assertThat(leaf.children()).isEmpty();
    }

    @Test
    void stepCountRecursive() {
        var child = StepTraceNode.leaf(0, "s", "plugin", "act",
                StepOutcome.EXECUTED, 1, Map.of());
        var root = new StepTraceNode(0, "b", "block", null,
                StepOutcome.EXECUTED, 5, Map.of(), List.of(child));
        assertThat(root.stepCount()).isEqualTo(2);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=StepTraceNodeTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: Compilation error — StepTraceNode does not exist

- [ ] **Step 3: Implement StepOutcome enum**

```java
package io.casehub.yaml.test;

public enum StepOutcome {
    EXECUTED,
    SKIPPED,
    SIMULATED,
    FAILED,
    ERROR
}
```

- [ ] **Step 4: Implement StepTraceNode record**

```java
package io.casehub.yaml.test;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public record StepTraceNode(
        int index,
        String name,
        String type,
        String action,
        StepOutcome outcome,
        long durationMs,
        Map<String, Object> detail,
        List<StepTraceNode> children) {

    public StepTraceNode {
        detail = detail != null ? Map.copyOf(detail) : Map.of();
        children = children != null ? List.copyOf(children) : List.of();
    }

    public static StepTraceNode leaf(int index, String name, String type,
                                      String action, StepOutcome outcome,
                                      long durationMs, Map<String, Object> detail) {
        return new StepTraceNode(index, name, type, action, outcome,
                                 durationMs, detail, List.of());
    }

    public record FlatEntry(int depth, StepTraceNode node) {}

    public List<FlatEntry> flatten() {
        List<FlatEntry> result = new ArrayList<>();
        flatten(this, 0, result);
        return result;
    }

    private static void flatten(StepTraceNode node, int depth, List<FlatEntry> result) {
        result.add(new FlatEntry(depth, node));
        for (var child : node.children) {
            flatten(child, depth + 1, result);
        }
    }

    public int stepCount() {
        int count = 1;
        for (var child : children) {
            count += child.stepCount();
        }
        return count;
    }
}
```

- [ ] **Step 5: Implement StepExecutionListener**

```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.step.catalog.ResolvedStep;
import io.casehub.yaml.plugin.api.Result;

import java.util.List;
import java.util.Map;

@FunctionalInterface
public interface StepExecutionListener {

    void onStepComplete(ResolvedStep step, int index, Result result,
                        long durationMs, Map<String, Object> detail);
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=StepTraceNodeTest`
Expected: All 3 tests PASS

- [ ] **Step 7: Commit**

```
git add yaml-test-core/src/main/java/io/casehub/yaml/test/StepTraceNode.java \
        yaml-test-core/src/main/java/io/casehub/yaml/test/StepOutcome.java \
        yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StepExecutionListener.java \
        yaml-test-core/src/test/java/io/casehub/yaml/test/StepTraceNodeTest.java
git commit -m "feat(#708): add StepTraceNode, StepOutcome, and StepExecutionListener"
```

---

## Batch 2: PlaybookRunnerCore + result types

The core runner POJO with tracing, extracted from RunPlaybookPlugin's execution logic. After this batch, playbooks can be run programmatically with trace output.

### Task 2: PlaybookRunConfig, PlaybookRunResult, PlaybookValidationResult records

**Files:**
- Create: `yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookRunConfig.java`
- Create: `yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookRunResult.java`
- Create: `yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookValidationResult.java`
- Test: `yaml-test-core/src/test/java/io/casehub/yaml/test/PlaybookRunResultTest.java`

**Interfaces:**
- Consumes: `StepTraceNode`, `StepOutcome`, `CapturedEvent` (existing)
- Produces: `PlaybookRunConfig(boolean dryRun, Map<String, Object> vars, String corpusPath, String simulationProfile)` with factory methods `defaults()` and `dryRun()`. `PlaybookRunResult(boolean success, String playbookName, String playbookPath, long durationMs, StepTraceNode trace, List<CapturedEvent> events, Map<String, Object> output, String error)`. `PlaybookValidationResult(boolean valid, List<String> errors, PlaybookFrontMatter frontMatter)`.

- [ ] **Step 1: Write tests for result types**

```java
package io.casehub.yaml.test;

import io.casehub.yaml.core.playbook.PlaybookFrontMatter;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class PlaybookRunResultTest {

    @Test
    void configDefaultsAreNotDryRun() {
        var config = PlaybookRunConfig.defaults();
        assertThat(config.dryRun()).isFalse();
        assertThat(config.vars()).isEmpty();
        assertThat(config.corpusPath()).isNull();
        assertThat(config.simulationProfile()).isNull();
    }

    @Test
    void configDryRunFactorySetsDryRunTrue() {
        var config = PlaybookRunConfig.dryRun();
        assertThat(config.dryRun()).isTrue();
    }

    @Test
    void validationResultReportsErrors() {
        var result = new PlaybookValidationResult(false,
                List.of("Unknown key 'foo'"), null);
        assertThat(result.valid()).isFalse();
        assertThat(result.errors()).containsExactly("Unknown key 'foo'");
    }

    @Test
    void successfulRunResult() {
        var trace = StepTraceNode.leaf(0, "s", "plugin", "act",
                StepOutcome.EXECUTED, 5, Map.of());
        var result = new PlaybookRunResult(true, "test-playbook",
                "test.yaml", 10, trace, List.of(), Map.of("key", "val"), null);
        assertThat(result.success()).isTrue();
        assertThat(result.trace().stepCount()).isEqualTo(1);
        assertThat(result.output()).containsEntry("key", "val");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=PlaybookRunResultTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: Compilation error — types don't exist

- [ ] **Step 3: Implement the three record types**

`PlaybookRunConfig.java`:
```java
package io.casehub.yaml.test;

import java.util.Map;

public record PlaybookRunConfig(
        boolean dryRun,
        Map<String, Object> vars,
        String corpusPath,
        String simulationProfile) {

    public PlaybookRunConfig {
        vars = vars != null ? Map.copyOf(vars) : Map.of();
    }

    public static PlaybookRunConfig defaults() {
        return new PlaybookRunConfig(false, Map.of(), null, null);
    }

    public static PlaybookRunConfig dryRun() {
        return new PlaybookRunConfig(true, Map.of(), null, null);
    }
}
```

`PlaybookRunResult.java`:
```java
package io.casehub.yaml.test;

import java.util.List;
import java.util.Map;

public record PlaybookRunResult(
        boolean success,
        String playbookName,
        String playbookPath,
        long durationMs,
        StepTraceNode trace,
        List<CapturedEvent> events,
        Map<String, Object> output,
        String error) {

    public PlaybookRunResult {
        events = events != null ? List.copyOf(events) : List.of();
        output = output != null ? Map.copyOf(output) : Map.of();
    }
}
```

`PlaybookValidationResult.java`:
```java
package io.casehub.yaml.test;

import io.casehub.yaml.core.playbook.PlaybookFrontMatter;
import java.util.List;

public record PlaybookValidationResult(
        boolean valid,
        List<String> errors,
        PlaybookFrontMatter frontMatter) {

    public PlaybookValidationResult {
        errors = errors != null ? List.copyOf(errors) : List.of();
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=PlaybookRunResultTest`
Expected: All 4 tests PASS

- [ ] **Step 5: Commit**

```
git add yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookRunConfig.java \
        yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookRunResult.java \
        yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookValidationResult.java \
        yaml-test-core/src/test/java/io/casehub/yaml/test/PlaybookRunResultTest.java
git commit -m "feat(#708): add PlaybookRunConfig, PlaybookRunResult, PlaybookValidationResult"
```

### Task 3: PlaybookRunnerCore — run and validate

**Files:**
- Create: `yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookRunnerCore.java`
- Test: `yaml-test-core/src/test/java/io/casehub/yaml/test/PlaybookRunnerCoreTest.java`
- Create: `yaml-test-core/src/test/resources/playbooks/simple.yaml` (test fixture)
- Create: `yaml-test-core/src/test/resources/playbooks/invalid.yaml` (test fixture)
- Create: `yaml-test-core/src/test/resources/playbooks/with-params.yaml` (test fixture)

**Interfaces:**
- Consumes: `PlaybookRunConfig`, `PlaybookRunResult`, `PlaybookValidationResult`, `StepTraceNode`, `StepOutcome` (Task 1-2). `Walker.resolve()`, `StructuralStepEvaluator`, `CatalogStepRunner` (yaml-step-runtime). `PlaybookParser.parse()`, `PlaybookVariableParser.parse()` (yaml-core). `SimulationRuntime.pushOverlay()/popOverlay()` (simulation-core). `SimulateBlockParser.parse()` (existing in yaml-test-core).
- Produces: `PlaybookRunnerCore(PluginRegistry, ServiceRegistry, Path, SimulationRuntime)` with `PlaybookRunResult run(Path, PlaybookRunConfig)` and `PlaybookValidationResult validate(Path)`.

- [ ] **Step 1: Write test fixtures**

`yaml-test-core/src/test/resources/playbooks/simple.yaml`:
```yaml
name: Simple playbook
steps:
  - agent-invoke:
      prompt: "hello"
    capture: result
  - assertThat: ${result.text}
    contains: 'hello'
```

`yaml-test-core/src/test/resources/playbooks/invalid.yaml`:
```yaml
name: Invalid playbook
steps:
  - unknown-action: "should fail"
```

`yaml-test-core/src/test/resources/playbooks/with-params.yaml`:
```yaml
name: Parameterized playbook
params:
  greeting: "default hello"
steps:
  - agent-invoke:
      prompt: ${greeting}
    capture: result
```

- [ ] **Step 2: Write PlaybookRunnerCore tests**

```java
package io.casehub.yaml.test;

import io.casehub.yaml.plugin.api.Definition;
import io.casehub.yaml.plugin.api.MapServiceRegistry;
import io.casehub.yaml.plugin.api.Result;
import io.casehub.yaml.step.catalog.CompositePluginRegistry;
import io.casehub.yaml.step.plugin.AssertThatPlugin;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.nio.file.Path;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class PlaybookRunnerCoreTest {

    private static final Path PLAYBOOK_ROOT = Path.of("src/test/resources/playbooks");

    private CompositePluginRegistry pluginRegistry;
    private MapServiceRegistry serviceRegistry;

    @BeforeEach
    void setUp() {
        pluginRegistry = new CompositePluginRegistry();
        pluginRegistry.register(AssertThatPlugin.definition());
        pluginRegistry.register(Definition.of("agent-invoke")
                .execute((params, svc) -> Result.of(Map.of("text", String.valueOf(params.get("prompt")))))
                .build());
        serviceRegistry = new MapServiceRegistry();
    }

    @Test
    void runSimplePlaybookSucceeds() {
        var runner = new PlaybookRunnerCore(pluginRegistry, serviceRegistry,
                PLAYBOOK_ROOT, null);
        var result = runner.run(PLAYBOOK_ROOT.resolve("simple.yaml"),
                PlaybookRunConfig.defaults());

        assertThat(result.success()).isTrue();
        assertThat(result.playbookName()).isEqualTo("Simple playbook");
        assertThat(result.trace()).isNotNull();
        assertThat(result.trace().children()).hasSize(2);
        assertThat(result.durationMs()).isGreaterThanOrEqualTo(0);
    }

    @Test
    void runPlaybookWithParamsPassesVars() {
        var runner = new PlaybookRunnerCore(pluginRegistry, serviceRegistry,
                PLAYBOOK_ROOT, null);
        var config = new PlaybookRunConfig(false, Map.of("greeting", "hi"), null, null);
        var result = runner.run(PLAYBOOK_ROOT.resolve("with-params.yaml"), config);

        assertThat(result.success()).isTrue();
    }

    @Test
    void validateValidPlaybookReturnsValid() {
        var runner = new PlaybookRunnerCore(pluginRegistry, serviceRegistry,
                PLAYBOOK_ROOT, null);
        var result = runner.validate(PLAYBOOK_ROOT.resolve("simple.yaml"));

        assertThat(result.valid()).isTrue();
        assertThat(result.errors()).isEmpty();
    }

    @Test
    void validateInvalidPlaybookReturnsErrors() {
        var runner = new PlaybookRunnerCore(pluginRegistry, serviceRegistry,
                PLAYBOOK_ROOT, null);
        var result = runner.validate(PLAYBOOK_ROOT.resolve("invalid.yaml"));

        assertThat(result.valid()).isFalse();
        assertThat(result.errors()).isNotEmpty();
    }

    @Test
    void runTraceRecordsStepOutcomes() {
        var runner = new PlaybookRunnerCore(pluginRegistry, serviceRegistry,
                PLAYBOOK_ROOT, null);
        var result = runner.run(PLAYBOOK_ROOT.resolve("simple.yaml"),
                PlaybookRunConfig.defaults());

        var flat = result.trace().flatten();
        assertThat(flat).hasSizeGreaterThanOrEqualTo(2);
        assertThat(flat).allMatch(e -> e.node().outcome() == StepOutcome.EXECUTED);
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=PlaybookRunnerCoreTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: Compilation error — PlaybookRunnerCore does not exist

- [ ] **Step 4: Implement PlaybookRunnerCore**

The implementation follows `RunPlaybookPlugin.execute()` structure but:
- Uses `PlaybookParser.parse()` for multi-document playbooks
- Wraps `CatalogStepRunner` with trace-building logic
- Builds `StepTraceNode` tree from step results
- Pushes/pops simulation overlay for dry-run mode

```java
package io.casehub.yaml.test;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import io.casehub.platform.simulation.SimulationOverlay;
import io.casehub.platform.simulation.SimulationRuntime;
import io.casehub.yaml.core.playbook.PlaybookDocument;
import io.casehub.yaml.core.playbook.PlaybookFrontMatter;
import io.casehub.yaml.core.playbook.PlaybookVariableParser;
import io.casehub.yaml.core.resolver.VariableResolver;
import io.casehub.yaml.plugin.api.PluginRegistry;
import io.casehub.yaml.plugin.api.Result;
import io.casehub.yaml.plugin.api.ServiceRegistry;
import io.casehub.yaml.step.catalog.ResolvedStep;
import io.casehub.yaml.step.catalog.Walker;
import io.casehub.yaml.step.eval.CatalogStepRunner;
import io.casehub.yaml.step.eval.StructuralStepEvaluator;
import io.casehub.yaml.step.plugin.EventSink;
import io.casehub.yaml.step.statemachine.PlaybookParser;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

public final class PlaybookRunnerCore {

    private final PluginRegistry pluginRegistry;
    private final ServiceRegistry serviceRegistry;
    private final Path resourceRoot;
    private final SimulationRuntime simulationRuntime;

    public PlaybookRunnerCore(PluginRegistry pluginRegistry,
                              ServiceRegistry serviceRegistry,
                              Path resourceRoot,
                              SimulationRuntime simulationRuntime) {
        this.pluginRegistry = pluginRegistry;
        this.serviceRegistry = serviceRegistry;
        this.resourceRoot = resourceRoot;
        this.simulationRuntime = simulationRuntime;
    }

    @SuppressWarnings("unchecked")
    public PlaybookRunResult run(Path playbookPath, PlaybookRunConfig config) {
        long start = System.nanoTime();
        SimulationOverlay overlay = null;
        EventCapture eventCapture = new EventCapture();

        try {
            String yaml = Files.readString(playbookPath);
            PlaybookDocument doc = PlaybookParser.parse(yaml);
            Map<String, Object> content = doc.content();

            String playbookName = doc.hasPlaybookHeader() && doc.frontMatter().name() != null
                    ? doc.frontMatter().name()
                    : (String) content.getOrDefault("name", playbookPath.getFileName().toString());

            if (config.dryRun() && simulationRuntime != null) {
                overlay = activateSimulation(config);
            }

            var parsed = PlaybookVariableParser.parse(content);

            Map<String, String> callerParams = new LinkedHashMap<>();
            if (config.vars() != null) {
                for (var entry : config.vars().entrySet()) {
                    callerParams.put(entry.getKey(), String.valueOf(entry.getValue()));
                }
            }

            if (!parsed.params().isEmpty()) {
                io.casehub.yaml.core.module.ParameterValidator.validateOrThrow(
                        parsed.params(), callerParams);
            }

            var steps = (List<Map<String, Object>>) content.get("steps");
            if (steps == null || steps.isEmpty()) {
                long durationMs = (System.nanoTime() - start) / 1_000_000;
                return new PlaybookRunResult(true, playbookName,
                        playbookPath.toString(), durationMs,
                        StepTraceNode.leaf(0, playbookName, "playbook", null,
                                StepOutcome.EXECUTED, durationMs, Map.of()),
                        eventCapture.events(), Map.of(), null);
            }

            var runServices = new io.casehub.yaml.plugin.api.MapServiceRegistry();
            runServices.register(EventSink.class, (EventSink) eventCapture::addEvent);

            List<ResolvedStep> resolved = Walker.resolve(steps, pluginRegistry);
            var runner = new CatalogStepRunner(pluginRegistry, runServices);
            var evaluator = new StructuralStepEvaluator(
                    new io.casehub.yaml.core.condition.ConditionEvaluator(null));

            VariableResolver resolver = parsed.params().isEmpty() && parsed.vars().values().isEmpty()
                    ? new VariableResolver(Map.of(), Set.of("events"))
                    : VariableResolver.forParams(parsed.params(), callerParams, Set.of("events"));

            if (!parsed.vars().values().isEmpty()) {
                resolver = resolver.withObjectScope("var",
                        name -> parsed.vars().values().get(name));
            }

            List<StepTraceNode> childTraces = new ArrayList<>();
            Map<String, Object> outputVars = new LinkedHashMap<>();
            boolean allPassed = true;
            String errorMsg = null;

            for (int i = 0; i < resolved.size(); i++) {
                var step = resolved.get(i);
                long stepStart = System.nanoTime();
                Result result = evaluator.evaluate(step, resolver, runner);
                long stepDurationMs = (System.nanoTime() - stepStart) / 1_000_000;

                String stepName = step.name();
                String stepType = resolveStepType(step);
                String actionName = step instanceof ResolvedStep.PluginStep ps ? ps.actionName() : null;
                StepOutcome outcome = result.isSuccess() ? StepOutcome.EXECUTED : StepOutcome.FAILED;

                childTraces.add(StepTraceNode.leaf(i, stepName, stepType,
                        actionName, outcome, stepDurationMs, Map.of()));

                if (!result.isSuccess()) {
                    allPassed = false;
                    errorMsg = result instanceof Result.Failure f ? f.message() : "Step failed";
                    break;
                }

                if (result.output() != null) {
                    outputVars.putAll(result.output());
                }

                if (step instanceof ResolvedStep.PluginStep ps) {
                    var capture = ps.decorators().get("capture");
                    if (capture != null && result.output() != null) {
                        Map<String, Object> capturedOutput = result.output();
                        resolver = resolver.withObjectScope(
                                String.valueOf(capture), capturedOutput::get);
                    }
                }
            }

            long durationMs = (System.nanoTime() - start) / 1_000_000;
            var rootTrace = new StepTraceNode(0, playbookName, "playbook", null,
                    allPassed ? StepOutcome.EXECUTED : StepOutcome.FAILED,
                    durationMs, Map.of(), childTraces);

            return new PlaybookRunResult(allPassed, playbookName,
                    playbookPath.toString(), durationMs, rootTrace,
                    eventCapture.events(), outputVars, errorMsg);

        } catch (io.casehub.yaml.core.module.ParameterValidationException e) {
            long durationMs = (System.nanoTime() - start) / 1_000_000;
            return new PlaybookRunResult(false, playbookPath.getFileName().toString(),
                    playbookPath.toString(), durationMs, null, List.of(), Map.of(),
                    "Parameter validation failed: " + e.getMessage());
        } catch (Exception e) {
            long durationMs = (System.nanoTime() - start) / 1_000_000;
            return new PlaybookRunResult(false, playbookPath.getFileName().toString(),
                    playbookPath.toString(), durationMs, null, List.of(), Map.of(),
                    e.getMessage());
        } finally {
            if (overlay != null && simulationRuntime != null) {
                simulationRuntime.popOverlay(overlay);
            }
        }
    }

    @SuppressWarnings("unchecked")
    public PlaybookValidationResult validate(Path playbookPath) {
        try {
            String yaml = Files.readString(playbookPath);
            PlaybookDocument doc = PlaybookParser.parse(yaml);
            Map<String, Object> content = doc.content();
            PlaybookFrontMatter frontMatter = doc.frontMatter();

            var steps = (List<Map<String, Object>>) content.get("steps");
            if (steps == null || steps.isEmpty()) {
                return new PlaybookValidationResult(true, List.of(), frontMatter);
            }

            Walker.resolve(steps, pluginRegistry);
            return new PlaybookValidationResult(true, List.of(), frontMatter);
        } catch (Exception e) {
            return new PlaybookValidationResult(false, List.of(e.getMessage()), null);
        }
    }

    private SimulationOverlay activateSimulation(PlaybookRunConfig config) {
        if (config.corpusPath() != null) {
            Path corpusFile = resourceRoot.resolve(config.corpusPath());
            var parsed = SimulateBlockParser.parse(
                    loadYamlMap(corpusFile), resourceRoot);
            return simulationRuntime.pushOverlay(parsed.config(), parsed.corpus());
        }
        return simulationRuntime.pushOverlay(
                io.casehub.platform.simulation.MapSimulationConfig.builder().build());
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> loadYamlMap(Path path) {
        try {
            var mapper = new ObjectMapper(new YAMLFactory());
            return mapper.readValue(Files.newInputStream(path), Map.class);
        } catch (Exception e) {
            throw new IllegalArgumentException("Failed to load: " + path, e);
        }
    }

    private static String resolveStepType(ResolvedStep step) {
        return switch (step) {
            case ResolvedStep.PluginStep ignored -> "plugin";
            case ResolvedStep.InvokeStep ignored -> "invoke";
            case ResolvedStep.BlockStep ignored -> "block";
            case ResolvedStep.IfElseStep ignored -> "if-else";
            case ResolvedStep.MatchStep ignored -> "match";
            case ResolvedStep.ParallelStep ignored -> "parallel";
            case ResolvedStep.TryCatchFinallyStep ignored -> "try-catch-finally";
            case ResolvedStep.SelectStep ignored -> "select";
            case ResolvedStep.BarrierStep ignored -> "barrier";
            case ResolvedStep.QuorumStep ignored -> "quorum";
            case ResolvedStep.ControlStep ignored -> "control";
            case ResolvedStep.RaceStep ignored -> "race";
            case ResolvedStep.FusedPipelineStep ignored -> "fused-pipeline";
        };
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=PlaybookRunnerCoreTest`
Expected: All 5 tests PASS

- [ ] **Step 6: Commit**

```
git add yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookRunnerCore.java \
        yaml-test-core/src/test/java/io/casehub/yaml/test/PlaybookRunnerCoreTest.java \
        yaml-test-core/src/test/resources/playbooks/
git commit -m "feat(#708): add PlaybookRunnerCore with run and validate"
```

---

## Batch 3: CLI extensions + RunPlaybookPlugin delegation

Extend YamlTestCli with --dry-run, wire SimulationRuntime, and refactor RunPlaybookPlugin to delegate. After this batch, dry-run works from the command line and RunPlaybookPlugin uses the shared runner.

### Task 4: YamlTestCli --dry-run and SimulationRuntime wiring

**Files:**
- Modify: `yaml-test-core/src/main/java/io/casehub/yaml/test/YamlTestCli.java`
- Test: `yaml-test-core/src/test/java/io/casehub/yaml/test/YamlTestCliTest.java`
- Create: `yaml-test-core/src/test/resources/playbooks/dry-run-agent.yaml` (test fixture)
- Create: `yaml-test-core/src/test/resources/playbooks/corpus.yaml` (test fixture)

**Interfaces:**
- Consumes: `PlaybookRunnerCore` (Task 3), `PlaybookRunConfig`, `PlaybookRunResult`, `StepTraceNode.flatten()` (Tasks 1-2). `SimulationRuntime` (simulation-core). `SimulateBlockParser` (existing).
- Produces: Extended `main(String[])` with `--dry-run`, `--corpus`, `--profile`, `--var` flags. Playbook mode when path is `.yaml` (not `.test.yaml`).

- [ ] **Step 1: Write test fixtures**

`yaml-test-core/src/test/resources/playbooks/dry-run-agent.yaml`:
```yaml
name: Dry run agent test
steps:
  - agent-invoke:
      prompt: "test prompt"
    capture: result
```

`yaml-test-core/src/test/resources/playbooks/corpus.yaml`:
```yaml
agent:
  - prompt: "test prompt"
    response: "simulated response"
```

- [ ] **Step 2: Write CLI test**

```java
package io.casehub.yaml.test;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class YamlTestCliTest {

    @Test
    void parseArgsDryRunFlag() {
        var args = YamlTestCli.parseArgs(new String[]{
                "--dry-run", "--corpus", "corpus.yaml",
                "--var", "key=val", "playbooks/"});
        assertThat(args.dryRun()).isTrue();
        assertThat(args.corpusPath()).isEqualTo("corpus.yaml");
        assertThat(args.vars()).containsEntry("key", "val");
        assertThat(args.paths()).containsExactly("playbooks/");
    }

    @Test
    void parseArgsDefaultsNotDryRun() {
        var args = YamlTestCli.parseArgs(new String[]{"tests/"});
        assertThat(args.dryRun()).isFalse();
        assertThat(args.corpusPath()).isNull();
        assertThat(args.vars()).isEmpty();
    }

    @Test
    void isPlaybookFileDetectsYamlNotTest() {
        assertThat(YamlTestCli.isPlaybookFile("example.yaml")).isTrue();
        assertThat(YamlTestCli.isPlaybookFile("test.test.yaml")).isFalse();
        assertThat(YamlTestCli.isPlaybookFile("dir/playbook.yml")).isTrue();
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=YamlTestCliTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: Compilation error — parseArgs method doesn't exist

- [ ] **Step 4: Implement YamlTestCli extensions**

Refactor `YamlTestCli.main()` to extract `parseArgs()` into a testable `ParsedArgs` record. Add `--dry-run`, `--corpus`, `--profile`, `--var` flag parsing. Add `isPlaybookFile()` utility. Add playbook execution branch that uses `PlaybookRunnerCore`. Wire `SimulationRuntime` (standalone: `new SimulationRuntime(MapSimulationConfig.builder().build(), new InMemorySimulationCorpus<>())`).

Key changes to `main()`:
- Parse new flags into `ParsedArgs`
- Construct `SimulationRuntime` (fixes existing gap)
- Pass `SimulationRuntime` to `YamlTestExecutor` constructor (4-arg version)
- For playbook files: use `PlaybookRunnerCore` with `PlaybookRunConfig`
- Print playbook results using `StepTraceNode.flatten()` for indented output

The complete implementation is ~120 lines. The existing test-mode code path remains unchanged except for receiving `SimulationRuntime`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=YamlTestCliTest`
Expected: All 3 tests PASS

- [ ] **Step 6: Run existing tests to verify no regression**

Run: `mvn --batch-mode test -pl yaml-test-core`
Expected: All tests PASS (existing + new)

- [ ] **Step 7: Commit**

```
git add yaml-test-core/src/main/java/io/casehub/yaml/test/YamlTestCli.java \
        yaml-test-core/src/test/java/io/casehub/yaml/test/YamlTestCliTest.java \
        yaml-test-core/src/test/resources/playbooks/
git commit -m "feat(#708): extend YamlTestCli with --dry-run, --corpus, --profile, --var flags"
```

### Task 5: RunPlaybookPlugin delegates to PlaybookRunnerCore

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/RunPlaybookPlugin.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/plugin/RunPlaybookPluginTest.java` (if exists, else create)

**Interfaces:**
- Consumes: `PlaybookRunnerCore.run()` (Task 3), `PlaybookRunConfig` (Task 2), `StepTraceNode.flatten()` (Task 1)
- Produces: Same `Result` output map as before (`succeeded`, `output`, `stepCount`, `duration`, `stepEvents`, `error`) — backward compatible

- [ ] **Step 1: Write test for backward-compatible output format**

```java
package io.casehub.yaml.step.plugin;

import io.casehub.yaml.plugin.api.Definition;
import io.casehub.yaml.plugin.api.MapServiceRegistry;
import io.casehub.yaml.plugin.api.Result;
import io.casehub.yaml.step.catalog.CompositePluginRegistry;
import io.casehub.yaml.step.plugin.AssertThatPlugin;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.nio.file.Path;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class RunPlaybookPluginDelegationTest {

    private CompositePluginRegistry pluginRegistry;
    private MapServiceRegistry serviceRegistry;

    @BeforeEach
    void setUp() {
        pluginRegistry = new CompositePluginRegistry();
        pluginRegistry.register(AssertThatPlugin.definition());
        pluginRegistry.register(RunPlaybookPlugin.definition());
        pluginRegistry.register(Definition.of("agent-invoke")
                .execute((params, svc) -> Result.of(Map.of("text", String.valueOf(params.get("prompt")))))
                .build());
        serviceRegistry = new MapServiceRegistry();
        serviceRegistry.register(TestExecutionContext.class,
                new TestExecutionContext(pluginRegistry, serviceRegistry,
                        Path.of("src/test/resources"), null));
    }

    @Test
    @SuppressWarnings("unchecked")
    void runPlaybookProducesBackwardCompatibleOutput() {
        var result = RunPlaybookPlugin.definition().action().execute(
                Map.of("_subject", "playbooks/simple.yaml"), serviceRegistry);

        assertThat(result.isSuccess()).isTrue();
        assertThat(result.output()).containsKey("succeeded");
        assertThat(result.output()).containsKey("stepCount");
        assertThat(result.output()).containsKey("duration");
        assertThat(result.output()).containsKey("stepEvents");
        assertThat((Boolean) result.output().get("succeeded")).isTrue();
        assertThat(((List<?>) result.output().get("stepEvents"))).isNotEmpty();
    }
}
```

- [ ] **Step 2: Run test to verify it passes with current implementation**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=RunPlaybookPluginDelegationTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: PASS (current code already produces this output)

- [ ] **Step 3: Refactor RunPlaybookPlugin to delegate**

Replace the inline execution logic with delegation to `PlaybookRunnerCore`. Map `PlaybookRunResult` back to the existing `Result` output format for backward compatibility:

```java
public Result execute(Map<String, Object> params, ServiceRegistry services) {
    TestExecutionContext ctx;
    try {
        ctx = services.lookup(TestExecutionContext.class);
    } catch (IllegalArgumentException e) {
        return Result.failed("run-playbook requires TestExecutionContext in ServiceRegistry");
    }

    String file = params.containsKey("_subject")
                  ? String.valueOf(params.get("_subject"))
                  : (String) params.get("file");
    if (file == null || file.isBlank()) {
        return Result.failed("run-playbook requires a file path");
    }

    Path playbookPath = ctx.resourceRoot().resolve(file);
    if (!java.nio.file.Files.exists(playbookPath)) {
        return Result.failed("Playbook not found: " + playbookPath);
    }

    @SuppressWarnings("unchecked")
    Map<String, Object> callerVars = params.containsKey("vars")
                                     ? (Map<String, Object>) params.get("vars")
                                     : Map.of();

    var config = new io.casehub.yaml.test.PlaybookRunConfig(false, callerVars, null, null);
    var runner = new io.casehub.yaml.test.PlaybookRunnerCore(
            ctx.pluginRegistry(), ctx.serviceRegistry(), ctx.resourceRoot(), null);

    var runResult = runner.run(playbookPath, config);

    var stepEvents = new java.util.ArrayList<Map<String, Object>>();
    if (runResult.trace() != null) {
        for (var entry : runResult.trace().flatten()) {
            var node = entry.node();
            if (!"playbook".equals(node.type())) {
                stepEvents.add(Map.of(
                        "step", node.index() + 1,
                        "action", node.action() != null ? node.action() : node.type(),
                        "success", node.outcome() == io.casehub.yaml.test.StepOutcome.EXECUTED
                                || node.outcome() == io.casehub.yaml.test.StepOutcome.SIMULATED));
            }
        }
    }

    return Result.of(Map.of(
            "succeeded", runResult.success(),
            "output", runResult.output(),
            "stepCount", stepEvents.size(),
            "duration", runResult.durationMs(),
            "stepEvents", stepEvents,
            "error", runResult.error() != null ? runResult.error() : ""));
}
```

- [ ] **Step 4: Run test to verify backward compatibility**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=RunPlaybookPluginDelegationTest`
Expected: PASS — same output format

- [ ] **Step 5: Run all yaml-step-runtime tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/RunPlaybookPlugin.java \
        yaml-step-runtime/src/test/java/io/casehub/yaml/step/plugin/RunPlaybookPluginDelegationTest.java \
        yaml-step-runtime/src/test/resources/playbooks/
git commit -m "refactor(#708): RunPlaybookPlugin delegates to PlaybookRunnerCore"
```

---

## Batch 4: @McpDomain("playbooks") API surface

The MCP/REST entry point. After this batch, playbooks can be run and validated via REST and MCP.

### Task 6: PlaybookApi interface with @McpDomain + PlaybookRunRequest

**Files:**
- Modify: `yaml-test-core/pom.xml` (add mcp-api dependency)
- Create: `yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookApi.java`
- Create: `yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookRunRequest.java`
- Test: `yaml-test-core/src/test/java/io/casehub/yaml/test/PlaybookApiContractTest.java`

**Interfaces:**
- Consumes: `PlaybookRunResult` (Task 2), `PlaybookValidationResult` (Task 2), `@McpDomain`, `@PlatformMutation`, `@PlatformQuery` (mcp-api)
- Produces: `PlaybookApi` interface with `run(PlaybookRunRequest)` and `validate(String)`. `PlaybookRunRequest(String playbookPath, boolean dryRun, Map<String, Object> vars, String corpusPath, String simulationProfile)`.

- [ ] **Step 1: Add mcp-api dependency to yaml-test-core pom.xml**

Add to `yaml-test-core/pom.xml` `<dependencies>` section:
```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-mcp-api</artifactId>
    <version>${project.version}</version>
</dependency>
```

- [ ] **Step 2: Write contract test**

```java
package io.casehub.yaml.test;

import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class PlaybookApiContractTest {

    @Test
    void runRequestDefaultsNotDryRun() {
        var request = new PlaybookRunRequest("test.yaml", false, Map.of(), null, null);
        assertThat(request.dryRun()).isFalse();
        assertThat(request.playbookPath()).isEqualTo("test.yaml");
    }

    @Test
    void runRequestConvertToConfig() {
        var request = new PlaybookRunRequest("test.yaml", true,
                Map.of("key", "val"), "corpus.yaml", "dev");
        var config = new PlaybookRunConfig(request.dryRun(), request.vars(),
                request.corpusPath(), request.simulationProfile());
        assertThat(config.dryRun()).isTrue();
        assertThat(config.vars()).containsEntry("key", "val");
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=PlaybookApiContractTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: Compilation error — PlaybookRunRequest doesn't exist

- [ ] **Step 4: Implement PlaybookRunRequest and PlaybookApi**

`PlaybookRunRequest.java`:
```java
package io.casehub.yaml.test;

import java.util.Map;

public record PlaybookRunRequest(
        String playbookPath,
        boolean dryRun,
        Map<String, Object> vars,
        String corpusPath,
        String simulationProfile) {

    public PlaybookRunRequest {
        vars = vars != null ? Map.copyOf(vars) : Map.of();
    }
}
```

`PlaybookApi.java`:
```java
package io.casehub.yaml.test;

import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;

@McpDomain("playbooks")
public interface PlaybookApi {

    @PlatformMutation("Run a playbook with optional dry-run simulation")
    PlaybookRunResult run(PlaybookRunRequest request);

    @PlatformQuery("Validate a playbook structure without executing")
    PlaybookValidationResult validate(String playbookPath);
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=PlaybookApiContractTest`
Expected: All 2 tests PASS

- [ ] **Step 6: Full module test**

Run: `mvn --batch-mode test -pl yaml-test-core`
Expected: All tests PASS

- [ ] **Step 7: Commit**

```
git add yaml-test-core/pom.xml \
        yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookApi.java \
        yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookRunRequest.java \
        yaml-test-core/src/test/java/io/casehub/yaml/test/PlaybookApiContractTest.java
git commit -m "feat(#708): add @McpDomain(\"playbooks\") PlaybookApi interface"
```

---

## Batch 5: Full build verification

### Task 7: Cross-module build and integration verification

**Files:**
- No new files — verification only

**Interfaces:**
- Consumes: all previous tasks

- [ ] **Step 1: Full build**

Run: `mvn --batch-mode install -pl yaml-test-core,yaml-step-runtime -am`
Expected: BUILD SUCCESS

- [ ] **Step 2: Run all tests in affected modules**

Run: `mvn --batch-mode test -pl yaml-test-core,yaml-step-runtime`
Expected: All tests PASS

- [ ] **Step 3: Verify no import cycles or missing dependencies**

Run: `mvn --batch-mode dependency:tree -pl yaml-test-core | grep casehub`
Expected: mcp-api appears, no circular deps

- [ ] **Step 4: Commit any final adjustments**

If any fixes were needed, commit them.

## References

- [2026-11-05-playbook-runner-dry-run-design.md] — design spec this plan implements
- [YamlTestExecutor.java] — existing test execution pipeline
- [RunPlaybookPlugin.java] — extraction source for PlaybookRunnerCore
- [YamlTestCli.java] — CLI to extend
- [SimulateBlockParser.java] — simulation config parsing
- [StructuralStepEvaluator.java] — step evaluation with dispatch
- [Walker.java] — step resolution
- [AgentHttpApi.java] — @McpDomain API pattern
- [GitHub #708] — focal issue
- [GitHub #702] — parent epic
