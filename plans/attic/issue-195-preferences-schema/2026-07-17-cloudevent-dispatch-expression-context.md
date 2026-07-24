# CloudEvent Type Dispatch + Expression Engine Enhancements — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #176 — engine-api expression types migrate to platform SPI
**Issue group:** #174, #176, #177, #178

**Goal:** Add CloudEvent CDI type dispatch, MVEL Map/POJO/List context support, block expressions, and verify engine migration readiness.

**Architecture:** `@CloudEventType` CDI qualifier in platform-api, dispatcher in platform/. MvelExpressionEngine refactored for three-way context dispatch (Map/POJO/List) with block expression detection. No SPI changes — all work is in implementations.

**Tech Stack:** Jakarta CDI (qualifiers, async events), MVEL3 3.0.0-SNAPSHOT (transpiler), CloudEvents SDK, Quarkus

## Global Constraints

- platform-api must remain zero-dependency (jakarta.inject-api already present as provided)
- Pre-release: breaking changes are free — fix the design, never protect callers
- IntelliJ MCP mandatory for all .java edits — no bash grep/Edit on source files
- TDD: write failing test → verify fail → implement → verify pass → commit
- MVEL3 gotchas: `contains` keyword shadows `String.contains()` (use `indexOf`); single-quoted strings fail (use double quotes)

---

### Task 1: @CloudEventType CDI qualifier annotation

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/event/CloudEventType.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/event/CloudEventTypeTest.java`

**Interfaces:**
- Consumes: nothing
- Produces: `@CloudEventType(String value())` — CDI qualifier annotation used by Task 2

- [ ] **Step 1: Write the test**

```java
package io.casehub.platform.api.event;

import jakarta.inject.Qualifier;
import org.junit.jupiter.api.Test;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;
import static org.assertj.core.api.Assertions.assertThat;

class CloudEventTypeTest {

    @Test
    void annotation_isQualifier() {
        assertThat(CloudEventType.class.isAnnotationPresent(Qualifier.class)).isTrue();
    }

    @Test
    void annotation_hasRuntimeRetention() {
        Retention retention = CloudEventType.class.getAnnotation(Retention.class);
        assertThat(retention).isNotNull();
        assertThat(retention.value()).isEqualTo(RetentionPolicy.RUNTIME);
    }

