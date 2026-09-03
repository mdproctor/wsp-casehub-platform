# Module Extension (`extends` keyword) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #269 — feat: module extension (extends keyword) for yaml-core module system
**Issue group:** #269

**Goal:** Add `extends: <parent-module-name>` to module headers so a child module inherits parent parameters, outputs, and sections (child wins on key conflict), with single-level extension only.

**Architecture:** Pre-processing step in `ModuleExpander.resolveExtensions()` that takes `List<YamlModuleFile>`, resolves inheritance, and returns `Map<String, YamlModule>`. Three touch points: `YamlModuleHeader` (field), `ModuleExpander` (method), `YamlCoreJacksonModule` (mixin).

**Tech Stack:** Pure Java (yaml-core zero-dep, J2CL-transpilable), Jackson mixins (yaml-jackson), JUnit 5 + AssertJ

## Global Constraints

- yaml-core must remain zero-dependency and J2CL-transpilable — no Jackson, no Quarkus
- Jackson concerns live exclusively in yaml-jackson/
- Single-level extension only — no chains (A extends B extends C)
- Shallow merge at section entry level — no deep merge of opaque `Object` values
- Pre-release — no backward compatibility shims needed

---

## Batch 1: Foundation — `YamlModuleHeader` field + `resolveExtensions()`

### Task 1: Add `extendsModule` field to `YamlModuleHeader`

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleFile.java:21-28`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/module/YamlModuleFileTest.java`

**Interfaces:**
- Produces: `YamlModuleHeader(String name, Map<String,YamlModuleParameter> parameters, Map<String,YamlModuleOutput> outputs, String extendsModule)` — 4-arg canonical constructor. `extendsModule` is nullable.

- [ ] **Step 1: Write the failing test**

Add to `YamlModuleFileTest.java`:

```java
@Test
void toModule_discards_extends() {
    var header = new YamlModuleFile.YamlModuleHeader("child", Map.of(), Map.of(), "parent");
    var file = new YamlModuleFile(header, Map.of(), List.of());
    var module = file.toModule();
    assertThat(module.name()).isEqualTo("child");
}

@Test
void extends_null_by_default() {
    var header = new YamlModuleFile.YamlModuleHeader("m", Map.of(), Map.of(), null);
    assertThat(header.extendsModule()).isNull();
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=YamlModuleFileTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: Compilation error — `YamlModuleHeader` has 3-arg constructor, not 4-arg

- [ ] **Step 3: Add `extendsModule` field to `YamlModuleHeader`**

Replace the `YamlModuleHeader` record in `YamlModuleFile.java`:

```java
public record YamlModuleHeader(String name,
                               Map<String, YamlModuleParameter> parameters,
                               Map<String, YamlModuleOutput> outputs,
                               String extendsModule) {
    public YamlModuleHeader {
        if (parameters == null) {parameters = Map.of();}
        if (outputs == null) {outputs = Map.of();}
    }
}
```

- [ ] **Step 4: Update existing test constructors**

All existing `YamlModuleHeader` constructors in `YamlModuleFileTest.java` gain a 4th argument `null`:

```java
// Line 14: toModule_converts_header_and_sections
var header = new YamlModuleFile.YamlModuleHeader("monitor", Map.of(), Map.of(), null);

// Line 25: toModule_discards_imports
var header = new YamlModuleFile.YamlModuleHeader("m", Map.of(), Map.of(), null);

// Line 34: null_defaults
var header = new YamlModuleFile.YamlModuleHeader("m", null, null, null);

// Line 44: toModule_includes_outputs
var header = new YamlModuleFile.YamlModuleHeader("db",
                                                 Map.of(), Map.of("url", output), null);
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=YamlModuleFileTest`
Expected: All 7 tests PASS (5 existing + 2 new)

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleFile.java yaml-core/src/test/java/io/casehub/yaml/core/module/YamlModuleFileTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#269): add extendsModule field to YamlModuleHeader

Refs #269"
```

### Task 2: Implement `ModuleExpander.resolveExtensions()` with tests

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleExpander.java`
- Modify: `yaml-core/src/test/java/io/casehub/yaml/core/module/ModuleExpanderTest.java`

**Interfaces:**
- Consumes: `YamlModuleHeader.extendsModule()` — nullable String (from Task 1)
- Consumes: `YamlModuleFile.toModule()` — existing method
- Produces: `ModuleExpander.resolveExtensions(List<YamlModuleFile>) → Map<String, YamlModule>`

- [ ] **Step 1: Write failing tests — no-extension passthrough**

Add to `ModuleExpanderTest.java`:

```java
// --- resolveExtensions ---

