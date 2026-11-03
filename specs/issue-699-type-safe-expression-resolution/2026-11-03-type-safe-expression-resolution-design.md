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
- **EXPRESSION** → `ExpressionEngine.compile().eval()` with expression context built from VariableResolver's Map-backed scopes

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
            case EXPRESSION -> true; // any value accepted — resolution handles null and non-String
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

@Target({ElementType.RECORD_COMPONENT, ElementType.FIELD, ElementType.PARAMETER})
@Retention(RetentionPolicy.RUNTIME)
public @interface Expression {}
```

Targets match `@Required` — `RECORD_COMPONENT` is required for annotation processing (`RecordComponentElement.getAnnotation(Expression.class)` returns null without it per JLS §9.6.4.1). `PARAMETER` is included for consistency with `@Required`.

Used on `@Plugin` record fields to mark them as EXPRESSION-typed. The Java type must be `Object` — MVEL evaluation returns typed results (Map, List, Number, String, etc.), not always String. The annotation drives schema generation and type-aware resolution.

**ParameterType.fromString() update:**

```java
public static ParameterType fromString(String name) {
    return switch (name.toUpperCase(Locale.ROOT)) {
        // ... existing cases ...
        case "EXPRESSION" -> EXPRESSION;
        default -> throw new IllegalArgumentException(
                "Unknown parameter type '" + name + "'");
    };
}
```

### 2. yaml-core (zero-dep, J2CL-safe)

**VariableResolver — map-backed scope overload + context export:**

New field and constructor parameter:

```java
private final Map<String, Object> scopeContainers; // prefix → backing Map or object
```

The existing 4-parameter private constructor is replaced by a 5-parameter constructor. All internal factory methods (`withScope()`, `withDeferredPrefixHandler()`, `withChainedScope()`, `withObjectScope(String, ObjectVariableSource)`) forward `this.scopeContainers`:

```java
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

The public 2-parameter constructor initialises `scopeContainers` to `Map.of()`. Every method that returns a new VariableResolver (`withScope()`, `withDeferredPrefixHandler()`, `withChainedScope()`, `withObjectScope(String, ObjectVariableSource)`) passes `this.scopeContainers` to the new constructor. This ensures scopeContainers is never silently lost.

New `withObjectScope(String, Map)` overload stores the backing map alongside the ObjectVariableSource:

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

`buildExpressionContext()` returns the stored containers — concrete maps that expression engines (MVEL) can iterate for type introspection:

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

**Scope visibility and migration:** Only Map-backed scopes (registered via `withObjectScope(String, Map)`) appear in the expression context. Scopes registered via `withObjectScope(String, ObjectVariableSource)` are NOT visible to expression evaluation. This is intentional — `MvelExpressionEngine.compileMapEvaluator()` calls `MVEL.getTypeMap(evalContext)` on the first `eval()`, which iterates the context map's `entrySet()` to infer types for compilation. An `AbstractMap` with empty `entrySet()` produces an empty type map, causing MVEL to fail to resolve identifiers declared via that scope.

Callers migrate from `withObjectScope("results", capturedOutput::get)` to `withObjectScope("results", capturedOutput)` to enable expression resolution for that scope. Migration of scope registrations in StructuralStepEvaluator (`result` scope) and ScopeUtils (`match`, `signal`, `from`, `each`) is required before EXPRESSION params can reference those scopes. See "Scope migration" below for what is in scope for this work.

**`withExpressionContext()` — expression-only scope registration:**

```java
public VariableResolver withExpressionContext(String prefix, Map<String, Object> map) {
    var newContainers = new LinkedHashMap<>(scopeContainers);
    newContainers.put(prefix, map);
    return new VariableResolver(prefixSources, objectPrefixSources,
            deferredPrefixes, deferredPrefixHandler, Map.copyOf(newContainers));
}
```

This stores ONLY in `scopeContainers` without touching `objectPrefixSources`. Use when a scope needs both a functional ObjectVariableSource (for STRING resolution with error wrapping) and a concrete Map (for EXPRESSION resolution via MVEL).

**Scope migration (in scope for this issue):**

The `result` scope in `StructuralStepEvaluator.withResultScope()` currently uses a functional `ObjectVariableSource` built from `StepResultStore`. This scope is the primary target for EXPRESSION params (e.g., `result.someStep.output`). The migration registers BOTH a functional source and a live concrete Map:

```java
private VariableResolver withResultScope(VariableResolver resolver) {
    if (resultSource == null) return resolver;
    // Functional source for STRING params (live, with error wrapping)
    resolver = resolver.withObjectScope("result", resultSource);
    // Live ConcurrentHashMap for EXPRESSION params (concrete, MVEL-compatible)
    resolver = resolver.withExpressionContext("result", scope.resultStore().liveResults());
    return resolver;
}
```

