# Canonical Runner + Inert Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #828 — WS-1: Canonical runner + finish inert features
**Issue group:** #828 (child of epic #827)

**Goal:** Move PlaybookRunnerCore to main code with ExecutionScope and expression engine wired, fix condition injection/Norway, implement on-error and transform decorators, enable captures at all nesting depths.

**Architecture:** Runner relocates from yaml-test-core to yaml-step-runtime (new `io.casehub.yaml.step.runner` package). Simulation is abstracted behind a `SimulationActivator` functional interface to avoid polluting yaml-step-runtime's classpath. DecoratorChain configuration consolidated into a `DecoratorConfig` record. ConditionEvaluator gains a safe 3-arg evaluation method with variables bound as data.

**Tech Stack:** Java 21+, yaml-core (zero-dep), yaml-step-runtime, yaml-test-core, playbook-runner (Quarkus CDI)

## Global Constraints

- `yaml-core` remains zero-dependency — no Quarkus, no platform-api imports
- `yaml-step-runtime` must NOT gain compile dependencies on simulation modules
- Pre-release platform: breaking changes are acceptable
- All primitives use j.u.c locks or lock-free atomics — never `synchronized`
- TDD: write failing test, verify failure, implement, verify pass, commit

---

## Batch 1: Condition safety (P33)

Foundation — every other batch depends on conditions evaluating safely.

### Task 1: Restrict Truthiness to strict boolean and update ConditionEvaluator

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/condition/Truthiness.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/condition/ConditionEvaluator.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java:135` (promote `isSoleReference` to public static)
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/condition/TruthinessTest.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/condition/ConditionEvaluatorTest.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/condition/ConditionDelegate.java`

**Interfaces:**
- Produces: `ConditionDelegate` — `boolean evaluate(String expression, Map<String, Object> bindings)`
- Produces: `ConditionEvaluator.evaluate(String condition, VariableResolver resolver, String context)` — the safe 3-arg method
- Produces: `VariableResolver.isSoleReference(String s)` — promoted to public static

- [ ] **Step 1: Write failing tests for strict Truthiness**

In `TruthinessTest.java`, add tests that assert `yes`, `no`, `on`, `off`, `y`, `n`, `1`, `0` all throw `IllegalArgumentException`. Only `true` and `false` should return boolean values.

```java
@Test
void norway_values_throw() {
    assertThrows(IllegalArgumentException.class, () -> Truthiness.isTruthy("yes"));
    assertThrows(IllegalArgumentException.class, () -> Truthiness.isTruthy("no"));
    assertThrows(IllegalArgumentException.class, () -> Truthiness.isTruthy("on"));
    assertThrows(IllegalArgumentException.class, () -> Truthiness.isTruthy("off"));
    assertThrows(IllegalArgumentException.class, () -> Truthiness.isTruthy("y"));
    assertThrows(IllegalArgumentException.class, () -> Truthiness.isTruthy("n"));
    assertThrows(IllegalArgumentException.class, () -> Truthiness.isTruthy("1"));
    assertThrows(IllegalArgumentException.class, () -> Truthiness.isTruthy("0"));
}

@Test
void strict_boolean_still_works() {
    assertTrue(Truthiness.isTruthy("true"));
    assertFalse(Truthiness.isTruthy("false"));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-core test -Dtest=TruthinessTest -DfailIfNoTests=false --batch-mode`
Expected: `norway_values_throw` FAILS (currently these return true/false)

- [ ] **Step 3: Restrict Truthiness**

Replace the switch in `Truthiness.isTruthy()`:

```java
public static boolean isTruthy(String value) {
    return switch (value) {
        case "true" -> true;
        case "false" -> false;
        default -> throw new IllegalArgumentException(
                "Condition resolved to '" + value
                + "' which is not a boolean literal. "
                + "Expected: true/false. Use an expression engine for complex conditions.");
    };
}
```

Note: removed `toLowerCase(Locale.ROOT)` — strict literal match only.

- [ ] **Step 4: Run Truthiness tests to verify they pass**

Run: `mvn -pl yaml-core test -Dtest=TruthinessTest -DfailIfNoTests=false --batch-mode`
Expected: ALL PASS

- [ ] **Step 5: Create ConditionDelegate functional interface**

Create `yaml-core/src/main/java/io/casehub/yaml/core/condition/ConditionDelegate.java`:

```java
package io.casehub.yaml.core.condition;

import java.util.Map;

@FunctionalInterface
public interface ConditionDelegate {
    boolean evaluate(String expression, Map<String, Object> bindings);
}
```

- [ ] **Step 6: Promote isSoleReference to public static on VariableResolver**

In `VariableResolver.java`, change line 135 from `private static boolean isSoleReference` to `public static boolean isSoleReference`.

- [ ] **Step 7: Write failing tests for safe ConditionEvaluator**

In `ConditionEvaluatorTest.java`, add tests for the new 3-arg method:

