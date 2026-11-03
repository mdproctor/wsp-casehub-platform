# Playbook Variable Declarations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #703 — feat: playbook variable declarations — vars:, params:, and typed variable context
**Issue group:** #703

**Goal:** Add `vars:` and `params:` sections to playbooks, enabling typed variable declarations with constraint validation, and wire them through the compilation, execution, and test pipelines.

**Architecture:** Extends the existing `TypedName`/`TypedVariables` infrastructure from #429 to accept domain types as opaque labels alongside scalar `ValueType`s. A new `PlaybookVariableParser` in yaml-core parses `vars:` and `params:` from the content map. `PlaybookVariableContext` in playbook-compiler wraps the parsed result and builds a `VariableResolver`. The compiler, `RunPlaybookPlugin`, and `YamlTestExecutor` all consume the new variable context.

**Tech Stack:** Java 21, yaml-core (zero-dep), playbook-compiler (SWF SDK), yaml-step-runtime (Walker, plugins), yaml-test-core, JUnit 5, AssertJ

## Global Constraints

- yaml-core must remain zero-dependency and J2CL-safe
- yaml-plugin-api must remain zero-dependency
- Domain types are opaque labels — no classpath resolution or Jackson deserialization
- Variable references use prefix-based resolution: `${var.name}`, `${params.name}`
- Constraint model reuses `YamlModuleParameter` and `ParameterValidator`

---

## Batch 1: TypedName and TypedMap extension — domain type support

### Task 1: Extend TypedName to accept domain types

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/type/TypedName.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/type/TypedNameTest.java`

**Interfaces:**
- Produces: `TypedName(String name, String typeName, ValueType scalarType)` with `boolean isScalar()`, `static TypedName parse(String raw)`

- [ ] **Step 1: Write failing tests for domain type parsing**

Add tests to `TypedNameTest.java`:

```java
@Test
void parse_domain_type_has_null_scalarType() {
    TypedName tn = TypedName.parse("config:AgentSessionConfig");
    assertThat(tn.name()).isEqualTo("config");
    assertThat(tn.typeName()).isEqualTo("AgentSessionConfig");
    assertThat(tn.scalarType()).isNull();
    assertThat(tn.isScalar()).isFalse();
}

@Test
void parse_scalar_type_populates_both_fields() {
    TypedName tn = TypedName.parse("count:integer");
    assertThat(tn.name()).isEqualTo("count");
    assertThat(tn.typeName()).isEqualTo("integer");
    assertThat(tn.scalarType()).isEqualTo(ValueType.INTEGER);
    assertThat(tn.isScalar()).isTrue();
}