**`StepResultStore.liveResults()`** returns the backing `ConcurrentHashMap<String, Map<String, Object>>` from `DefaultStepResultStore`. This map is:
- **Concrete** — `ConcurrentHashMap` implements `Map` with a real `entrySet()`, satisfying MVEL's `getTypeMap()` requirement
- **Live** — `recordSuccess()` calls `results.put(stepName, result)`, so new step completions are immediately visible to subsequent EXPRESSION evaluations within the same block

```java
// StepResultStore interface
Map<String, Object> liveResults();

// DefaultStepResultStore implementation
@Override
public Map<String, Object> liveResults() {
    return results; // the ConcurrentHashMap<String, Map<String, Object>> field
}
```

**Two paths, one prefix:** With this design, the `result` prefix has:
- `objectPrefixSources["result"]` → `buildResultSource(store)` — used by VariableResolver for `${result.stepName.output}` STRING resolution, includes error compositing
- `scopeContainers["result"]` → `store.liveResults()` — used by `buildExpressionContext()` for MVEL evaluation, raw output maps only

Failed steps that have no output do NOT appear in `liveResults()` (only `recordSuccess()` writes to the results map). This is correct for EXPRESSION params — there is no output to evaluate. Error information remains available through `${result.stepName.error.message}` via the functional ObjectVariableSource path.

Other scope migrations (`each`, `match`, `signal`, `from`, `error`, domain variables) are follow-up — see out-of-scope items. EXPRESSION params that reference those scopes will throw `ExpressionCompilationException` until their registrations are migrated.

### 3. platform-api

**ExpressionContext.PARAMETER:**

```java
public enum ExpressionContext {
    CONDITION, TRANSFORM, FILTER, PARAMETER
}
```

`PARAMETER` describes the purpose: resolving a plugin parameter value via an expression engine. Each `ExpressionContext` member names the *purpose* of evaluation — `CONDITION` (boolean test), `TRANSFORM` (data transformation), `FILTER` (data filtering), `PARAMETER` (plugin parameter resolution).

**Default engine registration:** The existing `CONDITION`, `TRANSFORM`, and `FILTER` defaults are registered by consumer repos (engine, ops), not platform — `registerDefault()` is never called in platform production code. `PARAMETER` follows the same pattern: consumers call `registry.registerDefault(ExpressionContext.PARAMETER, "mvel")` at application startup. If no default is registered, `TypeAwareParamResolver` throws `IllegalStateException` with a clear message identifying the missing registration.

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

**AptPluginSource changes:**

`AptPluginSource.loadManifest()` reads `"type"` from schema JSON properties but ignores `"format"`. This means `@Expression` fields emitting `{"type": "string", "format": "expression"}` produce `ParameterType.STRING` at runtime — `hasExpressionParams()` returns false and TypeAwareParamResolver is never created.

Fix: the schema property parsing loop checks `format` before falling through to `type`:

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

**BinderEmitter changes:**

`@Expression` record fields must be `Object`-typed (not `String`) because MVEL evaluation returns typed results. The generated `paramExtraction()` must skip casting for `@Expression` fields:

```java
static String paramExtraction(String type, String fieldName, boolean isExpression) {
    if (isExpression) {
        return "parameters.get(\"" + fieldName + "\")"; // no cast — returns Object
    }
    return switch (type) {
        // ... existing cases (unchanged) ...
    };
}
```

The `emit()` method passes the `@Expression` annotation check:

```java
boolean isExpression = field.getAnnotation(Expression.class) != null;
w.print(paramExtraction(type, yamlKey, isExpression));
```

### 5. yaml-plugin-processor

**StepPluginProcessor changes:**
- Scan record fields for `@Expression` annotation
- Map `@Expression` fields to `ParameterType.EXPRESSION` in generated Definition and schema

**SchemaEmitter changes:**

EXPRESSION fields emit `"type": "string", "format": "expression"` in JSON Schema. The existing `SchemaEmitter.emit()` property loop gains an annotation check:

```java
RecordComponentElement field = fields.get(i);
String yamlKey = BinderEmitter.toKebabCase(field.getSimpleName().toString());
String jsonType = toJsonType(field.asType().toString());
boolean isExpression = field.getAnnotation(Expression.class) != null;
if (isExpression) {
    w.print("    \"" + yamlKey + "\": { \"type\": \"string\", \"format\": \"expression\" }");
} else {
    w.print("    \"" + yamlKey + "\": { \"type\": \"" + jsonType + "\" }");
}
```

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

