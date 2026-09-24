# yaml-core Type System Polish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #429 — YAML surface type system: typed variable declarations + build-time type checking
**Issue group:** #429, #432 (follow-up: block-level forEach/loop on YamlImport)

**Goal:** Unify yaml-core's three parallel type vocabularies into one, fix forEach type loss, add typed variable declarations, and enable build-time type checking.

**Architecture:** Extract `ValueType` enum as the shared scalar type vocabulary. Activate the unused `ObjectVariableSource`/`resolveTyped()` path with source-controlled container semantics (`allowContainerReturn`). Register dual sources (string + typed) for forEach CSV and typed variables. `TypedSchema` interface unifies schema queries across CsvDataSource and TypedMap.

**Tech Stack:** Java 21, JUnit 5, AssertJ, zero external dependencies (yaml-core is zero-dep)

## Global Constraints

- yaml-core must remain zero-dependency — pure Java only, no Quarkus, no CDI, no jackson
- All primitives must be thread-safe via `java.util.concurrent` — never `synchronized`
- All new public types go in `io.casehub.yaml.core.type` package
- Backward compatible for untyped YAML variables (default to STRING)
- CSV headers retain mandatory `name:TYPE` syntax (existing enforced contract)

---

## Batch 1: Type vocabulary foundation + CSV migration

