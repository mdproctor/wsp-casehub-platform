# Declarative Playbook Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #683 — Epic: Declarative playbook testing and simulation alignment
**Issue group:** #684, #685, #686, #687, #688

**Goal:** Build a YAML-native test framework where `.test.yaml` files are
playbooks with simulation context and behavioural assertions, executable
via JUnit Platform TestEngine and standalone CLI.

**Architecture:** Test files are standard playbooks extended with a
`simulate:` top-level block. The test runner pushes simulation overlays
onto `SimulationRuntime`, executes via the Walker path (not SWF
compiler), and reports pass/fail from assertion step outcomes. New step
types (`assertThat`, `run-playbook`, `emit-event`, `verify-simulation`,
`agent-invoke`) are `@Plugin` records registered in `PluginRegistry`.

**Tech Stack:** JUnit Platform TestEngine API, MVEL3 expressions,
SimulationRuntime overlay stack, Walker + CatalogStepRunner,
CloudEventFixtureBuilder, Jackson YAML.

## Global Constraints

- `yaml-test-core` must be framework-neutral — no CDI, no Spring, no
  Quarkus imports. Pure Java + j.u.c only.
- `yaml-test` depends on Quarkus test framework + JUnit Platform Engine
  API.
- All new step types are `@Plugin` records in `yaml-step-runtime` (not
  in the test modules — they are usable in non-test playbooks too).
- Walker enhancements (sibling absorption, scalar-or-map polymorphism)
  are general-purpose — not test-specific.
- Thread safety via `java.util.concurrent` — never `synchronized`.
- `capture:` is a decorator key added to `StepKeywords.DECORATOR_KEYS`.
- `events` is a reserved capture name.

---

## Batch 1: Walker Enhancements + Core Step Types

### Task 1: Walker sibling-absorption and scalar-or-map polymorphism

