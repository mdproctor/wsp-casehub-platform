# yaml-core Module System + API Fixes — Design Spec

**Issues:** casehubio/platform#252, casehubio/platform#253
**Date:** 2026-08-31
**Status:** Draft

## Summary

Two changes to `casehub-platform-yaml-core`:

1. **API fixes (#253):** `ExpansionResult` returns `LinkedHashMap<String, E>` (keyed by
   stamped ID), and `VariableResolver` gains a `DeferredPrefixHandler` callback for
   context-dependent deferred prefix diagnostics.

2. **Module system (#252):** Generic YAML module model (`YamlModule`, `YamlModuleParameter`),
   `ParameterValidator` with type-aware constraint checking, `ModuleExpander` for
   parameter resolution + alias prefixing + import merging, and supporting types
   (`YamlImport`, `YamlModuleFile`, `ParameterType`).

All code is pure Java, zero dependencies, J2CL-transpilable.

## Part 1 — API Fixes (#253)

### ExpansionResult — Map instead of List

```java
public record ExpansionResult<E>(LinkedHashMap<String, E> elements,
                                  Set<String> excludedIds) {}
```

`LinkedHashMap` preserves insertion order and provides ID→element access. The
expander already computes `stampedId` for every element — dropping it from the
result was the bug. Callers that just need iteration use `elements.values()`.

`ForEachExpander.expand()` builds the map internally:

```java
LinkedHashMap<String, E> allElements = new LinkedHashMap<>();
// ...
allElements.put(stampedId, adapter.stamp(element, stampedId, eachResolver));
// ...
if (allElements.containsKey(stampedId)) {
    throw new IllegalStateException("Duplicate stamped ID '" + stampedId
            + "' — forEach values must be unique within each template.");
}
// ...
return new ExpansionResult<>(allElements, Set.copyOf(excludedIds));
```

### DeferredPrefixHandler — context-dependent diagnostics

```java
@FunctionalInterface
public interface DeferredPrefixHandler {
    void onDeferred(String prefix, String key, String elementContext);
}
```

Added to `VariableResolver` via the immutable-child pattern. The private
constructor gains a 5th parameter. **All existing `with*()` methods must
propagate the handler** — `withEachContext()`, `withEachRowContext()`, and
`withScope()` all pass the handler through the 5-argument constructor:

```java
public VariableResolver withDeferredPrefixHandler(DeferredPrefixHandler handler) {
    return new VariableResolver(prefixSources, deferredPrefixes,
            eachContext, eachRowContext, handler);
}

// All existing with*() methods updated to propagate handler:
public VariableResolver withEachContext(Map<String, String> eachContext) {
    return new VariableResolver(prefixSources, deferredPrefixes,
            eachContext, eachRowContext, deferredPrefixHandler);
}
// ... same pattern for withEachRowContext(), withScope()
```

In `lookupVariable()`, when a deferred prefix is hit:

```java
if (deferredPrefixes.contains(prefix)) {
    if (deferredPrefixHandler != null) {
        deferredPrefixHandler.onDeferred(prefix, key, elementContext);
    }
    return null;  // pass through (current behaviour preserved)
}
```

Default: `null` (silent — current behaviour). Consumers can throw
domain-specific errors:

```java
// Desiredstate — node spec context: match/fault must fail
var nodeResolver = new VariableResolver(sources, Set.of("match", "fault"))
        .withDeferredPrefixHandler((prefix, key, ctx) -> {
            throw new UnresolvedVariableException(key, ctx,
                    prefix + " references are resolved at rule evaluation time, "
                    + "not in node spec resolution.");
        });

// Desiredstate — rule spec context: match/fault pass through silently
var ruleResolver = new VariableResolver(sources, Set.of("match", "fault"));
// no handler — deferred prefixes pass through
```

## Part 2 — Module System (#252)

### Package structure

All new types in `io.casehub.yaml.core.module`:

```
yaml-core/src/main/java/io/casehub/yaml/core/module/
    YamlModule.java
    YamlModuleParameter.java
    YamlModuleFile.java
    YamlImport.java
    ModuleExpander.java
    ParameterValidator.java
    ParameterValidationException.java
    ParameterViolation.java
    ParameterType.java
```

### YamlModule — generic content sections

```java
public record YamlModule(
        String name,
        Map<String, YamlModuleParameter> parameters,
        Map<String, Map<String, Object>> sections) {

    public YamlModule {
        if (parameters == null) { parameters = Map.of(); }
        if (sections == null) { sections = Map.of(); }
    }
}
```

Content sections are opaque maps keyed by section name (D3). The module system
operates on keys (for alias prefixing) and passes values through. Consumers
interpret sections by name: desiredstate reads `sections.get("nodes")`,
`sections.get("rules")`.

Consumer boundary conversion requires `objectMapper.convertValue()` — not a
simple cast. This is an ObjectMapper step at the consumer side, not within
yaml-core (which remains Jackson-free).

### YamlModuleParameter — typed constraints

```java
public record YamlModuleParameter(
        ParameterType type,
        boolean required,
        String defaultValue,
        Integer minLength,
        Integer maxLength,
        String pattern,
        Number minimum,
        Number maximum) {

    public YamlModuleParameter {
        if (type == null) { type = ParameterType.STRING; }
    }
}
```

Constraint semantics are type-aware (D6):

| Constraint | STRING | LIST | INTEGER | NUMBER | BOOLEAN |
|------------|--------|------|---------|--------|---------|
| `minLength` | min char count | min element count | — | — | — |
| `maxLength` | max char count | max element count | — | — | — |
| `pattern` | regex match | per-element regex | — | — | — |
| `minimum` | — | — | lower bound | lower bound | — |
| `maximum` | — | — | upper bound | upper bound | — |

### ParameterType — separate from CsvColumnType

```java
public enum ParameterType {
    STRING, LIST, INTEGER, NUMBER, BOOLEAN;

    public Object parse(String value) {
        return switch (this) {
            case STRING -> value;
            case LIST -> List.of(value.split(",")).stream()
                    .map(String::trim).toList();
            case INTEGER -> Integer.parseInt(value);
            case NUMBER -> Double.parseDouble(value);
            case BOOLEAN -> Truthiness.isTruthy(value);
        };
    }
}
```

Parsing is transient — for validation only. Interpolation stays string-based.
Parsing is a deliberate JSON Schema subset scoped to what the module system needs
(D6, R1-04).

**LIST limitation:** comma is the delimiter; commas within values are not supported.
Empty string produces a single-element list with an empty value, not an empty list.
If a use case needs commas in values, the consumer should use STRING type with its
own parsing.

### ParameterValidator — collect-all, dual API

```java
public final class ParameterValidator {

    private ParameterValidator() {}

    public static List<ParameterViolation> validate(
            Map<String, YamlModuleParameter> declared,
            Map<String, String> provided) { ... }

    public static void validateOrThrow(
            Map<String, YamlModuleParameter> declared,
            Map<String, String> provided) {
        List<ParameterViolation> violations = validate(declared, provided);
        if (!violations.isEmpty()) {
            throw new ParameterValidationException(violations);
        }
    }
}
```

`validate()` returns violations (primitive). `validateOrThrow()` is the
convenience (D4 revised). Both collect all violations — not fail-fast.

Validation order per parameter:
1. Required check — parameter declared `required: true` but absent from `provided`
2. Type parsing — parse value per `ParameterType.parse()`; parse failure is a violation
3. Constraint checks — `minLength`, `maxLength`, `pattern`, `minimum`, `maximum`

```java
public record ParameterViolation(String parameterName, String constraint,
                                  String message, Object actualValue) {}

public class ParameterValidationException extends RuntimeException {
    private final List<ParameterViolation> violations;

    // constructor, getter
    public List<ParameterViolation> violations() { return violations; }
}
```

### YamlImport — import declaration

```java
public record YamlImport(
        String module,
        String as,
        String when,
        Map<String, String> parameters) {

    public YamlImport {
        if (parameters == null) { parameters = Map.of(); }
    }
}
```

### YamlModuleFile — file model for deserialization

```java
public record YamlModuleFile(
        YamlModuleHeader header,
        Map<String, Map<String, Object>> sections,
        List<YamlImport> imports) {

    public YamlModuleFile {
        if (sections == null) { sections = Map.of(); }
        if (imports == null) { imports = List.of(); }
    }

    public YamlModule toModule() {
        return new YamlModule(header.name(), header.parameters(), sections);
    }

    public record YamlModuleHeader(String name,
            Map<String, YamlModuleParameter> parameters) {
        public YamlModuleHeader {
            if (parameters == null) { parameters = Map.of(); }
        }
    }
}
```

Field named `module` (not `header`) to match the YAML key `module:` and the
existing desiredstate convention. `toModule()` discards the `imports` field —
nested imports must be resolved by the consumer before calling `toModule()`.

```java
public record YamlModuleFile(
        YamlModuleHeader module,    // matches YAML key "module:"
        Map<String, Map<String, Object>> sections,
        List<YamlImport> imports) {
    // ...
    public YamlModule toModule() {
        return new YamlModule(module.name(), module.parameters(), sections);
    }
}
```

### ModuleExpander — structural expansion

```java
public final class ModuleExpander {

    private ModuleExpander() {}

    public static ExpandedModule expand(
            List<YamlImport> imports,
            Map<String, YamlModule> availableModules,
            Map<String, Map<String, Object>> existingSections) { ... }
}

public record ExpandedModule(
        Map<String, Map<String, Object>> sections,
        Map<String, Map<String, String>> moduleScopes) {}
```

**Import structural validation (preconditions — checked before expansion):**
- Unknown module — import references a module name not in `availableModules`
- Missing alias — `as` is null or blank
- Dot in alias — alias contains `.` (reserved as the ID separator in `alias.entryKey`)
- Duplicate alias — two imports use the same alias
- Unknown parameters — provided params not declared in the module (typo detection)

All violations collected and thrown as `ParameterValidationException`.

**What ModuleExpander handles:**
- Import structural validation (above)
- Parameter resolution — import params merged with defaults
- Parameter validation — via `ParameterValidator.validateOrThrow()`
- Alias prefixing — section entry keys prefixed with `import.as + "."`
- Import merging — module sections merged into existing sections

**What stays in the consumer:**
- `when` propagation — the expander returns per-import `when` values in
  `ExpandedModule`; the consumer applies them to entries with domain knowledge
  of which sections support conditional inclusion. The expander does not inject
  `when` into opaque maps — that would contradict the "passes values through" design.
- Domain-specific dependency rewriting (desiredstate wires internal deps between
  aliased nodes)
- Section content interpretation (`objectMapper.convertValue()` to domain types)
- JSON array parsing from variable-resolved values (needs ObjectMapper)
- Nested import resolution — `ModuleExpander` handles single-level imports only;
  recursive resolution is the consumer's responsibility (call `toModule()` on
  inner modules after resolving their imports)

