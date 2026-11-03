# Type-Safe Expression Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #699 — feat: type-safe expression resolution — eliminate redundant ${} wrappers
**Issue group:** #699

**Goal:** Add `ParameterType.EXPRESSION` to the plugin type system so that EXPRESSION-typed parameters are automatically evaluated via ExpressionEngine, eliminating manual `${...}` wrapping and per-plugin expression boilerplate.

**Architecture:** A new `TypeAwareParamResolver` in yaml-step-runtime routes parameters by their declared type: EXPRESSION params go to ExpressionEngine, all others go through VariableResolver as today. Expression context is exported from VariableResolver via concrete Map-backed scopes. The `@Expression` annotation in yaml-plugin-api drives schema generation and runtime type-awareness.

**Tech Stack:** Java 21, yaml-plugin-api (zero-dep), yaml-core (zero-dep), platform-api, yaml-step-runtime, yaml-plugin-processor (APT), MVEL3

## Global Constraints

- `yaml-plugin-api` and `yaml-core` must remain zero-dependency and J2CL-safe
- `@Expression` annotation must target `RECORD_COMPONENT`, `FIELD`, and `PARAMETER` (matching `@Required`)
- `@Expression` record fields must be typed `Object` (not `String`) — MVEL returns typed results
- EXPRESSION params always route to ExpressionEngine, never VariableResolver — clean separation
- `${...}` wrapping in EXPRESSION fields must be accepted and stripped (backward compat)
- Fail fast with `IllegalStateException` when ExpressionEngineRegistry is missing
- Zero overhead for plugins that don't use EXPRESSION (hasExpressionParams guard)

---

## Batch 1: Foundation types

### Task 1: ParameterType.EXPRESSION + @Expression annotation + ExpressionContext.PARAMETER

**Files:**
- Modify: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/ParameterType.java`
- Create: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Expression.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionContext.java`
- Test: `yaml-plugin-api/src/test/java/io/casehub/yaml/plugin/api/ParameterTypeTest.java`

**Interfaces:**
- Produces: `ParameterType.EXPRESSION` enum constant (used by Task 2, 4, 5, 6, 7)
- Produces: `@Expression` annotation (used by Task 6)
- Produces: `ExpressionContext.PARAMETER` enum constant (used by Task 4)

- [ ] **Step 1: Write failing tests for ParameterType.EXPRESSION**

```java
@Test
void expression_isScalar() {
    assertTrue(ParameterType.EXPRESSION.isScalar());
}

@Test
void expression_validate_acceptsAnyNonNull() {
    assertTrue(ParameterType.EXPRESSION.validate("some expression"));
    assertTrue(ParameterType.EXPRESSION.validate(42));
    assertTrue(ParameterType.EXPRESSION.validate(Map.of()));
    assertTrue(ParameterType.EXPRESSION.validate(null));
}

@Test
void expression_parseScalar_returnsRawString() {
    assertEquals("results.output.risk", ParameterType.EXPRESSION.parseScalar("results.output.risk"));
}

@Test
void expression_canAccept_string() {
    assertTrue(ParameterType.EXPRESSION.canAccept(ParameterType.STRING));
}

@Test
void string_cannotAccept_expression() {
    assertFalse(ParameterType.STRING.canAccept(ParameterType.EXPRESSION));
}

@Test
void expression_fromString() {
    assertEquals(ParameterType.EXPRESSION, ParameterType.fromString("EXPRESSION"));
    assertEquals(ParameterType.EXPRESSION, ParameterType.fromString("expression"));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn test -pl yaml-plugin-api -Dtest=ParameterTypeTest -Dsurefire.failIfNoSpecifiedTests=false --batch-mode`
Expected: Compilation error — `EXPRESSION` not defined

- [ ] **Step 3: Add EXPRESSION to ParameterType enum**

In `ParameterType.java`, add `EXPRESSION` to the enum and update all switch expressions:

```java
STRING, INTEGER, NUMBER, BOOLEAN, ARRAY, OBJECT, EXPRESSION;
```

Update `validate()`:
```java
case EXPRESSION -> true;
```

Update `parseScalar()`:
```java
case EXPRESSION -> value;
```

Update `canAccept()` — add before the final `return false`:
```java
if (this == EXPRESSION && outputType == STRING) return true;
```

Update `fromString()`:
```java
case "EXPRESSION" -> EXPRESSION;
```

- [ ] **Step 4: Create @Expression annotation**

Create `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Expression.java`:

```java
package io.casehub.yaml.plugin.api;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target({ElementType.RECORD_COMPONENT, ElementType.FIELD, ElementType.PARAMETER})
@Retention(RetentionPolicy.RUNTIME)
public @interface Expression {}
```

- [ ] **Step 5: Add PARAMETER to ExpressionContext**

In `platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionContext.java`:

