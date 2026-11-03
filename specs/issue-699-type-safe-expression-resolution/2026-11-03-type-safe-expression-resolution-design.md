# Type-Safe Expression Resolution — Design Spec

**Issue:** casehubio/platform#699
**Branch:** issue-699-type-safe-expression-resolution
**Date:** 2026-11-03

## Problem

Every variable reference in YAML playbooks requires `${...}` wrapping — even when the schema declares the field as an expression type. The parser knows `assertThat:` takes an expression, but the author still writes `${results.output.risk}` instead of `results.output.risk`. The `${}` is telling the parser what it already knows.

Additionally, plugins that consume expression-typed parameters must manually strip `${...}`, look up the ExpressionEngineRegistry from ServiceRegistry, compile, and evaluate — boilerplate that belongs in the resolution layer. AssertThatPlugin.resolveSubject() (lines 61-93) is the canonical example.

```yaml
# Before
- assertThat: ${results.output.risk_assessment}
  contains: 'equities'

# After
- assertThat: results.output.risk_assessment
  contains: 'equities'
```

## Architecture

The change introduces type-aware parameter resolution at the boundary between step parsing and plugin execution. Currently, CatalogStepRunner calls `resolver.resolveMap(ps.params(), "step")` for ALL parameters regardless of their declared type — the Definition.inputs() type information is completely unused during resolution.

After this change, a new TypeAwareParamResolver routes parameters by their declared type:

- **STRING, INTEGER, NUMBER, BOOLEAN, ARRAY, OBJECT** → `VariableResolver` string-template expansion (existing path)
- **EXPRESSION** → `ExpressionEngine.compile().eval()` with expression context built from VariableResolver's scopes

```
                    ┌──────────────────────┐
                    │   Walker.resolve()   │ YAML → ResolvedStep (raw params)
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │ StructuralStep       │ decorators, structural dispatch
                    │ Evaluator            │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │ CatalogStepRunner    │
                    │                      │ looks up Definition
                    │ ┌──────────────────┐ │
                    │ │TypeAwareParam    │ │ routes by ParameterType
                    │ │Resolver          │ │
                    │ │                  │ │
                    │ │ STRING → VarRes  │ │
                    │ │ EXPR → ExprEng  │ │
                    │ └──────────────────┘ │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │ Plugin.execute()     │ receives fully-resolved params
                    └──────────────────────┘
```

### Key design principles

1. **Clean separation:** EXPRESSION params always go to ExpressionEngine, never VariableResolver. STRING params always go to VariableResolver, never ExpressionEngine. No ambiguity about which path produced the result.

2. **Single source of truth for context:** The expression context is exported from VariableResolver via `buildExpressionContext()`. The same data available as `${var.name}` in STRING params becomes `var.name` in EXPRESSION params.

3. **Backward compatibility:** Existing `${...}` syntax is accepted in EXPRESSION fields — the wrapper is stripped before expression evaluation. No migration required.

4. **Fail fast:** If EXPRESSION params exist but ExpressionEngineRegistry is not in ServiceRegistry, throw IllegalStateException with clear guidance.

## Module Changes

### 1. yaml-plugin-api (zero-dep, J2CL-safe)

**ParameterType.EXPRESSION variant:**

```java
public enum ParameterType {
    STRING, INTEGER, NUMBER, BOOLEAN, ARRAY, OBJECT, EXPRESSION;

    public boolean isScalar() {
        return this != ARRAY && this != OBJECT;
    }

    public boolean validate(Object value) {
        return switch (this) {
            // ... existing cases ...
            case EXPRESSION -> value instanceof String || value != null;
        };
    }

    public Object parseScalar(String value) {
        return switch (this) {
            // ... existing cases ...
            case EXPRESSION -> value;
        };
    }

    public boolean canAccept(ParameterType outputType) {
        if (this == outputType) return true;
        if (this == STRING && outputType.isScalar()) return true;
        if (this == NUMBER && outputType == INTEGER) return true;
        if (this == EXPRESSION && outputType == STRING) return true;
        return false;
    }
}
```

**@Expression annotation:**

```java
package io.casehub.yaml.plugin.api;

@Target(ElementType.FIELD)
@Retention(RetentionPolicy.RUNTIME)
public @interface Expression {}
```

Used on `@Plugin` record fields to mark them as EXPRESSION-typed. The Java type stays `String` — the annotation drives schema generation and type-aware resolution.

