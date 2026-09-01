# yaml-core Enhancements + Schema Generator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #257 — yaml-core ParameterValidator — allowedValues + constraintDescription
**Issue group:** #257, #259, #248

**Goal:** Add enum constraint + human-friendly messages to ParameterValidator, generic reference rewriting to ForEachExpander, and a shared JSON Schema generator module.

**Architecture:** Three independent increments: (1) extend YamlModuleParameter with allowedValues/constraintDescription and ParameterViolation with technicalDetail, (2) add Reference record and rewriting pass to ForEachAdapter/ForEachExpander, (3) create schema-generator/ module porting engine's victools-based generator.

**Tech Stack:** Pure Java (yaml-core), victools/jsonschema-generator (#248), JUnit 5, AssertJ

## Global Constraints

- yaml-core must remain zero-dependency and J2CL-transpilable (#257, #259)
- schema-generator/ is a new module with external deps — not subject to zero-dep constraint (#248)
- All validation errors use collect-all pattern (not fail-fast)
- Existing tests must pass unchanged

---

## Batch 1: allowedValues + constraintDescription (#257)

### Task 1: ParameterViolation.technicalDetail + ParameterValidator allowedValues + constraintDescription

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterViolation.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleParameter.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterValidator.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/module/ModuleExpander.java` (update validateModuleRefs violation construction)
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/module/ParameterValidatorTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/module/ModuleExpanderTest.java` (verify existing tests still compile)

**Interfaces:**
- Consumes: nothing (standalone)
- Produces: `ParameterViolation(parameterName, constraint, message, actualValue, technicalDetail)`, `YamlModuleParameter(..., allowedValues, constraintDescription)`

- [ ] **Step 1: Write failing tests for allowedValues**

Add to `ParameterValidatorTest.java`:

```java
@Test
void allowedValues_accepts_valid() {
    var param = new YamlModuleParameter(ParameterType.STRING, true, null,
            null, null, null, null, null,
            List.of("us-east-1", "eu-west-1", "ap-south-1"), null);
    var violations = ParameterValidator.validate(
            Map.of("region", param), Map.of("region", "eu-west-1"));
    assertThat(violations).isEmpty();
}

@Test
void allowedValues_rejects_invalid() {
    var param = new YamlModuleParameter(ParameterType.STRING, true, null,
            null, null, null, null, null,
            List.of("us-east-1", "eu-west-1", "ap-south-1"), null);
    var violations = ParameterValidator.validate(
            Map.of("region", param), Map.of("region", "us-west-3"));
    assertThat(violations).hasSize(1);
    assertThat(violations.get(0).constraint()).isEqualTo("allowedValues");
    assertThat(violations.get(0).message())
            .contains("us-west-3")
            .contains("us-east-1");
}

@Test
void allowedValues_empty_skips_check() {
    var param = new YamlModuleParameter(ParameterType.STRING, true, null,
            null, null, null, null, null, List.of(), null);
    var violations = ParameterValidator.validate(
            Map.of("x", param), Map.of("x", "anything"));
    assertThat(violations).isEmpty();
}

@Test
void constraintDescription_replaces_message() {
    var param = new YamlModuleParameter(ParameterType.INTEGER, true, null,
            null, null, null, 1, 100,
            List.of(), "Must be a percentage (1-100)");
    var violations = ParameterValidator.validate(
            Map.of("pct", param), Map.of("pct", "200"));
    assertThat(violations).hasSize(1);
    assertThat(violations.get(0).message())
            .isEqualTo("Must be a percentage (1-100)");
    assertThat(violations.get(0).technicalDetail())
            .contains("200")
            .contains("maximum")
            .contains("100");
}

@Test
void constraintDescription_null_no_technicalDetail() {
    var param = new YamlModuleParameter(ParameterType.INTEGER, true, null,
            null, null, null, 1, 100, List.of(), null);
    var violations = ParameterValidator.validate(
            Map.of("pct", param), Map.of("pct", "200"));
    assertThat(violations).hasSize(1);
    assertThat(violations.get(0).technicalDetail()).isNull();
}

@Test
void allowedValues_with_constraintDescription() {
    var param = new YamlModuleParameter(ParameterType.STRING, true, null,
            null, null, null, null, null,
            List.of("us-east-1", "eu-west-1"),
            "HA topology requires a US or EU region");
    var violations = ParameterValidator.validate(
            Map.of("region", param), Map.of("region", "ap-south-1"));
    assertThat(violations).hasSize(1);
    assertThat(violations.get(0).message())
            .isEqualTo("HA topology requires a US or EU region");
    assertThat(violations.get(0).technicalDetail())
            .contains("ap-south-1")
            .contains("us-east-1");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ParameterValidatorTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation failure — constructor arity mismatch

- [ ] **Step 3: Update ParameterViolation — add technicalDetail field**

Change record to:
```java
public record ParameterViolation(String parameterName, String constraint,
                                  String message, Object actualValue,
                                  String technicalDetail) {}
```

- [ ] **Step 4: Update YamlModuleParameter — add allowedValues + constraintDescription**

Change record to:
```java
public record YamlModuleParameter(
        ParameterType type, boolean required, String defaultValue,
        Integer minLength, Integer maxLength, String pattern,
        Number minimum, Number maximum,
        List<String> allowedValues,
        String constraintDescription) {

    public YamlModuleParameter {
        if (type == null) { type = ParameterType.STRING; }
        if (allowedValues == null) { allowedValues = List.of(); }
    }
}
```

- [ ] **Step 5: Update ParameterValidator — add createViolation helper and allowedValues check**

Add private helper method:
```java
private static ParameterViolation createViolation(String name, String constraint,
        String technicalMessage, Object actualValue, String constraintDescription) {
    if (constraintDescription != null) {
        return new ParameterViolation(name, constraint, constraintDescription,
                actualValue, technicalMessage);
    }
    return new ParameterViolation(name, constraint, technicalMessage,
            actualValue, null);
}
```

Add allowedValues check in `validateConstraints()` (after existing constraint checks):
```java
if (!param.allowedValues().isEmpty()) {
    if (!param.allowedValues().contains(rawValue)) {
        String technical = "Parameter '" + name + "': value '" + rawValue
                + "' is not one of " + param.allowedValues() + ".";
        violations.add(createViolation(name, "allowedValues", technical,
                rawValue, param.constraintDescription()));
    }
}
```

Update ALL existing `violations.add(new ParameterViolation(...))` calls to use `createViolation()` with `param.constraintDescription()`. There are ~8 call sites in `validate()` and `validateConstraints()`. Each needs the `param` reference passed through.

- [ ] **Step 6: Fix compilation in ModuleExpander**

`ModuleExpander.validateModuleRefs()` constructs `ParameterViolation` directly — update all 4 call sites to use the 5-arg constructor with `null` for `technicalDetail` (module ref violations don't use constraintDescription).

- [ ] **Step 7: Fix compilation in existing tests**

Update all `new YamlModuleParameter(...)` constructor calls in `ParameterValidatorTest.java`, `ModuleExpanderTest.java`, and `ParameterTypeTest.java` (if any) to include the two new fields (append `List.of(), null` to existing 8-arg calls).

- [ ] **Step 8: Run all yaml-core tests**

Run: `mvn --batch-mode test -pl yaml-core`
Expected: ALL tests PASS

- [ ] **Step 9: Update JSON Schema fragment**

Add `allowedValues` and `constraintDescription` properties to `yaml-core/src/main/resources/schema/yaml-module-parameter.schema.json` (if file exists; create if not).

- [ ] **Step 10: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-core/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(yaml-core): allowedValues + constraintDescription on ParameterValidator

Adds allowedValues enum constraint and constraintDescription human-
friendly message to YamlModuleParameter. ParameterViolation gains
technicalDetail field for generated message when constraintDescription
replaces the primary message.

Closes #257"
```

---

## Batch 2: ForEachExpander reference rewriting (#259)

### Task 2: ForEachAdapter Reference record + ForEachExpander rewriting pass

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ForEachAdapter.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ForEachExpander.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/foreach/ForEachExpanderTest.java`

**Interfaces:**
- Consumes: nothing (standalone)
- Produces: `ForEachAdapter.Reference(targetId, optional)`, `ForEachAdapter.getReferences(E)`, `ForEachAdapter.withReferences(E, List<Reference>)`

- [ ] **Step 1: Write failing tests for reference rewriting**

Add a test adapter with reference support and tests to `ForEachExpanderTest.java`:

```java
record RefElement(String id, Map<String, Object> spec,
                  Object forEach, String when,
                  List<ForEachAdapter.Reference> refs) {}

static class RefAdapter implements ForEachAdapter<RefElement> {
    @Override
    public RefElement stamp(RefElement template, String stampedId,
                             VariableResolver scopedResolver) {
        return new RefElement(stampedId,
                scopedResolver.resolveMap(template.spec(), stampedId),
                null, null, template.refs());
    }
    @Override
    public Object getForEach(RefElement element) { return element.forEach(); }
    @Override
    public String getId(RefElement element) { return element.id(); }
    @Override
    public String getWhen(RefElement element) { return element.when(); }
    @Override
    public List<Reference> getReferences(RefElement element) { return element.refs(); }
    @Override
    public RefElement withReferences(RefElement element, List<Reference> rewritten) {
        return new RefElement(element.id(), element.spec(), element.forEach(),
                element.when(), rewritten);
    }
}

@Test
void reference_rewriting_static_unchanged() {
    var refAdapter = new RefAdapter();
    var elements = new LinkedHashMap<String, RefElement>();
    elements.put("static-node", new RefElement("static-node",
            Map.of(), null, null, List.of()));
    elements.put("consumer", new RefElement("consumer",
            Map.of(), null, null,
            List.of(new ForEachAdapter.Reference("static-node", false))));

    var result = ForEachExpander.expand(elements, Map.of(),
            resolver, refAdapter, 1000);

    RefElement consumer = result.elements().get("consumer");
    assertThat(consumer.refs()).containsExactly(
            new ForEachAdapter.Reference("static-node", false));
}

@Test
void reference_rewriting_same_group_paired() {
    var refAdapter = new RefAdapter();
    var groups = Map.of("regional",
            new IterationGroup("region", List.of("us", "eu")));
    var elements = new LinkedHashMap<String, RefElement>();
    elements.put("source", new RefElement("source",
            Map.of(), "regional", null, List.of()));
    elements.put("sink", new RefElement("sink",
            Map.of(), "regional", null,
            List.of(new ForEachAdapter.Reference("source", false))));

    var result = ForEachExpander.expand(elements, groups,
            resolver, refAdapter, 1000);

    RefElement sinkUs = result.elements().get("sink.us");
    assertThat(sinkUs.refs()).containsExactly(
            new ForEachAdapter.Reference("source.us", false));
    RefElement sinkEu = result.elements().get("sink.eu");
    assertThat(sinkEu.refs()).containsExactly(
            new ForEachAdapter.Reference("source.eu", false));
}

@Test
void reference_rewriting_cross_group_optional_skipped() {
    var refAdapter = new RefAdapter();
    var groups = Map.of(
            "g1", new IterationGroup("a", List.of("x")),
            "g2", new IterationGroup("b", List.of("y")));
    var elements = new LinkedHashMap<String, RefElement>();
    elements.put("src", new RefElement("src",
            Map.of(), "g1", null, List.of()));
    elements.put("sink", new RefElement("sink",
            Map.of(), "g2", null,
            List.of(new ForEachAdapter.Reference("src", true))));

    var result = ForEachExpander.expand(elements, groups,
            resolver, refAdapter, 1000);

    RefElement sinkY = result.elements().get("sink.y");
    assertThat(sinkY.refs()).isEmpty();
}

@Test
void reference_rewriting_cross_group_required_throws() {
    var refAdapter = new RefAdapter();
    var groups = Map.of(
            "g1", new IterationGroup("a", List.of("x")),
            "g2", new IterationGroup("b", List.of("y")));
    var elements = new LinkedHashMap<String, RefElement>();
    elements.put("src", new RefElement("src",
            Map.of(), "g1", null, List.of()));
    elements.put("sink", new RefElement("sink",
            Map.of(), "g2", null,
            List.of(new ForEachAdapter.Reference("src", false))));

    assertThatThrownBy(() -> ForEachExpander.expand(elements, groups,
            resolver, refAdapter, 1000))
            .isInstanceOf(IllegalStateException.class)
            .hasMessageContaining("different group");
}

@Test
void reference_to_excluded_required_throws() {
    var refAdapter = new RefAdapter();
    var elements = new LinkedHashMap<String, RefElement>();
    elements.put("excluded", new RefElement("excluded",
            Map.of(), null, "false", List.of()));
    elements.put("consumer", new RefElement("consumer",
            Map.of(), null, null,
            List.of(new ForEachAdapter.Reference("excluded", false))));

    assertThatThrownBy(() -> ForEachExpander.expand(elements, Map.of(),
            resolver, refAdapter, 1000))
            .isInstanceOf(IllegalStateException.class)
            .hasMessageContaining("excluded");
}

@Test
void no_references_default_noop() {
    var elements = new LinkedHashMap<String, TestElement>();
    elements.put("node", new TestElement("node",
            Map.of("k", "v"), null, null));

    var result = ForEachExpander.expand(elements, Map.of(),
            resolver, adapter, 1000);

    assertThat(result.elements()).containsKey("node");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ForEachExpanderTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: compilation failure — `Reference` record and default methods don't exist

- [ ] **Step 3: Add Reference record and default methods to ForEachAdapter**

```java
public interface ForEachAdapter<E> {

    E stamp(E template, String stampedId, VariableResolver scopedResolver);
    Object getForEach(E element);
    String getId(E element);
    String getWhen(E element);

    default List<Reference> getReferences(E element) { return List.of(); }
    default E withReferences(E element, List<Reference> rewritten) { return element; }

    record Reference(String targetId, boolean optional) {}
}
```

- [ ] **Step 4: Add rewriting pass to ForEachExpander**

Add two helper methods:
```java
private static String originalId(String stampedId) {
    int dot = stampedId.lastIndexOf('.');
    return dot >= 0 ? stampedId.substring(0, dot) : stampedId;
}

private static String extractValue(String stampedId) {
    int dot = stampedId.lastIndexOf('.');
    return dot >= 0 ? stampedId.substring(dot + 1) : null;
}
```

Add the rewriting loop after the expansion loop, before the `return` statement. The loop iterates `allElements`, calls `adapter.getReferences(element)`, rewrites each reference based on the group membership rules (static=unchanged, same-group=paired, cross-group-optional=skip, cross-group-required=error), checks for references to excluded elements, and calls `adapter.withReferences(element, rewritten)`.

Full implementation per the spec's Part 2 section.

- [ ] **Step 5: Run all ForEachExpander tests**

Run: `mvn --batch-mode test -pl yaml-core -Dtest=ForEachExpanderTest`
Expected: ALL tests PASS

- [ ] **Step 6: Run full yaml-core test suite**

Run: `mvn --batch-mode test -pl yaml-core`
Expected: ALL tests PASS (175+ tests)

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-core/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(yaml-core): generic reference rewriting in ForEachExpander

Adds ForEachAdapter.Reference record and default getReferences/
withReferences methods. ForEachExpander post-expansion pass rewrites
references: static targets unchanged, same-group paired by value,
cross-group errors (or skips if optional).

Closes #259"
```

---

## Batch 3: Shared schema generator (#248)

### Task 3: schema-generator module — PlatformSchemaGenerator + modules

**Files:**
- Create: `schema-generator/pom.xml`
- Create: `schema-generator/src/main/java/io/casehub/schema/generator/PlatformSchemaGenerator.java`
- Create: `schema-generator/src/main/java/io/casehub/schema/generator/SchemaPostProcessor.java`
- Create: `schema-generator/src/main/java/io/casehub/schema/generator/module/EnumInliningModule.java`
- Create: `schema-generator/src/main/java/io/casehub/schema/generator/module/UnevaluatedPropertiesModule.java`
- Create: `schema-generator/src/test/java/io/casehub/schema/generator/PlatformSchemaGeneratorTest.java`
- Modify: `pom.xml` (add `<module>schema-generator</module>`)

**Interfaces:**
- Consumes: nothing (standalone new module)
- Produces: `PlatformSchemaGenerator(Module... customModules)`, `generate(Class<?>)`, `generateToJson(Class<?>, Path)`

- [ ] **Step 1: Write failing tests**

Create test file `PlatformSchemaGeneratorTest.java`:

```java
package io.casehub.schema.generator;

import com.fasterxml.jackson.databind.JsonNode;
import com.github.victools.jsonschema.generator.Module;
import com.github.victools.jsonschema.generator.SchemaGeneratorConfigBuilder;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class PlatformSchemaGeneratorTest {

    record SimpleRecord(String name, int count, boolean active) {}

    enum Color { RED, GREEN, BLUE }

    record WithEnum(String label, Color color) {}

    @Test
    void generates_schema_for_simple_record() {
        var generator = new PlatformSchemaGenerator();
        JsonNode schema = generator.generate(SimpleRecord.class);

        assertThat(schema.has("properties")).isTrue();
        assertThat(schema.get("properties").has("name")).isTrue();
        assertThat(schema.get("properties").has("count")).isTrue();
        assertThat(schema.get("properties").has("active")).isTrue();
    }

    @Test
    void includes_schema_version_draft_2020_12() {
        var generator = new PlatformSchemaGenerator();
        JsonNode schema = generator.generate(SimpleRecord.class);

        assertThat(schema.get("$schema").asText())
                .contains("2020-12");
    }

    @Test
    void enum_values_inlined() {
        var generator = new PlatformSchemaGenerator();
        JsonNode schema = generator.generate(WithEnum.class);

        JsonNode colorProp = schema.get("properties").get("color");
        assertThat(colorProp.has("enum")).isTrue();
        List<String> values = new java.util.ArrayList<>();
        colorProp.get("enum").forEach(v -> values.add(v.asText()));
        assertThat(values).containsExactlyInAnyOrder("RED", "GREEN", "BLUE");
    }

    @Test
    void custom_module_applied() {
        Module custom = (Module) configBuilder ->
                configBuilder.forFields()
                        .withDescriptionResolver(field -> "custom-desc");
        var generator = new PlatformSchemaGenerator(custom);
        JsonNode schema = generator.generate(SimpleRecord.class);

        JsonNode nameProp = schema.get("properties").get("name");
        assertThat(nameProp.get("description").asText())
                .isEqualTo("custom-desc");
    }

    @Test
    void generate_to_json_writes_file(@TempDir Path tempDir) throws Exception {
        var generator = new PlatformSchemaGenerator();
        Path output = tempDir.resolve("schema.json");
        generator.generateToJson(SimpleRecord.class, output);

        assertThat(Files.exists(output)).isTrue();
        String content = Files.readString(output);
        assertThat(content).contains("\"properties\"");
        assertThat(content).contains("\"$schema\"");
    }
}
```

- [ ] **Step 2: Create module pom.xml**

Create `schema-generator/pom.xml`:
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

    <artifactId>casehub-platform-schema-generator</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Schema Generator</name>
    <description>Shared JSON Schema generation from Java types — victools-based,
        Draft 2020-12, with common modules for enum inlining and unevaluatedProperties.</description>

    <dependencies>
        <dependency>
            <groupId>com.github.victools</groupId>
            <artifactId>jsonschema-generator</artifactId>
        </dependency>
        <dependency>
            <groupId>com.github.victools</groupId>
            <artifactId>jsonschema-module-jackson</artifactId>
        </dependency>
        <dependency>
            <groupId>com.github.victools</groupId>
            <artifactId>jsonschema-module-jakarta-validation</artifactId>
        </dependency>
        <dependency>
            <groupId>com.fasterxml.jackson.core</groupId>
            <artifactId>jackson-databind</artifactId>
        </dependency>

        <!-- test -->
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

- [ ] **Step 3: Add module to parent pom.xml**

Add `<module>schema-generator</module>` after `<module>yaml-codegen</module>` in the parent pom.

- [ ] **Step 4: Check victools dependency versions in parent BOM**

Run: `grep -n "victools\|jsonschema-generator\|jsonschema-module" /Users/mdproctor/claude/casehub/platform/pom.xml` — if not managed in parent, check `casehub-parent` BOM. If versions aren't managed, add explicit versions to the module pom.

- [ ] **Step 5: Implement PlatformSchemaGenerator**

```java
package io.casehub.schema.generator;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.github.victools.jsonschema.generator.*;
import com.github.victools.jsonschema.module.jackson.JacksonModule;
import com.github.victools.jsonschema.module.jakarta.validation.JakartaValidationModule;
import io.casehub.schema.generator.module.EnumInliningModule;
import io.casehub.schema.generator.module.UnevaluatedPropertiesModule;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

public class PlatformSchemaGenerator {

    private final SchemaGenerator generator;
    private final ObjectMapper mapper = new ObjectMapper();

    public PlatformSchemaGenerator(Module... customModules) {
        SchemaGeneratorConfigBuilder configBuilder = new SchemaGeneratorConfigBuilder(
                SchemaVersion.DRAFT_2020_12, OptionPreset.PLAIN_JSON)
                .with(Option.DEFINITIONS_FOR_ALL_OBJECTS)
                .with(Option.FLATTENED_ENUMS_FROM_TOSTRING)
                .with(new JacksonModule())
                .with(new JakartaValidationModule())
                .with(new EnumInliningModule())
                .with(new UnevaluatedPropertiesModule());
        for (Module m : customModules) {
            configBuilder.with(m);
        }
        this.generator = new SchemaGenerator(configBuilder.build());
    }

    public JsonNode generate(Class<?> rootType) {
        JsonNode schema = generator.generateSchema(rootType);
        return SchemaPostProcessor.process(schema);
    }

    public void generateToJson(Class<?> rootType, Path output) throws IOException {
        JsonNode schema = generate(rootType);
        Files.writeString(output, mapper.writerWithDefaultPrettyPrinter()
                .writeValueAsString(schema));
    }
}
```

- [ ] **Step 6: Implement SchemaPostProcessor**

```java
package io.casehub.schema.generator;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

public final class SchemaPostProcessor {

    private SchemaPostProcessor() {}

    public static JsonNode process(JsonNode schema) {
        if (schema instanceof ObjectNode root) {
            root.put("$schema", "https://json-schema.org/draft/2020-12/schema");
        }
        return schema;
    }
}
```

- [ ] **Step 7: Implement EnumInliningModule**

```java
package io.casehub.schema.generator.module;

import com.github.victools.jsonschema.generator.Module;
import com.github.victools.jsonschema.generator.SchemaGeneratorConfigBuilder;

public class EnumInliningModule implements Module {

    @Override
    public void applyToConfigBuilder(SchemaGeneratorConfigBuilder builder) {
        builder.forTypesInGeneral()
                .withSubtypeResolver((declaredType, context) -> null);
    }
}
```

- [ ] **Step 8: Implement UnevaluatedPropertiesModule**

```java
package io.casehub.schema.generator.module;

import com.fasterxml.jackson.databind.node.ObjectNode;
import com.github.victools.jsonschema.generator.Module;
import com.github.victools.jsonschema.generator.SchemaGeneratorConfigBuilder;

public class UnevaluatedPropertiesModule implements Module {

    @Override
    public void applyToConfigBuilder(SchemaGeneratorConfigBuilder builder) {
        builder.forTypesInGeneral()
                .withTypeAttributeOverride((node, scope, context) -> {
                    if (node instanceof ObjectNode obj && obj.has("properties")) {
                        obj.put("unevaluatedProperties", false);
                    }
                });
    }
}
```

- [ ] **Step 9: Run tests**

Run: `mvn --batch-mode test -pl schema-generator`
Expected: ALL tests PASS

Note: if victools dependency versions are not in the parent BOM, this step will fail at resolution. Fix by adding `<version>` tags to the module pom (check latest victools release).

- [ ] **Step 10: Run full build**

Run: `mvn --batch-mode install -pl schema-generator`
Expected: BUILD SUCCESS

- [ ] **Step 11: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add schema-generator/ pom.xml
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat: casehub-platform-schema-generator — shared JSON Schema from Java types

Ports engine's victools-based generator to a shared platform module.
Base config: Draft 2020-12, JacksonModule, JakartaValidationModule,
EnumInliningModule, UnevaluatedPropertiesModule. Domain-specific
modules stay in consuming repos.

Closes #248"
```

## References

- `specs/issue-257-yaml-core-enhancements/2026-09-01-yaml-core-enhancements-design.md` — design spec
- `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleParameter.java` — target for #257
- `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterViolation.java` — target for #257
- `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterValidator.java` — target for #257
- `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ForEachAdapter.java` — target for #259
- `yaml-core/src/main/java/io/casehub/yaml/core/foreach/ForEachExpander.java` — target for #259
- `docs/specs/2026-08-29-shared-schema-generator-design.md` — existing spec for #248
- `decisions.md` — D1 (technicalDetail), D2 (naming)
- GitHub #257, #259, #248
