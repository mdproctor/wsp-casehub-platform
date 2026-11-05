# Playbook Runner with Dry-Run Mode

**Issue:** casehubio/platform#708
**Branch:** issue-708-playbook-dry-run-mode
**Date:** 2026-11-05
**Epic:** #702 (YAML Playbook Polish)

## Problem

Playbook authors can test with `.test.yaml` files, but there's no way to run a production playbook outside the test framework. Three execution paths exist (YamlTestExecutor, RunPlaybookPlugin, CompiledStateMachine), but none is exposed as a standalone runner. No path produces a step-level trace. The CLI (`YamlTestCli`) doesn't wire `SimulationRuntime`, so `simulate:` blocks are silently ignored.

A playbook runner — with an optional dry-run mode that forces simulation — lets authors validate playbooks against simulation corpora without writing test files, run playbooks in tutorials, and validate before deployment.

## Design

### 1. PlaybookRunnerCore (yaml-test-core)

Framework-neutral POJO extracted from `RunPlaybookPlugin`'s execution logic. Lives in `yaml-test-core` alongside `YamlTestExecutor` — both share the same parse → resolve → evaluate → trace pipeline.

```java
package io.casehub.yaml.test;

public final class PlaybookRunnerCore {

    private final PluginRegistry pluginRegistry;
    private final ServiceRegistry serviceRegistry;
    private final Path resourceRoot;
    private final SimulationRuntime simulationRuntime;  // nullable

    public PlaybookRunnerCore(PluginRegistry pluginRegistry,
                              ServiceRegistry serviceRegistry,
                              Path resourceRoot,
                              SimulationRuntime simulationRuntime) { ... }

    public PlaybookRunResult run(Path playbookPath, PlaybookRunConfig config) { ... }

    public PlaybookValidationResult validate(Path playbookPath) { ... }
}
```

**`run()` pipeline:**

1. Parse playbook via `PlaybookParser.parse()` → `PlaybookDocument`
2. Extract vars/params via `PlaybookVariableParser.parse()`
3. Validate caller params via `ParameterValidator`
4. If `config.dryRun()` and `simulationRuntime != null`:
   - Load simulation config from convention discovery (`simulation.yaml` in directory hierarchy) or `config.corpusPath()` override
   - Call `simulationRuntime.pushOverlay(config, corpus)`
   - If `config.simulationProfile()` set, call `simulationRuntime.pushProfile(name)` on top
5. Resolve steps via `Walker.resolve(steps, pluginRegistry)`
6. Create `TracingStepRunner` wrapping `CatalogStepRunner` (see §2)
7. Evaluate via `StructuralStepEvaluator`
8. Pop simulation overlay in finally block
9. Build `PlaybookRunResult` from trace and outcome

**`validate()` pipeline:**

1. Parse playbook via `PlaybookParser.parse()`
2. Validate params schema (if declared)
3. Resolve steps via `Walker.resolve()` — catches structural errors (unknown keys, duplicate names, missing companions, depth overflow)
4. Return `PlaybookValidationResult(valid, errors, frontMatter)`

### 2. StepTraceNode — shared step trace model

New types in `yaml-test-core` composable by both `TestResult` and `PlaybookRunResult`:

```java
package io.casehub.yaml.test;

public record StepTraceNode(
    int index,
    String name,
    String type,
    String action,
    StepOutcome outcome,
    long durationMs,
    Map<String, Object> detail,
    List<StepTraceNode> children
) {
    public static StepTraceNode leaf(int index, String name, String type,
                                      String action, StepOutcome outcome,
                                      long durationMs, Map<String, Object> detail) {
        return new StepTraceNode(index, name, type, action, outcome,
                                 durationMs, detail, List.of());
    }
}

public enum StepOutcome {
    EXECUTED,
    SKIPPED,
    SIMULATED,
    FAILED,
    ERROR
}
```

**`type` values:** `"plugin"`, `"invoke"`, `"block"`, `"if-else"`, `"match"`, `"parallel"`, `"try-catch-finally"`, `"select"`, `"barrier"`, `"quorum"`, `"race"`, `"control"`, `"fused-pipeline"` — one per `ResolvedStep` variant.

**`detail` map by type:**