@Test
void resolve_no_extensions_converts_all() {
    var h1 = new YamlModuleFile.YamlModuleHeader("a", Map.of(), Map.of(), null);
    var h2 = new YamlModuleFile.YamlModuleHeader("b", Map.of(), Map.of(), null);
    var f1 = new YamlModuleFile(h1, Map.of("nodes", Map.of("n1", Map.of())), List.of());
    var f2 = new YamlModuleFile(h2, Map.of("nodes", Map.of("n2", Map.of())), List.of());

    var resolved = ModuleExpander.resolveExtensions(List.of(f1, f2));

    assertThat(resolved).containsKeys("a", "b");
    assertThat(resolved.get("a").sections().get("nodes")).containsKey("n1");
    assertThat(resolved.get("b").sections().get("nodes")).containsKey("n2");
}
```

- [ ] **Step 2: Write failing tests — inheritance**

```java
@Test
void resolve_inherits_parameters() {
    var parentParam = YamlModuleParameter.builder().type(ParameterType.STRING).required().build();
    var parentHeader = new YamlModuleFile.YamlModuleHeader("parent",
            Map.of("region", parentParam), Map.of(), null);
    var parentFile = new YamlModuleFile(parentHeader, Map.of(), List.of());

    var childParam = YamlModuleParameter.builder().type(ParameterType.STRING).required().build();
    var childHeader = new YamlModuleFile.YamlModuleHeader("child",
            Map.of("channel", childParam), Map.of(), "parent");
    var childFile = new YamlModuleFile(childHeader, Map.of(), List.of());

    var resolved = ModuleExpander.resolveExtensions(List.of(parentFile, childFile));

    assertThat(resolved.get("child").parameters())
            .containsKeys("region", "channel");
}

@Test
void resolve_inherits_outputs() {
    var parentOutput = new YamlModuleOutput(ParameterType.STRING, "value");
    var parentHeader = new YamlModuleFile.YamlModuleHeader("parent",
            Map.of(), Map.of("endpoint", parentOutput), null);
    var parentFile = new YamlModuleFile(parentHeader, Map.of(), List.of());

    var childHeader = new YamlModuleFile.YamlModuleHeader("child",
            Map.of(), Map.of(), "parent");
    var childFile = new YamlModuleFile(childHeader, Map.of(), List.of());

    var resolved = ModuleExpander.resolveExtensions(List.of(parentFile, childFile));

    assertThat(resolved.get("child").outputs()).containsKey("endpoint");
}

@Test
void resolve_inherits_sections() {
    var parentHeader = new YamlModuleFile.YamlModuleHeader("parent",
            Map.of(), Map.of(), null);
    var parentFile = new YamlModuleFile(parentHeader,
            Map.of("nodes", Map.of("monitor", Map.of("type", "http-poller"))), List.of());

    var childHeader = new YamlModuleFile.YamlModuleHeader("child",
            Map.of(), Map.of(), "parent");
    var childFile = new YamlModuleFile(childHeader, Map.of(), List.of());

    var resolved = ModuleExpander.resolveExtensions(List.of(parentFile, childFile));

    assertThat(resolved.get("child").sections().get("nodes"))
            .containsKey("monitor");
}

@Test
void resolve_child_adds_section_entries() {
    var parentHeader = new YamlModuleFile.YamlModuleHeader("parent",
            Map.of(), Map.of(), null);
    var parentFile = new YamlModuleFile(parentHeader,
            Map.of("nodes", Map.of("monitor", Map.of("type", "poller"))), List.of());

    var childHeader = new YamlModuleFile.YamlModuleHeader("child",
            Map.of(), Map.of(), "parent");
    var childFile = new YamlModuleFile(childHeader,
            Map.of("nodes", Map.of("notifier", Map.of("type", "slack"))), List.of());

    var resolved = ModuleExpander.resolveExtensions(List.of(parentFile, childFile));

    assertThat(resolved.get("child").sections().get("nodes"))
            .containsKeys("monitor", "notifier");
}

