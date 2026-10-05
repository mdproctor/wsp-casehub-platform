# Barrier/Quorum Sugar + StepResultStore Wiring — Design Spec

## Overview

Wire barrier and quorum as structural step sugar over `OrcLatch`, integrate `StepResultStore` recording into `StructuralStepEvaluator`, and enable `${result.<step>}` variable resolution via `ObjectVariableSource`. Together these transform the step runtime from fire-and-forget execution into a coordination engine where steps share results and synchronize.

**Module scope:** `yaml-step-runtime` (evaluator, walker, resolved step types). No changes to `yaml-core` — all primitives (`OrcLatch`, `StepResultStore`, `DefaultStepResultStore`, `ExecutionScope`, `ObjectVariableSource`, `VariableResolver.withObjectScope`) already exist and are tested.

## 1. Step Name Propagation

### 1.1 ResolvedStep gains `name()`

Add a default method to the sealed interface:

```java
public sealed interface ResolvedStep {
    Map<String, Object> decorators();
    default String name() { return null; }
    // ... permits unchanged except adding BarrierStep, QuorumStep
}
```

Each record variant adds an optional `String name` field. The compact constructor stores it (nullable). `StepWalker.resolveOne()` extracts the `step:` key value and passes it as the `name` parameter instead of discarding it.

### 1.2 Duplicate name validation in StepWalker

Thread a `Set<String> seenNames` through `StepWalker.resolve()`:

```java
private static List<ResolvedStep> resolve(
        List<Map<String, Object>> steps, StepCatalog catalog,
        int depth, String path, Set<String> seenNames) {
```

In `resolveOne`, after extracting the step name:
```java
if (name != null && !seenNames.add(name)) {
    throw new IllegalArgumentException(
        path + " → Step " + index + ": duplicate step name '" + name + "'");
}
```

The recursive structure means duplicates are caught across all nesting levels — block, parallel, try, barrier/quorum bodies. This matches the flat `StepResultStore` namespace.

## 2. StepResultStore Recording

### 2.1 Recording in StructuralStepEvaluator

After `dispatchStep` returns, if the step has a name and the evaluator has a scope, record the result:

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

### 2.2 Recording logic

```java
private void recordResult(String stepName, StepResult result) {
    if (stepName == null || scope == null) return;
    StepResultStore store = scope.resultStore();
    if (result.isSuccess()) {
        Map<String, Object> output = result instanceof StepResult.Success s
                ? s.output() : Map.of();
        store.recordSuccess(stepName, output);
    } else {
        String message = result instanceof StepResult.Failure f
                ? f.message() : "unknown error";
        store.recordFailure(stepName, new StepError(message, null, null));
    }
}
```

Recording happens **after decorators** — the final result (including retry outcomes, timeout failures, etc.) is what gets recorded. The step name on the outer step is what matters; inner structural steps inside a decorator chain don't independently record.

### 2.3 Barrier/quorum countdown integration

For barrier: step completion (success OR failure) calls `latch.countDown()`. Recording and countdown are both driven by the same event — step completion. The evaluator records the result, and the latch registered for the step name counts down.

For quorum: only successful completions count toward the threshold. The quorum evaluator inspects the result before counting.

## 3. `${result.<step>}` Variable Resolution

### 3.1 Registration in evaluator

The evaluator creates an `ObjectVariableSource` for the `result` prefix in its constructor (when a scope is present) and wraps the caller's resolver on every `evaluate()` call. `withObjectScope` is cheap — it's a constructor call, not a map copy.

```java
private final ObjectVariableSource resultSource; // null when no scope

// In constructor:
this.resultSource = (scope != null) ? buildResultSource(scope.resultStore()) : null;

private VariableResolver withResultScope(VariableResolver resolver) {
    return resultSource != null ? resolver.withObjectScope("result", resultSource) : resolver;
}
```

The `ObjectVariableSource` resolves step names from the store. It returns a **composite Map** that includes both the step's output fields and a nested `error` key. This allows `VariableResolver`'s `FieldDriller` to navigate `${result.risk-eval.error.message}` naturally — the source returns the composite Map for `risk-eval`, and drilling handles `.error.message`.