@Test
void parse_untyped_defaults_to_string_with_typeName() {
    TypedName tn = TypedName.parse("bucket");
    assertThat(tn.name()).isEqualTo("bucket");
    assertThat(tn.typeName()).isEqualTo("string");
    assertThat(tn.scalarType()).isEqualTo(ValueType.STRING);
    assertThat(tn.isScalar()).isTrue();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=TypedNameTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation failure — `typeName()`, `scalarType()`, `isScalar()` don't exist

- [ ] **Step 3: Implement TypedName extension**

Replace the `TypedName` record with:

```java
package io.casehub.yaml.core.type;

import java.util.Locale;

public record TypedName(String name, String typeName, ValueType scalarType) {
    public TypedName {
        if (name == null || name.isBlank())
            throw new IllegalArgumentException("Variable name must not be blank");
        if (typeName == null || typeName.isBlank())
            throw new IllegalArgumentException("Type name must not be blank");
    }

    public boolean isScalar() { return scalarType != null; }

    public static TypedName parse(String raw) {
        int colon = raw.indexOf(':');
        if (colon < 0) return new TypedName(raw.trim(), "string", ValueType.STRING);
        String name = raw.substring(0, colon).trim();
        String typePart = raw.substring(colon + 1).trim();
        if (typePart.isEmpty())
            throw new IllegalArgumentException(
                "Missing type after ':' in '" + raw + "'.");
        if (name.isBlank())
            throw new IllegalArgumentException("Variable name must not be blank");
        ValueType scalar = ValueType.fromString(typePart);
        return new TypedName(name, typePart, scalar);
    }
}
```

- [ ] **Step 4: Update existing tests to use new accessors**

In `TypedNameTest.java`, rename all `.type()` references to `.scalarType()`:

- `tn.type()` → `tn.scalarType()` (8 occurrences)
- Update `parse_unknown_type_throws` — this test previously expected an exception for `"x:BLOB"`. Now `BLOB` is a valid domain type. Change the test to verify domain type behavior instead:

```java
@Test
void parse_unknown_scalar_becomes_domain_type() {
    TypedName tn = TypedName.parse("x:BLOB");
    assertThat(tn.name()).isEqualTo("x");
    assertThat(tn.typeName()).isEqualTo("BLOB");
    assertThat(tn.scalarType()).isNull();
    assertThat(tn.isScalar()).isFalse();
}
```

- [ ] **Step 5: Update CsvParser to use scalarType()**

In `yaml-core/src/main/java/io/casehub/yaml/core/data/CsvParser.java` line 51, change:
```java
columns.add(new CsvColumn(tn.name(), tn.type()));
```
to:
```java
if (tn.scalarType() == null) {
    throw new IllegalArgumentException(
        "CSV column '" + tn.name() + "' must use a scalar type (STRING, INTEGER, BOOLEAN, NUMBER), not '" + tn.typeName() + "'.");
}
columns.add(new CsvColumn(tn.name(), tn.scalarType()));
```

- [ ] **Step 6: Update TypedVariables to use scalarType()**

In `yaml-core/src/main/java/io/casehub/yaml/core/type/TypedVariables.java` lines 15-21, change `.type()` to `.scalarType()` and add null check. The full method is updated in Task 2.

- [ ] **Step 7: Run all yaml-core tests**

Run: `mvn --batch-mode test -pl yaml-core`
Expected: all tests pass

- [ ] **Step 8: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/type/TypedName.java yaml-core/src/test/java/io/casehub/yaml/core/type/TypedNameTest.java yaml-core/src/main/java/io/casehub/yaml/core/data/CsvParser.java yaml-core/src/main/java/io/casehub/yaml/core/type/TypedVariables.java
git commit -m "feat(#703): extend TypedName to accept domain types as opaque labels

TypedName now holds typeName (always set) and nullable scalarType.
Domain types like AgentSessionConfig are accepted — scalarType is null.
CsvParser rejects non-scalar types with a clear error message.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: Extend TypedMap and TypedVariables for domain types

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/type/TypedMap.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/type/TypedVariables.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/type/TypedVariablesTest.java`

**Interfaces:**
- Consumes: `TypedName(name, typeName, scalarType)` from Task 1
- Produces: `TypedMap(schema, values, domainTypes)` with backward-compat 2-arg constructor; `TypedVariables.parse()` handles domain types

- [ ] **Step 1: Write failing tests for domain type variables**

Add tests to `TypedVariablesTest.java`:

```java
@Test
void parse_domain_type_stores_value_as_is() {
    var raw = new LinkedHashMap<String, Object>();
    raw.put("config:AgentSessionConfig", Map.of("model", "claude-3", "timeout", "30s"));

    TypedMap result = TypedVariables.parse(raw);

    assertThat(result.domainTypes()).containsEntry("config", "AgentSessionConfig");
    assertThat(result.typeOf("config")).isNull();
    assertThat(result.values().get("config")).isInstanceOf(Map.class);
}

@Test
void parse_mixed_scalar_and_domain_types() {
    var raw = new LinkedHashMap<String, Object>();
    raw.put("count:integer", 42);
    raw.put("config:AgentSessionConfig", Map.of("model", "opus"));

    TypedMap result = TypedVariables.parse(raw);

    assertThat(result.schema()).containsEntry("count", ValueType.INTEGER);
    assertThat(result.domainTypes()).containsEntry("config", "AgentSessionConfig");
    assertThat(result.values()).containsKeys("count", "config");
}

@Test
void parse_domain_type_with_null_value_stores_null() {
    var raw = new LinkedHashMap<String, Object>();
    raw.put("result:AgentInvocationResult", null);

    TypedMap result = TypedVariables.parse(raw);

    assertThat(result.domainTypes()).containsEntry("result", "AgentInvocationResult");
    assertThat(result.values().get("result")).isNull();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=TypedVariablesTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation failure — `domainTypes()` doesn't exist

- [ ] **Step 3: Extend TypedMap with domainTypes field**

Replace the `TypedMap` record:

```java
package io.casehub.yaml.core.type;

import java.util.Map;

public record TypedMap(Map<String, ValueType> schema,
                       Map<String, Object> values,
                       Map<String, String> domainTypes) implements TypedSchema {
    public TypedMap {
        schema = Map.copyOf(schema);
        values = Map.copyOf(values);
        domainTypes = domainTypes != null ? Map.copyOf(domainTypes) : Map.of();
    }

    public TypedMap(Map<String, ValueType> schema, Map<String, Object> values) {
        this(schema, values, Map.of());
    }

    @Override
    public ValueType typeOf(String name) { return schema.get(name); }
}
```

- [ ] **Step 4: Update TypedVariables.parse() for domain types**

Replace the `parse` method:

```java
public static TypedMap parse(Map<String, Object> rawVariables) {
    var schema = new LinkedHashMap<String, ValueType>();
    var domainTypes = new LinkedHashMap<String, String>();
    var values = new LinkedHashMap<String, Object>();
    for (var entry : rawVariables.entrySet()) {
        TypedName tn = TypedName.parse(entry.getKey());
        Object raw = entry.getValue();
        if (tn.isScalar()) {
            schema.put(tn.name(), tn.scalarType());
            if (raw == null || tn.scalarType().validate(raw)) {
                values.put(tn.name(), raw);
            } else {
                try {
                    values.put(tn.name(), tn.scalarType().parse(String.valueOf(raw)));
                } catch (IllegalArgumentException e) {
                    throw new IllegalArgumentException(
                            "Variable '" + tn.name() + "' (" + tn.scalarType()
                            + "): invalid value '" + raw + "'", e);
                }
            }
        } else {
            domainTypes.put(tn.name(), tn.typeName());
            values.put(tn.name(), raw);
        }
    }
    return new TypedMap(Map.copyOf(schema), Map.copyOf(values), Map.copyOf(domainTypes));
}
```

- [ ] **Step 5: Run all yaml-core tests**

Run: `mvn --batch-mode test -pl yaml-core`
Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/type/TypedMap.java yaml-core/src/main/java/io/casehub/yaml/core/type/TypedVariables.java yaml-core/src/test/java/io/casehub/yaml/core/type/TypedVariablesTest.java
git commit -m "feat(#703): extend TypedMap/TypedVariables for domain types

TypedMap gains domainTypes field. TypedVariables.parse() stores domain
type values as-is with type name as metadata. Backward-compat 2-arg
constructor preserved.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 2: PlaybookVariableParser — vars: and params: parsing

### Task 3: Implement PlaybookVariableParser

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/playbook/PlaybookVariableParser.java`
- Create: `yaml-core/src/test/java/io/casehub/yaml/core/playbook/PlaybookVariableParserTest.java`

**Interfaces:**
- Consumes: `TypedName.parse()`, `TypedVariables.parse()`, `YamlModuleParameter.builder()` from Tasks 1-2
- Produces: `PlaybookVariableParser.ParsedVariables(params, vars)` with `static ParsedVariables parse(Map<String, Object> content)`

- [ ] **Step 1: Write failing tests for vars: parsing**

Create `PlaybookVariableParserTest.java`:

```java
package io.casehub.yaml.core.playbook;

import io.casehub.yaml.core.type.ValueType;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class PlaybookVariableParserTest {

    @Test
    void parse_vars_typed_scalars() {
        var vars = new LinkedHashMap<String, Object>();
        vars.put("retryCount:integer", 0);
        vars.put("threshold:number", 0.85);
        var content = Map.<String, Object>of("vars", vars);

        var result = PlaybookVariableParser.parse(content);

        assertThat(result.vars().typeOf("retryCount")).isEqualTo(ValueType.INTEGER);
        assertThat(result.vars().values().get("retryCount")).isEqualTo(0);
        assertThat(result.vars().typeOf("threshold")).isEqualTo(ValueType.NUMBER);
        assertThat(result.vars().values().get("threshold")).isEqualTo(0.85);
    }

    @Test
    void parse_vars_inferred_types() {
        var vars = new LinkedHashMap<String, Object>();
        vars.put("count", 42);
        vars.put("name", "hello");
        vars.put("active", true);
        var content = Map.<String, Object>of("vars", vars);

        var result = PlaybookVariableParser.parse(content);

        assertThat(result.vars().typeOf("count")).isEqualTo(ValueType.INTEGER);
        assertThat(result.vars().typeOf("name")).isEqualTo(ValueType.STRING);
        assertThat(result.vars().typeOf("active")).isEqualTo(ValueType.BOOLEAN);
    }

    @Test
    void parse_vars_domain_type() {
        var vars = new LinkedHashMap<String, Object>();
        vars.put("config:AgentSessionConfig", Map.of("model", "claude-3"));
        var content = Map.<String, Object>of("vars", vars);

        var result = PlaybookVariableParser.parse(content);

        assertThat(result.vars().domainTypes()).containsEntry("config", "AgentSessionConfig");
        assertThat(result.vars().values().get("config")).isInstanceOf(Map.class);
    }

    @Test
    void parse_empty_content_returns_empty() {
        var result = PlaybookVariableParser.parse(Map.of());

        assertThat(result.params()).isEmpty();
        assertThat(result.vars().values()).isEmpty();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=PlaybookVariableParserTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation failure — class doesn't exist

- [ ] **Step 3: Write failing tests for params: parsing**

Add to `PlaybookVariableParserTest.java`:

```java
@Test
void parse_params_required_no_default() {
    var params = new LinkedHashMap<String, Object>();
    params.put("portfolio:string", null);
    var content = Map.<String, Object>of("params", params);

    var result = PlaybookVariableParser.parse(content);

    assertThat(result.params()).containsKey("portfolio");
    assertThat(result.params().get("portfolio").required()).isTrue();
    assertThat(result.params().get("portfolio").defaultValue()).isNull();
}

@Test
void parse_params_optional_with_default() {
    var params = new LinkedHashMap<String, Object>();
    params.put("tier:string", "standard");
    var content = Map.<String, Object>of("params", params);

    var result = PlaybookVariableParser.parse(content);

    assertThat(result.params().get("tier").required()).isFalse();
    assertThat(result.params().get("tier").defaultValue()).isEqualTo("standard");
}

@Test
void parse_params_long_form_with_constraints() {
    var constraints = new LinkedHashMap<String, Object>();
    constraints.put("default", 3);
    constraints.put("minimum", 1);
    constraints.put("maximum", 10);
    var params = new LinkedHashMap<String, Object>();
    params.put("maxRetries:integer", constraints);
    var content = Map.<String, Object>of("params", params);

    var result = PlaybookVariableParser.parse(content);

    var param = result.params().get("maxRetries");
    assertThat(param.defaultValue()).isEqualTo("3");
    assertThat(param.minimum()).isEqualTo(1);
    assertThat(param.maximum()).isEqualTo(10);
    assertThat(param.required()).isFalse();
}

@Test
void parse_params_long_form_required_no_default() {
    var constraints = new LinkedHashMap<String, Object>();
    constraints.put("minimum", 1);
    constraints.put("maximum", 100);
    var params = new LinkedHashMap<String, Object>();
    params.put("retries:integer", constraints);
    var content = Map.<String, Object>of("params", params);

    var result = PlaybookVariableParser.parse(content);

    var param = result.params().get("retries");
    assertThat(param.required()).isTrue();
    assertThat(param.defaultValue()).isNull();
    assertThat(param.minimum()).isEqualTo(1);
}

@Test
void parse_params_long_form_with_allowedValues() {
    var constraints = new LinkedHashMap<String, Object>();
    constraints.put("default", "standard");
    constraints.put("allowedValues", java.util.List.of("basic", "standard", "premium"));
    var params = new LinkedHashMap<String, Object>();
    params.put("tier:string", constraints);
    var content = Map.<String, Object>of("params", params);

    var result = PlaybookVariableParser.parse(content);

    var param = result.params().get("tier");
    assertThat(param.allowedValues()).containsExactly("basic", "standard", "premium");
}

@Test
void parse_both_vars_and_params() {
    var vars = new LinkedHashMap<String, Object>();
    vars.put("retryCount:integer", 0);
    var params = new LinkedHashMap<String, Object>();
    params.put("portfolio:string", null);
    var content = Map.<String, Object>of("vars", vars, "params", params);

    var result = PlaybookVariableParser.parse(content);

    assertThat(result.vars().values()).containsKey("retryCount");
    assertThat(result.params()).containsKey("portfolio");
}
```

- [ ] **Step 4: Implement PlaybookVariableParser**

Create `yaml-core/src/main/java/io/casehub/yaml/core/playbook/PlaybookVariableParser.java`:

```java
package io.casehub.yaml.core.playbook;

import io.casehub.yaml.core.module.YamlModuleParameter;
import io.casehub.yaml.core.type.TypedMap;
import io.casehub.yaml.core.type.TypedName;
import io.casehub.yaml.core.type.TypedVariables;
import io.casehub.yaml.plugin.api.ParameterType;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class PlaybookVariableParser {

    public record ParsedVariables(
            Map<String, YamlModuleParameter> params,
            TypedMap vars) {
        public static final ParsedVariables EMPTY =
            new ParsedVariables(Map.of(), new TypedMap(Map.of(), Map.of()));
    }

    private PlaybookVariableParser() {}

    public static ParsedVariables parse(Map<String, Object> content) {
        Map<String, YamlModuleParameter> params = parseParams(content.get("params"));
        TypedMap vars = parseVars(content.get("vars"));
        return new ParsedVariables(params, vars);
    }

    private static TypedMap parseVars(Object raw) {
        if (raw == null) return new TypedMap(Map.of(), Map.of());
        if (!(raw instanceof Map<?, ?>))
            throw new IllegalArgumentException("vars: must be a map");
        return TypedVariables.parse(asStringKeyedMap(raw));
    }

    @SuppressWarnings("unchecked")
    private static Map<String, YamlModuleParameter> parseParams(Object raw) {
        if (raw == null) return Map.of();
        if (!(raw instanceof Map<?, ?>))
            throw new IllegalArgumentException("params: must be a map");
        var result = new LinkedHashMap<String, YamlModuleParameter>();
        for (var entry : asStringKeyedMap(raw).entrySet()) {
            TypedName tn = TypedName.parse(entry.getKey());
            ParameterType paramType = tn.isScalar()
                ? tn.scalarType().toParameterType()
                : ParameterType.OBJECT;
            Object value = entry.getValue();

            if (value == null) {
                result.put(tn.name(), YamlModuleParameter.builder()
                    .type(paramType).required(true).build());
            } else if (value instanceof Map<?, ?> constraintMap) {
                var map = asStringKeyedMap(constraintMap);
                var builder = YamlModuleParameter.builder().type(paramType);
                if (map.containsKey("default"))
                    builder.defaultValue(String.valueOf(map.get("default")));
                else
                    builder.required(true);
                if (map.get("minimum") instanceof Number n) builder.minimum(n);
                if (map.get("maximum") instanceof Number n) builder.maximum(n);
                if (map.get("minLength") instanceof Number n) builder.minLength(n.intValue());
                if (map.get("maxLength") instanceof Number n) builder.maxLength(n.intValue());
                if (map.get("pattern") instanceof String s) builder.pattern(s);
                if (map.get("allowedValues") instanceof List<?> list)
                    builder.allowedValues(list.stream().map(String::valueOf).toList());
                if (map.get("constraintDescription") instanceof String s)
                    builder.constraintDescription(s);
                result.put(tn.name(), builder.build());
            } else {
                result.put(tn.name(), YamlModuleParameter.builder()
                    .type(paramType).defaultValue(String.valueOf(value)).build());
            }
        }
        return Map.copyOf(result);
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> asStringKeyedMap(Object raw) {
        return (Map<String, Object>) raw;
    }
}
```

- [ ] **Step 5: Run all yaml-core tests**

Run: `mvn --batch-mode test -pl yaml-core`
Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/playbook/PlaybookVariableParser.java yaml-core/src/test/java/io/casehub/yaml/core/playbook/PlaybookVariableParserTest.java
git commit -m "feat(#703): add PlaybookVariableParser for vars: and params: sections

Parses typed variable declarations (name:type: syntax) and parameter
constraints (short form + long form with min/max/allowedValues).
Returns ParsedVariables record for downstream consumption.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 3: Compiler integration — PlaybookVariableContext + CompilationResult

### Task 4: PlaybookVariableContext and PlaybookCompiler integration

**Files:**
- Create: `playbook-compiler/src/main/java/io/casehub/platform/compiler/PlaybookVariableContext.java`
- Modify: `playbook-compiler/src/main/java/io/casehub/platform/compiler/CompilationResult.java`
- Modify: `playbook-compiler/src/main/java/io/casehub/platform/compiler/PlaybookCompiler.java`
- Create: `playbook-compiler/src/test/java/io/casehub/platform/compiler/PlaybookVariableContextTest.java`
- Modify: `playbook-compiler/src/test/java/io/casehub/platform/compiler/PlaybookCompilerTest.java`

**Interfaces:**
- Consumes: `PlaybookVariableParser.parse()` from Task 3, `ParameterValidator.validateOrThrow()`, `VariableResolver.forParams()`
- Produces: `PlaybookVariableContext(params, vars)` with `buildResolver(callerParams, deferredPrefixes)`, `CompilationResult.variableContext()`

- [ ] **Step 1: Write failing test for PlaybookVariableContext.buildResolver()**

Create `PlaybookVariableContextTest.java`:

```java
package io.casehub.platform.compiler;

import io.casehub.yaml.core.module.YamlModuleParameter;
import io.casehub.yaml.core.type.TypedMap;
import io.casehub.yaml.core.type.ValueType;
import io.casehub.yaml.core.module.ParameterValidationException;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class PlaybookVariableContextTest {

    @Test
    void buildResolver_resolves_var_prefix() {
        var vars = new TypedMap(
            Map.of("count", ValueType.INTEGER),
            Map.of("count", (Object) 42));
        var ctx = new PlaybookVariableContext(Map.of(), vars);

        var resolver = ctx.buildResolver(Map.of(), Set.of());

        assertThat(resolver.resolve("${var.count}")).isEqualTo(42);
    }

    @Test
    void buildResolver_resolves_params_prefix() {
        var params = Map.of("portfolio",
            YamlModuleParameter.builder().type(io.casehub.yaml.plugin.api.ParameterType.STRING).required(true).build());
        var ctx = new PlaybookVariableContext(params, new TypedMap(Map.of(), Map.of()));

        var resolver = ctx.buildResolver(Map.of("portfolio", "growth-fund"), Set.of());

        assertThat(resolver.resolve("${params.portfolio}")).isEqualTo("growth-fund");
    }

    @Test
    void buildResolver_validates_missing_required_param() {
        var params = Map.of("portfolio",
            YamlModuleParameter.builder().type(io.casehub.yaml.plugin.api.ParameterType.STRING).required(true).build());
        var ctx = new PlaybookVariableContext(params, new TypedMap(Map.of(), Map.of()));

        assertThatThrownBy(() -> ctx.buildResolver(Map.of(), Set.of()))
            .isInstanceOf(ParameterValidationException.class);
    }

    @Test
    void empty_context_builds_resolver_without_error() {
        var resolver = PlaybookVariableContext.EMPTY.buildResolver(Map.of(), Set.of());
        assertThat(resolver).isNotNull();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl playbook-compiler -Dtest=PlaybookVariableContextTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation failure — class doesn't exist

- [ ] **Step 3: Implement PlaybookVariableContext**

Create `playbook-compiler/src/main/java/io/casehub/platform/compiler/PlaybookVariableContext.java`:

```java
package io.casehub.platform.compiler;

import io.casehub.yaml.core.module.ParameterValidator;
import io.casehub.yaml.core.module.YamlModuleParameter;
import io.casehub.yaml.core.playbook.PlaybookVariableParser;
import io.casehub.yaml.core.resolver.VariableResolver;
import io.casehub.yaml.core.type.TypedMap;

import java.util.Map;
import java.util.Set;

public record PlaybookVariableContext(
        Map<String, YamlModuleParameter> params,
        TypedMap vars) {

    public static final PlaybookVariableContext EMPTY =
        new PlaybookVariableContext(Map.of(), new TypedMap(Map.of(), Map.of()));

    public static PlaybookVariableContext from(PlaybookVariableParser.ParsedVariables parsed) {
        return new PlaybookVariableContext(parsed.params(), parsed.vars());
    }

    public VariableResolver buildResolver(Map<String, String> callerParams,
                                          Set<String> deferredPrefixes) {
        if (!params.isEmpty()) {
            ParameterValidator.validateOrThrow(params, callerParams);
        }
        VariableResolver resolver = VariableResolver.forParams(params, callerParams, deferredPrefixes);
        if (!vars.values().isEmpty()) {
            resolver = resolver.withObjectScope("var",
                name -> vars.values().get(name));
        }
        return resolver;
    }
}
```

- [ ] **Step 4: Extend CompilationResult with variableContext**

Modify `CompilationResult.java`:

```java
package io.casehub.platform.compiler;

import io.casehub.platform.agent.config.PoolDeclaration;
import io.serverlessworkflow.api.types.Workflow;

import java.util.List;

public record CompilationResult(
        Workflow workflow,
        CoordinationSpec coordinationSpec,
        SourceMap sourceMap,
        List<PoolDeclaration> poolDeclarations,
        PlaybookVariableContext variableContext
) {
    public CompilationResult(Workflow workflow, CoordinationSpec coordinationSpec, SourceMap sourceMap) {
        this(workflow, coordinationSpec, sourceMap, List.of(), PlaybookVariableContext.EMPTY);
    }

    public CompilationResult(Workflow workflow, CoordinationSpec coordinationSpec,
                             SourceMap sourceMap, List<PoolDeclaration> poolDeclarations) {
        this(workflow, coordinationSpec, sourceMap, poolDeclarations, PlaybookVariableContext.EMPTY);
    }

    public CompilationResult {
        poolDeclarations = poolDeclarations != null ? List.copyOf(poolDeclarations) : List.of();
        variableContext = variableContext != null ? variableContext : PlaybookVariableContext.EMPTY;
    }
}
```

- [ ] **Step 5: Wire PlaybookCompiler to parse vars/params**

In `PlaybookCompiler.java`, in the `compile(String name, Map<String, Object> content)` method, add parsing before steps compilation (after the `poolDeclarations` parsing):

```java
PlaybookVariableContext variableContext =
    PlaybookVariableContext.from(
        io.casehub.yaml.core.playbook.PlaybookVariableParser.parse(content));
```

Update the `CompilationOutcome.Success` return to include `variableContext`:

```java
return new CompilationOutcome.Success(
    new CompilationResult(workflow, coordination.build(), sourceMap.build(),
                          poolDeclarations, variableContext));
```

- [ ] **Step 6: Write compiler integration test**

Add to `PlaybookCompilerTest.java`:

```java
@Test
void compile_extracts_variable_context() {
    var content = new LinkedHashMap<String, Object>();
    var params = new LinkedHashMap<String, Object>();
    params.put("portfolio:string", null);
    var vars = new LinkedHashMap<String, Object>();
    vars.put("retryCount:integer", 0);
    content.put("params", params);
    content.put("vars", vars);
    content.put("steps", List.of());

    var outcome = compiler.compile("test", content);

    assertThat(outcome).isInstanceOf(CompilationOutcome.Success.class);
    var result = ((CompilationOutcome.Success) outcome).result();
    assertThat(result.variableContext().params()).containsKey("portfolio");
    assertThat(result.variableContext().vars().values()).containsKey("retryCount");
}

@Test
void compile_without_vars_has_empty_context() {
    var content = Map.<String, Object>of("steps", List.of());

    var outcome = compiler.compile("test", content);

    assertThat(outcome).isInstanceOf(CompilationOutcome.Success.class);
    var result = ((CompilationOutcome.Success) outcome).result();
    assertThat(result.variableContext()).isEqualTo(PlaybookVariableContext.EMPTY);
}
```

- [ ] **Step 7: Run all playbook-compiler tests**

Run: `mvn --batch-mode test -pl playbook-compiler`
Expected: all tests pass

- [ ] **Step 8: Commit**

```bash
git add playbook-compiler/src/main/java/io/casehub/platform/compiler/PlaybookVariableContext.java playbook-compiler/src/main/java/io/casehub/platform/compiler/CompilationResult.java playbook-compiler/src/main/java/io/casehub/platform/compiler/PlaybookCompiler.java playbook-compiler/src/test/java/io/casehub/platform/compiler/PlaybookVariableContextTest.java playbook-compiler/src/test/java/io/casehub/platform/compiler/PlaybookCompilerTest.java
git commit -m "feat(#703): wire vars:/params: through PlaybookCompiler pipeline

PlaybookVariableContext wraps parsed variables and builds a
VariableResolver with params validation. CompilationResult carries
the variable context. PlaybookCompiler extracts vars:/params: from
the content map.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 4: RunPlaybookPlugin integration — vars: passing and validation

### Task 5: Update RunPlaybookPlugin for vars: passing and param validation

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/RunPlaybookPlugin.java`
- Modify: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/WalkerSiblingAbsorptionTest.java` (or create new test)
- Create: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/plugin/RunPlaybookPluginTest.java`

**Interfaces:**
- Consumes: `PlaybookVariableParser.parse()` from Task 3, `ParameterValidator.validateOrThrow()`
- Produces: Updated `RunPlaybookPlugin` that parses sub-playbook params, validates caller vars, builds resolver

- [ ] **Step 1: Write failing test for run-playbook with vars**

Create `RunPlaybookPluginTest.java`:

```java
package io.casehub.yaml.step.plugin;

import io.casehub.yaml.plugin.api.Result;
import io.casehub.yaml.plugin.api.MapServiceRegistry;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class RunPlaybookPluginTest {

    @TempDir
    Path tempDir;

    @Test
    void execute_passes_vars_to_sub_playbook() throws IOException {
        var subPlaybook = tempDir.resolve("sub.yaml");
        Files.writeString(subPlaybook, """
            params:
              greeting:string:
            steps:
              - log: "${params.greeting}"
            """);

        var params = new LinkedHashMap<String, Object>();
        params.put("_subject", subPlaybook.toString());
        params.put("vars", Map.of("greeting", "hello"));

        var registry = new MapServiceRegistry();
        registry.register(TestExecutionContext.class,
            new TestExecutionContext(tempDir, createPluginRegistry(), createResolver()));

        var plugin = new RunPlaybookPlugin();
        Result result = plugin.execute(params, registry);

        assertThat(result.isSuccess()).isTrue();
    }
}
```

The test helpers (`createPluginRegistry`, `createResolver`) will need to be implemented based on existing test patterns in the module.

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=RunPlaybookPluginTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — RunPlaybookPlugin doesn't extract vars from params

- [ ] **Step 3: Update RunPlaybookPlugin to extract and validate vars**

In `RunPlaybookPlugin.execute()`:

1. Extract `vars` from the params map (sibling key absorbed by Walker)
2. Parse the sub-playbook's content for `params:` section using `PlaybookVariableParser`
3. Validate caller vars against declared params
4. Build a new `VariableResolver` from the variable context
5. Use the new resolver when running sub-playbook steps

Key changes to the `execute` method:

```java
@SuppressWarnings("unchecked")
Map<String, Object> callerVars = params.containsKey("vars")
    ? (Map<String, Object>) params.get("vars")
    : Map.of();

var parsed = PlaybookVariableParser.parse(doc);
Map<String, String> callerParams = new LinkedHashMap<>();
for (var entry : callerVars.entrySet()) {
    callerParams.put(entry.getKey(), String.valueOf(entry.getValue()));
}

if (!parsed.params().isEmpty()) {
    ParameterValidator.validateOrThrow(parsed.params(), callerParams);
}

VariableResolver resolver = VariableResolver.forParams(
    parsed.params(), callerParams, Set.of());
```

- [ ] **Step 4: Run all yaml-step-runtime tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/RunPlaybookPlugin.java yaml-step-runtime/src/test/java/io/casehub/yaml/step/plugin/RunPlaybookPluginTest.java
git commit -m "feat(#703): RunPlaybookPlugin validates caller vars against sub-playbook params

run-playbook now extracts vars: from caller, parses sub-playbook's
params: section, validates with ParameterValidator, and builds a
resolver scoped to the sub-playbook.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 5: Test infrastructure integration

### Task 6: Update YamlTestExecutor for vars/params support

**Files:**
- Modify: `yaml-test-core/src/main/java/io/casehub/yaml/test/YamlTestExecutor.java`
- Modify: `yaml-test-core/src/main/java/io/casehub/yaml/test/YamlTestDiscovery.java`
- Modify: `yaml-test-core/src/main/java/io/casehub/yaml/test/TestCase.java`
- Create: `yaml-test-core/src/test/java/io/casehub/yaml/test/YamlTestExecutorVarsTest.java`

**Interfaces:**
- Consumes: `PlaybookVariableParser.parse()` from Task 3
- Produces: `YamlTestExecutor` initializes `VariableResolver` from `vars:` and `params:` in test files

- [ ] **Step 1: Write failing test for test executor with vars**

Create `YamlTestExecutorVarsTest.java`:

```java
package io.casehub.yaml.test;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class YamlTestExecutorVarsTest {

    @TempDir
    Path tempDir;

    @Test
    void test_file_with_vars_initializes_resolver() throws IOException {
        var testFile = tempDir.resolve("vars.test.yaml");
        Files.writeString(testFile, """
            name: vars-test
            vars:
              count:integer: 42
            steps:
              - assert-equals:
                  actual: "${var.count}"
                  expected: "42"
            """);

        var descriptors = YamlTestDiscovery.discover(tempDir);
        assertThat(descriptors).hasSize(1);
        assertThat(descriptors.get(0).name()).isEqualTo("vars-test");
    }
}
```

- [ ] **Step 2: Implement test executor changes**

Update `YamlTestDiscovery.parseTestFile()` to extract `vars:` and `params:` from the test file and pass them to `TestCase` or `TestFileDescriptor`.

Update `YamlTestExecutor` to parse `vars:` and `params:` using `PlaybookVariableParser`, build the initial `VariableResolver` with declared variables, and use it when running steps.

- [ ] **Step 3: Run all yaml-test-core tests**

Run: `mvn --batch-mode test -pl yaml-test-core`
Expected: all tests pass

- [ ] **Step 4: Run full build to verify no regressions**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git add yaml-test-core/
git commit -m "feat(#703): YamlTestExecutor supports vars: and params: in test files

Test files can now declare typed variables and parameters. The test
executor builds a VariableResolver from these declarations before
running steps.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## References

- [2026-11-03-playbook-variable-declarations-design.md] — design spec this plan implements
- `yaml-core/src/main/java/io/casehub/yaml/core/type/TypedName.java` — existing name:type parsing
- `yaml-core/src/main/java/io/casehub/yaml/core/type/TypedVariables.java` — existing typed variable parsing
- `yaml-core/src/main/java/io/casehub/yaml/core/type/TypedMap.java` — typed variable storage
- `yaml-core/src/main/java/io/casehub/yaml/core/type/ValueType.java` — scalar type enum
- `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleParameter.java` — constraint model
- `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterValidator.java` — constraint validation
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java` — prefix-based resolution
- `playbook-compiler/src/main/java/io/casehub/platform/compiler/PlaybookCompiler.java` — compilation entry point
- `playbook-compiler/src/main/java/io/casehub/platform/compiler/CompilationResult.java` — compilation output
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/RunPlaybookPlugin.java` — sub-playbook execution
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java` — YAML step parsing
- `yaml-test-core/src/main/java/io/casehub/yaml/test/YamlTestExecutor.java` — test runner
- `yaml-core/src/main/java/io/casehub/yaml/core/data/CsvParser.java` — TypedName consumer (needs scalarType rename)
- GitHub #703 — focal issue
- GitHub #429 — YAML surface type system (compound key syntax foundation)
- GitHub #699 — type-safe expression resolution (future domain type deserialization)
- GitHub #702 — parent epic
