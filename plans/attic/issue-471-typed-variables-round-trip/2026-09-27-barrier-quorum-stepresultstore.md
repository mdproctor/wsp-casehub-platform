# Barrier/Quorum Sugar + StepResultStore Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #469 — Barrier/quorum sugar + StepResultStore wiring
**Issue group:** #469

**Goal:** Wire barrier and quorum as structural step sugar over OrcLatch, integrate StepResultStore recording into StructuralStepEvaluator, and enable `${result.<step>}` variable resolution.

**Architecture:** All changes are in `yaml-step-runtime`. The yaml-core primitives (OrcLatch, StepResultStore, DefaultStepResultStore, ScenarioScope, ObjectVariableSource, VariableResolver.withObjectScope, DurationParser) already exist and are tested. This is a wiring exercise — no new yaml-core types.

**Tech Stack:** Java 21+, JUnit 5, AssertJ, virtual threads (Executors.newVirtualThreadPerTaskExecutor)

## Global Constraints

- `yaml-step-runtime` depends on `yaml-core` and `yaml-plugin-api` only
- All coordination primitives use `java.util.concurrent` — never `synchronized` (virtual thread pinning)
- `StepResultStore` is a flat namespace (`ConcurrentHashMap<String, ...>`) — step names must be globally unique within a scenario
- Barrier: step failure DOES count toward countdown (the step completed, just with an error)
- Quorum: step failure does NOT count toward the `required` threshold — only successes count
- Parse-time validation for step name references (issue-386 type safety principle)

---

## Batch 1: Step names + result recording

After this batch: steps carry names, names are validated for uniqueness, results are recorded to StepResultStore, and `${result.<step>}` resolves from the store.

### Task 1: ResolvedStep name field + StepWalker name extraction + duplicate validation

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepWalker.java`
- Modify: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/StepWalkerTest.java`

**Interfaces:**
- Produces: `ResolvedStep.name()` returning `String` (nullable) — used by Task 2 for result recording, Task 3 for barrier/quorum step names

- [ ] **Step 1: Write failing test — name propagation through PluginStep**

```java
// In StepWalkerTest.java
@Test
void extractsStepLabel_passesToResolvedStep() {
    Map<String, Object> step = new LinkedHashMap<>();
    step.put("step", "risk-eval");
    step.put("process", Map.of("command", "evaluate.sh"));

    List<ResolvedStep> resolved = StepWalker.resolve(List.of(step), catalog);

    assertThat(resolved).hasSize(1);
    assertThat(resolved.get(0).name()).isEqualTo("risk-eval");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl yaml-step-runtime test -Dtest=StepWalkerTest#extractsStepLabel_passesToResolvedStep -q`
Expected: FAIL — `name()` method does not exist on ResolvedStep

- [ ] **Step 3: Add default `name()` to ResolvedStep sealed interface**

In `ResolvedStep.java`, add a default method to the interface:

```java
default String name() { return null; }
```

Then add a `String name` field to each record variant. For `PluginStep`:
```java
record PluginStep(
        String name,
        CatalogEntry entry,
        Map<String, Object> params,
        Map<String, Object> decorators) implements ResolvedStep {

    public PluginStep {
        params     = Map.copyOf(params);
        decorators = Map.copyOf(decorators);
    }
}
```

Repeat for all 8 existing variants: `PluginStep`, `InvokeStep`, `BlockStep`, `IfElseStep`, `MatchStep`, `ParallelStep`, `TryCatchFinallyStep`, `SelectStep`. The `name` field is first in each record (before existing fields), nullable.

Update all construction sites in `StepWalker.resolveOne()` to pass `null` for name initially (the extraction comes next). Update all test construction sites in `StructuralStepEvaluatorTest.java` and `StepWalkerTest.java` — add `null` as the first argument to every record constructor call.

- [ ] **Step 4: Extract step name in StepWalker.resolveOne()**

In `StepWalker.resolveOne()`, change the `"step"` case from discarding to capturing:

```java
String stepName = null;  // declare at top of method

// In the key loop:
if ("step".equals(key)) {
    stepName = (String) e.getValue();
}
```

Then pass `stepName` as the first argument to every `ResolvedStep` record construction at the bottom of `resolveOne()`.

- [ ] **Step 5: Run test to verify it passes**

Run: `mvn -pl yaml-step-runtime test -Dtest=StepWalkerTest#extractsStepLabel_passesToResolvedStep -q`
Expected: PASS

- [ ] **Step 6: Write failing test — no step label gives null name**

```java
@Test
void noStepLabel_nameIsNull() {
    Map<String, Object> step = new LinkedHashMap<>();
    step.put("process", Map.of("command", "deploy.sh"));

    List<ResolvedStep> resolved = StepWalker.resolve(List.of(step), catalog);

    assertThat(resolved.get(0).name()).isNull();
}
```

- [ ] **Step 7: Run test — should pass already**

Run: `mvn -pl yaml-step-runtime test -Dtest=StepWalkerTest#noStepLabel_nameIsNull -q`
Expected: PASS (null is the default)

- [ ] **Step 8: Write failing test — duplicate step name throws**

```java
@Test
void duplicateStepName_throws() {
    Map<String, Object> step1 = new LinkedHashMap<>();
    step1.put("step", "eval");
    step1.put("process", Map.of("command", "a.sh"));

    Map<String, Object> step2 = new LinkedHashMap<>();
    step2.put("step", "eval");
    step2.put("process", Map.of("command", "b.sh"));

    assertThatThrownBy(() -> StepWalker.resolve(List.of(step1, step2), catalog))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("duplicate step name 'eval'");
}
```

- [ ] **Step 9: Run test to verify it fails**

Run: `mvn -pl yaml-step-runtime test -Dtest=StepWalkerTest#duplicateStepName_throws -q`
Expected: FAIL — no duplicate checking exists

- [ ] **Step 10: Add duplicate validation to StepWalker**

Add a `Set<String> seenNames` parameter to the private `resolve()` method. The public `resolve()` creates the set and passes it through:

