# ModuleBridge<T> + Dynamic Section Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #270 — feat: ModuleBridge<T> generic + dynamic section capture for yaml-core modules
**Issue group:** #270

**Goal:** Add typed module expansion via `ModuleBridge<T>` interface in yaml-core, and Jackson mixin-based dynamic section capture in a new `yaml-jackson/` module.

**Architecture:** Three additive changes across two modules. yaml-core gains `ModuleBridge<T>` interface, `TypedExpandedModule<T>` record, and a typed `expand()` overload on `ModuleExpander`. A new `yaml-jackson/` module provides Jackson mixins for `YamlModuleFile` (dynamic section capture via builder + `@JsonAnySetter`) and case-insensitive enum deserialization via `ACCEPT_CASE_INSENSITIVE_ENUMS`.

**Tech Stack:** Java 21, Maven, JUnit 5, AssertJ, Jackson Databind (yaml-jackson only)

## Global Constraints

- yaml-core must remain zero-dependency and J2CL-transpilable — no Jackson, no Quarkus, no casehubio imports
- yaml-jackson depends on yaml-core + jackson-databind only
- All new types use Java records where immutable
- No `sections:` wrapper support — top-level keys only (D6)
- No identity bridge (D7)
- Pre-release: no backward compatibility concerns

---

## Batch 1: ModuleBridge<T> foundation (yaml-core)

### Task 1: ModuleBridge<T> interface + TypedExpandedModule<T> record

**Files:**
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleBridge.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/module/TypedExpandedModule.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/module/TypedExpandedModuleTest.java`

**Interfaces:**
- Produces: `ModuleBridge<T>` interface (used by Task 2's typed expand overload)
- Produces: `TypedExpandedModule<T>` record (returned by Task 2's typed expand overload)

- [ ] **Step 1: Write TypedExpandedModule tests**

```java
package io.casehub.yaml.core.module;

