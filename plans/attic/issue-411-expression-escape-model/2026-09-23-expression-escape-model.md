# Four-Tier Expression Escape Model — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #411 — feat: four-tier expression escape model — invoke, compute, expression defaults
**Issue group:** #411

**Goal:** Deliver the platform-level primitives for the four-tier expression escape model — expression defaults, bean invoke (Tier 3), and @ScenarioAction (Tier 4) — so the pages scenario runner (#412) can consume them.

**Architecture:** SPIs in platform-api (primitive params only, zero yaml-core imports). Data model (InvokeDirective) in yaml-core. ActionRegistry/ActionHandle in yaml-core alongside ScenarioScope. CDI implementations in expression/. Spring equivalents hand-written in expression-spring/. InvocationPolicy for fail-closed security on bean invoke.

**Tech Stack:** Java 21, Quarkus CDI, Spring Boot 4, yaml-core (zero-dep), platform-api (zero-dep)

## Global Constraints

- platform-api: zero casehubio dependencies — only JDK types in SPI signatures
- yaml-core: zero external dependencies — j.u.c and JDK only
- Virtual-thread safety: no `synchronized` — j.u.c locks or lock-free atomics only
- Dual-framework: core POJOs + Quarkus CDI + Spring auto-config
- Tutorial-quality tests: documentation-grade names, golden path + edge cases

---

## Batch 1: Foundation — SPIs + Data Models

### Task 1: Expression default wiring

**Files:**
- Modify: `expression-core/src/main/java/io/casehub/platform/expression/DefaultExpressionEngineRegistry.java`
- Test: `expression/src/test/java/io/casehub/platform/expression/ExpressionDefaultsTest.java`

**Interfaces:**
- Consumes: `ExpressionContext` enum (CONDITION, TRANSFORM, FILTER) from platform-api
- Produces: constructor-initialized defaults on DefaultExpressionEngineRegistry

- [ ] **Step 1: Write the failing test**

```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.ExpressionContext;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

class ExpressionDefaultsTest {

    @Test
    void conditionDefaultsToMvel() {
        var registry = new DefaultExpressionEngineRegistry(List.of());
        assertEquals("mvel", registry.resolveDefault(ExpressionContext.CONDITION));
    }

    @Test
    void transformDefaultsToJq() {
        var registry = new DefaultExpressionEngineRegistry(List.of());
        assertEquals("jq", registry.resolveDefault(ExpressionContext.TRANSFORM));
    }

    @Test
    void filterDefaultsToJq() {
        var registry = new DefaultExpressionEngineRegistry(List.of());
        assertEquals("jq", registry.resolveDefault(ExpressionContext.FILTER));
    }

    @Test
    void defaultsAreOverridable() {
        var registry = new DefaultExpressionEngineRegistry(List.of());
        registry.registerDefault(ExpressionContext.CONDITION, "jq");
        assertEquals("jq", registry.resolveDefault(ExpressionContext.CONDITION));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl expression -Dtest=ExpressionDefaultsTest test --batch-mode`
Expected: FAIL — defaults are not registered in constructor yet

- [ ] **Step 3: Add defaults to constructor**

Modify `DefaultExpressionEngineRegistry` constructor to register defaults after engine registration:

```java
public DefaultExpressionEngineRegistry(List<ExpressionEngine> engines) {
    for (ExpressionEngine engine : engines) {
        engineMap.put(engine.type(), engine);
    }
    defaults.put(ExpressionContext.CONDITION, "mvel");
    defaults.put(ExpressionContext.TRANSFORM, "jq");
    defaults.put(ExpressionContext.FILTER, "jq");
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -pl expression -Dtest=ExpressionDefaultsTest test --batch-mode`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add expression-core/src/main/java/io/casehub/platform/expression/DefaultExpressionEngineRegistry.java expression/src/test/java/io/casehub/platform/expression/ExpressionDefaultsTest.java
git commit -m "feat(#411): register expression context defaults in registry constructor

CONDITION→mvel, TRANSFORM/FILTER→jq. Framework-neutral — both Quarkus
and Spring get defaults via constructor.

Refs #411

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: InvokeDirective data model

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/InvokeDirective.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/InvokeDirectiveTest.java`

**Interfaces:**
- Consumes: ForEachDirective.parse(Object) pattern (sealed-type factory)
- Produces: `InvokeDirective(String beanClassName, String methodName, List<String> args)` record with `parse(Object)` factory

- [ ] **Step 1: Write the failing tests**

```java
package io.casehub.yaml.core.orchestration;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class InvokeDirectiveTest {

    @Test
    void parseShorthandBeanAndMethod() {
        var directive = InvokeDirective.parse("io.casehub.trading.AlertRepository::save");
        assertEquals("io.casehub.trading.AlertRepository", directive.beanClassName());
        assertEquals("save", directive.methodName());
        assertTrue(directive.args().isEmpty());
    }

    @Test
    void parseFullFormWithArgs() {
        var directive = InvokeDirective.parse(Map.of(
                "bean", "io.casehub.trading.OrderService",
                "method", "place",
                "args", List.of("${price}", "${quantity}")
        ));
        assertEquals("io.casehub.trading.OrderService", directive.beanClassName());
        assertEquals("place", directive.methodName());
        assertEquals(List.of("${price}", "${quantity}"), directive.args());
    }

    @Test
    void parseFullFormWithoutArgs() {
        var directive = InvokeDirective.parse(Map.of(
                "bean", "io.casehub.trading.OrderService",
                "method", "cancelAll"
        ));
        assertEquals("io.casehub.trading.OrderService", directive.beanClassName());
        assertEquals("cancelAll", directive.methodName());
        assertTrue(directive.args().isEmpty());
    }

    @Test
    void parseRejectsInvalidShorthandWithoutSeparator() {
        assertThrows(IllegalArgumentException.class,
                () -> InvokeDirective.parse("not-a-valid-invoke"));
    }

    @Test
    void parseRejectsNullInput() {
        assertThrows(NullPointerException.class, () -> InvokeDirective.parse(null));
    }

    @Test
    void parseRejectsMapMissingBean() {
        assertThrows(IllegalArgumentException.class,
                () -> InvokeDirective.parse(Map.of("method", "save")));
    }

    @Test
    void parseRejectsMapMissingMethod() {
        assertThrows(IllegalArgumentException.class,
                () -> InvokeDirective.parse(Map.of("bean", "Foo")));
    }

    @Test
    void parsePassesThroughExistingInstance() {
        var original = new InvokeDirective("Foo", "bar", List.of());
        assertSame(original, InvokeDirective.parse(original));
    }

    @Test
    void recordFieldsAreImmutable() {
        var directive = InvokeDirective.parse("Foo::bar");
        assertThrows(UnsupportedOperationException.class,
                () -> directive.args().add("x"));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl yaml-core -Dtest=InvokeDirectiveTest test --batch-mode`
Expected: FAIL — InvokeDirective class does not exist

- [ ] **Step 3: Implement InvokeDirective**

```java
package io.casehub.yaml.core.orchestration;

import java.util.List;
import java.util.Map;
import java.util.Objects;

public record InvokeDirective(String beanClassName, String methodName, List<String> args) {

    public InvokeDirective {
        Objects.requireNonNull(beanClassName, "beanClassName must not be null");
        Objects.requireNonNull(methodName, "methodName must not be null");
        args = args == null ? List.of() : List.copyOf(args);
    }

    @SuppressWarnings("unchecked")
    public static InvokeDirective parse(Object raw) {
        Objects.requireNonNull(raw, "invoke directive must not be null");
        if (raw instanceof InvokeDirective d) { return d; }
        if (raw instanceof String s) { return parseShorthand(s); }
        if (raw instanceof Map<?, ?> m) { return parseMap((Map<String, Object>) m); }
        throw new IllegalArgumentException(
                "Invalid invoke value: expected string or {bean, method} map — got " + raw.getClass().getSimpleName());
    }

    private static InvokeDirective parseShorthand(String s) {
        int sep = s.lastIndexOf("::");
        if (sep < 0) {
            throw new IllegalArgumentException(
                    "Invalid invoke shorthand: expected 'Bean::method' — got '" + s + "'");
        }
        return new InvokeDirective(s.substring(0, sep), s.substring(sep + 2), List.of());
    }

    @SuppressWarnings("unchecked")
    private static InvokeDirective parseMap(Map<String, Object> m) {
        String bean = (String) m.get("bean");
        String method = (String) m.get("method");
        if (bean == null) {
            throw new IllegalArgumentException("invoke map requires 'bean' field");
        }
        if (method == null) {
            throw new IllegalArgumentException("invoke map requires 'method' field");
        }
        List<String> args = m.containsKey("args") ? (List<String>) m.get("args") : List.of();
        return new InvokeDirective(bean, method, args);
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -pl yaml-core -Dtest=InvokeDirectiveTest test --batch-mode`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/InvokeDirective.java yaml-core/src/test/java/io/casehub/yaml/core/orchestration/InvokeDirectiveTest.java
git commit -m "feat(#411): InvokeDirective data model for Tier 3 bean invoke

parse(Object) factory handles shorthand ('Bean::method') and full form
({bean, method, args}). Follows ForEachDirective sealed-type pattern.

Refs #411

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 3: BeanInvoker + InvocationPolicy SPIs and @ScenarioAction annotation

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/expression/BeanInvoker.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/expression/InvocationPolicy.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/expression/InvocationDeniedException.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/expression/ScenarioAction.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ActionRegistry.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ActionHandle.java`
- Create: `platform-core/src/main/java/io/casehub/platform/expression/NoOpBeanInvoker.java`
- Create: `platform-core/src/main/java/io/casehub/platform/expression/NoOpInvocationPolicy.java`
- Create: `platform-core/src/main/java/io/casehub/platform/expression/NoOpActionRegistry.java`
- Modify: `platform/src/main/java/io/casehub/platform/quarkus/DefaultBeans.java` — add @DefaultBean producers
- Test: `platform-api/src/test/java/io/casehub/platform/api/expression/BeanInvokerTest.java`

**Interfaces:**
- Consumes: ScenarioScope (yaml-core) for ActionHandle parameter
- Produces: `BeanInvoker.invoke(String, String, Object...)`, `InvocationPolicy.isAllowed(String, String)`, `ActionRegistry.resolve(String)`, `ActionHandle.invoke(ScenarioScope, Map)`, `@ScenarioAction(value)`

- [ ] **Step 1: Create SPI interfaces**

`BeanInvoker.java`:
```java
package io.casehub.platform.api.expression;

public interface BeanInvoker {
    Object invoke(String beanClassName, String methodName, Object... args);
}
```

`InvocationPolicy.java`:
```java
package io.casehub.platform.api.expression;

public interface InvocationPolicy {
    boolean isAllowed(String beanClassName, String methodName);
}
```

`InvocationDeniedException.java`:
```java
package io.casehub.platform.api.expression;

public class InvocationDeniedException extends RuntimeException {
    private final String beanClassName;
    private final String methodName;

    public InvocationDeniedException(String beanClassName, String methodName) {
        super("Invocation denied: " + beanClassName + "::" + methodName);
        this.beanClassName = beanClassName;
        this.methodName = methodName;
    }

    public String beanClassName() { return beanClassName; }
    public String methodName() { return methodName; }
}
```

`ScenarioAction.java`:
```java
package io.casehub.platform.api.expression;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.METHOD)
public @interface ScenarioAction {
    String value();
}
```

- [ ] **Step 2: Create ActionRegistry + ActionHandle in yaml-core**

`ActionRegistry.java`:
```java
package io.casehub.yaml.core.orchestration;

import java.util.Optional;
import java.util.Set;

public interface ActionRegistry {
    Optional<ActionHandle> resolve(String name);
    Set<String> registeredNames();
}
```

`ActionHandle.java`:
```java
package io.casehub.yaml.core.orchestration;

import java.util.Map;

@FunctionalInterface
public interface ActionHandle {
    Object invoke(ScenarioScope scope, Map<String, Object> args);
}
```

- [ ] **Step 3: Create NoOp implementations in platform-core**

`NoOpBeanInvoker.java`:
```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.BeanInvoker;

public class NoOpBeanInvoker implements BeanInvoker {
    @Override
    public Object invoke(String beanClassName, String methodName, Object... args) {
        throw new UnsupportedOperationException(
                "BeanInvoker not available — add casehub-platform-expression to the classpath");
    }
}
```

`NoOpInvocationPolicy.java`:
```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.InvocationPolicy;

public class NoOpInvocationPolicy implements InvocationPolicy {
    @Override
    public boolean isAllowed(String beanClassName, String methodName) {
        return true;
    }
}
```

`NoOpActionRegistry.java`:
```java
package io.casehub.platform.expression;

import io.casehub.yaml.core.orchestration.ActionHandle;
import io.casehub.yaml.core.orchestration.ActionRegistry;

import java.util.Optional;
import java.util.Set;

public class NoOpActionRegistry implements ActionRegistry {
    @Override
    public Optional<ActionHandle> resolve(String name) { return Optional.empty(); }
    @Override
    public Set<String> registeredNames() { return Set.of(); }
}
```

- [ ] **Step 4: Add @DefaultBean producers in DefaultBeans.java**

Add three new producer methods following the existing pattern:

```java
@Produces @DefaultBean
public NoOpBeanInvoker noOpBeanInvoker() { return new NoOpBeanInvoker(); }

@Produces @DefaultBean
public NoOpInvocationPolicy noOpInvocationPolicy() { return new NoOpInvocationPolicy(); }

@Produces @DefaultBean
public NoOpActionRegistry noOpActionRegistry() { return new NoOpActionRegistry(); }
```

- [ ] **Step 5: Write SPI contract tests**

```java
package io.casehub.platform.api.expression;

import io.casehub.platform.expression.NoOpBeanInvoker;
import io.casehub.platform.expression.NoOpInvocationPolicy;
import io.casehub.platform.expression.NoOpActionRegistry;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class BeanInvokerSpiTest {

    @Test
    void noOpBeanInvokerThrowsUnsupported() {
        var invoker = new NoOpBeanInvoker();
        assertThrows(UnsupportedOperationException.class,
                () -> invoker.invoke("Foo", "bar"));
    }

    @Test
    void noOpInvocationPolicyAllowsEverything() {
        var policy = new NoOpInvocationPolicy();
        assertTrue(policy.isAllowed("any.Class", "anyMethod"));
    }

    @Test
    void noOpActionRegistryReturnsEmpty() {
        var registry = new NoOpActionRegistry();
        assertTrue(registry.resolve("anything").isEmpty());
        assertTrue(registry.registeredNames().isEmpty());
    }
}
```

- [ ] **Step 6: Run tests**

Run: `mvn -pl platform-api,platform-core,platform -Dtest=BeanInvokerSpiTest test --batch-mode`
Expected: PASS

- [ ] **Step 7: Full build check**

Run: `mvn --batch-mode install -DskipTests`
Expected: BUILD SUCCESS — verify no dependency violations

- [ ] **Step 8: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/expression/BeanInvoker.java platform-api/src/main/java/io/casehub/platform/api/expression/InvocationPolicy.java platform-api/src/main/java/io/casehub/platform/api/expression/InvocationDeniedException.java platform-api/src/main/java/io/casehub/platform/api/expression/ScenarioAction.java yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ActionRegistry.java yaml-core/src/main/java/io/casehub/yaml/core/orchestration/ActionHandle.java platform-core/src/main/java/io/casehub/platform/expression/NoOpBeanInvoker.java platform-core/src/main/java/io/casehub/platform/expression/NoOpInvocationPolicy.java platform-core/src/main/java/io/casehub/platform/expression/NoOpActionRegistry.java platform/src/main/java/io/casehub/platform/quarkus/DefaultBeans.java platform-api/src/test/java/io/casehub/platform/api/expression/BeanInvokerSpiTest.java
git commit -m "feat(#411): BeanInvoker, InvocationPolicy, ActionRegistry SPIs + @ScenarioAction

BeanInvoker SPI uses primitive params (String, Object...) — no yaml-core
types in platform-api. ActionRegistry + ActionHandle in yaml-core alongside
ScenarioScope. @DefaultBean no-ops in platform-core.

Refs #411

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 2: CDI Implementations

### Task 4: AllowListInvocationPolicy

**Files:**
- Create: `expression-core/src/main/java/io/casehub/platform/expression/AllowListInvocationPolicy.java`
- Test: `expression/src/test/java/io/casehub/platform/expression/AllowListInvocationPolicyTest.java`

**Interfaces:**
- Consumes: `InvocationPolicy` SPI from platform-api
- Produces: `AllowListInvocationPolicy(Set<String> allowedPackages)` — constructor-injected package prefixes

- [ ] **Step 1: Write the failing tests**

```java
package io.casehub.platform.expression;

import org.junit.jupiter.api.Test;

import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

class AllowListInvocationPolicyTest {

    @Test
    void allowsMethodInAllowedPackage() {
        var policy = new AllowListInvocationPolicy(Set.of("io.casehub.trading"));
        assertTrue(policy.isAllowed("io.casehub.trading.OrderService", "place"));
    }

    @Test
    void deniesMethodOutsideAllowedPackage() {
        var policy = new AllowListInvocationPolicy(Set.of("io.casehub.trading"));
        assertFalse(policy.isAllowed("java.lang.Runtime", "exec"));
    }

    @Test
    void allowsSubpackageOfAllowedPrefix() {
        var policy = new AllowListInvocationPolicy(Set.of("io.casehub"));
        assertTrue(policy.isAllowed("io.casehub.trading.sub.DeepService", "call"));
    }

    @Test
    void multipleAllowedPackages() {
        var policy = new AllowListInvocationPolicy(Set.of("io.casehub.trading", "io.casehub.risk"));
        assertTrue(policy.isAllowed("io.casehub.trading.OrderService", "place"));
        assertTrue(policy.isAllowed("io.casehub.risk.RiskEngine", "evaluate"));
        assertFalse(policy.isAllowed("io.casehub.admin.AdminService", "delete"));
    }

    @Test
    void emptyAllowListDeniesEverything() {
        var policy = new AllowListInvocationPolicy(Set.of());
        assertFalse(policy.isAllowed("io.casehub.trading.OrderService", "place"));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl expression -Dtest=AllowListInvocationPolicyTest test --batch-mode`
Expected: FAIL — class does not exist

- [ ] **Step 3: Implement AllowListInvocationPolicy**

```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.InvocationPolicy;

import java.util.Set;

public class AllowListInvocationPolicy implements InvocationPolicy {

    private final Set<String> allowedPackages;

    public AllowListInvocationPolicy(Set<String> allowedPackages) {
        this.allowedPackages = Set.copyOf(allowedPackages);
    }

    @Override
    public boolean isAllowed(String beanClassName, String methodName) {
        if (allowedPackages.isEmpty()) { return false; }
        for (String prefix : allowedPackages) {
            if (beanClassName.startsWith(prefix)) { return true; }
        }
        return false;
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn -pl expression -Dtest=AllowListInvocationPolicyTest test --batch-mode`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add expression-core/src/main/java/io/casehub/platform/expression/AllowListInvocationPolicy.java expression/src/test/java/io/casehub/platform/expression/AllowListInvocationPolicyTest.java
git commit -m "feat(#411): AllowListInvocationPolicy — fail-closed package allow-list

Empty allow-list denies everything. Package prefixes matched via startsWith.

Refs #411

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 5: CdiBeanInvoker

**Files:**
- Create: `expression-core/src/main/java/io/casehub/platform/expression/ReflectiveBeanInvoker.java`
- Create: `expression/src/main/java/io/casehub/platform/expression/CdiBeanInvokerProducer.java`
- Test: `expression/src/test/java/io/casehub/platform/expression/ReflectiveBeanInvokerTest.java`

**Interfaces:**
- Consumes: `BeanInvoker` SPI, `InvocationPolicy` SPI
- Produces: `ReflectiveBeanInvoker(Function<String, Object> beanResolver, InvocationPolicy policy)` — framework-neutral core POJO

- [ ] **Step 1: Write the failing tests**

```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.InvocationDeniedException;
import io.casehub.platform.api.expression.InvocationPolicy;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Function;

import static org.junit.jupiter.api.Assertions.*;

class ReflectiveBeanInvokerTest {

    public static class Calculator {
        public int add(int a, int b) { return a + b; }
        public String greet() { return "hello"; }
        public int sum(int... numbers) {
            int total = 0;
            for (int n : numbers) total += n;
            return total;
        }
    }

    private final InvocationPolicy allowAll = (bean, method) -> true;
    private final Map<String, Object> beans = new ConcurrentHashMap<>(Map.of(
            "test.Calculator", new Calculator()
    ));
    private final Function<String, Object> resolver = name -> {
        Object bean = beans.get(name);
        if (bean == null) throw new IllegalArgumentException("Bean not found: " + name);
        return bean;
    };

    @Test
    void invokesSimpleMethodWithArgs() {
        var invoker = new ReflectiveBeanInvoker(resolver, allowAll);
        assertEquals(5, invoker.invoke("test.Calculator", "add", 2, 3));
    }

    @Test
    void invokesNoArgMethod() {
        var invoker = new ReflectiveBeanInvoker(resolver, allowAll);
        assertEquals("hello", invoker.invoke("test.Calculator", "greet"));
    }

    @Test
    void invokesVarargsMethod() {
        var invoker = new ReflectiveBeanInvoker(resolver, allowAll);
        assertEquals(10, invoker.invoke("test.Calculator", "sum", 1, 2, 3, 4));
    }

    @Test
    void prefersFixedArityOverVarargs() {
        var invoker = new ReflectiveBeanInvoker(resolver, allowAll);
        assertEquals(7, invoker.invoke("test.Calculator", "add", 3, 4));
    }

    @Test
    void policyDenialThrowsInvocationDenied() {
        InvocationPolicy denyAll = (bean, method) -> false;
        var invoker = new ReflectiveBeanInvoker(resolver, denyAll);
        assertThrows(InvocationDeniedException.class,
                () -> invoker.invoke("test.Calculator", "add", 1, 2));
    }

    @Test
    void unknownBeanThrowsIllegalArgument() {
        var invoker = new ReflectiveBeanInvoker(resolver, allowAll);
        assertThrows(IllegalArgumentException.class,
                () -> invoker.invoke("nonexistent.Bean", "method"));
    }

    @Test
    void unknownMethodThrowsIllegalArgument() {
        var invoker = new ReflectiveBeanInvoker(resolver, allowAll);
        assertThrows(IllegalArgumentException.class,
                () -> invoker.invoke("test.Calculator", "nonexistent"));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl expression -Dtest=ReflectiveBeanInvokerTest test --batch-mode`
Expected: FAIL — class does not exist

- [ ] **Step 3: Implement ReflectiveBeanInvoker**

```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.BeanInvoker;
import io.casehub.platform.api.expression.InvocationDeniedException;
import io.casehub.platform.api.expression.InvocationPolicy;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.function.Function;

public class ReflectiveBeanInvoker implements BeanInvoker {

    private final Function<String, Object> beanResolver;
    private final InvocationPolicy policy;

    public ReflectiveBeanInvoker(Function<String, Object> beanResolver, InvocationPolicy policy) {
        this.beanResolver = beanResolver;
        this.policy = policy;
    }

    @Override
    public Object invoke(String beanClassName, String methodName, Object... args) {
        if (!policy.isAllowed(beanClassName, methodName)) {
            throw new InvocationDeniedException(beanClassName, methodName);
        }
        Object bean = beanResolver.apply(beanClassName);
        Method method = resolveMethod(bean.getClass(), methodName, args.length);
        try {
            if (method.isVarArgs()) {
                return invokeVarargs(bean, method, args);
            }
            return method.invoke(bean, args);
        } catch (InvocationTargetException e) {
            if (e.getCause() instanceof RuntimeException re) throw re;
            throw new RuntimeException("Invocation failed: " + beanClassName + "::" + methodName, e.getCause());
        } catch (IllegalAccessException e) {
            throw new RuntimeException("Method not accessible: " + beanClassName + "::" + methodName, e);
        }
    }

    private Method resolveMethod(Class<?> beanClass, String methodName, int argCount) {
        Method varArgsCandidate = null;
        for (Method m : beanClass.getMethods()) {
            if (!m.getName().equals(methodName)) continue;
            if (m.isVarArgs() && argCount >= m.getParameterCount() - 1) {
                if (m.getParameterCount() - 1 == argCount && !m.isVarArgs()) return m;
                varArgsCandidate = m;
                continue;
            }
            if (m.getParameterCount() == argCount) return m;
        }
        if (varArgsCandidate != null) return varArgsCandidate;
        throw new IllegalArgumentException(
                "No method '" + methodName + "' with " + argCount + " args on " + beanClass.getName());
    }

    private Object invokeVarargs(Object bean, Method method, Object[] args) throws InvocationTargetException, IllegalAccessException {
        int fixedCount = method.getParameterCount() - 1;
        Class<?> varArgType = method.getParameterTypes()[fixedCount].getComponentType();
        Object[] varArgs = (Object[]) java.lang.reflect.Array.newInstance(varArgType, args.length - fixedCount);
        System.arraycopy(args, fixedCount, varArgs, 0, varArgs.length);
        Object[] invokeArgs = new Object[fixedCount + 1];
        System.arraycopy(args, 0, invokeArgs, 0, fixedCount);
        invokeArgs[fixedCount] = varArgs;
        return method.invoke(bean, invokeArgs);
    }
}
```

- [ ] **Step 4: Create CDI producer**

`CdiBeanInvokerProducer.java` in expression/:
```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.InvocationPolicy;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Produces;
import jakarta.enterprise.inject.spi.BeanManager;

@ApplicationScoped
public class CdiBeanInvokerProducer {

    @Produces
    @ApplicationScoped
    public ReflectiveBeanInvoker cdiBeanInvoker(BeanManager beanManager, InvocationPolicy policy) {
        return new ReflectiveBeanInvoker(className -> {
            try {
                Class<?> beanClass = Class.forName(className);
                var beans = beanManager.getBeans(beanClass);
                if (beans.isEmpty()) throw new IllegalArgumentException("No CDI bean for: " + className);
                var bean = beanManager.resolve(beans);
                var ctx = beanManager.createCreationalContext(bean);
                return beanManager.getReference(bean, beanClass, ctx);
            } catch (ClassNotFoundException e) {
                throw new IllegalArgumentException("Class not found: " + className, e);
            }
        }, policy);
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mvn -pl expression -Dtest=ReflectiveBeanInvokerTest test --batch-mode`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add expression-core/src/main/java/io/casehub/platform/expression/ReflectiveBeanInvoker.java expression/src/main/java/io/casehub/platform/expression/CdiBeanInvokerProducer.java expression/src/test/java/io/casehub/platform/expression/ReflectiveBeanInvokerTest.java
git commit -m "feat(#411): ReflectiveBeanInvoker — Tier 3 CDI bean invocation

Framework-neutral core POJO with Function<String,Object> resolver.
CDI producer wraps BeanManager resolution. InvocationPolicy checked
before every invoke. Varargs support with fixed-arity preference.

Refs #411

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 6: CdiActionRegistry

**Files:**
- Create: `expression-core/src/main/java/io/casehub/platform/expression/DefaultActionRegistry.java`
- Create: `expression/src/main/java/io/casehub/platform/expression/CdiActionRegistryProducer.java`
- Test: `expression/src/test/java/io/casehub/platform/expression/DefaultActionRegistryTest.java`

**Interfaces:**
- Consumes: `ActionRegistry`, `ActionHandle` (yaml-core), `@ScenarioAction` (platform-api)
- Produces: `DefaultActionRegistry` — POJO with `register(String name, ActionHandle handle)` + resolve/registeredNames

- [ ] **Step 1: Write the failing tests**

```java
package io.casehub.platform.expression;

import io.casehub.yaml.core.orchestration.ActionHandle;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class DefaultActionRegistryTest {

    @Test
    void resolvesRegisteredAction() {
        var registry = new DefaultActionRegistry();
        ActionHandle handle = (scope, args) -> "executed";
        registry.register("test-action", handle);

        var resolved = registry.resolve("test-action");
        assertTrue(resolved.isPresent());
        assertEquals("executed", resolved.get().invoke(null, Map.of()));
    }

    @Test
    void returnsEmptyForUnknownAction() {
        var registry = new DefaultActionRegistry();
        assertTrue(registry.resolve("unknown").isEmpty());
    }

    @Test
    void registeredNamesReturnsAllNames() {
        var registry = new DefaultActionRegistry();
        registry.register("action-a", (s, a) -> null);
        registry.register("action-b", (s, a) -> null);

        var names = registry.registeredNames();
        assertEquals(2, names.size());
        assertTrue(names.contains("action-a"));
        assertTrue(names.contains("action-b"));
    }

    @Test
    void duplicateNameThrowsOnRegister() {
        var registry = new DefaultActionRegistry();
        registry.register("dup", (s, a) -> null);
        assertThrows(IllegalArgumentException.class,
                () -> registry.register("dup", (s, a) -> null));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn -pl expression -Dtest=DefaultActionRegistryTest test --batch-mode`
Expected: FAIL — class does not exist

- [ ] **Step 3: Implement DefaultActionRegistry**

```java
package io.casehub.platform.expression;

import io.casehub.yaml.core.orchestration.ActionHandle;
import io.casehub.yaml.core.orchestration.ActionRegistry;

import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

public class DefaultActionRegistry implements ActionRegistry {

    private final Map<String, ActionHandle> actions = new ConcurrentHashMap<>();

    public void register(String name, ActionHandle handle) {
        if (actions.putIfAbsent(name, handle) != null) {
            throw new IllegalArgumentException(
                    "Duplicate @ScenarioAction name: '" + name + "' — action names must be unique");
        }
    }

    @Override
    public Optional<ActionHandle> resolve(String name) {
        return Optional.ofNullable(actions.get(name));
    }

    @Override
    public Set<String> registeredNames() {
        return Set.copyOf(actions.keySet());
    }
}
```

- [ ] **Step 4: Create CDI startup scanner**

`CdiActionRegistryProducer.java`:
```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.ScenarioAction;
import io.casehub.yaml.core.orchestration.ActionHandle;
import io.casehub.yaml.core.orchestration.ScenarioScope;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Produces;
import jakarta.enterprise.inject.spi.BeanManager;
import jakarta.enterprise.inject.spi.CDI;
import io.quarkus.runtime.Startup;

import java.lang.reflect.Method;
import java.util.Map;

@ApplicationScoped
public class CdiActionRegistryProducer {

    @Produces
    @ApplicationScoped
    @Startup
    @SuppressWarnings("unchecked")
    public DefaultActionRegistry cdiActionRegistry(BeanManager beanManager) {
        var registry = new DefaultActionRegistry();
        for (var beanType : beanManager.getBeans(Object.class)) {
            Class<?> beanClass = beanType.getBeanClass();
            for (Method method : beanClass.getMethods()) {
                ScenarioAction annotation = method.getAnnotation(ScenarioAction.class);
                if (annotation == null) continue;
                String actionName = annotation.value();
                ActionHandle handle = (scope, args) -> {
                    Object bean = CDI.current().select(beanClass).get();
                    try {
                        return method.invoke(bean, scope, args);
                    } catch (Exception e) {
                        throw new RuntimeException("Action '" + actionName + "' failed", e);
                    }
                };
                registry.register(actionName, handle);
            }
        }
        return registry;
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mvn -pl expression -Dtest=DefaultActionRegistryTest test --batch-mode`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add expression-core/src/main/java/io/casehub/platform/expression/DefaultActionRegistry.java expression/src/main/java/io/casehub/platform/expression/CdiActionRegistryProducer.java expression/src/test/java/io/casehub/platform/expression/DefaultActionRegistryTest.java
git commit -m "feat(#411): DefaultActionRegistry + CDI startup scanner for @ScenarioAction

ConcurrentHashMap-backed registry. CDI producer scans beans at startup
for @ScenarioAction-annotated methods. Duplicate names rejected.

Refs #411

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 3: Spring Equivalents + Integration

### Task 7: Spring implementations

**Files:**
- Create: `expression-spring/src/main/java/io/casehub/platform/expression/spring/SpringBeanInvokerAutoConfiguration.java`
- Create: `expression-spring/src/main/java/io/casehub/platform/expression/spring/SpringActionRegistryAutoConfiguration.java`
- Test: `expression-spring/src/test/java/io/casehub/platform/expression/spring/SpringBeanInvokerTest.java`
- Test: `expression-spring/src/test/java/io/casehub/platform/expression/spring/SpringActionRegistryTest.java`

**Interfaces:**
- Consumes: `ReflectiveBeanInvoker`, `DefaultActionRegistry`, `AllowListInvocationPolicy` (expression-core)
- Produces: Spring auto-config beans wrapping core POJOs with ApplicationContext resolution

- [ ] **Step 1: Write SpringBeanInvoker auto-config**

```java
package io.casehub.platform.expression.spring;

import io.casehub.platform.api.expression.InvocationPolicy;
import io.casehub.platform.expression.AllowListInvocationPolicy;
import io.casehub.platform.expression.ReflectiveBeanInvoker;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.ApplicationContext;
import org.springframework.context.annotation.Bean;

import java.util.Set;

@AutoConfiguration
public class SpringBeanInvokerAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean
    public InvocationPolicy invocationPolicy(SpringInvokeProperties properties) {
        return new AllowListInvocationPolicy(properties.allowedPackages());
    }

    @Bean
    @ConditionalOnMissingBean
    public ReflectiveBeanInvoker beanInvoker(ApplicationContext ctx, InvocationPolicy policy) {
        return new ReflectiveBeanInvoker(className -> {
            try {
                return ctx.getBean(Class.forName(className));
            } catch (ClassNotFoundException e) {
                throw new IllegalArgumentException("Class not found: " + className, e);
            }
        }, policy);
    }

    @ConfigurationProperties(prefix = "casehub.expression.invoke")
    public record SpringInvokeProperties(Set<String> allowedPackages) {
        public SpringInvokeProperties {
            if (allowedPackages == null) allowedPackages = Set.of();
        }
    }
}
```

- [ ] **Step 2: Write SpringActionRegistry auto-config**

```java
package io.casehub.platform.expression.spring;

import io.casehub.platform.api.expression.ScenarioAction;
import io.casehub.platform.expression.DefaultActionRegistry;
import io.casehub.yaml.core.orchestration.ScenarioScope;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.ApplicationContext;
import org.springframework.context.annotation.Bean;

import java.lang.reflect.Method;
import java.util.Map;

@AutoConfiguration
public class SpringActionRegistryAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean
    public DefaultActionRegistry actionRegistry(ApplicationContext ctx) {
        var registry = new DefaultActionRegistry();
        for (String beanName : ctx.getBeanDefinitionNames()) {
            Object bean = ctx.getBean(beanName);
            for (Method method : bean.getClass().getMethods()) {
                ScenarioAction annotation = method.getAnnotation(ScenarioAction.class);
                if (annotation == null) continue;
                String actionName = annotation.value();
                registry.register(actionName, (scope, args) -> {
                    try {
                        return method.invoke(bean, scope, args);
                    } catch (Exception e) {
                        throw new RuntimeException("Action '" + actionName + "' failed", e);
                    }
                });
            }
        }
        return registry;
    }
}
```

- [ ] **Step 3: Write Spring tests**

```java
package io.casehub.platform.expression.spring;

import io.casehub.platform.expression.ReflectiveBeanInvoker;
import io.casehub.platform.expression.AllowListInvocationPolicy;
import org.junit.jupiter.api.Test;

import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

class SpringBeanInvokerTest {

    public static class TestService {
        public String hello() { return "world"; }
    }

    @Test
    void invokesViaApplicationContextResolver() {
        var policy = new AllowListInvocationPolicy(Set.of("io.casehub"));
        var service = new TestService();
        var invoker = new ReflectiveBeanInvoker(
                name -> name.equals(TestService.class.getName()) ? service : null,
                policy
        );
        assertEquals("world", invoker.invoke(TestService.class.getName(), "hello"));
    }
}
```

```java
package io.casehub.platform.expression.spring;

import io.casehub.platform.expression.DefaultActionRegistry;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class SpringActionRegistryTest {

    @Test
    void registryResolvesAndInvokes() {
        var registry = new DefaultActionRegistry();
        registry.register("greet", (scope, args) -> "hello " + args.get("name"));

        var handle = registry.resolve("greet");
        assertTrue(handle.isPresent());
        assertEquals("hello world", handle.get().invoke(null, Map.of("name", "world")));
    }
}
```

- [ ] **Step 4: Run tests**

Run: `mvn -pl expression-spring -Dtest="SpringBeanInvokerTest,SpringActionRegistryTest" test --batch-mode`
Expected: PASS

- [ ] **Step 5: Full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile and tests pass

- [ ] **Step 6: Commit**

```bash
git add expression-spring/src/main/java/io/casehub/platform/expression/spring/ expression-spring/src/test/java/io/casehub/platform/expression/spring/
git commit -m "feat(#411): Spring auto-configurations for BeanInvoker + ActionRegistry

Hand-written Spring equivalents — ApplicationContext bean resolution,
method-level @ScenarioAction scanning, ConfigurationProperties for
allowed-packages.

Refs #411

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## References

- [2026-09-23-expression-escape-model-design.md] — design spec this plan implements
- [decisions.md] — 7 decisions (D1-D7)
- [expression-core/src/main/java/.../DefaultExpressionEngineRegistry.java] — existing registry, gains constructor defaults
- [platform-api/src/main/java/.../ExpressionEngineRegistry.java] — SPI with registerDefault/resolveDefault
- [yaml-core/src/main/java/.../ForEachDirective.java] — parse(Object) pattern for InvokeDirective
- [yaml-core/src/main/java/.../ComputeBlock.java] — directive data model pattern
- [yaml-core/src/main/java/.../ScenarioScope.java] — ActionHandle.invoke() parameter
- [platform/src/main/java/.../DefaultBeans.java] — @DefaultBean producers
- [#391 decisions.md] — four-tier model design (D3, D4, D14)
- [GitHub #411] — focal issue
