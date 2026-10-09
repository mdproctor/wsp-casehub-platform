# Playbook Orchestration Extensions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #563 — Playbook orchestration: loop continuous, cancel, background, forEach collect, conditional retry, primitive variables
**Issue group:** #563

**Goal:** Complete the orchestration model with six features: continuous loops, signal-triggered cancellation, background spawning, iteration result collection, conditional retry, and primitive variable resolution.

**Architecture:** Extends LoopDirective (Continuous variant), adds three new decorators to DecoratorChain (cancel, background, from [future #564]), extends forEach with collect option, adds failure category to Result, wires VariableSource for orchestration primitives.

**Tech Stack:** Java 21, yaml-core (zero-dep, j.u.c concurrency), yaml-plugin-api (zero-dep), yaml-step-runtime (step evaluation), JUnit 5

## Global Constraints

- yaml-core must remain zero-dependency and J2CL-safe
- yaml-plugin-api must remain zero-dependency
- All primitives MUST use j.u.c locks or lock-free atomics — never `synchronized`
- ADR-0011 governs keyword reservation — `cancel` and `background` are imperative layer
- JSON Schema Draft 2020-12 for schema additions
- IntelliJ MCP required for all code navigation and refactoring

---

## Batch 1: Loop Continuous + Conditional Retry Foundations

After this batch: `loop: continuous` works, `Result.Failure` has optional category, `RetryDirective` supports `on:` filtering.

### Task 1: LoopDirective.Continuous + wrapLoop update

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/LoopDirective.java:5-47`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java:99-133` (wrapLoop)
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/LoopDirectiveTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/WrapLoopContinuousTest.java`

**Interfaces:**
- Produces: `LoopDirective.Continuous` record — consumed by wrapLoop in DecoratorChain
- Produces: `LoopDirective.parse("continuous")` returns `Continuous` — consumed by YAML parsing

- [ ] **Step 1: Write failing test for LoopDirective.Continuous parsing**

```java
// LoopDirectiveTest.java (new or extend existing)
@Test
void parsesContinuousString() {
    var directive = LoopDirective.parse("continuous");
    assertInstanceOf(LoopDirective.Continuous.class, directive);
}

@Test
void parsesContinuousInMap() {
    var directive = LoopDirective.parse(Map.of("continuous", true));
    assertInstanceOf(LoopDirective.Continuous.class, directive);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=LoopDirectiveTest`

- [ ] **Step 3: Add Continuous variant to LoopDirective**

Add `Continuous` record to the sealed interface permits list and the parse method:

```java
public sealed interface LoopDirective permits
        LoopDirective.Count, LoopDirective.CountUntil,
        LoopDirective.Until, LoopDirective.Continuous {

    record Continuous() implements LoopDirective {}

    // In parse():
    if (raw instanceof String s && "continuous".equalsIgnoreCase(s)) {
        return new Continuous();
    }
    // In map parsing:
    if (Boolean.TRUE.equals(m.get("continuous"))) {
        return new Continuous();
    }
}
```

- [ ] **Step 4: Run parse tests to verify they pass**

- [ ] **Step 5: Write failing test for wrapLoop with continuous**

```java
// WrapLoopContinuousTest.java
@Test
void continuousLoopRunsUntilInterrupted() throws Exception {
    var scope = new DefaultExecutionScope();
    var chain = new DecoratorChain(new ConditionEvaluator(null), SpeedMultiplier.identity(), scope);
    var counter = new AtomicInteger(0);

    DecoratedExecution inner = ctx -> {
        counter.incrementAndGet();
        if (counter.get() >= 5) {
            Thread.currentThread().interrupt();
        }
        return Result.of(Map.of());
    };

    var decorated = chain.apply(Map.of("loop", "continuous"), inner);
    decorated.execute(new StepContext(resolver));

    assertThat(counter.get()).isGreaterThanOrEqualTo(5);
}

@Test
void continuousLoopStopsOnFailure() {
    var scope = new DefaultExecutionScope();
    var chain = new DecoratorChain(new ConditionEvaluator(null), SpeedMultiplier.identity(), scope);
    var counter = new AtomicInteger(0);

    DecoratedExecution inner = ctx -> {
        if (counter.incrementAndGet() >= 3) {
            return Result.failed("stop");
        }
        return Result.of(Map.of());
    };

    var decorated = chain.apply(Map.of("loop", "continuous"), inner);
    Result result = decorated.execute(new StepContext(resolver));

    assertThat(result.isSuccess()).isFalse();
    assertThat(counter.get()).isEqualTo(3);
}
```

- [ ] **Step 6: Update wrapLoop to handle Continuous**

In the `wrapLoop` method, add the `Continuous` case:

```java
int maxIterations = switch (directive) {
    case LoopDirective.Count c -> c.count();
    case LoopDirective.CountUntil cu -> cu.count();
    case LoopDirective.Until u -> 1000;
    case LoopDirective.Continuous c -> Integer.MAX_VALUE;
};
```

And add interruption checking in the loop:

```java
for (int i = 0; i < maxIterations; i++) {
    if (Thread.currentThread().isInterrupted()) {
        return Result.failed("Loop interrupted");
    }
    last = inner.execute(ctx);
    if (!last.isSuccess()) { return last; }
    // ... existing until condition check
}
```

- [ ] **Step 7: Run tests, verify pass**

Run: `mvn --batch-mode test -pl yaml-core,yaml-step-runtime -Dtest="LoopDirectiveTest,WrapLoopContinuousTest"`

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(#563): LoopDirective.Continuous variant + wrapLoop continuous support"
```

### Task 2: Result.Failure category + conditional retry

**Files:**
- Modify: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Result.java:24-38`
- Create: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/FailureCategory.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/RetryDirective.java:6-40`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java:190-232` (wrapRetry)
- Test: `yaml-plugin-api/src/test/java/io/casehub/yaml/plugin/api/ResultFailureCategoryTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/WrapRetryConditionalTest.java`

**Interfaces:**
- Produces: `Result.Failure(String message, String category)` — backwards-compatible, null category matches all
- Produces: `Result.failed(String message, String category)` factory method
- Produces: `FailureCategory` constants (TIMEOUT, TRANSIENT, PERMANENT, RATE_LIMITED)
- Produces: `RetryDirective.Full` with optional `List<String> on` field

- [ ] **Step 1: Write failing tests for Result.Failure with category**

```java
// ResultFailureCategoryTest.java
@Test
void failureWithCategory() {
    Result r = Result.failed("timed out", FailureCategory.TIMEOUT);
    assertThat(r.isSuccess()).isFalse();
    assertThat(((Result.Failure) r).category()).isEqualTo("TIMEOUT");
}

@Test
void failureWithoutCategoryIsNull() {
    Result r = Result.failed("generic error");
    assertThat(((Result.Failure) r).category()).isNull();
}

@Test
void backwardsCompatible() {
    Result r = Result.failed("old style");
    assertThat(r).isInstanceOf(Result.Failure.class);
    assertThat(r.isSuccess()).isFalse();
}
```

- [ ] **Step 2: Run to verify failure**

- [ ] **Step 3: Update Result.Failure record**

```java
record Failure(String message, String category) implements Result {
    public Failure(String message) { this(message, null); }
    @Override public boolean isSuccess() { return false; }
    @Override public Map<String, Object> output() { return Map.of(); }
}

static Result failed(String message) { return new Failure(message, null); }
static Result failed(String message, String category) { return new Failure(message, category); }
```

- [ ] **Step 4: Create FailureCategory constants**

```java
// FailureCategory.java
package io.casehub.yaml.plugin.api;

public final class FailureCategory {
    public static final String TIMEOUT = "TIMEOUT";
    public static final String TRANSIENT = "TRANSIENT";
    public static final String PERMANENT = "PERMANENT";
    public static final String RATE_LIMITED = "RATE_LIMITED";
    private FailureCategory() {}
}
```

- [ ] **Step 5: Run Result tests, verify pass**

- [ ] **Step 6: Write failing tests for conditional retry**

```java
// WrapRetryConditionalTest.java
@Test
void retryOnlyMatchingCategory() {
    var chain = new DecoratorChain(new ConditionEvaluator(null), SpeedMultiplier.identity());
    var counter = new AtomicInteger(0);

    DecoratedExecution inner = ctx -> {
        if (counter.incrementAndGet() < 3) {
            return Result.failed("timeout", FailureCategory.TIMEOUT);
        }
        return Result.of(Map.of("done", true));
    };

    var decorated = chain.apply(Map.of("retry",
            Map.of("max", 5, "on", List.of("TIMEOUT"))), inner);
    Result result = decorated.execute(new StepContext(resolver));

    assertThat(result.isSuccess()).isTrue();
    assertThat(counter.get()).isEqualTo(3);
}

@Test
void noRetryOnNonMatchingCategory() {
    var chain = new DecoratorChain(new ConditionEvaluator(null), SpeedMultiplier.identity());
    var counter = new AtomicInteger(0);

    DecoratedExecution inner = ctx -> {
        counter.incrementAndGet();
        return Result.failed("permanent", FailureCategory.PERMANENT);
    };

    var decorated = chain.apply(Map.of("retry",
            Map.of("max", 5, "on", List.of("TIMEOUT"))), inner);
    Result result = decorated.execute(new StepContext(resolver));

    assertThat(result.isSuccess()).isFalse();
    assertThat(counter.get()).isEqualTo(1); // no retry — category didn't match
}

@Test
void nullCategoryAlwaysRetried() {
    var chain = new DecoratorChain(new ConditionEvaluator(null), SpeedMultiplier.identity());
    var counter = new AtomicInteger(0);

    DecoratedExecution inner = ctx -> {
        if (counter.incrementAndGet() < 2) {
            return Result.failed("generic error"); // no category
        }
        return Result.of(Map.of("done", true));
    };

    var decorated = chain.apply(Map.of("retry",
            Map.of("max", 5, "on", List.of("TIMEOUT"))), inner);
    Result result = decorated.execute(new StepContext(resolver));

    assertThat(result.isSuccess()).isTrue();
    assertThat(counter.get()).isEqualTo(2);
}
```

- [ ] **Step 7: Update RetryDirective.Full with `on` field**

```java
record Full(int max, String backoff, Duration delay, List<String> on) implements RetryDirective {
    public Full(int max, String backoff, Duration delay) { this(max, backoff, delay, List.of()); }
    // ... existing validation
}
// In parse() map handling:
@SuppressWarnings("unchecked")
List<String> on = m.containsKey("on") ? (List<String>) m.get("on") : List.of();
```

- [ ] **Step 8: Update wrapRetry for category filtering**

In the retry loop, after getting a failure, check category:

```java
if (!last.isSuccess() && !onCategories.isEmpty()) {
    String failCat = (last instanceof Result.Failure f) ? f.category() : null;
    if (failCat != null && !onCategories.contains(failCat)) {
        return last; // don't retry — category not in on: list
    }
    // null category always retries (backwards compatible)
}
```

- [ ] **Step 9: Run all tests, verify pass**

Run: `mvn --batch-mode test -pl yaml-plugin-api,yaml-core,yaml-step-runtime -Dtest="ResultFailureCategoryTest,WrapRetryConditionalTest,DecoratorChainTest"`

- [ ] **Step 10: Commit**

```bash
git commit -m "feat(#563): Result.Failure category + conditional retry via retry: { on: [...] }"
```

## Batch 2: Cancel + Background Decorators

After this batch: `cancel:` stops steps/loops when a signal fires, `background:` spawns and continues.

### Task 3: cancel: decorator

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java:54-72` (apply method) + new wrapCancel method
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepSchemaComposer.java` (DECORATOR_KEYS)
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/WrapCancelDecoratorTest.java`

**Interfaces:**
- Consumes: `OrcSignal` from yaml-core, `ExecutionScope.signal(String)` for signal registration
- Produces: `wrapCancel` decorator — signal-triggered interrupt of inner execution

- [ ] **Step 1: Write failing tests**

```java
// WrapCancelDecoratorTest.java
@Test
void cancelInterruptsRunningStep() throws Exception {
    var scope = new DefaultExecutionScope();
    var chain = new DecoratorChain(new ConditionEvaluator(null), SpeedMultiplier.identity(), scope);
    var started = new CountDownLatch(1);
    var result = new CompletableFuture<Result>();

    DecoratedExecution inner = ctx -> {
        started.countDown();
        try { Thread.sleep(5000); } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return Result.failed("interrupted");
        }
        return Result.of(Map.of());
    };

    var decorated = chain.apply(Map.of("cancel", "stop-signal"), inner);
    Thread.ofVirtual().start(() -> result.complete(decorated.execute(new StepContext(resolver))));

    started.await(1, TimeUnit.SECONDS);
    Thread.sleep(50);
    scope.signal("stop-signal").signal(); // fire the cancel signal

    Result r = result.get(2, TimeUnit.SECONDS);
    assertThat(r.isSuccess()).isFalse();
}

@Test
void cancelOnAlreadySignalledFiresImmediately() {
    var scope = new DefaultExecutionScope();
    scope.signal("already-done").signal();
    var chain = new DecoratorChain(new ConditionEvaluator(null), SpeedMultiplier.identity(), scope);

    DecoratedExecution inner = ctx -> {
        try { Thread.sleep(5000); } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return Result.failed("interrupted");
        }
        return Result.of(Map.of());
    };

    var decorated = chain.apply(Map.of("cancel", "already-done"), inner);
    Result r = decorated.execute(new StepContext(resolver));
    assertThat(r.isSuccess()).isFalse();
}

@Test
void cancelComposesWithLoop() throws Exception {
    var scope = new DefaultExecutionScope();
    var chain = new DecoratorChain(new ConditionEvaluator(null), SpeedMultiplier.identity(), scope);
    var iterations = new AtomicInteger(0);
    var result = new CompletableFuture<Result>();

    DecoratedExecution inner = ctx -> {
        iterations.incrementAndGet();
        try { Thread.sleep(50); } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return Result.failed("interrupted");
        }
        return Result.of(Map.of());
    };

    var decorated = chain.apply(Map.of("loop", "continuous", "cancel", "stop"), inner);
    Thread.ofVirtual().start(() -> result.complete(decorated.execute(new StepContext(resolver))));

    Thread.sleep(200);
    scope.signal("stop").signal();

    result.get(2, TimeUnit.SECONDS);
    assertThat(iterations.get()).isGreaterThan(1);
}
```

- [ ] **Step 2: Run to verify failure**

- [ ] **Step 3: Add wrapCancel to DecoratorChain**

Position: between `wrapForEach` (position 2) and `wrapLoop` (position 3) — cancel wraps the loop so it cancels the entire loop.

In `apply()`:
```java
current = wrapLoop(current, decorators);            // 5
current = wrapCancel(current, decorators);           // 4 — signal-triggered cancel
current = wrapForEach(current, decorators);         // 2
```

The `wrapCancel` method:

```java
private DecoratedExecution wrapCancel(DecoratedExecution inner, Map<String, Object> decorators) {
    Object cancelVal = decorators.get("cancel");
    if (cancelVal == null) return inner;
    if (scope == null) return ctx -> Result.failed("'cancel' requires an ExecutionScope");

    String signalName = String.valueOf(cancelVal);
    return ctx -> {
        OrcSignal signal = scope.signal(signalName);

        // Already signalled — cancel immediately
        if (signal.isSignalled()) {
            return Result.failed("Cancelled by signal '" + signalName + "'");
        }

        Thread executionThread = Thread.currentThread();
        // Register listener to interrupt when signal fires
        Runnable cancelListener = () -> executionThread.interrupt();
        // Use a virtual thread to watch the signal
        Thread watcher = Thread.ofVirtual().start(() -> {
            try {
                signal.await();
                executionThread.interrupt();
            } catch (InterruptedException e) {
                // watcher interrupted — step completed normally
            }
        });

        try {
            return inner.execute(ctx);
        } finally {
            watcher.interrupt(); // stop the watcher
        }
    };
}
```

- [ ] **Step 4: Add "cancel" to DECORATOR_KEYS in StepSchemaComposer**

- [ ] **Step 5: Run tests, verify pass**

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(#563): cancel: decorator — signal-triggered cancellation"
```

### Task 4: background: decorator

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java` (apply + new wrapBackground)
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepSchemaComposer.java` (DECORATOR_KEYS)
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/WrapBackgroundDecoratorTest.java`

**Interfaces:**
- Consumes: `ExecutionScope.spawn(String, Runnable)` — spawns virtual thread in scope
- Produces: `wrapBackground` decorator — spawns inner execution, returns immediately

- [ ] **Step 1: Write failing tests**

```java
// WrapBackgroundDecoratorTest.java
@Test
void backgroundReturnsImmediately() {
    var scope = new DefaultExecutionScope();
    var chain = new DecoratorChain(new ConditionEvaluator(null), SpeedMultiplier.identity(), scope);
    var started = new CountDownLatch(1);

    DecoratedExecution inner = ctx -> {
        started.countDown();
        try { Thread.sleep(5000); } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        return Result.of(Map.of());
    };

    var decorated = chain.apply(Map.of("background", true), inner);
    long start = System.currentTimeMillis();
    Result result = decorated.execute(new StepContext(resolver));
    long elapsed = System.currentTimeMillis() - start;

    assertThat(result.isSuccess()).isTrue();
    assertThat(elapsed).isLessThan(1000); // returned immediately, didn't wait 5s
}

@Test
void backgroundTaskRunsInScope() throws Exception {
    var scope = new DefaultExecutionScope();
    var chain = new DecoratorChain(new ConditionEvaluator(null), SpeedMultiplier.identity(), scope);
    var executed = new CompletableFuture<Boolean>();

    DecoratedExecution inner = ctx -> {
        executed.complete(true);
        return Result.of(Map.of());
    };

    chain.apply(Map.of("background", true), inner).execute(new StepContext(resolver));
    assertThat(executed.get(2, TimeUnit.SECONDS)).isTrue();
}

@Test
void backgroundTaskCancelledOnScopeClose() throws Exception {
    var scope = new DefaultExecutionScope();
    var chain = new DecoratorChain(new ConditionEvaluator(null), SpeedMultiplier.identity(), scope);
    var interrupted = new CompletableFuture<Boolean>();

    DecoratedExecution inner = ctx -> {
        try { Thread.sleep(60_000); } catch (InterruptedException e) {
            interrupted.complete(true);
        }
        return Result.of(Map.of());
    };

    chain.apply(Map.of("background", true), inner).execute(new StepContext(resolver));
    Thread.sleep(50);
    scope.close();

    assertThat(interrupted.get(2, TimeUnit.SECONDS)).isTrue();
}
```

- [ ] **Step 2: Run to verify failure**

- [ ] **Step 3: Implement wrapBackground**

Position: between `wrapCancel` and `wrapForEach`:

```java
// In apply():
current = wrapCancel(current, decorators);           // 4
current = wrapBackground(current, decorators);       // 3 — spawn and return
current = wrapForEach(current, decorators);          // 2
```

```java
private DecoratedExecution wrapBackground(DecoratedExecution inner, Map<String, Object> decorators) {
    Object bgVal = decorators.get("background");
    if (bgVal == null || !Boolean.TRUE.equals(bgVal)) return inner;
    if (scope == null) return ctx -> Result.failed("'background' requires an ExecutionScope");

    return ctx -> {
        scope.spawn("background", () -> inner.execute(ctx));
        return Result.of(Map.of());
    };
}
```

- [ ] **Step 4: Add "background" to DECORATOR_KEYS**

- [ ] **Step 5: Run tests, verify pass**

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(#563): background: decorator — spawn-and-continue via scope.spawn()"
```

## Batch 3: Primitive Variables + forEach Collect + Schema + ADR

After this batch: primitive values accessible in conditions, forEach collects all results, schema and ADR updated.

### Task 5: Primitive variable resolution

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/PrimitiveVariableSource.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java` (wire PrimitiveVariableSource into step context)
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/PrimitiveVariableSourceTest.java`

**Interfaces:**
- Consumes: `ExecutionScope` — reads primitive values
- Produces: `PrimitiveVariableSource implements VariableSource` — resolves `flag.*`, `counter.*`, `gauge.*`, `signal.*`, `accumulator.*`

- [ ] **Step 1: Write failing tests**

```java
// PrimitiveVariableSourceTest.java
@Test
void resolvesCounterValue() {
    var scope = new DefaultExecutionScope();
    scope.counter("supply").add(42);
    var source = new PrimitiveVariableSource(scope);
    assertThat(source.resolve("counter.supply")).isEqualTo("42");
}

@Test
void resolvesFlagValue() {
    var scope = new DefaultExecutionScope();
    scope.flag("ready").set();
    var source = new PrimitiveVariableSource(scope);
    assertThat(source.resolve("flag.ready")).isEqualTo("true");
}

@Test
void resolvesSignalState() {
    var scope = new DefaultExecutionScope();
    scope.signal("done").signal();
    var source = new PrimitiveVariableSource(scope);
    assertThat(source.resolve("signal.done")).isEqualTo("true");
}

@Test
void returnsNullForUnknownPrimitive() {
    var scope = new DefaultExecutionScope();
    var source = new PrimitiveVariableSource(scope);
    assertThat(source.resolve("counter.nonexistent")).isNull();
}
```

- [ ] **Step 2: Run to verify failure**

- [ ] **Step 3: Create PrimitiveVariableSource**

```java
package io.casehub.yaml.step.eval;

import io.casehub.yaml.core.orchestration.*;
import io.casehub.yaml.core.resolver.VariableSource;

public final class PrimitiveVariableSource implements VariableSource {
    private final ExecutionScope scope;

    public PrimitiveVariableSource(ExecutionScope scope) {
        this.scope = scope;
    }

    @Override
    public String resolve(String name) {
        int dot = name.indexOf('.');
        if (dot < 0) return null;
        String prefix = name.substring(0, dot);
        String primName = name.substring(dot + 1);

        try {
            return switch (prefix) {
                case "counter" -> String.valueOf(scope.primitive(primName, OrcCounter.class).get());
                case "flag" -> String.valueOf(scope.primitive(primName, OrcFlag.class).get());
                case "signal" -> String.valueOf(scope.primitive(primName, OrcSignal.class).isSignalled());
                case "gauge" -> String.valueOf(scope.primitive(primName, OrcGauge.class).get());
                case "accumulator" -> String.valueOf(scope.primitive(primName, OrcAccumulator.class).get());
                default -> null;
            };
        } catch (Exception e) {
            return null;
        }
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(#563): PrimitiveVariableSource — flag/counter/gauge/signal/accumulator in conditions"
```

### Task 6: forEach collect + StepSchemaComposer + ADR-0011

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java:291-300` (executeForEachSequential) + `302-330` (executeForEachParallel)
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepSchemaComposer.java`
- Modify: `docs/adr/0011-three-layer-evaluation-model-keyword-reservation.md`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/ForEachCollectTest.java`

**Interfaces:**
- Produces: `forEach: { in: list, as: item, collect: all }` — returns list of all iteration results

- [ ] **Step 1: Write failing tests**

```java
// ForEachCollectTest.java
@Test
@SuppressWarnings("unchecked")
void collectAllReturnsListOfResults() {
    var chain = new DecoratorChain(new ConditionEvaluator(null), SpeedMultiplier.identity());
    var resolver = new VariableResolver(Map.of("items", List.of("a", "b", "c")), Set.of());

    DecoratedExecution inner = ctx -> Result.of(Map.of("value", ctx.resolver().resolveString("${each.item}", "test")));

    var decorated = chain.apply(Map.of("forEach", Map.of("in", "${items}", "as", "item", "collect", "all")), inner);
    Result result = decorated.execute(new StepContext(resolver));

    assertThat(result.isSuccess()).isTrue();
    var collected = (List<Map<String, Object>>) result.output().get("collected");
    assertThat(collected).hasSize(3);
    assertThat(collected.get(0).get("value")).isEqualTo("a");
    assertThat(collected.get(1).get("value")).isEqualTo("b");
    assertThat(collected.get(2).get("value")).isEqualTo("c");
}

@Test
void withoutCollectReturnsLastResult() {
    var chain = new DecoratorChain(new ConditionEvaluator(null), SpeedMultiplier.identity());
    var resolver = new VariableResolver(Map.of("items", List.of("a", "b", "c")), Set.of());

    DecoratedExecution inner = ctx -> Result.of(Map.of("value", ctx.resolver().resolveString("${each.item}", "test")));

    var decorated = chain.apply(Map.of("forEach", Map.of("in", "${items}", "as", "item")), inner);
    Result result = decorated.execute(new StepContext(resolver));

    assertThat(result.isSuccess()).isTrue();
    assertThat(result.output().get("value")).isEqualTo("c"); // last item only
}
```

- [ ] **Step 2: Run to verify failure**

- [ ] **Step 3: Update wrapForEach to pass collect flag**

In `wrapForEach`, read the `collect` option and pass to sequential/parallel methods:

```java
boolean collect = "all".equals(forEachMap.get("collect"));
// Pass to executeForEachSequential/Parallel
```

In `executeForEachSequential`:
```java
if (collect) {
    var collected = new ArrayList<Map<String, Object>>();
    for (int i = 0; i < items.size(); i++) {
        VariableResolver scoped = pushEachContext(ctx.resolver(), as, items.get(i), i);
        Result r = inner.execute(ctx.withResolver(scoped));
        if (!r.isSuccess()) { return r; }
        collected.add(r.output());
    }
    return Result.of(Map.of("collected", collected));
}
// else: existing behavior (return last)
```

- [ ] **Step 4: Update StepSchemaComposer**

Add `"cancel"`, `"background"` to `DECORATOR_KEYS`. Add typed schemas:

```java
// cancel: string (signal name)
sharedProps.putObject("cancel").put("type", "string");
// background: boolean
sharedProps.putObject("background").put("type", "boolean");
```

Update `loop:` schema to include `"continuous"` as a valid string value.

- [ ] **Step 5: Update ADR-0011**

Add `cancel` and `background` as imperative-layer keywords.

- [ ] **Step 6: Run all tests across all modules**

Run: `mvn --batch-mode test -pl yaml-plugin-api,yaml-core,yaml-step-runtime`

- [ ] **Step 7: Commit**

```bash
git commit -m "feat(#563): forEach collect, StepSchemaComposer updates, ADR-0011 cancel+background keywords"
```

## References

- [GitHub #563](https://github.com/casehubio/platform/issues/563) — focal issue (spec is issue body)
- [GitHub #562](https://github.com/casehubio/platform/issues/562) — prior feature set (landed)
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/LoopDirective.java:5-47` — sealed interface to extend
- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Result.java:24-38` — Failure record to extend
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/RetryDirective.java:6-40` — retry parsing
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java:54-72` — apply() method, decorator ordering
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java:99-133` — wrapLoop
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java:190-232` — wrapRetry
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java:264-330` — wrapForEach
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepSchemaComposer.java` — DECORATOR_KEYS
- `docs/adr/0011-three-layer-evaluation-model-keyword-reservation.md` — keyword reservation