**AssertPlugin exclusion:** `AssertPlugin` also performs manual expression resolution via `ExpressionEngineRegistry`, but it is deliberately NOT migrated in this spec. AssertPlugin evaluates its `expression` field against `Map.of()` (empty context) — it tests MVEL expressions in isolation, not against playbook scope data. Migrating it to `@Expression` would expose the full expression context, changing semantics. AssertPlugin is a candidate for future migration if its design evolves to support contextual expressions.

## Scope Boundaries

**Note:** This work establishes the platform infrastructure for type-safe expression resolution. Issue #699 cannot be closed by this work alone — #699 explicitly scopes consumer repo migration (engine, ops, helpdesk playbooks) and cross-repo propagation. Follow-up issues listed below must be completed before #699 can be closed.

### In scope (this issue — platform only)
- `ParameterType.EXPRESSION` in yaml-plugin-api
- `@Expression` annotation in yaml-plugin-api
- `VariableResolver.withObjectScope(String, Map)` overload + `buildExpressionContext()` in yaml-core
- `VariableResolver` constructor refactor — all internal constructors forward `scopeContainers`
- `ExpressionContext.PARAMETER` in platform-api
- `TypeAwareParamResolver` in yaml-step-runtime
- `CatalogStepRunner` wiring change in yaml-step-runtime
- `StepResultStore.liveResults()` method + `result` scope dual-registration (functional + live map) in yaml-step-runtime
- `VariableResolver.withExpressionContext()` method in yaml-core
- `AptPluginSource.loadManifest()` format-aware property parsing in yaml-step-runtime
- `BinderEmitter` expression-aware param extraction (no cast for `@Expression Object` fields) in yaml-plugin-processor
- Plugin processor updates in yaml-plugin-processor (StepPluginProcessor + SchemaEmitter)
- `AssertThatPlugin` cleanup in yaml-step-runtime
- Tests for all of the above

### Out of scope (follow-up issues)
- Consumer repo migration (engine, ops, helpdesk playbooks) — audit and migrate to terse expression form (casehubio/platform#TBD)
- `when:` decorator condition unification via TypeAwareParamResolver (casehubio/platform#TBD)
- yaml-codegen `"format": "expression"` handling (casehubio/platform#TBD)
- TypeScript Walker parity in drafthouse (casehubio/platform#TBD)
- Work-slot for cross-repo propagation (casehubio/platform#TBD)
- Scope migration: `each`, `match`, `signal`, `from`, `error` scopes to Map-backed (casehubio/platform#TBD)
- `AssertPlugin` contextual expression migration (casehubio/platform#TBD)
- `registerDefault(ExpressionContext.PARAMETER, "mvel")` in consumer repo bootstrap (documented in consumer migration issue)

## Error Handling

| Scenario | Behavior |
|----------|----------|
| EXPRESSION param, no ExpressionEngineRegistry | IllegalStateException: "EXPRESSION parameters require ExpressionEngineRegistry in ServiceRegistry" |
| EXPRESSION param, no default engine for PARAMETER context | IllegalStateException: "No default expression engine registered for ExpressionContext.PARAMETER. Call registry.registerDefault(ExpressionContext.PARAMETER, \"mvel\") at application startup." |
| Expression references scope not in expression context | ExpressionCompilationException from MVEL — the scope must be migrated to Map-backed registration |
| Expression compilation fails | ExpressionCompilationException propagates — plugin.execute() never called |
| Expression evaluation fails | ExpressionEvaluationException propagates |
| EXPRESSION param with null value | Returns null (no expression evaluation) |
| EXPRESSION param with non-String value | Returns the value as-is (already evaluated, e.g., from YAML native types) |
| `${...}` in EXPRESSION field | Stripped, inner string evaluated as expression |
| `ParameterType.EXPRESSION.validate(null)` | Returns true — null is valid for EXPRESSION (resolution handles it) |

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
   - scopeContainers preserved across `withScope()`, `withDeferredPrefixHandler()`, `withChainedScope()`, `withObjectScope(String, ObjectVariableSource)` calls

4. **Plugin processor tests:**
   - @Expression annotation → ParameterType.EXPRESSION in generated Definition
   - JSON Schema includes `"format": "expression"`
   - BinderEmitter: `@Expression Object` field → `parameters.get()` without cast
   - BinderEmitter: non-Expression `String` field → `(String) parameters.get()` (unchanged)

5a. **AptPluginSource tests:**
   - Schema with `"format": "expression"` → `ParameterType.EXPRESSION` in loaded Definition
   - Schema without `"format"` → `ParameterType.STRING` (existing behavior)
   - `hasExpressionParams()` returns true for definitions loaded from `@Expression`-annotated plugins

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