```java
private static ObjectVariableSource buildResultSource(StepResultStore store) {
    return name -> {
        if (!store.hasCompleted(name)) return null;

        Map<String, Object> output = store.result(name);
        StepError err = store.error(name);

        if (output == null && err == null) return null;

        // Failed step with no output: return null (per issue-386 §3.1)
        // Callers use ${result.<step>.error} to access failure details
        if (output == null) {
            // Return a Map with only the error key — ${result.<step>} is
            // still non-null (step completed) but has no output fields.
            // ${result.<step>.error.message} drills through naturally.
            return Map.of("error", Map.of(
                    "message", err.message() != null ? err.message() : "",
                    "exceptionClass", err.exceptionClass() != null ? err.exceptionClass() : "",
                    "stackTrace", err.stackTrace() != null ? err.stackTrace() : ""));
        }

        // Successful step: return output Map, with error = null
        // ${result.<step>.score} drills into output
        // ${result.<step>.error} returns null (success)
        if (err == null) return output;

        // Edge case: step has both output and error (shouldn't happen
        // with current StepResultStore contract, but defensive)
        var composite = new java.util.HashMap<>(output);
        composite.put("error", Map.of(
                "message", err.message() != null ? err.message() : "",
                "exceptionClass", err.exceptionClass() != null ? err.exceptionClass() : "",
                "stackTrace", err.stackTrace() != null ? err.stackTrace() : ""));
        return composite;
    };
}
```

**Resolution semantics (corrected per issue-386 §3.1):**
- **Step not completed:** `${result.<step>}` → null (ObjectVariableSource returns null)
- **Step succeeded:** `${result.<step>}` → output Map (typed pass-through), `${result.<step>.error}` → null
- **Step failed:** `${result.<step>}` → Map with `error` key only, `${result.<step>.error.message}` drills through
- **Guard pattern:** `when: ${result.risk-eval.error} != null` correctly tests for failure

The `ObjectVariableSource` resolves the step name portion and returns the result map. `VariableResolver.drillFields()` handles nested field navigation (`${result.risk-eval.score}` → resolve `risk-eval` → drill `score`).

### 3.2 Resolution semantics

Per the spec (§3.1):
- **Sequential steps:** `${result.<step>}` resolves from any completed predecessor
- **Concurrent siblings:** Not available — use barrier, signal, or channel for cross-step data flow. Referencing an incomplete step returns null (deferred prefix handling)
- **Sole-reference typed pass-through:** `${result.risk-eval}` as the entire value returns the raw `Map<String, Object>`. Embedded in a string (`"score: ${result.risk-eval.score}"`) interpolates via toString
- **Error access:** `${result.risk-eval.error}` returns the StepError as a Map, `${result.risk-eval.error.message}` drills to the message string

## 4. Barrier Step Type

### 4.1 YAML syntax

```yaml
- step: await-all
  barrier:
    await: [momentum-eval, risk-eval, compliance-check]
    timeout: 30s
```

### 4.2 ResolvedStep variant

```java
record BarrierStep(
        String name,
        List<String> awaitSteps,
        Duration timeout,
        Map<String, Object> decorators) implements ResolvedStep {

    public BarrierStep {
        awaitSteps = List.copyOf(awaitSteps);
        decorators = Map.copyOf(decorators);
    }
}
```

### 4.3 StepWalker parsing

Recognise `barrier` as a structural type keyword (alongside block, parallel, try, select). Extract `await` (required list of step name strings) and `timeout` (optional duration string, parsed via `DurationParser`). Validate that `await` is non-empty.

Step name cross-validation uses a two-pass approach in StepWalker, per issue-386's type safety principle ("every construct must be parse-time-validatable"):

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

This catches typos like `[momentun-eval]` at parse time rather than at evaluation time.

### 4.4 Evaluation

