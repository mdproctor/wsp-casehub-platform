# yaml-core type system polish

**Branch:** issue-429-yaml-type-system  
**Covers:** #429 (typed variables), block-level expansion gap  
**Relates to:** #428 (YAML parsing standardisation) — this branch sidesteps YAML 1.1/1.2 parser inference by using declared types. The central `YamlMappers.create()` factory from #428 remains a separate concern.  
**Repo:** casehubio/platform (yaml-core)

## Problem

yaml-core has three parallel type vocabularies, a dead typed-resolution path, forEach that kills types via `toString()`, and no block-level iteration. A Claude working on the YAML surface can't trace types end-to-end or distinguish compile-time expansion from runtime loops.

### What's broken

1. **Three type enums:** `CsvColumnType` (data/), `ParameterType` (module/), and no shared vocabulary. Same scalar types defined independently.

2. **Dead typed resolution:** `ObjectVariableSource`, `withObjectScope()`, and `resolveTyped()` exist but have zero production usage. `CorpusVariableSource` implements `ObjectVariableSource` but is never registered with a resolver.

3. **forEach kills types:** `VariableSource.forEachContext()` line 49 calls `.toString()` on drilled values. `CsvColumnType.INTEGER.parse("8080")` → `Integer 8080` → row map → `forEachContext.toString()` → `"8080"` String. The test `csvDataSource_typedColumns_resolveCorrectly` asserts the broken behavior.

4. **No block-level iteration:** `ForEachDirective` decorates individual nodes. `LoopDirective` decorates individual steps. Modules define blocks but accept neither. A Claude sees these as interchangeable decorators with no structural signal about compile-time vs runtime, and no way to apply either to a group.

## Design

### Principles

1. **Types are declared, not inferred.** The `name:type` syntax is the declaration. No YAML parser guessing.
2. **Typed values flow through the pipeline.** Once parsed, the Java object (Integer, Boolean, Double, String) carries the type. No wrapper needed.
3. **resolveTyped returns scalars, never containers.** Map/List roots without a field path return null — fall through to string resolution. Eliminates the dual-purpose alias tension.
4. **Schema is queryable from source data.** CsvDataSource and TypedMap expose declared types. No parallel schema structure.

### 1. Unified type vocabulary — `ValueType`

New enum in `io.casehub.yaml.core.type`:

```java
public enum ValueType {
    STRING, INTEGER, BOOLEAN, NUMBER;

    public Object parse(String value) { /* existing CsvColumnType.parse logic */ }

    public Set<String> javaTypes() {
        return switch (this) {
            case STRING  -> Set.of("java.lang.String", "java.lang.CharSequence");
            case INTEGER -> Set.of("int", "java.lang.Integer", "long", "java.lang.Long");
            case BOOLEAN -> Set.of("boolean", "java.lang.Boolean");
            case NUMBER  -> Set.of("double", "java.lang.Double", "float", "java.lang.Float",
                                   "java.math.BigDecimal");
        };
    }

    public boolean accepts(String javaTypeName) { return javaTypes().contains(javaTypeName); }
}
```

**`CsvColumnType` is deleted.** `CsvColumn` becomes `CsvColumn(String name, ValueType type)`.

**`ParameterType` delegates scalar work:**

```java
public ValueType scalarType() {
    return switch (this) {
        case STRING  -> ValueType.STRING;
        case INTEGER -> ValueType.INTEGER;
        case NUMBER  -> ValueType.NUMBER;
        case BOOLEAN -> ValueType.BOOLEAN;
        case LIST    -> null;
    };
}
```

`ParameterType.parse()` delegates to `ValueType.parse()` for scalar cases but retains LIST handling and `ParsedValue` wrapping.

### 2. Shared name:type parser — `TypedName`

New record in `io.casehub.yaml.core.type`:

```java
public record TypedName(String name, ValueType type) {
    public static TypedName parse(String raw) {
        int colon = raw.indexOf(':');
        if (colon < 0) return new TypedName(raw.trim(), ValueType.STRING);
        return new TypedName(
            raw.substring(0, colon).trim(),
            ValueType.valueOf(raw.substring(colon + 1).trim().toUpperCase(Locale.ROOT)));
    }
}
```