```java
public record ExpandedModule(
        Map<String, Map<String, Object>> sections,
        Map<String, Map<String, String>> moduleScopes,
        Map<String, String> importConditions) {}  // alias → when value (null if unconditional)
```

### Module parameter resolution via VariableSource.chain()

`ModuleExpander` returns `moduleScopes` — per-alias maps of resolved parameter
values. The consumer wires these into the resolver via chaining (D5 revised):

```java
Map<String, String> moduleParams = expandedModule.moduleScopes().get(alias);
VariableSource chainedSource = VariableSource.chain(moduleParams::get, existingVarSource);
VariableResolver scopedResolver = resolver.withScope("var", chainedSource);
```

Chain order defines priority: module params checked first, then existing sources.
No `withModuleScope()` method needed — `VariableSource.chain()` is the composition
mechanism.

## Test Plan

### #253 tests (API fixes)

| Test | Coverage |
|------|----------|
| `ExpansionResult` returns map keyed by stamped ID | verify `.elements().get("node.us-east")` works |
| Duplicate stampedId throws | forEach with `["a", "a"]` throws IllegalStateException |
| Existing forEach tests updated to use map API | all 15 tests adapted |
| `DeferredPrefixHandler` invoked on deferred hit | handler receives correct prefix, key, context |
| Handler can throw domain-specific exception | exception propagates from resolveString |
| No handler = silent pass-through (default) | current behaviour preserved |
| Handler survives `withEachContext()` chain | set handler, call withEachContext, verify handler still fires |
| Handler survives `withScope()` chain | set handler, call withScope, verify handler still fires |

