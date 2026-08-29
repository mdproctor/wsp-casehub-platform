# Shared YAML Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #247 — Shared YAML core: extract common declaration primitives into casehub-yaml-core
**Issue group:** #247

**Goal:** Create `casehub-platform-yaml-core` — a pure Java, zero-dependency module providing composable YAML declaration primitives (variable resolution, forEach expansion, conditional inclusion, CSV data sources, iteration groups) with JSON Schema fragments for downstream YAML dialects.

**Architecture:** New module `yaml-core/` in the platform repo. Five primitives organized into four packages (`resolver/`, `foreach/`, `condition/`, `data/`). Each primitive is independently usable — domains compose them via direct API calls (toolbox model). JSON Schema fragments in `src/main/resources/schema/` provide composable YAML validation for downstream consumers.

**Tech Stack:** Pure Java 21 (records, sealed interfaces, pattern matching). JUnit 5 + AssertJ for tests. No Quarkus, no CDI, no Jackson, no reflection — J2CL-transpilable.

## Global Constraints

- **Zero production dependencies** — only `junit-jupiter` and `assertj-core` in test scope
- **J2CL compatible** — no `ConcurrentHashMap`, no `Thread`/`Lock`/`synchronized`, no reflection, no Jackson, no CDI
- **Port, don't rewrite** — existing code from desiredstate is production-tested; copy and adapt
- **`Locale.ROOT`** — all `toLowerCase()`/`toUpperCase()` calls use `Locale.ROOT`
- **Immutable returns** — `List.copyOf()`, `Map.copyOf()`, `Set.copyOf()` for all public return values
- **No Jandex** — no CDI beans to index; omit `jandex-maven-plugin`
- **No quarkus:build goal** — pure Java module

---

## Batch 1: Foundation — module scaffold, leaf types, and variable resolution

### Task 1: Maven module + leaf types