```java
private StepResult evaluateBarrier(ResolvedStep.BarrierStep barrier,
                                    VariableResolver resolver) {
    if (scope == null) {
        return StepResult.failed("'barrier' requires a ScenarioScope");
    }
    OrcLatch latch = scope.latch("barrier:" + barrier.name(),
                                  barrier.awaitSteps().size());
    // Latch countdown is driven by step result recording —
    // each awaited step's completion triggers countDown()
    // (wired via a recording callback, see §4.5)

    try {
        if (barrier.timeout() != null) {
            boolean completed = latch.await(
                    barrier.timeout().toMillis(), TimeUnit.MILLISECONDS);
            if (!completed) {
                return StepResult.failed("Barrier timed out after "
                        + barrier.timeout());
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

### 4.5 Countdown wiring

**Race condition prevention:** Barrier/quorum latches and their step-name bindings must be registered BEFORE any of the awaited steps can complete. If a parallel step completes before the barrier evaluator runs, the countdown would fire with no latch — a lost countdown. This matches the spec's §Lifecycle: "created eagerly at scenario load time."

The solution: **eager latch registration during step resolution**, not during evaluation.

`StructuralStepEvaluator` gains a setup phase. When `evaluate()` is called for the first time (or when a new set of resolved steps is loaded), it walks the step tree to find barrier/quorum steps and pre-registers their latches and bindings:

```java
private final Map<String, List<OrcLatch>> stepLatches = new ConcurrentHashMap<>();
private final Map<String, QuorumTracker> quorumTrackers = new ConcurrentHashMap<>();

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
            default -> {} // leaf steps, if/match — no nested latches
        }
    }
}
```

The caller (whoever builds the evaluator and kicks off evaluation) calls `preRegisterLatches(resolvedSteps)` once after resolution and before execution begins. This guarantees all latches exist and are bound to step names before any step can complete.

`recordResult` then notifies these pre-registered bindings:

```java
private void recordResult(String stepName, StepResult result) {
    if (stepName == null || scope == null) return;
    // ... record to store (§2.2) ...

    // Notify waiting barrier latches (success OR failure counts)
    List<OrcLatch> latches = stepLatches.get(stepName);
    if (latches != null) {
        for (OrcLatch l : latches) {
            l.countDown();
        }
    }

    // Notify quorum trackers (only success counts toward threshold)
    QuorumTracker tracker = quorumTrackers.get(stepName);
    if (tracker != null) {
        tracker.onStepComplete(result.isSuccess());
    }
}
```

Barrier evaluation simply retrieves the pre-created latch and blocks:
```java
OrcLatch latch = scope.latch("barrier:" + barrier.name(), barrier.awaitSteps().size());
// latch and bindings already exist from preRegisterLatches
latch.await();
```

## 5. Quorum Step Type

### 5.1 YAML syntax

```yaml
- step: consensus
  quorum:
    required: 2
    of: [strategy-a, strategy-b, strategy-c]
    timeout: 15s