```java
public enum ExpressionContext {
    CONDITION,
    TRANSFORM,
    FILTER,
    PARAMETER
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn test -pl yaml-plugin-api -Dtest=ParameterTypeTest --batch-mode`
Expected: All PASS

- [ ] **Step 7: Compile platform-api to verify ExpressionContext change**

Run: `mvn compile -pl platform-api --batch-mode`
Expected: BUILD SUCCESS

- [ ] **Step 8: Commit**

```bash
git add yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/ParameterType.java yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Expression.java yaml-plugin-api/src/test/java/io/casehub/yaml/plugin/api/ParameterTypeTest.java platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionContext.java
git commit -m "feat(#699): ParameterType.EXPRESSION, @Expression annotation, ExpressionContext.PARAMETER"
```

---

### Task 2: VariableResolver scope infrastructure

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/resolver/VariableResolverTest.java`

**Interfaces:**
- Consumes: nothing new (internal changes)
- Produces: `VariableResolver.withObjectScope(String, Map<String, Object>)` overload (used by Task 7)
- Produces: `VariableResolver.withExpressionContext(String, Map<String, Object>)` method (used by Task 7)
- Produces: `VariableResolver.buildExpressionContext()` → `Map<String, Object>` (used by Task 4)

- [ ] **Step 1: Write failing tests for scope infrastructure**

Add to `VariableResolverTest.java`:

```java
@Test
void withObjectScope_map_appearsInExpressionContext() {
    Map<String, Object> data = Map.of("name", "Alice", "age", 30);
    var resolver = new VariableResolver(Map.of(), Set.of())
            .withObjectScope("user", data);
    Map<String, Object> ctx = resolver.buildExpressionContext();
    assertEquals(1, ctx.size());
    assertSame(data, ctx.get("user"));
}

@Test
void withObjectScope_functional_notInExpressionContext() {
    var resolver = new VariableResolver(Map.of(), Set.of())
            .withObjectScope("user", name -> "value");
    Map<String, Object> ctx = resolver.buildExpressionContext();
    assertTrue(ctx.isEmpty());
}

@Test
void buildExpressionContext_excludesDeferredPrefixes() {
    Map<String, Object> data = Map.of("x", 1);
    var resolver = new VariableResolver(Map.of(), Set.of("events"))
            .withObjectScope("events", data);
    Map<String, Object> ctx = resolver.buildExpressionContext();
    assertFalse(ctx.containsKey("events"));
}

@Test
void scopeContainers_preservedAcross_withScope() {
    Map<String, Object> data = Map.of("x", 1);
    var resolver = new VariableResolver(Map.of(), Set.of())
            .withObjectScope("result", data)
            .withScope("var", name -> "val");
    Map<String, Object> ctx = resolver.buildExpressionContext();
    assertSame(data, ctx.get("result"));
}

@Test
void scopeContainers_preservedAcross_withObjectScope_functional() {
    Map<String, Object> data = Map.of("x", 1);
    var resolver = new VariableResolver(Map.of(), Set.of())
            .withObjectScope("result", data)
            .withObjectScope("other", name -> "val");
    Map<String, Object> ctx = resolver.buildExpressionContext();
    assertEquals(1, ctx.size());
    assertSame(data, ctx.get("result"));
}

@Test
void withExpressionContext_addsToContainersOnly() {
    Map<String, Object> data = Map.of("x", 1);
    var resolver = new VariableResolver(Map.of(), Set.of())
            .withExpressionContext("result", data);
    Map<String, Object> ctx = resolver.buildExpressionContext();
    assertSame(data, ctx.get("result"));
    // String resolution should NOT see this scope
    assertThrows(io.casehub.yaml.core.resolver.UnresolvedVariableException.class,
            () -> resolver.resolveString("${result.x}", "test"));
}