### #252 tests (module system)

| Test | Coverage |
|------|----------|
| `ParameterValidatorTest` | required check, type validation, minLength/maxLength (string + list), pattern, minimum/maximum, collect-all (multiple violations), validate() returns list, validateOrThrow() throws |
| `ParameterTypeTest` | parse each type, parse errors with messages |
| `ModuleExpanderTest` | alias prefixing on section keys, parameter resolution from import, default parameter values, multiple imports, existing section preservation, unknown module error, missing required parameter error, missing alias error, dot-in-alias error, duplicate alias error, unknown parameter error (typo detection), importConditions returned for conditional imports |
| `YamlModuleFileTest` | toModule() conversion, header parsing |

## Downstream Migration Path

- **casehubio/casehub-desiredstate#128:** Replace local `YamlModule`, `YamlModuleParameter`,
  `ModuleExpander`, `YamlImport`, `YamlModuleFile` with yaml-core's. Create
  `VariableSource` adapters for inline variables and MicroProfile Config. Register
  `match`/`fault` as deferred prefixes with a `DeferredPrefixHandler` that throws
  in node-spec context. Keep dependency rewriting and `when` propagation in the domain.
  **Jackson note:** yaml-core's `YamlModuleParameter` uses `defaultValue` as the field
  name (no `@JsonProperty` — yaml-core is Jackson-free). Consumers deserializing YAML
  with `default:` as the key must register a Jackson mixin or custom deserializer to
  map `default` → `defaultValue` (since `default` is a Java reserved word).

## References

- `io.casehub.yaml.core.foreach.ForEachExpander` — existing expander (D1 target)
- `io.casehub.yaml.core.foreach.ExpansionResult` — current List-based result (D1 target)
- `io.casehub.yaml.core.resolver.VariableResolver` — existing resolver (D2, D5 target)
- `io.casehub.yaml.core.resolver.VariableSource` — chain composition (D5)
- `io.casehub.desiredstate.yaml.ModuleExpander` — existing domain-coupled expander
- `io.casehub.desiredstate.yaml.model.YamlModule` — existing domain-coupled model
- `io.casehub.desiredstate.yaml.model.YamlModuleParameter` — existing (type + required + default only)
- `io.casehub.desiredstate.yaml.model.YamlImport` — existing import model
- `io.casehub.desiredstate.yaml.model.YamlModuleFile` — existing file model
- `io.casehub.desiredstate.yaml.deployment.YamlDesiredStateProcessor.validateImports()` — existing validation
- casehubio/platform#252 — module system issue
- casehubio/platform#253 — API fix issue
- casehubio/casehub-desiredstate#128 — migration issue (first consumer)
- `decisions.md` — D1–D6 design decisions