### 2. yaml-core (zero-dep, J2CL-safe)

**VariableResolver — map-backed scope overload + context export:**

New `withObjectScope(String, Map)` overload stores the backing map alongside the ObjectVariableSource:

```java
private final Map<String, Object> scopeContainers; // prefix → backing Map or object

public VariableResolver withObjectScope(String prefix, Map<String, Object> map) {
    var newObjectSources = new LinkedHashMap<>(objectPrefixSources);
    newObjectSources.put(prefix, map::get);
    var newContainers = new LinkedHashMap<>(scopeContainers);
    newContainers.put(prefix, map);
    return new VariableResolver(prefixSources, Map.copyOf(newObjectSources),
            deferredPrefixes, deferredPrefixHandler, Map.copyOf(newContainers));
}
```

`buildExpressionContext()` returns the stored containers — concrete maps that expression engines (MVEL, JQ) can iterate for type introspection:

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

Callers migrate from `withObjectScope("results", capturedOutput::get)` to `withObjectScope("results", capturedOutput)` to enable expression resolution for that scope. The existing `withObjectScope(String, ObjectVariableSource)` overload continues to work but those scopes are not available in expression context (MVEL needs iterable maps for type introspection at compile time).

**Why not lazy proxy maps:** MVEL calls `MVEL.getTypeMap(evalContext)` at compile time, which iterates the context map to determine types. An `AbstractMap` with empty `entrySet()` would cause MVEL compilation to fail for any expression referencing that scope. Concrete maps solve this.

### 3. platform-api

**ExpressionContext.EXPRESSION:**

```java
public enum ExpressionContext {
    CONDITION, TRANSFORM, FILTER, EXPRESSION
}
```

Used as the default engine context for plugin EXPRESSION params. ExpressionEngineRegistry consumers register a default engine for this context.

### 4. yaml-step-runtime

**TypeAwareParamResolver (new class):**

```java
package io.casehub.yaml.step.eval;

public class TypeAwareParamResolver {

    private final VariableResolver resolver;
    private final ServiceRegistry services;

    public TypeAwareParamResolver(VariableResolver resolver, ServiceRegistry services) {
        this.resolver = resolver;
        this.services = services;
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

        // Resolve non-EXPRESSION params via VariableResolver
        Map<String, Object> stringResolved = resolver.resolveMap(stringParams, "step");
        resolved.putAll(stringResolved);

        return resolved;
    }

    private Object resolveExpression(Object rawValue) {
        if (rawValue == null) return null;
        if (!(rawValue instanceof String expr)) return rawValue;

        // Strip ${...} wrapper if present (backward compat)
        if (expr.startsWith("${") && expr.endsWith("}")
                && expr.indexOf('}') == expr.length() - 1) {
            expr = expr.substring(2, expr.length() - 1);
        }

        ExpressionEngineRegistry engines = lookupEngines();
        String engineType = engines.resolveDefault(ExpressionContext.EXPRESSION);
        if (engineType == null) {
            throw new IllegalStateException(
                "No default expression engine registered for ExpressionContext.EXPRESSION");
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

**CatalogStepRunner changes:**

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

private static boolean hasExpressionParams(Definition definition) {
    return definition.inputs().values().stream()
            .anyMatch(p -> p.type() == ParameterType.EXPRESSION);
}
```

The `hasExpressionParams()` check avoids creating TypeAwareParamResolver for definitions that don't use EXPRESSION — zero overhead for existing plugins.

### 5. yaml-plugin-processor

**StepPluginProcessor changes:**
- Scan record fields for `@Expression` annotation
- Map `@Expression` fields to `ParameterType.EXPRESSION` in generated Definition and schema

**SchemaEmitter changes:**
- EXPRESSION fields emit `"type": "string", "format": "expression"` in JSON Schema

### 6. yaml-codegen

- EXPRESSION type in JSON Schema (`"format": "expression"`) generates as `String` in Java records/POJOs
- No functional change to generated code — the expression evaluation happens at runtime

### 7. Consumer cleanup — AssertThatPlugin

**Before:**
```java
public static Definition definition() {
    return Definition.of("assertThat")
            .description("Behavioural assertion with matchers")
            .absorbSiblings(true)
            .execute(new AssertThatPlugin())
            .build();
}

// 30+ lines of manual expression resolution in resolveSubject()
```