@Test
void resolve_child_adds_new_section() {
    var parentHeader = new YamlModuleFile.YamlModuleHeader("parent",
            Map.of(), Map.of(), null);
    var parentFile = new YamlModuleFile(parentHeader,
            Map.of("nodes", Map.of("n", Map.of())), List.of());

    var childHeader = new YamlModuleFile.YamlModuleHeader("child",
            Map.of(), Map.of(), "parent");
    var childFile = new YamlModuleFile(childHeader,
            Map.of("rules", Map.of("r", Map.of())), List.of());

    var resolved = ModuleExpander.resolveExtensions(List.of(parentFile, childFile));

    assertThat(resolved.get("child").sections()).containsKeys("nodes", "rules");
}
```

- [ ] **Step 3: Write failing tests — override semantics**

```java
@Test
void resolve_child_overrides_parameter() {
    var parentParam = YamlModuleParameter.builder().type(ParameterType.STRING)
            .defaultValue("us-east").build();
    var parentHeader = new YamlModuleFile.YamlModuleHeader("parent",
            Map.of("region", parentParam), Map.of(), null);
    var parentFile = new YamlModuleFile(parentHeader, Map.of(), List.of());

    var childParam = YamlModuleParameter.builder().type(ParameterType.INTEGER)
            .required().build();
    var childHeader = new YamlModuleFile.YamlModuleHeader("child",
            Map.of("region", childParam), Map.of(), "parent");
    var childFile = new YamlModuleFile(childHeader, Map.of(), List.of());

    var resolved = ModuleExpander.resolveExtensions(List.of(parentFile, childFile));

    assertThat(resolved.get("child").parameters().get("region").type())
            .isEqualTo(ParameterType.INTEGER);
    assertThat(resolved.get("child").parameters().get("region").required())
            .isTrue();
}

@Test
void resolve_child_overrides_output() {
    var parentOutput = new YamlModuleOutput(ParameterType.STRING, "old");
    var parentHeader = new YamlModuleFile.YamlModuleHeader("parent",
            Map.of(), Map.of("url", parentOutput), null);
    var parentFile = new YamlModuleFile(parentHeader, Map.of(), List.of());

    var childOutput = new YamlModuleOutput(ParameterType.INTEGER, "42");
    var childHeader = new YamlModuleFile.YamlModuleHeader("child",
            Map.of(), Map.of("url", childOutput), "parent");
    var childFile = new YamlModuleFile(childHeader, Map.of(), List.of());

    var resolved = ModuleExpander.resolveExtensions(List.of(parentFile, childFile));

    assertThat(resolved.get("child").outputs().get("url").type())
            .isEqualTo(ParameterType.INTEGER);
}

@Test
void resolve_child_overrides_section_entry() {
    var parentHeader = new YamlModuleFile.YamlModuleHeader("parent",
            Map.of(), Map.of(), null);
    var parentFile = new YamlModuleFile(parentHeader,
            Map.of("nodes", Map.of("monitor",
                    Map.of("type", "poller", "interval", 30))), List.of());

    var childHeader = new YamlModuleFile.YamlModuleHeader("child",
            Map.of(), Map.of(), "parent");
    var childFile = new YamlModuleFile(childHeader,
            Map.of("nodes", Map.of("monitor",
                    Map.of("type", "webhook"))), List.of());

    var resolved = ModuleExpander.resolveExtensions(List.of(parentFile, childFile));

    @SuppressWarnings("unchecked")
    Map<String, Object> monitor = (Map<String, Object>)
            resolved.get("child").sections().get("nodes").get("monitor");
    assertThat(monitor).containsEntry("type", "webhook");
    assertThat(monitor).doesNotContainKey("interval");
}

@Test
void resolve_preserves_child_name() {
    var parentHeader = new YamlModuleFile.YamlModuleHeader("parent",
            Map.of(), Map.of(), null);
    var parentFile = new YamlModuleFile(parentHeader, Map.of(), List.of());

    var childHeader = new YamlModuleFile.YamlModuleHeader("child",
            Map.of(), Map.of(), "parent");
    var childFile = new YamlModuleFile(childHeader, Map.of(), List.of());

    var resolved = ModuleExpander.resolveExtensions(List.of(parentFile, childFile));

    assertThat(resolved).containsKey("child");
    assertThat(resolved.get("child").name()).isEqualTo("child");
}
```

- [ ] **Step 4: Write failing tests — validation errors**

```java
@Test
void resolve_unknown_parent_throws() {
    var childHeader = new YamlModuleFile.YamlModuleHeader("child",
            Map.of(), Map.of(), "nonexistent");
    var childFile = new YamlModuleFile(childHeader, Map.of(), List.of());

    assertThatThrownBy(() -> ModuleExpander.resolveExtensions(List.of(childFile)))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("child")
            .hasMessageContaining("nonexistent");
}