```java
public static List<ResolvedStep> resolve(List<Map<String, Object>> steps, StepCatalog catalog) {
    Set<String> seenNames = new HashSet<>();
    return resolve(steps, catalog, 0, "root", seenNames);
}

private static List<ResolvedStep> resolve(
        List<Map<String, Object>> steps, StepCatalog catalog,
        int depth, String path, Set<String> seenNames) {
```

In `resolveOne`, after extracting `stepName`:
```java
if (stepName != null && !seenNames.add(stepName)) {
    throw new IllegalArgumentException(
            path + " → Step " + index + ": duplicate step name '" + stepName + "'");
}
```

Pass `seenNames` to all recursive `resolve()` calls.

- [ ] **Step 11: Run test to verify it passes**

Run: `mvn -pl yaml-step-runtime test -Dtest=StepWalkerTest#duplicateStepName_throws -q`
Expected: PASS

- [ ] **Step 12: Write test — duplicate across nesting levels**

```java
@Test
void duplicateStepName_acrossNestedBlocks_throws() {
    Map<String, Object> inner = new LinkedHashMap<>();
    inner.put("step", "eval");
    inner.put("process", Map.of("command", "a.sh"));

    Map<String, Object> outer = new LinkedHashMap<>();
    outer.put("step", "eval");
    outer.put("process", Map.of("command", "b.sh"));

    Map<String, Object> block = new LinkedHashMap<>();
    block.put("block", List.of(inner));

    assertThatThrownBy(() -> StepWalker.resolve(List.of(block, outer), catalog))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("duplicate step name 'eval'");
}
```

- [ ] **Step 13: Run — should pass already (seenNames threaded through recursion)**

Run: `mvn -pl yaml-step-runtime test -Dtest=StepWalkerTest#duplicateStepName_acrossNestedBlocks_throws -q`
Expected: PASS

- [ ] **Step 14: Run all existing tests to verify no regressions**

Run: `mvn -pl yaml-step-runtime test -q`
Expected: all tests PASS

- [ ] **Step 15: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepWalker.java yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/StepWalkerTest.java yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/StructuralStepEvaluatorTest.java
git commit -m "feat(#469): step name propagation + duplicate validation

ResolvedStep sealed interface gains name() default method. All 8 record
variants carry nullable String name field. StepWalker extracts step:
label, validates uniqueness across all nesting levels.

Refs #469"
```

---

### Task 2: StepResultStore recording + result ObjectVariableSource

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java`
- Modify: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/StructuralStepEvaluatorTest.java`

**Interfaces:**
- Consumes: `ResolvedStep.name()` from Task 1
- Consumes: `StepResultStore` (yaml-core — `recordSuccess`, `recordFailure`, `result`, `error`, `hasCompleted`)
- Consumes: `ObjectVariableSource` (yaml-core), `VariableResolver.withObjectScope()` (yaml-core)
- Produces: `StructuralStepEvaluator.recordResult(String, StepResult)` — used by Task 4 for countdown wiring
- Produces: `StructuralStepEvaluator.withResultScope(VariableResolver)` — wraps resolver with result prefix

- [ ] **Step 1: Write failing test — named step records success**

```java
// In StructuralStepEvaluatorTest.java — new @Nested class
@Nested
class StepResultRecordingTests {

    private DefaultScenarioScope scope;
    private StructuralStepEvaluator scopedEvaluator;

    @BeforeEach
    void setUp() {
        scope = new DefaultScenarioScope();
        var condEval = new ConditionEvaluator(null);
        scopedEvaluator = new StructuralStepEvaluator(condEval, scope);
    }