    @Test
    void annotation_hasValueMember() throws NoSuchMethodException {
        var method = CloudEventType.class.getMethod("value");
        assertThat(method.getReturnType()).isEqualTo(String.class);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform-api -Dtest=CloudEventTypeTest -DfailIfNoTests=false`
Expected: FAIL — class does not exist

- [ ] **Step 3: Create the annotation**

Use `ide_create_file`:

```java
package io.casehub.platform.api.event;

import jakarta.inject.Qualifier;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;
import static java.lang.annotation.ElementType.*;

@Qualifier
@Retention(RetentionPolicy.RUNTIME)
@Target({TYPE, METHOD, FIELD, PARAMETER})
public @interface CloudEventType {
    String value();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl platform-api -Dtest=CloudEventTypeTest`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/event/CloudEventType.java platform-api/src/test/java/io/casehub/platform/api/event/CloudEventTypeTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#174): @CloudEventType CDI qualifier annotation in platform-api"
```

---

### Task 2: CloudEventTypeDispatcher + literal

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/event/CloudEventTypeLiteral.java`
- Create: `platform/src/main/java/io/casehub/platform/event/CloudEventTypeDispatcher.java`
- Test: `platform/src/test/java/io/casehub/platform/event/CloudEventTypeDispatcherTest.java`

**Interfaces:**
- Consumes: `@CloudEventType` from Task 1
- Produces: `CloudEventTypeDispatcher` — `@ApplicationScoped`, `@ObservesAsync CloudEvent`, re-fires with type qualifier

- [ ] **Step 1: Write the test**

```java
package io.casehub.platform.event;

import io.casehub.platform.api.event.CloudEventType;
import io.cloudevents.CloudEvent;
import io.cloudevents.core.builder.CloudEventBuilder;
import jakarta.enterprise.event.Event;
import jakarta.enterprise.util.TypeLiteral;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import java.lang.annotation.Annotation;
import java.net.URI;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;

import static org.assertj.core.api.Assertions.assertThat;

class CloudEventTypeDispatcherTest {

    private List<Annotation> selectedQualifiers;
    private List<CloudEvent> firedEvents;
    private CloudEventTypeDispatcher dispatcher;

    @BeforeEach
    void setUp() {
        selectedQualifiers = new ArrayList<>();
        firedEvents = new ArrayList<>();

        Event<CloudEvent> mockBus = new StubEvent<>() {
            @Override
            public Event<CloudEvent> select(Annotation... qualifiers) {
                selectedQualifiers.addAll(List.of(qualifiers));
                return this;
            }

            @Override
            public <U extends CloudEvent> CompletionStage<U> fireAsync(U event) {
                firedEvents.add(event);
                return CompletableFuture.completedFuture(event);
            }
        };

        dispatcher = new CloudEventTypeDispatcher(mockBus);
    }

    private CloudEvent cloudEvent(String type) {
        return CloudEventBuilder.v1()
                .withId("test-1")
                .withSource(URI.create("/test"))
                .withType(type)
                .build();
    }

    @Test
    void dispatches_withCorrectQualifier() {
        dispatcher.onCloudEvent(cloudEvent("io.casehub.cbr.outcome"));

        assertThat(selectedQualifiers).hasSize(1);
        assertThat(selectedQualifiers.get(0)).isInstanceOf(CloudEventType.class);
        assertThat(((CloudEventType) selectedQualifiers.get(0)).value())
                .isEqualTo("io.casehub.cbr.outcome");
        assertThat(firedEvents).hasSize(1);
    }

    @Test
    void skips_blankType() {
        var ce = CloudEventBuilder.v1()
                .withId("test-1")
                .withSource(URI.create("/test"))
                .withType("   ")
                .build();
        dispatcher.onCloudEvent(ce);

        assertThat(firedEvents).isEmpty();
    }

    @Test
    void literal_equalityByValue() {
        var a = new CloudEventTypeLiteral("io.casehub.cbr.outcome");
        var b = new CloudEventTypeLiteral("io.casehub.cbr.outcome");
        var c = new CloudEventTypeLiteral("io.casehub.other");

        assertThat(a).isEqualTo(b);
        assertThat(a.hashCode()).isEqualTo(b.hashCode());
        assertThat(a).isNotEqualTo(c);
    }
}
```

The test uses a `StubEvent` — a no-op base implementation of `Event<CloudEvent>`. Create it as a static inner class or a test helper:

```java
// Inner abstract class in the test file — all methods throw by default,
// test overrides only what it needs
static abstract class StubEvent<T> implements Event<T> {
    @Override public void fire(T event) { throw new UnsupportedOperationException(); }
    @Override public <U extends T> CompletionStage<U> fireAsync(U event) { throw new UnsupportedOperationException(); }
    @Override public <U extends T> CompletionStage<U> fireAsync(U event, java.util.concurrent.Executor notificationOptions) { throw new UnsupportedOperationException(); }
    @Override public Event<T> select(Annotation... qualifiers) { throw new UnsupportedOperationException(); }
    @Override public <U extends T> Event<U> select(Class<U> subtype, Annotation... qualifiers) { throw new UnsupportedOperationException(); }
    @Override public <U extends T> Event<U> select(TypeLiteral<U> subtype, Annotation... qualifiers) { throw new UnsupportedOperationException(); }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform -Dtest=CloudEventTypeDispatcherTest -DfailIfNoTests=false`
Expected: FAIL — classes do not exist

- [ ] **Step 3: Create CloudEventTypeLiteral**

Use `ide_create_file`:

```java
package io.casehub.platform.event;

import io.casehub.platform.api.event.CloudEventType;
import jakarta.enterprise.util.AnnotationLiteral;

public final class CloudEventTypeLiteral extends AnnotationLiteral<CloudEventType> implements CloudEventType {

    private final String value;

    public CloudEventTypeLiteral(String value) {
        this.value = value;
    }

    @Override
    public String value() {
        return value;
    }
}
```

- [ ] **Step 4: Create CloudEventTypeDispatcher**

Use `ide_create_file`:

```java
package io.casehub.platform.event;

import io.cloudevents.CloudEvent;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Event;
import jakarta.enterprise.event.ObservesAsync;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;

@ApplicationScoped
public class CloudEventTypeDispatcher {

    private static final Logger LOG = Logger.getLogger(CloudEventTypeDispatcher.class);

    private final Event<CloudEvent> cloudEventBus;

    @Inject
    public CloudEventTypeDispatcher(Event<CloudEvent> cloudEventBus) {
        this.cloudEventBus = cloudEventBus;
    }

    public void onCloudEvent(@ObservesAsync CloudEvent event) {
        String type = event.getType();
        if (type == null || type.isBlank()) {
            return;
        }
        cloudEventBus.select(new CloudEventTypeLiteral(type))
                .fireAsync(event)
                .exceptionally(ex -> {
                    LOG.errorf(ex, "Typed CloudEvent observer failed for type=%s, id=%s",
                               type, event.getId());
                    return event;
                });
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mvn --batch-mode test -pl platform -Dtest=CloudEventTypeDispatcherTest`
Expected: PASS

- [ ] **Step 6: Verify with diagnostics**

Run `ide_diagnostics` on both new files to check for errors.

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform/src/main/java/io/casehub/platform/event/ platform/src/test/java/io/casehub/platform/event/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#174): CloudEventTypeDispatcher — re-fires CloudEvents with @CloudEventType qualifier"
```

---

### Task 3: MVEL POJO context support + three-way dispatch refactor

**Files:**
- Modify: `expression/src/main/java/io/casehub/platform/expression/MvelExpressionEngine.java`
- Modify: `expression/src/test/java/io/casehub/platform/expression/MvelExpressionEngineTest.java`

**Interfaces:**
- Consumes: `ExpressionEngine` SPI, MVEL3 `MVEL.pojo()` / `MVEL.map()` APIs
- Produces: `MvelExpressionEngine` with Map and POJO dispatch — used by Task 4 (List) and Task 5 (blocks)

- [ ] **Step 1: Write POJO context tests**

Add to `MvelExpressionEngineTest.java` using `ide_insert_member`. First create a test POJO as a static inner class:

```java
public static class Person {
    private final String name;
    private final int age;

    public Person(String name, int age) {
        this.name = name;
        this.age = age;
    }

    public String getName() { return name; }
    public int getAge() { return age; }
}
```

Then add POJO test methods:

```java
@Test
void compile_pojoContext_fieldAccess() {
    CompiledExpression<Person, String> expr =
            engine.compile("name", Person.class, String.class);
    assertThat(expr.eval(new Person("Alice", 30))).isEqualTo("Alice");
}

@Test
void compile_pojoContext_booleanExpression() {
    CompiledExpression<Person, Boolean> expr =
            engine.compile("age > 20", Person.class, Boolean.class);
    assertThat(expr.eval(new Person("Alice", 30))).isTrue();
    assertThat(expr.eval(new Person("Bob", 15))).isFalse();
}

@Test
void compile_pojoContext_withVariables() {
    CompiledExpression<Person, Boolean> expr =
            engine.compile("name == $p0", Person.class, Boolean.class,
                           Map.of("$p0", "Alice"));
    assertThat(expr.eval(new Person("Alice", 30))).isTrue();
    assertThat(expr.eval(new Person("Bob", 30))).isFalse();
}

@Test
void compile_pojoContext_cachedSeparatelyFromMap() {
    CompiledExpression<?, ?> mapExpr = engine.compile("age > 20", MAP_TYPE, Boolean.class);
    CompiledExpression<?, ?> pojoExpr = engine.compile("age > 20", Person.class, Boolean.class);
    assertThat(mapExpr).isNotSameAs(pojoExpr);
}
```

- [ ] **Step 2: Run tests to verify POJO tests fail**

Run: `mvn --batch-mode test -pl expression -Dtest=MvelExpressionEngineTest`
Expected: POJO tests FAIL (ClassCastException or wrong behaviour), existing Map tests PASS

- [ ] **Step 3: Refactor MvelExpressionEngine for three-way dispatch**

Replace the `compile` method body, `compileWithTypes` static method, `LazyMvelExpression` inner class, and `CacheKey` record using `ide_edit_member` / `ide_replace_member`. The new implementation:

**Replace `compileWithTypes` with two static compile helpers:**

```java
@SuppressWarnings("unchecked")
static <R> Evaluator<Map<String, Object>, Void, R> compileMapExpression(
        String expression, Map<String, Object> evalContext, Class<R> resultType) {
    Map<String, Type<?>> types = MVEL.getTypeMap(evalContext);
    var builder = MVEL.<Object>map(Declaration.from(types)).<R>out(resultType);
    if (expression.indexOf(';') > 0) {
        builder.block(expression);
    } else {
        builder.expression(expression);
    }
    return builder.imports(Collections.emptySet()).compile();
}
```

**Two lazy inner classes replacing the single LazyMvelExpression:**

`LazyMapMvelExpression<R> implements CompiledExpression<Map<String, Object>, R>`:
- Stores `expression`, `resultType`, `boundVars`
- On first `eval(context)`: merges boundVars into context, calls `compileMapExpression`, stores delegate
- Subsequent evals use cached delegate

`LazyPojoMvelExpression<C, R> implements CompiledExpression<C, R>`:
- Stores `expression`, `contextType`, `resultType`, `boundVars`
- On first `eval(context)`: compiles via `MVEL.pojo(contextType)` (with or without `.with(Map.class)` for bound vars)
- Without bound vars: `MVEL.pojo(contextType).out(resultType).expression/block(expr).imports(emptySet()).compile()` → `Evaluator<C, Void, R>`, call `eval(context)`
- With bound vars: `MVEL.pojo(contextType, Declaration.from(getTypeMap(boundVars))).with(Map.class).out(resultType).expression/block(expr).imports(emptySet()).compile()` → `Evaluator<C, Map, R>`, call `eval(context, boundVarsMap)`

**Updated compile method dispatch:**

```java
@Override
@SuppressWarnings("unchecked")
public <C, R> CompiledExpression<C, R> compile(
        String expression, Class<C> contextType, Class<R> resultType,
        Map<String, Object> variables) {
    Objects.requireNonNull(expression, "expression");
    Objects.requireNonNull(contextType, "contextType");
    Objects.requireNonNull(resultType, "resultType");

    Map<String, Object> boundVars = variables.isEmpty() ? Map.of() : Map.copyOf(variables);
    var key = new CacheKey(expression, contextType, resultType, boundVars);

    return (CompiledExpression<C, R>) cache.computeIfAbsent(key, k -> {
        if (Map.class.isAssignableFrom(contextType)) {
            return new LazyMapMvelExpression<>(expression, resultType, boundVars);
        } else {
            return new LazyPojoMvelExpression<>(expression, contextType, resultType, boundVars);
        }
    });
}
```

- [ ] **Step 4: Run all tests**

Run: `mvn --batch-mode test -pl expression -Dtest=MvelExpressionEngineTest`
Expected: ALL PASS (existing Map tests + new POJO tests)

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add expression/src/main/java/io/casehub/platform/expression/MvelExpressionEngine.java expression/src/test/java/io/casehub/platform/expression/MvelExpressionEngineTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#177): MVEL POJO context support + three-way dispatch refactor"
```

---

### Task 4: MVEL List context support

**Files:**
- Modify: `expression/src/main/java/io/casehub/platform/expression/MvelExpressionEngine.java`
- Modify: `expression/src/test/java/io/casehub/platform/expression/MvelExpressionEngineTest.java`

**Interfaces:**
- Consumes: Three-way dispatch structure from Task 3
- Produces: `MvelExpressionEngine` with Map, POJO, and List context support

- [ ] **Step 1: Write List context tests**

Add to `MvelExpressionEngineTest.java`:

```java
@SuppressWarnings("unchecked")
private static final Class<List<Object>> LIST_TYPE =
        (Class<List<Object>>) (Class<?>) List.class;

@Test
void compile_listContext_indexAccess() {
    CompiledExpression<List<Object>, Object> expr =
            engine.compile("get(0)", LIST_TYPE, Object.class);
    assertThat(expr.eval(List.of("Alice", 30))).isEqualTo("Alice");
}

@Test
void compile_listContext_sizeCheck() {
    CompiledExpression<List<Object>, Boolean> expr =
            engine.compile("size() > 1", LIST_TYPE, Boolean.class);
    assertThat(expr.eval(List.of("a", "b"))).isTrue();
    assertThat(expr.eval(List.of("a"))).isFalse();
}

@Test
void compile_listContext_cachedSeparately() {
    CompiledExpression<?, ?> mapExpr = engine.compile("size() > 1", MAP_TYPE, Boolean.class);
    CompiledExpression<?, ?> listExpr = engine.compile("size() > 1", LIST_TYPE, Boolean.class);
    assertThat(mapExpr).isNotSameAs(listExpr);
}
```

- [ ] **Step 2: Run tests to verify List tests fail**

Run: `mvn --batch-mode test -pl expression -Dtest=MvelExpressionEngineTest`
Expected: List tests FAIL, all others PASS

- [ ] **Step 3: Add LazyListMvelExpression and update dispatch**

Add `LazyListMvelExpression<R> implements CompiledExpression<List, R>`:
- On first `eval(list)`: compiles via `MVEL.list().out(resultType).expression/block(expr).imports(emptySet()).compile()`
- With bound vars: `MVEL.list().with(Map.class).out(resultType)...` → `eval(list, boundVarsMap)`

Update dispatch in `compile()`:

```java
if (Map.class.isAssignableFrom(contextType)) {
    return new LazyMapMvelExpression<>(expression, resultType, boundVars);
} else if (List.class.isAssignableFrom(contextType)) {
    return new LazyListMvelExpression<>(expression, resultType, boundVars);
} else {
    return new LazyPojoMvelExpression<>(expression, contextType, resultType, boundVars);
}
```

- [ ] **Step 4: Run all tests**

Run: `mvn --batch-mode test -pl expression -Dtest=MvelExpressionEngineTest`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add expression/src/main/java/io/casehub/platform/expression/MvelExpressionEngine.java expression/src/test/java/io/casehub/platform/expression/MvelExpressionEngineTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#177): MVEL List context support — three-way dispatch complete"
```

---

### Task 5: MVEL block expression support

**Files:**
- Modify: `expression/src/main/java/io/casehub/platform/expression/MvelExpressionEngine.java` (already has block detection from Task 3 compile helpers)
- Modify: `expression/src/test/java/io/casehub/platform/expression/MvelExpressionEngineTest.java`

**Interfaces:**
- Consumes: Three-way dispatch with block detection from Tasks 3-4
- Produces: Block expression support across all context types

Note: The block detection heuristic (`expression.indexOf(';') > 0`) was already added in Task 3's `compileMapExpression` and POJO/List compile helpers. This task adds tests to verify it works across all three context types.

- [ ] **Step 1: Write block expression tests**

Add to `MvelExpressionEngineTest.java`:

```java
@Test
void compile_blockExpression_mapContext() {
    CompiledExpression<Map<String, Object>, Integer> expr =
            engine.compile("var threshold = 10; x + threshold", MAP_TYPE, Integer.class);
    assertThat(expr.eval(Map.of("x", 5))).isEqualTo(15);
}

@Test
void compile_blockExpression_withControlFlow() {
    CompiledExpression<Map<String, Object>, String> expr =
            engine.compile("var result = \"unknown\"; if (age > 18) { result = \"adult\"; } else { result = \"minor\"; }; result",
                           MAP_TYPE, String.class);
    assertThat(expr.eval(Map.of("age", 25))).isEqualTo("adult");
    assertThat(expr.eval(Map.of("age", 10))).isEqualTo("minor");
}

@Test
void compile_blockExpression_pojoContext() {
    CompiledExpression<Person, String> expr =
            engine.compile("var greeting = \"Hello \"; greeting + name",
                           Person.class, String.class);
    assertThat(expr.eval(new Person("Alice", 30))).isEqualTo("Hello Alice");
}

@Test
void compile_singleExpression_noSemicolon_stillWorks() {
    CompiledExpression<Map<String, Object>, Integer> expr =
            engine.compile("x + y", MAP_TYPE, Integer.class);
    assertThat(expr.eval(Map.of("x", 3, "y", 5))).isEqualTo(8);
}
```

- [ ] **Step 2: Run tests**

Run: `mvn --batch-mode test -pl expression -Dtest=MvelExpressionEngineTest`
Expected: ALL PASS (block detection already in compile helpers from Task 3)

If any block tests fail, the compile helpers need adjustment — fix the `.block()` vs `.expression()` dispatch in the lazy inner classes.

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add expression/src/test/java/io/casehub/platform/expression/MvelExpressionEngineTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#178): MVEL block expression tests — verify block detection across all context types"
```

---

### Task 6: Engine migration readiness — file issues + ARC42 + HANDOFF

**Files:**
- Modify: `ARC42STORIES.MD` (project repo — §1 core capabilities, §5 building block view, L4 layer taxonomy)
- Update: `HANDOFF.md` (workspace)

**Interfaces:**
- Consumes: POJO context support from Task 3 (confirms engine can delegate)
- Produces: 4 GitHub issues against casehubio/engine, HANDOFF.md notes

- [ ] **Step 1: File engine issues**

File 4 issues against `casehubio/engine`:

1. `engine-api ExpressionEvaluator extends platform-api ExpressionEvaluator`
2. `engine-api ExpressionEngine wraps platform-api ExpressionEngine`
3. `LambdaExpressionEvaluator → LambdaExpression<CaseContext, Boolean>`
4. `DefaultExpressionEngineRegistry delegates to platform ExpressionEngineRegistry`

Each issue body should reference platform#176, explain the migration, and link to the spec.

- [ ] **Step 2: Fix issue #177 body**

The issue body says "POJO context only" — the code hardcodes Map context. Add a comment correcting this:

```bash
gh issue comment 177 --repo casehubio/platform --body "Note: the original issue body says 'POJO context only' — the actual code hardcodes Map<String, Object> context (via MVEL.map()). Fixed in implementation: three-way dispatch for Map, POJO, and List contexts."
```

- [ ] **Step 3: Update ARC42STORIES.MD**

Update §1 (core capabilities — CloudEvent type dispatch), §5 (building block view — event package in L1/L2), and L4 layer taxonomy (Map/POJO/List context support in expression/).

- [ ] **Step 4: Update HANDOFF.md**

Note the engine migration issues in HANDOFF.md so the next session knows to follow up.

- [ ] **Step 5: Run full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile and test

- [ ] **Step 6: Commit ARC42 + HANDOFF**

```bash
git -C /Users/mdproctor/claude/casehub/platform add ARC42STORIES.MD
git -C /Users/mdproctor/claude/casehub/platform commit -m "docs(#176): update ARC42STORIES.MD — CloudEvent dispatch, MVEL context types"
```

```bash
git -C /Users/mdproctor/claude/public/casehub/platform add HANDOFF.md
git -C /Users/mdproctor/claude/public/casehub/platform commit -m "docs: update HANDOFF.md with engine migration issues"
```

---

## Task Dependencies

```
Task 1 (@CloudEventType) ──► Task 2 (Dispatcher)
                                                    ──► Task 6 (Engine issues)
Task 3 (POJO + refactor) ──► Task 4 (List) ──► Task 5 (Blocks) ─┘
```

Tasks 1-2 and Tasks 3-5 are independent tracks.