@Test
void resolve_self_extension_throws() {
    var header = new YamlModuleFile.YamlModuleHeader("m",
            Map.of(), Map.of(), "m");
    var file = new YamlModuleFile(header, Map.of(), List.of());

    assertThatThrownBy(() -> ModuleExpander.resolveExtensions(List.of(file)))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("extends itself");
}

@Test
void resolve_chain_throws() {
    var grandparentHeader = new YamlModuleFile.YamlModuleHeader("gp",
            Map.of(), Map.of(), null);
    var grandparentFile = new YamlModuleFile(grandparentHeader, Map.of(), List.of());

    var parentHeader = new YamlModuleFile.YamlModuleHeader("parent",
            Map.of(), Map.of(), "gp");
    var parentFile = new YamlModuleFile(parentHeader, Map.of(), List.of());

    var childHeader = new YamlModuleFile.YamlModuleHeader("child",
            Map.of(), Map.of(), "parent");
    var childFile = new YamlModuleFile(childHeader, Map.of(), List.of());

    assertThatThrownBy(() -> ModuleExpander.resolveExtensions(
            List.of(grandparentFile, parentFile, childFile)))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("chain")
            .hasMessageContaining("child")
            .hasMessageContaining("parent");
}

@Test
void resolve_duplicate_name_throws() {
    var h1 = new YamlModuleFile.YamlModuleHeader("m", Map.of(), Map.of(), null);
    var h2 = new YamlModuleFile.YamlModuleHeader("m", Map.of(), Map.of(), null);

    assertThatThrownBy(() -> ModuleExpander.resolveExtensions(
            List.of(new YamlModuleFile(h1, Map.of(), List.of()),
                    new YamlModuleFile(h2, Map.of(), List.of()))))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("Duplicate");
}

@Test
void resolve_mixed_extended_and_plain() {
    var parentHeader = new YamlModuleFile.YamlModuleHeader("parent",
            Map.of(), Map.of(), null);
    var parentFile = new YamlModuleFile(parentHeader,
            Map.of("nodes", Map.of("base", Map.of())), List.of());

    var childHeader = new YamlModuleFile.YamlModuleHeader("child",
            Map.of(), Map.of(), "parent");
    var childFile = new YamlModuleFile(childHeader,
            Map.of("nodes", Map.of("extra", Map.of())), List.of());

    var plainHeader = new YamlModuleFile.YamlModuleHeader("standalone",
            Map.of(), Map.of(), null);
    var plainFile = new YamlModuleFile(plainHeader,
            Map.of("rules", Map.of("r1", Map.of())), List.of());

    var resolved = ModuleExpander.resolveExtensions(
            List.of(parentFile, childFile, plainFile));

    assertThat(resolved).hasSize(3);
    assertThat(resolved.get("child").sections().get("nodes"))
            .containsKeys("base", "extra");
    assertThat(resolved.get("standalone").sections()).containsKey("rules");
    assertThat(resolved.get("parent").sections().get("nodes"))
            .containsKey("base");
}
```

- [ ] **Step 5: Run tests to verify they all fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ModuleExpanderTest#resolve_*`
Expected: All fail with "no such method" — `resolveExtensions` doesn't exist yet

- [ ] **Step 6: Implement `resolveExtensions()` and `mergeModules()`**

Add to `ModuleExpander.java` after the typed `expand()` method (after line 111):

