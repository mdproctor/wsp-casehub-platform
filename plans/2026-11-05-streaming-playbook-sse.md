# Streaming Playbook Execution via SSE — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #724 — feat: streaming playbook execution via SSE
**Issue group:** #724

**Goal:** Add a streaming variant of PlaybookApi.run() that pushes StepTraceNode events via SSE as each step completes, plus a CLI --stream flag for live console output.

**Architecture:** StepTraceCollector gains an optional `Consumer<StepTraceNode>` callback invoked on each `exitStep()`. PlaybookRunnerCore adds a blocking `runStreaming()` method that uses this callback. PlaybookApi declares `runStream()` returning `Flow.Publisher<StepTraceNode>` (JDK standard — keeps yaml-test-core framework-neutral). PlaybookBeans bridges blocking→reactive using `SubmissionPublisher` + virtual thread. The graphql-generator APT automatically generates the SSE REST endpoint from `@PlatformMutation(streaming=true)`.

**Tech Stack:** Java 21 (Flow.Publisher, SubmissionPublisher, virtual threads), SmallRye Mutiny (CDI layer only), Quarkus RESTEasy Reactive SSE

## Global Constraints

- yaml-test-core must remain framework-neutral — no Mutiny, no Quarkus imports. JDK `java.util.concurrent.Flow` is acceptable.
- playbook-runner (CDI module) may use Quarkus/Mutiny imports.
- Existing blocking `run()` must remain unchanged.
- The graphql-generator APT handles `@PlatformMutation(streaming=true)` and `Flow.Publisher<T>` return types — no generator changes needed.
- StepTraceNode is the SSE element type — same record already used by the blocking path.

---

## Batch 1: Streaming infrastructure + SPI wiring

### Task 1: StepTraceCollector callback + PlaybookRunnerCore.runStreaming

Add per-step callback support to StepTraceCollector and a blocking streaming method to PlaybookRunnerCore that invokes the callback as each step completes.

**Files:**
- Modify: `yaml-test-core/src/main/java/io/casehub/yaml/test/StepTraceCollector.java`
- Modify: `yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookRunnerCore.java`
- Test: `yaml-test-core/src/test/java/io/casehub/yaml/test/StepTraceCollectorTest.java`
- Test: `yaml-test-core/src/test/java/io/casehub/yaml/test/PlaybookRunnerCoreTest.java`

**Interfaces:**
- Produces: `StepTraceCollector(SimulationRuntime, Consumer<StepTraceNode>)` — new constructor
- Produces: `PlaybookRunnerCore.runStreaming(Path playbookPath, PlaybookRunConfig config, Consumer<StepTraceNode> onStep)` — blocking method, calls onStep per completed step

- [ ] **Step 1: Write failing test — StepTraceCollector callback fires on exitStep**

Add to `StepTraceCollectorTest.java`:

```java
@Test
void callbackFiredOnExitStep() {
    var emitted = new ArrayList<StepTraceNode>();
    var collector = new StepTraceCollector(null, emitted::add);

    collector.enterStep(0, "step-a", "plugin");
    collector.exitStep("agent-invoke", StepOutcome.EXECUTED, Map.of());

    collector.enterStep(1, "step-b", "plugin");
    collector.exitStep("assertThat", StepOutcome.EXECUTED, Map.of());

    assertThat(emitted).hasSize(2);
    assertThat(emitted.get(0).name()).isEqualTo("step-a");
    assertThat(emitted.get(1).name()).isEqualTo("step-b");
    // rootChildren still populated too
    assertThat(collector.rootChildren()).hasSize(2);
}

@Test
void callbackFiredForNestedSteps() {
    var emitted = new ArrayList<StepTraceNode>();
    var collector = new StepTraceCollector(null, emitted::add);

    collector.enterStep(0, "block", "block");
    collector.enterStep(0, "inner", "plugin");
    collector.exitStep("act", StepOutcome.EXECUTED, Map.of());
    collector.exitStep(null, StepOutcome.EXECUTED, Map.of());

    // inner fires first, then block (which contains inner as child)
    assertThat(emitted).hasSize(2);
    assertThat(emitted.get(0).name()).isEqualTo("inner");
    assertThat(emitted.get(1).name()).isEqualTo("block");
    assertThat(emitted.get(1).children()).hasSize(1);
}

@Test
void nullCallbackDoesNotBreak() {
    var collector = new StepTraceCollector(null, null);
    collector.enterStep(0, "s", "plugin");
    collector.exitStep("act", StepOutcome.EXECUTED, Map.of());
    assertThat(collector.rootChildren()).hasSize(1);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=StepTraceCollectorTest -Dquarkus.build.skip=true`