**After:**
```java
public static Definition definition() {
    return Definition.of("assertThat")
            .description("Behavioural assertion with matchers")
            .input("_subject", ParameterType.EXPRESSION, true)
            .absorbSiblings(true)
            .execute(new AssertThatPlugin())
            .build();
}

// resolveSubject() deleted — _subject arrives already evaluated
```

## Scope Boundaries

### In scope (this issue — platform only)
- `ParameterType.EXPRESSION` in yaml-plugin-api
- `@Expression` annotation in yaml-plugin-api
- `VariableResolver.withObjectScope(String, Map)` overload + `buildExpressionContext()` in yaml-core
- `ExpressionContext.EXPRESSION` in platform-api
- `TypeAwareParamResolver` in yaml-step-runtime
- `CatalogStepRunner` wiring change in yaml-step-runtime
- Plugin processor updates in yaml-plugin-processor
- `AssertThatPlugin` cleanup in yaml-step-runtime
- Tests for all of the above

### Out of scope (follow-up issues)
- Consumer repo migration (engine, ops, helpdesk playbooks) — audit and migrate to terse expression form
- `when:` decorator condition unification via TypeAwareParamResolver
- yaml-codegen `"format": "expression"` handling
- TypeScript Walker parity in drafthouse
- Work-slot for cross-repo propagation

## Error Handling

| Scenario | Behavior |
|----------|----------|
| EXPRESSION param, no ExpressionEngineRegistry | IllegalStateException: "EXPRESSION parameters require ExpressionEngineRegistry in ServiceRegistry" |
| EXPRESSION param, no default engine for EXPRESSION context | IllegalStateException: "No default expression engine registered for ExpressionContext.EXPRESSION" |
| Expression compilation fails | ExpressionCompilationException propagates — plugin.execute() never called |
| Expression evaluation fails | ExpressionEvaluationException propagates |
| EXPRESSION param with null value | Returns null (no expression evaluation) |
| EXPRESSION param with non-String value | Returns the value as-is (already evaluated, e.g., from YAML native types) |
| `${...}` in EXPRESSION field | Stripped, inner string evaluated as expression |

## Testing Strategy

1. **TypeAwareParamResolver unit tests:**
   - STRING params resolve via VariableResolver
   - EXPRESSION params resolve via ExpressionEngine
   - Mixed params in one step
   - `${...}` stripping in EXPRESSION fields
   - Null and non-String EXPRESSION values
   - Missing ExpressionEngineRegistry → IllegalStateException
   - Undeclared params default to STRING resolution

2. **CatalogStepRunner integration tests:**
   - Plugin with EXPRESSION input receives evaluated value
   - Plugin without EXPRESSION inputs — unchanged behavior
   - End-to-end with AssertThatPlugin (terse syntax)

3. **VariableResolver.buildExpressionContext() tests:**
   - Map-backed scopes (via `withObjectScope(String, Map)`) included in expression context
   - Functional ObjectVariableSource scopes (via `withObjectScope(String, ObjectVariableSource)`) NOT in expression context
   - Deferred prefixes excluded
   - Context updates when resolver scopes change (withObjectScope(String, Map) adds container)

4. **Plugin processor tests:**
   - @Expression annotation → ParameterType.EXPRESSION in generated Definition
   - JSON Schema includes `"format": "expression"`

5. **AssertThatPlugin regression tests:**
   - Existing tests continue to pass with ${...} syntax
   - New tests with terse expression syntax

## References

- `yaml-plugin-api/ParameterType.java` — type enum to extend
- `yaml-plugin-api/Parameter.java` — param record (type field)
- `yaml-plugin-api/Definition.java` — plugin definition with inputs map
- `yaml-plugin-api/Plugin.java` — @Plugin annotation
- `yaml-core/VariableResolver.java` — resolution pipeline, scopes
- `yaml-step-runtime/Walker.java` — step parsing, _subject at line 176
- `yaml-step-runtime/CatalogStepRunner.java` — execution path, resolution at line 28
- `yaml-step-runtime/StructuralStepEvaluator.java` — orchestration layer
- `yaml-step-runtime/AssertThatPlugin.java` — manual expression resolution (lines 61-93)
- `yaml-plugin-processor/SchemaEmitter.java` — JSON Schema generation
- `yaml-plugin-processor/StepPluginProcessor.java` — @Plugin annotation processing
- `platform-api/ExpressionContext.java` — expression engine contexts
- `platform-api/ExpressionEngineRegistry.java` — engine registry SPI
- casehubio/platform#683 — declarative playbook testing (first consumer)