| Type | Detail keys |
|------|-------------|
| `plugin` / `invoke` | `strategy` (if simulated), `corpusKey` |
| `if-else` | `condition`, `evaluated` (boolean), `branch` ("then" / "else") |
| `match` | `scrutinee`, `matchedCase` (index or "default"), `pattern` |
| `parallel` | `branchCount`, `advanceAfter` |
| `try-catch-finally` | `caughtError` (if catch branch taken) |
| `block` with `when:` | `condition`, `evaluated` (boolean) |

### 3. TracingStepRunner

A `StepRunner` decorator that wraps `CatalogStepRunner` and builds `StepTraceNode` entries as steps execute. `StructuralStepEvaluator` already dispatches by `ResolvedStep` variant — the trace needs to be built at the evaluator level, not the runner level, because structural steps (if/else, parallel) are handled by the evaluator.

Two approaches to integrate tracing:

**TracingStructuralStepEvaluator** — a subclass or wrapper of `StructuralStepEvaluator` that intercepts `dispatchStep()` calls, records timing and outcome, and builds the `StepTraceNode` tree. Since `dispatchStep()` is private, this works via a `StepExecutionListener` callback:

```java
@FunctionalInterface
public interface StepExecutionListener {
    void onStepComplete(ResolvedStep step, Result result, long durationMs,
                        Map<String, Object> detail, List<StepTraceNode> children);
}
```

`StructuralStepEvaluator` gains an optional listener (null by default — zero overhead for existing callers). When set, it fires after each step dispatch with the step's result and structural detail. The listener builds the `StepTraceNode` tree.

**Simulation detection:** When a plugin step executes and `SimulationRuntime.strategyFor(qualifiedName)` returns a strategy (i.e., the call was intercepted by simulation), the outcome is `SIMULATED` and `detail` includes the strategy name. The `@SimulationEligible` decorator infrastructure already handles this transparently — the runner sees a successful result regardless. Detection is via `SimulationRuntime`'s `InvocationJournal`: if a journal entry was recorded for this invocation, it was simulated.

### 4. Result types

```java
public record PlaybookRunResult(
    boolean success,
    String playbookName,
    String playbookPath,
    long durationMs,
    StepTraceNode trace,
    List<CapturedEvent> events,
    Map<String, Object> output,
    String error
) {}

public record PlaybookRunConfig(
    boolean dryRun,
    Map<String, Object> vars,
    String corpusPath,
    String simulationProfile
) {
    public static PlaybookRunConfig defaults() {
        return new PlaybookRunConfig(false, Map.of(), null, null);
    }

    public static PlaybookRunConfig dryRun() {
        return new PlaybookRunConfig(true, Map.of(), null, null);
    }
}

public record PlaybookValidationResult(
    boolean valid,
    List<String> errors,
    PlaybookFrontMatter frontMatter
) {}
```

### 5. @McpDomain("playbooks") — PlaybookApi

SPI interface in `yaml-test-core` (package `io.casehub.yaml.test.api`):

```java
@McpDomain("playbooks")
public interface PlaybookApi {

    @PlatformMutation("Run a playbook with optional dry-run simulation")
    PlaybookRunResult run(PlaybookRunRequest request);

    @PlatformQuery("Validate a playbook structure without executing")
    PlaybookValidationResult validate(String playbookPath);
}
```

```java
public record PlaybookRunRequest(
    String playbookPath,
    boolean dryRun,
    Map<String, Object> vars,
    String corpusPath,
    String simulationProfile
) {}
```

CDI implementation in a new `playbook-runner` module (or added to an existing Quarkus wiring module). The implementation delegates to `PlaybookRunnerCore`, with `SimulationRuntime` injected via CDI.

REST + MCP endpoints generated by `graphql-generator` APT from the `@McpDomain` annotations — no hand-written REST code.

### 6. CLI — YamlTestCli extensions

New flags on `YamlTestCli`:

```
casehub-test [--dry-run] [--corpus <path>] [--profile <name>]
             [--filter <pattern>] [--report junit-xml] [--output <dir>]
             [--var key=value]... <path>...
```

| Flag | Effect |
|------|--------|
| `--dry-run` | Forces simulation on for all SPI calls |
| `--corpus <path>` | Override/augment simulation corpus from file |
| `--profile <name>` | Use a named simulation profile |
| `--var key=value` | Pass variables to the playbook |

**Mode detection:** If `<path>` resolves to `.test.yaml` files → test mode (existing `YamlTestExecutor` pipeline). If `<path>` resolves to `.yaml` files (not `.test.yaml`) → playbook mode (`PlaybookRunnerCore` pipeline).