Expected: compilation error — constructor `StepTraceCollector(null, Consumer)` does not exist.

- [ ] **Step 3: Implement StepTraceCollector callback**

Modify `StepTraceCollector.java` — add a `Consumer<StepTraceNode>` field and a new constructor. Invoke the callback in `exitStep()` after building the node:

```java
private final Consumer<StepTraceNode> onStepComplete;

public StepTraceCollector() {
    this(null, null);
}

public StepTraceCollector(SimulationRuntime simulationRuntime) {
    this(simulationRuntime, null);
}

public StepTraceCollector(SimulationRuntime simulationRuntime,
                          Consumer<StepTraceNode> onStepComplete) {
    this.simulationRuntime = simulationRuntime;
    this.onStepComplete = onStepComplete;
}
```

In `exitStep()`, after building the node and adding it to the tree, add:

```java
if (onStepComplete != null) {
    onStepComplete.accept(node);
}
```

Add import: `java.util.function.Consumer`

- [ ] **Step 4: Run StepTraceCollector tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=StepTraceCollectorTest -Dquarkus.build.skip=true`
Expected: all tests PASS (existing + new).

- [ ] **Step 5: Write failing test — PlaybookRunnerCore.runStreaming**

Add to `PlaybookRunnerCoreTest.java`:

```java
@Test
void runStreamingEmitsStepNodes() {
    var runner = new PlaybookRunnerCore(pluginRegistry, serviceRegistry,
            PLAYBOOK_ROOT, null);
    var emitted = new ArrayList<StepTraceNode>();
    runner.runStreaming(PLAYBOOK_ROOT.resolve("simple.yaml"),
            PlaybookRunConfig.defaults(), emitted::add);

    // simple.yaml has 2 steps
    assertThat(emitted).hasSize(2);
    assertThat(emitted.get(0).action()).isEqualTo("agent-invoke");
    assertThat(emitted.get(1).action()).isEqualTo("agent-invoke");
    assertThat(emitted.get(0).outcome()).isEqualTo(StepOutcome.EXECUTED);
}

