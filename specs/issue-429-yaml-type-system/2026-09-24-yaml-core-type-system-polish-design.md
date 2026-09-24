# yaml-core type system polish

**Branch:** issue-429-yaml-type-system  
**Covers:** #429 (typed variables)  
**Relates to:** #428 (YAML parsing standardisation) — this branch sidesteps YAML 1.1/1.2 parser inference by using declared types. The central `YamlMappers.create()` factory from #428 remains a separate concern.  
**Repo:** casehubio/platform (yaml-core)

## Problem

yaml-core has three parallel type vocabularies, a dead typed-resolution path, and forEach that kills types via `toString()`. A Claude working on the YAML surface can't trace types end-to-end.

### What's broken

1. **Three type enums:** `CsvColumnType` (data/), `ParameterType` (module/), and no shared vocabulary. Same scalar types defined independently.

2. **Dead typed resolution:** `ObjectVariableSource`, `withObjectScope()`, and `resolveTyped()` exist but have zero production usage. `CorpusVariableSource` implements `ObjectVariableSource` but is never registered with a resolver.

3. **forEach kills types:** `VariableSource.forEachContext()` line 49 calls `.toString()` on drilled values. `CsvColumnType.INTEGER.parse("8080")` → `Integer 8080` → row map → `forEachContext.toString()` → `"8080"` String. The test `csvDataSource_typedColumns_resolveCorrectly` asserts the broken behavior.

## Design

### Principles

1. **Types are declared, not inferred.** The `name:type` syntax is the declaration. No YAML parser guessing.
2. **Typed values flow through the pipeline.** Once parsed, the Java object (Integer, Boolean, Double, String) carries the type. No wrapper needed.
3. **Container return is source-controlled.** `ObjectVariableSource.allowContainerReturn()` determines whether Map/List root values pass through typed resolution or fall through to string resolution. forEach row sources are drill-only (containers exist only for field access); runtime result sources pass through (the Map IS the value).
4. **Schema is queryable from source data.** CsvDataSource and TypedMap expose declared types. No parallel schema structure.

### 1. Unified type vocabulary — `ValueType`

New enum in `io.casehub.yaml.core.type`:

```java
public enum ValueType {
    STRING, INTEGER, BOOLEAN, NUMBER;

    public Object parse(String value) {
        return switch (this) {
            case STRING  -> value;
            case INTEGER -> Integer.parseInt(value);
            case BOOLEAN -> Truthiness.isTruthy(value);
            case NUMBER  -> Double.parseDouble(value);
        };
    }

    public Set<String> javaTypes() {
        return switch (this) {
            case STRING  -> Set.of("java.lang.String", "java.lang.CharSequence");
            case INTEGER -> Set.of("int", "java.lang.Integer", "long", "java.lang.Long",
                                   "java.lang.Number");
            case BOOLEAN -> Set.of("boolean", "java.lang.Boolean");
            case NUMBER  -> Set.of("double", "java.lang.Double", "float", "java.lang.Float",
                                   "java.math.BigDecimal", "java.lang.Number");
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

`ParameterType.scalarType()` provides build-time type mapping for the validator (§7) — it bridges module parameter types to the shared `ValueType` vocabulary. `ParameterType.parse()` retains its own parsing logic and `ParsedValue` wrapping; no delegation to `ValueType.parse()`. `ParsedValue` is the right model for module parameters — the sealed type hierarchy enables exhaustive pattern matching in `ParameterValidator`.

**Type checking layering:** `ParameterType.canAccept(ParameterType)` and `ValueType.accepts(String javaTypeName)` serve different layers and are not redundant. `canAccept()` validates inter-module type compatibility — can module A's INTEGER output feed module B's NUMBER parameter. `accepts()` validates YAML-to-Java compatibility at the deployment boundary — can a declared INTEGER map to an `int` field in a spec class. They are orthogonal: `canAccept` operates within the YAML type system, `accepts` bridges YAML types to Java types.

**Error context:** `ValueType.parse()` is context-free — it throws raw `NumberFormatException` or `IllegalArgumentException` on invalid input. Callers that have positional context (CSV row/column, YAML path) must catch and re-throw with context. `CsvParser.parseRow()` already follows this pattern; `TypedVariables.parse()` must wrap similarly with the variable name.

### 2. Shared name:type parser — `TypedName`

New record in `io.casehub.yaml.core.type`:

```java
public record TypedName(String name, ValueType type) {
    public TypedName {
        if (name == null || name.isBlank())
            throw new IllegalArgumentException("Variable name must not be blank");
    }

