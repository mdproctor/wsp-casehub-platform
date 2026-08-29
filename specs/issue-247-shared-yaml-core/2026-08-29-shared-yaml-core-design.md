# Shared YAML Core — Refined Design Spec

**Issue:** casehubio/platform#247
**Date:** 2026-08-29
**Status:** Draft
**Parent spec:** `casehub-parent/docs/specs/2026-08-29-shared-yaml-core-design.md`

## Summary

Extract common YAML declaration primitives from `casehub-desiredstate/yaml/` into
`casehub-platform-yaml-core` — a new module in the platform repo. This spec refines
the parent spec with decisions from brainstorming and corrections from source code
analysis.

Five primitives: variable resolution, forEach expansion, conditional inclusion,
named iteration groups, and CSV typed data sources. Pure Java, zero dependencies,
J2CL-transpilable.

## Module Identity

| Element | Value |
|---|---|
| groupId | `io.casehub` |
| artifactId | `casehub-platform-yaml-core` |
| parent | `casehub-platform-parent` |
| directory | `yaml-core/` |
| package root | `io.casehub.yaml.core` |

**Rationale (D1):** Follows `casehub-platform-*` naming convention. Platform already
hosts zero-dep utility code (expression/, graphql/). No new repo needed.

## Design Model

### Toolbox composability (D2)

Primitives are independent utilities. Each domain's compilation pipeline cherry-picks
which primitives it uses. No composition framework — composability comes from the
primitives being decoupled:

- `resolver/` is standalone — no dependency on foreach or data
- `condition/` is standalone
- `foreach/` depends on resolver + condition (for when evaluation)
- `data/` depends on condition (for BOOLEAN column parsing)

A domain that only wants variable resolution imports only `resolver/` classes.

### YAML schema composability (D3)

Each primitive ships a JSON Schema fragment in `src/main/resources/schema/`:

```
src/main/resources/schema/
  foreach.schema.json       — forEach key structure (string ref or {as, in} map)
  when.schema.json          — when key structure (string value)
  iterations.schema.json    — iterations top-level section
  data.schema.json          — data top-level section with typed CSV
  variable.schema.json      — ${prefix.name} pattern documentation
```

Domains compose their full YAML schema by referencing these fragments via `$ref`.
A domain that doesn't support forEach omits the forEach fragment — its schema
validation rejects `forEach:` keys with a clear error.

Schema fragments are resource files only — no runtime cost, no J2CL impact.

## Module Structure

```
yaml-core/
  src/main/java/io/casehub/yaml/core/
    resolver/
      VariableResolver.java
      VariableSource.java
      UnresolvedVariableException.java
    foreach/
      ForEachExpander.java
      ForEachAdapter.java
      IterationGroup.java
      ExpansionResult.java
    condition/
      Truthiness.java
    data/
      CsvDataSource.java
      CsvColumn.java
      CsvColumnType.java
      CsvParser.java
  src/main/resources/schema/
    foreach.schema.json
    when.schema.json
    iterations.schema.json
    data.schema.json
    variable.schema.json
  src/test/java/io/casehub/yaml/core/
    resolver/
      VariableResolverTest.java
    foreach/
      ForEachExpanderTest.java
    condition/
      TruthinessTest.java
    data/
      CsvParserTest.java
```

## Primitive 1 — Variable Resolution

### API

```java
@FunctionalInterface
public interface VariableSource {
    String resolve(String name);

    static VariableSource chain(VariableSource... sources) {
        return name -> {
            for (VariableSource source : sources) {
                String value = source.resolve(name);
                if (value != null) return value;
            }
            return null;
        };
    }
}
```

**Contract:** `resolve()` returns `null` for "not found." The `chain()` compositor
tries sources in order, returning the first non-null result (C3).

```java
public class VariableResolver {
    private static final Pattern VAR_PATTERN = Pattern.compile("\\$\\{([^}]+)}");

    private final Map<String, VariableSource> prefixSources;
    private final Set<String> deferredPrefixes;
    private final Map<String, String> eachContext;
    private final Map<String, Map<String, Object>> eachRowContext;

    public VariableResolver(Map<String, VariableSource> prefixSources,
                            Set<String> deferredPrefixes) { ... }

    // Immutable child resolvers
    public VariableResolver withEachContext(Map<String, String> eachContext) { ... }
    public VariableResolver withEachRowContext(
            Map<String, Map<String, Object>> rowContext) { ... }
    public VariableResolver withScope(String prefix, VariableSource source) { ... }

    // Resolution
    public Object resolve(Object value) { ... }        // polymorphic dispatch (C6)
    public String resolveString(String template, String elementContext) { ... }
    public Map<String, Object> resolveMap(Map<?, ?> input, String elementContext) { ... }
    public List<?> resolveList(List<?> input, String elementContext) { ... }
}
```

