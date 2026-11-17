# WS-1: Canonical runner + finish inert features

**Issue:** casehubio/platform#828
**Epic:** casehubio/platform#827 (Playbook language direction — platform)
**Direction:** casehubio/parent#540
**Findings:** P32, P33, P34, P35, P36, P40

## Summary

Move `PlaybookRunnerCore` from `yaml-test-core` to `yaml-step-runtime` as main code, wire `ExecutionScope` and expression engine, and implement the declared-but-inert features (on-error handler, transform, nested capture).

## Architecture

### Module changes

```
yaml-step-runtime/        (gains PlaybookRunnerCore + helpers)
  └── io.casehub.yaml.step.runner/
        PlaybookRunnerCore.java      ← moved from yaml-test-core
        PlaybookRunResult.java       ← moved
        PlaybookRunConfig.java       ← moved
        PlaybookValidationResult.java ← moved
        PlaybookApi.java             ← moved (SPI interface)
        PlaybookRunRequest.java      ← moved
        ModuleLoader.java            ← moved (functional interface)
        StepTraceNode.java           ← moved
        StepTraceCollector.java      ← moved
        StepOutcome.java             ← moved
        EventCapture.java            ← moved
        CaptureCollector.java        ← new
        PlaybookModuleBridge.java    ← moved
        FileSystemModuleLoader.java  ← moved
        SimulateBlockParser.java     ← moved

yaml-test-core/           (retains test-only types)
  └── io.casehub.yaml.test/
        YamlTestExecutor.java        stays
        YamlTestEngine.java          stays
        assertion helpers            stay

playbook-runner/           (CDI wiring, unchanged module)
  └── io.casehub.yaml.test.quarkus/
        PlaybookBeans.java           updated imports
```

### Dependency changes

`yaml-step-runtime` gains:
- `simulation-api` (compile, for `SimulationRuntime` constructor parameter — optional at runtime)
- `simulation-core` (compile, for `SimulationOverlay`, `MapSimulationConfig`)
- `simulation-inmem` (compile, for `InMemorySimulationCorpus`)
- `simulation-config-core` (compile, for `YamlSimulationConfig`)
- `yaml-jackson` (compile, for `YamlModuleFileMixin` used by module loading)

`yaml-test-core` drops the runner types and their transitive deps. Retains dependency on `yaml-step-runtime` to access the relocated types.

## P32: Runner wiring — ExecutionScope and expression engine

### ExecutionScope

`PlaybookRunnerCore.run()` creates a `DefaultExecutionScope` as the root scope for each playbook run. The scope is closed in a `finally` block.

```java
public PlaybookRunResult run(Path playbookPath, PlaybookRunConfig config) {
    try (var scope = new DefaultExecutionScope(
            new DefaultPrimitiveFactory(), speedMultiplier)) {
        // ...
        var evaluator = new StructuralStepEvaluator(conditionEvaluator, scope)
                .withListener(traceCollector);
        // ...
    }
}
```

The `StructuralStepEvaluator` already accepts an `ExecutionScope` in its two-arg constructor and passes it to `DecoratorChain`. This wiring is correct — the only gap was that nobody created the scope. The runner fills that gap.

### Expression engine

The runner accepts a `Function<String, Boolean>` condition delegate via its constructor. When present, `ConditionEvaluator` uses it for any condition that isn't a literal boolean.

The CDI layer (`PlaybookBeans`) wires this from `ExpressionEngineRegistry`:

```java
Function<String, Boolean> conditionDelegate = expression -> {
    var compiled = expressionRegistry.compile(expression, ExpressionContext.CONDITION);
    Object result = compiled.eval(/* variables from resolver */);
    return Truthiness.isTruthy(String.valueOf(result));
};
```

### SpeedMultiplier

The runner extracts `SpeedMultiplier` from `SimulationRuntime` when available, otherwise uses `SpeedMultiplier.identity()`. This is passed to `DefaultExecutionScope` and `DecoratorChain`.

## P33: Condition safety — injection and Norway fix

### Problem

```java
// Current: template-then-evaluate
String resolved = resolver.resolveString(condition, context);  // ${var} → "no"
conditionEvaluator.evaluate(resolved);                         // "no" → false (Norway)
```

A variable value containing expression syntax becomes code. A Norwegian country code evaluates as boolean false.

### Fix

**ConditionEvaluator gains a new method signature:**

```java
public boolean evaluate(String condition, VariableResolver resolver, String context) {
    // 1. Try strict literal boolean (only "true" / "false")
    if ("true".equals(condition) || "false".equals(condition)) {
        return Boolean.parseBoolean(condition);
    }

    // 2. Check if it's a pure variable reference (${x.y}) that resolved to a boolean
    if (isVariableReference(condition)) {
        Object value = resolver.resolve(condition);
        if (value instanceof Boolean b) return b;
        if (value instanceof String s) {
            if ("true".equals(s) || "false".equals(s)) return Boolean.parseBoolean(s);
        }
        // Non-boolean variable — fall through to expression engine
    }

    // 3. Compile via expression engine with variables as data bindings
    if (expressionDelegate == null) {
        throw new ConditionEvaluationException(
            "Cannot evaluate '" + condition + "' — no expression engine configured");
    }
    return expressionDelegate.evaluate(condition, resolver.buildExpressionContext());
}
```

