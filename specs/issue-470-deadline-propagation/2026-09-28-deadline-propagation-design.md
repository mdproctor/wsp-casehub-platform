# Deadline Propagation — Design Spec

**Issue:** #470
**Branch:** issue-469-barrier-quorum-sugar
**Date:** 2026-09-28
**Depends on:** #469 (barrier/quorum sugar — landed on branch), #410 (deadline + condition combinators — landed on main)

## Overview

Wire deadline awareness through the step runtime so that inner steps, blocking decorators, and nested evaluations can query remaining time and respond cooperatively to deadline expiry. The decorator chain's `wrapTimeout` currently uses `Future.get(timeout)` with no propagation — inner steps block indefinitely, unaware they're in a timeout block.

**Module scope:** `yaml-step-runtime` only. No yaml-core changes — `OrcSignal.await(timeout, unit)` and `OrcSemaphore.tryAcquire(timeout, unit)` already exist.

## 1. DeadlineContext

New immutable value type tracking the effective absolute deadline in nanos. Composable via `withTimeout()` which does `Math.min(existing, now + timeout)` — nested timeouts naturally produce the tighter deadline.

```java
package io.casehub.yaml.step.eval;

public final class DeadlineContext {
    public static final DeadlineContext NONE = new DeadlineContext(Long.MAX_VALUE);

    private final long deadlineNanos;

    private DeadlineContext(long deadlineNanos) {
        this.deadlineNanos = deadlineNanos;
    }

    public DeadlineContext withTimeout(Duration timeout) {
        long candidate = System.nanoTime() + timeout.toNanos();
        return new DeadlineContext(Math.min(deadlineNanos, candidate));
    }

    public Optional<Duration> remainingTime() {
        if (deadlineNanos == Long.MAX_VALUE) return Optional.empty();
        long remaining = deadlineNanos - System.nanoTime();
        return Optional.of(remaining > 0 ? Duration.ofNanos(remaining) : Duration.ZERO);
    }

    public boolean isExpired() {
        return deadlineNanos != Long.MAX_VALUE && System.nanoTime() >= deadlineNanos;
    }

    public boolean hasDeadline() {
        return deadlineNanos != Long.MAX_VALUE;
    }
}
```

## 2. StepContext

Execution context threaded through the decorator chain and evaluator. Carries `VariableResolver` (existing) and `DeadlineContext` (new). Replaces the bare `VariableResolver` parameter on `DecoratedExecution`.

```java
package io.casehub.yaml.step.eval;

public final class StepContext {
    private final VariableResolver resolver;
    private final DeadlineContext deadline;

    public StepContext(VariableResolver resolver) {
        this(resolver, DeadlineContext.NONE);
    }

    public StepContext(VariableResolver resolver, DeadlineContext deadline) {
        this.resolver = resolver;
        this.deadline = deadline;
    }

    public VariableResolver resolver() { return resolver; }
    public DeadlineContext deadline() { return deadline; }

    public StepContext withResolver(VariableResolver resolver) {
        return new StepContext(resolver, this.deadline);
    }

    public StepContext withDeadline(Duration timeout) {
        return new StepContext(resolver, deadline.withTimeout(timeout));
    }
}
```

## 3. DecoratedExecution Interface Change

```java
// Before
@FunctionalInterface
public interface DecoratedExecution {
    StepResult execute(VariableResolver resolver);
}

// After
@FunctionalInterface
public interface DecoratedExecution {
    StepResult execute(StepContext ctx);
}
```

## 4. DecoratorChain Changes

The `scope` and `speedMultiplier` fields remain — the scope is for primitive access (signal, semaphore, latch), not deadline tracking. Only the deadline flows through StepContext.

### 4.1 Passthrough decorators (mechanical)

All decorators that don't interact with deadlines change `resolver` → `ctx` and `ctx.resolver()` where the resolver is needed. These are: `wrapWhen`, `wrapLoop`, `wrapOnError`, `wrapRetry`, `wrapDelay`, `wrapTransform`, `wrapForEach`, `wrapPostSignal`, `wrapTransition`.

### 4.2 wrapTimeout — creates deadline context

```java
private DecoratedExecution wrapTimeout(DecoratedExecution inner, Map<String, Object> decorators) {
    Object timeoutVal = decorators.get("timeout");
    if (timeoutVal == null) return inner;

    Duration timeout = DurationParser.parse(String.valueOf(timeoutVal));
    return ctx -> {
        double speed = speedMultiplier.currentSpeed();
        long adjustedMs = Math.max(1, (long) (timeout.toMillis() / speed));
        Duration adjusted = Duration.ofMillis(adjustedMs);

        StepContext deadlineCtx = ctx.withDeadline(adjusted);

        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            Future<StepResult> future = executor.submit(() -> inner.execute(deadlineCtx));
            try {
                return future.get(adjustedMs, TimeUnit.MILLISECONDS);
            } catch (TimeoutException e) {
                future.cancel(true);
                return StepResult.failed("Step timeout after " + timeout);
            } catch (java.util.concurrent.ExecutionException e) {
                return StepResult.failed("Step execution failed: " + e.getCause().getMessage());
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return StepResult.failed("Step interrupted during timeout");
        }
    };
}
```