```java
@Test
void literal_true_evaluates_without_delegate() {
    var eval = new ConditionEvaluator(null);
    assertTrue(eval.evaluate("true", new VariableResolver(Map.of(), Set.of()), "test"));
}

@Test
void literal_false_evaluates_without_delegate() {
    var eval = new ConditionEvaluator(null);
    assertFalse(eval.evaluate("false", new VariableResolver(Map.of(), Set.of()), "test"));
}

@Test
void sole_variable_reference_resolved_to_boolean() {
    var resolver = new VariableResolver(Map.of(), Set.of())
            .withObjectScope("var", name -> "flag".equals(name) ? Boolean.TRUE : null);
    var eval = new ConditionEvaluator(null);
    assertTrue(eval.evaluate("${var.flag}", resolver, "test"));
}

@Test
void expression_delegates_with_bindings() {
    ConditionDelegate delegate = (expr, bindings) -> {
        return "x > 5".equals(expr) && ((Integer) ((Map<?,?>) bindings.get("var")).get("x")) > 5;
    };
    var resolver = new VariableResolver(Map.of(), Set.of())
            .withObjectScope("var", name -> "x".equals(name) ? 10 : null)
            .withExpressionContext("var", Map.of("x", 10));
    var eval = new ConditionEvaluator(delegate);
    assertTrue(eval.evaluate("x > 5", resolver, "test"));
}

@Test
void injection_attempt_goes_to_expression_engine_not_code() {
    ConditionDelegate delegate = (expr, bindings) -> {
        // The raw expression text, not substituted values
        return expr.equals("${var.input} == true");
    };
    var resolver = new VariableResolver(Map.of(), Set.of())
            .withObjectScope("var", name -> "input".equals(name) ? "Runtime.exec('rm -rf /')" : null);
    var eval = new ConditionEvaluator(delegate);
    // The variable value is in bindings, not substituted into expression text
    assertFalse(eval.evaluate("${var.input} == true", resolver, "test"));
}

@Test
void no_delegate_throws_for_non_literal() {
    var eval = new ConditionEvaluator(null);
    var resolver = new VariableResolver(Map.of(), Set.of());
    assertThrows(ConditionEvaluationException.class,
            () -> eval.evaluate("x > 5", resolver, "test"));
}
```

- [ ] **Step 8: Run tests to verify they fail**