**Files:**
- Create: `yaml-core/pom.xml`
- Modify: `pom.xml` (add `<module>yaml-core</module>`)
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/condition/Truthiness.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/foreach/IterationGroup.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ExpansionResult.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/UnresolvedVariableException.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableSource.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/condition/TruthinessTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/foreach/IterationGroupTest.java`

**Interfaces:**
- Consumes: nothing (leaf task)
- Produces: `Truthiness.isTruthy(String)`, `IterationGroup(String as, Object in)`, `ExpansionResult<E>(List<E>, Set<String>)`, `UnresolvedVariableException(String, String, String)`, `VariableSource.resolve(String)`, `VariableSource.chain(VariableSource...)`

- [ ] **Step 1: Create module directory and pom.xml**

Create `yaml-core/pom.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-yaml-core</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform YAML Core</name>
    <description>Pure Java YAML declaration primitives — variable resolution, forEach expansion,
        conditional inclusion, CSV data sources, iteration groups. Zero dependencies, J2CL-transpilable.</description>

    <dependencies>
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>
</project>
```

Add `<module>yaml-core</module>` to the parent `pom.xml` `<modules>` section, after the last module entry.

- [ ] **Step 2: Write TruthinessTest (failing)**

Create `yaml-core/src/test/java/io/casehub/yaml/core/condition/TruthinessTest.java`:

```java
package io.casehub.yaml.core.condition;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class TruthinessTest {

    @ParameterizedTest
    @ValueSource(strings = {"true", "True", "TRUE", "yes", "Yes", "on", "ON", "y", "Y", "1"})
    void truthy_values(String value) {
        assertThat(Truthiness.isTruthy(value)).isTrue();
    }

    @ParameterizedTest
    @ValueSource(strings = {"false", "False", "FALSE", "no", "No", "off", "OFF", "n", "N", "0"})
    void falsy_values(String value) {
        assertThat(Truthiness.isTruthy(value)).isFalse();
    }

    @Test
    void invalid_value_throws() {
        assertThatThrownBy(() -> Truthiness.isTruthy("production"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("production")
                .hasMessageContaining("not a boolean");
    }

    @Test
    void empty_string_throws() {
        assertThatThrownBy(() -> Truthiness.isTruthy(""))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mvn --batch-mode -pl yaml-core test -Dtest=TruthinessTest`
Expected: compilation error — `Truthiness` does not exist

- [ ] **Step 4: Implement Truthiness**

Create `yaml-core/src/main/java/io/casehub/yaml/core/condition/Truthiness.java`:

```java
package io.casehub.yaml.core.condition;

import java.util.Locale;

public final class Truthiness {

    private Truthiness() {}

    public static boolean isTruthy(String value) {
        return switch (value.toLowerCase(Locale.ROOT)) {
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

- [ ] **Step 5: Run test to verify it passes**

Run: `mvn --batch-mode -pl yaml-core test -Dtest=TruthinessTest`
Expected: all 4 tests PASS

- [ ] **Step 6: Write IterationGroupTest (failing)**

Create `yaml-core/src/test/java/io/casehub/yaml/core/foreach/IterationGroupTest.java`:

```java
package io.casehub.yaml.core.foreach;

import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class IterationGroupTest {

    @Test
    void list_in_returns_copy() {
        var group = new IterationGroup("region", List.of("us-east", "eu-west"));
        assertThat(group.inAsList()).containsExactly("us-east", "eu-west");
    }

    @Test
    void string_in_returns_singleton() {
        var group = new IterationGroup("region", "us-east");
        assertThat(group.inAsList()).containsExactly("us-east");
    }

    @Test
    void null_in_returns_empty() {
        var group = new IterationGroup("region", null);
        assertThat(group.inAsList()).isEmpty();
    }

    @Test
    void invalid_type_throws() {
        var group = new IterationGroup("region", 42);
        assertThatThrownBy(group::inAsList)
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("list or string");
    }
}
```

- [ ] **Step 7: Implement IterationGroup + ExpansionResult**

Create `yaml-core/src/main/java/io/casehub/yaml/core/foreach/IterationGroup.java`:

```java
package io.casehub.yaml.core.foreach;

import java.util.List;

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

Create `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ExpansionResult.java`:

```java
package io.casehub.yaml.core.foreach;

import java.util.List;
import java.util.Set;

public record ExpansionResult<E>(List<E> elements, Set<String> excludedIds) {}
```

- [ ] **Step 8: Implement UnresolvedVariableException + VariableSource**

Create `yaml-core/src/main/java/io/casehub/yaml/core/resolver/UnresolvedVariableException.java`:

```java
package io.casehub.yaml.core.resolver;

public class UnresolvedVariableException extends RuntimeException {

    private final String variableName;
    private final String elementContext;

    public UnresolvedVariableException(String variableName, String elementContext, String detail) {
        super("Unresolved variable '" + variableName + "' in element '" + elementContext + "'. " + detail);
        this.variableName = variableName;
        this.elementContext = elementContext;
    }

    public String variableName() { return variableName; }

    public String elementContext() { return elementContext; }
}
```

Create `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableSource.java`:

```java
package io.casehub.yaml.core.resolver;

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

- [ ] **Step 9: Run all tests to verify everything passes**

Run: `mvn --batch-mode -pl yaml-core test`
Expected: all tests PASS

- [ ] **Step 10: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-core/ pom.xml
git commit -m "feat(yaml-core): scaffold module + leaf types (Truthiness, IterationGroup, VariableSource) Refs #247"
```

---

### Task 2: VariableResolver

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/resolver/VariableResolverTest.java`

**Interfaces:**
- Consumes: `VariableSource`, `UnresolvedVariableException` (from Task 1)
- Produces: `VariableResolver(Map<String, VariableSource>, Set<String>)`, `.resolveString(String, String)`, `.resolveMap(Map, String)`, `.resolveList(List, String)`, `.resolve(Object)`, `.withEachContext(Map<String, String>)`, `.withEachRowContext(Map<String, Map<String, Object>>)`, `.withScope(String, VariableSource)`

- [ ] **Step 1: Write VariableResolverTest — basic resolution**

Create `yaml-core/src/test/java/io/casehub/yaml/core/resolver/VariableResolverTest.java`:

```java
package io.casehub.yaml.core.resolver;

import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class VariableResolverTest {

    private static VariableSource mapSource(Map<String, String> values) {
        return values::get;
    }

    @Test
    void resolves_prefixed_variable() {
        var resolver = new VariableResolver(
                Map.of("var", mapSource(Map.of("batch", "500"))), Set.of());
        assertThat(resolver.resolveString("${var.batch}", "test"))
                .isEqualTo("500");
    }

    @Test
    void passes_plain_strings_through() {
        var resolver = new VariableResolver(Map.of(), Set.of());
        assertThat(resolver.resolve("plain-string")).isEqualTo("plain-string");
    }

    @Test
    void resolves_embedded_variable() {
        var resolver = new VariableResolver(
                Map.of("var", mapSource(Map.of("bucket", "prod"))), Set.of());
        assertThat(resolver.resolveString("s3://${var.bucket}/data", "node"))
                .isEqualTo("s3://prod/data");
    }

    @Test
    void resolves_multiple_variables() {
        var resolver = new VariableResolver(
                Map.of("var", mapSource(Map.of("proto", "s3", "bucket", "data"))), Set.of());
        assertThat(resolver.resolveString("${var.proto}://${var.bucket}/path", "node"))
                .isEqualTo("s3://data/path");
    }

    @Test
    void resolves_map_values() {
        var resolver = new VariableResolver(
                Map.of("var", mapSource(Map.of("uri", "s3://data"))), Set.of());
        Map<String, Object> input = new LinkedHashMap<>();
        input.put("destination", "${var.uri}");
        input.put("count", 42);
        var resolved = resolver.resolveMap(input, "node");
        assertThat(resolved).containsEntry("destination", "s3://data");
        assertThat(resolved).containsEntry("count", 42);
    }

    @Test
    void resolves_list_values() {
        var resolver = new VariableResolver(
                Map.of("var", mapSource(Map.of("field", "email"))), Set.of());
        var resolved = resolver.resolveList(List.of("name", "${var.field}"), "node");
        assertThat(resolved).containsExactly("name", "email");
    }

    @Test
    void resolve_object_dispatches_by_type() {
        var resolver = new VariableResolver(
                Map.of("var", mapSource(Map.of("x", "1"))), Set.of());
        assertThat(resolver.resolve("${var.x}")).isEqualTo("1");
        assertThat(resolver.resolve(42)).isEqualTo(42);
        assertThat(resolver.resolve(true)).isEqualTo(true);
    }

    @Test
    void non_string_values_pass_through() {
        var resolver = new VariableResolver(Map.of(), Set.of());
        assertThat(resolver.resolve(42)).isEqualTo(42);
        assertThat(resolver.resolve(3.14)).isEqualTo(3.14);
    }

    @Test
    void bare_name_throws_with_guidance() {
        var resolver = new VariableResolver(
                Map.of("var", mapSource(Map.of("x", "1"))), Set.of());
        assertThatThrownBy(() -> resolver.resolveString("${x}", "test"))
                .isInstanceOf(UnresolvedVariableException.class)
                .hasMessageContaining("${var.x}");
    }

    @Test
    void unknown_prefix_throws_listing_available() {
        var resolver = new VariableResolver(
                Map.of("var", mapSource(Map.of())), Set.of());
        assertThatThrownBy(() -> resolver.resolveString("${nope.x}", "test"))
                .isInstanceOf(UnresolvedVariableException.class)
                .hasMessageContaining("nope")
                .hasMessageContaining("var");
    }

    @Test
    void unresolved_variable_throws() {
        var resolver = new VariableResolver(
                Map.of("var", mapSource(Map.of("batch_size", "100"))), Set.of());
        assertThatThrownBy(() -> resolver.resolveString("${var.bacth_size}", "node"))
                .isInstanceOf(UnresolvedVariableException.class)
                .hasMessageContaining("bacth_size");
    }

    // --- Deferred prefixes ---

    @Test
    void deferred_prefix_passes_through() {
        var resolver = new VariableResolver(
                Map.of("var", mapSource(Map.of("region", "us-east"))),
                Set.of("match", "fault"));
        String result = resolver.resolveString(
                "${match.sink.id}-${var.region}", "rule");
        assertThat(result).isEqualTo("${match.sink.id}-us-east");
    }

    @Test
    void deferred_all_refs_passes_through() {
        var resolver = new VariableResolver(Map.of(), Set.of("match"));
        assertThat(resolver.resolveString("${match.sink.id}", "rule"))
                .isEqualTo("${match.sink.id}");
    }

    // --- Each context ---

    @Test
    void each_context_resolves() {
        var resolver = new VariableResolver(
                Map.of("var", mapSource(Map.of("batch", "1000"))), Set.of());
        var eachResolver = resolver.withEachContext(Map.of("region", "us-east"));
        assertThat(eachResolver.resolveString("s3://${each.region}/${var.batch}", "node"))
                .isEqualTo("s3://us-east/1000");
    }

    @Test
    void each_unknown_variable_throws() {
        var resolver = new VariableResolver(Map.of(), Set.of());
        var eachResolver = resolver.withEachContext(Map.of("region", "us-east"));
        assertThatThrownBy(() -> eachResolver.resolveString("${each.zone}", "node"))
                .isInstanceOf(UnresolvedVariableException.class)
                .hasMessageContaining("zone");
    }

    @Test
    void each_without_context_throws() {
        var resolver = new VariableResolver(Map.of(), Set.of());
        assertThatThrownBy(() -> resolver.resolveString("${each.region}", "node"))
                .isInstanceOf(UnresolvedVariableException.class)
                .hasMessageContaining("forEach");
    }

    // --- Each row context (CSV) ---

    @Test
    void each_row_context_drills_into_field() {
        var resolver = new VariableResolver(Map.of(), Set.of());
        var rowResolver = resolver.withEachRowContext(
                Map.of("env", Map.of("name", "staging", "region", "us-east")));
        assertThat(rowResolver.resolveString("${each.env.name}", "node"))
                .isEqualTo("staging");
        assertThat(rowResolver.resolveString("${each.env.region}", "node"))
                .isEqualTo("us-east");
    }

    @Test
    void each_row_missing_field_throws() {
        var resolver = new VariableResolver(Map.of(), Set.of());
        var rowResolver = resolver.withEachRowContext(
                Map.of("env", Map.of("name", "staging")));
        assertThatThrownBy(() -> rowResolver.resolveString("${each.env.missing}", "node"))
                .isInstanceOf(UnresolvedVariableException.class)
                .hasMessageContaining("missing")
                .hasMessageContaining("name");
    }

    @Test
    void each_row_without_field_throws() {
        var resolver = new VariableResolver(Map.of(), Set.of());
        var rowResolver = resolver.withEachRowContext(
                Map.of("env", Map.of("name", "staging")));
        assertThatThrownBy(() -> rowResolver.resolveString("${each.env}", "node"))
                .isInstanceOf(UnresolvedVariableException.class)
                .hasMessageContaining("field access");
    }

    // --- Chain ---

    @Test
    void chain_tries_sources_in_order() {
        var primary = mapSource(Map.of("email", "module@test.com"));
        var fallback = mapSource(Map.of("email", "global@test.com", "batch", "1000"));
        var resolver = new VariableResolver(
                Map.of("var", VariableSource.chain(primary, fallback)), Set.of());
        assertThat(resolver.resolveString("${var.email}", "test"))
                .isEqualTo("module@test.com");
        assertThat(resolver.resolveString("${var.batch}", "test"))
                .isEqualTo("1000");
    }

    // --- withScope ---

    @Test
    void withScope_adds_prefix_source() {
        var resolver = new VariableResolver(
                Map.of("var", mapSource(Map.of("x", "1"))), Set.of());
        var scoped = resolver.withScope("step", mapSource(Map.of("result", "ok")));
        assertThat(scoped.resolveString("${step.result}", "test")).isEqualTo("ok");
        assertThat(scoped.resolveString("${var.x}", "test")).isEqualTo("1");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode -pl yaml-core test -Dtest=VariableResolverTest`
Expected: compilation error — `VariableResolver` does not exist

- [ ] **Step 3: Implement VariableResolver**

Create `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java`:

```java
package io.casehub.yaml.core.resolver;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class VariableResolver {

    private static final Pattern VAR_PATTERN = Pattern.compile("\\$\\{([^}]+)}");

    private final Map<String, VariableSource> prefixSources;
    private final Set<String> deferredPrefixes;
    private final Map<String, String> eachContext;
    private final Map<String, Map<String, Object>> eachRowContext;

    public VariableResolver(Map<String, VariableSource> prefixSources,
                            Set<String> deferredPrefixes) {
        this.prefixSources = Map.copyOf(prefixSources);
        this.deferredPrefixes = Set.copyOf(deferredPrefixes);
        this.eachContext = null;
        this.eachRowContext = null;
    }

    private VariableResolver(Map<String, VariableSource> prefixSources,
                             Set<String> deferredPrefixes,
                             Map<String, String> eachContext,
                             Map<String, Map<String, Object>> eachRowContext) {
        this.prefixSources = prefixSources;
        this.deferredPrefixes = deferredPrefixes;
        this.eachContext = eachContext;
        this.eachRowContext = eachRowContext;
    }

    public VariableResolver withEachContext(Map<String, String> eachContext) {
        return new VariableResolver(prefixSources, deferredPrefixes, eachContext, eachRowContext);
    }

    public VariableResolver withEachRowContext(Map<String, Map<String, Object>> rowContext) {
        return new VariableResolver(prefixSources, deferredPrefixes, eachContext, rowContext);
    }

    public VariableResolver withScope(String prefix, VariableSource source) {
        var newSources = new LinkedHashMap<>(prefixSources);
        newSources.put(prefix, source);
        return new VariableResolver(Map.copyOf(newSources), deferredPrefixes, eachContext, eachRowContext);
    }

    public Object resolve(Object value) {
        if (value instanceof String s) {
            return s.contains("${") ? resolveString(s, "") : s;
        }
        if (value instanceof Map<?, ?> map) { return resolveMap(map, ""); }
        if (value instanceof List<?> list) { return resolveList(list, ""); }
        return value;
    }

    public String resolveString(String template, String elementContext) {
        Matcher matcher = VAR_PATTERN.matcher(template);
        StringBuilder sb = new StringBuilder();
        while (matcher.find()) {
            String key = matcher.group(1);
            String resolved = lookupVariable(key, elementContext);
            if (resolved == null) {
                matcher.appendReplacement(sb, Matcher.quoteReplacement(matcher.group()));
            } else {
                matcher.appendReplacement(sb, Matcher.quoteReplacement(resolved));
            }
        }
        matcher.appendTail(sb);
        return sb.toString();
    }

    public Map<String, Object> resolveMap(Map<?, ?> input, String elementContext) {
        Map<String, Object> result = new LinkedHashMap<>();
        for (Map.Entry<?, ?> entry : input.entrySet()) {
            String key = entry.getKey().toString();
            Object val = entry.getValue();
            if (val instanceof String s && s.contains("${")) {
                result.put(key, resolveString(s, elementContext));
            } else if (val instanceof Map<?, ?> nested) {
                result.put(key, resolveMap(nested, elementContext));
            } else if (val instanceof List<?> list) {
                result.put(key, resolveList(list, elementContext));
            } else {
                result.put(key, val);
            }
        }
        return result;
    }

    public List<?> resolveList(List<?> input, String elementContext) {
        return input.stream()
                .map(item -> {
                    if (item instanceof String s && s.contains("${")) {
                        return resolveString(s, elementContext);
                    }
                    if (item instanceof Map<?, ?> map) {
                        return resolveMap(map, elementContext);
                    }
                    return item;
                })
                .toList();
    }

    private String lookupVariable(String key, String elementContext) {
        int dot = key.indexOf('.');
        if (dot < 0) {
            throw new UnresolvedVariableException(key, elementContext,
                    "Bare variable references are not supported. "
                    + "Use ${var." + key + "} instead of ${" + key + "}. "
                    + "Available prefixes: " + availablePrefixes() + ".");
        }

        String prefix = key.substring(0, dot);
        String name = key.substring(dot + 1);

        if ("each".equals(prefix)) {
            return resolveEach(name, key, elementContext);
        }

        VariableSource source = prefixSources.get(prefix);
        if (source != null) {
            String value = source.resolve(name);
            if (value != null) return value;
            throw new UnresolvedVariableException(key, elementContext,
                    "Variable '" + name + "' not found in prefix '" + prefix + "'.");
        }

        if (deferredPrefixes.contains(prefix)) {
            return null;
        }

        throw new UnresolvedVariableException(key, elementContext,
                "Unknown prefix '" + prefix + "'. "
                + "Available prefixes: " + availablePrefixes() + ".");
    }

    private String resolveEach(String name, String key, String elementContext) {
        int dot = name.indexOf('.');
        if (dot >= 0) {
            String rowName = name.substring(0, dot);
            String fieldPath = name.substring(dot + 1);
            if (eachRowContext != null) {
                Map<String, Object> row = eachRowContext.get(rowName);
                if (row != null) {
                    Object value = drillField(row, fieldPath);
                    if (value != null) return value.toString();
                    throw new UnresolvedVariableException(key, elementContext,
                            "Field '" + fieldPath + "' not found in row '" + rowName
                            + "'. Available fields: " + row.keySet());
                }
            }
        }

        if (eachContext != null) {
            String value = eachContext.get(name);
            if (value != null) return value;
            if (eachRowContext != null) {
                Map<String, Object> row = eachRowContext.get(name);
                if (row != null) {
                    throw new UnresolvedVariableException(key, elementContext,
                            "'" + name + "' is a row — use field access like ${each."
                            + name + ".fieldName}. Available fields: " + row.keySet());
                }
            }
            throw new UnresolvedVariableException(key, elementContext,
                    "Unknown forEach variable '" + name + "'. Available: " + eachContext.keySet());
        }

        if (eachRowContext != null) {
            Map<String, Object> row = eachRowContext.get(name);
            if (row != null) {
                throw new UnresolvedVariableException(key, elementContext,
                        "'" + name + "' is a row — use field access like ${each."
                        + name + ".fieldName}. Available fields: " + row.keySet());
            }
        }

        throw new UnresolvedVariableException(key, elementContext,
                "${each.*} references are resolved during forEach expansion. "
                + "No forEach context is active.");
    }

    @SuppressWarnings("unchecked")
    private static Object drillField(Map<String, Object> map, String fieldPath) {
        String[] parts = fieldPath.split("\\.");
        Object current = map;
        for (String part : parts) {
            if (current instanceof Map<?, ?> m) { current = m.get(part); }
            else { return null; }
        }
        return current;
    }

    private String availablePrefixes() {
        var all = new TreeSet<>(prefixSources.keySet());
        all.add("each");
        all.addAll(deferredPrefixes);
        return all.toString();
    }
}
```

- [ ] **Step 4: Run test to verify all pass**

Run: `mvn --batch-mode -pl yaml-core test -Dtest=VariableResolverTest`
Expected: all tests PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-core/
git commit -m "feat(yaml-core): VariableResolver with pluggable sources and deferred prefixes Refs #247"
```

---

## Batch 2: Expansion primitives — CSV data source and ForEach

### Task 3: CSV data source

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/data/CsvColumnType.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/data/CsvColumn.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/data/CsvDataSource.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/data/CsvParser.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/data/CsvParserTest.java`

**Interfaces:**
- Consumes: `Truthiness.isTruthy(String)` (from Task 1)
- Produces: `CsvParser.parse(String name, String csvContent)` → `CsvDataSource`, `CsvColumnType.parse(String, int, String)` → `Object`

- [ ] **Step 1: Write CsvParserTest (failing)**

Create `yaml-core/src/test/java/io/casehub/yaml/core/data/CsvParserTest.java`:

```java
package io.casehub.yaml.core.data;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class CsvParserTest {

    @Test
    void parses_typed_columns() {
        String csv = """
                name:string,region:string,tier:integer,production:boolean
                staging,us-east,1,false
                production,eu-west,2,true
                """;

        CsvDataSource ds = CsvParser.parse("environments", csv);

        assertThat(ds.name()).isEqualTo("environments");
        assertThat(ds.columns()).hasSize(4);
        assertThat(ds.columns().get(0)).isEqualTo(new CsvColumn("name", CsvColumnType.STRING));
        assertThat(ds.columns().get(2)).isEqualTo(new CsvColumn("tier", CsvColumnType.INTEGER));
        assertThat(ds.rows()).hasSize(2);

        Map<String, Object> row0 = ds.rows().get(0);
        assertThat(row0.get("name")).isEqualTo("staging");
        assertThat(row0.get("tier")).isEqualTo(1);
        assertThat(row0.get("production")).isEqualTo(false);

        Map<String, Object> row1 = ds.rows().get(1);
        assertThat(row1.get("production")).isEqualTo(true);
    }

    @Test
    void decimal_column_type() {
        String csv = """
                value:decimal
                3.14
                """;
        CsvDataSource ds = CsvParser.parse("numbers", csv);
        assertThat(ds.rows().get(0).get("value")).isEqualTo(new BigDecimal("3.14"));
    }

    @Test
    void empty_csv_throws() {
        assertThatThrownBy(() -> CsvParser.parse("test", ""))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("empty");
    }

    @Test
    void header_only_returns_empty_rows() {
        CsvDataSource ds = CsvParser.parse("test", "name:string,id:integer");
        assertThat(ds.columns()).hasSize(2);
        assertThat(ds.rows()).isEmpty();
    }

    @Test
    void wrong_column_count_throws() {
        String csv = """
                name:string,id:integer
                only-one
                """;
        assertThatThrownBy(() -> CsvParser.parse("test", csv))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("row 1")
                .hasMessageContaining("1 cells")
                .hasMessageContaining("2");
    }

    @Test
    void invalid_integer_throws() {
        String csv = """
                count:integer
                abc
                """;
        assertThatThrownBy(() -> CsvParser.parse("test", csv))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("count")
                .hasMessageContaining("integer")
                .hasMessageContaining("abc");
    }

    @Test
    void unknown_column_type_throws() {
        assertThatThrownBy(() -> CsvParser.parse("test", "name:blorp"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("blorp")
                .hasMessageContaining("STRING");
    }

    @Test
    void header_without_type_throws() {
        assertThatThrownBy(() -> CsvParser.parse("test", "name"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("name:type");
    }

    @Test
    void boolean_uses_truthiness() {
        String csv = """
                flag:boolean
                yes
                no
                on
                off
                1
                0
                """;
        CsvDataSource ds = CsvParser.parse("flags", csv);
        assertThat(ds.rows().get(0).get("flag")).isEqualTo(true);
        assertThat(ds.rows().get(1).get("flag")).isEqualTo(false);
        assertThat(ds.rows().get(2).get("flag")).isEqualTo(true);
        assertThat(ds.rows().get(3).get("flag")).isEqualTo(false);
        assertThat(ds.rows().get(4).get("flag")).isEqualTo(true);
        assertThat(ds.rows().get(5).get("flag")).isEqualTo(false);
    }

    @Test
    void skips_blank_lines() {
        String csv = """
                name:string
                first

                second
                """;
        CsvDataSource ds = CsvParser.parse("test", csv);
        assertThat(ds.rows()).hasSize(2);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode -pl yaml-core test -Dtest=CsvParserTest`
Expected: compilation error — `CsvParser` does not exist

- [ ] **Step 3: Implement CSV types + parser**

Create `yaml-core/src/main/java/io/casehub/yaml/core/data/CsvColumnType.java`:

```java
package io.casehub.yaml.core.data;

import io.casehub.yaml.core.condition.Truthiness;

import java.math.BigDecimal;

public enum CsvColumnType {
    STRING, INTEGER, BOOLEAN, DECIMAL;

    public Object parse(String value, int row, String columnName) {
        return switch (this) {
            case STRING -> value;
            case INTEGER -> {
                try {
                    yield Integer.parseInt(value.trim());
                } catch (NumberFormatException e) {
                    throw new IllegalArgumentException(
                            "Row " + row + ", column '" + columnName
                            + "': expected integer, got '" + value + "'");
                }
            }
            case BOOLEAN -> Truthiness.isTruthy(value.trim());
            case DECIMAL -> {
                try {
                    yield new BigDecimal(value.trim());
                } catch (NumberFormatException e) {
                    throw new IllegalArgumentException(
                            "Row " + row + ", column '" + columnName
                            + "': expected decimal, got '" + value + "'");
                }
            }
        };
    }
}
```

Create `yaml-core/src/main/java/io/casehub/yaml/core/data/CsvColumn.java`:

```java
package io.casehub.yaml.core.data;

public record CsvColumn(String name, CsvColumnType type) {}
```

Create `yaml-core/src/main/java/io/casehub/yaml/core/data/CsvDataSource.java`:

```java
package io.casehub.yaml.core.data;

import java.util.List;
import java.util.Map;

public record CsvDataSource(String name, List<CsvColumn> columns,
                             List<Map<String, Object>> rows) {}
```

Create `yaml-core/src/main/java/io/casehub/yaml/core/data/CsvParser.java`:

```java
package io.casehub.yaml.core.data;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

public final class CsvParser {

    private CsvParser() {}

    public static CsvDataSource parse(String name, String csvContent) {
        String[] lines = csvContent.strip().split("\\R");
        if (lines.length == 0 || lines[0].isBlank()) {
            throw new IllegalArgumentException("CSV '" + name + "': empty content");
        }

        String[] headerCells = lines[0].split(",");
        List<CsvColumn> columns = new ArrayList<>();
        for (String cell : headerCells) {
            String trimmed = cell.trim();
            int colon = trimmed.indexOf(':');
            if (colon < 0) {
                throw new IllegalArgumentException(
                        "CSV '" + name + "': header cell '" + trimmed
                        + "' must be 'name:type'");
            }
            String colName = trimmed.substring(0, colon).trim();
            String typeName = trimmed.substring(colon + 1).trim().toUpperCase(Locale.ROOT);
            CsvColumnType type;
            try {
                type = CsvColumnType.valueOf(typeName);
            } catch (IllegalArgumentException e) {
                throw new IllegalArgumentException(
                        "CSV '" + name + "': unknown column type '" + typeName
                        + "' for column '" + colName + "'. "
                        + "Expected: STRING, INTEGER, BOOLEAN, DECIMAL");
            }
            columns.add(new CsvColumn(colName, type));
        }

        List<Map<String, Object>> rows = new ArrayList<>();
        for (int i = 1; i < lines.length; i++) {
            String line = lines[i].trim();
            if (line.isEmpty()) continue;
            String[] cells = line.split(",", -1);
            if (cells.length != columns.size()) {
                throw new IllegalArgumentException(
                        "CSV '" + name + "': row " + i + " has " + cells.length
                        + " cells, expected " + columns.size());
            }
            Map<String, Object> row = new LinkedHashMap<>();
            for (int j = 0; j < columns.size(); j++) {
                CsvColumn col = columns.get(j);
                row.put(col.name(), col.type().parse(cells[j].trim(), i, col.name()));
            }
            rows.add(Map.copyOf(row));
        }

        return new CsvDataSource(name, List.copyOf(columns), List.copyOf(rows));
    }
}
```

- [ ] **Step 4: Run test to verify all pass**

Run: `mvn --batch-mode -pl yaml-core test -Dtest=CsvParserTest`
Expected: all tests PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-core/
git commit -m "feat(yaml-core): CSV typed data source (CsvParser, CsvColumnType) Refs #247"
```

---

### Task 4: ForEach expansion

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ForEachAdapter.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ForEachExpander.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/foreach/ForEachExpanderTest.java`

**Interfaces:**
- Consumes: `VariableResolver` (Task 2), `Truthiness` (Task 1), `IterationGroup` (Task 1), `ExpansionResult` (Task 1)
- Produces: `ForEachExpander.expand(Map<String, E>, Map<String, IterationGroup>, VariableResolver, ForEachAdapter<E>, int)` → `ExpansionResult<E>`

- [ ] **Step 1: Write ForEachExpanderTest (failing)**

Create `yaml-core/src/test/java/io/casehub/yaml/core/foreach/ForEachExpanderTest.java`:

```java
package io.casehub.yaml.core.foreach;

import io.casehub.yaml.core.resolver.VariableResolver;
import io.casehub.yaml.core.resolver.VariableSource;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ForEachExpanderTest {

    record TestElement(String id, String type, Map<String, Object> spec,
                       String when, Object forEach) {}

    private static final ForEachAdapter<TestElement> ADAPTER = new ForEachAdapter<>() {
        @Override
        public TestElement stamp(TestElement template, String stampedId,
                                 VariableResolver scopedResolver) {
            Map<String, Object> resolvedSpec = scopedResolver.resolveMap(template.spec(), stampedId);
            return new TestElement(stampedId, template.type(), resolvedSpec,
                    template.when(), template.forEach());
        }

        @Override
        public Object getForEach(TestElement element) { return element.forEach(); }

        @Override
        public String getId(TestElement element) { return element.id(); }

        @Override
        public String getWhen(TestElement element) { return element.when(); }
    };

    private final VariableResolver resolver = new VariableResolver(Map.of(), Set.of());

    @Test
    void inline_forEach_stamps_three_copies() {
        Map<String, Object> inlineForEach = Map.of("as", "region",
                "in", List.of("us-east", "eu-west", "ap-south"));
        var elements = new LinkedHashMap<String, TestElement>();
        elements.put("regional-source", new TestElement("regional-source", "data-source",
                Map.of("name", "${each.region}", "uri", "s3://${each.region}/data.csv"),
                null, inlineForEach));

        var result = ForEachExpander.expand(elements, Map.of(), resolver, ADAPTER, 1000);

        assertThat(result.elements()).hasSize(3);
        assertThat(result.elements().stream().map(TestElement::id).toList())
                .containsExactlyInAnyOrder("regional-source.us-east",
                        "regional-source.eu-west", "regional-source.ap-south");
        TestElement usEast = result.elements().stream()
                .filter(e -> e.id().equals("regional-source.us-east"))
                .findFirst().orElseThrow();
        assertThat(usEast.spec().get("name")).isEqualTo("us-east");
        assertThat(usEast.spec().get("uri")).isEqualTo("s3://us-east/data.csv");
    }

    @Test
    void named_group_forEach() {
        var iterations = Map.of("regional",
                new IterationGroup("region", List.of("us-east", "eu-west")));
        var elements = new LinkedHashMap<String, TestElement>();
        elements.put("source", new TestElement("source", "data-source",
                Map.of("name", "${each.region}"),
                null, "regional"));

        var result = ForEachExpander.expand(elements, iterations, resolver, ADAPTER, 1000);

        assertThat(result.elements()).hasSize(2);
        assertThat(result.elements().stream().map(TestElement::id).toList())
                .containsExactlyInAnyOrder("source.us-east", "source.eu-west");
    }

    @Test
    void forEach_plus_when_excludes() {
        var varResolver = new VariableResolver(
                Map.of("var", (VariableSource) name -> "false".equals(name) ? null :
                        name.equals("enable") ? "false" : null), Set.of());
        var resolverWithVar = new VariableResolver(
                Map.of("var", (VariableSource) Map.of("enable", "false")::get), Set.of());
        Map<String, Object> inlineForEach = Map.of("as", "region",
                "in", List.of("us-east", "eu-west"));
        var elements = new LinkedHashMap<String, TestElement>();
        elements.put("source", new TestElement("source", "data-source",
                Map.of("name", "${each.region}"),
                "${var.enable}", inlineForEach));

        var result = ForEachExpander.expand(elements, Map.of(), resolverWithVar, ADAPTER, 1000);

        assertThat(result.elements()).isEmpty();
        assertThat(result.excludedIds())
                .containsExactlyInAnyOrder("source.us-east", "source.eu-west");
    }

    @Test
    void when_without_forEach_excludes() {
        var resolverWithVar = new VariableResolver(
                Map.of("var", (VariableSource) Map.of("debug", "false")::get), Set.of());
        var elements = new LinkedHashMap<String, TestElement>();
        elements.put("logger", new TestElement("logger", "sink",
                Map.of("name", "log"),
                "${var.debug}", null));

        var result = ForEachExpander.expand(elements, Map.of(), resolverWithVar, ADAPTER, 1000);

        assertThat(result.elements()).isEmpty();
        assertThat(result.excludedIds()).contains("logger");
    }

    @Test
    void expansion_limit_throws() {
        Map<String, Object> inlineForEach = Map.of("as", "idx",
                "in", List.of("1", "2", "3", "4", "5"));
        var elements = new LinkedHashMap<String, TestElement>();
        elements.put("node", new TestElement("node", "type",
                Map.of("name", "${each.idx}"),
                null, inlineForEach));

        assertThatThrownBy(() -> ForEachExpander.expand(
                elements, Map.of(), resolver, ADAPTER, 3))
                .hasMessageContaining("node")
                .hasMessageContaining("5")
                .hasMessageContaining("3");
    }

    @Test
    void zero_values_produces_empty() {
        Map<String, Object> inlineForEach = Map.of("as", "idx", "in", List.of());
        var elements = new LinkedHashMap<String, TestElement>();
        elements.put("empty", new TestElement("empty", "type",
                Map.of("name", "x"),
                null, inlineForEach));

        var result = ForEachExpander.expand(elements, Map.of(), resolver, ADAPTER, 1000);

        assertThat(result.elements()).isEmpty();
    }

    @Test
    void mixed_forEach_and_fixed() {
        var iterations = Map.of("regional",
                new IterationGroup("region", List.of("us-east", "eu-west")));
        var elements = new LinkedHashMap<String, TestElement>();
        elements.put("fixed-db", new TestElement("fixed-db", "data-source",
                Map.of("name", "db"), null, null));
        elements.put("regional-source", new TestElement("regional-source", "data-source",
                Map.of("name", "${each.region}"),
                null, "regional"));

        var result = ForEachExpander.expand(elements, iterations, resolver, ADAPTER, 1000);

        assertThat(result.elements()).hasSize(3);
    }

    @Test
    void when_true_includes() {
        var resolverWithVar = new VariableResolver(
                Map.of("var", (VariableSource) Map.of("enabled", "yes")::get), Set.of());
        var elements = new LinkedHashMap<String, TestElement>();
        elements.put("node", new TestElement("node", "type",
                Map.of("name", "x"),
                "${var.enabled}", null));

        var result = ForEachExpander.expand(elements, Map.of(), resolverWithVar, ADAPTER, 1000);

        assertThat(result.elements()).hasSize(1);
        assertThat(result.excludedIds()).isEmpty();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode -pl yaml-core test -Dtest=ForEachExpanderTest`
Expected: compilation error — `ForEachAdapter`, `ForEachExpander` do not exist

- [ ] **Step 3: Implement ForEachAdapter**

Create `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ForEachAdapter.java`:

```java
package io.casehub.yaml.core.foreach;

import io.casehub.yaml.core.resolver.VariableResolver;

public interface ForEachAdapter<E> {

    E stamp(E template, String stampedId, VariableResolver scopedResolver);

    Object getForEach(E element);

    String getId(E element);

    String getWhen(E element);
}
```

- [ ] **Step 4: Implement ForEachExpander**

Create `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ForEachExpander.java`:

```java
package io.casehub.yaml.core.foreach;

import io.casehub.yaml.core.condition.Truthiness;
import io.casehub.yaml.core.resolver.VariableResolver;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

public final class ForEachExpander {

    private ForEachExpander() {}

    @SuppressWarnings("unchecked")
    public static <E> ExpansionResult<E> expand(
            Map<String, E> elements,
            Map<String, IterationGroup> iterationGroups,
            VariableResolver resolver,
            ForEachAdapter<E> adapter,
            int maxExpansion) {

        List<E> expanded = new ArrayList<>();
        Set<String> excludedIds = new HashSet<>();
        Map<String, String> elementToGroup = new LinkedHashMap<>();
        Map<String, List<String>> groupValues = new LinkedHashMap<>();

        for (Map.Entry<String, E> entry : elements.entrySet()) {
            String id = entry.getKey();
            E element = entry.getValue();
            Object forEach = adapter.getForEach(element);

            if (forEach == null) {
                elementToGroup.put(id, null);
                continue;
            }

            String groupKey;
            List<String> values;

            if (forEach instanceof String groupRef) {
                groupKey = groupRef;
                if (!groupValues.containsKey(groupRef)) {
                    IterationGroup group = iterationGroups.get(groupRef);
                    if (group == null) {
                        throw new IllegalArgumentException(
                                "forEach references unknown group '" + groupRef
                                + "' on element '" + id + "'");
                    }
                    values = group.inAsList().stream().map(Object::toString).toList();
                    groupValues.put(groupRef, values);
                }
                values = groupValues.get(groupRef);
            } else if (forEach instanceof Map<?, ?> inlineMap) {
                groupKey = "__inline__" + id;
                List<?> in = (List<?>) inlineMap.get("in");
                if (in == null) {
                    throw new IllegalArgumentException(
                            "Inline forEach on '" + id + "' must have an 'in' key");
                }
                values = in.stream()
                        .map(item -> {
                            if (!(item instanceof String)) {
                                throw new IllegalArgumentException(
                                        "forEach '" + id + "': values must be strings, got "
                                        + item.getClass().getSimpleName() + " (" + item + ")");
                            }
                            return (String) item;
                        })
                        .toList();
                groupValues.put(groupKey, values);
            } else {
                throw new IllegalArgumentException(
                        "Invalid forEach on element '" + id + "'");
            }

            elementToGroup.put(id, groupKey);

            if (values.size() > maxExpansion) {
                throw new IllegalStateException(
                        "forEach on '" + id + "' would expand to " + values.size()
                        + " elements (limit: " + maxExpansion + ")");
            }
        }

        for (Map.Entry<String, E> entry : elements.entrySet()) {
            String id = entry.getKey();
            E element = entry.getValue();
            String groupKey = elementToGroup.get(id);

            if (groupKey == null) {
                String when = adapter.getWhen(element);
                if (when != null) {
                    String resolvedWhen = resolver.resolveString(when, id);
                    if (!Truthiness.isTruthy(resolvedWhen)) {
                        excludedIds.add(id);
                        continue;
                    }
                }
                expanded.add(adapter.stamp(element, id, resolver));
                continue;
            }

            List<String> values = groupValues.get(groupKey);
            String as = resolveAs(adapter.getForEach(element), iterationGroups);

            for (String value : values) {
                String stampedId = id + "." + value;
                VariableResolver eachResolver = resolver.withEachContext(Map.of(as, value));

                String when = adapter.getWhen(element);
                if (when != null) {
                    String resolvedWhen = eachResolver.resolveString(when, stampedId);
                    if (!Truthiness.isTruthy(resolvedWhen)) {
                        excludedIds.add(stampedId);
                        continue;
                    }
                }

                expanded.add(adapter.stamp(element, stampedId, eachResolver));
            }
        }

        return new ExpansionResult<>(expanded, excludedIds);
    }

    @SuppressWarnings("unchecked")
    private static String resolveAs(Object forEach,
                                     Map<String, IterationGroup> groups) {
        if (forEach instanceof String groupRef) {
            return groups.get(groupRef).as();
        }
        if (forEach instanceof Map<?, ?> m) {
            return (String) m.get("as");
        }
        throw new IllegalArgumentException("Invalid forEach: " + forEach);
    }
}
```

- [ ] **Step 5: Run test to verify all pass**

Run: `mvn --batch-mode -pl yaml-core test -Dtest=ForEachExpanderTest`
Expected: all tests PASS

- [ ] **Step 6: Run full module test suite**

Run: `mvn --batch-mode -pl yaml-core test`
Expected: all tests across all 4 test classes PASS

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-core/
git commit -m "feat(yaml-core): ForEach expansion with generic adapter pattern Refs #247"
```

---

## Batch 3: Schema fragments and verification

### Task 5: JSON Schema fragments + full build

**Files:**
- Create: `yaml-core/src/main/resources/schema/foreach.schema.json`
- Create: `yaml-core/src/main/resources/schema/when.schema.json`
- Create: `yaml-core/src/main/resources/schema/iterations.schema.json`
- Create: `yaml-core/src/main/resources/schema/data.schema.json`
- Create: `yaml-core/src/main/resources/schema/variable.schema.json`

**Interfaces:**
- Consumes: nothing (resource files only)
- Produces: JSON Schema fragments composable via `$ref` by downstream domains

- [ ] **Step 1: Create schema fragments**

Create `yaml-core/src/main/resources/schema/foreach.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://casehub.io/yaml-core/foreach.schema.json",
  "title": "ForEach",
  "description": "Stamps multiple copies of an element. Either a reference to a named iteration group (string) or an inline definition with 'as' (loop variable name) and 'in' (values to iterate).",
  "oneOf": [
    {
      "type": "string",
      "description": "Reference to a named iteration group defined in the iterations section"
    },
    {
      "type": "object",
      "properties": {
        "as": { "type": "string", "description": "Loop variable name, accessible as ${each.<as>}" },
        "in": {
          "type": "array",
          "items": { "type": "string" },
          "description": "Values to iterate over — each produces a stamped copy with ID suffix"
        }
      },
      "required": ["as", "in"],
      "additionalProperties": false
    }
  ]
}
```

Create `yaml-core/src/main/resources/schema/when.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://casehub.io/yaml-core/when.schema.json",
  "title": "When",
  "description": "Conditional inclusion. Value is resolved as a variable expression, then evaluated as a boolean (true/false/yes/no/on/off/y/n/1/0). When false, the element is excluded.",
  "type": "string"
}
```

Create `yaml-core/src/main/resources/schema/iterations.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://casehub.io/yaml-core/iterations.schema.json",
  "title": "Iterations",
  "description": "Named iteration groups, shared across multiple elements. Elements referencing the same group align their stamped IDs.",
  "type": "object",
  "additionalProperties": {
    "type": "object",
    "properties": {
      "as": { "type": "string", "description": "Loop variable name" },
      "in": {
        "oneOf": [
          {
            "type": "array",
            "items": { "type": "string" },
            "description": "Inline string values"
          },
          {
            "type": "string",
            "description": "Reference to a data source name"
          }
        ]
      }
    },
    "required": ["as", "in"],
    "additionalProperties": false
  }
}
```

Create `yaml-core/src/main/resources/schema/data.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://casehub.io/yaml-core/data.schema.json",
  "title": "Data",
  "description": "Typed CSV data sources. Header row declares 'name:type' pairs (STRING, INTEGER, BOOLEAN, DECIMAL). Data rows are parsed and type-validated at compile time.",
  "type": "object",
  "additionalProperties": {
    "type": "object",
    "properties": {
      "inline": {
        "type": "string",
        "description": "Inline CSV content with typed header row"
      }
    },
    "required": ["inline"],
    "additionalProperties": false
  }
}
```

Create `yaml-core/src/main/resources/schema/variable.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://casehub.io/yaml-core/variable.schema.json",
  "title": "Variable Expression",
  "description": "Variable expressions use ${prefix.name} syntax. The domain declares which prefixes are available (e.g., 'var', 'params', 'step'). The built-in 'each' prefix is available during forEach expansion. Deferred prefixes pass through unresolved.",
  "type": "string",
  "pattern": ".*\\$\\{[^}]+}.*"
}
```

- [ ] **Step 2: Run full platform build to verify yaml-core integrates**

Run: `mvn --batch-mode -pl yaml-core install`
Expected: BUILD SUCCESS — compile, test, package, install all pass

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-core/
git commit -m "feat(yaml-core): JSON Schema fragments for YAML vocabulary composability Refs #247"
```

---

## References

- [2026-08-29-shared-yaml-core-design.md](/Users/mdproctor/claude/public/casehub/platform/specs/issue-247-shared-yaml-core/2026-08-29-shared-yaml-core-design.md) — refined design spec
- [casehub-parent/docs/specs/2026-08-29-shared-yaml-core-design.md](/Users/mdproctor/claude/casehub/parent/docs/specs/2026-08-29-shared-yaml-core-design.md) — parent spec
- [decisions.md](/Users/mdproctor/claude/public/casehub/platform/specs/issue-247-shared-yaml-core/decisions.md) — D1-D4 design decisions
- [io.casehub.desiredstate.yaml.resolver.VariableResolver] — source for variable resolver port
- [io.casehub.desiredstate.yaml.ForEachExpander] — source for forEach expander port
- [io.casehub.desiredstate.yaml.YamlGraphRecorder:217-226] — source for isTruthy port
- [io.casehub.desiredstate.yaml.model.YamlIterationGroup] — source for iteration group port
- [io.casehub.pages.scenario.runtime.VariableContext] — pages variable context (informs API design)
- [GitHub #247](https://github.com/casehubio/platform/issues/247) — focal issue