**SimulationRuntime bootstrap (CLI):** The CLI constructs a standalone `SimulationRuntime` with `InMemorySimulationCorpus`. If `--corpus` is provided, loads via `SimulateBlockParser.parse()` or `YamlSimulationConfig` (format auto-detected). If `--dry-run` without `--corpus`, discovers `simulation.yaml` from the playbook's directory hierarchy.

**Fixes existing gap:** The CLI now wires `SimulationRuntime` into `YamlTestExecutor` too, fixing the silent `simulate:` block ignore.

**Output format (playbook mode):**

```
Run: risk-assessment.yaml
  1  SIMULATED  agent-invoke "Assess risk" (key-lookup, 2ms)
  2  EXECUTED   assertThat ${result.text} contains 'equities' (1ms)
  3  SIMULATED  rest-call /api/submit (key-lookup, 1ms)

3/3 steps succeeded (4ms)
Events: capacity.pressure (1), risk.assessed (1)
```

For `--report junit-xml`, playbook results are rendered using the existing `TestReport.toJunitXml()` by mapping `PlaybookRunResult` → `TestResult`.

### 7. RunPlaybookPlugin delegation

`RunPlaybookPlugin` is refactored to delegate to `PlaybookRunnerCore`:

```java
public Result execute(Map<String, Object> params, ServiceRegistry services) {
    // ... parse file, vars as before ...
    var config = new PlaybookRunConfig(false, callerVars, null, null);
    var runner = new PlaybookRunnerCore(ctx.pluginRegistry(), ctx.serviceRegistry(),
                                        ctx.resourceRoot(), null);
    PlaybookRunResult result = runner.run(playbookPath, config);
    return result.success()
        ? Result.of(Map.of("succeeded", true, "output", result.output(),
                           "stepCount", countSteps(result.trace()),
                           "duration", result.durationMs(),
                           "stepEvents", flattenTrace(result.trace())))
        : Result.failed(result.error());
}
```

The `stepEvents` output is preserved for backward compatibility by flattening the trace tree.

## Module Impact

| Module | Changes |
|--------|---------|
| `yaml-test-core` | PlaybookRunnerCore, StepTraceNode, StepOutcome, PlaybookRunResult, PlaybookRunConfig, PlaybookValidationResult, PlaybookRunRequest, PlaybookApi (@McpDomain), TracingStepRunner, StepExecutionListener |
| `yaml-step-runtime` | StructuralStepEvaluator gains optional StepExecutionListener. RunPlaybookPlugin refactored to delegate to PlaybookRunnerCore |
| `yaml-test-core` (CLI) | YamlTestCli extended with --dry-run, --corpus, --profile, --var flags. SimulationRuntime bootstrap for standalone use |

## Testing

- Unit tests for PlaybookRunnerCore: run a simple playbook, verify trace structure
- Unit tests for StepTraceNode: verify tree flattening for CLI output
- Dry-run tests: run playbook with dryRun=true, verify all plugin steps report SIMULATED outcome
- Structural step trace tests: if/else traces both branches, parallel traces all branches, match traces selected case
- CLI integration test: invoke YamlTestCli.main with --dry-run and a playbook, verify output format
- Validation tests: invalid playbook (unknown step, missing params) produces errors
- Existing test regression: verify YamlTestExecutor still works unchanged (listener defaults to null)

## Non-goals

- Streaming execution output (future — would use `@PlatformMutation(streaming=true)`)
- Playbook listing or compilation via MCP (separate concerns, additive later)
- CDI-integrated playbook execution (CompiledStateMachine handles that path)
- MCP debugger integration (future — separate design)

## References

- `YamlTestExecutor.java` — existing test execution pipeline, simulation overlay pattern
- `RunPlaybookPlugin.java` — existing inline playbook runner, extraction source
- `YamlTestCli.java` — existing CLI, SimulationRuntime gap
- `SimulateBlockParser.java` — simulation config parsing from YAML
- `SimulationRuntime.java` — overlay stack mechanism
- `StructuralStepEvaluator.java` — step dispatch and structural evaluation
- `Walker.java` — step resolution and structural validation
- `AgentHttpApi.java` — @McpDomain API pattern
- `TemporalDriverService.java` — @McpDomain CDI implementation pattern
- `PlaybookParser.java` — playbook document parsing
- casehubio/platform#702 — parent epic
- casehubio/platform#683 — test framework infrastructure (predecessor)