**Files:**
- Modify: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Plugin.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepKeywords.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/WalkerSiblingAbsorptionTest.java`

**Interfaces:**
- Produces: `@Plugin(absorbSiblings = true)` annotation attribute
- Produces: `StepKeywords.DECORATOR_KEYS` includes `"capture"`
- Produces: Walker resolves scalar plugin values as `_subject` param
- Produces: Walker collects sibling keys for absorbing plugins

- [ ] **Step 1: Write failing test for sibling absorption**

```java
@Test
void siblingAbsorbingPluginCollectsSiblingKeys() {
    var registry = new CompositePluginRegistry();
    // Register a mock plugin with absorbSiblings = true
    registry.register(Definition.builder("test-absorb")
            .action((params, services) -> Result.of(params))
            .absorbSiblings(true)
            .build());

    var step = Map.of(
        "test-absorb", "subject-value",
        "key1", "value1",
        "key2", "value2"
    );

    var resolved = Walker.resolve(List.of(step), registry);
    assertThat(resolved).hasSize(1);
    var params = ((PluginStep) resolved.get(0)).params();
    assertThat(params.get("_subject")).isEqualTo("subject-value");
    assertThat(params.get("key1")).isEqualTo("value1");
    assertThat(params.get("key2")).isEqualTo("value2");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=WalkerSiblingAbsorptionTest#siblingAbsorbingPluginCollectsSiblingKeys`
Expected: FAIL — `absorbSiblings` attribute doesn't exist yet

- [ ] **Step 3: Add `absorbSiblings` to `@Plugin` annotation**

Use `ide_edit_member` to add `boolean absorbSiblings() default false;`
to `@Plugin` annotation in `yaml-plugin-api`.

Add `absorbSiblings` field to `Definition` record + Builder:
`private boolean absorbSiblings = false;`

- [ ] **Step 4: Add `capture` to `StepKeywords.DECORATOR_KEYS`**

Use `ide_edit_member` to add `"capture"` to the `DECORATOR_KEYS` set
in `StepKeywords.java`.

- [ ] **Step 5: Implement sibling absorption in Walker**

In `Walker.resolve()`, when a plugin is matched and
`definition.absorbSiblings()` is true:
- Extract the scalar value as `_subject` param
- Collect all remaining non-reserved, non-structural, non-decorator
  keys as plugin params
- Build `PluginStep` with the combined params map

Also implement scalar-or-map polymorphism: when a plugin key has a
scalar value (not a Map), pass it as `_subject`. When it has a Map
value, use the Map as params directly.

- [ ] **Step 6: Write test for scalar-or-map polymorphism**

```java
@Test
void scalarValueBecomesSubjectParam() {
    var registry = new CompositePluginRegistry();
    registry.register(Definition.builder("run-playbook")
            .action((params, services) -> Result.of(params))
            .build());

    var step = Map.of("run-playbook", "examples/02.yaml");
    var resolved = Walker.resolve(List.of(step), registry);
    var params = ((PluginStep) resolved.get(0)).params();
    assertThat(params.get("_subject")).isEqualTo("examples/02.yaml");
}
```

- [ ] **Step 7: Run all Walker tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=WalkerSiblingAbsorptionTest`
Expected: ALL PASS

- [ ] **Step 8: Write test for capture decorator extraction**

```java
@Test
void captureExtractedAsDecorator() {
    var registry = new CompositePluginRegistry();
    registry.register(Definition.builder("agent-invoke")
            .action((params, services) -> Result.of(params))
            .build());

    var step = Map.of(
        "agent-invoke", Map.of("prompt", "hello"),
        "capture", "result"
    );

    var resolved = Walker.resolve(List.of(step), registry);
    assertThat(resolved).hasSize(1);
    // capture should be extracted as a decorator, not a plugin param
    var pluginStep = (PluginStep) resolved.get(0);
    assertThat(pluginStep.params()).doesNotContainKey("capture");
    assertThat(pluginStep.decorators().get("capture")).isEqualTo("result");
}
```

- [ ] **Step 9: Run test, verify pass**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=WalkerSiblingAbsorptionTest`
Expected: ALL PASS

- [ ] **Step 10: Commit**

```bash
git add yaml-plugin-api/ yaml-step-runtime/
git commit -m "feat(#685): Walker sibling absorption, scalar-or-map polymorphism, capture decorator

Add absorbSiblings attribute to @Plugin for sibling-key collection.
Add capture to StepKeywords.DECORATOR_KEYS for output binding.
Walker resolves scalar plugin values as _subject param.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: assertThat @Plugin with matcher-based assertions

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/AssertThatPlugin.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/Matcher.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/MatcherRegistry.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/plugin/AssertThatPluginTest.java`

**Interfaces:**
- Consumes: Walker sibling-absorption from Task 1
- Consumes: `ExpressionEngineRegistry` for deferred subject resolution
- Produces: `AssertThatPlugin` @Plugin(absorbSiblings = true)
- Produces: `Matcher` functional interface: `MatchResult apply(Object subject, Object expected)`
- Produces: `MatcherRegistry.resolve(String name)` → `Optional<Matcher>`
- Produces: `MatchResult` record: `boolean passed, String description`

- [ ] **Step 1: Write failing test for single-matcher assertion**

```java
@Test
void containsMatcherPassesWhenSubjectContainsExpected() {
    var plugin = new AssertThatPlugin();
    var params = Map.of(
        "_subject", "Moderate risk: 60% equities",
        "contains", "equities"
    );

    var result = plugin.run(params, mockEngineRegistry());
    assertThat(result.isSuccess()).isTrue();
}

@Test
void containsMatcherFailsWithStructuredMessage() {
    var plugin = new AssertThatPlugin();
    var params = Map.of(
        "_subject", "The portfolio is balanced.",
        "contains", "equities"
    );

    var result = plugin.run(params, mockEngineRegistry());
    assertThat(result.isSuccess()).isFalse();
    assertThat(result.message()).contains("contains");
    assertThat(result.message()).contains("equities");
    assertThat(result.message()).contains("The portfolio is balanced.");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=AssertThatPluginTest`
Expected: FAIL — class doesn't exist

- [ ] **Step 3: Implement Matcher interface and built-in matchers**

```java
@FunctionalInterface
public interface Matcher {
    MatchResult apply(Object subject, Object expected);
}

public record MatchResult(boolean passed, String description) {
    public static MatchResult pass() { return new MatchResult(true, null); }
    public static MatchResult fail(String desc) { return new MatchResult(false, desc); }
}
```

`MatcherRegistry` — static registry of built-in matchers:
- `contains` — String.contains or Collection.contains
- `equals` — Objects.equals
- `matches` — Pattern.matches
- `hasSize` — Collection.size() or String.length()
- `startsWith` / `endsWith` — String prefix/suffix
- `greaterThan` / `greaterThanOrEqual` / `lessThan` — Comparable
- `not-null` / `not-empty` / `empty` — null/empty checks

- [ ] **Step 4: Implement AssertThatPlugin**

```java
@Plugin(value = "assertThat", description = "Behavioural assertion with matchers",
        absorbSiblings = true)
public class AssertThatPlugin {

    private static final Set<String> RESERVED = Set.of("_subject", "message");

    @Execute
    public Result run(Map<String, Object> params,
                      ExpressionEngineRegistry engines) {
        Object subject = resolveSubject(params.get("_subject"), engines);
        String message = (String) params.get("message");

        List<MatchResult> failures = new ArrayList<>();
        for (var entry : params.entrySet()) {
            if (RESERVED.contains(entry.getKey())) continue;
            var matcher = MatcherRegistry.resolve(entry.getKey());
            if (matcher.isEmpty()) continue;
            var result = matcher.get().apply(subject, entry.getValue());
            if (!result.passed()) failures.add(result);
        }

        if (failures.isEmpty()) return Result.of(Map.of("passed", true));

        var sb = new StringBuilder();
        sb.append("Subject: ").append(params.get("_subject")).append("\n");
        sb.append("Actual: ").append(formatValue(subject)).append("\n");
        sb.append("Failed:\n");
        for (var f : failures) sb.append("  ").append(f.description()).append("\n");
        if (message != null) sb.append(message);

        return Result.failed(sb.toString());
    }
}
```

- [ ] **Step 5: Write tests for multiple matchers and all matcher types**

Test all 12 matchers (contains, equals, matches, hasSize, startsWith,
endsWith, greaterThan, greaterThanOrEqual, lessThan, not-null,
not-empty, empty). Test multiple matchers on same subject — all
failures reported.

- [ ] **Step 6: Write test for two-phase subject resolution**

```java
@Test
void deferredSubjectResolvedViaExpressionEngine() {
    var plugin = new AssertThatPlugin();
    // Subject still has ${...} wrapper — deferred prefix
    var params = Map.of(
        "_subject", "${events.last('capacity.pressure')}",
        "not-null", true
    );

    var mockCapture = new EventCapture();
    mockCapture.addEvent(buildCloudEvent("capacity.pressure", Map.of("p", 0.9)));

    var engines = mockEngineRegistryWithContext(Map.of("events", mockCapture));
    var result = plugin.run(params, engines);
    assertThat(result.isSuccess()).isTrue();
}
```

- [ ] **Step 7: Run all tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=AssertThatPluginTest`
Expected: ALL PASS

- [ ] **Step 8: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#685): assertThat @Plugin with matcher-based behavioural assertions

Subject-first assertions with 12 built-in matchers. Multiple matchers
per assertion, all failures reported. Two-phase subject resolution
for deferred-prefix event queries.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 3: emit-event and agent-invoke @Plugin step types

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/EmitEventPlugin.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/AgentInvokePlugin.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/plugin/EmitEventPluginTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/plugin/AgentInvokePluginTest.java`

**Interfaces:**
- Consumes: `CloudEventFixtureBuilder.fromMap()` from event-simulation-core
- Consumes: `AgentProvider` SPI from agent-api
- Consumes: Walker sibling-absorption from Task 1 (emit-event uses `data:` sibling)
- Produces: `EmitEventPlugin` @Plugin(absorbSiblings = true)
- Produces: `AgentInvokePlugin` @Plugin with `prompt`, `pool` fields

- [ ] **Step 1: Write failing test for emit-event with scalar type**

```java
@Test
void emitEventCreatesCloudEventFromTypeAndData() {
    var capture = new EventCapture();
    var plugin = new EmitEventPlugin();
    var params = Map.of(
        "_subject", "capacity.pressure",
        "data", Map.of("actorId", "agent-001", "pressure", 0.92)
    );

    var result = plugin.run(params, capture);
    assertThat(result.isSuccess()).isTrue();
    assertThat(capture.count("capacity.pressure")).isEqualTo(1);
    var event = capture.last("capacity.pressure");
    assertThat(event.data().get("actorId")).isEqualTo("agent-001");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=EmitEventPluginTest`
Expected: FAIL

- [ ] **Step 3: Implement EmitEventPlugin**

```java
@Plugin(value = "emit-event", description = "Fires a CloudEvent",
        absorbSiblings = true)
public class EmitEventPlugin {

    @Execute
    public Result run(Map<String, Object> params, EventCapture capture) {
        String type;
        Map<String, Object> eventMap;

        Object subject = params.get("_subject");
        if (subject instanceof String) {
            type = (String) subject;
            eventMap = new HashMap<>();
            eventMap.put("type", type);
            eventMap.put("source", params.getOrDefault("source", "/test"));
            if (params.containsKey("data")) {
                eventMap.put("data", params.get("data"));
            }
        } else if (subject instanceof Map) {
            eventMap = new HashMap<>((Map<String, Object>) subject);
        } else {
            return Result.failed("emit-event requires type string or event map");
        }

        var event = CloudEventFixtureBuilder.fromMap(eventMap);
        capture.addEvent(event);
        return Result.of(Map.of("type", event.getType()));
    }
}
```

- [ ] **Step 4: Write failing test for agent-invoke**

```java
@Test
void agentInvokeWrapsSessionOpenQueryClose() {
    var mockProvider = new MockAgentProvider("test response");
    var plugin = new AgentInvokePlugin();
    var params = Map.of("prompt", "What's my risk profile?");

    var result = plugin.run(params, mockProvider);
    assertThat(result.isSuccess()).isTrue();
    var output = result.output();
    assertThat(output.get("text")).isEqualTo("test response");
}
```

- [ ] **Step 5: Implement AgentInvokePlugin**

```java
@Plugin(value = "agent-invoke",
        description = "Single-shot agent invocation (open → query → close)")
public record AgentInvokePlugin(
        @Required String prompt,
        @Optional String pool) {

    @Execute
    public Result run(AgentProvider provider) {
        var config = AgentSessionConfig.builder().build();
        if (pool != null) { /* configure pool */ }
        long start = System.nanoTime();
        var invResult = provider.invokeBlocking(null, prompt,
                Duration.ofSeconds(30));
        long durationMs = (System.nanoTime() - start) / 1_000_000;
        return Result.of(Map.of(
            "text", invResult.text(),
            "tokens", invResult.outputTokens(),
            "duration", durationMs
        ));
    }
}
```

- [ ] **Step 6: Run all tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest="EmitEventPluginTest,AgentInvokePluginTest"`
Expected: ALL PASS

- [ ] **Step 7: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#685): emit-event and agent-invoke @Plugin step types

emit-event fires CloudEvents via CloudEventFixtureBuilder with
sibling-absorbed data: key. agent-invoke wraps session open/query/close
for single-shot agent interactions.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 2: Simulate Block + run-playbook + verify-simulation

### Task 4: SimulateBlockParser and EventCapture

**Files:**
- Create: `yaml-test-core/pom.xml`
- Create: `yaml-test-core/src/main/java/io/casehub/yaml/test/SimulateBlockParser.java`
- Create: `yaml-test-core/src/main/java/io/casehub/yaml/test/EventCapture.java`
- Create: `yaml-test-core/src/main/java/io/casehub/yaml/test/CapturedEvent.java`
- Test: `yaml-test-core/src/test/java/io/casehub/yaml/test/SimulateBlockParserTest.java`
- Test: `yaml-test-core/src/test/java/io/casehub/yaml/test/EventCaptureTest.java`

**Interfaces:**
- Consumes: `SimulationRuntime.pushOverlay()` / `popOverlay()`
- Consumes: `YamlSimulationConfig` parser for corpus loading
- Produces: `SimulateBlockParser.parse(Map<String, Object>)` → overlay-ready config
- Produces: `SimulateBlockParser.resolveAlias(String)` → canonical QN
- Produces: `EventCapture.addEvent(CloudEvent)`, `ofType(String)`, `last(String)`, `count(String)`
- Produces: `CapturedEvent` record: `event`, `data()` → `Map<String, Object>`

- [ ] **Step 1: Create yaml-test-core module POM**

New Maven module under platform root. Dependencies: `yaml-core`,
`yaml-step-runtime`, `simulation-core`, `simulation-config-core`,
`event-simulation-core` (for CloudEventFixtureBuilder), `jackson-dataformat-yaml`.
No Quarkus dependencies.

- [ ] **Step 2: Write failing test for EventCapture**

```java
@Test
void captureRecordsAndQueriesEvents() {
    var capture = new EventCapture();
    capture.addEvent(buildEvent("capacity.pressure", Map.of("p", 0.9)));
    capture.addEvent(buildEvent("capacity.pressure", Map.of("p", 0.95)));
    capture.addEvent(buildEvent("redistribution.decision", Map.of("reason", "threshold")));

    assertThat(capture.count("capacity.pressure")).isEqualTo(2);
    assertThat(capture.last("redistribution.decision").data().get("reason"))
        .isEqualTo("threshold");
    assertThat(capture.ofType("capacity.pressure")).hasSize(2);
}
```

- [ ] **Step 3: Implement EventCapture and CapturedEvent**

```java
public class EventCapture {
    private final List<CapturedEvent> events = new CopyOnWriteArrayList<>();

    public void addEvent(CloudEvent event) {
        events.add(new CapturedEvent(event, parseData(event)));
    }

    public List<CapturedEvent> ofType(String type) { /* filter */ }
    public CapturedEvent last(String type) { /* last match or null */ }
    public int count(String type) { /* count matches */ }
}

public record CapturedEvent(CloudEvent event, Map<String, Object> data) {
    public String type() { return event.getType(); }
    public String source() { return event.getSource().toString(); }
}
```

- [ ] **Step 4: Write failing test for SimulateBlockParser alias resolution**

```java
@Test
void agentAliasResolvesToQualifiedName() {
    var block = Map.of("agent", List.of(
        Map.of("prompt", "hello", "response", "world")
    ));

    var config = SimulateBlockParser.parse(block);
    assertThat(config.methods()).containsKey("agent-provider.invoke");
}

@Test
void promptResponseNormalisedToKeyOutput() {
    var block = Map.of("agent", List.of(
        Map.of("prompt", "hello", "response", "world")
    ));

    var config = SimulateBlockParser.parse(block);
    var corpus = config.methods().get("agent-provider.invoke").corpus();
    assertThat(corpus.get(0).get("key")).isEqualTo("hello");
    assertThat(corpus.get(0).get("output")).isEqualTo("world");
}
```

- [ ] **Step 5: Implement SimulateBlockParser**

Parse the `simulate:` block from a test file:
- Resolve aliases (`agent` → `agent-provider.invoke`)
- Normalise field names (`prompt`/`response` → `key`/`output`)
- Apply defaults (strategy: `key`, key-extractor: `field:user-prompt`)
- Support `corpus-file:` for external corpus loading
- Return a structure compatible with `SimulationRuntime.pushOverlay()`

- [ ] **Step 6: Write test for corpus-file loading**

```java
@Test
void corpusFileLoadsExternalYaml() {
    var block = Map.of("agent", Map.of(
        "corpus-file", "corpora/test-corpus.yaml"
    ));

    var config = SimulateBlockParser.parse(block,
        Path.of("src/test/resources"));
    assertThat(config.methods().get("agent-provider.invoke").corpus())
        .isNotEmpty();
}
```

(Create `src/test/resources/corpora/test-corpus.yaml` test fixture.)

- [ ] **Step 7: Run all tests**

Run: `mvn --batch-mode test -pl yaml-test-core`
Expected: ALL PASS

- [ ] **Step 8: Commit**

```bash
git add yaml-test-core/ pom.xml
git commit -m "feat(#684): SimulateBlockParser and EventCapture in yaml-test-core

Alias resolution (agent → agent-provider.invoke), field normalisation
(prompt/response → key/output), corpus-file loading. EventCapture
records CloudEvents with ofType/last/count queries.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 5: run-playbook and verify-simulation @Plugin step types

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/RunPlaybookPlugin.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/VerifySimulationPlugin.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/plugin/RunPlaybookPluginTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/plugin/VerifySimulationPluginTest.java`

**Interfaces:**
- Consumes: Walker + CatalogStepRunner from yaml-step-runtime
- Consumes: `SimulationVerifier` from simulation-core
- Consumes: `SimulationOverlay.journal()` for invocation journal
- Produces: `RunPlaybookPlugin` — executes target playbook, returns
  `PlaybookResult(succeeded, output, stepCount, duration, stepEvents, error)`
- Produces: `VerifySimulationPlugin` — delegates to `SimulationVerifier`

- [ ] **Step 1: Write failing test for run-playbook short form**

```java
@Test
void runPlaybookExecutesTargetAndCapturesResult() {
    var plugin = new RunPlaybookPlugin();
    var params = Map.of("_subject", "test-playbooks/simple.yaml");

    var result = plugin.run(params, testResourceRoot, walkerContext);
    assertThat(result.isSuccess()).isTrue();
    var output = result.output();
    assertThat(output.get("succeeded")).isEqualTo(true);
    assertThat(output.get("stepCount")).isEqualTo(2);
}
```

Create `src/test/resources/test-playbooks/simple.yaml` fixture.

- [ ] **Step 2: Implement RunPlaybookPlugin**

```java
@Plugin(value = "run-playbook",
        description = "Executes another playbook and captures results")
public class RunPlaybookPlugin {

    @Execute
    public Result run(Map<String, Object> params,
                      Path resourceRoot,
                      Walker walker,
                      CatalogStepRunner runner,
                      PluginRegistry registry) {
        String file = params.containsKey("_subject")
            ? (String) params.get("_subject")
            : (String) params.get("file");

        Path playbookPath = resourceRoot.resolve(file);
        // Parse → Walker.resolve → execute steps → collect results
        // ...
        return Result.of(Map.of(
            "succeeded", allPassed,
            "output", outputVars,
            "stepCount", stepCount,
            "duration", durationMs,
            "stepEvents", stepEvents,
            "error", errorMessage
        ));
    }
}
```

- [ ] **Step 3: Write failing test for verify-simulation**

```java
@Test
void verifySimulationChecksInvocationCount() {
    var overlay = createOverlayWithJournal(
        "agent-provider.invoke", 2);
    var plugin = new VerifySimulationPlugin();
    var params = Map.of(
        "method", "agent-provider.invoke",
        "called", 2
    );

    var result = plugin.run(params, overlay);
    assertThat(result.isSuccess()).isTrue();
}

@Test
void verifySimulationFailsOnWrongCount() {
    var overlay = createOverlayWithJournal(
        "agent-provider.invoke", 1);
    var plugin = new VerifySimulationPlugin();
    var params = Map.of(
        "method", "agent-provider.invoke",
        "called", 2
    );

    var result = plugin.run(params, overlay);
    assertThat(result.isSuccess()).isFalse();
}
```

- [ ] **Step 4: Implement VerifySimulationPlugin**

Delegates to `SimulationVerifier` — `called`, `calledAtLeast`,
`calledAtMost`, `neverCalled`, `inOrder`, `exhaustive`.

- [ ] **Step 5: Run all tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest="RunPlaybookPluginTest,VerifySimulationPluginTest"`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#685): run-playbook and verify-simulation @Plugin step types

run-playbook executes target playbooks via Walker path, captures
results (succeeded, output, stepCount, duration). verify-simulation
delegates to SimulationVerifier for invocation journal assertions.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 3: Test Runner (JUnit Platform + CLI)

### Task 6: YamlTestExecutor and YamlTestDiscovery (yaml-test-core)

**Files:**
- Create: `yaml-test-core/src/main/java/io/casehub/yaml/test/YamlTestDiscovery.java`
- Create: `yaml-test-core/src/main/java/io/casehub/yaml/test/YamlTestExecutor.java`
- Create: `yaml-test-core/src/main/java/io/casehub/yaml/test/TestResult.java`
- Create: `yaml-test-core/src/main/java/io/casehub/yaml/test/TestReport.java`
- Test: `yaml-test-core/src/test/java/io/casehub/yaml/test/YamlTestDiscoveryTest.java`
- Test: `yaml-test-core/src/test/java/io/casehub/yaml/test/YamlTestExecutorTest.java`

**Interfaces:**
- Consumes: `SimulateBlockParser` from Task 4
- Consumes: `EventCapture` from Task 4
- Consumes: `SimulationRuntime.pushOverlay()` / `popOverlay()`
- Consumes: `Walker.resolve()`, `CatalogStepRunner.run()`
- Produces: `YamlTestDiscovery.discover(Path root)` → `List<TestDescriptor>`
- Produces: `YamlTestExecutor.execute(TestDescriptor, SimulationRuntime, ...)` → `TestResult`
- Produces: `TestResult` record: `status(PASS/FAIL/ERROR/SKIP), name, file, failures, duration`
- Produces: `TestReport.toJunitXml(List<TestResult>)` → `String`

- [ ] **Step 1: Write failing test for discovery**

```java
@Test
void discoversTestYamlFilesInConventionOrder() {
    var descriptors = YamlTestDiscovery.discover(
        Path.of("src/test/resources/test-suite"));
    assertThat(descriptors).extracting("name")
        .containsExactly("01-basic", "02-session");
}
```

Create test fixtures:
- `src/test/resources/test-suite/01-basic.test.yaml`
- `src/test/resources/test-suite/02-session.test.yaml`

- [ ] **Step 2: Implement YamlTestDiscovery**

Walk directory tree, find `*.test.yaml`, sort by path, build
`TestDescriptor` tree (directories as containers, files as tests).

- [ ] **Step 3: Write failing test for executor**

```java
@Test
void executorPushesOverlayAndRunsSteps() {
    var descriptor = YamlTestDiscovery.discover(
        Path.of("src/test/resources/test-suite"))
        .get(0);
    var runtime = new SimulationRuntime(config, corpus);

    var result = YamlTestExecutor.execute(descriptor, runtime,
        registry, expressionEngines);
    assertThat(result.status()).isEqualTo(TestStatus.PASS);
}
```

- [ ] **Step 4: Implement YamlTestExecutor**

Orchestration: parse YAML → extract `simulate:` → push overlay →
create EventCapture → register `events` as deferred prefix →
Walker.resolve → execute steps → pop overlay → collect result.

Handle capture decorator processing in the step execution loop.

- [ ] **Step 5: Write test for TestReport JUnit XML output**

```java
@Test
void junitXmlContainsTestCaseElements() {
    var results = List.of(
        TestResult.pass("test1", "file1.test.yaml", 100),
        TestResult.fail("test2", "file2.test.yaml", 200, List.of(failure))
    );

    var xml = TestReport.toJunitXml(results);
    assertThat(xml).contains("<testcase name=\"test1\"");
    assertThat(xml).contains("<failure message=");
}
```

- [ ] **Step 6: Implement TestReport**

JUnit XML generation following the Surefire schema.

- [ ] **Step 7: Run all tests**

Run: `mvn --batch-mode test -pl yaml-test-core`
Expected: ALL PASS

- [ ] **Step 8: Commit**

```bash
git add yaml-test-core/
git commit -m "feat(#686): YamlTestDiscovery, YamlTestExecutor, TestReport

Convention-based discovery of *.test.yaml. Executor orchestrates:
simulate block → overlay push → Walker resolve → step execution →
overlay pop → result. JUnit XML report generation.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 7: JUnit Platform TestEngine + CLI (yaml-test module)

**Files:**
- Create: `yaml-test/pom.xml`
- Create: `yaml-test/src/main/java/io/casehub/yaml/test/engine/YamlTestEngine.java`
- Create: `yaml-test/src/main/java/io/casehub/yaml/test/engine/YamlTestDescriptor.java`
- Create: `yaml-test/src/main/java/io/casehub/yaml/test/cdi/YamlTestBeans.java`
- Create: `yaml-test/src/main/java/io/casehub/yaml/test/cdi/TestEventCapture.java`
- Create: `yaml-test/src/main/resources/META-INF/services/org.junit.platform.engine.TestEngine`
- Create: `yaml-test-core/src/main/java/io/casehub/yaml/test/cli/YamlTestCli.java`
- Test: `yaml-test/src/test/java/io/casehub/yaml/test/engine/YamlTestEngineTest.java`

**Interfaces:**
- Consumes: `YamlTestDiscovery` and `YamlTestExecutor` from Task 6
- Consumes: CDI `SimulationRuntime`, `PluginRegistry`, `ExpressionEngineRegistry`
- Produces: `YamlTestEngine implements TestEngine` (JUnit Platform SPI)
- Produces: `TestEventCapture @ApplicationScoped` (CDI observer → EventCapture bridge)
- Produces: `YamlTestCli.main(String[])` — standalone CLI entry point

- [ ] **Step 1: Create yaml-test module POM**

Dependencies: `yaml-test-core`, `junit-platform-engine`, Quarkus test
framework, CDI. SPI registration via
`META-INF/services/org.junit.platform.engine.TestEngine`.

- [ ] **Step 2: Write failing test for TestEngine discovery**

```java
@Test
void engineDiscoversTestYamlFiles() {
    var engine = new YamlTestEngine();
    assertThat(engine.getId()).isEqualTo("casehub-yaml");

    var request = LauncherDiscoveryRequestBuilder.request()
        .selectors(selectClasspathRoots(Set.of(
            Path.of("src/test/resources"))))
        .build();

    var descriptor = engine.discover(request,
        UniqueId.forEngine("casehub-yaml"));
    assertThat(descriptor.getChildren()).isNotEmpty();
}
```

- [ ] **Step 3: Implement YamlTestEngine**

`discover()` delegates to `YamlTestDiscovery`, wraps in JUnit
`TestDescriptor` tree. `execute()` iterates descriptors, creates
`EngineExecutionListener` callbacks for started/success/failure.

- [ ] **Step 4: Write SPI service file**

```
io.casehub.yaml.test.engine.YamlTestEngine
```

- [ ] **Step 5: Implement TestEventCapture CDI observer**

```java
@ApplicationScoped
public class TestEventCapture {
    private final AtomicReference<EventCapture> active = new AtomicReference<>();

    public void activate(EventCapture capture) { active.set(capture); }
    public void deactivate() { active.set(null); }

    void onCloudEvent(@Observes CloudEvent event) {
        var capture = active.get();
        if (capture != null) capture.addEvent(event);
    }
}
```

- [ ] **Step 6: Implement YamlTestCli**

```java
public class YamlTestCli {
    public static void main(String[] args) {
        // Parse args: paths, --filter, --report, --output
        // Create SimulationRuntime (standalone, no CDI)
        // Run YamlTestDiscovery + YamlTestExecutor
        // Print results, optionally write JUnit XML
        // System.exit based on pass/fail
    }
}
```

- [ ] **Step 7: Run all tests**

Run: `mvn --batch-mode test -pl yaml-test`
Expected: ALL PASS

- [ ] **Step 8: Full integration test — run the build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile and test

- [ ] **Step 9: Commit**

```bash
git add yaml-test/ yaml-test-core/ pom.xml
git commit -m "feat(#686): JUnit Platform TestEngine + standalone CLI

YamlTestEngine discovers and executes *.test.yaml files natively in
IntelliJ and Maven Surefire. TestEventCapture bridges CDI CloudEvents
into test-scoped EventCapture. YamlTestCli for non-CDI execution.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 4: Integration and Tutorial Tests

### Task 8: End-to-end integration test with tutorial .test.yaml files

**Files:**
- Create: `yaml-test/src/test/resources/tutorials/01-basics/01-invoke.test.yaml`
- Create: `yaml-test/src/test/resources/tutorials/01-basics/02-assert.test.yaml`
- Create: `yaml-test/src/test/resources/tutorials/02-sessions/01-context.test.yaml`
- Create: `yaml-test/src/test/resources/tutorials/03-events/01-emit.test.yaml`
- Create: `yaml-test/src/test/resources/corpora/financial-qa.yaml`

**Interfaces:**
- Consumes: All step types from Tasks 1-5
- Consumes: YamlTestEngine from Task 7
- Consumes: SimulateBlockParser from Task 4
- Produces: Working tutorial test suite that validates the full pipeline

- [ ] **Step 1: Create Level 1 tutorial — basic invoke**

```yaml
name: Basic agent invocation

simulate:
  agent:
    - prompt: "What's my risk profile?"
      response: "Moderate risk: 60% equities, 30% bonds, 10% cash."

steps:
  - agent-invoke:
      prompt: "What's my risk profile?"
    capture: result
  - assertThat: ${result.text}
    contains: 'equities'
```

- [ ] **Step 2: Create Level 1 tutorial — assertThat matchers**

```yaml
name: Assertion matchers

simulate:
  agent:
    - prompt: "portfolio"
      response: "Total value: 150000"

steps:
  - agent-invoke:
      prompt: "portfolio"
    capture: result
  - assertThat: ${result.text}
    contains: '150000'
    startsWith: 'Total'
    not-empty: true
```

- [ ] **Step 3: Create Level 2 tutorial — session context**

Use the Level 2 format from the spec with multi-turn agent session.

- [ ] **Step 4: Create Level 3 tutorial — emit-event**

```yaml
name: Emit and capture events

steps:
  - emit-event: test.event
    data:
      key: value
  - assertThat: ${events.last('test.event')}
    not-null: true
  - assertThat: ${events.count('test.event')}
    equals: 1
```

- [ ] **Step 5: Create shared corpus file**

```yaml
# corpora/financial-qa.yaml
- key: "risk profile"
  output: "Moderate risk: 60% equities."
- key: "rebalancing"
  output: "Shift 10% equities to bonds."
```

- [ ] **Step 6: Run the full tutorial suite via Maven**

Run: `mvn --batch-mode test -pl yaml-test`
Expected: ALL tutorials PASS — validates the full pipeline end-to-end

- [ ] **Step 7: Commit**

```bash
git add yaml-test/
git commit -m "feat(#686): tutorial test suite — e2e validation of declarative testing

4 tutorial .test.yaml files covering agent invoke, assertThat matchers,
session context, and event emission. Shared corpus file. All execute
via JUnit Platform TestEngine.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## References

- [2026-11-02-declarative-playbook-testing-design.md] — design spec this plan implements
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/AssertPlugin.java:15` — existing assert plugin
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java:12` — step resolution
- `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationRuntime.java:83-99` — pushOverlay/popOverlay
- `simulation-core/src/main/java/io/casehub/platform/simulation/SimulationOverlay.java:5` — overlay structure
- `event-simulation-core/src/main/java/io/casehub/platform/simulation/event/CloudEventFixtureBuilder.java:23` — fromMap
- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/PluginRegistry.java:6` — plugin registration SPI
- GitHub #683, #684, #685, #686, #687, #688