```

### 5.2 ResolvedStep variant

```java
record QuorumStep(
        String name,
        int required,
        List<String> ofSteps,
        Duration timeout,
        Map<String, Object> decorators) implements ResolvedStep {

    public QuorumStep {
        if (required <= 0) throw new IllegalArgumentException("required must be > 0");
        if (required > ofSteps.size()) throw new IllegalArgumentException(
                "required (" + required + ") > of (" + ofSteps.size() + ")");
        ofSteps = List.copyOf(ofSteps);
        decorators = Map.copyOf(decorators);
    }
}
```

### 5.3 StepWalker parsing

Recognise `quorum` as a structural keyword. Extract `required` (int), `of` (list of step name strings), `timeout` (optional duration). Validate `required > 0` and `required <= of.size()` at parse time.

### 5.4 Evaluation

Quorum differs from barrier: **only successful completions count** toward the threshold. If failures reduce surviving steps below `required`, throw `QuorumUnreachableException`.

```java
private StepResult evaluateQuorum(ResolvedStep.QuorumStep quorum,
                                   VariableResolver resolver) {
    if (scope == null) {
        return StepResult.failed("'quorum' requires a ScenarioScope");
    }
    OrcLatch latch = scope.latch("quorum:" + quorum.name(), quorum.required());

    // Register a success-only countdown — failures don't count
    registerQuorumLatch(quorum.ofSteps(), latch, quorum.required());

    try {
        if (quorum.timeout() != null) {
            boolean completed = latch.await(
                    quorum.timeout().toMillis(), TimeUnit.MILLISECONDS);
            if (!completed) {
                return StepResult.failed("Quorum timed out — "
                        + latch.getCount() + " of " + quorum.required()
                        + " still needed");
            }
        } else {
            latch.await();
        }
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        return StepResult.failed("Quorum interrupted");
    }

    // Check if latch was released due to unreachability (too many failures)
    QuorumTracker tracker = quorumTrackers.get(quorum.ofSteps().get(0));
    if (tracker != null && tracker.isUnreachable()) {
        return StepResult.failed("Quorum unreachable — "
                + tracker.failureCount().get() + " of " + quorum.ofSteps().size()
                + " steps failed, " + quorum.required() + " successes required");
    }
    return StepResult.of(Map.of());
}
```

The quorum latch registration tracks failures separately. When a step fails, the quorum evaluator checks: `failedCount > (totalSteps - required)`. If so, the quorum can never be satisfied — it throws `QuorumUnreachableException` (or returns failure) and releases the latch to unblock.

This requires a slightly different wiring than barrier. Instead of the simple `stepLatches` map, quorum uses a `QuorumTracker`:

```java
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
            while (latch.getCount() > 0) latch.countDown();
        }
    }

    boolean isUnreachable() {
        return unreachable.get();
    }
}
```

## 6. StepWalker Changes Summary

### New structural keywords

Add `"barrier"` and `"quorum"` to the structural type recognition in `resolveOne()`, alongside `block`, `parallel`, `try`, `select`.

### Companion keys

- `barrier` → none (self-contained: `await` and `timeout` are subkeys of the barrier map)
- `quorum` → none (self-contained: `required`, `of`, `timeout` are subkeys)

### RESERVED_KEYS update

No change — `barrier` and `quorum` are structural types, not decorator keys.

### STRUCTURAL_COMPANIONS update

No change — barrier/quorum are self-contained maps, not companion keys.

## 7. Test Plan

### yaml-step-runtime tests

**StepResultStore recording (StructuralStepEvaluator):**
- `evaluate_namedStep_recordsSuccessToStore`
- `evaluate_namedStep_recordsFailureToStore`
- `evaluate_unnamedStep_doesNotRecord`
- `evaluate_noScope_doesNotRecord`
- `evaluate_nestedNamedSteps_allRecorded`
- `evaluate_parallelNamedSteps_allRecordedConcurrently`

**`${result.<step>}` resolution:**
- `resultVariable_completedStep_resolvesOutput`
- `resultVariable_failedStep_resolvesError`
- `resultVariable_nestedField_drillsIntoMap`
- `resultVariable_uncompletedStep_returnsNull`
- `resultVariable_soleReference_returnsTypedMap`
- `resultVariable_interpolated_returnsString`

**Barrier:**
- `barrier_awaitsAllNamedSteps`
- `barrier_stepCompletionOrder_doesNotMatter`
- `barrier_timeout_returnsFailed`
- `barrier_failedStep_stillCountsDown`
- `barrier_emptyAwaitList_throwsAtParseTime`

**Quorum:**
- `quorum_proceedsOnRequiredCount`
- `quorum_doesNotWaitForAll`
- `quorum_failedStep_doesNotCountTowardRequired`
- `quorum_unreachable_returnsFailed`
- `quorum_requiredGreaterThanOf_throwsAtParseTime`
- `quorum_timeout_returnsFailed`

**StepWalker parsing:**
- `walker_parsesBarrierStep`
- `walker_parsesQuorumStep`
- `walker_duplicateStepName_throws`
- `walker_barrierWithoutAwait_throws`
- `walker_quorumRequiredExceedsOf_throws`
- `walker_barrierAwaitsUnknownStep_throws`
- `walker_quorumReferencesUnknownStep_throws`

**Composition:**
- `parallel_then_barrier_executesSequentially`
- `parallel_with_quorum_proceedsOnMajority`
- `barrier_result_availableViaResultVariable`
- `decorators_applyToBarrierStep`
- `decorators_applyToQuorumStep`

## References

- issue-386 §2.2 Latch — barrier/quorum semantics, test case list
- issue-386 §3.1 Runtime VariableSource — `${result.<step>}` resolution, ObjectVariableSource, sole-reference typed pass-through
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/StepResultStore.java` — SPI
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultStepResultStore.java` — ConcurrentHashMap impl
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcLatch.java` — countdown interface
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcLatch.java` — j.u.c.CountDownLatch impl
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ScenarioScope.java` — `resultStore()`, `latch()`
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/ObjectVariableSource.java` — typed variable source
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java:48` — `withObjectScope()`
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java` — current evaluator
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepWalker.java` — YAML parser
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java` — sealed step types