Key: `ctx.withDeadline(adjusted)` composes with any existing deadline via `Math.min`. The inner execution receives the tighter deadline. `Future.get` still enforces the timeout.

### 4.3 wrapWait — deadline-bounded signal await

```java
private DecoratedExecution wrapWait(DecoratedExecution inner, Map<String, Object> decorators) {
    Object waitVal = decorators.get("wait");
    if (waitVal == null) return inner;
    if (scope == null) return ctx -> StepResult.failed("'wait' requires a ScenarioScope");

    String signalName = String.valueOf(waitVal);
    return ctx -> {
        OrcSignal signal = scope.signal(signalName);
        try {
            var remaining = ctx.deadline().remainingTime();
            if (remaining.isPresent()) {
                if (!signal.await(remaining.get().toMillis(), TimeUnit.MILLISECONDS)) {
                    return StepResult.failed(
                        "Wait for signal '" + signalName + "' exceeded deadline");
                }
            } else {
                signal.await();
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return StepResult.failed("Wait for signal '" + signalName + "' interrupted");
        }
        VariableResolver scoped = ScopeUtils.pushScope(ctx.resolver(), "signal", signal.payload());
        return inner.execute(ctx.withResolver(scoped));
    };
}
```

### 4.4 wrapSemaphore — deadline-bounded acquire

```java
private DecoratedExecution wrapSemaphore(DecoratedExecution inner, Map<String, Object> decorators) {
    // ... existing name/permits parsing unchanged ...
    return ctx -> {
        OrcSemaphore semaphore = scope.semaphore(name, permits);
        try {
            var remaining = ctx.deadline().remainingTime();
            if (remaining.isPresent()) {
                if (!semaphore.tryAcquire(remaining.get().toMillis(), TimeUnit.MILLISECONDS)) {
                    return StepResult.failed(
                        "Semaphore '" + name + "' acquire exceeded deadline");
                }
            } else {
                semaphore.acquire();
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return StepResult.failed("Semaphore '" + name + "' acquire interrupted");
        }
        try {
            return inner.execute(ctx);
        } finally {
            semaphore.release();
        }
    };
}
```

## 5. StructuralStepEvaluator Changes

### 5.1 Public API preserved

```java
// Unchanged — callers don't see StepContext
public StepResult evaluate(ResolvedStep step, VariableResolver resolver, StepRunner runner) {
    StepContext ctx = new StepContext(withResultScope(resolver));
    return evaluateInternal(step, ctx, runner);
}
```

### 5.2 Internal threading

A new private `evaluateInternal` takes `StepContext` and threads it through all dispatch methods. The scope field remains for result recording, latch/quorum tracking.

```java
private StepResult evaluateInternal(ResolvedStep step, StepContext ctx, StepRunner runner) {
    Map<String, Object> decorators = step.decorators();
    StepResult result;
    if (decorators.isEmpty()) {
        result = dispatchStep(step, ctx, runner);
    } else {
        result = decoratorChain.apply(decorators, c -> dispatchStep(step, c, runner))
                               .execute(ctx);
    }
    recordResult(step.name(), result);
    return result;
}
```

All `evaluateX` methods change from `(step, VariableResolver, StepRunner)` to `(step, StepContext, StepRunner)` and call `evaluateInternal` for recursion. Where they need the resolver (e.g., condition evaluation, scope pushing), they use `ctx.resolver()`.

### 5.3 evaluateParallel — deadline inheritance

Each child virtual thread receives the same `ctx`, so deadline awareness propagates automatically. No special deadline handling needed — if a child step has its own `timeout:`, its `wrapTimeout` call `ctx.withDeadline()` which composes via `Math.min`.

## 6. What This Does NOT Change

- **ScenarioScope** — no changes. scope stays as a field on evaluator/decorator chain for primitive access.
- **Result recording** — stays on root scope's StepResultStore.
- **Step latches and quorum tracking** — stays on root scope via evaluator's ConcurrentHashMaps.
- **Speed multiplier** — sampled once per wrapTimeout entry (same as current behaviour).
- **yaml-core** — no changes. Timed `await(timeout, unit)` and `tryAcquire(timeout, unit)` already exist.

## References

- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java` — primary change target
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java` — evaluator threading
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratedExecution.java` — interface change
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcSignal.java:9` — timed await already exists
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcSemaphore.java:7` — timed tryAcquire already exists
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ScenarioScope.java` — unchanged, deadline API already exists
- `specs/issue-469-barrier-quorum-sugar/2026-09-27-barrier-quorum-stepresultstore-design.md` — predecessor spec
- `specs/issue-410-orc-correlate-deadline-cond/2026-09-23-orc-correlate-deadline-cond-design.md` — deadline primitives spec