import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class TypedExpandedModuleTest {

    @Test
    void content_accessor_returns_typed_object() {
        var module = new TypedExpandedModule<>("typed-content",
                Map.of(), Map.of(), Map.of());
        assertThat(module.content()).isEqualTo("typed-content");
    }

    @Test
    void output_source_resolves_alias_dot_name() {
        var module = new TypedExpandedModule<>("content",
                Map.of(), Map.of(),
                Map.of("monitoring", Map.of("endpoint", "https://example.com")));
        assertThat(module.outputSource().lookup("monitoring.endpoint"))
                .isEqualTo("https://example.com");
    }

    @Test
    void output_source_unknown_alias_returns_null() {
        var module = new TypedExpandedModule<>("content",
                Map.of(), Map.of(), Map.of());
        assertThat(module.outputSource().lookup("unknown.key")).isNull();
    }

    @Test
    void output_source_no_dot_returns_null() {
        var module = new TypedExpandedModule<>("content",
                Map.of(), Map.of(),
                Map.of("monitoring", Map.of("endpoint", "val")));
        assertThat(module.outputSource().lookup("monitoring")).isNull();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=TypedExpandedModuleTest`
Expected: FAIL — class not found

- [ ] **Step 3: Create ModuleBridge interface**

```java
package io.casehub.yaml.core.module;

import java.util.Map;

public interface ModuleBridge<T> {
    T fromSections(Map<String, Map<String, Object>> sections);
    Map<String, Map<String, Object>> toSections(T content);
    default SectionContentRewriter rewriter() { return null; }
    default Map<String, String> deriveOutputs(
            T expandedContent, String alias, Map<String, String> paramScope) {
        return Map.of();
    }
}
```

- [ ] **Step 4: Create TypedExpandedModule record**

```java
package io.casehub.yaml.core.module;

import io.casehub.yaml.core.resolver.VariableSource;
import java.util.Map;

public record TypedExpandedModule<T>(
        T content,
        Map<String, Map<String, String>> moduleScopes,
        Map<String, String> importConditions,
        Map<String, Map<String, String>> moduleOutputs) {

    public VariableSource outputSource() {
        return name -> {
            int dot = name.indexOf('.');
            if (dot < 0) return null;
            String alias = name.substring(0, dot);
            String outputName = name.substring(dot + 1);
            Map<String, String> outputs = moduleOutputs.get(alias);
            return outputs != null ? outputs.get(outputName) : null;
        };
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=TypedExpandedModuleTest`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleBridge.java yaml-core/src/main/java/io/casehub/yaml/core/module/TypedExpandedModule.java yaml-core/src/test/java/io/casehub/yaml/core/module/TypedExpandedModuleTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#270): add ModuleBridge<T> interface and TypedExpandedModule<T> record"
```

### Task 2: Typed expand() overload on ModuleExpander

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleExpander.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/module/ModuleBridgeExpandTest.java`

**Interfaces:**
- Consumes: `ModuleBridge<T>` from Task 1, `TypedExpandedModule<T>` from Task 1
- Consumes: existing `ModuleExpander.expand(List, Map, Map, ExpansionOptions)` — delegates to it
- Produces: `ModuleExpander.expand(List, Map, T, ModuleBridge<T>)` — typed expansion overload

- [ ] **Step 1: Write failing tests for typed expansion**

```java
package io.casehub.yaml.core.module;

import org.junit.jupiter.api.Test;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import static org.assertj.core.api.Assertions.assertThat;

class ModuleBridgeExpandTest {

    record TestContent(Map<String, Map<String, Object>> nodes,
                       Map<String, Map<String, Object>> rules) {}

    static class TestBridge implements ModuleBridge<TestContent> {

        @Override
        public TestContent fromSections(Map<String, Map<String, Object>> sections) {
            return new TestContent(
                    sections.getOrDefault("nodes", Map.of()),
                    sections.getOrDefault("rules", Map.of()));
        }

        @Override
        public Map<String, Map<String, Object>> toSections(TestContent content) {
            Map<String, Map<String, Object>> sections = new LinkedHashMap<>();
            if (!content.nodes().isEmpty()) sections.put("nodes", content.nodes());
            if (!content.rules().isEmpty()) sections.put("rules", content.rules());
            return sections;
        }
    }

    @Test
    void typed_expand_converts_at_boundaries() {
        var module = new YamlModule("monitoring",
                Map.of("region", new YamlModuleParameter(ParameterType.STRING, true,
                        null, null, null, null, null, null, List.of(), null)),
                Map.of(),
                Map.of("nodes", Map.of("monitor", Map.of("type", "http-poller"))));

        var imports = List.of(new YamlImport("monitoring", "mon", null, Map.of("region", "us-east")));
        var existingContent = new TestContent(Map.of(), Map.of());
        var bridge = new TestBridge();

        TypedExpandedModule<TestContent> result = ModuleExpander.expand(
                imports, Map.of("monitoring", module), existingContent, bridge);

        assertThat(result.content().nodes()).containsKey("mon.monitor");
        assertThat(result.content().nodes().get("mon.monitor"))
                .containsEntry("type", "http-poller");
    }

    @Test
    void typed_expand_rewriter_applied() {
        var module = new YamlModule("m",
                Map.of(),
                Map.of(),
                Map.of("nodes", Map.of("a", Map.of("dep", "b"))));

        var bridge = new ModuleBridge<TestContent>() {
            @Override
            public TestContent fromSections(Map<String, Map<String, Object>> sections) {
                return new TestContent(
                        sections.getOrDefault("nodes", Map.of()),
                        sections.getOrDefault("rules", Map.of()));
            }
            @Override
            public Map<String, Map<String, Object>> toSections(TestContent content) {
                Map<String, Map<String, Object>> sections = new LinkedHashMap<>();
                if (!content.nodes().isEmpty()) sections.put("nodes", content.nodes());
                return sections;
            }
            @Override
            public SectionContentRewriter rewriter() {
                return (sectionName, entryKey, entryValue, alias, moduleKeys) -> {
                    if (entryValue instanceof Map) {
                        @SuppressWarnings("unchecked")
                        Map<String, Object> map = new LinkedHashMap<>((Map<String, Object>) entryValue);
                        if (map.containsKey("dep") && moduleKeys.contains((String) map.get("dep"))) {
                            map.put("dep", alias + "." + map.get("dep"));
                        }
                        return map;
                    }
                    return entryValue;
                };
            }
        };

        var imports = List.of(new YamlImport("m", "x", null, Map.of()));
        var result = ModuleExpander.expand(
                imports, Map.of("m", module), new TestContent(Map.of(), Map.of()), bridge);

        assertThat(result.content().nodes().get("x.a")).containsEntry("dep", "x.b");
    }

    @Test
    void typed_expand_null_rewriter_no_error() {
        var module = new YamlModule("m", Map.of(), Map.of(),
                Map.of("nodes", Map.of("a", Map.of("k", "v"))));

        var imports = List.of(new YamlImport("m", "x", null, Map.of()));
        var bridge = new TestBridge();

        TypedExpandedModule<TestContent> result = ModuleExpander.expand(
                imports, Map.of("m", module), new TestContent(Map.of(), Map.of()), bridge);

        assertThat(result.content().nodes()).containsKey("x.a");
    }

    @Test
    void typed_expand_preserves_module_scopes() {
        var module = new YamlModule("m",
                Map.of("region", new YamlModuleParameter(ParameterType.STRING, false,
                        "default", null, null, null, null, null, List.of(), null)),
                Map.of(),
                Map.of("nodes", Map.of("a", Map.of("k", "v"))));

        var imports = List.of(new YamlImport("m", "x", null, Map.of("region", "us-east")));
        var bridge = new TestBridge();

        var result = ModuleExpander.expand(
                imports, Map.of("m", module), new TestContent(Map.of(), Map.of()), bridge);

        assertThat(result.moduleScopes()).containsKey("x");
        assertThat(result.moduleScopes().get("x")).containsEntry("region", "us-east");
    }

    @Test
    void typed_expand_preserves_import_conditions() {
        var module = new YamlModule("m", Map.of(), Map.of(),
                Map.of("nodes", Map.of("a", Map.of("k", "v"))));

        var imports = List.of(new YamlImport("m", "x", "env == 'prod'", Map.of()));
        var bridge = new TestBridge();

        var result = ModuleExpander.expand(
                imports, Map.of("m", module), new TestContent(Map.of(), Map.of()), bridge);

        assertThat(result.importConditions()).containsEntry("x", "env == 'prod'");
    }

    @Test
    void typed_expand_preserves_module_outputs() {
        var module = new YamlModule("m", Map.of(),
                Map.of("endpoint", new YamlModuleOutput("https://example.com", ParameterType.STRING)),
                Map.of("nodes", Map.of("a", Map.of("k", "v"))));

        var imports = List.of(new YamlImport("m", "x", null, Map.of()));
        var bridge = new TestBridge();

        var result = ModuleExpander.expand(
                imports, Map.of("m", module), new TestContent(Map.of(), Map.of()), bridge);

        assertThat(result.moduleOutputs()).containsKey("x");
        assertThat(result.moduleOutputs().get("x")).containsEntry("endpoint", "https://example.com");
    }

    @Test
    void typed_expand_output_source_resolves() {
        var module = new YamlModule("m", Map.of(),
                Map.of("endpoint", new YamlModuleOutput("https://example.com", ParameterType.STRING)),
                Map.of("nodes", Map.of("a", Map.of("k", "v"))));

        var imports = List.of(new YamlImport("m", "x", null, Map.of()));
        var bridge = new TestBridge();

        var result = ModuleExpander.expand(
                imports, Map.of("m", module), new TestContent(Map.of(), Map.of()), bridge);

        assertThat(result.outputSource().lookup("x.endpoint"))
                .isEqualTo("https://example.com");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ModuleBridgeExpandTest`
Expected: FAIL — no matching expand() overload

- [ ] **Step 3: Add typed expand() overload to ModuleExpander**

Add this method to `ModuleExpander.java` after the existing `expand()` overloads (after line 91):

```java
public static <T> TypedExpandedModule<T> expand(
        List<YamlImport> imports,
        Map<String, YamlModule> availableModules,
        T existingContent,
        ModuleBridge<T> bridge) {

    Map<String, Map<String, Object>> rawSections = bridge.toSections(existingContent);
    ExpansionOptions options = new ExpansionOptions(null, bridge.rewriter());

    ExpandedModule rawResult = expand(imports, availableModules, rawSections, options);

    T typedContent = bridge.fromSections(rawResult.sections());

    return new TypedExpandedModule<>(
            typedContent,
            rawResult.moduleScopes(),
            rawResult.importConditions(),
            rawResult.moduleOutputs());
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ModuleBridgeExpandTest`
Expected: PASS

- [ ] **Step 5: Run all yaml-core tests to verify no regressions**

Run: `mvn --batch-mode test -pl yaml-core`
Expected: PASS — all existing tests still green

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleExpander.java yaml-core/src/test/java/io/casehub/yaml/core/module/ModuleBridgeExpandTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#270): add typed expand() overload with ModuleBridge<T>"
```

## Batch 2: yaml-jackson/ module

### Task 3: yaml-jackson module scaffold + YamlModuleFileBuilder + YamlCoreJacksonModule

**Files:**
- Create: `yaml-jackson/pom.xml`
- Create: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlCoreJacksonModule.java`
- Create: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlModuleFileMixin.java`
- Create: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlModuleFileBuilder.java`
- Modify: `pom.xml` (parent — add `<module>yaml-jackson</module>`)
- Test: `yaml-jackson/src/test/java/io/casehub/yaml/jackson/YamlModuleFileBuilderTest.java`
- Test: `yaml-jackson/src/test/java/io/casehub/yaml/jackson/ParameterTypeCaseInsensitiveTest.java`

**Interfaces:**
- Consumes: `YamlModuleFile`, `YamlModuleFile.YamlModuleHeader`, `YamlImport`, `ParameterType` from yaml-core
- Produces: `YamlCoreJacksonModule` (Jackson Module consumers register on their ObjectMapper)

- [ ] **Step 1: Create yaml-jackson/pom.xml**

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

    <artifactId>casehub-platform-yaml-jackson</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform YAML Jackson</name>
    <description>Jackson mixins for yaml-core types — dynamic section capture,
        case-insensitive enum deserialization.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-yaml-core</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>com.fasterxml.jackson.core</groupId>
            <artifactId>jackson-databind</artifactId>
        </dependency>
        <dependency>
            <groupId>com.fasterxml.jackson.dataformat</groupId>
            <artifactId>jackson-dataformat-yaml</artifactId>
            <scope>test</scope>
        </dependency>
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

- [ ] **Step 2: Add module to parent pom.xml**

Add `<module>yaml-jackson</module>` after `<module>yaml-codegen</module>` (line 64 area) in the parent pom.

- [ ] **Step 3: Create directory structure**

```bash
mkdir -p /Users/mdproctor/claude/casehub/platform/yaml-jackson/src/main/java/io/casehub/yaml/jackson
mkdir -p /Users/mdproctor/claude/casehub/platform/yaml-jackson/src/test/java/io/casehub/yaml/jackson
```

- [ ] **Step 4: Write failing tests for dynamic section capture**

```java
package io.casehub.yaml.jackson;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import io.casehub.yaml.core.module.YamlModuleFile;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class YamlModuleFileBuilderTest {

    private ObjectMapper mapper;

    @BeforeEach
    void setUp() {
        mapper = new ObjectMapper(new YAMLFactory())
                .registerModule(new YamlCoreJacksonModule())
                .enable(DeserializationFeature.ACCEPT_CASE_INSENSITIVE_ENUMS);
    }

    @Test
    void top_level_keys_become_sections() throws Exception {
        String yaml = """
                module:
                  name: monitoring
                nodes:
                  monitor:
                    type: http-poller
                rules:
                  alert:
                    when: "status != 200"
                """;

        YamlModuleFile file = mapper.readValue(yaml, YamlModuleFile.class);

        assertThat(file.module().name()).isEqualTo("monitoring");
        assertThat(file.sections()).containsKeys("nodes", "rules");
        assertThat(file.sections().get("nodes")).containsKey("monitor");
        assertThat(file.sections().get("rules")).containsKey("alert");
    }

    @Test
    void module_and_imports_not_captured_as_sections() throws Exception {
        String yaml = """
                module:
                  name: test
                imports:
                  - module: other
                    as: o
                nodes:
                  a:
                    type: sensor
                """;

        YamlModuleFile file = mapper.readValue(yaml, YamlModuleFile.class);

        assertThat(file.sections()).containsOnlyKeys("nodes");
        assertThat(file.sections()).doesNotContainKeys("module", "imports");
        assertThat(file.imports()).hasSize(1);
    }

    @Test
    void sections_key_treated_as_section_not_wrapper() throws Exception {
        String yaml = """
                module:
                  name: test
                sections:
                  mysection:
                    key: value
                """;

        YamlModuleFile file = mapper.readValue(yaml, YamlModuleFile.class);

        assertThat(file.sections()).containsOnlyKeys("sections");
        assertThat(file.sections().get("sections")).containsKey("mysection");
    }

    @Test
    void empty_file_module_only() throws Exception {
        String yaml = """
                module:
                  name: empty
                """;

        YamlModuleFile file = mapper.readValue(yaml, YamlModuleFile.class);

        assertThat(file.module().name()).isEqualTo("empty");
        assertThat(file.sections()).isEmpty();
        assertThat(file.imports()).isEmpty();
    }

    @Test
    void nested_map_values_captured() throws Exception {
        String yaml = """
                module:
                  name: deep
                nodes:
                  sensor:
                    config:
                      interval: 30
                      retries: 3
                """;

        YamlModuleFile file = mapper.readValue(yaml, YamlModuleFile.class);

        assertThat(file.sections().get("nodes").get("sensor"))
                .isInstanceOf(java.util.Map.class);
    }

    @Test
    void non_map_top_level_values_ignored() throws Exception {
        String yaml = """
                module:
                  name: test
                version: "1.0"
                nodes:
                  a:
                    type: sensor
                """;

        YamlModuleFile file = mapper.readValue(yaml, YamlModuleFile.class);

        assertThat(file.sections()).containsOnlyKeys("nodes");
    }
}
```

- [ ] **Step 5: Write failing tests for case-insensitive ParameterType**

```java
package io.casehub.yaml.jackson;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import io.casehub.yaml.core.module.ParameterType;
import io.casehub.yaml.core.module.YamlModuleFile;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class ParameterTypeCaseInsensitiveTest {

    private ObjectMapper mapper;

    @BeforeEach
    void setUp() {
        mapper = new ObjectMapper(new YAMLFactory())
                .registerModule(new YamlCoreJacksonModule())
                .enable(DeserializationFeature.ACCEPT_CASE_INSENSITIVE_ENUMS);
    }

    @Test
    void lowercase_type_accepted() throws Exception {
        String yaml = """
                module:
                  name: test
                  parameters:
                    region:
                      type: string
                      required: true
                """;

        YamlModuleFile file = mapper.readValue(yaml, YamlModuleFile.class);

        assertThat(file.module().parameters().get("region").type())
                .isEqualTo(ParameterType.STRING);
    }

    @Test
    void mixed_case_accepted() throws Exception {
        String yaml = """
                module:
                  name: test
                  parameters:
                    count:
                      type: Integer
                """;

        YamlModuleFile file = mapper.readValue(yaml, YamlModuleFile.class);

        assertThat(file.module().parameters().get("count").type())
                .isEqualTo(ParameterType.INTEGER);
    }

    @Test
    void uppercase_still_works() throws Exception {
        String yaml = """
                module:
                  name: test
                  parameters:
                    flag:
                      type: BOOLEAN
                """;

        YamlModuleFile file = mapper.readValue(yaml, YamlModuleFile.class);

        assertThat(file.module().parameters().get("flag").type())
                .isEqualTo(ParameterType.BOOLEAN);
    }

    @Test
    void all_types_case_insensitive() throws Exception {
        String yaml = """
                module:
                  name: test
                  parameters:
                    a:
                      type: string
                    b:
                      type: list
                    c:
                      type: integer
                    d:
                      type: number
                    e:
                      type: boolean
                """;

        YamlModuleFile file = mapper.readValue(yaml, YamlModuleFile.class);

        assertThat(file.module().parameters().get("a").type()).isEqualTo(ParameterType.STRING);
        assertThat(file.module().parameters().get("b").type()).isEqualTo(ParameterType.LIST);
        assertThat(file.module().parameters().get("c").type()).isEqualTo(ParameterType.INTEGER);
        assertThat(file.module().parameters().get("d").type()).isEqualTo(ParameterType.NUMBER);
        assertThat(file.module().parameters().get("e").type()).isEqualTo(ParameterType.BOOLEAN);
    }
}
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-jackson`
Expected: FAIL — classes not found

- [ ] **Step 7: Create YamlModuleFileMixin**

```java
package io.casehub.yaml.jackson;

import com.fasterxml.jackson.databind.annotation.JsonDeserialize;

@JsonDeserialize(builder = YamlModuleFileBuilder.class)
abstract class YamlModuleFileMixin {}
```

- [ ] **Step 8: Create YamlModuleFileBuilder**

```java
package io.casehub.yaml.jackson;

import com.fasterxml.jackson.annotation.JsonAnySetter;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.annotation.JsonPOJOBuilder;
import io.casehub.yaml.core.module.YamlImport;
import io.casehub.yaml.core.module.YamlModuleFile;
import io.casehub.yaml.core.module.YamlModuleFile.YamlModuleHeader;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@JsonPOJOBuilder(withPrefix = "")
public class YamlModuleFileBuilder {

    private YamlModuleHeader module;
    private List<YamlImport> imports = new ArrayList<>();
    private final Map<String, Map<String, Object>> sections = new LinkedHashMap<>();

    @JsonProperty("module")
    public YamlModuleFileBuilder module(YamlModuleHeader module) {
        this.module = module;
        return this;
    }

    @JsonProperty("imports")
    public YamlModuleFileBuilder imports(List<YamlImport> imports) {
        this.imports = imports != null ? imports : new ArrayList<>();
        return this;
    }

    @JsonAnySetter
    @SuppressWarnings("unchecked")
    public void addSection(String name, Object value) {
        if (value instanceof Map) {
            sections.put(name, (Map<String, Object>) value);
        }
    }

    public YamlModuleFile build() {
        return new YamlModuleFile(module, Map.copyOf(sections), List.copyOf(imports));
    }
}
```

- [ ] **Step 9: Create YamlCoreJacksonModule**

```java
package io.casehub.yaml.jackson;

import com.fasterxml.jackson.databind.module.SimpleModule;
import io.casehub.yaml.core.module.YamlModuleFile;

public class YamlCoreJacksonModule extends SimpleModule {

    public YamlCoreJacksonModule() {
        super("yaml-core");
    }

    @Override
    public void setupModule(SetupContext context) {
        super.setupModule(context);
        context.setMixInAnnotations(YamlModuleFile.class, YamlModuleFileMixin.class);
    }
}
```

- [ ] **Step 10: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-jackson`
Expected: PASS

- [ ] **Step 11: Run full build to verify no regressions**

Run: `mvn --batch-mode install -pl yaml-core,yaml-jackson`
Expected: PASS

- [ ] **Step 12: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-jackson/ pom.xml
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#270): add yaml-jackson module — dynamic section capture + case-insensitive enums"
```

## References

- [2026-09-03-module-bridge-dynamic-sections-design.md] — design spec this plan implements
- [decisions.md] — D1–D7 design decisions
- `io.casehub.yaml.core.module.ModuleExpander` — expansion engine (typed overload target)
- `io.casehub.yaml.core.module.ExpandedModule` — raw result type (unchanged)
- `io.casehub.yaml.core.module.YamlModuleFile` — deserialization model (mixin target)
- `io.casehub.yaml.core.module.ExpansionOptions` — raw consumer hook (stays)
- `io.casehub.yaml.core.module.SectionContentRewriter` — provided by bridge.rewriter()
- `io.casehub.yaml.core.module.ParameterType` — enum (case-insensitive via Jackson feature)
- `io.casehub.yaml.core.module.YamlModuleOutput` — output declaration record
- GitHub #270 — focal issue
- GitHub casehubio/casehub-desiredstate#126 — first consumer