Used by `CsvParser.parseHeader()` and `TypedVariables.parse()`.

### 3. Typed variable declarations — `TypedMap`

New record in `io.casehub.yaml.core.type`:

```java
public record TypedMap(Map<String, ValueType> schema, Map<String, Object> values) {
    public ValueType typeOf(String name) { return schema.get(name); }
}
```

New utility `TypedVariables`:

```java
public final class TypedVariables {
    public static TypedMap parse(Map<String, Object> rawVariables) {
        var schema = new LinkedHashMap<String, ValueType>();
        var values = new LinkedHashMap<String, Object>();
        for (var entry : rawVariables.entrySet()) {
            TypedName tn = TypedName.parse(entry.getKey());
            schema.put(tn.name(), tn.type());
            values.put(tn.name(), tn.type().parse(String.valueOf(entry.getValue())));
        }
        return new TypedMap(Map.copyOf(schema), Map.copyOf(values));
    }
}
```

YAML surface:
```yaml
variables:
  batch_size:integer: 500
  bucket: prod                # string is default
  enabled:boolean: true
  ratio:number: 3.14
```

Backward compatible — untyped variables default to STRING.

### 4. CsvDataSource schema API

Add to existing `CsvDataSource`:

```java
public ValueType typeOf(String columnName) {
    return columns.stream()
        .filter(c -> c.name().equals(columnName))
        .map(CsvColumn::type)
        .findFirst().orElse(null);
}

public Map<String, ValueType> schema() {
    return columns.stream()
        .collect(Collectors.toMap(CsvColumn::name, CsvColumn::type,
                                  (a, b) -> a, LinkedHashMap::new));
}
```

### 5. resolveTyped — scalar-only rule

One change in `VariableResolver.resolveTyped()`:

```java
// Current:
if (nextDot < 0) return root;

// New:
if (nextDot < 0) {
    if (root instanceof Map || root instanceof List) return null;
    return root;
}
```

**Effect:**
- `${each.region}` → resolveTyped gets row Map, no field path → null → resolveString → "us-east" ✓
- `${each.region.tier}` → resolveTyped gets row Map, drills "tier" → Integer 500 ✓
- `${var.batch_size}` → resolveTyped gets Integer 500, scalar → Integer 500 ✓

### 6. ForEachExpander — register ObjectVariableSource

CSV iteration path (ForEachExpander line ~262), add `withObjectScope`:

```java
VariableResolver rowResolver = resolver
    .withScope("each", VariableSource.forEachContext(
        Map.of(as, rowKey, "index", String.valueOf(i)),
        Map.of(as, row)))
    .withObjectScope("each", name -> name.equals(as) ? row : null);
```

Both sources registered for "each" prefix:
- **ObjectVariableSource** → used by `resolveTyped()` for sole references → typed values
- **VariableSource** → used by `resolveString()` for embedded references → string interpolation

### 7. Block-level expansion — forEach on YamlImport

Add `forEach` field to `YamlImport`:

```java
public record YamlImport(
        String module,
        String as,
        String when,
        Map<String, String> parameters,
        Object forEach) {       // NEW — ForEachDirective.parse(forEach)
}
```

YAML surface:
```yaml
imports:
  - module: regional-pipeline
    as: region
    forEach: { group: regions }
    parameters:
      endpoint: ${each.region.endpoint}
```

**Expansion order (three-phase):**
1. Resolve forEach on imports → stamp out N copies, each with a unique `as` prefix (e.g., `region.us-east`, `region.eu-west`)
2. ModuleExpander → flatten each import into nodes
3. ForEachExpander → per-node forEach on the flattened result

Phase 1 is a new pre-expansion step in `YamlGraphRecorder` (desiredstate) and any other module consumer.

### 8. Block-level runtime loop — loop on YamlImport

Add `loop` field to `YamlImport`:

```java
public record YamlImport(
        String module,
        String as,
        String when,
        Map<String, String> parameters,
        Object forEach,
        Object loop) {          // NEW — LoopDirective.parse(loop)
}
```

YAML surface:
```yaml
imports:
  - module: retry-pipeline
    as: attempt
    loop: { count: 3, until: ${module.attempt.status} == "ok" }
```

The orchestration runtime consumes `LoopDirective` on the expanded block. Implementation follows existing per-step loop handling, extended to block scope.

### 9. Build-time type validation (desiredstate deployment processor)

New validation step in `YamlDesiredStateProcessor.validateForEach()`:

For each `${each.X.field}` or `${var.X}` reference in a spec:
1. Trace to source: variable declarations → `TypedMap.typeOf()`, or CSV → `CsvDataSource.typeOf()`
2. Look up target spec field via Jandex (already available in the deployment processor)
3. Check: `valueType.accepts(javaTypeName)`
4. Error on mismatch with clear message:

```
ERROR test.yaml: node 'ingest' spec field 'batchSize' (int)
  references ${var.batch_size} declared as 'string' — type mismatch
```

### 10. Final conformance audit

After all changes land, systematic sweep for:
- Type safety gaps — any resolution path that loses declared types
- Duplicate paths — parallel resolution mechanisms serving the same purpose
- Non-normalised entry points — inconsistent API shapes for the same concept
- Expansion asymmetries — constructs that work at step level but not block level, or vice versa

Findings become follow-up issues, not scope on this branch.

## What changes where

| File | Change |
|------|--------|
| `yaml-core/type/ValueType.java` | New enum — scalar types + parse + compatibility |
| `yaml-core/type/TypedName.java` | New record — name:type parser |
| `yaml-core/type/TypedMap.java` | New record — schema + typed values |
| `yaml-core/type/TypedVariables.java` | New utility — variable declaration parser |
| `yaml-core/data/CsvColumnType.java` | **Deleted** — replaced by ValueType |
| `yaml-core/data/CsvColumn.java` | Updated — uses ValueType |
| `yaml-core/data/CsvParser.java` | Updated — uses TypedName.parse() |
| `yaml-core/data/CsvDataSource.java` | Updated — add typeOf(), schema() |
| `yaml-core/module/ParameterType.java` | Updated — add scalarType() delegation |
| `yaml-core/module/YamlImport.java` | Updated — add forEach, loop fields |
| `yaml-core/resolver/VariableResolver.java` | Updated — resolveTyped scalar-only rule |
| `yaml-core/foreach/ForEachExpander.java` | Updated — withObjectScope for CSV rows |
| `yaml-core/data/CsvParserTest.java` | Updated — fix type assertions |
| `yaml-core/foreach/ForEachExpanderTest.java` | Updated — typed value assertions, block forEach tests |

Desiredstate (separate PRs):
| `yaml/deployment/YamlDesiredStateProcessor.java` | Build-time type validation |
| `yaml/runtime/YamlGraphRecorder.java` | forEach-on-import pre-expansion phase |

## References

- `yaml-core/data/CsvColumnType.java` — existing type enum being replaced
- `yaml-core/module/ParameterType.java:7-8` — parallel type enum to unify with
- `yaml-core/resolver/VariableResolver.java:91-148` — resolveTyped method
- `yaml-core/resolver/VariableSource.java:39-66` — forEachContext with toString bug
- `yaml-core/resolver/ObjectVariableSource.java` — unused interface to activate
- `yaml-core/foreach/ForEachExpander.java:255-280` — CSV forEach path
- `yaml-core/orchestration/LoopDirective.java` — runtime loop model
- `yaml-core/module/YamlImport.java` — import record to extend
- `desiredstate/yaml/runtime/YamlGraphRecorder.java:100-148` — expansion phases
- `desiredstate/yaml/deployment/YamlDesiredStateProcessor.java:307-342` — build-time validation
- GitHub issue #429 — typed variable declarations
- GitHub issue #428 — YAML parsing standardisation