```java
public static Map<String, YamlModule> resolveExtensions(
        List<YamlModuleFile> moduleFiles) {

    Map<String, YamlModuleFile> filesByName = new LinkedHashMap<>();
    for (YamlModuleFile file : moduleFiles) {
        String name = file.module().name();
        if (filesByName.containsKey(name)) {
            throw new IllegalArgumentException(
                    "Duplicate module name '" + name + "'.");
        }
        filesByName.put(name, file);
    }

    Map<String, YamlModule> resolved = new LinkedHashMap<>();
    for (YamlModuleFile file : moduleFiles) {
        String parentName = file.module().extendsModule();

        if (parentName == null) {
            resolved.put(file.module().name(), file.toModule());
            continue;
        }

        if (parentName.equals(file.module().name())) {
            throw new IllegalArgumentException(
                    "Module '" + parentName + "' extends itself.");
        }

        YamlModuleFile parentFile = filesByName.get(parentName);
        if (parentFile == null) {
            throw new IllegalArgumentException(
                    "Module '" + file.module().name()
                    + "' extends unknown module '" + parentName + "'.");
        }

        if (parentFile.module().extendsModule() != null) {
            throw new IllegalArgumentException(
                    "Module '" + file.module().name() + "' extends '"
                    + parentName + "', which itself extends '"
                    + parentFile.module().extendsModule()
                    + "'. Extension chains are not supported.");
        }

        YamlModule parentModule = parentFile.toModule();
        YamlModule merged = mergeModules(parentModule, file);
        resolved.put(file.module().name(), merged);
    }

    return Map.copyOf(resolved);
}

private static YamlModule mergeModules(YamlModule parent,
                                        YamlModuleFile childFile) {
    Map<String, YamlModuleParameter> mergedParams =
            new LinkedHashMap<>(parent.parameters());
    mergedParams.putAll(childFile.module().parameters());

    Map<String, YamlModuleOutput> mergedOutputs =
            new LinkedHashMap<>(parent.outputs());
    mergedOutputs.putAll(childFile.module().outputs());

    Map<String, Map<String, Object>> mergedSections = new LinkedHashMap<>();
    for (Map.Entry<String, Map<String, Object>> entry : parent.sections().entrySet()) {
        mergedSections.put(entry.getKey(), new LinkedHashMap<>(entry.getValue()));
    }
    for (Map.Entry<String, Map<String, Object>> entry : childFile.sections().entrySet()) {
        Map<String, Object> targetSection = mergedSections
                .computeIfAbsent(entry.getKey(), k -> new LinkedHashMap<>());
        targetSection.putAll(entry.getValue());
    }

    return new YamlModule(childFile.module().name(),
                          Map.copyOf(mergedParams),
                          Map.copyOf(mergedOutputs),
                          Map.copyOf(mergedSections));
}
```

- [ ] **Step 7: Run all tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ModuleExpanderTest`
Expected: All tests PASS (existing + new resolve_* tests)

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleExpander.java yaml-core/src/test/java/io/casehub/yaml/core/module/ModuleExpanderTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#269): add resolveExtensions() to ModuleExpander

Static method resolves module inheritance before expansion.
Merges parent parameters, outputs, and sections into child
(child wins on key conflict). Validates: unknown parent,
self-extension, extension chains, duplicate names.

Refs #269"
```

## Batch 2: Jackson deserialization + integration

### Task 3: Add `YamlModuleHeaderMixin` and integration test

**Files:**
- Create: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlModuleHeaderMixin.java`
- Modify: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlCoreJacksonModule.java:13-16`
- Modify: `yaml-jackson/src/test/java/io/casehub/yaml/jackson/YamlModuleFileBuilderTest.java`

**Interfaces:**
- Consumes: `YamlModuleHeader(String, Map, Map, String)` — 4-arg constructor (from Task 1)
- Produces: Jackson `extends` → `extendsModule` mapping via mixin

- [ ] **Step 1: Write the failing test**

Add to `YamlModuleFileBuilderTest.java`:

```java
@Test
void extends_field_deserialized() throws Exception {
    String yaml = """
            module:
              name: child
              extends: parent
            nodes:
              notifier:
                type: slack
            """;
    ObjectMapper mapper = new ObjectMapper(new YAMLFactory());
    mapper.registerModule(new YamlCoreJacksonModule());

    YamlModuleFile result = mapper.readValue(yaml, YamlModuleFile.class);

    assertThat(result.module().extendsModule()).isEqualTo("parent");
    assertThat(result.module().name()).isEqualTo("child");
    assertThat(result.sections()).containsKey("nodes");
}

@Test
void no_extends_field_null() throws Exception {
    String yaml = """
            module:
              name: standalone
            nodes:
              monitor:
                type: poller
            """;
    ObjectMapper mapper = new ObjectMapper(new YAMLFactory());
    mapper.registerModule(new YamlCoreJacksonModule());

    YamlModuleFile result = mapper.readValue(yaml, YamlModuleFile.class);

    assertThat(result.module().extendsModule()).isNull();
}

@Test
void extends_with_params_and_sections() throws Exception {
    String yaml = """
            module:
              name: monitoring-with-slack
              extends: monitoring
              parameters:
                slack_channel:
                  type: string
                  required: true
            nodes:
              slack-notifier:
                type: notifier
            """;
    ObjectMapper mapper = new ObjectMapper(new YAMLFactory());
    mapper.registerModule(new YamlCoreJacksonModule());
    mapper.enable(DeserializationFeature.ACCEPT_CASE_INSENSITIVE_ENUMS);

    YamlModuleFile result = mapper.readValue(yaml, YamlModuleFile.class);

    assertThat(result.module().extendsModule()).isEqualTo("monitoring");
    assertThat(result.module().parameters()).containsKey("slack_channel");
    assertThat(result.sections()).containsKey("nodes");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-jackson -Dtest=YamlModuleFileBuilderTest`
