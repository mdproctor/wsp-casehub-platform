# yaml-core Module System + API Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #253 — fix: yaml-core ForEachExpander API — return ID mapping, not bare list
**Issue group:** #252, #253

**Goal:** Fix two API regressions in yaml-core (#253), then add a generic YAML module system (#252) for parameter validation, alias-prefixed expansion, and import merging.

**Architecture:** #253 changes `ExpansionResult` from `List<E>` to `LinkedHashMap<String, E>` and adds `DeferredPrefixHandler` to `VariableResolver`. #252 adds a new `io.casehub.yaml.core.module` package with `YamlModule` (generic sections), `ParameterValidator` (collect-all, type-aware constraints), and `ModuleExpander` (structural expansion without domain coupling). All code is pure Java, zero dependencies, J2CL-transpilable.

**Tech Stack:** Java 21, JUnit 5, AssertJ. No external dependencies.

## Global Constraints

- Zero external dependencies — `yaml-core/pom.xml` has only `junit-jupiter` and `assertj-core` (test scope)
- J2CL-transpilable — no reflection, no `ConcurrentHashMap`, no CDI, no Jackson, no `synchronized`
- Records, sealed interfaces, `List.of()`, `Map.of()`, `Map.copyOf()` are fine
- All utility classes: `final` with private constructor, static methods only
- Package: existing types in their current packages; new types in `io.casehub.yaml.core.module`

---

## Batch 1: API Fixes (#253)

### Task 1: ExpansionResult Map + duplicate ID detection

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ExpansionResult.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ForEachExpander.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/foreach/ForEachExpanderTest.java`

**Interfaces:**
- Produces: `ExpansionResult<E>(LinkedHashMap<String, E> elements, Set<String> excludedIds)` — consumed by all existing and future callers

- [ ] **Step 1: Update ExpansionResult record**

Change field type from `List<E>` to `LinkedHashMap<String, E>`:

```java
public record ExpansionResult<E>(LinkedHashMap<String, E> elements,
                                  Set<String> excludedIds) {}
```

- [ ] **Step 2: Update ForEachExpander to build LinkedHashMap**

Replace `List<E> allElements = new ArrayList<>()` with `LinkedHashMap<String, E> allElements = new LinkedHashMap<>()`.

For fixed elements:
```java
allElements.put(elementId, adapter.stamp(element, elementId, resolver));
```

For forEach elements, add duplicate detection before put:
```java
if (allElements.containsKey(stampedId)) {
    throw new IllegalStateException("Duplicate stamped ID '" + stampedId
            + "' — forEach values must be unique within each template.");
}
allElements.put(stampedId, adapter.stamp(element, stampedId, eachResolver));
```

Remove `List.copyOf()` wrap — return the `LinkedHashMap` directly (already insertion-ordered).

- [ ] **Step 3: Migrate all 15 existing ForEachExpanderTest tests**

Every test that calls `result.elements()` now gets a `LinkedHashMap<String, E>`. Update assertions:

- `result.elements().hasSize(N)` → `result.elements().size()` is N (same — Map has size())
- `result.elements().stream().map(TestElement::id).toList()` → `new ArrayList<>(result.elements().keySet())`
- `result.elements().get(0)` → `result.elements().get("node-id")` (lookup by key)
- `result.elements().stream().filter(...)` → `result.elements().values().stream().filter(...)`

- [ ] **Step 4: Add duplicate stampedId test**

```java
@Test
void duplicate_forEach_values_throws() {
    Map<String, Object> inlineForEach = Map.of("as", "x",
            "in", List.of("same", "same"));
    var elements = new LinkedHashMap<String, TestElement>();
    elements.put("node", new TestElement("node",
            Map.of("name", "${each.x}"), inlineForEach, null));

    assertThatThrownBy(() -> ForEachExpander.expand(elements, Map.of(),
            resolver, adapter, 1000))
            .isInstanceOf(IllegalStateException.class)
            .hasMessageContaining("Duplicate stamped ID")
            .hasMessageContaining("node.same");
}
```

- [ ] **Step 5: Run tests, verify all pass**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test --batch-mode -q`
Expected: all tests pass (15 migrated + 1 new = 16 forEach tests)

- [ ] **Step 6: Commit**

```
feat(yaml-core): ExpansionResult returns LinkedHashMap keyed by stamped ID

Fixes the lost-ID regression — forEach expansion now preserves the
stampedId→element mapping. Duplicate forEach values are detected and
throw IllegalStateException.

Closes #253 (partial — DeferredPrefixHandler in Task 2)
Refs #253
```

### Task 2: DeferredPrefixHandler callback

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/DeferredPrefixHandler.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableResolver.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/resolver/VariableResolverTest.java`

**Interfaces:**
- Consumes: existing `VariableResolver` API
- Produces: `DeferredPrefixHandler` functional interface + `withDeferredPrefixHandler()` method

- [ ] **Step 1: Write failing tests for handler invocation**

Add to `VariableResolverTest`:

```java
@Test
void deferred_prefix_handler_invoked_on_hit() {
    var captured = new java.util.concurrent.atomic.AtomicReference<String>();
    var resolver = new VariableResolver(Map.of(), Set.of("match"))
            .withDeferredPrefixHandler((prefix, key, ctx) ->
                    captured.set(prefix + ":" + key));
    resolver.resolveString("${match.sink.id}", "rule");
    assertThat(captured.get()).isEqualTo("match:match.sink.id");
}

@Test
void deferred_prefix_handler_can_throw() {
    var resolver = new VariableResolver(Map.of(), Set.of("match"))
            .withDeferredPrefixHandler((prefix, key, ctx) -> {
                throw new UnresolvedVariableException(key, ctx,
                        prefix + " refs resolved at runtime");
            });
    assertThatThrownBy(() -> resolver.resolveString("${match.sink.id}", "node"))
            .isInstanceOf(UnresolvedVariableException.class)
            .hasMessageContaining("runtime");
}

@Test
void no_handler_deferred_passes_through_silently() {
    var resolver = new VariableResolver(Map.of(), Set.of("match"));
    assertThat(resolver.resolveString("${match.sink.id}", "rule"))
            .isEqualTo("${match.sink.id}");
}

@Test
void handler_survives_withEachContext() {
    var captured = new java.util.concurrent.atomic.AtomicReference<String>();
    var resolver = new VariableResolver(Map.of(), Set.of("match"))
            .withDeferredPrefixHandler((prefix, key, ctx) ->
                    captured.set(prefix));
    var child = resolver.withEachContext(Map.of("region", "us-east"));
    child.resolveString("${match.x}", "test");
    assertThat(captured.get()).isEqualTo("match");
}

@Test
void handler_survives_withScope() {
    var captured = new java.util.concurrent.atomic.AtomicReference<String>();
    var resolver = new VariableResolver(Map.of(), Set.of("fault"))
            .withDeferredPrefixHandler((prefix, key, ctx) ->
                    captured.set(prefix));
    var child = resolver.withScope("var", name -> "val");
    child.resolveString("${fault.nodeId}", "test");
    assertThat(captured.get()).isEqualTo("fault");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test --batch-mode -q`
Expected: compilation error — `withDeferredPrefixHandler` does not exist

- [ ] **Step 3: Create DeferredPrefixHandler interface**

```java
package io.casehub.yaml.core.resolver;

@FunctionalInterface
public interface DeferredPrefixHandler {
    void onDeferred(String prefix, String key, String elementContext);
}
```

- [ ] **Step 4: Add handler field to VariableResolver**

Add `private final DeferredPrefixHandler deferredPrefixHandler` field. Update the private constructor to 5 parameters. Add `withDeferredPrefixHandler()` method. Update ALL existing `with*()` methods to propagate the handler:

```java
private VariableResolver(Map<String, VariableSource> prefixSources,
                         Set<String> deferredPrefixes,
                         Map<String, String> eachContext,
                         Map<String, Map<String, Object>> eachRowContext,
                         DeferredPrefixHandler deferredPrefixHandler) {
    // ... assign all 5 fields
}

public VariableResolver withDeferredPrefixHandler(DeferredPrefixHandler handler) {
    return new VariableResolver(prefixSources, deferredPrefixes,
            eachContext, eachRowContext, handler);
}

public VariableResolver withEachContext(Map<String, String> eachContext) {
    return new VariableResolver(prefixSources, deferredPrefixes,
            eachContext, eachRowContext, deferredPrefixHandler);
}

public VariableResolver withEachRowContext(Map<String, Map<String, Object>> rowContext) {
    return new VariableResolver(prefixSources, deferredPrefixes,
            eachContext, rowContext, deferredPrefixHandler);
}

public VariableResolver withScope(String prefix, VariableSource source) {
    var newSources = new LinkedHashMap<>(prefixSources);
    newSources.put(prefix, source);
    return new VariableResolver(Map.copyOf(newSources), deferredPrefixes,
            eachContext, eachRowContext, deferredPrefixHandler);
}
```

In `lookupVariable()`, update deferred prefix handling:
```java
if (deferredPrefixes.contains(prefix)) {
    if (deferredPrefixHandler != null) {
        deferredPrefixHandler.onDeferred(prefix, key, elementContext);
    }
    return null;
}
```

The public 2-arg constructor passes `null` for the handler (preserving current behaviour).

- [ ] **Step 5: Run tests, verify all pass**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test --batch-mode -q`
Expected: all tests pass (existing + 5 new handler tests)

- [ ] **Step 6: Commit**

```
fix(yaml-core): DeferredPrefixHandler for context-dependent deferred prefix diagnostics

Adds @FunctionalInterface DeferredPrefixHandler invoked when a deferred
prefix is encountered. Handler propagates through all with*() immutable-child
methods. Default: null (silent pass-through — preserves current behaviour).

Closes #253
Refs #253
```

## Batch 2: Module Model + Parameter Validation (#252)

### Task 3: Module model types + ParameterType

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterType.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleParameter.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModule.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlImport.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleFile.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/module/ParameterTypeTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/module/YamlModuleFileTest.java`

**Interfaces:**
- Consumes: `Truthiness.isTruthy()` (for BOOLEAN parsing)
- Produces: `YamlModule`, `YamlModuleParameter`, `ParameterType`, `YamlImport`, `YamlModuleFile` — consumed by Tasks 4 and 5

- [ ] **Step 1: Write ParameterTypeTest**

```java
@Test
void string_returns_value() {
    assertThat(ParameterType.STRING.parse("hello")).isEqualTo("hello");
}

@Test
void list_splits_on_comma() {
    assertThat(ParameterType.LIST.parse("a, b, c")).isEqualTo(List.of("a", "b", "c"));
}

@Test
void list_single_value() {
    assertThat(ParameterType.LIST.parse("only")).isEqualTo(List.of("only"));
}

@Test
void integer_parses() {
    assertThat(ParameterType.INTEGER.parse("42")).isEqualTo(42);
}

@Test
void integer_invalid_throws() {
    assertThatThrownBy(() -> ParameterType.INTEGER.parse("abc"))
            .isInstanceOf(NumberFormatException.class);
}

@Test
void number_parses() {
    assertThat(ParameterType.NUMBER.parse("3.14")).isEqualTo(3.14);
}

@Test
void boolean_parses_truthy() {
    assertThat(ParameterType.BOOLEAN.parse("yes")).isEqualTo(true);
}

@Test
void boolean_parses_falsy() {
    assertThat(ParameterType.BOOLEAN.parse("no")).isEqualTo(false);
}
```

- [ ] **Step 2: Write YamlModuleFileTest**

```java
@Test
void toModule_converts_header_and_sections() {
    var header = new YamlModuleFile.YamlModuleHeader("monitor", Map.of());
    var sections = Map.of("nodes", Map.<String, Object>of("cpu-check",
            Map.of("type", "sensor")));
    var file = new YamlModuleFile(header, sections, List.of());
    var module = file.toModule();
    assertThat(module.name()).isEqualTo("monitor");
    assertThat(module.sections()).containsKey("nodes");
}

@Test
void toModule_discards_imports() {
    var header = new YamlModuleFile.YamlModuleHeader("m", Map.of());
    var imp = new YamlImport("other", "alias", null, Map.of());
    var file = new YamlModuleFile(header, Map.of(), List.of(imp));
    var module = file.toModule();
    assertThat(module.sections()).isEmpty();
}

@Test
void null_defaults() {
    var header = new YamlModuleFile.YamlModuleHeader("m", null);
    var file = new YamlModuleFile(header, null, null);
    assertThat(header.parameters()).isEmpty();
    assertThat(file.sections()).isEmpty();
    assertThat(file.imports()).isEmpty();
}
```

- [ ] **Step 3: Run tests — verify compilation fails**

- [ ] **Step 4: Implement all model types**

Create `ParameterType`, `YamlModuleParameter`, `YamlModule`, `YamlImport`, `YamlModuleFile` as specified in the design spec. All records with compact constructors defaulting nulls.

- [ ] **Step 5: Run tests, verify all pass**

- [ ] **Step 6: Commit**

```
feat(yaml-core): module model types — YamlModule, ParameterType, YamlImport, YamlModuleFile

Generic module model with opaque Map<String, Map<String, Object>> sections.
ParameterType enum (STRING/LIST/INTEGER/NUMBER/BOOLEAN) with transient parsing.
YamlModuleParameter with typed constraints (minLength/maxLength/pattern/minimum/maximum).

Refs #252
```

### Task 4: ParameterValidator + error types

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterViolation.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterValidationException.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterValidator.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/module/ParameterValidatorTest.java`

**Interfaces:**
- Consumes: `YamlModuleParameter`, `ParameterType` from Task 3
- Produces: `ParameterValidator.validate()`, `ParameterValidator.validateOrThrow()` — consumed by Task 5

- [ ] **Step 1: Write ParameterValidatorTest**

```java
@Test
void required_missing_returns_violation() {
    var declared = Map.of("region", new YamlModuleParameter(
            ParameterType.STRING, true, null, null, null, null, null, null));
    var violations = ParameterValidator.validate(declared, Map.of());
    assertThat(violations).hasSize(1);
    assertThat(violations.get(0).parameterName()).isEqualTo("region");
    assertThat(violations.get(0).constraint()).isEqualTo("required");
}

@Test
void required_with_default_passes() {
    var declared = Map.of("region", new YamlModuleParameter(
            ParameterType.STRING, true, "us-east", null, null, null, null, null));
    var violations = ParameterValidator.validate(declared, Map.of());
    assertThat(violations).isEmpty();
}

@Test
void minLength_string_violation() {
    var declared = Map.of("name", new YamlModuleParameter(
            ParameterType.STRING, false, null, 5, null, null, null, null));
    var violations = ParameterValidator.validate(declared, Map.of("name", "ab"));
    assertThat(violations).hasSize(1);
    assertThat(violations.get(0).constraint()).isEqualTo("minLength");
}

@Test
void minLength_list_counts_elements() {
    var declared = Map.of("tags", new YamlModuleParameter(
            ParameterType.LIST, false, null, 3, null, null, null, null));
    var violations = ParameterValidator.validate(declared, Map.of("tags", "a,b"));
    assertThat(violations).hasSize(1);
    assertThat(violations.get(0).constraint()).isEqualTo("minLength");
}

@Test
void pattern_violation() {
    var declared = Map.of("id", new YamlModuleParameter(
            ParameterType.STRING, false, null, null, null, "^[a-z]+$", null, null));
    var violations = ParameterValidator.validate(declared, Map.of("id", "ABC123"));
    assertThat(violations).hasSize(1);
    assertThat(violations.get(0).constraint()).isEqualTo("pattern");
}

@Test
void minimum_violation() {
    var declared = Map.of("port", new YamlModuleParameter(
            ParameterType.INTEGER, false, null, null, null, null, 1024, null));
    var violations = ParameterValidator.validate(declared, Map.of("port", "80"));
    assertThat(violations).hasSize(1);
    assertThat(violations.get(0).constraint()).isEqualTo("minimum");
}

@Test
void maximum_violation() {
    var declared = Map.of("rate", new YamlModuleParameter(
            ParameterType.NUMBER, false, null, null, null, null, null, 1.0));
    var violations = ParameterValidator.validate(declared, Map.of("rate", "1.5"));
    assertThat(violations).hasSize(1);
    assertThat(violations.get(0).constraint()).isEqualTo("maximum");
}

@Test
void type_parse_error_returns_violation() {
    var declared = Map.of("count", new YamlModuleParameter(
            ParameterType.INTEGER, false, null, null, null, null, null, null));
    var violations = ParameterValidator.validate(declared, Map.of("count", "abc"));
    assertThat(violations).hasSize(1);
    assertThat(violations.get(0).constraint()).isEqualTo("type");
}

@Test
void collect_all_multiple_violations() {
    var declared = Map.of(
            "name", new YamlModuleParameter(ParameterType.STRING, true, null, null, null, null, null, null),
            "port", new YamlModuleParameter(ParameterType.INTEGER, false, null, null, null, null, 1024, null));
    var violations = ParameterValidator.validate(declared, Map.of("port", "80"));
    assertThat(violations).hasSize(2);
}

@Test
void unknown_parameter_returns_violation() {
    var declared = Map.of("region", new YamlModuleParameter(
            ParameterType.STRING, false, null, null, null, null, null, null));
    var violations = ParameterValidator.validate(declared, Map.of("reigon", "us-east"));
    assertThat(violations).hasSize(1);
    assertThat(violations.get(0).constraint()).isEqualTo("unknown");
    assertThat(violations.get(0).parameterName()).isEqualTo("reigon");
}

@Test
void validateOrThrow_throws_on_violations() {
    var declared = Map.of("x", new YamlModuleParameter(
            ParameterType.STRING, true, null, null, null, null, null, null));
    assertThatThrownBy(() -> ParameterValidator.validateOrThrow(declared, Map.of()))
            .isInstanceOf(ParameterValidationException.class)
            .satisfies(e -> assertThat(
                    ((ParameterValidationException) e).violations()).hasSize(1));
}

@Test
void validateOrThrow_silent_on_valid() {
    var declared = Map.of("x", new YamlModuleParameter(
            ParameterType.STRING, false, null, null, null, null, null, null));
    ParameterValidator.validateOrThrow(declared, Map.of("x", "ok"));
}

@Test
void valid_params_return_empty() {
    var declared = Map.of("region", new YamlModuleParameter(
            ParameterType.STRING, true, null, 2, 10, null, null, null));
    var violations = ParameterValidator.validate(declared, Map.of("region", "us-east"));
    assertThat(violations).isEmpty();
}
```

- [ ] **Step 2: Run tests — verify compilation fails**

- [ ] **Step 3: Implement ParameterViolation, ParameterValidationException, ParameterValidator**

`ParameterViolation` — record with 4 fields.
`ParameterValidationException` — extends RuntimeException, holds `List<ParameterViolation>`.
`ParameterValidator` — static `validate()` and `validateOrThrow()`. Iterates declared params, checks required/type/constraints. Also iterates provided params to detect unknown keys.

- [ ] **Step 4: Run tests, verify all pass**

- [ ] **Step 5: Commit**

```
feat(yaml-core): ParameterValidator with type-aware constraint checking

Collect-all validation: required, type parsing, minLength/maxLength
(string char count, list element count), pattern (regex), minimum/maximum
(numeric bounds). Unknown parameter detection for typo catching.
Dual API: validate() returns List, validateOrThrow() convenience.

Refs #252
```

## Batch 3: Module Expansion (#252)

### Task 5: ModuleExpander + ExpandedModule

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/ExpandedModule.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleExpander.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/module/ModuleExpanderTest.java`

**Interfaces:**
- Consumes: `YamlModule`, `YamlImport`, `ParameterValidator` from Tasks 3-4
- Produces: `ModuleExpander.expand()` → `ExpandedModule`

- [ ] **Step 1: Write ModuleExpanderTest**

```java
@Test
void alias_prefixes_section_keys() {
    var module = new YamlModule("monitor", Map.of(),
            Map.of("nodes", Map.of("cpu-check", Map.of("type", "sensor"))));
    var imp = new YamlImport("monitor", "infra", null, Map.of());
    var result = ModuleExpander.expand(List.of(imp), Map.of("monitor", module), Map.of());
    assertThat(result.sections().get("nodes")).containsKey("infra.cpu-check");
}

@Test
void parameter_resolution_builds_scope() {
    var param = new YamlModuleParameter(ParameterType.STRING, true, null,
            null, null, null, null, null);
    var module = new YamlModule("monitor", Map.of("threshold", param),
            Map.of("nodes", Map.of("check", Map.of("val", "x"))));
    var imp = new YamlImport("monitor", "mon", null, Map.of("threshold", "90"));
    var result = ModuleExpander.expand(List.of(imp), Map.of("monitor", module), Map.of());
    assertThat(result.moduleScopes().get("mon")).containsEntry("threshold", "90");
}

@Test
void default_parameter_used_when_not_provided() {
    var param = new YamlModuleParameter(ParameterType.STRING, false, "us-east",
            null, null, null, null, null);
    var module = new YamlModule("m", Map.of("region", param),
            Map.of("nodes", Map.of("n", Map.of())));
    var imp = new YamlImport("m", "a", null, Map.of());
    var result = ModuleExpander.expand(List.of(imp), Map.of("m", module), Map.of());
    assertThat(result.moduleScopes().get("a")).containsEntry("region", "us-east");
}

@Test
void multiple_imports_merge_sections() {
    var m1 = new YamlModule("a", Map.of(),
            Map.of("nodes", Map.of("n1", Map.of("t", "1"))));
    var m2 = new YamlModule("b", Map.of(),
            Map.of("nodes", Map.of("n2", Map.of("t", "2"))));
    var result = ModuleExpander.expand(
            List.of(new YamlImport("a", "x", null, Map.of()),
                    new YamlImport("b", "y", null, Map.of())),
            Map.of("a", m1, "b", m2), Map.of());
    assertThat(result.sections().get("nodes"))
            .containsKey("x.n1")
            .containsKey("y.n2");
}

@Test
void existing_sections_preserved() {
    var module = new YamlModule("m", Map.of(),
            Map.of("nodes", Map.of("new", Map.of())));
    var existing = Map.<String, Map<String, Object>>of(
            "nodes", Map.of("existing", Map.of("type", "fixed")));
    var result = ModuleExpander.expand(
            List.of(new YamlImport("m", "a", null, Map.of())),
            Map.of("m", module), existing);
    assertThat(result.sections().get("nodes"))
            .containsKey("existing")
            .containsKey("a.new");
}

@Test
void conditional_import_returns_importConditions() {
    var module = new YamlModule("m", Map.of(),
            Map.of("nodes", Map.of("n", Map.of())));
    var imp = new YamlImport("m", "a", "${var.enabled}", Map.of());
    var result = ModuleExpander.expand(List.of(imp), Map.of("m", module), Map.of());
    assertThat(result.importConditions()).containsEntry("a", "${var.enabled}");
}

@Test
void unconditional_import_null_in_importConditions() {
    var module = new YamlModule("m", Map.of(),
            Map.of("nodes", Map.of("n", Map.of())));
    var imp = new YamlImport("m", "a", null, Map.of());
    var result = ModuleExpander.expand(List.of(imp), Map.of("m", module), Map.of());
    assertThat(result.importConditions().get("a")).isNull();
}

@Test
void unknown_module_throws() {
    var imp = new YamlImport("nonexistent", "a", null, Map.of());
    assertThatThrownBy(() -> ModuleExpander.expand(
            List.of(imp), Map.of(), Map.of()))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("nonexistent");
}

@Test
void missing_alias_throws() {
    var module = new YamlModule("m", Map.of(), Map.of());
    var imp = new YamlImport("m", null, null, Map.of());
    assertThatThrownBy(() -> ModuleExpander.expand(
            List.of(imp), Map.of("m", module), Map.of()))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("alias");
}

@Test
void dot_in_alias_throws() {
    var module = new YamlModule("m", Map.of(), Map.of());
    var imp = new YamlImport("m", "infra.monitor", null, Map.of());
    assertThatThrownBy(() -> ModuleExpander.expand(
            List.of(imp), Map.of("m", module), Map.of()))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining(".");
}

@Test
void duplicate_alias_throws() {
    var module = new YamlModule("m", Map.of(),
            Map.of("nodes", Map.of("n", Map.of())));
    assertThatThrownBy(() -> ModuleExpander.expand(
            List.of(new YamlImport("m", "a", null, Map.of()),
                    new YamlImport("m", "a", null, Map.of())),
            Map.of("m", module), Map.of()))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("duplicate")
            .hasMessageContaining("a");
}

@Test
void unknown_parameter_throws() {
    var module = new YamlModule("m",
            Map.of("region", new YamlModuleParameter(ParameterType.STRING, false, null,
                    null, null, null, null, null)),
            Map.of("nodes", Map.of("n", Map.of())));
    var imp = new YamlImport("m", "a", null, Map.of("reigon", "us-east"));
    assertThatThrownBy(() -> ModuleExpander.expand(
            List.of(imp), Map.of("m", module), Map.of()))
            .isInstanceOf(ParameterValidationException.class);
}
```

- [ ] **Step 2: Run tests — verify compilation fails**

- [ ] **Step 3: Implement ExpandedModule record**

```java
public record ExpandedModule(
        Map<String, Map<String, Object>> sections,
        Map<String, Map<String, String>> moduleScopes,
        Map<String, String> importConditions) {}
```

- [ ] **Step 4: Implement ModuleExpander**

Static `expand()` method:
1. Import structural validation — unknown module, missing/blank alias, dot in alias, duplicate alias
2. For each import: resolve parameters (provided + defaults), validate via `ParameterValidator.validateOrThrow()`, build moduleScope
3. For each section in the module: prefix entry keys with `alias + "."`, merge into result sections
4. Preserve existing sections (existing entries first, then imports in declaration order)
5. Collect `importConditions` — `alias → import.when()` (null if unconditional)

- [ ] **Step 5: Run tests, verify all pass**

- [ ] **Step 6: Full module build**

Run: `/opt/homebrew/bin/mvn -f yaml-core/pom.xml test --batch-mode -q`
Expected: all tests pass

- [ ] **Step 7: Commit**

```
feat(yaml-core): ModuleExpander — structural expansion with import validation

Alias prefixing, parameter resolution with defaults, import merging,
per-import condition passthrough. Structural validation: unknown module,
missing/blank/dotted alias, duplicate alias, unknown parameters.
Consumer owns when-propagation, dependency rewriting, and nested imports.

Refs #252
```

## References

- `specs/issue-252-yaml-core-modules/2026-08-31-yaml-core-modules-design.md` — design spec
- `specs/issue-252-yaml-core-modules/decisions.md` — D1–D6 decisions
- `io.casehub.yaml.core.foreach.ForEachExpander` — Task 1 target
- `io.casehub.yaml.core.foreach.ExpansionResult` — Task 1 target
- `io.casehub.yaml.core.resolver.VariableResolver` — Task 2 target
- `io.casehub.yaml.core.condition.Truthiness` — consumed by ParameterType.BOOLEAN
- `io.casehub.desiredstate.yaml.ModuleExpander` — reference implementation
- casehubio/platform#252, #253 — focal issues
- casehubio/casehub-desiredstate#128 — first consumer