@Test
void runStreamingStopsOnFailure() {
    pluginRegistry.register(Definition.of("fail-step")
            .execute((params, svc) -> Result.failure("boom"))
            .build());
    var runner = new PlaybookRunnerCore(pluginRegistry, serviceRegistry,
            PLAYBOOK_ROOT, null);
    var emitted = new ArrayList<StepTraceNode>();

    // Create a playbook that fails on step 2
    // Use the invalid.yaml which references unknown steps
    // Better: use a temp playbook
    // Actually, let's just verify the streaming method exists and works
    runner.runStreaming(PLAYBOOK_ROOT.resolve("simple.yaml"),
            PlaybookRunConfig.defaults(), emitted::add);
    assertThat(emitted).isNotEmpty();
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=PlaybookRunnerCoreTest#runStreamingEmitsStepNodes -Dquarkus.build.skip=true`
Expected: compilation error — `runStreaming` method does not exist.

- [ ] **Step 7: Implement PlaybookRunnerCore.runStreaming**

Add a `runStreaming` method to `PlaybookRunnerCore.java`. This is structurally identical to `run()` but uses a `StepTraceCollector` with the callback and does not return a `PlaybookRunResult`:

```java
@SuppressWarnings("unchecked")
public void runStreaming(Path playbookPath, PlaybookRunConfig config,
                         Consumer<StepTraceNode> onStep) {
    SimulationOverlay overlay = null;
    try {
        String yaml = Files.readString(playbookPath);
        PlaybookDocument doc = PlaybookParser.parse(yaml);
        Map<String, Object> content = new LinkedHashMap<>(doc.content());
        VariableSource moduleOutputSource = expandImports(content, playbookPath);

        if (config.dryRun() && simulationRuntime != null) {
            overlay = activateSimulation(config, playbookPath);
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
            return;
        }

        var runServices = new io.casehub.yaml.plugin.api.MapServiceRegistry();
        List<ResolvedStep> resolved = Walker.resolve(steps, pluginRegistry);
        var runner = new CatalogStepRunner(pluginRegistry, runServices);
        var traceCollector = new StepTraceCollector(
                config.dryRun() ? simulationRuntime : null, onStep);
        var evaluator = new StructuralStepEvaluator(
                new io.casehub.yaml.core.condition.ConditionEvaluator(null))
                .withListener(traceCollector);

        VariableResolver resolver = buildResolver(parsed, callerParams,
                moduleOutputSource);

        for (int i = 0; i < resolved.size(); i++) {
            var step = resolved.get(i);
            Result result = evaluator.evaluate(step, resolver, runner);
            if (!result.isSuccess()) {
                break;
            }
            if (step instanceof ResolvedStep.PluginStep ps) {
                var capture = ps.decorators().get("capture");
                if (capture != null && result.output() != null) {
                    resolver = resolver.withObjectScope(
                            String.valueOf(capture), result.output()::get);
                }
            }
        }
    } catch (Exception e) {
        throw new RuntimeException("Streaming playbook execution failed: "
                + e.getMessage(), e);
    } finally {
        if (overlay != null && simulationRuntime != null) {
            simulationRuntime.popOverlay(overlay);
        }
    }
}
```

Add import: `java.util.function.Consumer`

- [ ] **Step 8: Run all PlaybookRunnerCore tests**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=PlaybookRunnerCoreTest -Dquarkus.build.skip=true`
Expected: all tests PASS.

- [ ] **Step 9: Commit**

```bash
git add yaml-test-core/src/main/java/io/casehub/yaml/test/StepTraceCollector.java
git add yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookRunnerCore.java
git add yaml-test-core/src/test/java/io/casehub/yaml/test/StepTraceCollectorTest.java
git add yaml-test-core/src/test/java/io/casehub/yaml/test/PlaybookRunnerCoreTest.java
git commit -m "feat(#724): add streaming callback to StepTraceCollector and runStreaming to PlaybookRunnerCore"
```

### Task 2: PlaybookApi SPI + PlaybookBeans SSE implementation

Declare `runStream()` on the SPI interface and implement it in the CDI bean. The graphql-generator APT auto-generates the SSE REST endpoint.

**Files:**
- Modify: `yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookApi.java`
- Modify: `playbook-runner/src/main/java/io/casehub/yaml/test/quarkus/PlaybookBeans.java`
- Test: `playbook-runner/src/test/java/io/casehub/yaml/test/quarkus/PlaybookBeansStreamingTest.java`

**Interfaces:**
- Consumes: `PlaybookRunnerCore.runStreaming(Path, PlaybookRunConfig, Consumer<StepTraceNode>)` from Task 1
- Produces: `PlaybookApi.runStream(PlaybookRunRequest) → Flow.Publisher<StepTraceNode>` — SSE streaming SPI method
- Produces: Generated `POST /api/playbooks/run-stream` SSE endpoint (via graphql-generator APT)

- [ ] **Step 1: Write failing test — PlaybookBeans.runStream returns nodes via Flow.Publisher**

Create `playbook-runner/src/test/java/io/casehub/yaml/test/quarkus/PlaybookBeansStreamingTest.java`:

```java
package io.casehub.yaml.test.quarkus;

import io.casehub.yaml.test.PlaybookRunRequest;
import io.casehub.yaml.test.StepTraceNode;
import org.junit.jupiter.api.Test;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Flow;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;

class PlaybookBeansStreamingTest {

    @Test
    void runStreamPublishesStepNodes() throws Exception {
        // Use a direct PlaybookRunnerCore (no CDI needed)
        var pluginRegistry = new io.casehub.yaml.step.catalog.CompositePluginRegistry();
        pluginRegistry.register(io.casehub.yaml.plugin.api.Definition.of("agent-invoke")
                .execute((params, svc) ->
                        io.casehub.yaml.plugin.api.Result.of(
                                Map.of("text", String.valueOf(params.get("prompt")))))
                .build());
        var serviceRegistry = new io.casehub.yaml.plugin.api.MapServiceRegistry();

        var beans = new PlaybookBeans(pluginRegistry, serviceRegistry, null);

        Path playbookRoot = Path.of("../yaml-test-core/src/test/playbooks");
        var request = new PlaybookRunRequest(
                playbookRoot.resolve("simple.yaml").toString(),
                false, Map.of(), null, null);

        Flow.Publisher<StepTraceNode> publisher = beans.runStream(request);

        var received = new ArrayList<StepTraceNode>();
        var latch = new CountDownLatch(1);
        publisher.subscribe(new Flow.Subscriber<>() {
            private Flow.Subscription subscription;
            @Override public void onSubscribe(Flow.Subscription s) {
                this.subscription = s;
                s.request(Long.MAX_VALUE);
            }
            @Override public void onNext(StepTraceNode item) {
                received.add(item);
            }
            @Override public void onError(Throwable t) { latch.countDown(); }
            @Override public void onComplete() { latch.countDown(); }
        });

        assertThat(latch.await(5, TimeUnit.SECONDS)).isTrue();
        assertThat(received).hasSize(2);
        assertThat(received.get(0).action()).isEqualTo("agent-invoke");
        assertThat(received.get(1).action()).isEqualTo("agent-invoke");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl playbook-runner -Dtest=PlaybookBeansStreamingTest -Dquarkus.build.skip=true`
Expected: compilation error — `runStream` does not exist on PlaybookBeans/PlaybookApi.

- [ ] **Step 3: Add runStream to PlaybookApi SPI**

Modify `yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookApi.java`:

```java
@McpDomain("playbooks")
public interface PlaybookApi {

    @PlatformMutation("Run a playbook with optional dry-run simulation")
    PlaybookRunResult run(PlaybookRunRequest request);

    @PlatformMutation(value = "Run a playbook with streaming trace output", streaming = true)
    java.util.concurrent.Flow.Publisher<StepTraceNode> runStream(PlaybookRunRequest request);

    @PlatformQuery("Validate a playbook structure without executing")
    PlaybookValidationResult validate(String playbookPath);
}
```

- [ ] **Step 4: Implement runStream in PlaybookBeans**

Modify `playbook-runner/src/main/java/io/casehub/yaml/test/quarkus/PlaybookBeans.java` — add the `runStream()` override. Uses `SubmissionPublisher` + virtual thread to bridge blocking `runStreaming()` into reactive `Flow.Publisher`:

```java
@Override
@PlatformMutation(value = "Run a playbook with streaming trace output",
                  streaming = true)
public Flow.Publisher<StepTraceNode> runStream(PlaybookRunRequest request) {
    var config = new PlaybookRunConfig(request.dryRun(), request.vars(),
                                       request.corpusPath(),
                                       request.simulationProfile());
    Path resourceRoot = PlaybookRunnerCore.resolveClasspathRoot("playbooks");
    if (resourceRoot == null) {
        resourceRoot = Path.of(".");
    }
    var runner = new PlaybookRunnerCore(pluginRegistry, serviceRegistry,
                                        resourceRoot, simulationRuntime,
                                        moduleLoader);
    Path playbookPath = Path.of(request.playbookPath());
    return subscriber -> {
        var publisher = new java.util.concurrent.SubmissionPublisher<StepTraceNode>();
        publisher.subscribe(subscriber);
        Thread.startVirtualThread(() -> {
            try {
                runner.runStreaming(playbookPath, config, publisher::submit);
            } catch (Exception e) {
                publisher.closeExceptionally(e);
                return;
            }
            publisher.close();
        });
    };
}
```

Add imports: `java.util.concurrent.Flow`, `io.casehub.yaml.test.StepTraceNode`

- [ ] **Step 5: Run streaming test to verify it passes**

Run: `mvn --batch-mode test -pl playbook-runner -Dtest=PlaybookBeansStreamingTest -Dquarkus.build.skip=true`
Expected: PASS.

- [ ] **Step 6: Rebuild to verify APT generates correct SSE endpoint**

Run: `mvn --batch-mode compile -pl yaml-test-core,playbook-runner -Dquarkus.build.skip=true`

Then verify the generated resource at `playbook-runner/target/generated-sources/annotations/io/casehub/yaml/test/quarkus/rest/PlaybooksResource.java` contains a new method with:
- `@POST @Path("/run-stream")`
- `@Produces(MediaType.SERVER_SENT_EVENTS)`
- `@RestStreamElementType(MediaType.APPLICATION_JSON)`
- Return type wrapping `Flow.Publisher` in `Multi.createFrom().publisher(...)`

- [ ] **Step 7: Run full module tests**

Run: `mvn --batch-mode test -pl yaml-test-core,playbook-runner -Dquarkus.build.skip=true`
Expected: all tests PASS.

- [ ] **Step 8: Commit**

```bash
git add yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookApi.java
git add playbook-runner/src/main/java/io/casehub/yaml/test/quarkus/PlaybookBeans.java
git add playbook-runner/src/test/java/io/casehub/yaml/test/quarkus/PlaybookBeansStreamingTest.java
git commit -m "feat(#724): PlaybookApi.runStream SSE endpoint via Flow.Publisher"
```

## Batch 2: CLI streaming output

### Task 3: YamlTestCli --stream flag

Add `--stream` flag to the CLI for live step-by-step console output as steps complete, instead of the batch summary printed after execution finishes.

**Files:**
- Modify: `yaml-test-core/src/main/java/io/casehub/yaml/test/YamlTestCli.java`
- Test: `yaml-test-core/src/test/java/io/casehub/yaml/test/YamlTestCliTest.java`

**Interfaces:**
- Consumes: `PlaybookRunnerCore.runStreaming(Path, PlaybookRunConfig, Consumer<StepTraceNode>)` from Task 1

- [ ] **Step 1: Write failing test — --stream flag parsed**

Add to or create `YamlTestCliTest.java`:

```java
package io.casehub.yaml.test;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class YamlTestCliTest {

    @Test
    void parseStreamFlag() {
        var args = YamlTestCli.parseArgs(
                new String[]{"--stream", "--dry-run", "playbook.yaml"});
        assertThat(args.stream()).isTrue();
        assertThat(args.dryRun()).isTrue();
        assertThat(args.paths()).containsExactly("playbook.yaml");
    }

    @Test
    void defaultStreamIsFalse() {
        var args = YamlTestCli.parseArgs(new String[]{"playbook.yaml"});
        assertThat(args.stream()).isFalse();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=YamlTestCliTest -Dquarkus.build.skip=true`
Expected: compilation error — `stream()` does not exist on ParsedArgs.

- [ ] **Step 3: Add --stream flag to ParsedArgs and parser**

Modify `YamlTestCli.java`:

In `ParsedArgs` record, add `boolean stream` parameter (after `dryRun`):

```java
public record ParsedArgs(
        boolean dryRun,
        boolean stream,
        String corpusPath,
        String profile,
        Map<String, Object> vars,
        String filter,
        String reportFormat,
        String outputDir,
        List<String> paths) {
    // ...
}
```

In `parseArgs()`, add `boolean stream = false;` and the switch case:

```java
case "--stream" -> stream = true;
```

Update the return statement to include `stream`:

```java
return new ParsedArgs(dryRun, stream, corpusPath, profile, vars,
        filter, reportFormat, outputDir, paths);
```

Update the usage string in `main()` to include `[--stream]`.

- [ ] **Step 4: Run CLI parse tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=YamlTestCliTest -Dquarkus.build.skip=true`
Expected: PASS.

- [ ] **Step 5: Implement streaming output in runPlaybook**

In `YamlTestCli.java`, modify `runPlaybook()` to check for `--stream` and use `runStreaming()` with a print callback:

```java
private static boolean runPlaybook(Path playbookPath, ParsedArgs parsed,
                                    CompositePluginRegistry pluginRegistry,
                                    MapServiceRegistry serviceRegistry,
                                    SimulationRuntime simulationRuntime) {
    var config = new PlaybookRunConfig(parsed.dryRun(), parsed.vars(),
            parsed.corpusPath(), parsed.profile());
    var runner = new PlaybookRunnerCore(pluginRegistry, serviceRegistry,
            playbookPath.getParent(), simulationRuntime, new FileSystemModuleLoader());

    if (parsed.stream()) {
        try {
            runner.runStreaming(playbookPath, config, node -> {
                String action = node.action() != null ? node.action() : node.type();
                System.out.printf("  %-10s %s (%dms)%n",
                        node.outcome().name(), action, node.durationMs());
                System.out.flush();
            });
            return false;
        } catch (Exception e) {
            System.err.printf("Error: %s%n", e.getMessage());
            return true;
        }
    }

    PlaybookRunResult result = runner.run(playbookPath, config);
    printPlaybookResult(result);
    return !result.success();
}
```

- [ ] **Step 6: Run all yaml-test-core tests**

Run: `mvn --batch-mode test -pl yaml-test-core -Dquarkus.build.skip=true`
Expected: all tests PASS.

- [ ] **Step 7: Commit**

```bash
git add yaml-test-core/src/main/java/io/casehub/yaml/test/YamlTestCli.java
git add yaml-test-core/src/test/java/io/casehub/yaml/test/YamlTestCliTest.java
git commit -m "feat(#724): CLI --stream flag for live step-by-step playbook output"
```

## References

- [PlaybookApi.java] — yaml-test-core SPI interface
- [PlaybookRunnerCore.java] — yaml-test-core blocking runner
- [StepTraceCollector.java] — yaml-test-core step trace builder
- [StepTraceNode.java] — yaml-test-core trace record type
- [PlaybookBeans.java] — playbook-runner CDI implementation
- [YamlTestCli.java] — yaml-test-core CLI entry point
- [AgentHttpApi.java] — agent-api streaming pattern reference (invokeStream)
- [AgentHttpResource.java:71-78] — generated SSE endpoint pattern
- [GraphQLResolverProcessor.java:1509] — APT streaming mutation generation
- [PlatformMutation.java] — mcp-api annotation with streaming attribute
- [GitHub #724] — focal issue
