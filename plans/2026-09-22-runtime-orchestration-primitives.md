# Runtime Orchestration Primitives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #386 — Runtime orchestration primitives for YAML-defined workflows
**Issue group:** #386

**Goal:** Add runtime evaluation contracts to yaml-core and build a new orchestration-core module with thread-safe coordination primitives (Semaphore, Latch, Signal, Channel, StateMachine).

**Architecture:** Two-tier addition. yaml-core gains pure contracts (ObjectVariableSource, Condition, ConditionEvaluator, RuntimeForEach, SpeedMultiplier) — zero-dep, J2CL-safe. New orchestration-core module provides thread-safe coordination primitives via java.util.concurrent, plus DurationParser, StepResultStore, and ScenarioScope lifecycle management. Step decorator evaluators (LoopEvaluator, TriggerEvaluator, etc.) live in consuming modules (casehub-pages) — not in this issue.

**Tech Stack:** Java 21+, JUnit 5, AssertJ, java.util.concurrent (virtual threads, CAS, BlockingQueue, Semaphore)

## Global Constraints

- yaml-core: zero dependencies, J2CL-transpilable — no j.u.c types in yaml-core interfaces
- orchestration-core: JDK-only — no platform-api, no governance, no CDI
- All coordination primitives: thread-safe by design, virtual-thread-first blocking interfaces
- Package: `io.casehub.yaml.core.runtime` (yaml-core contracts), `io.casehub.orchestration` (orchestration-core)
- Naming: `Orc` prefix for coordination interfaces (OrcSemaphore, OrcLatch, OrcSignal, OrcChannel, OrcStateMachine) to avoid java.util.concurrent name collisions

---

## Batch 1: yaml-core Runtime Contracts