**`resolve(Object)` dispatch (C6):** If `String` containing `${` → `resolveString()`.
If `Map` → `resolveMap()`. If `List` → `resolveList()`. Otherwise return unchanged.
Ported from existing `VariableResolver.resolve(Object)`.
}
```

### Resolution order

For a variable `${prefix.name}`:

1. If prefix is `each` → look up `name` in `eachContext` (string) or drill into
   `eachRowContext` (dotted path: `${each.env.name}` → rowContext["env"]["name"])
2. If prefix is in `prefixSources` → call `source.resolve(name)`. If null → throw
   `UnresolvedVariableException` listing available variables
3. If prefix is in `deferredPrefixes` → pass through (leave `${prefix.name}` in output)
4. If prefix is bare (no dot) → throw with guidance: "Use `${var.name}` instead"
5. Unknown prefix → throw listing registered prefixes and deferred prefixes

### Template mode replacement (C2)

The existing `resolveTemplateString/Map/List` methods are removed. The `deferredPrefixes`
concept replaces them:

```java
// Desiredstate — node spec resolution: match/fault MUST throw
var nodeResolver = new VariableResolver(
    Map.of("var", chain(moduleParams, inlineVars, configSource)),
    Set.of());  // no deferred prefixes — match.* throws

// Desiredstate — rule spec resolution: match/fault pass through
var ruleResolver = new VariableResolver(
    Map.of("var", chain(moduleParams, inlineVars, configSource)),
    Set.of("match", "fault"));  // deferred — pass through

// Scenario — step result resolution
var stepResolver = new VariableResolver(
    Map.of("params", callerContext, "step", stepResults),
    Set.of());
```

### Error model

```java
public class UnresolvedVariableException extends RuntimeException {
    private final String variableName;
    private final String elementContext;

    public UnresolvedVariableException(String variableName,
            String elementContext, String detail) { ... }

    public String variableName() { return variableName; }
    public String elementContext() { return elementContext; }
}
```

Direct port. `nodeContext` renamed to `elementContext` (generic — not all domains
call their elements "nodes").

## Primitive 2 — ForEach Expansion

### API

```java
public interface ForEachAdapter<E> {   // NOT @FunctionalInterface — 4 methods (C1)
    E stamp(E template, String stampedId, VariableResolver scopedResolver);
    Object getForEach(E element);
    String getId(E element);
    String getWhen(E element);
}
```

```java
public record IterationGroup(String as, Object in) {
    public List<Object> inAsList() {
        if (in instanceof List<?> list) { return List.copyOf(list); }
        if (in instanceof String s) { return List.of(s); }
        if (in == null) { return List.of(); }
        throw new IllegalArgumentException(
            "iterations.in must be a list or string, got: " + in.getClass());
    }
}
```

```java
public record ExpansionResult<E>(List<E> elements, Set<String> excludedIds) {}
```

```java
public final class ForEachExpander {
    private ForEachExpander() {}

    public static <E> ExpansionResult<E> expand(   // static method (C4)
            Map<String, E> elements,
            Map<String, IterationGroup> iterationGroups,
            VariableResolver resolver,
            ForEachAdapter<E> adapter,
            int maxExpansion) { ... }
}
```

### Ported behaviour

Matches existing `ForEachExpanderTest` coverage:

- Inline forEach stamps N copies with `originalId.value` IDs
- Named group forEach references shared `IterationGroup`
- Variables in `forEach.in` values resolved before expansion
- `when` evaluated per stamped copy (after `each.*` resolution via `Truthiness.isTruthy()`)
- `maxExpansion` limit enforced per template
- Excluded elements tracked in `excludedIds`

### What stays in the domain

- Dependency wiring (graph-specific — desiredstate's third pass)
- JSON array parsing for variable-resolved group values (needs ObjectMapper)
- Domain type construction (`DesiredNode`, `NodeSpec` conversion)

The adapter's `stamp()` method is where all domain-specific logic goes: spec resolution,
type conversion, hook resolution, node construction.

## Primitive 3 — Conditional Inclusion

```java
public final class Truthiness {
    private Truthiness() {}

    public static boolean isTruthy(String value) {
        return switch (value.toLowerCase(java.util.Locale.ROOT)) {
            case "true", "yes", "on", "y", "1" -> true;
            case "false", "no", "off", "n", "0" -> false;
            default -> throw new IllegalArgumentException(
                "Condition resolved to '" + value
                + "' which is not a boolean value. "
                + "Expected: true/false/yes/no/on/off/y/n/1/0");
        };
    }
}
```

Direct port. `Locale.ROOT` for J2CL-safe case folding. Generic error message
(caller knows the context — no `when:` prefix).

## Primitive 4 — CSV Typed Data Source

New capability. Neither domain has this today (D4).

```java
public enum CsvColumnType {
    STRING, INTEGER, BOOLEAN, DECIMAL;

