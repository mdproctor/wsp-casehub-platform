# yaml-core API Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #255 — fix: yaml-core API parity — eliminate all migration regressions for desiredstate#128
**Issue group:** #255

**Goal:** Add four API improvements to yaml-core that eliminate migration regressions, unblocking desiredstate#128.

**Architecture:** All changes are additive — no breaking changes. `sourceFor` + `withChainedScope` on VariableResolver for ergonomic module scope layering. `IterationValueExpander` callback on ForEachExpander for consumer-provided value expansion (JSON arrays). `SectionDeserializer` + `SectionContentRewriter` on ModuleExpander for typed section conversion and reference rewriting during expansion. Typed accessor on `ExpandedModule`.

**Tech Stack:** Java 21, JUnit 5, AssertJ. No external dependencies.

## Global Constraints

- Zero external dependencies — yaml-core has only test-scope deps
- J2CL-transpilable — no reflection, no ConcurrentHashMap, no CDI, no Jackson
- All utility classes: `final` with private constructor, static methods only
- Immutable-child pattern on VariableResolver — all `with*()` methods propagate all fields

---

## Batch 1: API Parity

### Task 1: sourceFor + withChainedScope on VariableResolver

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/resolver/VariableResolverTest.java`

**Interfaces:**
- Produces: `VariableSource sourceFor(String prefix)`, `VariableResolver withChainedScope(String prefix, VariableSource source)` — consumed by desiredstate#128 migration

- [ ] **Step 1: Write failing tests**

```java
// --- sourceFor ---

@Test
void sourceFor_returns_registered_source() {
    VariableSource source = name -> "val";
    var resolver = new VariableResolver(Map.of("var", source), Set.of());
    assertThat(resolver.sourceFor("var")).isSameAs(source);
}

@Test
void sourceFor_returns_null_for_unknown() {
    var resolver = new VariableResolver(Map.of(), Set.of());
    assertThat(resolver.sourceFor("var")).isNull();
}

// --- withChainedScope ---

@Test
void withChainedScope_layers_ahead_of_existing() {
    VariableSource base = name -> "region".equals(name) ? "us-east" : null;
    var resolver = new VariableResolver(Map.of("var", base), Set.of());
    VariableSource module = name -> "region".equals(name) ? "eu-west" : null;
    var scoped = resolver.withChainedScope("var", module);
    assertThat(scoped.resolveString("${var.region}", "test")).isEqualTo("eu-west");
}

@Test
void withChainedScope_falls_through_to_existing() {
    VariableSource base = name -> "batch".equals(name) ? "500" : null;
    var resolver = new VariableResolver(Map.of("var", base), Set.of());
    VariableSource module = name -> null;
    var scoped = resolver.withChainedScope("var", module);
    assertThat(scoped.resolveString("${var.batch}", "test")).isEqualTo("500");
}

@Test
void withChainedScope_no_existing_source_registers_directly() {
    var resolver = new VariableResolver(Map.of(), Set.of());
    VariableSource module = name -> "region".equals(name) ? "us-east" : null;
    var scoped = resolver.withChainedScope("var", module);
    assertThat(scoped.resolveString("${var.region}", "test")).isEqualTo("us-east");
}

@Test
void withChainedScope_propagates_handler() {
    var captured = new java.util.concurrent.atomic.AtomicReference<String>();
    var resolver = new VariableResolver(Map.of(), Set.of("match"))
            .withDeferredPrefixHandler((p, k, c) -> captured.set(p));
    var scoped = resolver.withChainedScope("var", name -> "val");
    scoped.resolveString("${match.x}", "test");
    assertThat(captured.get()).isEqualTo("match");
}
```

- [ ] **Step 2: Run tests — verify compilation fails**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test --batch-mode -q`
Expected: compilation error — `sourceFor` and `withChainedScope` do not exist

- [ ] **Step 3: Implement sourceFor and withChainedScope**

Add to `VariableResolver.java` using `ide_insert_member`:

```java
public VariableSource sourceFor(String prefix) {
    return prefixSources.get(prefix);
}

public VariableResolver withChainedScope(String prefix, VariableSource source) {
    VariableSource existing = prefixSources.get(prefix);
    VariableSource chained = existing != null
            ? VariableSource.chain(source, existing) : source;
    return withScope(prefix, chained);
}
```

- [ ] **Step 4: Run tests — verify all pass**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test --batch-mode -q`
Expected: all tests pass

- [ ] **Step 5: Commit**

```
feat(yaml-core): sourceFor + withChainedScope on VariableResolver

sourceFor(prefix) returns the registered VariableSource for a prefix.
withChainedScope(prefix, source) layers a new source ahead of the
existing one — ergonomic module scope layering in one call.

Refs #255
```

### Task 2: IterationValueExpander on ForEachExpander

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/foreach/IterationValueExpander.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ForEachExpander.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/foreach/ForEachExpanderTest.java`

**Interfaces:**
- Consumes: existing `ForEachExpander.expand()` API
- Produces: `IterationValueExpander` functional interface + overloaded `expand()` — consumed by desiredstate#128

- [ ] **Step 1: Write failing tests**

```java
@Test
void valueExpander_splits_json_array() {
    var groups = Map.of("regional",
            new IterationGroup("region", List.of("[\"us-east\",\"eu-west\"]")));
    var elements = new LinkedHashMap<String, TestElement>();
    elements.put("source", new TestElement("source",
            Map.of("name", "${each.region}"), "regional", null));

    IterationValueExpander expander = (resolved, ctx) -> {
        if (resolved.startsWith("[")) {
            return List.of(resolved.substring(2, resolved.length() - 2).split("\",\""));
        }
        return List.of(resolved);
    };

    var result = ForEachExpander.expand(elements, groups, resolver,
            adapter, 1000, expander);

    assertThat(result.elements()).hasSize(2);
    assertThat(result.elements().containsKey("source.us-east")).isTrue();
    assertThat(result.elements().containsKey("source.eu-west")).isTrue();
}

@Test
void valueExpander_null_uses_default() {
    Map<String, Object> inlineForEach = Map.of("as", "x",
            "in", List.of("a", "b"));
    var elements = new LinkedHashMap<String, TestElement>();
    elements.put("node", new TestElement("node",
            Map.of("name", "${each.x}"), inlineForEach, null));

    var result = ForEachExpander.expand(elements, Map.of(), resolver,
            adapter, 1000, null);

    assertThat(result.elements()).hasSize(2);
}

@Test
void valueExpander_single_passthrough() {
    var groups = Map.of("env",
            new IterationGroup("e", List.of("prod")));
    var elements = new LinkedHashMap<String, TestElement>();
    elements.put("node", new TestElement("node",
            Map.of("name", "${each.e}"), "env", null));

    IterationValueExpander expander = (resolved, ctx) -> List.of(resolved);

    var result = ForEachExpander.expand(elements, groups, resolver,
            adapter, 1000, expander);

    assertThat(result.elements()).hasSize(1);
    assertThat(result.elements().containsKey("node.prod")).isTrue();
}
```

- [ ] **Step 2: Run tests — verify compilation fails**

- [ ] **Step 3: Create IterationValueExpander interface**

```java
package io.casehub.yaml.core.foreach;

@FunctionalInterface
public interface IterationValueExpander {
    java.util.List<String> expand(String resolvedValue, String groupContext);
}
```

- [ ] **Step 4: Add expand() overload with IterationValueExpander**

Add a new overload that accepts `IterationValueExpander`. The existing 5-arg overload delegates to it with null expander. In `resolveValues()`, after resolving each value, pass through the expander if non-null:

```java
// In resolveValues, replace:
//   values.add(s);
// With:
if (valueExpander != null) {
    try {
        values.addAll(valueExpander.expand(s, context));
    } catch (Exception e) {
        throw new IllegalArgumentException(
                "IterationValueExpander failed for group '" + context
                + "': resolved value '" + s + "'", e);
    }
} else {
    values.add(s);
}
```

- [ ] **Step 5: Run tests — verify all pass**

