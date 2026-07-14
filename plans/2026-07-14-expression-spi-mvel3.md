# Expression SPI + MVEL3 Evaluator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #141 — MVEL3 real evaluator
**Issue group:** #141

**Goal:** Promote a generic, pluggable expression evaluation SPI to
platform-api, implement JQ and MVEL3 engines in expression/, and wire
ConstraintCompiler to real MVEL3 evaluation with injection prevention.

**Architecture:** Generic `CompiledExpression<C, R>` runtime contract in
platform-api with `ExpressionEngine` factory SPI and
`ExpressionEngineRegistry` dispatcher. MVEL3 engine wraps MVEL3's
`Evaluator<C, Void, R>` (transpiled bytecode). JQ engine wraps existing
`JQEvaluator`. `ConstraintCompiler` converts from static utility to CDI
bean, uses parameterized expressions to prevent injection.

**Tech Stack:** Java 22, Quarkus CDI, MVEL3 3.0.0-SNAPSHOT, jackson-jq,
JUnit 5, AssertJ

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA, no
  casehubio imports. Pure Java only.
- `platform/` contains `@DefaultBean` implementations only — no domain logic.
- Every SPI in `platform-api/` gets a `@DefaultBean` in `platform/`.
- Pre-release — breaking changes cost nothing.
- MVEL3 dependency: `org.mvel:mvel3:3.0.0-SNAPSHOT` (JBoss Nexus snapshots,
  parent#372 already landed).

---

### Task 1: Expression SPI interfaces in platform-api

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/expression/CompiledExpression.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionEvaluator.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionEngine.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionEngineRegistry.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionCompilationException.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionEvaluationException.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/expression/CompiledExpressionContractTest.java`

**Interfaces:**
- Produces: `CompiledExpression<C, R>` (interface: `type()`, `eval(C)`),
  `ExpressionEvaluator` (interface: `type()`),
  `ExpressionEngine` (interface: `type()`, `compile(String, Class<C>, Class<R>)`,
  `compile(String, Class<C>, Class<R>, Map<String, Object>)`, `validate(String)`),
  `ExpressionEngineRegistry` (interface: `register(ExpressionEngine)`,
  `resolve(String)`, `compile(...)`, `validate(...)`)

- [ ] **Step 1: Write CompiledExpression contract test**

```java
package io.casehub.platform.api.expression;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class CompiledExpressionContractTest {

    @Test
    void eval_returnsResultFromFunction() {
        CompiledExpression<String, Integer> expr = new CompiledExpression<>() {
            @Override public String type() { return "test"; }
            @Override public Integer eval(String context) { return context.length(); }
        };
        assertThat(expr.eval("hello")).isEqualTo(5);
        assertThat(expr.type()).isEqualTo("test");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -f platform-api/pom.xml test -Dtest=CompiledExpressionContractTest -pl platform-api --batch-mode`
Expected: FAIL — `CompiledExpression` does not exist

- [ ] **Step 3: Create CompiledExpression interface**

Use `ide_create_file` to create `platform-api/src/main/java/io/casehub/platform/api/expression/CompiledExpression.java`:

```java
package io.casehub.platform.api.expression;

public interface CompiledExpression<C, R> {
    String type();
    R eval(C context);
}
```

- [ ] **Step 4: Create ExpressionEvaluator interface**

Use `ide_create_file`:

```java
package io.casehub.platform.api.expression;

public interface ExpressionEvaluator {
    String type();
}
```

- [ ] **Step 5: Create ExpressionCompilationException**

```java
package io.casehub.platform.api.expression;

public class ExpressionCompilationException extends RuntimeException {
    public ExpressionCompilationException(String message) {
        super(message);
    }
    public ExpressionCompilationException(String message, Throwable cause) {
        super(message, cause);
    }
}
```

- [ ] **Step 6: Create ExpressionEvaluationException**

```java
package io.casehub.platform.api.expression;

public class ExpressionEvaluationException extends RuntimeException {
    public ExpressionEvaluationException(String message) {
        super(message);
    }
    public ExpressionEvaluationException(String message, Throwable cause) {
        super(message, cause);
    }
}
```

- [ ] **Step 7: Create ExpressionEngine interface**

```java
package io.casehub.platform.api.expression;

import java.util.Map;

public interface ExpressionEngine {
    String type();

    <C, R> CompiledExpression<C, R> compile(
            String expression, Class<C> contextType, Class<R> resultType);

    <C, R> CompiledExpression<C, R> compile(
            String expression, Class<C> contextType, Class<R> resultType,
            Map<String, Object> variables);

    void validate(String expression);

    default boolean supportsStringCreation() { return true; }
}
```

- [ ] **Step 8: Create ExpressionEngineRegistry interface**

```java
package io.casehub.platform.api.expression;

import java.util.Map;
import java.util.Optional;

public interface ExpressionEngineRegistry {
    void register(ExpressionEngine engine);
    Optional<ExpressionEngine> resolve(String type);

    <C, R> CompiledExpression<C, R> compile(
            String type, String expression,
            Class<C> contextType, Class<R> resultType);

    <C, R> CompiledExpression<C, R> compile(
            String type, String expression,
            Class<C> contextType, Class<R> resultType,
            Map<String, Object> variables);

    void validate(String type, String expression);
}
```

- [ ] **Step 9: Run test to verify it passes**

Run: `mvn -f platform-api/pom.xml test -Dtest=CompiledExpressionContractTest -pl platform-api --batch-mode`
Expected: PASS

- [ ] **Step 10: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/expression/CompiledExpression.java \
       platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionEvaluator.java \
       platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionEngine.java \
       platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionEngineRegistry.java \
       platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionCompilationException.java \
       platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionEvaluationException.java \
       platform-api/src/test/java/io/casehub/platform/api/expression/CompiledExpressionContractTest.java
git commit -m "feat(#141): expression SPI interfaces — CompiledExpression, ExpressionEngine, ExpressionEngineRegistry"
```

---

### Task 2: Concrete evaluator types in platform-api

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/expression/JQExpressionEvaluator.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/expression/MvelExpressionEvaluator.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/expression/LambdaExpression.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/expression/LambdaExpressionTest.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/expression/JQExpressionEvaluatorTest.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/expression/MvelExpressionEvaluatorTest.java`

**Interfaces:**
- Consumes: `ExpressionEvaluator`, `CompiledExpression` from Task 1
- Produces: `JQExpressionEvaluator` (record: `expression()`),
  `MvelExpressionEvaluator` (record: `expression()`),
  `LambdaExpression<C, R>` (class: implements both `ExpressionEvaluator` and
  `CompiledExpression<C, R>`, wraps `Function<C, R>`)

- [ ] **Step 1: Write LambdaExpression test**

```java
package io.casehub.platform.api.expression;

import org.junit.jupiter.api.Test;
import java.util.function.Function;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class LambdaExpressionTest {

    @Test
    void eval_delegatesToFunction() {
        var expr = new LambdaExpression<>(String::length);
        assertThat(expr.eval("hello")).isEqualTo(5);
    }

    @Test
    void type_returnsLambda() {
        var expr = new LambdaExpression<>(Function.identity());
        assertThat(expr.type()).isEqualTo("lambda");
    }

    @Test
    void implementsBothInterfaces() {
        var expr = new LambdaExpression<>(String::length);
        assertThat(expr).isInstanceOf(ExpressionEvaluator.class);
        assertThat(expr).isInstanceOf(CompiledExpression.class);
    }

    @Test
    void booleanPredicate_worksNaturally() {
        LambdaExpression<Integer, Boolean> isPositive =
                new LambdaExpression<>(n -> n > 0);
        assertThat(isPositive.eval(5)).isTrue();
        assertThat(isPositive.eval(-1)).isFalse();
    }

    @Test
    void rejectsNullFunction() {
        assertThatThrownBy(() -> new LambdaExpression<>(null))
                .isInstanceOf(NullPointerException.class);
    }
}
```

- [ ] **Step 2: Write JQExpressionEvaluator test**

```java
package io.casehub.platform.api.expression;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class JQExpressionEvaluatorTest {

    @Test
    void type_returnsJq() {
        var eval = new JQExpressionEvaluator(".status");
        assertThat(eval.type()).isEqualTo("jq");
    }

    @Test
    void expression_returnsValue() {
        var eval = new JQExpressionEvaluator(".status == \"active\"");
        assertThat(eval.expression()).isEqualTo(".status == \"active\"");
    }

    @Test
    void implementsExpressionEvaluator() {
        var eval = new JQExpressionEvaluator(".x");
        assertThat(eval).isInstanceOf(ExpressionEvaluator.class);
    }

    @Test
    void rejectsNullExpression() {
        assertThatThrownBy(() -> new JQExpressionEvaluator(null))
                .isInstanceOf(NullPointerException.class);
    }
}
```

- [ ] **Step 3: Write MvelExpressionEvaluator test**

```java
package io.casehub.platform.api.expression;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class MvelExpressionEvaluatorTest {

    @Test
    void type_returnsMvel() {
        var eval = new MvelExpressionEvaluator("status == \"active\"");
        assertThat(eval.type()).isEqualTo("mvel");
    }

    @Test
    void expression_returnsValue() {
        var eval = new MvelExpressionEvaluator("age > 20");
        assertThat(eval.expression()).isEqualTo("age > 20");
    }

    @Test
    void implementsExpressionEvaluator() {
        var eval = new MvelExpressionEvaluator("x");
        assertThat(eval).isInstanceOf(ExpressionEvaluator.class);
    }

    @Test
    void rejectsNullExpression() {
        assertThatThrownBy(() -> new MvelExpressionEvaluator(null))
                .isInstanceOf(NullPointerException.class);
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `mvn -f platform-api/pom.xml test -Dtest="LambdaExpressionTest,JQExpressionEvaluatorTest,MvelExpressionEvaluatorTest" -pl platform-api --batch-mode`
Expected: FAIL — classes do not exist

- [ ] **Step 5: Create JQExpressionEvaluator**

```java
package io.casehub.platform.api.expression;

import java.util.Objects;

public record JQExpressionEvaluator(String expression) implements ExpressionEvaluator {

    public JQExpressionEvaluator {
        Objects.requireNonNull(expression, "expression");
    }

    @Override
    public String type() { return "jq"; }
}
```

- [ ] **Step 6: Create MvelExpressionEvaluator**

```java
package io.casehub.platform.api.expression;

import java.util.Objects;

public record MvelExpressionEvaluator(String expression) implements ExpressionEvaluator {

    public MvelExpressionEvaluator {
        Objects.requireNonNull(expression, "expression");
    }

    @Override
    public String type() { return "mvel"; }
}
```

- [ ] **Step 7: Create LambdaExpression**

```java
package io.casehub.platform.api.expression;

import java.util.Objects;
import java.util.function.Function;

public class LambdaExpression<C, R> implements ExpressionEvaluator, CompiledExpression<C, R> {

    private final Function<C, R> function;

    public LambdaExpression(Function<C, R> function) {
        Objects.requireNonNull(function, "function");
        this.function = function;
    }

    @Override
    public String type() { return "lambda"; }

    @Override
    public R eval(C context) { return function.apply(context); }
}
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `mvn -f platform-api/pom.xml test -Dtest="LambdaExpressionTest,JQExpressionEvaluatorTest,MvelExpressionEvaluatorTest" -pl platform-api --batch-mode`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/expression/JQExpressionEvaluator.java \
       platform-api/src/main/java/io/casehub/platform/api/expression/MvelExpressionEvaluator.java \
       platform-api/src/main/java/io/casehub/platform/api/expression/LambdaExpression.java \
       platform-api/src/test/java/io/casehub/platform/api/expression/LambdaExpressionTest.java \
       platform-api/src/test/java/io/casehub/platform/api/expression/JQExpressionEvaluatorTest.java \
       platform-api/src/test/java/io/casehub/platform/api/expression/MvelExpressionEvaluatorTest.java
git commit -m "feat(#141): concrete evaluator types — JQExpressionEvaluator, MvelExpressionEvaluator, LambdaExpression"
```

---

### Task 3: Constraint field name validation

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/subscription/Constraint.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/subscription/ConstraintTest.java` (if exists, else create)

**Interfaces:**
- Consumes: existing `Constraint` record
- Produces: `Constraint` with field name validation in compact constructor —
  rejects any `field` not matching `[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)*`

- [ ] **Step 1: Write field validation tests**

```java
package io.casehub.platform.api.subscription;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ConstraintFieldValidationTest {

    @ParameterizedTest
    @ValueSource(strings = {"status", "assignee", "priority_level", "item.status",
            "a", "_private", "deep.nested.field"})
    void validFieldNames_accepted(String field) {
        var c = new Constraint(field, ConstraintOp.EQ, "val");
        assertThat(c.field()).isEqualTo(field);
    }

    @ParameterizedTest
    @ValueSource(strings = {
            "\"; Runtime.getRuntime().exec(\"id\")",
            "field\"; //",
            ".leading.dot",
            "trailing.",
            "has spaces",
            "has-dash",
            "123startsWithDigit",
            "",
            "a..b",
            "field;drop",
            "field()",
            "field[0]"
    })
    void invalidFieldNames_rejected(String field) {
        assertThatThrownBy(() -> new Constraint(field, ConstraintOp.EQ, "val"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("field");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -f platform-api/pom.xml test -Dtest=ConstraintFieldValidationTest -pl platform-api --batch-mode`
Expected: FAIL — invalid field names are currently accepted

- [ ] **Step 3: Add field validation to Constraint record**

Use `ide_edit_member` to replace the `Constraint` record. Add a `FIELD_PATTERN`
constant and validation in the compact constructor:

```java
public record Constraint(
        String field,
        ConstraintOp op,
        String value
) {
    private static final java.util.regex.Pattern FIELD_PATTERN =
            java.util.regex.Pattern.compile("[a-zA-Z_][a-zA-Z0-9_]*(\\.[a-zA-Z_][a-zA-Z0-9_]*)*");

    public Constraint {
        Objects.requireNonNull(field, "field");
        Objects.requireNonNull(op, "op");
        Objects.requireNonNull(value, "value");
        if (!FIELD_PATTERN.matcher(field).matches()) {
            throw new IllegalArgumentException(
                    "Invalid constraint field name: '" + field
                    + "' — must be identifier-dot-separated path (e.g., 'status', 'assignee.name')");
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -f platform-api/pom.xml test -Dtest=ConstraintFieldValidationTest -pl platform-api --batch-mode`
Expected: PASS

- [ ] **Step 5: Run full platform-api tests for regressions**

Run: `mvn -f platform-api/pom.xml test -pl platform-api --batch-mode`
Expected: All tests pass. Check that existing `ConstraintCompilerTest` tests still
pass (they use valid field names like `"status"`, `"assignee"`, `"priority"`).

- [ ] **Step 6: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/subscription/Constraint.java \
       platform-api/src/test/java/io/casehub/platform/api/subscription/ConstraintFieldValidationTest.java
git commit -m "feat(#141): Constraint field name validation — rejects injection patterns"
```

---

### Task 4: NoOpExpressionEngineRegistry @DefaultBean in platform/

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/expression/NoOpExpressionEngineRegistry.java`
- Test: `platform/src/test/java/io/casehub/platform/expression/NoOpExpressionEngineRegistryTest.java`

**Interfaces:**
- Consumes: `ExpressionEngineRegistry`, `ExpressionEngine`, `CompiledExpression`
  from Task 1
- Produces: `NoOpExpressionEngineRegistry` — `@DefaultBean @ApplicationScoped`,
  `resolve()` → `Optional.empty()`, `register()` → no-op,
  `compile()`/`validate()` → throws `UnsupportedOperationException`

- [ ] **Step 1: Write NoOp test**

```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.ExpressionEngineRegistry;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class NoOpExpressionEngineRegistryTest {

    private final ExpressionEngineRegistry registry = new NoOpExpressionEngineRegistry();

    @Test
    void resolve_returnsEmpty() {
        assertThat(registry.resolve("mvel")).isEmpty();
        assertThat(registry.resolve("jq")).isEmpty();
    }

    @Test
    void compile_throwsUnsupported() {
        assertThatThrownBy(() -> registry.compile("mvel", "x > 1", Object.class, Boolean.class))
                .isInstanceOf(UnsupportedOperationException.class)
                .hasMessageContaining("casehub-platform-expression");
    }

    @Test
    void compileWithVariables_throwsUnsupported() {
        assertThatThrownBy(() -> registry.compile("mvel", "x > 1",
                Object.class, Boolean.class, java.util.Map.of()))
                .isInstanceOf(UnsupportedOperationException.class);
    }

    @Test
    void validate_throwsUnsupported() {
        assertThatThrownBy(() -> registry.validate("mvel", "x > 1"))
                .isInstanceOf(UnsupportedOperationException.class);
    }

    @Test
    void register_silentNoOp() {
        registry.register(null);
        assertThat(registry.resolve("anything")).isEmpty();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -f platform/pom.xml test -Dtest=NoOpExpressionEngineRegistryTest -pl platform --batch-mode`
Expected: FAIL — class does not exist

- [ ] **Step 3: Create NoOpExpressionEngineRegistry**

Use `ide_create_file`:

```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.CompiledExpression;
import io.casehub.platform.api.expression.ExpressionEngine;
import io.casehub.platform.api.expression.ExpressionEngineRegistry;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;
import java.util.Map;
import java.util.Optional;

@DefaultBean
@ApplicationScoped
public class NoOpExpressionEngineRegistry implements ExpressionEngineRegistry {

    private static final String MESSAGE =
            "No ExpressionEngine available — add casehub-platform-expression to the classpath";

    @Override
    public void register(ExpressionEngine engine) {}

    @Override
    public Optional<ExpressionEngine> resolve(String type) {
        return Optional.empty();
    }

    @Override
    public <C, R> CompiledExpression<C, R> compile(
            String type, String expression,
            Class<C> contextType, Class<R> resultType) {
        throw new UnsupportedOperationException(MESSAGE);
    }

    @Override
    public <C, R> CompiledExpression<C, R> compile(
            String type, String expression,
            Class<C> contextType, Class<R> resultType,
            Map<String, Object> variables) {
        throw new UnsupportedOperationException(MESSAGE);
    }

    @Override
    public void validate(String type, String expression) {
        throw new UnsupportedOperationException(MESSAGE);
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -f platform/pom.xml test -Dtest=NoOpExpressionEngineRegistryTest -pl platform --batch-mode`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add platform/src/main/java/io/casehub/platform/expression/NoOpExpressionEngineRegistry.java \
       platform/src/test/java/io/casehub/platform/expression/NoOpExpressionEngineRegistryTest.java
git commit -m "feat(#141): NoOpExpressionEngineRegistry @DefaultBean in platform/"
```

---

### Task 5: DefaultExpressionEngineRegistry + MvelExpressionEngine + JQExpressionEngine in expression/

**Files:**
- Create: `expression/src/main/java/io/casehub/platform/expression/DefaultExpressionEngineRegistry.java`
- Create: `expression/src/main/java/io/casehub/platform/expression/MvelExpressionEngine.java`
- Create: `expression/src/main/java/io/casehub/platform/expression/JQExpressionEngine.java`
- Modify: `expression/pom.xml` (add MVEL3 dependency)
- Test: `expression/src/test/java/io/casehub/platform/expression/DefaultExpressionEngineRegistryTest.java`
- Test: `expression/src/test/java/io/casehub/platform/expression/MvelExpressionEngineTest.java`
- Test: `expression/src/test/java/io/casehub/platform/expression/JQExpressionEngineTest.java`

**Interfaces:**
- Consumes: `ExpressionEngine`, `ExpressionEngineRegistry`, `CompiledExpression`,
  `ExpressionCompilationException`, `ExpressionEvaluationException` from Task 1;
  existing `JQEvaluator`, `ValidationResult` in expression/
- Produces: `DefaultExpressionEngineRegistry` (`@ApplicationScoped`, CDI-discovers
  `ExpressionEngine` beans, dispatches by `type()`),
  `MvelExpressionEngine` (`@ApplicationScoped`, type `"mvel"`, compile via
  `MVEL.pojo(contextType).out(resultType).expression(expr).compile()`,
  `ConcurrentHashMap` cache keyed by `(expression, contextType, resultType)`),
  `JQExpressionEngine` (`@ApplicationScoped`, type `"jq"`, delegates to
  `JQEvaluator` internally)

- [ ] **Step 1: Add MVEL3 dependency to expression/pom.xml**

Add to `<dependencies>` section of `expression/pom.xml`:

```xml
<dependency>
    <groupId>org.mvel</groupId>
    <artifactId>mvel3</artifactId>
    <version>3.0.0-SNAPSHOT</version>
</dependency>
```

- [ ] **Step 2: Write MvelExpressionEngine test**

```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.CompiledExpression;
import io.casehub.platform.api.expression.ExpressionCompilationException;
import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class MvelExpressionEngineTest {

    private final MvelExpressionEngine engine = new MvelExpressionEngine();

    record Person(String name, int age) {}

    @Test
    void type_returnsMvel() {
        assertThat(engine.type()).isEqualTo("mvel");
    }

    @Test
    void compile_pojoFieldAccess_booleanResult() {
        CompiledExpression<Person, Boolean> expr =
                engine.compile("age > 20", Person.class, Boolean.class);
        assertThat(expr.eval(new Person("Alice", 25))).isTrue();
        assertThat(expr.eval(new Person("Bob", 18))).isFalse();
    }

    @Test
    void compile_pojoFieldAccess_stringResult() {
        CompiledExpression<Person, String> expr =
                engine.compile("name", Person.class, String.class);
        assertThat(expr.eval(new Person("Alice", 25))).isEqualTo("Alice");
    }

    @Test
    void compile_withVariables_parameterizedExpression() {
        CompiledExpression<Person, Boolean> expr =
                engine.compile("name == $p0", Person.class, Boolean.class,
                        Map.of("$p0", "Alice"));
        assertThat(expr.eval(new Person("Alice", 25))).isTrue();
        assertThat(expr.eval(new Person("Bob", 18))).isFalse();
    }

    @Test
    void compile_equality() {
        CompiledExpression<Person, Boolean> expr =
                engine.compile("name == \"Alice\"", Person.class, Boolean.class);
        assertThat(expr.eval(new Person("Alice", 25))).isTrue();
        assertThat(expr.eval(new Person("Bob", 18))).isFalse();
    }

    @Test
    void compile_invalidExpression_throwsCompilationException() {
        assertThatThrownBy(() -> engine.compile("!!invalid!!", Person.class, Boolean.class))
                .isInstanceOf(ExpressionCompilationException.class);
    }

    @Test
    void validate_validExpression_noException() {
        engine.validate("age > 20");
    }

    @Test
    void validate_invalidExpression_throwsCompilationException() {
        assertThatThrownBy(() -> engine.validate("!!invalid!!"))
                .isInstanceOf(ExpressionCompilationException.class);
    }

    @Test
    void compile_cachedForSameExpression() {
        CompiledExpression<Person, Boolean> first =
                engine.compile("age > 20", Person.class, Boolean.class);
        CompiledExpression<Person, Boolean> second =
                engine.compile("age > 20", Person.class, Boolean.class);
        assertThat(first).isSameAs(second);
    }

    @Test
    void compile_booleanLogic() {
        CompiledExpression<Person, Boolean> expr =
                engine.compile("age > 18 && name != \"Bob\"", Person.class, Boolean.class);
        assertThat(expr.eval(new Person("Alice", 25))).isTrue();
        assertThat(expr.eval(new Person("Bob", 25))).isFalse();
        assertThat(expr.eval(new Person("Alice", 16))).isFalse();
    }
}
```

- [ ] **Step 3: Write JQExpressionEngine test**

```java
package io.casehub.platform.expression;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import io.casehub.platform.api.expression.CompiledExpression;
import io.casehub.platform.api.expression.ExpressionCompilationException;
import org.junit.jupiter.api.Test;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class JQExpressionEngineTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private final JQExpressionEngine engine = new JQExpressionEngine();

    @Test
    void type_returnsJq() {
        assertThat(engine.type()).isEqualTo("jq");
    }

    @Test
    void compile_fieldExtraction() {
        ObjectNode input = MAPPER.createObjectNode().put("status", "active");
        CompiledExpression<JsonNode, List> expr =
                engine.compile(".status", JsonNode.class, List.class);
        @SuppressWarnings("unchecked")
        List<JsonNode> result = (List<JsonNode>) expr.eval(input);
        assertThat(result).hasSize(1);
        assertThat(result.get(0).asText()).isEqualTo("active");
    }

    @Test
    void compile_booleanExpression() {
        ObjectNode input = MAPPER.createObjectNode().put("age", 25);
        CompiledExpression<JsonNode, Boolean> expr =
                engine.compile(".age > 20", JsonNode.class, Boolean.class);
        assertThat(expr.eval(input)).isTrue();
    }

    @Test
    void compile_invalidExpression_throwsCompilationException() {
        assertThatThrownBy(() -> engine.compile("invalid jq [[[", JsonNode.class, List.class))
                .isInstanceOf(ExpressionCompilationException.class);
    }

    @Test
    void validate_validExpression_noException() {
        engine.validate(".status");
    }

    @Test
    void validate_invalidExpression_throwsCompilationException() {
        assertThatThrownBy(() -> engine.validate("invalid jq [[["))
                .isInstanceOf(ExpressionCompilationException.class);
    }
}
```

- [ ] **Step 4: Write DefaultExpressionEngineRegistry test**

```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.CompiledExpression;
import io.casehub.platform.api.expression.ExpressionEngine;
import io.casehub.platform.api.expression.ExpressionEngineRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class DefaultExpressionEngineRegistryTest {

    private DefaultExpressionEngineRegistry registry;

    @BeforeEach
    void setUp() {
        registry = new DefaultExpressionEngineRegistry();
    }

    @Test
    void resolve_unknownType_returnsEmpty() {
        assertThat(registry.resolve("unknown")).isEmpty();
    }

    @Test
    void register_andResolve() {
        var engine = new StubExpressionEngine("test");
        registry.register(engine);
        assertThat(registry.resolve("test")).contains(engine);
    }

    @Test
    void compile_unknownType_throwsIllegalArgument() {
        assertThatThrownBy(() -> registry.compile("unknown", "x", Object.class, Boolean.class))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("unknown");
    }

    @Test
    void compile_delegatesToEngine() {
        var engine = new StubExpressionEngine("test");
        registry.register(engine);
        CompiledExpression<Object, Boolean> compiled =
                registry.compile("test", "expr", Object.class, Boolean.class);
        assertThat(compiled.eval("anything")).isTrue();
    }

    @Test
    void validate_unknownType_throwsIllegalArgument() {
        assertThatThrownBy(() -> registry.validate("unknown", "x"))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void validate_delegatesToEngine() {
        var engine = new StubExpressionEngine("test");
        registry.register(engine);
        registry.validate("test", "expr");
    }

    private static class StubExpressionEngine implements ExpressionEngine {
        private final String type;
        StubExpressionEngine(String type) { this.type = type; }

        @Override public String type() { return type; }

        @Override
        public <C, R> CompiledExpression<C, R> compile(
                String expression, Class<C> contextType, Class<R> resultType) {
            @SuppressWarnings("unchecked")
            CompiledExpression<C, R> result = (CompiledExpression<C, R>)
                    (CompiledExpression<Object, Boolean>) ctx -> true;
            return new CompiledExpression<>() {
                @Override public String type() { return StubExpressionEngine.this.type; }
                @Override public R eval(C context) { return result.eval(context); }
            };
        }

        @Override
        public <C, R> CompiledExpression<C, R> compile(
                String expression, Class<C> contextType, Class<R> resultType,
                Map<String, Object> variables) {
            return compile(expression, contextType, resultType);
        }

        @Override public void validate(String expression) {}
    }
}
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `mvn -f expression/pom.xml test -Dtest="MvelExpressionEngineTest,JQExpressionEngineTest,DefaultExpressionEngineRegistryTest" -pl expression --batch-mode`
Expected: FAIL — classes do not exist

- [ ] **Step 6: Create MvelExpressionEngine**

Use `ide_create_file` for `expression/src/main/java/io/casehub/platform/expression/MvelExpressionEngine.java`.

Implementation: wraps MVEL3's `MVEL.pojo(contextType).out(resultType).expression(expr).compile()`.
Cache key is `(expression, contextType, resultType)`. The `compile` overload with
`variables` compiles and binds variables into the evaluator. `validate()` attempts
a compile with `Object.class` context and discards the result.

The actual implementation code depends on MVEL3's API shape — implement based on
the MVEL3 snapshot's `org.mvel3.MVEL` class, adapting the fluent builder pattern
from the README. Wrap `Evaluator<C, Void, R>.eval(C)` in a `CompiledExpression<C, R>`.
Catch MVEL3 compilation errors and wrap in `ExpressionCompilationException`.

- [ ] **Step 7: Create JQExpressionEngine**

Use `ide_create_file` for `expression/src/main/java/io/casehub/platform/expression/JQExpressionEngine.java`.

Implementation: wraps jackson-jq's `JsonQuery.compile(expr, Versions.JQ_1_6)` behind
the `ExpressionEngine` interface. For `Boolean` result type, evaluates and returns
`isTrue()` from `ValidationResult`. For `List` result type, returns the output list.
Uses the existing `JQEvaluator`'s `queryCache` pattern. Catches jackson-jq parse
errors and wraps in `ExpressionCompilationException`.

- [ ] **Step 8: Create DefaultExpressionEngineRegistry**

Use `ide_create_file` for `expression/src/main/java/io/casehub/platform/expression/DefaultExpressionEngineRegistry.java`.

```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.CompiledExpression;
import io.casehub.platform.api.expression.ExpressionEngine;
import io.casehub.platform.api.expression.ExpressionEngineRegistry;
import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

@ApplicationScoped
public class DefaultExpressionEngineRegistry implements ExpressionEngineRegistry {

    @Inject
    Instance<ExpressionEngine> engines;

    private final ConcurrentHashMap<String, ExpressionEngine> engineMap = new ConcurrentHashMap<>();

    public DefaultExpressionEngineRegistry() {}

    @PostConstruct
    void init() {
        for (ExpressionEngine engine : engines) {
            engineMap.put(engine.type(), engine);
        }
    }

    @Override
    public void register(ExpressionEngine engine) {
        engineMap.put(engine.type(), engine);
    }

    @Override
    public Optional<ExpressionEngine> resolve(String type) {
        return Optional.ofNullable(engineMap.get(type));
    }

    @Override
    public <C, R> CompiledExpression<C, R> compile(
            String type, String expression,
            Class<C> contextType, Class<R> resultType) {
        return resolveEngine(type).compile(expression, contextType, resultType);
    }

    @Override
    public <C, R> CompiledExpression<C, R> compile(
            String type, String expression,
            Class<C> contextType, Class<R> resultType,
            Map<String, Object> variables) {
        return resolveEngine(type).compile(expression, contextType, resultType, variables);
    }

    @Override
    public void validate(String type, String expression) {
        resolveEngine(type).validate(expression);
    }

    private ExpressionEngine resolveEngine(String type) {
        ExpressionEngine engine = engineMap.get(type);
        if (engine == null) {
            throw new IllegalArgumentException(
                    "No ExpressionEngine registered for type '" + type + "'");
        }
        return engine;
    }
}
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `mvn -f expression/pom.xml test -Dtest="MvelExpressionEngineTest,JQExpressionEngineTest,DefaultExpressionEngineRegistryTest" -pl expression --batch-mode`
Expected: PASS

- [ ] **Step 10: Commit**

```bash
git add expression/pom.xml \
       expression/src/main/java/io/casehub/platform/expression/MvelExpressionEngine.java \
       expression/src/main/java/io/casehub/platform/expression/JQExpressionEngine.java \
       expression/src/main/java/io/casehub/platform/expression/DefaultExpressionEngineRegistry.java \
       expression/src/test/java/io/casehub/platform/expression/MvelExpressionEngineTest.java \
       expression/src/test/java/io/casehub/platform/expression/JQExpressionEngineTest.java \
       expression/src/test/java/io/casehub/platform/expression/DefaultExpressionEngineRegistryTest.java
git commit -m "feat(#141): MvelExpressionEngine + JQExpressionEngine + DefaultExpressionEngineRegistry"
```

---

### Task 6: ConstraintCompiler CDI conversion + real MVEL evaluation

**Files:**
- Modify: `subscriptions/src/main/java/io/casehub/platform/subscription/engine/ConstraintCompiler.java`
- Modify: `subscriptions/src/main/java/io/casehub/platform/subscription/engine/SubscriptionEngine.java`
- Modify: `subscriptions/pom.xml` (add expression dependency)
- Modify: `subscriptions/src/test/java/io/casehub/platform/subscription/engine/ConstraintCompilerTest.java`

**Interfaces:**
- Consumes: `ExpressionEngineRegistry.compile("mvel", expr, Object.class, Boolean.class, variables)`
  from Tasks 1+5, `Constraint` with validated field names from Task 3
- Produces: `ConstraintCompiler` as `@ApplicationScoped` CDI bean with injected
  `ExpressionEngineRegistry`. `compile()` becomes an instance method.
  `toMvelClause()` generates parameterized expressions (`field == $p0`) with
  variable bindings. `SubscriptionEngine` injects `ConstraintCompiler` instead
  of calling static methods.

- [ ] **Step 1: Add expression dependency to subscriptions/pom.xml**

Add to `<dependencies>`:

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-expression</artifactId>
    <version>${project.version}</version>
</dependency>
```

- [ ] **Step 2: Update ConstraintCompilerTest — user constraints now actually evaluate**

Rewrite tests to verify real constraint evaluation. The key change: with real MVEL,
`fe.test(event)` now returns `false` when constraints don't match (previously
mock-true). Add tests that verify parameterized constraint values are treated as
data, not code.

```java
@Test
void compile_eqConstraint_matchingEvent_returnsTrue() {
    var constraints = List.of(new Constraint("type", ConstraintOp.EQ, "alert"));
    var fe = constraintCompiler.compile(constraints, "tenant-1", "user-1");
    var event = new TestEvent("alert", "tenant-1");
    assertThat(fe.test(event)).isTrue();
}

@Test
void compile_eqConstraint_nonMatchingEvent_returnsFalse() {
    var constraints = List.of(new Constraint("type", ConstraintOp.EQ, "alert"));
    var fe = constraintCompiler.compile(constraints, "tenant-1", "user-1");
    var event = new TestEvent("info", "tenant-1");
    assertThat(fe.test(event)).isFalse();
}

@Test
void compile_injectionAttempt_treatedAsData() {
    var constraints = List.of(new Constraint("type", ConstraintOp.EQ,
            "x\"; Runtime.getRuntime().exec(\"id\"); //"));
    var fe = constraintCompiler.compile(constraints, "tenant-1", "user-1");
    var event = new TestEvent("alert", "tenant-1");
    assertThat(fe.test(event)).isFalse();
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn -f subscriptions/pom.xml test -Dtest=ConstraintCompilerTest -pl subscriptions --batch-mode`
Expected: FAIL — ConstraintCompiler is still static, no CDI injection

- [ ] **Step 4: Convert ConstraintCompiler to CDI bean with parameterized MVEL**

Use `ide_edit_member` on `ConstraintCompiler`:
- Remove `private ConstraintCompiler()` constructor
- Add `@ApplicationScoped` annotation
- Add `@Inject ExpressionEngineRegistry registry` field
- Change `compile()` from static to instance method
- Change `toMvelClause()` to generate parameterized expressions with `$pN`
  variable references and collect variable bindings into a `Map<String, Object>`
- Use `registry.compile("mvel", mvelExpression, Object.class, Boolean.class, variables)`
  to get a real `CompiledExpression`
- Build the final `Predicate<Object>` from `tenantCheck.and(compiled::eval)`

- [ ] **Step 5: Update SubscriptionEngine to inject ConstraintCompiler**

Use `ide_edit_member` to add `ConstraintCompiler constraintCompiler` field to
the constructor. Change the two call sites (`wireSubscription` line 107 and
`wireAndReturnHandle` line 135) from `ConstraintCompiler.compile(...)` to
`constraintCompiler.compile(...)`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn -f subscriptions/pom.xml test -pl subscriptions --batch-mode`
Expected: All tests pass, including real constraint evaluation

- [ ] **Step 7: Run full project build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile and tests pass

- [ ] **Step 8: Commit**

```bash
git add subscriptions/pom.xml \
       subscriptions/src/main/java/io/casehub/platform/subscription/engine/ConstraintCompiler.java \
       subscriptions/src/main/java/io/casehub/platform/subscription/engine/SubscriptionEngine.java \
       subscriptions/src/test/java/io/casehub/platform/subscription/engine/ConstraintCompilerTest.java
git commit -m "feat(#141): ConstraintCompiler CDI conversion + real MVEL evaluation with injection prevention"
```

---

### Task 7: ARC42STORIES.MD update + CLAUDE.md sync

**Files:**
- Modify: `ARC42STORIES.MD` (if exists in project or workspace)
- Modify: `CLAUDE.md` (expression SPI types in package structure)

**Interfaces:**
- Consumes: All types from Tasks 1-6
- Produces: Updated documentation reflecting new SPI types and MVEL3 dependency

- [ ] **Step 1: Update ARC42STORIES.MD**

Update §1 (core capabilities to mention expression evaluation SPI), §5 (building
block view — expression module gains MvelExpressionEngine, JQExpressionEngine,
DefaultExpressionEngineRegistry), and the layer taxonomy (L1 expression SPI types
in platform-api, L4 MVEL3 in expression/).

- [ ] **Step 2: Update CLAUDE.md**

Add new types to the package structure section under
`io.casehub.platform.api.expression`:

```
  .expression    — CompiledExpression<C,R> (runtime contract), ExpressionEvaluator (marker),
                   ExpressionEngine (factory SPI: compile/validate), ExpressionEngineRegistry (SPI: dispatch by type),
                   JQExpressionEvaluator, MvelExpressionEvaluator, LambdaExpression<C,R>,
                   ExpressionCompilationException, ExpressionEvaluationException,
                   SecretManager, ConfigManager
```

Update the `expression/` module description to mention the new engines and registry.

- [ ] **Step 3: Commit**

```bash
git add ARC42STORIES.MD CLAUDE.md
git commit -m "docs(#141): ARC42STORIES + CLAUDE.md — expression SPI types and MVEL3"
```