    public Object parse(String value, int row, String columnName) {
        return switch (this) {
            case STRING  -> value;
            case INTEGER -> parseInteger(value, row, columnName);
            case BOOLEAN -> Truthiness.isTruthy(value);
            case DECIMAL -> parseDecimal(value, row, columnName);
        };
    }

    // private helpers with clear error messages: row N, column "name", expected type, got "value"
}

public record CsvColumn(String name, CsvColumnType type) {}

public record CsvDataSource(String name, List<CsvColumn> columns,
                             List<Map<String, Object>> rows) {}
```

```java
public final class CsvParser {
    private CsvParser() {}

    public static CsvDataSource parse(String name, String csvContent) { ... }  // single method (C5)
}
```

**Header format:** First row declares `columnName:type` pairs. Type validation at
parse time — every cell validated against its declared column type.

**Integration with VariableResolver:** CSV rows are passed via `withEachRowContext()`.
When `${each.env.name}` is encountered, the resolver looks up `env` in the row context
map, then drills into the `name` field.

**Integration with ForEach:** The domain's compilation pipeline parses `data:` blocks
via `CsvParser`, converts rows to iteration values, and passes them to
`ForEachExpander` through the adapter.

## J2CL Compatibility Constraints

Enforced by code review and test discipline (no build-time checker):

- No `java.lang.reflect`
- No `ConcurrentHashMap` — use `HashMap`
- No `Thread`, `Lock`, `synchronized`
- No CDI annotations
- No Jackson
- Records, sealed interfaces, `List.of()`, `Map.of()`, `Map.copyOf()` are fine

## Test Plan

Port existing tests with adaptations:

| Source test | Shared test | Adaptation |
|---|---|---|
| `ForEachExpanderTest` | `ForEachExpanderTest` | Replace `YamlNode`/`DesiredNode` with test record + `ForEachAdapter` implementation |
| `YamlConditionalEvaluationTest` | `TruthinessTest` | Direct — tests `isTruthy()` with all truthy/falsy values + invalid input |
| `VariableResolverTest` (inline in desiredstate) | `VariableResolverTest` | Adapt to pluggable `VariableSource` chain instead of inline variables map |

New tests (no existing source):

| Test | Coverage |
|---|---|
| `CsvParserTest` | Typed columns, parse errors (wrong type, missing column), empty CSV, header-only CSV, boolean column via Truthiness |
| `VariableResolverTest` (CSV rows) | `${each.env.name}` dotted row field access, mixed simple + row contexts |
| `ForEachExpanderTest` (CSV iteration) | forEach over CSV data source rows, when evaluation per row |

## Downstream Migration Path

Unchanged from parent spec. Each downstream repo migrates independently:

- **Desiredstate:** Replace VariableResolver, ForEachExpander, isTruthy, YamlIterationGroup.
  Provide `ForEachAdapter<YamlNode>` with domain-specific stamp logic.
  Register `match`/`fault` as deferred prefixes.
- **Scenarios:** Replace VariableContext with shared VariableResolver.
  Adopt ForEach, when, CSV via adapter.

Migration is separate work — file issues on `casehubio/desiredstate` and `casehubio/pages`.

## References

- `io.casehub.desiredstate.yaml.resolver.VariableResolver` (206 lines) — existing variable resolver
- `io.casehub.desiredstate.yaml.resolver.VariableResolverTest` (220 lines) — existing test coverage
- `io.casehub.desiredstate.yaml.ForEachExpander` (272 lines) — existing forEach expansion
- `io.casehub.desiredstate.yaml.ForEachExpanderTest` (202 lines) — existing forEach test coverage
- `io.casehub.desiredstate.yaml.YamlGraphRecorder:217-226` — existing isTruthy()
- `io.casehub.desiredstate.yaml.YamlConditionalEvaluationTest` (151 lines) — existing conditional tests
- `io.casehub.desiredstate.yaml.model.YamlIterationGroup` (15 lines) — existing iteration group record
- `io.casehub.desiredstate.yaml.model.YamlNode` (42 lines) — existing node model (adapter target)
- `io.casehub.pages.scenario.runtime.VariableContext` (73 lines) — pages variable context
- `io.casehub.desiredstate.yaml.resolver.UnresolvedVariableException` (18 lines) — existing error model
- `casehub-parent/docs/specs/2026-08-29-shared-yaml-core-design.md` — parent spec
- `decisions.md` — D1 (module placement), D2 (toolbox composability), D3 (schema fragments), D4 (CSV in scope)