    public static TypedName parse(String raw) {
        int colon = raw.indexOf(':');
        if (colon < 0) return new TypedName(raw.trim(), ValueType.STRING);
        String name = raw.substring(0, colon).trim();
        String typePart = raw.substring(colon + 1).trim();
        if (typePart.isEmpty())
            throw new IllegalArgumentException(
                "Missing type after ':' in '" + raw + "'. Expected: STRING, INTEGER, BOOLEAN, NUMBER.");
        try {
            return new TypedName(name, ValueType.valueOf(typePart.toUpperCase(Locale.ROOT)));
        } catch (IllegalArgumentException e) {
            throw new IllegalArgumentException(
                "Unknown type '" + typePart + "' in '" + raw
                + "'. Expected: STRING, INTEGER, BOOLEAN, NUMBER.");
        }
    }
}
```

Used by `CsvParser.parseHeader()` and `TypedVariables.parse()`. `CsvParser.parseHeader()` retains its existing validation that columns must have explicit type annotations — it checks for a colon before calling `TypedName.parse()` and rejects untyped headers with `IllegalArgumentException`. This is an intentional behavioral difference: CSV headers require explicit types (existing enforced contract), while variable declarations default to STRING (ergonomic convenience for the common case).

### 3. Typed variable declarations — `TypedMap`

New record in `io.casehub.yaml.core.type`:

**Shared type schema interface — `TypedSchema`:**

New interface in `io.casehub.yaml.core.type`:

```java
public interface TypedSchema {
    ValueType typeOf(String name);
    Map<String, ValueType> schema();
}
```

Both `TypedMap` and `CsvDataSource` implement this interface. The build-time validator (§9) works with `TypedSchema` generically rather than branching on source type.

```java
public record TypedMap(Map<String, ValueType> schema, Map<String, Object> values) implements TypedSchema {
    public TypedMap {
        schema = Map.copyOf(schema);
        values = Map.copyOf(values);
    }
    @Override public ValueType typeOf(String name) { return schema.get(name); }
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
            try {
                values.put(tn.name(), tn.type().parse(String.valueOf(entry.getValue())));
            } catch (IllegalArgumentException e) {
                throw new IllegalArgumentException(
                    "Variable '" + tn.name() + "' (" + tn.type()
                    + "): invalid value '" + entry.getValue() + "'", e);
            }
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

**YAML parser pre-typing caveat:** `TypedVariables.parse()` uses `String.valueOf(entry.getValue())` to convert YAML-parsed values back to strings before re-parsing with `ValueType.parse()`. This roundtrip is lossy when the YAML parser applies type inference before Java receives the value — e.g., YAML 1.1 interprets `010` as octal 8, `yes` as boolean `true`. Declared types control the *output* type but cannot recover the *original literal* after parser inference. This is a known limitation. Full mitigation requires #428's YAML parsing standardisation (YAML 1.2 core schema or SnakeYAML's safe/failsafe constructor), which prevents parser inference at the source. For the common case (decimal integers, `true`/`false` booleans, unambiguous strings), the roundtrip is lossless.

### 4. CsvDataSource schema API

**Duplicate column detection:** `CsvParser.parseHeader()` must reject duplicate column names at parse time:

```java
// In CsvParser.parseHeader(), after building columns list:
Set<String> seen = new HashSet<>();
for (CsvColumn col : columns) {
    if (!seen.add(col.name()))
        throw new IllegalArgumentException(
            "Duplicate column name '" + col.name() + "' in CSV header.");
}
```

`CsvDataSource` implements `TypedSchema`:

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
                                  (a, b) -> { throw new IllegalStateException(
                                      "Duplicate column '" + a + "'"); },
                                  LinkedHashMap::new));
}
```

With the `parseHeader()` duplicate check, the `schema()` merge function should never fire — it's a defensive backstop.

### 5. resolveTyped — source-controlled container semantics

Add `allowContainerReturn()` default method to `ObjectVariableSource`:

```java
@FunctionalInterface
public interface ObjectVariableSource {
    Object resolve(String name);
    default boolean allowContainerReturn() { return true; }