Run: `mvn -pl yaml-core test -Dtest=ConditionEvaluatorTest -DfailIfNoTests=false --batch-mode`
Expected: New tests FAIL (3-arg method doesn't exist yet)

- [ ] **Step 9: Implement safe ConditionEvaluator**

Change the `ConditionEvaluator` constructor to accept `ConditionDelegate` instead of `Function<String, Boolean>`. Remove the old `evaluate(String resolved)` method. Add the new 3-arg method:

```java
package io.casehub.yaml.core.condition;

import io.casehub.yaml.core.resolver.VariableResolver;

public final class ConditionEvaluator {

    private final ConditionDelegate expressionDelegate;

    public ConditionEvaluator(ConditionDelegate expressionDelegate) {
        this.expressionDelegate = expressionDelegate;
    }

    public boolean evaluate(String condition, VariableResolver resolver, String context) {
        if ("true".equals(condition)) return true;
        if ("false".equals(condition)) return false;

        if (VariableResolver.isSoleReference(condition)) {
            Object value = resolver.resolve(condition);
            if (value instanceof Boolean b) return b;
            if (value instanceof String s) {
                if ("true".equals(s)) return true;
                if ("false".equals(s)) return false;
            }
        }

        if (expressionDelegate == null) {
            throw new ConditionEvaluationException(
                    "Cannot evaluate '" + condition + "' — no expression engine configured", null);
        }
        return expressionDelegate.evaluate(condition, resolver.buildExpressionContext());
    }
}
```

- [ ] **Step 10: Run all yaml-core tests**

Run: `mvn -pl yaml-core test --batch-mode`
Expected: ALL PASS. Fix any tests that relied on the old `evaluate(String)` method or broad Truthiness values.

- [ ] **Step 11: Commit**

```bash
git add yaml-core/
git commit -m "feat(#828): restrict Truthiness to strict boolean, add safe ConditionEvaluator

P33: Variables bound as data to compiled expressions, never substituted
into expression text. Truthiness accepts only literal true/false —
fixes Norway problem. Old unsafe evaluate(String) removed.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: Update DecoratorChain and StructuralStepEvaluator condition callers

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java`
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/DecoratorConditionTest.java`

**Interfaces:**
- Consumes: `ConditionEvaluator.evaluate(String, VariableResolver, String)` from Task 1

- [ ] **Step 1: Write failing test for safe condition routing in wrapWhen**

Create `DecoratorConditionTest.java`:

```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.core.condition.ConditionDelegate;
import io.casehub.yaml.core.condition.ConditionEvaluator;
import io.casehub.yaml.core.resolver.VariableResolver;
import io.casehub.yaml.core.runtime.SpeedMultiplier;
import io.casehub.yaml.plugin.api.Result;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

class DecoratorConditionTest {

    @Test
    void when_guard_passes_variables_as_bindings_not_substitution() {
        ConditionDelegate delegate = (expr, bindings) -> {
            assertEquals("${var.flag}", expr);
            assertNotNull(bindings.get("var"));
            return true;
        };
        var evaluator = new ConditionEvaluator(delegate);
        var chain = new DecoratorChain(evaluator, SpeedMultiplier.identity());

        var resolver = new VariableResolver(Map.of(), Set.of())
                .withObjectScope("var", name -> "flag".equals(name) ? "maybe" : null)
                .withExpressionContext("var", Map.of("flag", "maybe"));

        DecoratedExecution inner = ctx -> Result.of(Map.of("ran", true));
        DecoratedExecution wrapped = chain.apply(
                Map.of("when", "${var.flag}"), inner);

        Result result = wrapped.execute(new StepContext(resolver));
        assertTrue(result.isSuccess());
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl yaml-step-runtime test -Dtest=DecoratorConditionTest -DfailIfNoTests=false --batch-mode`
Expected: FAIL (DecoratorChain still calls old `resolveCondition` with resolve-then-evaluate)

- [ ] **Step 3: Update DecoratorChain.resolveCondition**

Change `resolveCondition` to delegate to the new 3-arg ConditionEvaluator method:

```java
private boolean resolveCondition(String condition, VariableResolver resolver, String context) {
    return conditionEvaluator.evaluate(condition, resolver, context);
}
```

This propagates to all callers: `wrapWhen`, `wrapLoop` (until), `wrapFrom` (filter, until), `publishToChannel` (if).

- [ ] **Step 4: Update StructuralStepEvaluator condition callers**

In `evaluateIfElse`, change:
```java
String resolved = ctx.resolver().resolveString(ifElse.condition(), "if-condition");
condition = conditionEvaluator.evaluate(resolved);
```
to:
```java
condition = conditionEvaluator.evaluate(ifElse.condition(), ctx.resolver(), "if-condition");
```

In `evaluateMatch`, change guard evaluation similarly:
```java
String resolvedGuard = ctx.resolver().resolveString(mc.guard(), "match-guard");
if (!conditionEvaluator.evaluate(resolvedGuard)) {
```
to:
```java
if (!conditionEvaluator.evaluate(mc.guard(), ctx.resolver(), "match-guard")) {
```

- [ ] **Step 5: Run all yaml-step-runtime tests**

Run: `mvn -pl yaml-step-runtime test --batch-mode`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#828): migrate condition callers to safe 3-arg evaluation

DecoratorChain.resolveCondition and StructuralStepEvaluator condition
sites now use ConditionEvaluator.evaluate(condition, resolver, context).
Variables bound as data at every call site.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 2: DecoratorConfig, on-error handler, transform (P34, P35)

### Task 3: Introduce DecoratorConfig and implement on-error handler

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorConfig.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StepLookup.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StepEvaluator.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StepIndexBuilder.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/TransformDelegate.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java`
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/OnErrorHandlerTest.java`
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/StepIndexBuilderTest.java`

**Interfaces:**
- Produces: `DecoratorConfig` record — consolidated constructor params for DecoratorChain
- Produces: `StepLookup` — `ResolvedStep resolve(String stepName)`
- Produces: `StepEvaluator` — `Result evaluate(ResolvedStep step, StepContext ctx, StepRunner runner)`
- Produces: `StepIndexBuilder.build(List<ResolvedStep>)` → `Map<String, ResolvedStep>`
- Produces: `TransformDelegate` — `Map<String, Object> transform(String expression, Map<String, Object> input)`

- [ ] **Step 1: Create new types (DecoratorConfig, StepLookup, StepEvaluator, TransformDelegate)**

`DecoratorConfig.java`:
```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.core.condition.ConditionEvaluator;
import io.casehub.yaml.core.orchestration.ExecutionScope;
import io.casehub.yaml.core.runtime.SpeedMultiplier;

public record DecoratorConfig(
        ConditionEvaluator conditionEvaluator,
        SpeedMultiplier speedMultiplier,
        ExecutionScope scope,
        StepLookup stepLookup,
        StepEvaluator handlerEvaluator,
        StepRunner handlerRunner,
        TransformDelegate transformDelegate
) {}
```

`StepLookup.java`:
```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.step.catalog.ResolvedStep;

@FunctionalInterface
public interface StepLookup {
    ResolvedStep resolve(String stepName);
}
```

`StepEvaluator.java`:
```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.plugin.api.Result;
import io.casehub.yaml.step.catalog.ResolvedStep;

@FunctionalInterface
public interface StepEvaluator {
    Result evaluate(ResolvedStep step, StepContext ctx, StepRunner runner);
}
```

`TransformDelegate.java`:
```java
package io.casehub.yaml.step.eval;

import java.util.Map;

@FunctionalInterface
public interface TransformDelegate {
    Map<String, Object> transform(String expression, Map<String, Object> input);
}
```

- [ ] **Step 2: Create StepIndexBuilder with test**

`StepIndexBuilder.java`:
```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.step.catalog.ResolvedStep;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class StepIndexBuilder {

    private StepIndexBuilder() {}

    public static Map<String, ResolvedStep> build(List<ResolvedStep> steps) {
        Map<String, ResolvedStep> index = new LinkedHashMap<>();
        indexRecursive(steps, index);
        return Map.copyOf(index);
    }

    private static void indexRecursive(List<ResolvedStep> steps, Map<String, ResolvedStep> index) {
        for (ResolvedStep step : steps) {
            if (step.name() != null) {
                index.put(step.name(), step);
            }
            switch (step) {
                case ResolvedStep.BlockStep b -> indexRecursive(b.steps(), index);
                case ResolvedStep.ParallelStep p -> indexRecursive(p.steps(), index);
                case ResolvedStep.RaceStep r -> indexRecursive(r.branches(), index);
                case ResolvedStep.TryCatchFinallyStep t -> {
                    indexRecursive(t.trySteps(), index);
                    indexRecursive(t.catchSteps(), index);
                    indexRecursive(t.finallySteps(), index);
                }
                case ResolvedStep.IfElseStep i -> {
                    indexRecursive(i.thenSteps(), index);
                    indexRecursive(i.elseSteps(), index);
                }
                default -> {}
            }
        }
    }
}
```

`StepIndexBuilderTest.java`:
```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.step.catalog.ResolvedStep;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

class StepIndexBuilderTest {

    @Test
    void indexes_named_steps_recursively() {
        var inner = new ResolvedStep.PluginStep("inner-step", "action", Map.of(), Map.of());
        var block = new ResolvedStep.BlockStep("outer-block",
                List.of(inner), Map.of());
        var top = new ResolvedStep.PluginStep("top-step", "action", Map.of(), Map.of());

        var index = StepIndexBuilder.build(List.of(top, block));

        assertEquals(3, index.size());
        assertSame(top, index.get("top-step"));
        assertSame(block, index.get("outer-block"));
        assertSame(inner, index.get("inner-step"));
    }

    @Test
    void unnamed_steps_not_indexed() {
        var unnamed = new ResolvedStep.PluginStep(null, "action", Map.of(), Map.of());
        var index = StepIndexBuilder.build(List.of(unnamed));
        assertTrue(index.isEmpty());
    }

    @Test
    void duplicate_names_last_wins() {
        var first = new ResolvedStep.PluginStep("dup", "action-a", Map.of(), Map.of());
        var second = new ResolvedStep.PluginStep("dup", "action-b", Map.of(), Map.of());
        var index = StepIndexBuilder.build(List.of(first, second));
        assertEquals("action-b", ((ResolvedStep.PluginStep) index.get("dup")).actionName());
    }
}
```

- [ ] **Step 3: Run StepIndexBuilder test**

Run: `mvn -pl yaml-step-runtime test -Dtest=StepIndexBuilderTest -DfailIfNoTests=false --batch-mode`
Expected: ALL PASS

- [ ] **Step 4: Write failing on-error handler test**

`OnErrorHandlerTest.java`:
```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.core.condition.ConditionEvaluator;
import io.casehub.yaml.core.resolver.VariableResolver;
import io.casehub.yaml.core.runtime.SpeedMultiplier;
import io.casehub.yaml.plugin.api.Result;
import io.casehub.yaml.step.catalog.ResolvedStep;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

class OnErrorHandlerTest {

    private DecoratorChain chainWithHandler(ResolvedStep handler) {
        StepLookup lookup = name -> "recovery".equals(name) ? handler : null;
        StepEvaluator evaluator = (step, ctx, runner) -> runner.run(step, ctx.resolver());
        var config = new DecoratorConfig(
                new ConditionEvaluator(null), SpeedMultiplier.identity(), null,
                lookup, evaluator, (step, resolver) -> Result.of(Map.of("recovered", true)),
                null);
        return new DecoratorChain(config);
    }

    @Test
    void handler_runs_on_failure_and_recovers() {
        var handler = new ResolvedStep.PluginStep("recovery", "recovery-action",
                Map.of(), Map.of());
        var chain = chainWithHandler(handler);

        DecoratedExecution failing = ctx -> Result.failed("boom");
        DecoratedExecution wrapped = chain.apply(
                Map.of("on-error", "recovery"), failing);

        var resolver = new VariableResolver(Map.of(), Set.of());
        Result result = wrapped.execute(new StepContext(resolver));
        assertTrue(result.isSuccess());
        assertEquals(true, result.output().get("recovered"));
    }

    @Test
    void handler_failure_propagates_original_error() {
        StepLookup lookup = name -> new ResolvedStep.PluginStep("recovery",
                "recovery-action", Map.of(), Map.of());
        StepEvaluator evaluator = (step, ctx, runner) -> Result.failed("handler also failed");
        var config = new DecoratorConfig(
                new ConditionEvaluator(null), SpeedMultiplier.identity(), null,
                lookup, evaluator, (step, resolver) -> Result.failed("handler also failed"),
                null);
        var chain = new DecoratorChain(config);

        DecoratedExecution failing = ctx -> Result.failed("original error");
        DecoratedExecution wrapped = chain.apply(
                Map.of("on-error", "recovery"), failing);

        Result result = wrapped.execute(new StepContext(new VariableResolver(Map.of(), Set.of())));
        assertFalse(result.isSuccess());
        assertTrue(((Result.Failure) result).message().contains("original error"));
    }

    @Test
    void missing_handler_propagates_original_error() {
        StepLookup lookup = name -> null;
        var config = new DecoratorConfig(
                new ConditionEvaluator(null), SpeedMultiplier.identity(), null,
                lookup, null, null, null);
        var chain = new DecoratorChain(config);

        DecoratedExecution failing = ctx -> Result.failed("boom");
        DecoratedExecution wrapped = chain.apply(
                Map.of("on-error", "nonexistent"), failing);

        Result result = wrapped.execute(new StepContext(new VariableResolver(Map.of(), Set.of())));
        assertFalse(result.isSuccess());
    }
}
```

- [ ] **Step 5: Run test to verify it fails**

Run: `mvn -pl yaml-step-runtime test -Dtest=OnErrorHandlerTest -DfailIfNoTests=false --batch-mode`
Expected: FAIL (DecoratorChain doesn't accept DecoratorConfig yet)

- [ ] **Step 6: Refactor DecoratorChain to use DecoratorConfig**

Replace the existing constructor parameters with `DecoratorConfig`. Update `StructuralStepEvaluator` to construct `DecoratorConfig` and pass it. Update `wrapOnError` to use `config.stepLookup()`, `config.handlerEvaluator()`, and `config.handlerRunner()`:

The `wrapOnError` implementation:
```java
private DecoratedExecution wrapOnError(DecoratedExecution inner, Map<String, Object> decorators) {
    Object onErrorVal = decorators.get("on-error");
    if (onErrorVal == null) return inner;

    String fallbackStepName = String.valueOf(onErrorVal);
    return ctx -> {
        Result result;
        try {
            result = inner.execute(ctx);
        } catch (Exception e) {
            result = Result.failed(e.getMessage());
        }
        if (!result.isSuccess()) {
            if (config.stepLookup() == null) {
                return result;
            }
            ResolvedStep handler = config.stepLookup().resolve(fallbackStepName);
            if (handler == null) {
                return result;
            }
            String errorMsg = result instanceof Result.Failure f ? f.message() : "unknown";
            String errorType = result instanceof Result.Failure f ? f.category() : "unknown";
            VariableResolver errorResolver = ctx.resolver()
                    .withObjectScope("error", name -> switch (name) {
                        case "type" -> errorType;
                        case "message" -> errorMsg;
                        default -> null;
                    });
            Result handlerResult = config.handlerEvaluator().evaluate(
                    handler, ctx.withResolver(errorResolver), config.handlerRunner());
            if (!handlerResult.isSuccess()) return result;
            return handlerResult;
        }
        return result;
    };
}
```

- [ ] **Step 7: Run all yaml-step-runtime tests**

Run: `mvn -pl yaml-step-runtime test --batch-mode`
Expected: ALL PASS

- [ ] **Step 8: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#828): implement on-error handler via DecoratorConfig

P34: on-error now looks up and executes the named handler step through
the structural evaluator. Handler success recovers the error; handler
failure propagates the original. DecoratorConfig consolidates all
decorator chain parameters into one record.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4: Implement transform decorator

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java`
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/TransformDecoratorTest.java`

**Interfaces:**
- Consumes: `TransformDelegate` from Task 3
- Consumes: `DecoratorConfig` from Task 3

- [ ] **Step 1: Write failing transform tests**

`TransformDecoratorTest.java`:
```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.core.condition.ConditionEvaluator;
import io.casehub.yaml.core.resolver.VariableResolver;
import io.casehub.yaml.core.runtime.SpeedMultiplier;
import io.casehub.yaml.plugin.api.Result;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

class TransformDecoratorTest {

    @Test
    void transform_applies_expression_to_output() {
        TransformDelegate delegate = (expr, input) -> Map.of("doubled", (Integer) input.get("x") * 2);
        var config = new DecoratorConfig(
                new ConditionEvaluator(null), SpeedMultiplier.identity(), null,
                null, null, null, delegate);
        var chain = new DecoratorChain(config);

        DecoratedExecution inner = ctx -> Result.of(Map.of("x", 5));
        DecoratedExecution wrapped = chain.apply(Map.of("transform", "double(x)"), inner);

        Result result = wrapped.execute(new StepContext(new VariableResolver(Map.of(), Set.of())));
        assertTrue(result.isSuccess());
        assertEquals(10, result.output().get("doubled"));
    }

    @Test
    void transform_wraps_scalar_result() {
        TransformDelegate delegate = (expr, input) -> Map.of("value", 42);
        var config = new DecoratorConfig(
                new ConditionEvaluator(null), SpeedMultiplier.identity(), null,
                null, null, null, delegate);
        var chain = new DecoratorChain(config);

        DecoratedExecution inner = ctx -> Result.of(Map.of("x", 5));
        DecoratedExecution wrapped = chain.apply(Map.of("transform", "compute"), inner);

        Result result = wrapped.execute(new StepContext(new VariableResolver(Map.of(), Set.of())));
        assertTrue(result.isSuccess());
        assertEquals(42, result.output().get("value"));
    }

    @Test
    void transform_failure_fails_step() {
        TransformDelegate delegate = (expr, input) -> { throw new RuntimeException("bad expression"); };
        var config = new DecoratorConfig(
                new ConditionEvaluator(null), SpeedMultiplier.identity(), null,
                null, null, null, delegate);
        var chain = new DecoratorChain(config);

        DecoratedExecution inner = ctx -> Result.of(Map.of("x", 5));
        DecoratedExecution wrapped = chain.apply(Map.of("transform", "bad"), inner);

        Result result = wrapped.execute(new StepContext(new VariableResolver(Map.of(), Set.of())));
        assertFalse(result.isSuccess());
        assertTrue(((Result.Failure) result).message().contains("Transform failed"));
    }

    @Test
    void no_transform_delegate_returns_error() {
        var config = new DecoratorConfig(
                new ConditionEvaluator(null), SpeedMultiplier.identity(), null,
                null, null, null, null);
        var chain = new DecoratorChain(config);

        DecoratedExecution inner = ctx -> Result.of(Map.of("x", 5));
        DecoratedExecution wrapped = chain.apply(Map.of("transform", "expr"), inner);

        Result result = wrapped.execute(new StepContext(new VariableResolver(Map.of(), Set.of())));
        assertFalse(result.isSuccess());
        assertTrue(((Result.Failure) result).message().contains("requires an expression engine"));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-step-runtime test -Dtest=TransformDecoratorTest -DfailIfNoTests=false --batch-mode`
Expected: FAIL

- [ ] **Step 3: Implement wrapTransform**

Replace the no-op `wrapTransform` in `DecoratorChain`:

```java
private DecoratedExecution wrapTransform(DecoratedExecution inner, Map<String, Object> decorators) {
    Object transformVal = decorators.get("transform");
    if (transformVal == null) return inner;
    if (config.transformDelegate() == null) {
        return ctx -> Result.failed("'transform' requires an expression engine");
    }

    String expression = String.valueOf(transformVal);
    return ctx -> {
        Result result = inner.execute(ctx);
        if (!result.isSuccess()) return result;
        try {
            Map<String, Object> transformed = config.transformDelegate().transform(
                    expression, result.output());
            return Result.of(transformed);
        } catch (Exception e) {
            return Result.failed("Transform failed: " + e.getMessage());
        }
    };
}
```

- [ ] **Step 4: Run all yaml-step-runtime tests**

Run: `mvn -pl yaml-step-runtime test --batch-mode`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#828): implement transform decorator via expression engine

P35: transform applies an expression to the step's output map. Delegate
wired from ExpressionEngineRegistry with TRANSFORM context. Expression
failures caught and reported as step failures.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 3: Nested captures (P36) and invoke fix (P40)

### Task 5: Implement CaptureCollector and nested capture support

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/CaptureCollector.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java`
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/NestedCaptureTest.java`

**Interfaces:**
- Produces: `CaptureCollector` — thread-safe flat capture map
- Produces: `StructuralStepEvaluator.withCaptureCollector(CaptureCollector)` — wither

- [ ] **Step 1: Write failing nested capture test**

`NestedCaptureTest.java`:
```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.core.condition.ConditionEvaluator;
import io.casehub.yaml.core.resolver.VariableResolver;
import io.casehub.yaml.plugin.api.Result;
import io.casehub.yaml.step.catalog.ResolvedStep;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

class NestedCaptureTest {

    private static StepRunner echoRunner() {
        return (step, resolver) -> {
            if (step instanceof ResolvedStep.PluginStep ps) {
                return Result.of(Map.copyOf(ps.params()));
            }
            throw new IllegalArgumentException("unsupported");
        };
    }

    @Test
    void capture_inside_block_is_collected() {
        var innerStep = new ResolvedStep.PluginStep("inner", "action",
                Map.of("key", "value"), Map.of("capture", "my-capture"));
        var block = new ResolvedStep.BlockStep(null,
                List.of(innerStep), Map.of());

        var collector = new CaptureCollector();
        var evaluator = new StructuralStepEvaluator(new ConditionEvaluator(null))
                .withCaptureCollector(collector);

        Result result = evaluator.evaluate(block,
                new VariableResolver(Map.of(), Set.of()), echoRunner());

        assertTrue(result.isSuccess());
        var captures = collector.all();
        assertTrue(captures.containsKey("my-capture"));
        assertEquals("value", captures.get("my-capture").get("key"));
    }

    @Test
    void capture_inside_if_then_is_collected() {
        var innerStep = new ResolvedStep.PluginStep("inner", "action",
                Map.of("data", "result"), Map.of("capture", "if-capture"));
        var ifElse = new ResolvedStep.IfElseStep(null, "true",
                List.of(innerStep), List.of(), Map.of());

        var collector = new CaptureCollector();
        var evaluator = new StructuralStepEvaluator(new ConditionEvaluator(null))
                .withCaptureCollector(collector);

        Result result = evaluator.evaluate(ifElse,
                new VariableResolver(Map.of(), Set.of()), echoRunner());

        assertTrue(result.isSuccess());
        assertTrue(collector.all().containsKey("if-capture"));
    }

    @Test
    void capture_on_structural_step_is_collected() {
        var innerStep = new ResolvedStep.PluginStep(null, "action",
                Map.of("x", 1), Map.of());
        var block = new ResolvedStep.BlockStep("my-block",
                List.of(innerStep), Map.of("capture", "block-result"));

        var collector = new CaptureCollector();
        var evaluator = new StructuralStepEvaluator(new ConditionEvaluator(null))
                .withCaptureCollector(collector);

        Result result = evaluator.evaluate(block,
                new VariableResolver(Map.of(), Set.of()), echoRunner());

        assertTrue(result.isSuccess());
        assertTrue(collector.all().containsKey("block-result"));
    }

    @Test
    void captured_value_available_to_downstream_steps() {
        var step1 = new ResolvedStep.PluginStep("s1", "action",
                Map.of("val", "hello"), Map.of("capture", "first"));
        var step2 = new ResolvedStep.PluginStep("s2", "action",
                Map.of("ref", "${first.val}"), Map.of());
        var block = new ResolvedStep.BlockStep(null,
                List.of(step1, step2), Map.of());

        var collector = new CaptureCollector();
        var evaluator = new StructuralStepEvaluator(new ConditionEvaluator(null))
                .withCaptureCollector(collector);

        StepRunner resolvingRunner = (step, resolver) -> {
            if (step instanceof ResolvedStep.PluginStep ps) {
                return Result.of(resolver.resolveMap(ps.params(), "step"));
            }
            throw new IllegalArgumentException("unsupported");
        };

        Result result = evaluator.evaluate(block,
                new VariableResolver(Map.of(), Set.of()), resolvingRunner);

        assertTrue(result.isSuccess());
        assertEquals("hello", result.output().get("ref"));
    }

    @Test
    void last_write_wins_on_name_collision() {
        var step1 = new ResolvedStep.PluginStep("s1", "action",
                Map.of("v", "first"), Map.of("capture", "data"));
        var step2 = new ResolvedStep.PluginStep("s2", "action",
                Map.of("v", "second"), Map.of("capture", "data"));
        var block = new ResolvedStep.BlockStep(null,
                List.of(step1, step2), Map.of());

        var collector = new CaptureCollector();
        var evaluator = new StructuralStepEvaluator(new ConditionEvaluator(null))
                .withCaptureCollector(collector);

        evaluator.evaluate(block, new VariableResolver(Map.of(), Set.of()), echoRunner());

        assertEquals("second", collector.all().get("data").get("v"));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-step-runtime test -Dtest=NestedCaptureTest -DfailIfNoTests=false --batch-mode`
Expected: FAIL (CaptureCollector doesn't exist yet)

- [ ] **Step 3: Create CaptureCollector**

```java
package io.casehub.yaml.step.eval;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public final class CaptureCollector {

    private final ConcurrentHashMap<String, Map<String, Object>> captures = new ConcurrentHashMap<>();

    public void capture(String name, Map<String, Object> output) {
        captures.put(name, Map.copyOf(output));
    }

    public Map<String, Map<String, Object>> all() {
        return Map.copyOf(captures);
    }

    public Map<String, Object> get(String name) {
        return captures.get(name);
    }

    public boolean has(String name) {
        return captures.containsKey(name);
    }
}
```

- [ ] **Step 4: Add capture logic to StructuralStepEvaluator.evaluateInternal**

Add `CaptureCollector` field and `withCaptureCollector` wither method. In `evaluateInternal`, after computing the result and before returning, check for `capture` decorator on any step type:

```java
if (result.isSuccess() && result.output() != null && captureCollector != null) {
    Object captureVal = step.decorators().get("capture");
    if (captureVal != null) {
        String captureName = String.valueOf(captureVal);
        captureCollector.capture(captureName, result.output());
    }
}
```

Update `evaluateBlock` to thread updated resolver forward — after a capture, add the captured scope to the resolver for subsequent steps:

```java
private Result evaluateBlock(ResolvedStep.BlockStep block, StepContext ctx, StepRunner runner) {
    if (block.steps().isEmpty()) return Result.of(Map.of());
    Result last = Result.of(Map.of());
    StepContext currentCtx = ctx;
    for (ResolvedStep sub : block.steps()) {
        last = evaluateInternal(sub, currentCtx, runner);
        if (!last.isSuccess()) return last;
        // Thread capture scopes forward
        if (captureCollector != null) {
            Object captureVal = sub.decorators().get("capture");
            if (captureVal != null && last.output() != null) {
                String captureName = String.valueOf(captureVal);
                Map<String, Object> output = last.output();
                currentCtx = currentCtx.withResolver(
                        currentCtx.resolver().withObjectScope(captureName, output::get));
            }
        }
    }
    return last;
}
```

- [ ] **Step 5: Run all yaml-step-runtime tests**

Run: `mvn -pl yaml-step-runtime test --batch-mode`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add yaml-step-runtime/
git commit -m "feat(#828): captures work at all nesting depths

P36: CaptureCollector is a thread-safe flat map shared across the
evaluator. Captures from any step type at any depth write to the same
map. Captured values wired into resolver for downstream steps.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 6: Fix invoke step and CatalogStepRunner

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/CatalogStepRunner.java`
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/InvokeStepTest.java`

**Interfaces:**
- Consumes: `ResolvedStep.InvokeStep` from ResolvedStep sealed interface

- [ ] **Step 1: Write failing test for invoke step**

`InvokeStepTest.java`:
```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.core.resolver.VariableResolver;
import io.casehub.yaml.plugin.api.PluginRegistry;
import io.casehub.yaml.plugin.api.MapServiceRegistry;
import io.casehub.yaml.plugin.api.Result;
import io.casehub.yaml.step.catalog.ResolvedStep;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

class InvokeStepTest {

    @Test
    void invoke_step_returns_error_result_not_exception() {
        PluginRegistry registry = name -> Optional.empty();
        var runner = new CatalogStepRunner(registry, new MapServiceRegistry());
        var invokeStep = new ResolvedStep.InvokeStep("test-invoke",
                Map.of("type", "mcp"), Map.of());

        Result result = runner.run(invokeStep, new VariableResolver(Map.of(), Set.of()));
        assertFalse(result.isSuccess());
        assertTrue(((Result.Failure) result).message().contains("not yet supported"));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl yaml-step-runtime test -Dtest=InvokeStepTest -DfailIfNoTests=false --batch-mode`
Expected: FAIL with IllegalArgumentException (current behavior throws)

- [ ] **Step 3: Fix CatalogStepRunner to return error result for InvokeStep**

In `CatalogStepRunner.run()`, change the throw to a result:

```java
@Override
public Result run(ResolvedStep step, VariableResolver resolver) {
    if (step instanceof ResolvedStep.PluginStep ps) {
        // ... existing plugin logic ...
    }
    if (step instanceof ResolvedStep.InvokeStep) {
        return Result.failed("'invoke:' steps are not yet supported — use a plugin step instead");
    }
    return Result.failed("Unsupported step type: " + step.getClass().getSimpleName());
}
```

- [ ] **Step 4: Run all yaml-step-runtime tests**

Run: `mvn -pl yaml-step-runtime test --batch-mode`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add yaml-step-runtime/
git commit -m "fix(#828): invoke step returns error result instead of throwing

P40: CatalogStepRunner now returns a clear failure result for InvokeStep
instead of throwing IllegalArgumentException.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 4: Runner relocation (P32) and CDI wiring

### Task 7: Move PlaybookRunnerCore to yaml-step-runtime and wire scope + expressions

**Files:**
- Move: `yaml-test-core/.../PlaybookRunnerCore.java` → `yaml-step-runtime/.../io/casehub/yaml/step/runner/PlaybookRunnerCore.java`
- Move: `yaml-test-core/.../PlaybookRunResult.java` → `yaml-step-runtime/.../io/casehub/yaml/step/runner/PlaybookRunResult.java`
- Move: `yaml-test-core/.../PlaybookRunConfig.java` → `yaml-step-runtime/.../io/casehub/yaml/step/runner/PlaybookRunConfig.java`
- Move: `yaml-test-core/.../PlaybookValidationResult.java` → `yaml-step-runtime/.../io/casehub/yaml/step/runner/PlaybookValidationResult.java`
- Move: `yaml-test-core/.../PlaybookApi.java` → `yaml-step-runtime/.../io/casehub/yaml/step/runner/PlaybookApi.java`
- Move: `yaml-test-core/.../PlaybookRunRequest.java` → `yaml-step-runtime/.../io/casehub/yaml/step/runner/PlaybookRunRequest.java`
- Move: `yaml-test-core/.../ModuleLoader.java` → `yaml-step-runtime/.../io/casehub/yaml/step/runner/ModuleLoader.java`
- Move: `yaml-test-core/.../StepTraceNode.java` → `yaml-step-runtime/.../io/casehub/yaml/step/runner/StepTraceNode.java`
- Move: `yaml-test-core/.../StepTraceCollector.java` → `yaml-step-runtime/.../io/casehub/yaml/step/runner/StepTraceCollector.java`
- Move: `yaml-test-core/.../StepOutcome.java` → `yaml-step-runtime/.../io/casehub/yaml/step/runner/StepOutcome.java`
- Move: `yaml-test-core/.../EventCapture.java` → `yaml-step-runtime/.../io/casehub/yaml/step/runner/EventCapture.java`
- Move: `yaml-test-core/.../CapturedEvent.java` → `yaml-step-runtime/.../io/casehub/yaml/step/runner/CapturedEvent.java`
- Move: `yaml-test-core/.../PlaybookModuleBridge.java` → `yaml-step-runtime/.../io/casehub/yaml/step/runner/PlaybookModuleBridge.java`
- Move: `yaml-test-core/.../FileSystemModuleLoader.java` → `yaml-step-runtime/.../io/casehub/yaml/step/runner/FileSystemModuleLoader.java`
- Move: `yaml-test-core/.../SimulateBlockParser.java` → `yaml-step-runtime/.../io/casehub/yaml/step/runner/SimulateBlockParser.java`
- Move: `yaml-test-core/.../ModuleNotFoundException.java` → `yaml-step-runtime/.../io/casehub/yaml/step/runner/ModuleNotFoundException.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/SimulationActivator.java`
- Modify: `playbook-runner/.../PlaybookBeans.java` — update imports
- Modify: `yaml-test-core` — update imports for remaining classes (YamlTestExecutor, etc.)
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/runner/PlaybookRunnerCoreTest.java`

**Interfaces:**
- Produces: `SimulationActivator` — `SimulationOverlay activate(PlaybookRunConfig, Path)`
- Produces: relocated `PlaybookRunnerCore` with `ExecutionScope`, `ConditionDelegate`, `CaptureCollector`, `StepLookup`, `DecoratorConfig` wired

- [ ] **Step 1: Create SimulationActivator interface**

```java
package io.casehub.yaml.step.runner;

import java.nio.file.Path;

@FunctionalInterface
public interface SimulationActivator {
    Object activate(Object config, Path playbookPath);
    // Returns opaque overlay object; runner calls deactivate on finally
}
```

Actually, to avoid simulation type leakage, use a `Closeable` pattern:

```java
package io.casehub.yaml.step.runner;

import java.nio.file.Path;

@FunctionalInterface
public interface SimulationActivator {
    AutoCloseable activate(PlaybookRunConfig config, Path playbookPath);
}
```

The CDI layer wraps `SimulationRuntime.pushOverlay()` / `popOverlay()` into an `AutoCloseable`.

- [ ] **Step 2: Move files to new package**

Move all runner-related types from `yaml-test-core/src/main/java/io/casehub/yaml/test/` to `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/`. Update package declarations. When IntelliJ MCP is available, use `ide_move_file`; otherwise use Edit to change package declarations and move files via bash (non-source move is acceptable for the file system operation).

- [ ] **Step 3: Update PlaybookRunnerCore to wire ExecutionScope and captures**

Key changes to `PlaybookRunnerCore.run()`:
- Constructor accepts `ConditionDelegate`, optional `SimulationActivator`
- Creates `DefaultExecutionScope` per run, closed in finally
- Creates `CaptureCollector`, passes to evaluator
- Builds step index via `StepIndexBuilder.build(resolved)`
- Constructs `DecoratorConfig` with all wiring
- Removes the top-level capture loop (now handled by CaptureCollector)
- Reads captures from `captureCollector.all()`

- [ ] **Step 4: Update yaml-test-core imports**

Update `YamlTestExecutor.java`, `RunPlaybookPlugin.java`, `ValidatePlaybookPlugin.java`, `YamlTestCli.java`, and other files in yaml-test-core that reference the moved types.

- [ ] **Step 5: Update PlaybookBeans imports and wire expression delegates**

In `PlaybookBeans.java`:
- Import from `io.casehub.yaml.step.runner` instead of `io.casehub.yaml.test`
- Inject `Instance<ExpressionEngineRegistry>` for condition and transform delegates
- Wire `SimulationActivator` from `Instance<SimulationRuntime>`
- Wire `ConditionDelegate` from `ExpressionEngineRegistry.resolveDefault(CONDITION)`
- Wire `TransformDelegate` from `ExpressionEngineRegistry.resolveDefault(TRANSFORM)`

- [ ] **Step 6: Write PlaybookRunnerCore integration test**

`PlaybookRunnerCoreTest.java` — test that scope-dependent features work:

```java
package io.casehub.yaml.step.runner;

import io.casehub.yaml.core.condition.ConditionEvaluator;
import io.casehub.yaml.plugin.api.*;
import io.casehub.yaml.step.catalog.ResolvedStep;
import io.casehub.yaml.step.catalog.Walker;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class PlaybookRunnerCoreTest {

    @Test
    void runner_creates_scope_so_background_works() {
        // Write a playbook YAML that uses background: true
        // Run it via PlaybookRunnerCore
        // Assert it succeeds (previously returned "requires an ExecutionScope")
    }

    @Test
    void runner_wires_captures_at_all_depths() {
        // Write a playbook with captures inside a block
        // Assert captures are collected in the result
    }
}
```

- [ ] **Step 7: Build the full project**

Run: `mvn --batch-mode install -DskipTests`
Then: `mvn --batch-mode test -pl yaml-core,yaml-step-runtime,yaml-test-core,playbook-runner`
Expected: ALL PASS

- [ ] **Step 8: Commit**

```bash
git add yaml-core/ yaml-step-runtime/ yaml-test-core/ playbook-runner/
git commit -m "feat(#828): relocate PlaybookRunnerCore to yaml-step-runtime, wire scope + expressions

P32: Runner moved from yaml-test-core to yaml-step-runtime (new
io.casehub.yaml.step.runner package). ExecutionScope created per run.
Expression engine wired via ConditionDelegate and TransformDelegate.
SimulationActivator abstracts simulation deps.
CaptureCollector wired for nested captures.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## References

- [2026-11-17-canonical-runner-inert-features-design.md] — design spec this plan implements
- [yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookRunnerCore.java] — current runner location
- [yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java] — decorator chain
- [yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java] — structural evaluator
- [yaml-core/src/main/java/io/casehub/yaml/core/condition/ConditionEvaluator.java] — condition evaluation
- [yaml-core/src/main/java/io/casehub/yaml/core/condition/Truthiness.java] — boolean parsing
- [yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultExecutionScope.java] — scope impl
- [playbook-runner/src/main/java/io/casehub/yaml/test/quarkus/PlaybookBeans.java] — CDI wiring
- P32, P33, P34, P35, P36, P40 — code review findings
- GitHub #828, #827 — issue and epic