- [ ] **Step 6: Commit**

```
feat(yaml-core): IterationValueExpander callback on ForEachExpander

Consumer-provided callback for expanding resolved iteration values
(e.g., JSON array parsing). Called after variable resolution on each
value. Default: single-element list (current behaviour). Exceptions
wrapped with expansion context.

Refs #255
```

### Task 3: SectionDeserializer + SectionContentRewriter on ModuleExpander

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/SectionDeserializer.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/SectionContentRewriter.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleExpander.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/ExpandedModule.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/module/ModuleExpanderTest.java`

**Interfaces:**
- Consumes: existing `ModuleExpander.expand()`, `ExpandedModule`
- Produces: `SectionDeserializer`, `SectionContentRewriter`, typed `section()` accessor, overloaded `expand()`

- [ ] **Step 1: Write failing tests**

```java
// --- SectionDeserializer ---

record TypedNode(String type, Map<String, Object> spec, List<String> dependsOn) {}

@Test
void deserializer_converts_during_expansion() {
    var module = new YamlModule("m", Map.of(),
            Map.of("nodes", Map.of("check", Map.of("type", "sensor",
                    "spec", Map.of("uri", "s3://data"),
                    "dependsOn", List.of()))));
    var imp = new YamlImport("m", "a", null, Map.of());

    SectionDeserializer deserializer = (section, key, raw) -> {
        if ("nodes".equals(section)) {
            return new TypedNode(
                    (String) raw.get("type"),
                    raw.get("spec") instanceof Map ? (Map<String, Object>) raw.get("spec") : Map.of(),
                    raw.get("dependsOn") instanceof List ? ((List<?>) raw.get("dependsOn")).stream()
                            .map(Object::toString).toList() : List.of());
        }
        return raw;
    };

    var result = ModuleExpander.expand(List.of(imp),
            Map.of("m", module), Map.of(), deserializer, null);

    Object value = result.sections().get("nodes").get("a.check");
    assertThat(value).isInstanceOf(TypedNode.class);
    assertThat(((TypedNode) value).type()).isEqualTo("sensor");
}

@Test
void deserializer_null_passes_raw() {
    var module = new YamlModule("m", Map.of(),
            Map.of("nodes", Map.of("n", Map.of("type", "x"))));
    var imp = new YamlImport("m", "a", null, Map.of());
    var result = ModuleExpander.expand(List.of(imp),
            Map.of("m", module), Map.of(), null, null);
    assertThat(result.sections().get("nodes").get("a.n")).isInstanceOf(Map.class);
}

// --- SectionContentRewriter ---

@Test
void rewriter_receives_typed_objects() {
    var module = new YamlModule("m", Map.of(),
            Map.of("nodes", Map.of("alerter", Map.of("type", "alert",
                    "spec", Map.of(), "dependsOn", List.of("monitor")),
                    "monitor", Map.of("type", "sensor",
                    "spec", Map.of(), "dependsOn", List.of()))));
    var imp = new YamlImport("m", "pipe", null, Map.of());

    SectionDeserializer deserializer = (section, key, raw) ->
            new TypedNode((String) raw.get("type"),
                    raw.get("spec") instanceof Map ? (Map<String, Object>) raw.get("spec") : Map.of(),
                    raw.get("dependsOn") instanceof List ? ((List<?>) raw.get("dependsOn")).stream()
                            .map(Object::toString).toList() : List.of());

    SectionContentRewriter rewriter = (section, key, value, alias, moduleKeys) -> {
        if (value instanceof TypedNode node) {
            List<String> rewritten = node.dependsOn().stream()
                    .map(dep -> moduleKeys.contains(dep) ? alias + "." + dep : dep)
                    .toList();
            return new TypedNode(node.type(), node.spec(), rewritten);
        }
        return value;
    };

    var result = ModuleExpander.expand(List.of(imp),
            Map.of("m", module), Map.of(), deserializer, rewriter);

    TypedNode alerter = (TypedNode) result.sections().get("nodes").get("pipe.alerter");
    assertThat(alerter.dependsOn()).containsExactly("pipe.monitor");
}