### Task 1: ObjectVariableSource + VariableResolver typed resolution

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/ObjectVariableSource.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/resolver/ObjectVariableSourceTest.java`
- Extend: `yaml-core/src/test/java/io/casehub/yaml/core/resolver/VariableResolverTest.java`

**Interfaces:**
- Produces: `ObjectVariableSource` (functional interface: `Object resolve(String name)`), `VariableResolver.withObjectScope(String prefix, ObjectVariableSource source)`, `VariableResolver.resolve(Object)` typed pass-through for sole-references

- [ ] **Step 1: Write failing test for ObjectVariableSource**

```java
// ObjectVariableSourceTest.java
@Test
void soleReference_returnsTypedObject() {
    Map<String, Object> stepResult = Map.of("price", 42.5, "symbol", "AAPL");
    ObjectVariableSource source = name -> {
        if ("myStep".equals(name)) return stepResult;
        return null;
    };
    VariableResolver resolver = new VariableResolver(Map.of(), Set.of())
            .withObjectScope("result", source);

    Object resolved = resolver.resolve("${result.myStep}");
    assertThat(resolved).isEqualTo(stepResult);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn test -pl yaml-core -Dtest=ObjectVariableSourceTest#soleReference_returnsTypedObject -DfailIfNoTests=false`
Expected: FAIL — `ObjectVariableSource` class doesn't exist, `withObjectScope` method doesn't exist

- [ ] **Step 3: Create ObjectVariableSource interface**

```java
// ObjectVariableSource.java
package io.casehub.yaml.core.resolver;

@FunctionalInterface
public interface ObjectVariableSource {
    Object resolve(String name);
}
```

- [ ] **Step 4: Add withObjectScope to VariableResolver**

Add field `Map<String, ObjectVariableSource> objectPrefixSources` to VariableResolver. Add constructor overload and `withObjectScope()` method. Modify `resolve(Object value)` to detect sole-references (`value.startsWith("${") && value.endsWith("}") && value.indexOf('}') == value.length() - 1`) and resolve via ObjectVariableSource when available.

Use `ide_insert_member` for the new field and methods, `ide_replace_member` for the modified `resolve(Object)`.

- [ ] **Step 5: Run test to verify it passes**

Run: `mvn test -pl yaml-core -Dtest=ObjectVariableSourceTest#soleReference_returnsTypedObject`
Expected: PASS

- [ ] **Step 6: Write remaining ObjectVariableSource tests**

```java
@Test void soleReference_drillsNestedFields()
// ${result.myStep.price} → resolves to 42.5 via drillFields

@Test void interpolation_fallsBackToStringSource()
// "price is ${result.myStep.price}" → String concatenation, not typed

@Test void soleReference_noObjectSource_fallsBackToStringSource()
// ${var.name} with only VariableSource registered → returns String

@Test void objectSource_returnsNull_fallsBackToStringSource()
// ObjectVariableSource returns null → tries VariableSource

@Test void nestedFieldDrilling_mapHierarchy()
// ${result.step.nested.deep.field} → drills through nested Maps

@Test void errorMapResolution()
// ${result.step.error.message} → drills into StepError-like Map
```

- [ ] **Step 7: Implement remaining behaviour and verify all tests pass**

Run: `mvn test -pl yaml-core -Dtest=ObjectVariableSourceTest`
Expected: all PASS

- [ ] **Step 8: Extend VariableResolverTest with typed resolution cases**

Add to existing VariableResolverTest:
```java
@Test void withObjectScope_soleReference_returnsObject()
@Test void withObjectScope_interpolation_usesStringFallback()
@Test void withObjectScope_andStringScope_objectTakesPrecedence()
```

- [ ] **Step 9: Run full yaml-core test suite**

Run: `mvn test -pl yaml-core`
Expected: all PASS (no regressions)

- [ ] **Step 10: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/resolver/ObjectVariableSource.java
git add yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java
git add yaml-core/src/test/java/io/casehub/yaml/core/resolver/ObjectVariableSourceTest.java
git add yaml-core/src/test/java/io/casehub/yaml/core/resolver/VariableResolverTest.java
git commit -m "feat(#386): add ObjectVariableSource and typed resolution to VariableResolver"
```

---

### Task 2: Condition, ConditionEvaluator, SpeedMultiplier, RuntimeForEach

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/runtime/Condition.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/runtime/RuntimeForEach.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/runtime/SpeedMultiplier.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/condition/ConditionEvaluator.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/condition/ConditionEvaluationException.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/condition/ConditionEvaluatorTest.java`
- Extend: `yaml-core/src/test/java/io/casehub/yaml/core/condition/TruthinessTest.java`

**Interfaces:**
- Consumes: `Truthiness.isTruthy(String)` from Task 0 (existing)
- Produces: `Condition` (functional: `boolean evaluate()`), `ConditionEvaluator` (evaluates `when` strings via Truthiness + expression delegate), `RuntimeForEach` (functional: `List<?> resolve()`), `SpeedMultiplier` (functional: `double currentSpeed()`)

- [ ] **Step 1: Write failing test for ConditionEvaluator**

```java
// ConditionEvaluatorTest.java
@Test
void simpleTruthyValue_returnsTrue() {
    ConditionEvaluator evaluator = new ConditionEvaluator(null);
    assertThat(evaluator.evaluate("true")).isTrue();
}

@Test
void simpleFalsyValue_returnsFalse() {
    ConditionEvaluator evaluator = new ConditionEvaluator(null);
    assertThat(evaluator.evaluate("false")).isFalse();
}

@Test
void equalityExpression_delegatesToExpressionFunction() {
    Function<String, Boolean> exprDelegate = expr -> expr.contains("==") && expr.contains("HIGH");
    ConditionEvaluator evaluator = new ConditionEvaluator(exprDelegate);
    assertThat(evaluator.evaluate("HIGH == 'HIGH'")).isTrue();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn test -pl yaml-core -Dtest=ConditionEvaluatorTest -DfailIfNoTests=false`
Expected: FAIL — classes don't exist

- [ ] **Step 3: Create runtime contracts**

```java
// Condition.java
package io.casehub.yaml.core.runtime;

@FunctionalInterface
public interface Condition {
    boolean evaluate();
}

// RuntimeForEach.java
package io.casehub.yaml.core.runtime;

@FunctionalInterface
public interface RuntimeForEach {
    java.util.List<?> resolve();
}

// SpeedMultiplier.java
package io.casehub.yaml.core.runtime;

@FunctionalInterface
public interface SpeedMultiplier {
    double currentSpeed();
}
```

- [ ] **Step 4: Create ConditionEvaluator**

```java
// ConditionEvaluator.java
package io.casehub.yaml.core.condition;

import java.util.function.Function;

public final class ConditionEvaluator {

    private final Function<String, Boolean> expressionDelegate;

    public ConditionEvaluator(Function<String, Boolean> expressionDelegate) {
        this.expressionDelegate = expressionDelegate;
    }

    public boolean evaluate(String resolved) {
        // Try Truthiness first (true/false/yes/no/on/off/y/n/1/0)
        try {
            return Truthiness.isTruthy(resolved);
        } catch (IllegalArgumentException e) {
            // Not a simple boolean — delegate to expression engine
            if (expressionDelegate == null) {
                throw new ConditionEvaluationException(
                    "Cannot evaluate '" + resolved + "' — no expression engine configured", e);
            }
            return expressionDelegate.apply(resolved);
        }
    }
}
```

- [ ] **Step 5: Create ConditionEvaluationException**

```java
package io.casehub.yaml.core.condition;

public class ConditionEvaluationException extends RuntimeException {
    public ConditionEvaluationException(String message) { super(message); }
    public ConditionEvaluationException(String message, Throwable cause) { super(message, cause); }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn test -pl yaml-core -Dtest=ConditionEvaluatorTest`
Expected: PASS

- [ ] **Step 7: Write remaining ConditionEvaluator tests**

```java
@Test void nonBooleanWithoutDelegate_throwsConditionEvaluationException()
@Test void yesValue_returnsTrue()
@Test void noValue_returnsFalse()
@Test void expressionDelegate_receivesFullString()
@Test void expressionDelegate_throwsException_propagates()
```

- [ ] **Step 8: Implement and verify**

Run: `mvn test -pl yaml-core -Dtest=ConditionEvaluatorTest`
Expected: all PASS

- [ ] **Step 9: Run full yaml-core test suite**

Run: `mvn test -pl yaml-core`
Expected: all PASS

- [ ] **Step 10: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/runtime/
git add yaml-core/src/main/java/io/casehub/yaml/core/condition/ConditionEvaluator.java
git add yaml-core/src/main/java/io/casehub/yaml/core/condition/ConditionEvaluationException.java
git add yaml-core/src/test/java/io/casehub/yaml/core/condition/ConditionEvaluatorTest.java
git commit -m "feat(#386): add Condition, ConditionEvaluator, RuntimeForEach, SpeedMultiplier contracts"
```

---

## Batch 2: orchestration-core Module + Foundation

### Task 3: Module scaffolding + DurationParser + StepResultStore + ScenarioScope

**Files:**
- Create: `orchestration-core/pom.xml`
- Modify: `pom.xml` (parent — add `<module>orchestration-core</module>`)
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DurationParser.java`
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/StepResultStore.java`
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/StepError.java`
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ScenarioScope.java`
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultStepResultStore.java`
- Test: `../../yaml-core/src/test/java/io/casehub/yaml/core/orchestration/DurationParserTest.java`
- Test: `../../yaml-core/src/test/java/io/casehub/yaml/core/orchestration/DefaultStepResultStoreTest.java`

**Interfaces:**
- Produces: `DurationParser.parse(String) → Duration`, `StepResultStore` (interface), `StepError` (record), `ScenarioScope` (interface), `DefaultStepResultStore` (ConcurrentHashMap-backed)

- [ ] **Step 1: Create orchestration-core pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-orchestration-core</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Orchestration Core</name>
    <description>Thread-safe coordination primitives for runtime orchestration — Semaphore, Latch, Signal, Channel, StateMachine. JDK-only, virtual-thread-first.</description>

    <dependencies>
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>
</project>
```

- [ ] **Step 2: Add module to parent pom after yaml-core**

Use `ide_replace_text_in_file` to add `<module>orchestration-core</module>` after `<module>yaml-core</module>` in the parent pom.xml.

- [ ] **Step 3: Write failing DurationParser tests**

```java
// DurationParserTest.java
@Test void parsesMilliseconds() { assertThat(DurationParser.parse("500ms")).isEqualTo(Duration.ofMillis(500)); }
@Test void parsesSeconds() { assertThat(DurationParser.parse("5s")).isEqualTo(Duration.ofSeconds(5)); }
@Test void parsesMinutes() { assertThat(DurationParser.parse("2m")).isEqualTo(Duration.ofMinutes(2)); }
@Test void parsesHours() { assertThat(DurationParser.parse("1h")).isEqualTo(Duration.ofHours(1)); }
@Test void invalidSuffix_throws() { assertThatThrownBy(() -> DurationParser.parse("5x")).isInstanceOf(IllegalArgumentException.class); }
@Test void negativeDuration_throws() { assertThatThrownBy(() -> DurationParser.parse("-5s")).isInstanceOf(IllegalArgumentException.class); }
@Test void zeroDuration_allowed() { assertThat(DurationParser.parse("0s")).isEqualTo(Duration.ZERO); }
```

- [ ] **Step 4: Implement DurationParser**

```java
package io.casehub.orchestration;

import java.time.Duration;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class DurationParser {

    private static final Pattern PATTERN = Pattern.compile("^(\\d+)(ms|s|m|h)$");

    private DurationParser() {}

    public static Duration parse(String input) {
        Matcher matcher = PATTERN.matcher(input.trim());
        if (!matcher.matches()) {
            throw new IllegalArgumentException(
                "Invalid duration: '" + input + "'. Expected format: <number><ms|s|m|h>");
        }
        long value = Long.parseLong(matcher.group(1));
        return switch (matcher.group(2)) {
            case "ms" -> Duration.ofMillis(value);
            case "s" -> Duration.ofSeconds(value);
            case "m" -> Duration.ofMinutes(value);
            case "h" -> Duration.ofHours(value);
            default -> throw new IllegalArgumentException("Unknown suffix: " + matcher.group(2));
        };
    }
}
```

- [ ] **Step 5: Run DurationParser tests**

Run: `mvn test -pl orchestration-core -Dtest=DurationParserTest`
Expected: all PASS

- [ ] **Step 6: Create StepError, StepResultStore, DefaultStepResultStore**

```java
// StepError.java
package io.casehub.orchestration;
public record StepError(String message, String exceptionClass, String stackTrace) {}

// StepResultStore.java
package io.casehub.orchestration;
import java.util.Map;
public interface StepResultStore {
    void recordSuccess(String stepName, Map<String, Object> result);
    void recordFailure(String stepName, StepError error);
    Map<String, Object> result(String stepName);
    StepError error(String stepName);
    boolean hasCompleted(String stepName);
}

// DefaultStepResultStore.java — ConcurrentHashMap-backed
```

- [ ] **Step 7: Write and pass DefaultStepResultStore tests**

```java
@Test void recordSuccess_retrievable()
@Test void recordFailure_retrievable()
@Test void result_unknownStep_returnsNull()
@Test void error_succeededStep_returnsNull()
@Test void hasCompleted_afterSuccess_true()
@Test void hasCompleted_afterFailure_true()
@Test void hasCompleted_unknown_false()
```

- [ ] **Step 8: Create ScenarioScope interface**

```java
// ScenarioScope.java
package io.casehub.orchestration;
import java.time.Duration;
import java.util.concurrent.TimeUnit;
public interface ScenarioScope extends AutoCloseable {
    OrcSemaphore semaphore(String name, int permits);
    OrcSemaphore semaphore(String name, int permits, Duration window);
    OrcLatch latch(String name, int count);
    OrcSignal signal(String name);
    <T> OrcChannel<T> channel(String name);
    <T> OrcChannel<T> channel(String name, int capacity);
    <S extends Enum<S>> OrcStateMachine<S> stateMachine(String name, Class<S> stateType, S initialState);
    <T> T primitive(String name, Class<T> type);
    StepResultStore resultStore();
    @Override void close();
}
```

(This compiles once the Orc* interfaces exist — they're added in Batches 3-4.)

- [ ] **Step 9: Run full orchestration-core tests + mvn compile on parent**

Run: `mvn test -pl orchestration-core`
Run: `mvn compile -pl yaml-core,orchestration-core`
Expected: all PASS, compile succeeds

- [ ] **Step 10: Commit**

```bash
git add orchestration-core/ pom.xml
git commit -m "feat(#386): scaffold orchestration-core module — DurationParser, StepResultStore, ScenarioScope"
```

---

## Batch 3: Coordination Primitives — Semaphore + Latch

### Task 4: OrcSemaphore

**Files:**
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcSemaphore.java`
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcSemaphore.java`
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/SemaphoreReentrancyException.java`
- Test: `../../yaml-core/src/test/java/io/casehub/yaml/core/orchestration/OrcSemaphoreTest.java`
- Test: `../../yaml-core/src/test/java/io/casehub/yaml/core/orchestration/ConcurrentSemaphoreTest.java`

**Interfaces:**
- Produces: `OrcSemaphore` (acquire/tryAcquire/release/availablePermits), `DefaultOrcSemaphore` (j.u.c.Semaphore-backed, time-windowed permit replenishment, single-permit reentrancy detection via step context ID)

- [ ] **Step 1: Write failing tests for basic semaphore**

```java
@Test void acquireAndRelease_basic()
@Test void blocksWhenNoPermits()
@Test void releasesOnStepCompletion()
@Test void namedSharing_sameNameSameInstance() // tested via ScenarioScope later
@Test void differentNames_independent()
@Test void tryAcquireTimeout_returnsFalse()
@Test void availablePermits_tracksCorrectly()
```

- [ ] **Step 2: Implement OrcSemaphore interface + DefaultOrcSemaphore**

Interface: `acquire()`, `tryAcquire(long, TimeUnit)`, `release()`, `availablePermits()`.
Implementation: wraps `java.util.concurrent.Semaphore(permits, true)` (fair ordering).

- [ ] **Step 3: Run basic tests, verify pass**

- [ ] **Step 4: Add time-windowed permit replenishment tests**

```java
@Test void withTimeWindow_replenishesPermits()
@Test void withTimeWindow_permitsDoNotAccumulateBeyondMax()
```

- [ ] **Step 5: Implement time-windowed replenishment**

ScheduledExecutorService with virtual threads, periodic permit replenishment.

- [ ] **Step 6: Add reentrancy detection tests**

```java
@Test void singlePermit_reentrancy_throws()
@Test void multiPermit_noReentrancyTracking()
```

- [ ] **Step 7: Implement reentrancy detection for permits=1**

Track owning step context ID (String). On `acquire()`, check if current context already holds the permit.

- [ ] **Step 8: Write concurrent contention tests**

```java
// ConcurrentSemaphoreTest.java
@Test void multipleThreadsRespectPermitLimit()
// Spawn 10 virtual threads, semaphore with 3 permits, verify max 3 concurrent
@Test void noDeadlockUnderContention()
// Acquire/release in tight loop across 20 virtual threads, verify completes
```

- [ ] **Step 9: Run all semaphore tests**

Run: `mvn test -pl orchestration-core -Dtest="OrcSemaphoreTest,ConcurrentSemaphoreTest"`
Expected: all PASS

- [ ] **Step 10: Commit**

```bash
git add orchestration-core/src/main/java/io/casehub/orchestration/OrcSemaphore.java
git add orchestration-core/src/main/java/io/casehub/orchestration/DefaultOrcSemaphore.java
git add orchestration-core/src/main/java/io/casehub/orchestration/SemaphoreReentrancyException.java
git add orchestration-core/src/test/java/io/casehub/orchestration/OrcSemaphoreTest.java
git add orchestration-core/src/test/java/io/casehub/orchestration/ConcurrentSemaphoreTest.java
git commit -m "feat(#386): add OrcSemaphore — permits, time-window, reentrancy detection, concurrent tests"
```

---

### Task 5: OrcLatch

**Files:**
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcLatch.java`
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcLatch.java`
- Test: `../../yaml-core/src/test/java/io/casehub/yaml/core/orchestration/OrcLatchTest.java`
- Test: `../../yaml-core/src/test/java/io/casehub/yaml/core/orchestration/ConcurrentLatchTest.java`

**Interfaces:**
- Produces: `OrcLatch` (countDown/await/getCount), `DefaultOrcLatch` (CountDownLatch-backed)

- [ ] **Step 1: Write failing tests**

```java
@Test void countDown_decrementsCount()
@Test void await_blocksUntilZero()
@Test void await_timeout_returnsFalse()
@Test void alreadyZero_awaitReturnsImmediately()
```

- [ ] **Step 2: Implement OrcLatch interface + DefaultOrcLatch**

Wraps `java.util.concurrent.CountDownLatch`.

- [ ] **Step 3: Run tests, verify pass**

- [ ] **Step 4: Write concurrent tests**

```java
// ConcurrentLatchTest.java
@Test void multipleCountdowns_safeUnderContention()
// 5 virtual threads each countDown(), 1 thread awaits — verify unblocks after all 5
@Test void awaitAndCountdown_noDeadlock()
// Interleaved await and countDown from 10 threads
```

- [ ] **Step 5: Run all latch tests**

Run: `mvn test -pl orchestration-core -Dtest="OrcLatchTest,ConcurrentLatchTest"`
Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add orchestration-core/src/main/java/io/casehub/orchestration/OrcLatch.java
git add orchestration-core/src/main/java/io/casehub/orchestration/DefaultOrcLatch.java
git add orchestration-core/src/test/java/io/casehub/orchestration/OrcLatchTest.java
git add orchestration-core/src/test/java/io/casehub/orchestration/ConcurrentLatchTest.java
git commit -m "feat(#386): add OrcLatch — countdown synchronization with concurrent tests"
```

---

## Batch 4: Coordination Primitives — Signal + Channel

### Task 6: OrcSignal

**Files:**
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcSignal.java`
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcSignal.java`
- Test: `../../yaml-core/src/test/java/io/casehub/yaml/core/orchestration/OrcSignalTest.java`
- Test: `../../yaml-core/src/test/java/io/casehub/yaml/core/orchestration/ConcurrentSignalTest.java`

**Interfaces:**
- Produces: `OrcSignal` (signal/await/payload/isSignalled), `DefaultOrcSignal` (CompletableFuture-backed for one-shot, AtomicReference for repeatable)

- [ ] **Step 1: Write failing tests**

```java
@Test void signalAndAwait_basic()
@Test void awaitBeforeSignal_blocksUntilSignalled()
@Test void withPayload_payloadAccessible()
@Test void oneShotSignal_secondSignalIgnored()
@Test void alreadySignalled_awaitReturnsImmediately()
@Test void payloadRetention_accessibleAfterSignal()
```

- [ ] **Step 2: Implement OrcSignal interface + DefaultOrcSignal**

One-shot: `CompletableFuture<Object>` backing — `signal()` calls `complete()`, `await()` calls `get()`.
Repeatable: `AtomicReference<Object>` for latest-value, `CountDownLatch` per-waiter for blocking.

- [ ] **Step 3: Run tests, verify pass**

- [ ] **Step 4: Add repeatable signal tests**

```java
@Test void repeatableSignal_multipleSignals_latestPayload()
@Test void repeatableSignal_multipleWaiters_allUnblocked()
```

- [ ] **Step 5: Write concurrent tests**

```java
// ConcurrentSignalTest.java
@Test void signalAndAwait_safeUnderContention()
// 10 waiters, 1 signaller — all waiters unblock with correct payload
```

- [ ] **Step 6: Run all signal tests, commit**

```bash
git add orchestration-core/src/main/java/io/casehub/orchestration/OrcSignal.java
git add orchestration-core/src/main/java/io/casehub/orchestration/DefaultOrcSignal.java
git add orchestration-core/src/test/java/io/casehub/orchestration/OrcSignalTest.java
git add orchestration-core/src/test/java/io/casehub/orchestration/ConcurrentSignalTest.java
git commit -m "feat(#386): add OrcSignal — one-shot, repeatable, payload, broadcast semantics"
```

---

### Task 7: OrcChannel

**Files:**
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcChannel.java`
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcChannel.java`
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ChannelClosedException.java`
- Test: `../../yaml-core/src/test/java/io/casehub/yaml/core/orchestration/OrcChannelTest.java`
- Test: `../../yaml-core/src/test/java/io/casehub/yaml/core/orchestration/ConcurrentChannelTest.java`

**Interfaces:**
- Produces: `OrcChannel<T>` (send/receive/close/isErrorClosed), `DefaultOrcChannel` (LinkedBlockingQueue unbounded, ArrayBlockingQueue bounded), `ChannelClosedException`

- [ ] **Step 1: Write failing tests**

```java
@Test void sendAndReceive_basic()
@Test void blocksOnFullBounded()
@Test void blocksOnEmptyReceive()
@Test void close_drainThenClosed()
@Test void unbounded_neverBlocksOnSend()
@Test void sendOnClosedChannel_throwsChannelClosedException()
```

- [ ] **Step 2: Implement OrcChannel + DefaultOrcChannel**

Interface: `send(T)`, `send(T, long, TimeUnit)`, `receive()`, `receive(long, TimeUnit)`, `isEmpty()`, `close()`, `close(Throwable)`, `isErrorClosed()`, `closeError()`.
Unbounded: `LinkedBlockingQueue`. Bounded: `ArrayBlockingQueue(capacity)`. Atomic close flag with optional error cause.

- [ ] **Step 3: Run basic tests, verify pass**

- [ ] **Step 4: Add error-close tests**

```java
@Test void errorClose_producerFailure_consumersGetException()
@Test void errorClose_drainsRemainingBeforeError()
```

- [ ] **Step 5: Write concurrent tests**

```java
// ConcurrentChannelTest.java
@Test void producerConsumer_safeUnderContention()
// 3 producers, 2 consumers, bounded channel, verify all items delivered exactly once
@Test void multipleProducers_allDataDelivered()
@Test void multipleConsumers_eachItemDeliveredOnce()
```

- [ ] **Step 6: Run all channel tests, commit**

```bash
git add orchestration-core/src/main/java/io/casehub/orchestration/OrcChannel.java
git add orchestration-core/src/main/java/io/casehub/orchestration/DefaultOrcChannel.java
git add orchestration-core/src/main/java/io/casehub/orchestration/ChannelClosedException.java
git add orchestration-core/src/test/java/io/casehub/orchestration/OrcChannelTest.java
git add orchestration-core/src/test/java/io/casehub/orchestration/ConcurrentChannelTest.java
git commit -m "feat(#386): add OrcChannel — bounded/unbounded, close/error-close, concurrent tests"
```

---

## Batch 5: StateMachine + ScenarioScope Implementation

### Task 8: OrcStateMachine

**Files:**
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcStateMachine.java`
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultOrcStateMachine.java`
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/TransitionHandler.java`
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/StateHandler.java`
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/IllegalTransitionException.java`
- Test: `../../yaml-core/src/test/java/io/casehub/yaml/core/orchestration/OrcStateMachineTest.java`
- Test: `../../yaml-core/src/test/java/io/casehub/yaml/core/orchestration/ConcurrentStateMachineTest.java`

**Interfaces:**
- Produces: `OrcStateMachine<S extends Enum<S>>` (currentState/transition/onTransition/onEnter/onExit), `DefaultOrcStateMachine` (AtomicReference CAS), `TransitionHandler`, `StateHandler`

- [ ] **Step 1: Write failing tests**

```java
@Test void initialState_isSet()
@Test void validTransition_changesState()
@Test void invalidTransition_throws()
@Test void terminalState_rejectsTransitions()
@Test void stateQueryable()
```

- [ ] **Step 2: Implement OrcStateMachine interface + DefaultOrcStateMachine**

`AtomicReference<S>` for state. `Map<S, Map<S, TransitionDef>>` for valid transitions. CAS loop for atomic transitions. Terminal state set for rejection.

- [ ] **Step 3: Run basic tests, verify pass**

- [ ] **Step 4: Add guard and handler tests**

```java
@Test void guardCondition_preventsTransition()
@Test void guardCondition_returnsFalse_stateUnchanged()
@Test void transitionHandler_firesAfterCommit()
@Test void onEnter_firesOnStateEntry()
@Test void onExit_firesOnStateExit()
```

- [ ] **Step 5: Implement guards and handlers**

Guards: `Function<S, Boolean>` evaluated before CAS. Handlers: registered callbacks fired after CAS succeeds.

- [ ] **Step 6: Write concurrent tests**

```java
// ConcurrentStateMachineTest.java
@Test void atomicTransition_noDuplicateStates()
// 10 threads all try to transition from PENDING → APPROVED, exactly one wins
@Test void competingTransitions_exactlyOneWins()
@Test void observersSeeCommittedStateOnly()
```

- [ ] **Step 7: Run all state machine tests, commit**

```bash
git add orchestration-core/src/main/java/io/casehub/orchestration/OrcStateMachine.java
git add orchestration-core/src/main/java/io/casehub/orchestration/DefaultOrcStateMachine.java
git add orchestration-core/src/main/java/io/casehub/orchestration/TransitionHandler.java
git add orchestration-core/src/main/java/io/casehub/orchestration/StateHandler.java
git add orchestration-core/src/main/java/io/casehub/orchestration/IllegalTransitionException.java
git add orchestration-core/src/test/java/io/casehub/orchestration/OrcStateMachineTest.java
git add orchestration-core/src/test/java/io/casehub/orchestration/ConcurrentStateMachineTest.java
git commit -m "feat(#386): add OrcStateMachine — CAS transitions, guards, handlers, concurrent tests"
```

---

### Task 9: DefaultScenarioScope

**Files:**
- Create: `../../yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultScenarioScope.java`
- Test: `../../yaml-core/src/test/java/io/casehub/yaml/core/orchestration/ScenarioScopeTest.java`

**Interfaces:**
- Consumes: `OrcSemaphore`, `OrcLatch`, `OrcSignal`, `OrcChannel`, `OrcStateMachine`, `StepResultStore` (all from Tasks 4-8)
- Produces: `DefaultScenarioScope` (ConcurrentHashMap name-to-instance, idempotent creation via computeIfAbsent, lifecycle cleanup on close)

- [ ] **Step 1: Write failing tests**

```java
@Test void semaphore_sameNameReturnsSameInstance()
@Test void semaphore_differentNameReturnsDifferentInstance()
@Test void latch_createdWithCorrectCount()
@Test void signal_createdAndRetrievable()
@Test void channel_unboundedByDefault()
@Test void channel_boundedWithCapacity()
@Test void close_disposesAllPrimitives()
@Test void resultStore_returnsSameInstance()
@Test void primitive_genericLookup()
```

- [ ] **Step 2: Implement DefaultScenarioScope**

ConcurrentHashMap for name→instance mapping. Factory methods use `computeIfAbsent()` for idempotent creation. `close()` iterates all primitives and disposes (close channels, countdown latches to zero, signal all signals, release semaphore permits).

- [ ] **Step 3: Run tests, verify pass**

- [ ] **Step 4: Add concurrent access tests**

```java
@Test void concurrentAccess_sameNameSameInstance()
// 10 threads all call scope.semaphore("api", 3) — verify single instance created
@Test void close_unblocksWaiters()
// Thread awaiting a latch, scope.close() counts it down — thread unblocks
```

- [ ] **Step 5: Run full orchestration-core test suite**

Run: `mvn test -pl orchestration-core`
Expected: all PASS

- [ ] **Step 6: Run full project build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — yaml-core + orchestration-core compile and all tests pass

- [ ] **Step 7: Commit**

```bash
git add orchestration-core/src/main/java/io/casehub/orchestration/DefaultScenarioScope.java
git add orchestration-core/src/test/java/io/casehub/orchestration/ScenarioScopeTest.java
git commit -m "feat(#386): add DefaultScenarioScope — ConcurrentHashMap lifecycle, eager init, cleanup"
```

---

## References

- [2026-09-22-runtime-orchestration-primitives-design.md](../specs/issue-386-runtime-orchestration/2026-09-22-runtime-orchestration-primitives-design.md) — design spec this plan implements
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java` — existing variable resolution
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableSource.java` — existing variable source interface with drillFields
- `yaml-core/src/main/java/io/casehub/yaml/core/condition/Truthiness.java` — existing boolean string evaluation
- `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ForEachExpander.java` — existing parse-time forEach pattern
- `simulation-config-core/.../DurationParser.java` — existing duration parsing (ms/s/m only)
- `governance-core/.../PolicyEnforcer.java` — existing policy enforcement SPI
- decisions.md D1-D6 — design decisions
- GitHub #386 — focal issue
- GitHub #391 — DX refinements follow-up (shorthands, defaults)
- GitHub #402 — error reporting model follow-up