**The delegate signature changes** from `Function<String, Boolean>` to a two-arg function that accepts the expression and the variable bindings:

```java
@FunctionalInterface
public interface ConditionDelegate {
    boolean evaluate(String expression, Map<String, Object> bindings);
}
```

**Truthiness is restricted** to strict `true`/`false` only. The old values (`yes`, `no`, `on`, `off`, `y`, `n`, `1`, `0`) are removed. This is a breaking change — intentional for a pre-release platform.

**All callers updated.** `DecoratorChain.resolveCondition()`, `StructuralStepEvaluator.evaluateIfElse()`, `evaluateMatch()` guard evaluation — all switch from the two-step resolve-then-evaluate to the single `evaluate(condition, resolver, context)` call.

## P34: on-error handler implementation

### Problem

`wrapOnError` catches failures and returns a success with marker keys (`on-error.caught`, `on-error.fallback`). The named handler step is never looked up or executed.

### Fix

`DecoratorChain` gains a `StepLookup` function:

```java
@FunctionalInterface
public interface StepLookup {
    ResolvedStep resolve(String stepName);
}
```

The runner passes this when constructing the decorator chain. `wrapOnError` uses it:

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
            if (stepLookup == null) {
                return Result.failed("on-error handler '" + fallbackStepName
                    + "' cannot run — no step lookup available");
            }
            ResolvedStep handler = stepLookup.resolve(fallbackStepName);
            if (handler == null) {
                return Result.failed("on-error handler '" + fallbackStepName + "' not found");
            }
            // Bind error context
            String errorMsg = result instanceof Result.Failure f ? f.message() : "unknown";
            String errorType = result instanceof Result.Failure f ? f.category() : "unknown";
            VariableResolver errorResolver = ctx.resolver()
                .withObjectScope("error", name -> switch (name) {
                    case "type" -> errorType;
                    case "message" -> errorMsg;
                    default -> null;
                });
            // Execute the handler step
            return handlerRunner.run(handler, errorResolver);
        }
        return result;
    };
}
```

The `handlerRunner` is the same `StepRunner` used by `StructuralStepEvaluator`, passed into `DecoratorChain` via constructor.

### Contract

- `on-error: <step-name>` — on failure, run the named step with `${error.type}` and `${error.message}` bound
- If the handler succeeds, the error is recovered — the handler's result replaces the failure
- If the handler fails, the original failure propagates
- If the named step doesn't exist, the original failure propagates with an additional error message

## P35: transform implementation

### Problem

`wrapTransform` returns the result unchanged.

### Fix

`DecoratorChain` accepts a transform delegate:

```java
@FunctionalInterface
public interface TransformDelegate {
    Map<String, Object> transform(String expression, Map<String, Object> input);
}
```

The runner wires this from `ExpressionEngineRegistry` with `ExpressionContext.TRANSFORM`:

```java
TransformDelegate transformDelegate = (expression, input) -> {
    var compiled = expressionRegistry.compile(expression, ExpressionContext.TRANSFORM);
    Object result = compiled.eval(input);
    if (result instanceof Map<?, ?> m) {
        return (Map<String, Object>) m;
    }
    return Map.of("value", result);
};
```

`wrapTransform` applies the delegate:

```java
private DecoratedExecution wrapTransform(DecoratedExecution inner, Map<String, Object> decorators) {
    Object transformVal = decorators.get("transform");
    if (transformVal == null) return inner;
    if (transformDelegate == null) {
        return ctx -> Result.failed("'transform' requires an expression engine");
    }

    String expression = String.valueOf(transformVal);
    return ctx -> {
        Result result = inner.execute(ctx);
        if (!result.isSuccess()) return result;
        Map<String, Object> transformed = transformDelegate.transform(expression, result.output());
        return Result.of(transformed);
    };
}
```

### Contract

- `transform: <expression>` — on success, apply the expression to the step output map
- The expression receives the output map as its evaluation context
- If the expression returns a Map, that map becomes the new output
- If the expression returns a scalar, it's wrapped as `{"value": <result>}`
- If the expression fails, the step fails with a transform error
- Transform runs after the step succeeds, before post-signal and transition decorators

## P36: Capture in nested scopes

### Problem

Captures inside structural steps (if/then, block, parallel, try) are silently dropped. Only top-level `PluginStep`s in the runner's loop have their captures collected.

### Fix

Introduce `CaptureCollector` — a thread-safe flat map shared across the evaluator:

```java
public final class CaptureCollector {
    private final ConcurrentHashMap<String, Map<String, Object>> captures
        = new ConcurrentHashMap<>();