// --- Typed accessor ---

@Test
void section_typed_accessor() {
    var module = new YamlModule("m", Map.of(),
            Map.of("nodes", Map.of("n", Map.of("type", "x",
                    "spec", Map.of(), "dependsOn", List.of()))));
    var imp = new YamlImport("m", "a", null, Map.of());

    SectionDeserializer deserializer = (section, key, raw) ->
            new TypedNode((String) raw.get("type"),
                    raw.get("spec") instanceof Map ? (Map<String, Object>) raw.get("spec") : Map.of(),
                    List.of());

    var result = ModuleExpander.expand(List.of(imp),
            Map.of("m", module), Map.of(), deserializer, null);

    Map<String, TypedNode> nodes = result.section("nodes");
    assertThat(nodes.get("a.n").type()).isEqualTo("x");
}

@Test
void section_accessor_returns_empty_for_unknown() {
    var result = ModuleExpander.expand(List.of(), Map.of(), Map.of(), null, null);
    Map<String, Object> unknown = result.section("nonexistent");
    assertThat(unknown).isEmpty();
}
```

- [ ] **Step 2: Run tests — verify compilation fails**

- [ ] **Step 3: Create SectionDeserializer and SectionContentRewriter**

```java
// SectionDeserializer.java
package io.casehub.yaml.core.module;

import java.util.Map;

@FunctionalInterface
public interface SectionDeserializer {
    Object deserialize(String sectionName, String entryKey, Map<String, Object> rawEntry);
}
```

```java
// SectionContentRewriter.java
package io.casehub.yaml.core.module;

import java.util.Set;

@FunctionalInterface
public interface SectionContentRewriter {
    Object rewrite(String sectionName, String entryKey, Object entryValue,
                   String alias, Set<String> moduleKeys);
}
```

- [ ] **Step 4: Add typed accessor to ExpandedModule**

```java
@SuppressWarnings("unchecked")
public <T> Map<String, T> section(String name) {
    return (Map<String, T>) (Map<String, ?>)
            sections.getOrDefault(name, Map.of());
}
```

- [ ] **Step 5: Add expand() overload with deserializer + rewriter**

Add 5-arg overload. Existing 3-arg delegates with `null, null`. In the expansion loop:

```java
Object value = contentEntry.getValue();
if (deserializer != null && value instanceof Map) {
    @SuppressWarnings("unchecked")
    Map<String, Object> rawMap = (Map<String, Object>) value;
    value = deserializer.deserialize(sectionName, contentEntry.getKey(), rawMap);
}
if (rewriter != null) {
    value = rewriter.rewrite(sectionName, contentEntry.getKey(), value,
            imp.as(), module.sections().get(sectionName).keySet());
}
targetSection.put(prefixedKey, value);
```

- [ ] **Step 6: Run tests — verify all pass**

- [ ] **Step 7: Full build**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test --batch-mode -q`
Expected: all tests pass

- [ ] **Step 8: Commit**

```
feat(yaml-core): SectionDeserializer + SectionContentRewriter + typed accessor

SectionDeserializer converts raw Map entries to typed domain objects
during expansion. SectionContentRewriter rewrites internal references
on the typed objects. ExpandedModule.section(name) provides typed access
via unchecked cast — safe because the consumer controls the deserializer.

Closes #255
Refs #255
```

## References

- `specs/issue-255-yaml-core-api-parity/2026-09-01-yaml-core-api-parity-design.md` — design spec
- `specs/issue-255-yaml-core-api-parity/decisions.md` — D1–D4 decisions
- `io.casehub.yaml.core.resolver.VariableResolver` — Task 1 target
- `io.casehub.yaml.core.foreach.ForEachExpander` — Task 2 target
- `io.casehub.yaml.core.module.ModuleExpander` — Task 3 target
- `io.casehub.yaml.core.module.ExpandedModule` — Task 3 target
- casehubio/platform#255 — focal issue
- casehubio/casehub-desiredstate#128 — migration blocked until this lands