Expected: Fails — Jackson can't map `extends` to `extendsModule` without a mixin

- [ ] **Step 3: Create `YamlModuleHeaderMixin`**

Create `yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlModuleHeaderMixin.java`:

```java
package io.casehub.yaml.jackson;

import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonProperty;
import io.casehub.yaml.core.module.YamlModuleOutput;
import io.casehub.yaml.core.module.YamlModuleParameter;

import java.util.Map;

abstract class YamlModuleHeaderMixin {
    @JsonCreator
    YamlModuleHeaderMixin(
            @JsonProperty("name") String name,
            @JsonProperty("parameters") Map<String, YamlModuleParameter> parameters,
            @JsonProperty("outputs") Map<String, YamlModuleOutput> outputs,
            @JsonProperty("extends") String extendsModule) {}
}
```

- [ ] **Step 4: Register mixin in `YamlCoreJacksonModule`**

Add to `setupModule()` in `YamlCoreJacksonModule.java`:

```java
@Override
public void setupModule(SetupContext context) {
    super.setupModule(context);
    context.setMixInAnnotations(YamlModuleFile.class, YamlModuleFileMixin.class);
    context.setMixInAnnotations(YamlModuleFile.YamlModuleHeader.class,
                                YamlModuleHeaderMixin.class);
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-jackson`
Expected: All tests PASS (existing + 3 new extends tests)

- [ ] **Step 6: Write integration test — resolveExtensions + expand**

Add to `ModuleExpanderTest.java`:

```java
@Test
void extended_module_expands_correctly() {
    var parentParam = YamlModuleParameter.builder().type(ParameterType.STRING).required().build();
    var parentHeader = new YamlModuleFile.YamlModuleHeader("monitoring",
            Map.of("region", parentParam), Map.of(), null);
    var parentFile = new YamlModuleFile(parentHeader,
            Map.of("nodes", Map.of("monitor", Map.of("type", "poller"))), List.of());

    var childParam = YamlModuleParameter.builder().type(ParameterType.STRING).required().build();
    var childHeader = new YamlModuleFile.YamlModuleHeader("monitoring-slack",
            Map.of("channel", childParam), Map.of(), "monitoring");
    var childFile = new YamlModuleFile(childHeader,
            Map.of("nodes", Map.of("notifier", Map.of("type", "slack"))), List.of());

    var modules = ModuleExpander.resolveExtensions(List.of(parentFile, childFile));

    var result = ModuleExpander.expand(
            List.of(new YamlImport("monitoring-slack", "alerts", null,
                    Map.of("region", "us-east", "channel", "#ops"))),
            modules, Map.of());

    assertThat(result.sections().get("nodes"))
            .containsKey("alerts.monitor")
            .containsKey("alerts.notifier");
    assertThat(result.moduleScopes().get("alerts"))
            .containsEntry("region", "us-east")
            .containsEntry("channel", "#ops");
}
```

- [ ] **Step 7: Run full yaml-core tests**

Run: `mvn --batch-mode test -pl yaml-core`
Expected: All tests PASS

- [ ] **Step 8: Run full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 9: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlModuleHeaderMixin.java yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlCoreJacksonModule.java yaml-jackson/src/test/java/io/casehub/yaml/jackson/YamlModuleFileBuilderTest.java yaml-core/src/test/java/io/casehub/yaml/core/module/ModuleExpanderTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#269): add Jackson mixin for extends deserialization

YamlModuleHeaderMixin maps YAML 'extends' key to extendsModule
field. Integration test verifies resolveExtensions + expand
pipeline end-to-end.

Refs #269"
```

## References

- `specs/issue-269-module-extension-extends/2026-09-03-module-extension-extends-design.md` — design spec
- `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleFile.java:21-28` — YamlModuleHeader record
- `yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleExpander.java:24-111` — existing expand() methods
- `yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlCoreJacksonModule.java:13-16` — mixin registration
- `yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlModuleFileBuilder.java` — existing builder
- `specs/issue-269-module-extension-extends/decisions.md` — D1-D5 design decisions
- GitHub #269 — focal issue
- GitHub #270 — ModuleBridge<T> foundation
- GitHub #252 — yaml-core module system