    public void capture(String name, Map<String, Object> output) {
        captures.put(name, output);
    }

    public Map<String, Map<String, Object>> all() {
        return Map.copyOf(captures);
    }
}
```

`StructuralStepEvaluator` accepts a `CaptureCollector` and checks for `capture` decorators on every step at every depth:

```java
private Result evaluateInternal(ResolvedStep step, StepContext ctx, StepRunner runner) {
    // ... existing code ...
    Result result = /* dispatch */;

    // Capture at any depth
    if (result.isSuccess() && step instanceof ResolvedStep.PluginStep ps) {
        var capture = ps.decorators().get("capture");
        if (capture != null && result.output() != null && captureCollector != null) {
            captureCollector.capture(String.valueOf(capture), result.output());
            // Also add to resolver for downstream reference
        }
    }

    return result;
}
```

The runner creates a `CaptureCollector` per run, passes it to the evaluator, and reads from it after evaluation:

```java
var captureCollector = new CaptureCollector();
var evaluator = new StructuralStepEvaluator(conditionEvaluator, scope)
    .withCaptureCollector(captureCollector);
// ... run steps ...
Map<String, Map<String, Object>> captures = captureCollector.all();
```

### Namespace model

Flat map, globally scoped within the playbook run. A capture at any depth writes to the same map. Same name at different depths = last-write-wins (matches existing top-level behavior). No auto-namespacing. Playbook authors choose capture names; name collisions in parallel branches are the author's responsibility.

## P40: Guide vs code mismatches (code-side fixes only)

### invoke: step

`CatalogStepRunner.run()` currently throws `IllegalArgumentException` on `InvokeStep`. Since invoke semantics are undefined and WS-1 scope doesn't include designing them, replace the throw with a clear error result:

```java
case ResolvedStep.InvokeStep is ->
    Result.failed("'invoke:' steps are not yet supported — use a plugin step instead");
```

### Guard keyword

Code uses `when`. This is correct. Guide will be updated in WS-4 (#833). No code change needed.

### Bare variable references

Code rejects bare `${risk}`. This is correct — variables need a prefix (`${var.risk}`, `${param.risk}`). Guide will be updated in WS-4. No code change needed.

## Testing strategy

Each finding gets its own test class. Tests are written before implementation (TDD).

| Finding | Test class | Key assertions |
|---------|-----------|----------------|
| P32 | `PlaybookRunnerCoreTest` | Runner creates scope, decorators that require scope work (cancel, background, select, barrier, quorum), expression conditions evaluate |
| P33 | `ConditionEvaluatorTest` | Strict boolean only, expression delegation with bindings, injection attempt fails safely, Norway values rejected |
| P34 | `OnErrorHandlerTest` | Named handler runs on failure, handler success recovers error, handler failure propagates original, missing handler propagates original |
| P35 | `TransformDecoratorTest` | Expression applied to output, map result replaces output, scalar wrapped, transform failure fails step |
| P36 | `NestedCaptureTest` | Capture inside if/then, block, parallel, try all collected, flat map semantics, last-write-wins on collision |
| P40 | `InvokeStepTest` | invoke: returns clear error result, not exception |

## Migration

### Breaking changes

1. **Truthiness restricted:** `yes`, `no`, `on`, `off`, `y`, `n`, `1`, `0` no longer work as condition values. Only `true` and `false`. Playbooks using these must be updated.
2. **Package relocation:** `PlaybookRunnerCore` and helpers move from `io.casehub.yaml.test` to `io.casehub.yaml.step.runner`. Any direct imports must be updated. The CDI layer (`PlaybookBeans`) absorbs this change.
3. **on-error semantics:** Previously returned a success with marker keys. Now actually runs the named handler. Playbooks depending on the marker key behavior need to be updated.

### Non-breaking changes

- Captures work at all depths (additive)
- Transform decorator now functions (was a no-op)
- ExecutionScope features now work (was returning errors)
- invoke: returns a result instead of throwing (behavior improvement)

## References

- `yaml-test-core/src/main/java/io/casehub/yaml/test/PlaybookRunnerCore.java` — current runner location
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java` — decorator chain with on-error, transform, condition evaluation
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java` — structural step evaluation, capture point
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/CatalogStepRunner.java` — step runner, invoke throw
- `yaml-core/src/main/java/io/casehub/yaml/core/condition/ConditionEvaluator.java` — condition evaluation
- `yaml-core/src/main/java/io/casehub/yaml/core/condition/Truthiness.java` — boolean parsing (Norway problem)
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ExecutionScope.java` — scope interface
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultExecutionScope.java` — scope implementation
- `playbook-runner/src/main/java/io/casehub/yaml/test/quarkus/PlaybookBeans.java` — CDI wiring
- P32, P33, P34, P35, P36, P40 — code review findings in `code-review-notes.md`
- LD-1, LD-4, LD-7 — language direction items in `playbook-direction.md`