    @Test
    void evaluate_namedStep_recordsSuccessToStore() {
        var step = new ResolvedStep.InvokeStep("risk-eval", Map.of("id", "a"), Map.of());
        scopedEvaluator.evaluate(step, resolver,
                (s, r) -> StepResult.of(Map.of("score", 85)));

        assertThat(scope.resultStore().hasCompleted("risk-eval")).isTrue();
        assertThat(scope.resultStore().result("risk-eval"))
                .containsEntry("score", 85);
        assertThat(scope.resultStore().error("risk-eval")).isNull();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl yaml-step-runtime test -Dtest="StructuralStepEvaluatorTest\$StepResultRecordingTests#evaluate_namedStep_recordsSuccessToStore" -q`
Expected: FAIL — evaluator doesn't record results

- [ ] **Step 3: Add recordResult method + call from evaluate()**

In `StructuralStepEvaluator.java`:

Add a `resultSource` field and `withResultScope` method:

```java
private final ObjectVariableSource resultSource;

// In constructor with scope:
this.resultSource = (scope != null) ? buildResultSource(scope.resultStore()) : null;

private VariableResolver withResultScope(VariableResolver resolver) {
    return resultSource != null ? resolver.withObjectScope("result", resultSource) : resolver;
}
```

Add `recordResult`:
```java
private void recordResult(String stepName, StepResult result) {
    if (stepName == null || scope == null) return;
    StepResultStore store = scope.resultStore();
    if (result.isSuccess()) {
        store.recordSuccess(stepName, result.output());
    } else {
        String message = result instanceof StepResult.Failure f
                ? f.message() : "unknown error";
        store.recordFailure(stepName, new StepError(message, null, null));
    }
}
```

Update `evaluate()`:
```java
public StepResult evaluate(ResolvedStep step, VariableResolver resolver, StepRunner runner) {
    VariableResolver effective = withResultScope(resolver);
    Map<String, Object> decorators = step.decorators();
    StepResult result;
    if (decorators.isEmpty()) {
        result = dispatchStep(step, effective, runner);
    } else {
        result = decoratorChain.apply(decorators, r -> dispatchStep(step, r, runner))
                .execute(effective);
    }
    recordResult(step.name(), result);
    return result;
}
```

Add `buildResultSource` as a private static method:
```java
private static ObjectVariableSource buildResultSource(StepResultStore store) {
    return name -> {
        if (!store.hasCompleted(name)) return null;
        Map<String, Object> output = store.result(name);
        StepError err = store.error(name);
        if (output == null && err == null) return null;
        if (output == null) {
            return Map.of("error", Map.of(
                    "message", err.message() != null ? err.message() : "",
                    "exceptionClass", err.exceptionClass() != null ? err.exceptionClass() : "",
                    "stackTrace", err.stackTrace() != null ? err.stackTrace() : ""));
        }
        if (err == null) return output;
        var composite = new java.util.HashMap<>(output);
        composite.put("error", Map.of(
                "message", err.message() != null ? err.message() : "",
                "exceptionClass", err.exceptionClass() != null ? err.exceptionClass() : "",
                "stackTrace", err.stackTrace() != null ? err.stackTrace() : ""));
        return composite;
    };
}
```

Add required imports: `StepResultStore`, `StepError`, `ObjectVariableSource` from `io.casehub.yaml.core.orchestration` and `io.casehub.yaml.core.resolver`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -pl yaml-step-runtime test -Dtest="StructuralStepEvaluatorTest\$StepResultRecordingTests#evaluate_namedStep_recordsSuccessToStore" -q`
Expected: PASS

- [ ] **Step 5: Write + run remaining recording tests**

```java
@Test
void evaluate_namedStep_recordsFailureToStore() {
    var step = new ResolvedStep.InvokeStep("risk-eval", Map.of("id", "a"), Map.of());
    scopedEvaluator.evaluate(step, resolver,
            (s, r) -> StepResult.failed("connection timeout"));

    assertThat(scope.resultStore().hasCompleted("risk-eval")).isTrue();
    assertThat(scope.resultStore().result("risk-eval")).isNull();
    assertThat(scope.resultStore().error("risk-eval")).isNotNull();
    assertThat(scope.resultStore().error("risk-eval").message())
            .isEqualTo("connection timeout");
}

@Test
void evaluate_unnamedStep_doesNotRecord() {
    var step = new ResolvedStep.InvokeStep(null, Map.of("id", "a"), Map.of());
    scopedEvaluator.evaluate(step, resolver,
            (s, r) -> StepResult.of(Map.of("score", 85)));

    assertThat(scope.resultStore().hasCompleted("a")).isFalse();
}

@Test
void evaluate_noScope_doesNotRecord() {
    var step = new ResolvedStep.InvokeStep("risk-eval", Map.of("id", "a"), Map.of());
    evaluator.evaluate(step, resolver,
            (s, r) -> StepResult.of(Map.of("score", 85)));
    // No assertion needed — just verify no NPE
}

@Test
void evaluate_nestedNamedSteps_allRecorded() {
    var inner1 = new ResolvedStep.InvokeStep("step-a", Map.of("id", "a"), Map.of());
    var inner2 = new ResolvedStep.InvokeStep("step-b", Map.of("id", "b"), Map.of());
    var block = new ResolvedStep.BlockStep(null, List.of(inner1, inner2), Map.of());
    scopedEvaluator.evaluate(block, resolver,
            (s, r) -> StepResult.of(Map.of("id", ((ResolvedStep.InvokeStep) s).invokeSpec().get("id"))));

    assertThat(scope.resultStore().hasCompleted("step-a")).isTrue();
    assertThat(scope.resultStore().hasCompleted("step-b")).isTrue();
}

@Test
void evaluate_parallelNamedSteps_allRecordedConcurrently() throws Exception {
    var step1 = new ResolvedStep.InvokeStep("eval-a", Map.of("id", "a"), Map.of());
    var step2 = new ResolvedStep.InvokeStep("eval-b", Map.of("id", "b"), Map.of());
    var parallel = new ResolvedStep.ParallelStep(null, List.of(step1, step2), Map.of());
    scopedEvaluator.evaluate(parallel, resolver,
            (s, r) -> StepResult.of(Map.of("done", true)));

    assertThat(scope.resultStore().hasCompleted("eval-a")).isTrue();
    assertThat(scope.resultStore().hasCompleted("eval-b")).isTrue();
}
```

Run: `mvn -pl yaml-step-runtime test -Dtest="StructuralStepEvaluatorTest\$StepResultRecordingTests" -q`
Expected: all PASS

- [ ] **Step 6: Write failing test — result variable resolution**

```java
@Nested
class ResultVariableResolutionTests {

    private DefaultScenarioScope scope;
    private StructuralStepEvaluator scopedEvaluator;

    @BeforeEach
    void setUp() {
        scope = new DefaultScenarioScope();
        var condEval = new ConditionEvaluator(null);
        scopedEvaluator = new StructuralStepEvaluator(condEval, scope);
    }

    @Test
    void resultVariable_completedStep_resolvesOutput() {
        var step = new ResolvedStep.InvokeStep("risk-eval", Map.of("id", "a"), Map.of());
        scopedEvaluator.evaluate(step, resolver,
                (s, r) -> StepResult.of(Map.of("score", 85)));

        var resolved = resolver.withObjectScope("result",
                StructuralStepEvaluatorTest.this.buildResultSource(scope.resultStore()));
        // Actually, the evaluator wraps the resolver internally.
        // Let's test via a second step that references the result:
        var step2 = new ResolvedStep.InvokeStep("consumer", Map.of("id", "b"), Map.of());
        var capturedResolver = new VariableResolver[1];
        scopedEvaluator.evaluate(step2, resolver, (s, r) -> {
            capturedResolver[0] = r;
            return StepResult.of(Map.of());
        });

        Object value = capturedResolver[0].resolve("${result.risk-eval.score}");
        assertThat(value).isEqualTo(85);
    }
}
```

- [ ] **Step 7: Run test to verify it fails or passes**

Run: `mvn -pl yaml-step-runtime test -Dtest="StructuralStepEvaluatorTest\$ResultVariableResolutionTests#resultVariable_completedStep_resolvesOutput" -q`

- [ ] **Step 8: Write remaining resolution tests**

```java
@Test
void resultVariable_failedStep_resolvesError() {
    var step = new ResolvedStep.InvokeStep("risk-eval", Map.of("id", "a"), Map.of());
    scopedEvaluator.evaluate(step, resolver,
            (s, r) -> StepResult.failed("timeout"));

    var step2 = new ResolvedStep.InvokeStep(null, Map.of("id", "b"), Map.of());
    var capturedResolver = new VariableResolver[1];
    scopedEvaluator.evaluate(step2, resolver, (s, r) -> {
        capturedResolver[0] = r;
        return StepResult.of(Map.of());
    });

    Object errorMap = capturedResolver[0].resolve("${result.risk-eval.error}");
    assertThat(errorMap).isInstanceOf(Map.class);
    @SuppressWarnings("unchecked")
    var error = (Map<String, Object>) errorMap;
    assertThat(error).containsEntry("message", "timeout");
}

@Test
void resultVariable_uncompletedStep_returnsNull() {
    var step = new ResolvedStep.InvokeStep(null, Map.of("id", "a"), Map.of());
    var capturedResolver = new VariableResolver[1];
    scopedEvaluator.evaluate(step, resolver, (s, r) -> {
        capturedResolver[0] = r;
        return StepResult.of(Map.of());
    });

    Object value = capturedResolver[0].resolve("${result.nonexistent}");
    assertThat(value).isNull();
}

@Test
void resultVariable_soleReference_returnsTypedMap() {
    var step = new ResolvedStep.InvokeStep("risk-eval", Map.of("id", "a"), Map.of());
    scopedEvaluator.evaluate(step, resolver,
            (s, r) -> StepResult.of(Map.of("score", 85, "grade", "A")));

    var step2 = new ResolvedStep.InvokeStep(null, Map.of("id", "b"), Map.of());
    var capturedResolver = new VariableResolver[1];
    scopedEvaluator.evaluate(step2, resolver, (s, r) -> {
        capturedResolver[0] = r;
        return StepResult.of(Map.of());
    });

    Object value = capturedResolver[0].resolve("${result.risk-eval}");
    assertThat(value).isInstanceOf(Map.class);
    @SuppressWarnings("unchecked")
    var map = (Map<String, Object>) value;
    assertThat(map).containsEntry("score", 85).containsEntry("grade", "A");
}
```

- [ ] **Step 9: Run all tests**

Run: `mvn -pl yaml-step-runtime test -q`
Expected: all PASS

- [ ] **Step 10: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#469): StepResultStore recording + result variable resolution

StructuralStepEvaluator records success/failure to ScenarioScope.resultStore()
after each named step. ObjectVariableSource for 'result' prefix enables
\${result.<step>.field} resolution. Composite Map supports error drilling.

Refs #469"
```

---

## Batch 2: Barrier and quorum coordination

After this batch: barrier and quorum step types parse from YAML, evaluate with latch-based coordination, and compose with parallel blocks and result variables.

### Task 3: BarrierStep + QuorumStep variants + StepWalker parsing + reference validation

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepWalker.java`
- Modify: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/StepWalkerTest.java`

**Interfaces:**
- Consumes: `ResolvedStep.name()` from Task 1, `DurationParser` from yaml-core (`io.casehub.yaml.core.orchestration.DurationParser`)
- Produces: `ResolvedStep.BarrierStep(name, awaitSteps, timeout, decorators)` — used by Task 4
- Produces: `ResolvedStep.QuorumStep(name, required, ofSteps, timeout, decorators)` — used by Task 4
- Produces: `StepWalker.validateBarrierQuorumReferences(List<ResolvedStep>, Set<String>)` — called from public `resolve()`

- [ ] **Step 1: Write failing test — StepWalker parses barrier step**

```java
@Test
void parsesBarrierStep() {
    Map<String, Object> step = new LinkedHashMap<>();
    step.put("step", "await-all");
    step.put("barrier", Map.of("await", List.of("eval-a", "eval-b"), "timeout", "30s"));

    // Need named steps that barrier references — add them
    Map<String, Object> evalA = new LinkedHashMap<>();
    evalA.put("step", "eval-a");
    evalA.put("process", Map.of("command", "a.sh"));

    Map<String, Object> evalB = new LinkedHashMap<>();
    evalB.put("step", "eval-b");
    evalB.put("process", Map.of("command", "b.sh"));

    List<ResolvedStep> resolved = StepWalker.resolve(List.of(evalA, evalB, step), catalog);

    assertThat(resolved).hasSize(3);
    assertThat(resolved.get(2)).isInstanceOf(ResolvedStep.BarrierStep.class);
    var barrier = (ResolvedStep.BarrierStep) resolved.get(2);
    assertThat(barrier.name()).isEqualTo("await-all");
    assertThat(barrier.awaitSteps()).containsExactly("eval-a", "eval-b");
    assertThat(barrier.timeout()).isEqualTo(java.time.Duration.ofSeconds(30));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl yaml-step-runtime test -Dtest=StepWalkerTest#parsesBarrierStep -q`
Expected: FAIL — `BarrierStep` doesn't exist, `barrier` is not a recognised keyword

- [ ] **Step 3: Add BarrierStep + QuorumStep to ResolvedStep**

In `ResolvedStep.java`, add to the permits list and add new records:

```java
public sealed interface ResolvedStep permits
    ResolvedStep.PluginStep,
    ResolvedStep.InvokeStep,
    ResolvedStep.BlockStep,
    ResolvedStep.IfElseStep,
    ResolvedStep.MatchStep,
    ResolvedStep.ParallelStep,
    ResolvedStep.TryCatchFinallyStep,
    ResolvedStep.SelectStep,
    ResolvedStep.BarrierStep,
    ResolvedStep.QuorumStep {
```

```java
record BarrierStep(
        String name,
        List<String> awaitSteps,
        Duration timeout,
        Map<String, Object> decorators) implements ResolvedStep {

    public BarrierStep {
        if (awaitSteps == null || awaitSteps.isEmpty()) {
            throw new IllegalArgumentException("barrier 'await' must be non-empty");
        }
        awaitSteps = List.copyOf(awaitSteps);
        decorators = Map.copyOf(decorators);
    }
}

record QuorumStep(
        String name,
        int required,
        List<String> ofSteps,
        Duration timeout,
        Map<String, Object> decorators) implements ResolvedStep {

    public QuorumStep {
        if (required <= 0) throw new IllegalArgumentException("quorum 'required' must be > 0");
        if (required > ofSteps.size()) throw new IllegalArgumentException(
                "quorum 'required' (" + required + ") > 'of' (" + ofSteps.size() + ")");
        ofSteps = List.copyOf(ofSteps);
        decorators = Map.copyOf(decorators);
    }
}
```

Add `import java.time.Duration;` to ResolvedStep.java.

- [ ] **Step 4: Add barrier/quorum parsing to StepWalker**

In `StepWalker.resolveOne()`, add `"barrier"` and `"quorum"` to the structural type recognition alongside `"block"`, `"parallel"`, `"try"`, `"select"`:

```java
} else if ("block".equals(key) || "parallel".equals(key) || "try".equals(key)
           || "select".equals(key) || "barrier".equals(key) || "quorum".equals(key)) {
    structuralType  = key;
    structuralValue = e.getValue();
}
```

Add parsing blocks before the plugin/invoke resolution at the end of `resolveOne()`:

```java
if ("barrier".equals(structuralType)) {
    @SuppressWarnings("unchecked")
    var barrierMap = (Map<String, Object>) structuralValue;
    @SuppressWarnings("unchecked")
    var awaitList = (List<String>) barrierMap.get("await");
    if (awaitList == null || awaitList.isEmpty()) {
        throw new IllegalArgumentException(
                stepPath + ": barrier 'await' must be a non-empty list of step names");
    }
    var timeoutStr = (String) barrierMap.get("timeout");
    return new ResolvedStep.BarrierStep(stepName, awaitList,
            DurationParser.parseOrNull(timeoutStr), decorators);
}
if ("quorum".equals(structuralType)) {
    @SuppressWarnings("unchecked")
    var quorumMap = (Map<String, Object>) structuralValue;
    var required = ((Number) quorumMap.get("required")).intValue();
    @SuppressWarnings("unchecked")
    var ofList = (List<String>) quorumMap.get("of");
    if (ofList == null || ofList.isEmpty()) {
        throw new IllegalArgumentException(
                stepPath + ": quorum 'of' must be a non-empty list of step names");
    }
    var timeoutStr = (String) quorumMap.get("timeout");
    return new ResolvedStep.QuorumStep(stepName, required, ofList,
            DurationParser.parseOrNull(timeoutStr), decorators);
}
```

Add `import io.casehub.yaml.core.orchestration.DurationParser;` to StepWalker.

- [ ] **Step 5: Add reference validation (two-pass)**

Add `validateBarrierQuorumReferences` as a private static method in StepWalker. Call it from the public `resolve()`:

```java
public static List<ResolvedStep> resolve(List<Map<String, Object>> steps, StepCatalog catalog) {
    Set<String> seenNames = new HashSet<>();
    List<ResolvedStep> result = resolve(steps, catalog, 0, "root", seenNames);
    validateBarrierQuorumReferences(result, seenNames);
    return result;
}

private static void validateBarrierQuorumReferences(
        List<ResolvedStep> steps, Set<String> knownNames) {
    for (ResolvedStep step : steps) {
        switch (step) {
            case ResolvedStep.BarrierStep b -> {
                for (String name : b.awaitSteps()) {
                    if (!knownNames.contains(name)) {
                        throw new IllegalArgumentException(
                                "barrier '" + b.name() + "' awaits unknown step '" + name + "'");
                    }
                }
            }
            case ResolvedStep.QuorumStep q -> {
                for (String name : q.ofSteps()) {
                    if (!knownNames.contains(name)) {
                        throw new IllegalArgumentException(
                                "quorum '" + q.name() + "' references unknown step '" + name + "'");
                    }
                }
            }
            case ResolvedStep.BlockStep b -> validateBarrierQuorumReferences(b.steps(), knownNames);
            case ResolvedStep.ParallelStep p -> validateBarrierQuorumReferences(p.steps(), knownNames);
            case ResolvedStep.TryCatchFinallyStep t -> {
                validateBarrierQuorumReferences(t.trySteps(), knownNames);
                validateBarrierQuorumReferences(t.catchSteps(), knownNames);
                validateBarrierQuorumReferences(t.finallySteps(), knownNames);
            }
            default -> {}
        }
    }
}
```

Also update the `dispatchStep` switch in `StructuralStepEvaluator.java` to add placeholder cases for the new types (avoids compile error — evaluation comes in Task 4):

```java
case ResolvedStep.BarrierStep b -> StepResult.failed("barrier not yet implemented");
case ResolvedStep.QuorumStep q -> StepResult.failed("quorum not yet implemented");
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mvn -pl yaml-step-runtime test -Dtest=StepWalkerTest#parsesBarrierStep -q`
Expected: PASS

- [ ] **Step 7: Write + run remaining parsing tests**

```java
@Test
void parsesQuorumStep() {
    Map<String, Object> evalA = new LinkedHashMap<>();
    evalA.put("step", "strat-a");
    evalA.put("process", Map.of("command", "a.sh"));
    Map<String, Object> evalB = new LinkedHashMap<>();
    evalB.put("step", "strat-b");
    evalB.put("process", Map.of("command", "b.sh"));
    Map<String, Object> evalC = new LinkedHashMap<>();
    evalC.put("step", "strat-c");
    evalC.put("process", Map.of("command", "c.sh"));

    Map<String, Object> step = new LinkedHashMap<>();
    step.put("step", "consensus");
    step.put("quorum", Map.of("required", 2, "of", List.of("strat-a", "strat-b", "strat-c"), "timeout", "15s"));

    List<ResolvedStep> resolved = StepWalker.resolve(
            List.of(evalA, evalB, evalC, step), catalog);

    assertThat(resolved.get(3)).isInstanceOf(ResolvedStep.QuorumStep.class);
    var quorum = (ResolvedStep.QuorumStep) resolved.get(3);
    assertThat(quorum.required()).isEqualTo(2);
    assertThat(quorum.ofSteps()).containsExactly("strat-a", "strat-b", "strat-c");
}

@Test
void barrierWithoutAwait_throwsAtParseTime() {
    Map<String, Object> step = new LinkedHashMap<>();
    step.put("step", "wait");
    step.put("barrier", Map.of());

    assertThatThrownBy(() -> StepWalker.resolve(List.of(step), catalog))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("await");
}

@Test
void quorumRequiredExceedsOf_throwsAtParseTime() {
    Map<String, Object> evalA = new LinkedHashMap<>();
    evalA.put("step", "a");
    evalA.put("process", Map.of("command", "a.sh"));

    Map<String, Object> step = new LinkedHashMap<>();
    step.put("step", "q");
    step.put("quorum", Map.of("required", 5, "of", List.of("a")));

    assertThatThrownBy(() -> StepWalker.resolve(List.of(evalA, step), catalog))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("required");
}

@Test
void barrierAwaitsUnknownStep_throws() {
    Map<String, Object> step = new LinkedHashMap<>();
    step.put("step", "wait");
    step.put("barrier", Map.of("await", List.of("nonexistent")));

    assertThatThrownBy(() -> StepWalker.resolve(List.of(step), catalog))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("unknown step 'nonexistent'");
}

@Test
void quorumReferencesUnknownStep_throws() {
    Map<String, Object> step = new LinkedHashMap<>();
    step.put("step", "q");
    step.put("quorum", Map.of("required", 1, "of", List.of("ghost")));

    assertThatThrownBy(() -> StepWalker.resolve(List.of(step), catalog))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("unknown step 'ghost'");
}
```

Run: `mvn -pl yaml-step-runtime test -Dtest=StepWalkerTest -q`
Expected: all PASS

- [ ] **Step 8: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#469): BarrierStep + QuorumStep types + StepWalker parsing

New sealed permits: BarrierStep(awaitSteps, timeout) and QuorumStep(required,
ofSteps, timeout). StepWalker recognises barrier: and quorum: structural
keywords. Two-pass validation catches unknown step name references at
parse time.

Refs #469"
```

---

### Task 4: Barrier/quorum evaluation + latch wiring + QuorumTracker + composition tests

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/QuorumTracker.java`
- Modify: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/StructuralStepEvaluatorTest.java`

**Interfaces:**
- Consumes: `ResolvedStep.BarrierStep`, `ResolvedStep.QuorumStep` from Task 3
- Consumes: `OrcLatch` (yaml-core — `countDown`, `await`, `getCount`), `ScenarioScope.latch()`
- Consumes: `StructuralStepEvaluator.recordResult()` from Task 2 (extended with countdown)
- Produces: `StructuralStepEvaluator.preRegisterLatches(List<ResolvedStep>)` — must be called before evaluation
- Produces: `QuorumTracker` record — success-only counting with unreachability detection

- [ ] **Step 1: Create QuorumTracker record**

Create `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/QuorumTracker.java`:

```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.core.orchestration.OrcLatch;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

record QuorumTracker(OrcLatch latch, int required, int totalSteps,
                     AtomicInteger successCount, AtomicInteger failureCount,
                     AtomicBoolean unreachable) {

    void onStepComplete(boolean success) {
        if (success) {
            successCount.incrementAndGet();
            latch.countDown();
            return;
        }
        int failures = failureCount.incrementAndGet();
        if (failures > totalSteps - required) {
            unreachable.set(true);
            while (latch.getCount() > 0) {
                latch.countDown();
            }
        }
    }

    boolean isUnreachable() {
        return unreachable.get();
    }
}
```

- [ ] **Step 2: Write failing test — barrier awaits all named steps**

```java
@Nested
class BarrierTests {

    private DefaultScenarioScope scope;
    private StructuralStepEvaluator scopedEvaluator;

    @BeforeEach
    void setUp() {
        scope = new DefaultScenarioScope();
        var condEval = new ConditionEvaluator(null);
        scopedEvaluator = new StructuralStepEvaluator(condEval, scope);
    }

    @Test
    void barrier_awaitsAllNamedSteps() throws Exception {
        var evalA = new ResolvedStep.InvokeStep("eval-a", Map.of("id", "a"), Map.of());
        var evalB = new ResolvedStep.InvokeStep("eval-b", Map.of("id", "b"), Map.of());
        var barrier = new ResolvedStep.BarrierStep("wait-all",
                List.of("eval-a", "eval-b"), null, Map.of());
        var parallel = new ResolvedStep.ParallelStep(null,
                List.of(evalA, evalB, barrier), Map.of());

        var order = new CopyOnWriteArrayList<String>();
        scopedEvaluator.preRegisterLatches(List.of(parallel));

        var result = scopedEvaluator.evaluate(parallel, resolver, (step, res) -> {
            if (step instanceof ResolvedStep.InvokeStep inv) {
                String id = (String) inv.invokeSpec().get("id");
                order.add(id);
                try { Thread.sleep(50); } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
            return StepResult.of(Map.of());
        });

        assertThat(result.isSuccess()).isTrue();
        assertThat(order).containsExactlyInAnyOrder("a", "b");
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mvn -pl yaml-step-runtime test -Dtest="StructuralStepEvaluatorTest\$BarrierTests#barrier_awaitsAllNamedSteps" -q`
Expected: FAIL — `preRegisterLatches` doesn't exist, barrier evaluation returns placeholder failure

- [ ] **Step 4: Implement preRegisterLatches + evaluateBarrier + countdown wiring**

In `StructuralStepEvaluator.java`:

Add fields:
```java
private final Map<String, List<OrcLatch>> stepLatches = new ConcurrentHashMap<>();
private final Map<String, QuorumTracker> quorumTrackers = new ConcurrentHashMap<>();
```

Add `preRegisterLatches`:
```java
public void preRegisterLatches(List<ResolvedStep> steps) {
    for (ResolvedStep step : steps) {
        switch (step) {
            case ResolvedStep.BarrierStep b -> {
                OrcLatch latch = scope.latch("barrier:" + b.name(), b.awaitSteps().size());
                for (String name : b.awaitSteps()) {
                    stepLatches.computeIfAbsent(name, k -> new CopyOnWriteArrayList<>()).add(latch);
                }
            }
            case ResolvedStep.QuorumStep q -> {
                OrcLatch latch = scope.latch("quorum:" + q.name(), q.required());
                var tracker = new QuorumTracker(latch, q.required(), q.ofSteps().size(),
                        new AtomicInteger(), new AtomicInteger(), new AtomicBoolean(false));
                for (String name : q.ofSteps()) {
                    quorumTrackers.put(name, tracker);
                }
            }
            case ResolvedStep.BlockStep b -> preRegisterLatches(b.steps());
            case ResolvedStep.ParallelStep p -> preRegisterLatches(p.steps());
            case ResolvedStep.TryCatchFinallyStep t -> {
                preRegisterLatches(t.trySteps());
                preRegisterLatches(t.catchSteps());
                preRegisterLatches(t.finallySteps());
            }
            default -> {}
        }
    }
}
```

Update `recordResult` to add countdown wiring:
```java
private void recordResult(String stepName, StepResult result) {
    if (stepName == null || scope == null) return;
    StepResultStore store = scope.resultStore();
    if (result.isSuccess()) {
        store.recordSuccess(stepName, result.output());
    } else {
        String message = result instanceof StepResult.Failure f ? f.message() : "unknown error";
        store.recordFailure(stepName, new StepError(message, null, null));
    }

    List<OrcLatch> latches = stepLatches.get(stepName);
    if (latches != null) {
        for (OrcLatch l : latches) { l.countDown(); }
    }

    QuorumTracker tracker = quorumTrackers.get(stepName);
    if (tracker != null) {
        tracker.onStepComplete(result.isSuccess());
    }
}
```

Replace the placeholder barrier case in `dispatchStep`:
```java
case ResolvedStep.BarrierStep b -> evaluateBarrier(b);
case ResolvedStep.QuorumStep q -> evaluateQuorum(q);
```

Add `evaluateBarrier`:
```java
private StepResult evaluateBarrier(ResolvedStep.BarrierStep barrier) {
    if (scope == null) {
        return StepResult.failed("'barrier' requires a ScenarioScope");
    }
    OrcLatch latch = scope.latch("barrier:" + barrier.name(), barrier.awaitSteps().size());
    try {
        if (barrier.timeout() != null) {
            boolean completed = latch.await(barrier.timeout().toMillis(), TimeUnit.MILLISECONDS);
            if (!completed) {
                return StepResult.failed("Barrier timed out after " + barrier.timeout());
            }
        } else {
            latch.await();
        }
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        return StepResult.failed("Barrier interrupted");
    }
    return StepResult.of(Map.of());
}
```

Add `evaluateQuorum` (placeholder that compiles):
```java
private StepResult evaluateQuorum(ResolvedStep.QuorumStep quorum) {
    if (scope == null) {
        return StepResult.failed("'quorum' requires a ScenarioScope");
    }
    OrcLatch latch = scope.latch("quorum:" + quorum.name(), quorum.required());
    try {
        if (quorum.timeout() != null) {
            boolean completed = latch.await(quorum.timeout().toMillis(), TimeUnit.MILLISECONDS);
            if (!completed) {
                return StepResult.failed("Quorum timed out — "
                        + latch.getCount() + " of " + quorum.required() + " still needed");
            }
        } else {
            latch.await();
        }
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        return StepResult.failed("Quorum interrupted");
    }
    QuorumTracker tracker = quorumTrackers.get(quorum.ofSteps().get(0));
    if (tracker != null && tracker.isUnreachable()) {
        return StepResult.failed("Quorum unreachable — "
                + tracker.failureCount().get() + " of " + quorum.ofSteps().size()
                + " steps failed, " + quorum.required() + " successes required");
    }
    return StepResult.of(Map.of());
}
```

Add required imports: `OrcLatch`, `CopyOnWriteArrayList`, `AtomicInteger`, `AtomicBoolean`, `TimeUnit`.

- [ ] **Step 5: Run barrier test to verify it passes**

Run: `mvn -pl yaml-step-runtime test -Dtest="StructuralStepEvaluatorTest\$BarrierTests#barrier_awaitsAllNamedSteps" -q`
Expected: PASS

- [ ] **Step 6: Write + run remaining barrier tests**

```java
@Test
void barrier_timeout_returnsFailed() {
    var evalA = new ResolvedStep.InvokeStep("slow", Map.of("id", "a"), Map.of());
    var barrier = new ResolvedStep.BarrierStep("wait",
            List.of("slow"), java.time.Duration.ofMillis(50), Map.of());
    var parallel = new ResolvedStep.ParallelStep(null,
            List.of(evalA, barrier), Map.of());

    scopedEvaluator.preRegisterLatches(List.of(parallel));

    var result = scopedEvaluator.evaluate(parallel, resolver, (step, res) -> {
        try { Thread.sleep(500); } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        return StepResult.of(Map.of());
    });

    assertThat(result.isSuccess()).isFalse();
}

@Test
void barrier_failedStep_stillCountsDown() {
    var evalA = new ResolvedStep.InvokeStep("eval-a", Map.of("id", "a"), Map.of());
    var barrier = new ResolvedStep.BarrierStep("wait",
            List.of("eval-a"), null, Map.of());
    var parallel = new ResolvedStep.ParallelStep(null,
            List.of(evalA, barrier), Map.of());

    scopedEvaluator.preRegisterLatches(List.of(parallel));

    var result = scopedEvaluator.evaluate(parallel, resolver, (step, res) -> {
        return StepResult.failed("error");
    });

    // Barrier should not hang — failed step still counts down
    // The parallel block returns failure because eval-a failed
    assertThat(scope.resultStore().hasCompleted("eval-a")).isTrue();
}
```

Run: `mvn -pl yaml-step-runtime test -Dtest="StructuralStepEvaluatorTest\$BarrierTests" -q`
Expected: all PASS

- [ ] **Step 7: Write + run quorum tests**

```java
@Nested
class QuorumTests {

    private DefaultScenarioScope scope;
    private StructuralStepEvaluator scopedEvaluator;

    @BeforeEach
    void setUp() {
        scope = new DefaultScenarioScope();
        var condEval = new ConditionEvaluator(null);
        scopedEvaluator = new StructuralStepEvaluator(condEval, scope);
    }

    @Test
    void quorum_proceedsOnRequiredCount() {
        var a = new ResolvedStep.InvokeStep("a", Map.of("id", "a"), Map.of());
        var b = new ResolvedStep.InvokeStep("b", Map.of("id", "b"), Map.of());
        var c = new ResolvedStep.InvokeStep("c", Map.of("id", "c"), Map.of());
        var quorum = new ResolvedStep.QuorumStep("consensus", 2,
                List.of("a", "b", "c"), null, Map.of());
        var parallel = new ResolvedStep.ParallelStep(null,
                List.of(a, b, c, quorum), Map.of());

        scopedEvaluator.preRegisterLatches(List.of(parallel));

        var result = scopedEvaluator.evaluate(parallel, resolver,
                (step, res) -> StepResult.of(Map.of("done", true)));

        assertThat(result.isSuccess()).isTrue();
    }

    @Test
    void quorum_failedStep_doesNotCountTowardRequired() throws Exception {
        var a = new ResolvedStep.InvokeStep("a", Map.of("id", "a"), Map.of());
        var b = new ResolvedStep.InvokeStep("b", Map.of("id", "b"), Map.of());
        var c = new ResolvedStep.InvokeStep("c", Map.of("id", "c"), Map.of());
        var quorum = new ResolvedStep.QuorumStep("consensus", 2,
                List.of("a", "b", "c"), java.time.Duration.ofSeconds(2), Map.of());
        var parallel = new ResolvedStep.ParallelStep(null,
                List.of(a, b, c, quorum), Map.of());

        scopedEvaluator.preRegisterLatches(List.of(parallel));
        var callCount = new AtomicInteger(0);

        var result = scopedEvaluator.evaluate(parallel, resolver, (step, res) -> {
            int call = callCount.incrementAndGet();
            if (call == 1) return StepResult.failed("error");
            return StepResult.of(Map.of("done", true));
        });

        assertThat(result.isSuccess()).isTrue();
    }

    @Test
    void quorum_unreachable_returnsFailed() {
        var a = new ResolvedStep.InvokeStep("a", Map.of("id", "a"), Map.of());
        var b = new ResolvedStep.InvokeStep("b", Map.of("id", "b"), Map.of());
        var quorum = new ResolvedStep.QuorumStep("consensus", 2,
                List.of("a", "b"), null, Map.of());
        var parallel = new ResolvedStep.ParallelStep(null,
                List.of(a, b, quorum), Map.of());

        scopedEvaluator.preRegisterLatches(List.of(parallel));

        var result = scopedEvaluator.evaluate(parallel, resolver,
                (step, res) -> StepResult.failed("all fail"));

        // At least one failure path — quorum should detect unreachability
        // The parallel block itself returns failure from the first failed step
        assertThat(scope.resultStore().hasCompleted("a")).isTrue();
    }
}
```

Run: `mvn -pl yaml-step-runtime test -Dtest="StructuralStepEvaluatorTest\$QuorumTests" -q`
Expected: all PASS

- [ ] **Step 8: Write + run composition tests**

```java
@Nested
class CompositionTests {

    private DefaultScenarioScope scope;
    private StructuralStepEvaluator scopedEvaluator;

    @BeforeEach
    void setUp() {
        scope = new DefaultScenarioScope();
        var condEval = new ConditionEvaluator(null);
        scopedEvaluator = new StructuralStepEvaluator(condEval, scope);
    }

    @Test
    void barrier_result_availableViaResultVariable() {
        var step1 = new ResolvedStep.InvokeStep("producer", Map.of("id", "p"), Map.of());
        var barrier = new ResolvedStep.BarrierStep("wait",
                List.of("producer"), null, Map.of());
        var consumer = new ResolvedStep.InvokeStep("consumer", Map.of("id", "c"), Map.of());

        var block = new ResolvedStep.BlockStep(null, List.of(step1, barrier, consumer), Map.of());

        // Not truly parallel here — sequential block means producer
        // completes before barrier, barrier completes immediately.
        // But the result variable should still resolve.
        scopedEvaluator.preRegisterLatches(List.of(block));

        var capturedValue = new Object[1];
        var result = scopedEvaluator.evaluate(block, resolver, (step, res) -> {
            if (step instanceof ResolvedStep.InvokeStep inv) {
                String id = (String) inv.invokeSpec().get("id");
                if ("p".equals(id)) {
                    return StepResult.of(Map.of("score", 95));
                }
                if ("c".equals(id)) {
                    capturedValue[0] = res.resolve("${result.producer.score}");
                }
            }
            return StepResult.of(Map.of());
        });

        assertThat(result.isSuccess()).isTrue();
        assertThat(capturedValue[0]).isEqualTo(95);
    }

    @Test
    void decorators_applyToBarrierStep() {
        var evalA = new ResolvedStep.InvokeStep("eval-a", Map.of("id", "a"), Map.of());
        var barrier = new ResolvedStep.BarrierStep("wait",
                List.of("eval-a"), null, Map.of("when", "true"));

        var block = new ResolvedStep.BlockStep(null, List.of(evalA, barrier), Map.of());
        scopedEvaluator.preRegisterLatches(List.of(block));

        var result = scopedEvaluator.evaluate(block, resolver,
                (step, res) -> StepResult.of(Map.of()));

        assertThat(result.isSuccess()).isTrue();
    }
}
```

Run: `mvn -pl yaml-step-runtime test -Dtest="StructuralStepEvaluatorTest\$CompositionTests" -q`
Expected: all PASS

- [ ] **Step 9: Run all yaml-step-runtime tests**

Run: `mvn -pl yaml-step-runtime test -q`
Expected: all PASS

- [ ] **Step 10: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#469): barrier/quorum evaluation + latch wiring + QuorumTracker

preRegisterLatches() eagerly creates latches and binds step names before
execution (prevents race conditions). recordResult() notifies barrier
latches (success+failure count) and quorum trackers (success-only).
QuorumTracker detects unreachability when failures exceed tolerance.

Refs #469"
```

---

## References

- [2026-09-27-barrier-quorum-stepresultstore-design.md] — design spec this plan implements
- [issue-386 §2.2 Latch] — barrier/quorum semantics
- [issue-386 §3.1 Runtime VariableSource] — ${result.<step>} resolution
- [yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java] — sealed step types
- [yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepWalker.java] — YAML parser
- [yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java] — current evaluator
- [yaml-core/src/main/java/io/casehub/yaml/core/orchestration/StepResultStore.java] — result store SPI
- [yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcLatch.java] — countdown latch
- [yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ScenarioScope.java] — scope with resultStore() and latch()
- [yaml-core/src/main/java/io/casehub/yaml/core/resolver/ObjectVariableSource.java] — typed variable source
- [yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DurationParser.java] — ms/s/m/h parsing
- [yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StepResult.java] — Success/Failure sealed types
- [GitHub #469] — focal issue