@Test
void withObjectScope_map_alsoResolvesStrings() {
    Map<String, Object> data = Map.of("name", "Alice");
    var resolver = new VariableResolver(Map.of(), Set.of())
            .withObjectScope("user", data);
    Object result = resolver.resolve("${user.name}");
    assertEquals("Alice", result);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn test -pl yaml-core -Dtest=VariableResolverTest --batch-mode`
Expected: Compilation errors — `buildExpressionContext()`, `withExpressionContext()`, and `withObjectScope(String, Map)` not defined

- [ ] **Step 3: Implement scope infrastructure in VariableResolver**

Add `scopeContainers` field and update the private constructor to 5 parameters:

```java
private final Map<String, Object> scopeContainers;

private VariableResolver(Map<String, VariableSource> prefixSources,
                         Map<String, ObjectVariableSource> objectPrefixSources,
                         Set<String> deferredPrefixes,
                         DeferredPrefixHandler deferredPrefixHandler,
                         Map<String, Object> scopeContainers) {
    this.prefixSources         = prefixSources;
    this.objectPrefixSources   = objectPrefixSources;
    this.deferredPrefixes      = deferredPrefixes;
    this.deferredPrefixHandler = deferredPrefixHandler;
    this.scopeContainers       = scopeContainers;
}
```

Update the public 2-parameter constructor to pass `Map.of()` for scopeContainers:

```java
public VariableResolver(Map<String, VariableSource> prefixSources,
                        Set<String> deferredPrefixes) {
    this.prefixSources         = Map.copyOf(prefixSources);
    this.objectPrefixSources   = Map.of();
    this.deferredPrefixes      = Set.copyOf(deferredPrefixes);
    this.deferredPrefixHandler = null;
    this.scopeContainers       = Map.of();
}
```

Update ALL existing methods that create new VariableResolver instances to forward `this.scopeContainers`:
- `withScope()` — pass `scopeContainers`
- `withDeferredPrefixHandler()` — pass `scopeContainers`
- `withObjectScope(String, ObjectVariableSource)` — pass `scopeContainers`
- `withChainedScope()` — pass `scopeContainers`
- `forParams()` static factory — pass `Map.of()`

Add `withObjectScope(String, Map)` overload:

```java
public VariableResolver withObjectScope(String prefix, Map<String, Object> map) {
    var newObjectSources = new LinkedHashMap<>(objectPrefixSources);
    newObjectSources.put(prefix, map::get);
    var newContainers = new LinkedHashMap<>(scopeContainers);
    newContainers.put(prefix, map);
    return new VariableResolver(prefixSources, Map.copyOf(newObjectSources),
            deferredPrefixes, deferredPrefixHandler, Map.copyOf(newContainers));
}
```

Add `withExpressionContext()`:

```java
public VariableResolver withExpressionContext(String prefix, Map<String, Object> map) {
    var newContainers = new LinkedHashMap<>(scopeContainers);
    newContainers.put(prefix, map);
    return new VariableResolver(prefixSources, objectPrefixSources,
            deferredPrefixes, deferredPrefixHandler, Map.copyOf(newContainers));
}
```

Add `buildExpressionContext()`:

```java
public Map<String, Object> buildExpressionContext() {
    Map<String, Object> context = new LinkedHashMap<>();
    for (var entry : scopeContainers.entrySet()) {
        if (!deferredPrefixes.contains(entry.getKey())) {
            context.put(entry.getKey(), entry.getValue());
        }
    }
    return context;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn test -pl yaml-core -Dtest=VariableResolverTest --batch-mode`
Expected: All PASS

- [ ] **Step 5: Run all yaml-core tests for regression**

Run: `mvn test -pl yaml-core --batch-mode`
Expected: All PASS (existing tests unaffected — scopeContainers is transparent)

- [ ] **Step 6: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java yaml-core/src/test/java/io/casehub/yaml/core/resolver/VariableResolverTest.java
git commit -m "feat(#699): VariableResolver scope infrastructure — withObjectScope(Map), withExpressionContext, buildExpressionContext"
```

---

### Task 3: StepResultStore.liveResults()

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/StepResultStore.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultStepResultStore.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/orchestration/DefaultStepResultStoreTest.java`

**Interfaces:**
- Consumes: nothing new
- Produces: `StepResultStore.liveResults()` → `Map<String, Object>` (used by Task 7)

- [ ] **Step 1: Write failing test for liveResults()**

Add to `DefaultStepResultStoreTest.java`:

```java
@Test
void liveResults_returnsLiveView() {
    var store = new DefaultStepResultStore();
    Map<String, Object> live = store.liveResults();
    assertTrue(live.isEmpty());

    store.recordSuccess("step1", Map.of("output", "value1"));
    assertEquals(1, live.size());
    assertEquals(Map.of("output", "value1"), live.get("step1"));

    store.recordSuccess("step2", Map.of("output", "value2"));
    assertEquals(2, live.size());
}

@Test
void liveResults_excludesFailedSteps() {
    var store = new DefaultStepResultStore();
    store.recordFailure("badStep", new io.casehub.yaml.core.error.RuntimeStepError.StepActionError(
            "badStep", null, "failed", io.casehub.yaml.core.error.SourceLocation.UNKNOWN, null));
    Map<String, Object> live = store.liveResults();
    assertFalse(live.containsKey("badStep"));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn test -pl yaml-core -Dtest=DefaultStepResultStoreTest --batch-mode`
Expected: Compilation error — `liveResults()` not defined

- [ ] **Step 3: Add liveResults() to StepResultStore interface and DefaultStepResultStore**

In `StepResultStore.java`, add:

```java
default Map<String, Object> liveResults() {
    return Map.of();
}
```

In `DefaultStepResultStore.java`, add:

```java
@SuppressWarnings("unchecked")
@Override
public Map<String, Object> liveResults() {
    return (Map<String, Object>) (Map<?, ?>) results;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn test -pl yaml-core -Dtest=DefaultStepResultStoreTest --batch-mode`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/StepResultStore.java yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultStepResultStore.java yaml-core/src/test/java/io/casehub/yaml/core/orchestration/DefaultStepResultStoreTest.java
git commit -m "feat(#699): StepResultStore.liveResults() — live ConcurrentHashMap view for expression context"
```

---

## Batch 2: Resolution engine

### Task 4: TypeAwareParamResolver

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/TypeAwareParamResolver.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/TypeAwareParamResolverTest.java`

**Interfaces:**
- Consumes: `ParameterType.EXPRESSION` (Task 1), `VariableResolver.buildExpressionContext()` (Task 2), `ExpressionContext.PARAMETER` (Task 1)
- Produces: `TypeAwareParamResolver.resolve(Map<String, Object>, Map<String, Parameter>)` → `Map<String, Object>` (used by Task 5)

- [ ] **Step 1: Write failing tests for TypeAwareParamResolver**

Create `yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/TypeAwareParamResolverTest.java`:

```java
package io.casehub.yaml.step.eval;

import io.casehub.platform.api.expression.CompiledExpression;
import io.casehub.platform.api.expression.ExpressionContext;
import io.casehub.platform.api.expression.ExpressionEngine;
import io.casehub.platform.api.expression.ExpressionEngineRegistry;
import io.casehub.yaml.core.resolver.VariableResolver;
import io.casehub.yaml.plugin.api.MapServiceRegistry;
import io.casehub.yaml.plugin.api.Parameter;
import io.casehub.yaml.plugin.api.ParameterType;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

class TypeAwareParamResolverTest {

    private ExpressionEngineRegistry mockRegistry() {
        return new io.casehub.platform.api.expression.DefaultExpressionEngineRegistry() {{
            var engine = new ExpressionEngine() {
                @Override public String type() { return "test"; }
                @Override @SuppressWarnings("unchecked")
                public <C, R> CompiledExpression<C, R> compile(String expr, Class<C> ct, Class<R> rt) {
                    return (CompiledExpression<C, R>) (CompiledExpression<Map<String, Object>, Object>) ctx -> {
                        String[] parts = expr.split("\\.");
                        Object current = ctx.get(parts[0]);
                        for (int i = 1; i < parts.length && current instanceof Map; i++) {
                            current = ((Map<?, ?>) current).get(parts[i]);
                        }
                        return current;
                    };
                }
                @Override public void validate(String expr) {}
            };
            register(engine);
            registerDefault(ExpressionContext.PARAMETER, "test");
        }};
    }

    @Test
    void stringParams_resolvedViaVariableResolver() {
        var services = new MapServiceRegistry();
        services.register(ExpressionEngineRegistry.class, mockRegistry());
        var resolver = new VariableResolver(Map.of("var", name -> "hello"), Set.of());
        var paramResolver = new TypeAwareParamResolver(resolver, services);

        Map<String, Parameter> inputs = Map.of("greeting", new Parameter(ParameterType.STRING, false, null, null, null, null));
        Map<String, Object> result = paramResolver.resolve(Map.of("greeting", "${var.name}"), inputs);
        // STRING params go through VariableResolver — var.name not found returns unresolved
    }

    @Test
    void expressionParams_resolvedViaExpressionEngine() {
        var services = new MapServiceRegistry();
        services.register(ExpressionEngineRegistry.class, mockRegistry());
        Map<String, Object> data = Map.of("output", Map.of("risk", "high"));
        var resolver = new VariableResolver(Map.of(), Set.of())
                .withObjectScope("results", data);
        var paramResolver = new TypeAwareParamResolver(resolver, services);

        Map<String, Parameter> inputs = Map.of("_subject", new Parameter(ParameterType.EXPRESSION, true, null, null, null, null));
        Map<String, Object> result = paramResolver.resolve(Map.of("_subject", "results.output.risk"), inputs);
        assertEquals("high", result.get("_subject"));
    }

    @Test
    void expressionParams_stripsDollarBraces() {
        var services = new MapServiceRegistry();
        services.register(ExpressionEngineRegistry.class, mockRegistry());
        Map<String, Object> data = Map.of("output", Map.of("risk", "high"));
        var resolver = new VariableResolver(Map.of(), Set.of())
                .withObjectScope("results", data);
        var paramResolver = new TypeAwareParamResolver(resolver, services);

        Map<String, Parameter> inputs = Map.of("_subject", new Parameter(ParameterType.EXPRESSION, true, null, null, null, null));
        Map<String, Object> result = paramResolver.resolve(Map.of("_subject", "${results.output.risk}"), inputs);
        assertEquals("high", result.get("_subject"));
    }

    @Test
    void expressionParams_nullValue_returnsNull() {
        var services = new MapServiceRegistry();
        services.register(ExpressionEngineRegistry.class, mockRegistry());
        var resolver = new VariableResolver(Map.of(), Set.of());
        var paramResolver = new TypeAwareParamResolver(resolver, services);

        Map<String, Parameter> inputs = Map.of("_subject", new Parameter(ParameterType.EXPRESSION, true, null, null, null, null));
        Map<String, Object> rawParams = new LinkedHashMap<>();
        rawParams.put("_subject", null);
        Map<String, Object> result = paramResolver.resolve(rawParams, inputs);
        assertNull(result.get("_subject"));
    }

    @Test
    void expressionParams_nonString_passthrough() {
        var services = new MapServiceRegistry();
        services.register(ExpressionEngineRegistry.class, mockRegistry());
        var resolver = new VariableResolver(Map.of(), Set.of());
        var paramResolver = new TypeAwareParamResolver(resolver, services);

        Map<String, Parameter> inputs = Map.of("_subject", new Parameter(ParameterType.EXPRESSION, true, null, null, null, null));
        Map<String, Object> result = paramResolver.resolve(Map.of("_subject", 42), inputs);
        assertEquals(42, result.get("_subject"));
    }

    @Test
    void missingExpressionEngineRegistry_throwsIllegalState() {
        var services = new MapServiceRegistry();
        var resolver = new VariableResolver(Map.of(), Set.of());
        var paramResolver = new TypeAwareParamResolver(resolver, services);

        Map<String, Parameter> inputs = Map.of("_subject", new Parameter(ParameterType.EXPRESSION, true, null, null, null, null));
        assertThrows(IllegalStateException.class,
                () -> paramResolver.resolve(Map.of("_subject", "expr"), inputs));
    }

    @Test
    void undeclaredParams_defaultToStringResolution() {
        var services = new MapServiceRegistry();
        services.register(ExpressionEngineRegistry.class, mockRegistry());
        var resolver = new VariableResolver(Map.of("var", name -> "world"), Set.of());
        var paramResolver = new TypeAwareParamResolver(resolver, services);

        Map<String, Parameter> inputs = Map.of(); // empty — all undeclared
        Map<String, Object> result = paramResolver.resolve(Map.of("msg", "${var.greeting}"), inputs);
        // Undeclared params go through VariableResolver
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn test -pl yaml-step-runtime -Dtest=TypeAwareParamResolverTest -Dsurefire.failIfNoSpecifiedTests=false --batch-mode`
Expected: Compilation error — `TypeAwareParamResolver` not defined

- [ ] **Step 3: Implement TypeAwareParamResolver**

Create `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/TypeAwareParamResolver.java`:

```java
package io.casehub.yaml.step.eval;

import io.casehub.platform.api.expression.ExpressionContext;
import io.casehub.platform.api.expression.ExpressionEngineRegistry;
import io.casehub.yaml.core.resolver.VariableResolver;
import io.casehub.yaml.plugin.api.Parameter;
import io.casehub.yaml.plugin.api.ParameterType;
import io.casehub.yaml.plugin.api.ServiceRegistry;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;

public class TypeAwareParamResolver {

    private final VariableResolver resolver;
    private final ServiceRegistry services;

    public TypeAwareParamResolver(VariableResolver resolver, ServiceRegistry services) {
        this.resolver = Objects.requireNonNull(resolver);
        this.services = Objects.requireNonNull(services);
    }

    public Map<String, Object> resolve(
            Map<String, Object> rawParams,
            Map<String, Parameter> declaredInputs) {

        Map<String, Object> resolved = new LinkedHashMap<>();
        Map<String, Object> stringParams = new LinkedHashMap<>();

        for (var entry : rawParams.entrySet()) {
            Parameter declared = declaredInputs.get(entry.getKey());
            if (declared != null && declared.type() == ParameterType.EXPRESSION) {
                Object value = resolveExpression(entry.getValue());
                resolved.put(entry.getKey(), value);
            } else {
                stringParams.put(entry.getKey(), entry.getValue());
            }
        }

        Map<String, Object> stringResolved = resolver.resolveMap(stringParams, "step");
        resolved.putAll(stringResolved);

        return resolved;
    }

    private Object resolveExpression(Object rawValue) {
        if (rawValue == null) return null;
        if (!(rawValue instanceof String expr)) return rawValue;

        if (expr.startsWith("${") && expr.endsWith("}")
                && expr.indexOf('}') == expr.length() - 1) {
            expr = expr.substring(2, expr.length() - 1);
        }

        ExpressionEngineRegistry engines = lookupEngines();
        String engineType = engines.resolveDefault(ExpressionContext.PARAMETER);
        if (engineType == null) {
            throw new IllegalStateException(
                "No default expression engine registered for ExpressionContext.PARAMETER. "
                + "Call registry.registerDefault(ExpressionContext.PARAMETER, \"mvel\") "
                + "at application startup.");
        }

        Map<String, Object> context = resolver.buildExpressionContext();
        var compiled = engines.compile(engineType, expr, Map.class, Object.class);
        return compiled.eval(context);
    }

    private ExpressionEngineRegistry lookupEngines() {
        try {
            return services.lookup(ExpressionEngineRegistry.class);
        } catch (IllegalArgumentException e) {
            throw new IllegalStateException(
                "EXPRESSION parameters require ExpressionEngineRegistry in ServiceRegistry", e);
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn test -pl yaml-step-runtime -Dtest=TypeAwareParamResolverTest --batch-mode`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/TypeAwareParamResolver.java yaml-step-runtime/src/test/java/io/casehub/yaml/step/eval/TypeAwareParamResolverTest.java
git commit -m "feat(#699): TypeAwareParamResolver — routes EXPRESSION params to ExpressionEngine"
```

---

### Task 5: CatalogStepRunner wiring + AptPluginSource format-aware parsing

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/CatalogStepRunner.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/AptPluginSource.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/AptPluginSourceTest.java`

**Interfaces:**
- Consumes: `TypeAwareParamResolver.resolve()` (Task 4), `ParameterType.EXPRESSION` (Task 1)
- Produces: CatalogStepRunner now type-aware (used by Task 7 end-to-end tests)

- [ ] **Step 1: Write failing test for AptPluginSource format-aware parsing**

Add to `AptPluginSourceTest.java`:

```java
@Test
void loadManifest_expressionFormat_mapsToExpressionType() throws Exception {
    var source = new AptPluginSource(new com.fasterxml.jackson.databind.ObjectMapper());
    String manifest = "{\"actionClass\": \"io.casehub.yaml.step.catalog.AptPluginSourceTest$StubAction\"}";
    String schema = """
            {
              "type": "object",
              "properties": {
                "subject": { "type": "string", "format": "expression" },
                "message": { "type": "string" }
              }
            }
            """;
    var definition = source.loadManifest("test",
            new java.io.ByteArrayInputStream(manifest.getBytes()),
            new java.io.ByteArrayInputStream(schema.getBytes()));
    assertEquals(io.casehub.yaml.plugin.api.ParameterType.EXPRESSION,
            definition.inputs().get("subject").type());
    assertEquals(io.casehub.yaml.plugin.api.ParameterType.STRING,
            definition.inputs().get("message").type());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn test -pl yaml-step-runtime -Dtest=AptPluginSourceTest#loadManifest_expressionFormat_mapsToExpressionType --batch-mode`
Expected: FAIL — `subject` maps to STRING, not EXPRESSION

- [ ] **Step 3: Update AptPluginSource to check format before type**

In `AptPluginSource.loadManifest()`, replace the property parsing loop (lines 123-129):

```java
for (Map.Entry<String, Object> prop : properties.entrySet()) {
    Map<String, Object> propSchema = (Map<String, Object>) prop.getValue();
    String typeStr = (String) propSchema.getOrDefault("type", "string");
    String formatStr = (String) propSchema.get("format");
    ParameterType paramType = "expression".equals(formatStr)
            ? ParameterType.EXPRESSION
            : ParameterType.fromString(typeStr);
    builder.input(prop.getKey(), new Parameter(
            paramType, false, null, null, null,
            (String) propSchema.get("description")));
}
```

- [ ] **Step 4: Update CatalogStepRunner to use TypeAwareParamResolver**

Replace the `run()` method in `CatalogStepRunner.java`:

```java
@Override
public Result run(ResolvedStep step, VariableResolver resolver) {
    if (step instanceof ResolvedStep.PluginStep ps) {
        var definition = registry.resolve(ps.actionName())
                .orElseThrow(() -> new IllegalArgumentException(
                        "No action registered for '" + ps.actionName() + "'"));

        Map<String, Object> resolved;
        if (hasExpressionParams(definition)) {
            var paramResolver = new TypeAwareParamResolver(resolver, services);
            resolved = paramResolver.resolve(ps.params(), definition.inputs());
        } else {
            resolved = resolver.resolveMap(ps.params(), "step");
        }
        return definition.action().execute(resolved, services);
    }
    throw new IllegalArgumentException(
            "Unsupported step type: " + step.getClass().getSimpleName());
}

private static boolean hasExpressionParams(io.casehub.yaml.plugin.api.Definition definition) {
    return definition.inputs().values().stream()
            .anyMatch(p -> p.type() == ParameterType.EXPRESSION);
}
```

Add the import:
```java
import io.casehub.yaml.plugin.api.ParameterType;
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn test -pl yaml-step-runtime -Dtest=AptPluginSourceTest --batch-mode`
Expected: All PASS

- [ ] **Step 6: Run all yaml-step-runtime tests for regression**

Run: `mvn test -pl yaml-step-runtime --batch-mode`
Expected: All PASS (existing plugins have no EXPRESSION params — `hasExpressionParams()` returns false, unchanged path)

- [ ] **Step 7: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/CatalogStepRunner.java yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/AptPluginSource.java yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/AptPluginSourceTest.java
git commit -m "feat(#699): CatalogStepRunner type-aware wiring + AptPluginSource format-aware parsing"
```

---

## Batch 3: Processor + consumer cleanup

### Task 6: yaml-plugin-processor @Expression support

**Files:**
- Modify: `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/SchemaEmitter.java`
- Modify: `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/BinderEmitter.java`
- Modify: `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/StepPluginProcessor.java` (if needed for @Expression detection)
- Test: `yaml-plugin-processor/src/test/java/io/casehub/yaml/plugin/processor/StepPluginProcessorTest.java`

**Interfaces:**
- Consumes: `@Expression` annotation (Task 1), `ParameterType.EXPRESSION` (Task 1)
- Produces: Generated JSON Schema with `"format": "expression"`, generated Action class with uncast `Object` extraction for `@Expression` fields

- [ ] **Step 1: Write failing test for @Expression in plugin processor**

Add a test plugin record to `yaml-plugin-processor/src/test/resources/test-plugins/ExpressionPlugin.java`:

```java
package test.plugins;

import io.casehub.yaml.plugin.api.Plugin;
import io.casehub.yaml.plugin.api.Execute;
import io.casehub.yaml.plugin.api.Required;
import io.casehub.yaml.plugin.api.Expression;
import io.casehub.yaml.plugin.api.Result;

@Plugin("expression-test")
public record ExpressionPlugin(
        @Required @Expression Object subject,
        String message
) {
    @Execute
    public Result run() {
        return Result.of(java.util.Map.of("evaluated", subject));
    }
}
```

Add test to `StepPluginProcessorTest.java`:

```java
@Test
void expressionField_generatesFormatInSchema() throws Exception {
    // Compile ExpressionPlugin and verify schema has format: expression
    // and binder extracts without cast
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn test -pl yaml-plugin-processor -Dtest=StepPluginProcessorTest --batch-mode`
Expected: FAIL — @Expression not recognized by processor

- [ ] **Step 3: Update SchemaEmitter for @Expression**

In `SchemaEmitter.emit()`, update the property loop to check for `@Expression`:

```java
RecordComponentElement field = fields.get(i);
String yamlKey = BinderEmitter.toKebabCase(field.getSimpleName().toString());
boolean isExpression = field.getAnnotation(io.casehub.yaml.plugin.api.Expression.class) != null;
if (isExpression) {
    w.print("    \"" + yamlKey + "\": { \"type\": \"string\", \"format\": \"expression\" }");
} else {
    String jsonType = toJsonType(field.asType().toString());
    w.print("    \"" + yamlKey + "\": { \"type\": \"" + jsonType + "\" }");
}
```

- [ ] **Step 4: Update BinderEmitter for @Expression**

Update `paramExtraction()` to accept an `isExpression` flag:

```java
static String paramExtraction(String type, String fieldName, boolean isExpression) {
    if (isExpression) {
        return "parameters.get(\"" + fieldName + "\")";
    }
    return switch (type) {
        case "int" -> "((Number) parameters.getOrDefault(\"" + fieldName + "\", 0)).intValue()";
        case "long" -> "((Number) parameters.getOrDefault(\"" + fieldName + "\", 0L)).longValue()";
        case "double" -> "((Number) parameters.getOrDefault(\"" + fieldName + "\", 0.0)).doubleValue()";
        case "boolean" -> "(Boolean) parameters.getOrDefault(\"" + fieldName + "\", false)";
        case "java.lang.String" -> "(String) parameters.get(\"" + fieldName + "\")";
        default -> "(" + type + ") parameters.get(\"" + fieldName + "\")";
    };
}
```

Keep the old 2-arg overload for backward compatibility:

```java
static String paramExtraction(String type, String fieldName) {
    return paramExtraction(type, fieldName, false);
}
```

Update `emit()` to pass the `@Expression` check:

```java
boolean isExpression = field.getAnnotation(io.casehub.yaml.plugin.api.Expression.class) != null;
w.print(paramExtraction(type, yamlKey, isExpression));
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn test -pl yaml-plugin-processor --batch-mode`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/SchemaEmitter.java yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/BinderEmitter.java yaml-plugin-processor/src/test/resources/test-plugins/ExpressionPlugin.java yaml-plugin-processor/src/test/java/io/casehub/yaml/plugin/processor/StepPluginProcessorTest.java
git commit -m "feat(#699): plugin processor @Expression support — schema format + uncast Object extraction"
```

---

### Task 7: StructuralStepEvaluator scope migration + AssertThatPlugin cleanup

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/AssertThatPlugin.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/plugin/AssertThatPluginTest.java`

**Interfaces:**
- Consumes: `VariableResolver.withExpressionContext()` (Task 2), `StepResultStore.liveResults()` (Task 3), `ParameterType.EXPRESSION` (Task 1), `TypeAwareParamResolver` (Task 4)
- Produces: End-to-end working EXPRESSION resolution through the full pipeline

- [ ] **Step 1: Write failing test for AssertThatPlugin with terse expression syntax**

Add to `AssertThatPluginTest.java`:

```java
@Test
void assertThat_terseExpression_withoutDollarBraces() {
    // This test verifies the full pipeline: Walker → CatalogStepRunner → TypeAwareParamResolver → AssertThatPlugin
    // Setup: register ExpressionEngineRegistry, create resolver with result scope, run assertThat with bare expression
    var services = new MapServiceRegistry();
    var engines = new io.casehub.platform.api.expression.DefaultExpressionEngineRegistry();
    engines.register(new io.casehub.platform.expression.MvelExpressionEngine());
    engines.registerDefault(io.casehub.platform.api.expression.ExpressionContext.PARAMETER, "mvel");
    services.register(io.casehub.platform.api.expression.ExpressionEngineRegistry.class, engines);

    Map<String, Object> resultData = Map.of("output", Map.of("risk", "equities"));
    var resolver = new VariableResolver(Map.of(), Set.of())
            .withObjectScope("results", resultData);

    var definition = AssertThatPlugin.definition();
    var runner = new CatalogStepRunner(/* registry with assertThat */, services);
    var step = new ResolvedStep.PluginStep(null, "assertThat",
            Map.of("_subject", "results.output.risk", "equals", "equities"), Map.of());

    Result result = runner.run(step, resolver);
    assertTrue(result.isSuccess());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn test -pl yaml-step-runtime -Dtest=AssertThatPluginTest --batch-mode`
Expected: FAIL — AssertThatPlugin.definition() doesn't declare `_subject` as EXPRESSION, and CatalogStepRunner doesn't route to TypeAwareParamResolver

- [ ] **Step 3: Update AssertThatPlugin.definition() to declare _subject as EXPRESSION**

In `AssertThatPlugin.java`, update the `definition()` method:

```java
public static Definition definition() {
    return Definition.of("assertThat")
            .description("Behavioural assertion with matchers")
            .input("_subject", ParameterType.EXPRESSION, true)
            .absorbSiblings(true)
            .execute(new AssertThatPlugin())
            .build();
}
```

Add import: `import io.casehub.yaml.plugin.api.ParameterType;`

- [ ] **Step 4: Remove resolveSubject() from AssertThatPlugin**

Delete the `resolveSubject()` method (lines 61-93) entirely.

Update `execute()` — replace `resolveSubject(rawSubject, services)` with direct use:

```java
@Override
public Result execute(Map<String, Object> params, ServiceRegistry services) {
    Object subject = params.get("_subject");
    String message = params.get("message") != null ? String.valueOf(params.get("message")) : null;
    // ... rest unchanged
}
```

Remove unused imports: `ExpressionContext`, `ExpressionEngineRegistry`.

- [ ] **Step 5: Update StructuralStepEvaluator.withResultScope() for dual registration**

In `StructuralStepEvaluator.java`, update `withResultScope()`:

```java
private VariableResolver withResultScope(VariableResolver resolver) {
    if (resultSource == null) return resolver;
    resolver = resolver.withObjectScope("result", resultSource);
    if (scope != null) {
        resolver = resolver.withExpressionContext("result", scope.resultStore().liveResults());
    }
    return resolver;
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn test -pl yaml-step-runtime -Dtest=AssertThatPluginTest --batch-mode`
Expected: All PASS

- [ ] **Step 7: Run full yaml-step-runtime test suite for regression**

Run: `mvn test -pl yaml-step-runtime --batch-mode`
Expected: All PASS

- [ ] **Step 8: Run full project build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 9: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/AssertThatPlugin.java yaml-step-runtime/src/test/java/io/casehub/yaml/step/plugin/AssertThatPluginTest.java
git commit -m "feat(#699): result scope dual-registration + AssertThatPlugin cleanup — terse expression syntax works end-to-end"
```

---

## References

- [2026-11-03-type-safe-expression-resolution-design.md] — design spec this plan implements
- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/ParameterType.java` — type enum to extend
- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Parameter.java` — param record
- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Definition.java` — plugin definition
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java` — resolution pipeline
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/StepResultStore.java` — result store interface
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultStepResultStore.java` — ConcurrentHashMap impl
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/CatalogStepRunner.java` — execution path
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/StructuralStepEvaluator.java:670-721` — result scope setup
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/AptPluginSource.java:119-131` — schema property parsing
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/AssertThatPlugin.java:61-93` — manual expression resolution to delete
- `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/SchemaEmitter.java` — JSON Schema generation
- `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/BinderEmitter.java:86-95` — param extraction
- `platform-api/src/main/java/io/casehub/platform/api/expression/ExpressionContext.java` — engine contexts
- `expression-core/src/main/java/io/casehub/platform/expression/MvelExpressionEngine.java:25` — MVEL.getTypeMap iteration
- GitHub #699 — focal issue
- GitHub #683 — declarative playbook testing (first consumer)