    static ObjectVariableSource drillOnly(ObjectVariableSource source) {
        return new ObjectVariableSource() {
            @Override public Object resolve(String name) { return source.resolve(name); }
            @Override public boolean allowContainerReturn() { return false; }
        };
    }
}
```

One change in `VariableResolver.resolveTyped()`:

```java
// Current:
if (nextDot < 0) return root;

// New:
if (nextDot < 0) {
    if (!objSource.allowContainerReturn()
            && (root instanceof Map || root instanceof List)) {
        return null;
    }
    return root;
}
```

**Why source-controlled, not a global guard:** A global scalar-only guard would break runtime orchestration (#386), which explicitly designs `${result.step1}` to return a step result Map via `ObjectVariableSource`. The forEach row problem — `${each.region}` returning a row Map instead of falling through to the string key — is specific to the forEach context, not a universal property of typed resolution. The distinction belongs on the source: forEach rows are drill-only containers (the Map exists for field access, not as a value); runtime results are pass-through values (the Map IS the typed result).

**Effect:**
- `${each.region}` → drill-only source → row Map at root → null → resolveString → "us-east" ✓
- `${each.region.tier}` → drill-only source → row Map → drills "tier" → Integer 500 ✓
- `${var.batch_size}` → pass-through source → Integer 500, scalar → Integer 500 ✓
- `${result.step1}` → pass-through source (default) → step result Map → Map ✓ (runtime orchestration #386)

**Shared `drillFields` utility:** Extract the duplicate `drillFields(Map, String)` implementations from both `VariableSource` and `VariableResolver` into a shared package-private utility `FieldDriller` in `io.casehub.yaml.core.resolver`.

### 6. ObjectVariableSource registration

The dual-registration pattern — both `VariableSource` (string) and `ObjectVariableSource` (typed) for the same prefix — is how typed values flow through the pipeline. Apply it to every prefix that carries typed data.

**"each" prefix (ForEachExpander):** CSV iteration path (ForEachExpander line ~262), add `withObjectScope`:

```java
VariableResolver rowResolver = resolver
    .withScope("each", VariableSource.forEachContext(
        Map.of(as, rowKey, "index", String.valueOf(i)),
        Map.of(as, row)))
    .withObjectScope("each", ObjectVariableSource.drillOnly(
        name -> name.equals(as) ? row : null));
```

**"var" prefix (spec processors):** Wherever the VariableResolver is constructed with variable declarations (desiredstate processors, YAML spec loaders), register TypedMap as an ObjectVariableSource:

```java
TypedMap typedVars = TypedVariables.parse(rawVariables);

VariableResolver resolver = baseResolver
    .withScope("var", name -> {
        Object value = typedVars.values().get(name);
        return value != null ? value.toString() : null;
    })
    .withObjectScope("var", name -> typedVars.values().get(name));