### Task 1: ValueType enum, TypedName record, TypedSchema interface

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/type/ValueType.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/type/TypedName.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/type/TypedSchema.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/type/ValueTypeTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/type/TypedNameTest.java`

**Interfaces:**
- Produces: `ValueType.parse(String) → Object`, `ValueType.accepts(String) → boolean`, `ValueType.javaTypes() → Set<String>`
- Produces: `TypedName.parse(String) → TypedName`, `TypedName(String name, ValueType type)`
- Produces: `TypedSchema.typeOf(String) → ValueType`, `TypedSchema.schema() → Map<String, ValueType>`

- [ ] **Step 1: Write ValueType tests**

```java
package io.casehub.yaml.core.type;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class ValueTypeTest {

    @Test
    void parse_string_returns_same_value() {
        assertThat(ValueType.STRING.parse("hello")).isEqualTo("hello");
    }

    @Test
    void parse_integer_returns_int() {
        assertThat(ValueType.INTEGER.parse("8080")).isEqualTo(8080);
    }

    @Test
    void parse_boolean_true_via_truthiness() {
        assertThat(ValueType.BOOLEAN.parse("true")).isEqualTo(true);
        assertThat(ValueType.BOOLEAN.parse("yes")).isEqualTo(true);
        assertThat(ValueType.BOOLEAN.parse("1")).isEqualTo(true);
    }

    @Test
    void parse_boolean_false_via_truthiness() {
        assertThat(ValueType.BOOLEAN.parse("false")).isEqualTo(false);
        assertThat(ValueType.BOOLEAN.parse("no")).isEqualTo(false);
    }

    @Test
    void parse_number_returns_double() {
        assertThat(ValueType.NUMBER.parse("3.14")).isEqualTo(3.14);
    }

    @Test
    void parse_integer_invalid_throws() {
        assertThatThrownBy(() -> ValueType.INTEGER.parse("abc"))
                .isInstanceOf(NumberFormatException.class);
    }

    @Test
    void parse_number_invalid_throws() {
        assertThatThrownBy(() -> ValueType.NUMBER.parse("xyz"))
                .isInstanceOf(NumberFormatException.class);
    }

    @Test
    void accepts_integer_java_types() {
        assertThat(ValueType.INTEGER.accepts("int")).isTrue();
        assertThat(ValueType.INTEGER.accepts("java.lang.Integer")).isTrue();
        assertThat(ValueType.INTEGER.accepts("long")).isTrue();
        assertThat(ValueType.INTEGER.accepts("java.lang.Long")).isTrue();
        assertThat(ValueType.INTEGER.accepts("java.lang.Number")).isTrue();
        assertThat(ValueType.INTEGER.accepts("java.lang.String")).isFalse();
    }

    @Test
    void accepts_string_java_types() {
        assertThat(ValueType.STRING.accepts("java.lang.String")).isTrue();
        assertThat(ValueType.STRING.accepts("java.lang.CharSequence")).isTrue();
        assertThat(ValueType.STRING.accepts("int")).isFalse();
    }

    @Test
    void accepts_boolean_java_types() {
        assertThat(ValueType.BOOLEAN.accepts("boolean")).isTrue();
        assertThat(ValueType.BOOLEAN.accepts("java.lang.Boolean")).isTrue();
    }

    @Test
    void accepts_number_java_types() {
        assertThat(ValueType.NUMBER.accepts("double")).isTrue();
        assertThat(ValueType.NUMBER.accepts("java.lang.Double")).isTrue();
        assertThat(ValueType.NUMBER.accepts("float")).isTrue();
        assertThat(ValueType.NUMBER.accepts("java.math.BigDecimal")).isTrue();
        assertThat(ValueType.NUMBER.accepts("java.lang.Number")).isTrue();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ValueTypeTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — class does not exist

- [ ] **Step 3: Implement ValueType**

Create `yaml-core/src/main/java/io/casehub/yaml/core/type/ValueType.java`:

```java
package io.casehub.yaml.core.type;

import io.casehub.yaml.core.condition.Truthiness;
import java.util.Set;

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

- [ ] **Step 4: Run ValueType tests**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ValueTypeTest`
Expected: PASS

- [ ] **Step 5: Write TypedName tests**

```java
package io.casehub.yaml.core.type;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class TypedNameTest {

    @Test
    void parse_with_type_suffix() {
        TypedName tn = TypedName.parse("batch_size:integer");
        assertThat(tn.name()).isEqualTo("batch_size");
        assertThat(tn.type()).isEqualTo(ValueType.INTEGER);
    }

    @Test
    void parse_without_type_defaults_to_string() {
        TypedName tn = TypedName.parse("bucket");
        assertThat(tn.name()).isEqualTo("bucket");
        assertThat(tn.type()).isEqualTo(ValueType.STRING);
    }

    @Test
    void parse_trims_whitespace() {
        TypedName tn = TypedName.parse("  name : STRING  ");
        assertThat(tn.name()).isEqualTo("name");
        assertThat(tn.type()).isEqualTo(ValueType.STRING);
    }

    @Test
    void parse_case_insensitive_type() {
        assertThat(TypedName.parse("x:boolean").type()).isEqualTo(ValueType.BOOLEAN);
        assertThat(TypedName.parse("x:BOOLEAN").type()).isEqualTo(ValueType.BOOLEAN);
        assertThat(TypedName.parse("x:Boolean").type()).isEqualTo(ValueType.BOOLEAN);
    }

    @Test
    void parse_unknown_type_throws() {
        assertThatThrownBy(() -> TypedName.parse("x:BLOB"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("BLOB")
                .hasMessageContaining("STRING, INTEGER, BOOLEAN, NUMBER");
    }

    @Test
    void parse_empty_type_throws() {
        assertThatThrownBy(() -> TypedName.parse("x:"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("Missing type");
    }

    @Test
    void blank_name_throws() {
        assertThatThrownBy(() -> TypedName.parse(":INTEGER"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("blank");
    }

    @Test
    void all_four_types() {
        assertThat(TypedName.parse("a:string").type()).isEqualTo(ValueType.STRING);
        assertThat(TypedName.parse("b:integer").type()).isEqualTo(ValueType.INTEGER);
        assertThat(TypedName.parse("c:boolean").type()).isEqualTo(ValueType.BOOLEAN);
        assertThat(TypedName.parse("d:number").type()).isEqualTo(ValueType.NUMBER);
    }
}
```

- [ ] **Step 6: Implement TypedName and TypedSchema**

Create `yaml-core/src/main/java/io/casehub/yaml/core/type/TypedName.java`:

```java
package io.casehub.yaml.core.type;

import java.util.Locale;

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

Create `yaml-core/src/main/java/io/casehub/yaml/core/type/TypedSchema.java`:

```java
package io.casehub.yaml.core.type;

import java.util.Map;

public interface TypedSchema {
    ValueType typeOf(String name);
    Map<String, ValueType> schema();
}
```

- [ ] **Step 7: Run TypedName tests**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=TypedNameTest`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/type/
git add yaml-core/src/test/java/io/casehub/yaml/core/type/
git commit -m "feat(#429): ValueType enum, TypedName record, TypedSchema interface"
```

---

### Task 2: CSV migration to ValueType + CsvDataSource schema API

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/data/CsvColumn.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/data/CsvParser.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/data/CsvDataSource.java`
- Delete: `yaml-core/src/main/java/io/casehub/yaml/core/data/CsvColumnType.java` (use `ide_refactor_safe_delete`)
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/data/CsvParserTest.java`

**Interfaces:**
- Consumes: `ValueType` from Task 1, `TypedName.parse(String)` from Task 1, `TypedSchema` from Task 1
- Produces: `CsvDataSource implements TypedSchema`, `CsvDataSource.typeOf(String) → ValueType`, `CsvDataSource.schema() → Map<String, ValueType>`

- [ ] **Step 1: Write test for CsvDataSource.typeOf() and schema()**

Add to `CsvParserTest.java`:

```java
@Test
void typeOf_returns_declared_type() {
    String csv = "name:STRING,port:INTEGER,enabled:BOOLEAN\nweb,8080,true\n";
    CsvDataSource ds = CsvParser.parse("svc", csv);
    assertThat(ds.typeOf("port")).isEqualTo(ValueType.INTEGER);
    assertThat(ds.typeOf("enabled")).isEqualTo(ValueType.BOOLEAN);
    assertThat(ds.typeOf("name")).isEqualTo(ValueType.STRING);
    assertThat(ds.typeOf("missing")).isNull();
}

@Test
void schema_returns_column_type_map() {
    String csv = "name:STRING,port:INTEGER\nweb,8080\n";
    CsvDataSource ds = CsvParser.parse("svc", csv);
    assertThat(ds.schema()).containsEntry("name", ValueType.STRING)
                           .containsEntry("port", ValueType.INTEGER);
}

@Test
void duplicate_column_name_throws() {
    String csv = "name:STRING,name:INTEGER\nweb,8080\n";
    assertThatThrownBy(() -> CsvParser.parse("dup", csv))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("Duplicate column name")
            .hasMessageContaining("name");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=CsvParserTest#typeOf_returns_declared_type+schema_returns_column_type_map+duplicate_column_name_throws`
Expected: FAIL — methods don't exist, ValueType not imported

- [ ] **Step 3: Update CsvColumn to use ValueType**

Change `CsvColumn.java`:
```java
package io.casehub.yaml.core.data;

import io.casehub.yaml.core.type.ValueType;

public record CsvColumn(String name, ValueType type) {}
```

- [ ] **Step 4: Update CsvParser to use TypedName and ValueType**

Replace `CsvParser.parseHeader()` to use `TypedName.parse()` internally while retaining the mandatory-type-annotation check. Replace all `CsvColumnType` references with `ValueType`. Add duplicate column detection. Update `parseRow` to call `col.type().parse()` with context wrapping.

Key changes in `parseHeader`:
```java
private static List<CsvColumn> parseHeader(String headerLine) {
    String[] parts = headerLine.split(",");
    List<CsvColumn> columns = new ArrayList<>();
    Set<String> seen = new HashSet<>();
    for (String part : parts) {
        String trimmed = part.trim();
        int colon = trimmed.indexOf(':');
        if (colon < 0) {
            throw new IllegalArgumentException(
                    "Header column '" + trimmed
                    + "' must use format columnName:TYPE (e.g. name:STRING).");
        }
        TypedName tn = TypedName.parse(trimmed);
        if (!seen.add(tn.name())) {
            throw new IllegalArgumentException(
                    "Duplicate column name '" + tn.name() + "' in CSV header.");
        }
        columns.add(new CsvColumn(tn.name(), tn.type()));
    }
    return columns;
}
```

Key changes in `parseRow` — replace `col.type().parse(value, rowIndex, col.name())` with context-wrapping:
```java
try {
    row.put(col.name(), col.type().parse(value));
} catch (IllegalArgumentException | NumberFormatException e) {
    throw new IllegalArgumentException(
            "CSV row " + rowIndex + ", column '" + col.name()
            + "': expected " + col.type() + ", got '" + value + "'", e);
}
```

- [ ] **Step 5: Update CsvDataSource to implement TypedSchema**

```java
package io.casehub.yaml.core.data;

import io.casehub.yaml.core.type.TypedSchema;
import io.casehub.yaml.core.type.ValueType;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

public record CsvDataSource(String name, List<CsvColumn> columns,
                             List<Map<String, Object>> rows) implements TypedSchema {

    @Override
    public ValueType typeOf(String columnName) {
        return columns.stream()
                .filter(c -> c.name().equals(columnName))
                .map(CsvColumn::type)
                .findFirst().orElse(null);
    }

    @Override
    public Map<String, ValueType> schema() {
        return columns.stream()
                .collect(Collectors.toMap(CsvColumn::name, CsvColumn::type,
                                          (a, b) -> a, LinkedHashMap::new));
    }

    // existing fromDataBlock unchanged
}
```

- [ ] **Step 6: Update CsvParserTest — replace CsvColumnType with ValueType**

Use `ide_search_text` to find all `CsvColumnType` references in `CsvParserTest.java`. Replace with `ValueType`:
- `CsvColumnType.STRING` → `ValueType.STRING`
- `CsvColumnType.INTEGER` → `ValueType.INTEGER`
- Import `io.casehub.yaml.core.type.ValueType` instead of `io.casehub.yaml.core.data.CsvColumnType`

- [ ] **Step 7: Delete CsvColumnType**

Use `ide_refactor_safe_delete` on `CsvColumnType.java`. If safe delete reports remaining usages, fix them first.

- [ ] **Step 8: Run all CSV tests**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=CsvParserTest`
Expected: ALL PASS (existing tests work with ValueType, new tests pass)

- [ ] **Step 9: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/data/
git add yaml-core/src/test/java/io/casehub/yaml/core/data/
git commit -m "feat(#429): migrate CSV to ValueType, add schema API, delete CsvColumnType"
```

---

## Batch 2: Typed resolution pipeline

### Task 3: FieldDriller + ObjectVariableSource.allowContainerReturn + resolveTyped fix

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/FieldDriller.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/ObjectVariableSource.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableSource.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/resolver/ObjectVariableSourceTest.java`

**Interfaces:**
- Consumes: none from prior tasks
- Produces: `ObjectVariableSource.allowContainerReturn() → boolean`, `ObjectVariableSource.drillOnly(ObjectVariableSource) → ObjectVariableSource`, `FieldDriller.drill(Map, String) → Object`

- [ ] **Step 1: Write tests for drillOnly container semantics**

Add to `ObjectVariableSourceTest.java`:

```java
@Test
void drillOnly_bareMapReference_fallsThroughToString() {
    Map<String, Object> row = Map.of("name", "Alice", "port", 8080);
    ObjectVariableSource objSource = ObjectVariableSource.drillOnly(
            name -> "member".equals(name) ? row : null);
    VariableSource strSource = name -> "member".equals(name) ? "Alice" : null;
    VariableResolver resolver = new VariableResolver(Map.of("each", strSource), Set.of())
            .withObjectScope("each", objSource);

    // Bare alias → drillOnly returns null for Map root → string fallback
    Object bare = resolver.resolve("${each.member}");
    assertThat(bare).isEqualTo("Alice");
}

@Test
void drillOnly_fieldAccess_returnsTypedValue() {
    Map<String, Object> row = Map.of("name", "Alice", "port", 8080);
    ObjectVariableSource objSource = ObjectVariableSource.drillOnly(
            name -> "member".equals(name) ? row : null);
    VariableResolver resolver = new VariableResolver(Map.of(), Set.of())
            .withObjectScope("each", objSource);

    Object port = resolver.resolve("${each.member.port}");
    assertThat(port).isEqualTo(8080);
    assertThat(port).isInstanceOf(Integer.class);
}

@Test
void defaultSource_bareMapReference_returnsMap() {
    Map<String, Object> stepResult = Map.of("price", 42.5);
    ObjectVariableSource source = name -> "step".equals(name) ? stepResult : null;
    VariableResolver resolver = new VariableResolver(Map.of(), Set.of())
            .withObjectScope("result", source);

    // Default allowContainerReturn=true → returns the Map
    Object resolved = resolver.resolve("${result.step}");
    assertThat(resolved).isEqualTo(stepResult);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ObjectVariableSourceTest#drillOnly_bareMapReference_fallsThroughToString+drillOnly_fieldAccess_returnsTypedValue`
Expected: FAIL — `drillOnly` method doesn't exist

- [ ] **Step 3: Create FieldDriller utility**

Create `yaml-core/src/main/java/io/casehub/yaml/core/resolver/FieldDriller.java`:

```java
package io.casehub.yaml.core.resolver;

import java.util.Map;

final class FieldDriller {
    private FieldDriller() {}

    @SuppressWarnings("unchecked")
    static Object drill(Map<String, Object> map, String dotPath) {
        Object current = map;
        for (String part : dotPath.split("\\.")) {
            if (current instanceof Map<?, ?> m) {
                current = m.get(part);
            } else {
                return null;
            }
        }
        return current;
    }
}
```

- [ ] **Step 4: Add allowContainerReturn + drillOnly to ObjectVariableSource**

Update `ObjectVariableSource.java`:

```java
package io.casehub.yaml.core.resolver;

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

- [ ] **Step 5: Update VariableResolver.resolveTyped() — container check + FieldDriller**

In `VariableResolver.java`, update `resolveTyped()`:

Change:
```java
if (nextDot < 0) return root;
```
To:
```java
if (nextDot < 0) {
    if (!objSource.allowContainerReturn()
            && (root instanceof Map || root instanceof List)) {
        return null;
    }
    return root;
}
```

Replace the private `drillFields` method with `FieldDriller.drill()`:
```java
// Replace:
return drillFields((Map<String, Object>) map, fieldPath);
// With:
return FieldDriller.drill((Map<String, Object>) map, fieldPath);
```

- [ ] **Step 6: Update VariableSource.drillFields to use FieldDriller**

In `VariableSource.java`, replace the private `drillFields` method body to delegate:
```java
private static Object drillFields(java.util.Map<String, Object> map, String dotPath) {
    return FieldDriller.drill(map, dotPath);
}
```

Note: `FieldDriller` is package-private — both `VariableSource` and `VariableResolver` are in the same `resolver` package.

- [ ] **Step 7: Run all resolver tests**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ObjectVariableSourceTest,VariableResolverTest`
Expected: ALL PASS — existing tests unchanged (default `allowContainerReturn=true`), new drillOnly tests pass

- [ ] **Step 8: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/resolver/
git add yaml-core/src/test/java/io/casehub/yaml/core/resolver/
git commit -m "feat(#429): source-controlled container semantics, FieldDriller extraction"
```

---

### Task 4: ForEachExpander withObjectScope for CSV rows

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ForEachExpander.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/foreach/ForEachExpanderTest.java`

**Interfaces:**
- Consumes: `ObjectVariableSource.drillOnly()` from Task 3, `VariableResolver.withObjectScope()` from existing API
- Produces: typed values in expanded spec maps (Integer, Boolean, Double instead of String)

- [ ] **Step 1: Fix existing test to assert typed values**

Update `ForEachExpanderTest.csvDataSource_typedColumns_resolveCorrectly` (line 662):

```java
@Test
void csvDataSource_typedColumns_resolveCorrectly() {
    var csv = io.casehub.yaml.core.data.CsvParser.parse("envs",
            "name:STRING,port:INTEGER,production:BOOLEAN\nstaging,8080,false\nprod,443,true");
    var dataSources = Map.of("envs", csv);
    var groups      = Map.of("envs", new IterationGroup("env", List.of()));
    var elements    = new LinkedHashMap<String, TestElement>();
    elements.put("deploy", new TestElement("deploy",
            Map.of("host", "${each.env.name}", "p", "${each.env.port}",
                   "isProd", "${each.env.production}"),
            new ForEachDirective.GroupRef("envs"), null));

    var result = ForEachExpander.expand(elements, groups, dataSources,
            resolver, adapter, 1000);

    assertThat(result.elements()).hasSize(2);
    // NOW typed: Integer and Boolean, not String
    assertThat(result.elements().get("deploy.staging").spec())
            .containsEntry("host", "staging")
            .containsEntry("p", 8080)
            .containsEntry("isProd", false);
    assertThat(result.elements().get("deploy.prod").spec())
            .containsEntry("host", "prod")
            .containsEntry("p", 443)
            .containsEntry("isProd", true);
}
```

- [ ] **Step 2: Add test for bare alias in CSV context falls through to string**

```java
@Test
void csvDataSource_bareAlias_resolvesToStringKey() {
    var csv = io.casehub.yaml.core.data.CsvParser.parse("members",
            "name:STRING,role:STRING\nAlice,Developer\nBob,Viewer");
    var dataSources = Map.of("members", csv);
    var groups      = Map.of("members", new IterationGroup("member", List.of()));
    var elements    = new LinkedHashMap<String, TestElement>();
    elements.put("greet", new TestElement("greet",
            Map.of("label", "${each.member}"),
            new ForEachDirective.GroupRef("members"), null));

    var result = ForEachExpander.expand(elements, groups, dataSources,
            resolver, adapter, 1000);

    // Bare ${each.member} returns string key, not the row Map
    assertThat(result.elements().get("greet.Alice").spec())
            .containsEntry("label", "Alice");
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ForEachExpanderTest#csvDataSource_typedColumns_resolveCorrectly+csvDataSource_bareAlias_resolvesToStringKey`
Expected: FAIL — typed values return as strings ("8080" not 8080)

- [ ] **Step 4: Add withObjectScope to ForEachExpander CSV path**

In `ForEachExpander.java`, locate the CSV iteration block (the `if (isCsv)` branch around line 255). Change the resolver construction:

```java
// Current:
VariableResolver rowResolver = resolver.withScope("each",
        io.casehub.yaml.core.resolver.VariableSource.forEachContext(
                Map.of(as, rowKey, "index", String.valueOf(i)),
                Map.of(as, row)));

// New — add withObjectScope:
VariableResolver rowResolver = resolver.withScope("each",
        io.casehub.yaml.core.resolver.VariableSource.forEachContext(
                Map.of(as, rowKey, "index", String.valueOf(i)),
                Map.of(as, row)))
        .withObjectScope("each", io.casehub.yaml.core.resolver.ObjectVariableSource.drillOnly(
                name -> name.equals(as) ? row : null));
```

- [ ] **Step 5: Run forEach tests**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ForEachExpanderTest`
Expected: ALL PASS — typed values preserved, bare aliases fall through, existing tests unchanged

- [ ] **Step 6: Run full yaml-core test suite**

Run: `mvn --batch-mode test -pl yaml-core`
Expected: ALL PASS

- [ ] **Step 7: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/foreach/ForEachExpander.java
git add yaml-core/src/test/java/io/casehub/yaml/core/foreach/ForEachExpanderTest.java
git commit -m "feat(#429): ForEachExpander preserves typed values from CSV rows"
```

---

## Batch 3: Typed variables + integration

### Task 5: TypedMap + TypedVariables + ParameterType.scalarType()

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/type/TypedMap.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/type/TypedVariables.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterType.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/type/TypedVariablesTest.java`

**Interfaces:**
- Consumes: `ValueType` from Task 1, `TypedName.parse()` from Task 1, `TypedSchema` from Task 1
- Produces: `TypedMap implements TypedSchema`, `TypedVariables.parse(Map) → TypedMap`, `ParameterType.scalarType() → ValueType`

- [ ] **Step 1: Write TypedVariables tests**

```java
package io.casehub.yaml.core.type;

import org.junit.jupiter.api.Test;
import java.util.LinkedHashMap;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class TypedVariablesTest {

    @Test
    void parse_typed_variables() {
        var raw = new LinkedHashMap<String, Object>();
        raw.put("batch_size:integer", 500);
        raw.put("bucket", "prod");
        raw.put("enabled:boolean", true);
        raw.put("ratio:number", 3.14);

        TypedMap result = TypedVariables.parse(raw);

        assertThat(result.typeOf("batch_size")).isEqualTo(ValueType.INTEGER);
        assertThat(result.typeOf("bucket")).isEqualTo(ValueType.STRING);
        assertThat(result.typeOf("enabled")).isEqualTo(ValueType.BOOLEAN);
        assertThat(result.typeOf("ratio")).isEqualTo(ValueType.NUMBER);

        assertThat(result.values().get("batch_size")).isEqualTo(500);
        assertThat(result.values().get("bucket")).isEqualTo("prod");
        assertThat(result.values().get("enabled")).isEqualTo(true);
        assertThat(result.values().get("ratio")).isEqualTo(3.14);
    }

    @Test
    void parse_untyped_defaults_to_string() {
        TypedMap result = TypedVariables.parse(Map.of("name", "hello"));

        assertThat(result.typeOf("name")).isEqualTo(ValueType.STRING);
        assertThat(result.values().get("name")).isEqualTo("hello");
    }

    @Test
    void parse_invalid_value_includes_variable_name() {
        var raw = new LinkedHashMap<String, Object>();
        raw.put("count:integer", "not-a-number");

        assertThatThrownBy(() -> TypedVariables.parse(raw))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("count")
                .hasMessageContaining("INTEGER")
                .hasMessageContaining("not-a-number");
    }

    @Test
    void parse_empty_map_returns_empty() {
        TypedMap result = TypedVariables.parse(Map.of());
        assertThat(result.schema()).isEmpty();
        assertThat(result.values()).isEmpty();
    }

    @Test
    void schema_implements_TypedSchema() {
        TypedMap result = TypedVariables.parse(Map.of("x:integer", 42));
        assertThat(result).isInstanceOf(TypedSchema.class);
        assertThat(result.schema()).containsEntry("x", ValueType.INTEGER);
    }

    @Test
    void values_are_unmodifiable() {
        TypedMap result = TypedVariables.parse(Map.of("x", "hello"));
        assertThatThrownBy(() -> result.values().put("y", "world"))
                .isInstanceOf(UnsupportedOperationException.class);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=TypedVariablesTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — classes don't exist

- [ ] **Step 3: Implement TypedMap**

Create `yaml-core/src/main/java/io/casehub/yaml/core/type/TypedMap.java`:

```java
package io.casehub.yaml.core.type;

import java.util.Map;

public record TypedMap(Map<String, ValueType> schema, Map<String, Object> values) implements TypedSchema {
    public TypedMap {
        schema = Map.copyOf(schema);
        values = Map.copyOf(values);
    }

    @Override
    public ValueType typeOf(String name) { return schema.get(name); }
}
```

- [ ] **Step 4: Implement TypedVariables**

Create `yaml-core/src/main/java/io/casehub/yaml/core/type/TypedVariables.java`:

```java
package io.casehub.yaml.core.type;

import java.util.LinkedHashMap;
import java.util.Map;

public final class TypedVariables {

    private TypedVariables() {}

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

- [ ] **Step 5: Run TypedVariables tests**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=TypedVariablesTest`
Expected: ALL PASS

- [ ] **Step 6: Add ParameterType.scalarType()**

Add method to `ParameterType.java` using `ide_insert_member`:

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

Add import: `import io.casehub.yaml.core.type.ValueType;`

- [ ] **Step 7: Run full yaml-core test suite**

Run: `mvn --batch-mode test -pl yaml-core`
Expected: ALL PASS

- [ ] **Step 8: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/type/TypedMap.java
git add yaml-core/src/main/java/io/casehub/yaml/core/type/TypedVariables.java
git add yaml-core/src/test/java/io/casehub/yaml/core/type/TypedVariablesTest.java
git add yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterType.java
git commit -m "feat(#429): TypedMap, TypedVariables, ParameterType.scalarType()"
```

---

### Task 6: Full build + conformance audit

**Files:**
- No new files — audit only

**Interfaces:**
- Consumes: all prior tasks
- Produces: follow-up issues for any gaps found

- [ ] **Step 1: Run full platform build**

Run: `mvn --batch-mode install`
Expected: ALL PASS — no downstream modules broken by CsvColumnType deletion or API changes

- [ ] **Step 2: Check for remaining CsvColumnType references**

Use `ide_search_text` to search for `CsvColumnType` across the entire platform project. Expected: zero Java hits (only docs/specs may reference the old name).

- [ ] **Step 3: Verify no toString() on typed values in resolution paths**

Use `ide_search_text` to search for `.toString()` in `VariableSource.java` and `VariableResolver.java`. Check that the `forEachContext` method's `.toString()` call is only reached for embedded references (non-sole), never for sole references that should preserve types.

- [ ] **Step 4: Verify dual-registration pattern consistency**

Search for all `withObjectScope` calls. Verify that every prefix registering an ObjectVariableSource also has a corresponding `withScope` for string fallback.

- [ ] **Step 5: Check CorpusVariableSource compatibility**

Verify `CorpusVariableSource` still works with the new `allowContainerReturn()` default. It uses the default (`true`), so existing tests should pass unchanged.

Run: `mvn --batch-mode test -pl simulation-config`
Expected: PASS

- [ ] **Step 6: File follow-up issues for any gaps found**

If the audit finds:
- Type safety gaps → file as issue
- Duplicate resolution paths → file as issue
- Non-normalised entry points → file as issue
- Expansion asymmetries → already tracked in #432

- [ ] **Step 7: Final commit**

```bash
git add -A
git commit -m "chore(#429): conformance audit — yaml-core type system polish complete"
```

---

## References

- [2026-09-24-yaml-core-type-system-polish-design.md] — design spec this plan implements
- [yaml-core/data/CsvColumnType.java:5-46] — existing type enum being replaced
- [yaml-core/data/CsvColumn.java:3] — record to update
- [yaml-core/data/CsvParser.java:35-59] — header parsing to update
- [yaml-core/data/CsvDataSource.java:6-20] — record to extend with TypedSchema
- [yaml-core/module/ParameterType.java:7-41] — parallel type enum to bridge
- [yaml-core/resolver/ObjectVariableSource.java:1-6] — interface to extend
- [yaml-core/resolver/VariableResolver.java:91-148] — resolveTyped method to update
- [yaml-core/resolver/VariableSource.java:39-86] — forEachContext + drillFields
- [yaml-core/foreach/ForEachExpander.java:255-280] — CSV forEach path to fix
- [yaml-core/test: CsvParserTest, ForEachExpanderTest, ObjectVariableSourceTest] — tests to update
- [simulation-config/CorpusVariableSource.java] — existing ObjectVariableSource to verify
- [GitHub #429] — typed variable declarations
- [GitHub #432] — block-level forEach/loop (follow-up)