```

Both sources registered for each prefix:
- **ObjectVariableSource** → used by `resolveTyped()` for sole references → typed values (e.g., `${var.batch_size}` → Integer 500)
- **VariableSource** → used by `resolveString()` for embedded references → string interpolation (e.g., `"size=${var.batch_size}"` → `"size=500"`)

The "each" source uses `drillOnly()` (container roots fall through to string); the "var" source uses the default (scalars pass through directly). This distinction is correct: forEach row Maps are containers for field access, while typed variables are direct scalar values.

**Why only the CSV path for "each":** The non-CSV `expand()` overload iterates over string values from `IterationGroup`. These are simple strings — there are no typed fields to drill into. Only CSV rows are `Map<String, Object>` with typed values, so only that path benefits from `ObjectVariableSource` registration.

### 7. Build-time type validation (desiredstate deployment processor)

New validation step in `YamlDesiredStateProcessor.validateForEach()`:

This is a new validation layer that complements the existing three-layer model from #260 (structural type check → output value validation → parameter value validation). The #260 layers validate inter-module `ParameterType` compatibility. This layer validates YAML-declared-type-to-Java-field compatibility for `${each.*}` and `${var.*}` references — a boundary the #260 layers don't cover because these references bypass module parameters. `${params.X}` references are already validated by the existing `ParameterType.canAccept()` layer.

For each `${each.X.field}` or `${var.X}` reference in a spec:
1. Trace to source via `TypedSchema`: variable declarations → `TypedMap.typeOf()`, CSV → `CsvDataSource.typeOf()`. Both implement `TypedSchema`, so the validator works generically without branching on source type.
2. Look up target spec field via Jandex (already available in the deployment processor)
3. Check: `valueType.accepts(javaTypeName)`
4. Error on mismatch with clear message:

```
ERROR test.yaml: node 'ingest' spec field 'batchSize' (int)
  references ${var.batch_size} declared as 'string' — type mismatch
```

### 8. Final conformance audit

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
| `yaml-core/type/TypedSchema.java` | New interface — shared type schema contract |
| `yaml-core/type/TypedMap.java` | New record — schema + typed values, implements TypedSchema |
| `yaml-core/type/TypedVariables.java` | New utility — variable declaration parser |
| `yaml-core/data/CsvColumnType.java` | **Deleted** — replaced by ValueType |
| `yaml-core/data/CsvColumn.java` | Updated — uses ValueType |
| `yaml-core/data/CsvParser.java` | Updated — uses TypedName.parse(), error-context wrapping |
| `yaml-core/data/CsvDataSource.java` | Updated — implements TypedSchema, add typeOf(), schema() |
| `yaml-core/module/ParameterType.java` | Updated — add scalarType() mapping |
| `yaml-core/resolver/ObjectVariableSource.java` | Updated — add allowContainerReturn(), drillOnly() |
| `yaml-core/resolver/VariableSource.java` | Updated — drillFields extracted to FieldDriller |
| `yaml-core/resolver/VariableResolver.java` | Updated — resolveTyped source-controlled container check, drillFields extracted to FieldDriller |
| `yaml-core/resolver/FieldDriller.java` | New utility — shared drillFields extracted from VariableSource/VariableResolver |
| `yaml-core/foreach/ForEachExpander.java` | Updated — withObjectScope (drillOnly) for CSV rows |
| `yaml-core/data/CsvParserTest.java` | Updated — fix type assertions |
| `yaml-core/foreach/ForEachExpanderTest.java` | Updated — typed value assertions |

Desiredstate (casehubio/desiredstate — separate repo, separate PRs):
| `yaml/deployment/YamlDesiredStateProcessor.java` | Build-time type validation via TypedSchema |

## References

**yaml-core (casehubio/platform):**
- `yaml-core/data/CsvColumnType.java` — existing type enum being replaced
- `yaml-core/module/ParameterType.java:7-8` — parallel type enum to unify with
- `yaml-core/resolver/VariableResolver.java:91-148` — resolveTyped method
- `yaml-core/resolver/VariableSource.java:39-66` — forEachContext with toString bug
- `yaml-core/resolver/ObjectVariableSource.java` — unused interface to activate + extend
- `yaml-core/foreach/ForEachExpander.java:255-280` — CSV forEach path

**Downstream consumers (casehubio/desiredstate — separate repo, separate PRs):**
- `yaml/deployment/YamlDesiredStateProcessor.java` — build-time type validation (§7 consumer)
- The spec defines the yaml-core API contract; desiredstate consumes it. Desiredstate PRs track separately and depend on the yaml-core changes landing first.

**Issues:**
- GitHub issue #429 — typed variable declarations
- GitHub issue #428 — YAML parsing standardisation (parser inference mitigation)
- GitHub issue #432 — block-level iteration: forEach and loop on YamlImport (extracted from this spec; #431 closed as duplicate)
