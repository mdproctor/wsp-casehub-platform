# yaml-codegen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #258 — schema-driven YAML record generation Maven plugin
**Issue group:** #258

**Goal:** Build a Maven plugin (`casehub-yaml-codegen-maven-plugin`) that reads a JSON Schema and emits Java records and/or POJOs.

**Architecture:** The plugin uses jsonschema2pojo as a library for schema parsing (`$defs`, `$ref` resolution, type graph). A `SchemaParser` wraps jsonschema2pojo to produce a `TypeGraph` — an intermediate model of types and their fields. Output backends (`RecordEmitter`, `PojoEmitter`) consume the TypeGraph and write Java source files. A YAML mapping file configures per-field annotation overrides for the record backend.

**Tech Stack:** Java 21, Maven Plugin API 3.9.x, jsonschema2pojo-core 1.3.3, Jackson (YAML + databind), JUnit 5, AssertJ

## Global Constraints

- Java 21 (`maven.compiler.release=21`)
- jsonschema2pojo-core 1.3.3 (matches engine's pinned version)
- Module: `casehub-platform-yaml-codegen`, packaging `maven-plugin`
- Package: `io.casehub.yaml.codegen`
- Apache 2.0 license header on all files
- No Quarkus dependency — pure Maven plugin

---

## Batch 1: Module scaffold + schema parsing

### Task 1: Create yaml-codegen module with SchemaParser and TypeGraph

**Files:**
- Create: `yaml-codegen/pom.xml`
- Create: `yaml-codegen/src/main/java/io/casehub/yaml/codegen/TypeGraph.java`
- Create: `yaml-codegen/src/main/java/io/casehub/yaml/codegen/SchemaParser.java`
- Create: `yaml-codegen/src/test/java/io/casehub/yaml/codegen/SchemaParserTest.java`
- Create: `yaml-codegen/src/test/resources/schema/simple-test.yaml`
- Modify: `pom.xml` (add `<module>yaml-codegen</module>`)

**Interfaces:**
- Produces: `TypeGraph` — immutable model with `List<TypeDef> types()`. Each `TypeDef` has `String name`, `List<FieldDef> fields`, `boolean hasAdditionalProperties`, `String additionalPropertiesType`. Each `FieldDef` has `String name`, `String schemaType`, `String refTarget`, `boolean isArray`, `boolean isMap`, `String mapValueType`, `boolean required`, `String description`.
- Produces: `SchemaParser.parse(File schemaFile) → TypeGraph` — reads JSON Schema YAML via jsonschema2pojo's `SchemaStore` and `ContentResolver`, walks `$defs`, extracts type/field metadata into `TypeGraph`.

- [ ] **Step 1: Create pom.xml**

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

    <artifactId>casehub-platform-yaml-codegen</artifactId>
    <packaging>maven-plugin</packaging>
    <name>CaseHub Platform YAML Codegen</name>
    <description>Maven plugin generating Java records and POJOs from JSON Schema.</description>

    <properties>
        <version.jsonschema2pojo>1.3.3</version.jsonschema2pojo>
        <version.maven-plugin-api>3.9.9</version.maven-plugin-api>
        <version.maven-plugin-annotations>3.16.0</version.maven-plugin-annotations>
    </properties>

    <dependencies>
        <dependency>
            <groupId>org.jsonschema2pojo</groupId>
            <artifactId>jsonschema2pojo-core</artifactId>
            <version>${version.jsonschema2pojo}</version>
        </dependency>
        <dependency>
            <groupId>com.fasterxml.jackson.dataformat</groupId>
            <artifactId>jackson-dataformat-yaml</artifactId>
        </dependency>
        <dependency>
            <groupId>com.fasterxml.jackson.databind</groupId>
            <artifactId>jackson-databind</artifactId>
        </dependency>

        <!-- Maven Plugin API -->
        <dependency>
            <groupId>org.apache.maven</groupId>
            <artifactId>maven-plugin-api</artifactId>
            <version>${version.maven-plugin-api}</version>
            <scope>provided</scope>
        </dependency>
        <dependency>
            <groupId>org.apache.maven.plugin-tools</groupId>
            <artifactId>maven-plugin-annotations</artifactId>
            <version>${version.maven-plugin-annotations}</version>
            <scope>provided</scope>
        </dependency>
        <dependency>
            <groupId>org.apache.maven</groupId>
            <artifactId>maven-project</artifactId>
            <version>2.2.1</version>
            <scope>provided</scope>
        </dependency>

        <!-- Test -->
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

    <build>
        <plugins>
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-plugin-plugin</artifactId>
                <version>${version.maven-plugin-annotations}</version>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Add module to parent pom.xml**

Add `<module>yaml-codegen</module>` after the `yaml-core` module entry in the root `pom.xml`.

- [ ] **Step 3: Create test schema file**

Create `yaml-codegen/src/test/resources/schema/simple-test.yaml`:

```yaml
$schema: https://json-schema.org/draft/2020-12/schema
$defs:
  Person:
    type: object
    properties:
      name:
        type: string
      age:
        type: integer
      tags:
        type: array
        items:
          type: string
      address:
        $ref: "#/$defs/Address"
    unevaluatedProperties: false
    required:
      - name
  Address:
    type: object
    properties:
      street:
        type: string
      city:
        type: string
      metadata:
        type: object
        additionalProperties:
          type: string
    unevaluatedProperties: false
```

- [ ] **Step 4: Write the failing test for SchemaParser**

Create `yaml-codegen/src/test/java/io/casehub/yaml/codegen/SchemaParserTest.java`:

```java
package io.casehub.yaml.codegen;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.File;
import org.junit.jupiter.api.Test;

class SchemaParserTest {

    @Test
    void parsesDefsIntoTypeGraph() {
        File schema = new File("src/test/resources/schema/simple-test.yaml");
        TypeGraph graph = new SchemaParser().parse(schema);

        assertThat(graph.types()).hasSize(2);
        assertThat(graph.types().stream().map(TypeGraph.TypeDef::name))
                .containsExactlyInAnyOrder("Person", "Address");
    }

    @Test
    void extractsFieldsFromProperties() {
        File schema = new File("src/test/resources/schema/simple-test.yaml");
        TypeGraph graph = new SchemaParser().parse(schema);

        TypeGraph.TypeDef person = graph.findType("Person").orElseThrow();
        assertThat(person.fields()).hasSize(4);
        assertThat(person.fields().stream().map(TypeGraph.FieldDef::name))
                .containsExactly("name", "age", "tags", "address");
    }

    @Test
    void detectsArrayFields() {
        File schema = new File("src/test/resources/schema/simple-test.yaml");
        TypeGraph graph = new SchemaParser().parse(schema);

        TypeGraph.TypeDef person = graph.findType("Person").orElseThrow();
        TypeGraph.FieldDef tags = person.findField("tags").orElseThrow();
        assertThat(tags.isArray()).isTrue();
        assertThat(tags.schemaType()).isEqualTo("string");
    }

    @Test
    void detectsRefFields() {
        File schema = new File("src/test/resources/schema/simple-test.yaml");
        TypeGraph graph = new SchemaParser().parse(schema);

        TypeGraph.TypeDef person = graph.findType("Person").orElseThrow();
        TypeGraph.FieldDef address = person.findField("address").orElseThrow();
        assertThat(address.refTarget()).isEqualTo("Address");
    }

    @Test
    void detectsMapFields() {
        File schema = new File("src/test/resources/schema/simple-test.yaml");
        TypeGraph graph = new SchemaParser().parse(schema);

        TypeGraph.TypeDef addr = graph.findType("Address").orElseThrow();
        TypeGraph.FieldDef metadata = addr.findField("metadata").orElseThrow();
        assertThat(metadata.isMap()).isTrue();
        assertThat(metadata.mapValueType()).isEqualTo("string");
    }
}
```

- [ ] **Step 5: Run test to verify it fails**

Run: `mvn test -pl yaml-codegen -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: Compilation failure — `TypeGraph` and `SchemaParser` do not exist.

- [ ] **Step 6: Implement TypeGraph**

Create `yaml-codegen/src/main/java/io/casehub/yaml/codegen/TypeGraph.java`:

```java
package io.casehub.yaml.codegen;

import java.util.List;
import java.util.Optional;

public record TypeGraph(List<TypeDef> types) {

    public Optional<TypeDef> findType(String name) {
        return types.stream().filter(t -> t.name().equals(name)).findFirst();
    }

    public record TypeDef(
            String name,
            List<FieldDef> fields,
            boolean hasAdditionalProperties,
            String additionalPropertiesType) {

        public Optional<FieldDef> findField(String name) {
            return fields.stream().filter(f -> f.name().equals(name)).findFirst();
        }
    }

    public record FieldDef(
            String name,
            String schemaType,
            String refTarget,
            boolean isArray,
            boolean isMap,
            String mapValueType,
            boolean required,
            String description) {}
}
```

- [ ] **Step 7: Implement SchemaParser**

Create `yaml-codegen/src/main/java/io/casehub/yaml/codegen/SchemaParser.java`:

```java
package io.casehub.yaml.codegen;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import java.io.File;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Map;

public class SchemaParser {

    private final ObjectMapper yaml = new ObjectMapper(new YAMLFactory());

    public TypeGraph parse(File schemaFile) {
        try {
            JsonNode root = yaml.readTree(schemaFile);
            JsonNode defs = root.path("$defs");
            if (defs.isMissingNode()) {
                return new TypeGraph(List.of());
            }

            List<TypeGraph.TypeDef> types = new ArrayList<>();
            Iterator<Map.Entry<String, JsonNode>> it = defs.fields();
            while (it.hasNext()) {
                Map.Entry<String, JsonNode> entry = it.next();
                types.add(parseTypeDef(entry.getKey(), entry.getValue()));
            }
            return new TypeGraph(List.copyOf(types));
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    private TypeGraph.TypeDef parseTypeDef(String name, JsonNode typeNode) {
        List<TypeGraph.FieldDef> fields = new ArrayList<>();
        JsonNode properties = typeNode.path("properties");
        JsonNode requiredArray = typeNode.path("required");
        List<String> requiredFields = new ArrayList<>();
        if (requiredArray.isArray()) {
            requiredArray.forEach(n -> requiredFields.add(n.asText()));
        }

        Iterator<Map.Entry<String, JsonNode>> it = properties.fields();
        while (it.hasNext()) {
            Map.Entry<String, JsonNode> entry = it.next();
            fields.add(parseFieldDef(entry.getKey(), entry.getValue(),
                    requiredFields.contains(entry.getKey())));
        }

        JsonNode additionalProps = typeNode.path("additionalProperties");
        boolean hasAdditional = additionalProps.isObject() || additionalProps.asBoolean(false);
        String additionalType = null;
        if (additionalProps.isObject()) {
            if (additionalProps.has("$ref")) {
                additionalType = extractRefName(additionalProps.get("$ref").asText());
            } else if (additionalProps.has("type")) {
                additionalType = additionalProps.get("type").asText();
            }
        } else if (additionalProps.asBoolean(false)) {
            additionalType = "object";
        }

        return new TypeGraph.TypeDef(name, List.copyOf(fields),
                hasAdditional, additionalType);
    }

    private TypeGraph.FieldDef parseFieldDef(String name, JsonNode fieldNode,
            boolean required) {
        String schemaType = null;
        String refTarget = null;
        boolean isArray = false;
        boolean isMap = false;
        String mapValueType = null;
        String description = fieldNode.has("description")
                ? fieldNode.get("description").asText() : null;

        if (fieldNode.has("$ref")) {
            refTarget = extractRefName(fieldNode.get("$ref").asText());
        } else if (fieldNode.has("type")) {
            String type = fieldNode.get("type").asText();
            if ("array".equals(type)) {
                isArray = true;
                JsonNode items = fieldNode.path("items");
                if (items.has("$ref")) {
                    refTarget = extractRefName(items.get("$ref").asText());
                } else if (items.has("type")) {
                    schemaType = items.get("type").asText();
                }
            } else if ("object".equals(type) && !fieldNode.has("properties")) {
                JsonNode addProps = fieldNode.path("additionalProperties");
                if (addProps.isObject() || addProps.asBoolean(false)) {
                    isMap = true;
                    if (addProps.isObject() && addProps.has("type")) {
                        mapValueType = addProps.get("type").asText();
                    } else if (addProps.isObject() && addProps.has("$ref")) {
                        mapValueType = extractRefName(addProps.get("$ref").asText());
                    } else {
                        mapValueType = "object";
                    }
                } else {
                    schemaType = "object";
                }
            } else {
                schemaType = type;
            }
        } else if (fieldNode.has("oneOf")) {
            schemaType = "oneOf";
        }

        return new TypeGraph.FieldDef(name, schemaType, refTarget,
                isArray, isMap, mapValueType, required, description);
    }

    private static String extractRefName(String ref) {
        int lastSlash = ref.lastIndexOf('/');
        return lastSlash >= 0 ? ref.substring(lastSlash + 1) : ref;
    }
}
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `mvn test -pl yaml-codegen -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: All 5 tests PASS.

- [ ] **Step 9: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-codegen/ pom.xml
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#258): yaml-codegen module scaffold with SchemaParser + TypeGraph Refs #258"
```

---

## Batch 2: Mapping config + record emitter

### Task 2: MappingConfig — YAML mapping file reader

**Files:**
- Create: `yaml-codegen/src/main/java/io/casehub/yaml/codegen/MappingConfig.java`
- Create: `yaml-codegen/src/test/java/io/casehub/yaml/codegen/MappingConfigTest.java`
- Create: `yaml-codegen/src/test/resources/schema/test-mappings.yaml`

**Interfaces:**
- Produces: `MappingConfig.load(File) → MappingConfig` — reads the YAML mapping file
- Produces: `MappingConfig.forType(String typeName) → Optional<TypeMapping>`
- Produces: `TypeMapping.forField(String fieldName) → Optional<FieldMapping>`
- Produces: `FieldMapping` — record with `String type`, `String deserializer`, `Object alias` (String or List<String>), `String jsonProperty`, `boolean skip`
- Produces: `MappingConfig.globalAnnotations() → List<String>`
- Produces: `MappingConfig.empty() → MappingConfig` — no overrides

- [ ] **Step 1: Create test mappings file**

Create `yaml-codegen/src/test/resources/schema/test-mappings.yaml`:

```yaml
globalAnnotations:
  - "com.fasterxml.jackson.annotation.JsonIgnoreProperties(ignoreUnknown = true)"

types:
  Person:
    fields:
      name:
        alias: fullName
      address:
        type: com.example.CustomAddress
        deserializer: com.example.AddressDeserializer
      nickname:
        skip: true
  Worker:
    fields:
      doBlock:
        jsonProperty: "do"
        type: com.fasterxml.jackson.databind.JsonNode
```

- [ ] **Step 2: Write the failing test**

Create `yaml-codegen/src/test/java/io/casehub/yaml/codegen/MappingConfigTest.java`:

```java
package io.casehub.yaml.codegen;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.File;
import org.junit.jupiter.api.Test;

class MappingConfigTest {

    @Test
    void loadsGlobalAnnotations() {
        MappingConfig config = MappingConfig.load(
                new File("src/test/resources/schema/test-mappings.yaml"));
        assertThat(config.globalAnnotations()).containsExactly(
                "com.fasterxml.jackson.annotation.JsonIgnoreProperties(ignoreUnknown = true)");
    }

    @Test
    void resolvesTypeMapping() {
        MappingConfig config = MappingConfig.load(
                new File("src/test/resources/schema/test-mappings.yaml"));
        assertThat(config.forType("Person")).isPresent();
        assertThat(config.forType("Unknown")).isEmpty();
    }

    @Test
    void resolvesFieldMapping() {
        MappingConfig config = MappingConfig.load(
                new File("src/test/resources/schema/test-mappings.yaml"));
        var person = config.forType("Person").orElseThrow();
        var address = person.forField("address").orElseThrow();
        assertThat(address.type()).isEqualTo("com.example.CustomAddress");
        assertThat(address.deserializer()).isEqualTo("com.example.AddressDeserializer");
    }

    @Test
    void resolvesAlias() {
        MappingConfig config = MappingConfig.load(
                new File("src/test/resources/schema/test-mappings.yaml"));
        var person = config.forType("Person").orElseThrow();
        var name = person.forField("name").orElseThrow();
        assertThat(name.aliases()).containsExactly("fullName");
    }

    @Test
    void resolvesJsonProperty() {
        MappingConfig config = MappingConfig.load(
                new File("src/test/resources/schema/test-mappings.yaml"));
        var worker = config.forType("Worker").orElseThrow();
        var doBlock = worker.forField("doBlock").orElseThrow();
        assertThat(doBlock.jsonProperty()).isEqualTo("do");
    }

    @Test
    void resolvesSkip() {
        MappingConfig config = MappingConfig.load(
                new File("src/test/resources/schema/test-mappings.yaml"));
        var person = config.forType("Person").orElseThrow();
        var nickname = person.forField("nickname").orElseThrow();
        assertThat(nickname.skip()).isTrue();
    }

    @Test
    void emptyConfigHasNoOverrides() {
        MappingConfig config = MappingConfig.empty();
        assertThat(config.forType("Anything")).isEmpty();
        assertThat(config.globalAnnotations()).isEmpty();
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mvn test -pl yaml-codegen -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: Compilation failure — `MappingConfig` does not exist.

- [ ] **Step 4: Implement MappingConfig**

Create `yaml-codegen/src/main/java/io/casehub/yaml/codegen/MappingConfig.java`:

```java
package io.casehub.yaml.codegen;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import java.io.File;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Optional;

public record MappingConfig(
        List<String> globalAnnotations,
        Map<String, TypeMapping> types) {

    public Optional<TypeMapping> forType(String typeName) {
        return Optional.ofNullable(types.get(typeName));
    }

    public static MappingConfig empty() {
        return new MappingConfig(List.of(), Map.of());
    }

    public static MappingConfig load(File file) {
        try {
            ObjectMapper yaml = new ObjectMapper(new YAMLFactory());
            JsonNode root = yaml.readTree(file);

            List<String> annotations = new ArrayList<>();
            JsonNode globalAnns = root.path("globalAnnotations");
            if (globalAnns.isArray()) {
                globalAnns.forEach(n -> annotations.add(n.asText()));
            }

            Map<String, TypeMapping> types = new HashMap<>();
            JsonNode typesNode = root.path("types");
            Iterator<Map.Entry<String, JsonNode>> it = typesNode.fields();
            while (it.hasNext()) {
                Map.Entry<String, JsonNode> entry = it.next();
                types.put(entry.getKey(), parseTypeMapping(entry.getValue()));
            }

            return new MappingConfig(List.copyOf(annotations), Map.copyOf(types));
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    private static TypeMapping parseTypeMapping(JsonNode node) {
        Map<String, FieldMapping> fields = new HashMap<>();
        JsonNode fieldsNode = node.path("fields");
        Iterator<Map.Entry<String, JsonNode>> it = fieldsNode.fields();
        while (it.hasNext()) {
            Map.Entry<String, JsonNode> entry = it.next();
            fields.put(entry.getKey(), parseFieldMapping(entry.getValue()));
        }
        return new TypeMapping(Map.copyOf(fields));
    }

    private static FieldMapping parseFieldMapping(JsonNode node) {
        String type = node.has("type") ? node.get("type").asText() : null;
        String deserializer = node.has("deserializer")
                ? node.get("deserializer").asText() : null;
        String jsonProperty = node.has("jsonProperty")
                ? node.get("jsonProperty").asText() : null;
        boolean skip = node.has("skip") && node.get("skip").asBoolean();

        List<String> aliases = new ArrayList<>();
        JsonNode aliasNode = node.path("alias");
        if (aliasNode.isArray()) {
            aliasNode.forEach(n -> aliases.add(n.asText()));
        } else if (aliasNode.isTextual()) {
            aliases.add(aliasNode.asText());
        }

        return new FieldMapping(type, deserializer, List.copyOf(aliases),
                jsonProperty, skip);
    }

    public record TypeMapping(Map<String, FieldMapping> fields) {
        public Optional<FieldMapping> forField(String fieldName) {
            return Optional.ofNullable(fields.get(fieldName));
        }
    }

    public record FieldMapping(
            String type,
            String deserializer,
            List<String> aliases,
            String jsonProperty,
            boolean skip) {}
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn test -pl yaml-codegen -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: All 7 MappingConfig tests + 5 SchemaParser tests PASS.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-codegen/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#258): MappingConfig — YAML mapping file reader Refs #258"
```

### Task 3: RecordEmitter — Java record source generation

**Files:**
- Create: `yaml-codegen/src/main/java/io/casehub/yaml/codegen/RecordEmitter.java`
- Create: `yaml-codegen/src/main/java/io/casehub/yaml/codegen/JavaTypeResolver.java`
- Create: `yaml-codegen/src/test/java/io/casehub/yaml/codegen/RecordEmitterTest.java`

**Interfaces:**
- Consumes: `TypeGraph` from Task 1, `MappingConfig` from Task 2
- Produces: `RecordEmitter.emit(TypeGraph, MappingConfig, EmitConfig) → List<GeneratedFile>`
- Produces: `GeneratedFile` — record with `String packagePath`, `String fileName`, `String content`
- Produces: `EmitConfig` — record with `String targetPackage`, `String prefix`
- Produces: `JavaTypeResolver.resolve(FieldDef, MappingConfig, String prefix) → ResolvedType` — maps schema types + mapping overrides to Java type strings

- [ ] **Step 1: Write the failing test**

Create `yaml-codegen/src/test/java/io/casehub/yaml/codegen/RecordEmitterTest.java`:

```java
package io.casehub.yaml.codegen;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.File;
import java.util.List;
import org.junit.jupiter.api.Test;

class RecordEmitterTest {

    private final TypeGraph graph = new SchemaParser()
            .parse(new File("src/test/resources/schema/simple-test.yaml"));
    private final MappingConfig emptyMapping = MappingConfig.empty();
    private final RecordEmitter.EmitConfig config =
            new RecordEmitter.EmitConfig("io.test.yaml", "Yaml");

    @Test
    void generatesRecordPerType() {
        List<RecordEmitter.GeneratedFile> files =
                new RecordEmitter().emit(graph, emptyMapping, config);
        assertThat(files).hasSize(2);
        assertThat(files.stream().map(RecordEmitter.GeneratedFile::fileName))
                .containsExactlyInAnyOrder("YamlPerson.java", "YamlAddress.java");
    }

    @Test
    void recordHasJsonIgnoreProperties() {
        MappingConfig withAnnotation = MappingConfig.load(
                new File("src/test/resources/schema/test-mappings.yaml"));
        List<RecordEmitter.GeneratedFile> files =
                new RecordEmitter().emit(graph, withAnnotation, config);
        RecordEmitter.GeneratedFile person = files.stream()
                .filter(f -> f.fileName().equals("YamlPerson.java")).findFirst().orElseThrow();
        assertThat(person.content()).contains("@JsonIgnoreProperties(ignoreUnknown = true)");
    }

    @Test
    void recordHasNullSafeCompactConstructor() {
        List<RecordEmitter.GeneratedFile> files =
                new RecordEmitter().emit(graph, emptyMapping, config);
        RecordEmitter.GeneratedFile person = files.stream()
                .filter(f -> f.fileName().equals("YamlPerson.java")).findFirst().orElseThrow();
        assertThat(person.content()).contains("if (tags == null)");
        assertThat(person.content()).contains("tags = List.of()");
    }

    @Test
    void recordHasCorrectComponents() {
        List<RecordEmitter.GeneratedFile> files =
                new RecordEmitter().emit(graph, emptyMapping, config);
        RecordEmitter.GeneratedFile person = files.stream()
                .filter(f -> f.fileName().equals("YamlPerson.java")).findFirst().orElseThrow();
        assertThat(person.content()).contains("String name");
        assertThat(person.content()).contains("Integer age");
        assertThat(person.content()).contains("List<String> tags");
        assertThat(person.content()).contains("YamlAddress address");
    }

    @Test
    void mapFieldGeneratesMapType() {
        List<RecordEmitter.GeneratedFile> files =
                new RecordEmitter().emit(graph, emptyMapping, config);
        RecordEmitter.GeneratedFile address = files.stream()
                .filter(f -> f.fileName().equals("YamlAddress.java")).findFirst().orElseThrow();
        assertThat(address.content()).contains("Map<String, String> metadata");
        assertThat(address.content()).contains("if (metadata == null)");
        assertThat(address.content()).contains("metadata = Map.of()");
    }

    @Test
    void mappingOverridesTypeAndAddsDeserializer() {
        MappingConfig mapping = MappingConfig.load(
                new File("src/test/resources/schema/test-mappings.yaml"));
        List<RecordEmitter.GeneratedFile> files =
                new RecordEmitter().emit(graph, mapping, config);
        RecordEmitter.GeneratedFile person = files.stream()
                .filter(f -> f.fileName().equals("YamlPerson.java")).findFirst().orElseThrow();
        assertThat(person.content()).contains("com.example.CustomAddress address");
        assertThat(person.content()).contains(
                "@JsonDeserialize(using = AddressDeserializer.class)");
    }

    @Test
    void mappingAddsAlias() {
        MappingConfig mapping = MappingConfig.load(
                new File("src/test/resources/schema/test-mappings.yaml"));
        List<RecordEmitter.GeneratedFile> files =
                new RecordEmitter().emit(graph, mapping, config);
        RecordEmitter.GeneratedFile person = files.stream()
                .filter(f -> f.fileName().equals("YamlPerson.java")).findFirst().orElseThrow();
        assertThat(person.content()).contains("@JsonAlias(\"fullName\")");
    }

    @Test
    void skippedFieldsOmitted() {
        MappingConfig mapping = MappingConfig.load(
                new File("src/test/resources/schema/test-mappings.yaml"));
        List<RecordEmitter.GeneratedFile> files =
                new RecordEmitter().emit(graph, mapping, config);
        RecordEmitter.GeneratedFile person = files.stream()
                .filter(f -> f.fileName().equals("YamlPerson.java")).findFirst().orElseThrow();
        assertThat(person.content()).doesNotContain("nickname");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn test -pl yaml-codegen -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: Compilation failure — `RecordEmitter` does not exist.

- [ ] **Step 3: Implement JavaTypeResolver**

Create `yaml-codegen/src/main/java/io/casehub/yaml/codegen/JavaTypeResolver.java`. This maps schema types + mapping overrides to Java type strings and import statements. The resolver checks the mapping first; if no override, infers from schema type using the default type mapping table from the spec.

- [ ] **Step 4: Implement RecordEmitter**

Create `yaml-codegen/src/main/java/io/casehub/yaml/codegen/RecordEmitter.java`. For each `TypeDef` in the `TypeGraph`:
1. Resolve each field's Java type via `JavaTypeResolver`
2. Skip fields marked `skip` in the mapping
3. Build the record source text: license header, package, imports, class-level annotations, record declaration with components, compact constructor with null-safe defaults for List/Map fields
4. Return as `GeneratedFile`

The emitter uses `StringBuilder` — no template engine needed. Records are structurally simple enough for direct string construction.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn test -pl yaml-codegen -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: All 8 RecordEmitter tests PASS.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-codegen/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#258): RecordEmitter — Java record source generation Refs #258"
```

---

## Batch 3: Maven plugin + POJO emitter + integration test

### Task 4: PojoEmitter + YamlCodegenMojo + integration test

**Files:**
- Create: `yaml-codegen/src/main/java/io/casehub/yaml/codegen/PojoEmitter.java`
- Create: `yaml-codegen/src/main/java/io/casehub/yaml/codegen/YamlCodegenMojo.java`
- Create: `yaml-codegen/src/main/java/io/casehub/yaml/codegen/OutputConfig.java`
- Create: `yaml-codegen/src/test/java/io/casehub/yaml/codegen/PojoEmitterTest.java`
- Create: `yaml-codegen/src/test/java/io/casehub/yaml/codegen/YamlCodegenMojoTest.java`

**Interfaces:**
- Consumes: `SchemaParser` (Task 1), `MappingConfig` (Task 2), `RecordEmitter` (Task 3)
- Produces: `PojoEmitter.emit(File schemaFile, String targetPackage, String ruleFactoryClass, File outputDir)` — wraps jsonschema2pojo pipeline
- Produces: `YamlCodegenMojo` — `@Mojo(name = "generate", defaultPhase = GENERATE_SOURCES)` with `schemaFile`, `outputs` config
- Produces: `OutputConfig` — record with `String format`, `String targetPackage`, `String prefix`, `String mappingsFile`, `String ruleFactory`

- [ ] **Step 1: Write the failing test for PojoEmitter**

Create `yaml-codegen/src/test/java/io/casehub/yaml/codegen/PojoEmitterTest.java`:

```java
package io.casehub.yaml.codegen;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class PojoEmitterTest {

    @TempDir Path tempDir;

    @Test
    void generatesPojoClasses() throws Exception {
        File schema = new File("src/test/resources/schema/simple-test.yaml");
        File outputDir = tempDir.toFile();

        new PojoEmitter().emit(schema, "io.test.model", null, outputDir);

        Path personFile = tempDir.resolve("io/test/model/Person.java");
        assertThat(personFile).exists();
        String content = Files.readString(personFile);
        assertThat(content).contains("public class Person");
        assertThat(content).contains("private String name");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn test -pl yaml-codegen -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: Compilation failure — `PojoEmitter` does not exist.

- [ ] **Step 3: Implement PojoEmitter**

Create `yaml-codegen/src/main/java/io/casehub/yaml/codegen/PojoEmitter.java`. Wraps the existing jsonschema2pojo pipeline (same logic as engine's `CasehubCodegen.main()`):
1. Create `DefaultGenerationConfig` with `YAMLSCHEMA` source type
2. Set up `SchemaStore` with `ContentResolver`
3. If `ruleFactoryClass` is provided, load it via `Class.forName()` and instantiate; otherwise use default `RuleFactory`
4. Run `SchemaMapper.generate()` → `JCodeModel.build(outputDir)`

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn test -pl yaml-codegen -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: PojoEmitter test PASSES.

- [ ] **Step 5: Implement OutputConfig and YamlCodegenMojo**

Create `yaml-codegen/src/main/java/io/casehub/yaml/codegen/OutputConfig.java`:

```java
package io.casehub.yaml.codegen;

public class OutputConfig {
    private String format;
    private String targetPackage;
    private String prefix = "Yaml";
    private String mappingsFile;
    private String ruleFactory;

    // Getters and setters for Maven parameter injection
    public String getFormat() { return format; }
    public void setFormat(String format) { this.format = format; }
    public String getTargetPackage() { return targetPackage; }
    public void setTargetPackage(String targetPackage) { this.targetPackage = targetPackage; }
    public String getPrefix() { return prefix; }
    public void setPrefix(String prefix) { this.prefix = prefix; }
    public String getMappingsFile() { return mappingsFile; }
    public void setMappingsFile(String mappingsFile) { this.mappingsFile = mappingsFile; }
    public String getRuleFactory() { return ruleFactory; }
    public void setRuleFactory(String ruleFactory) { this.ruleFactory = ruleFactory; }
}
```

Create `yaml-codegen/src/main/java/io/casehub/yaml/codegen/YamlCodegenMojo.java`:

```java
package io.casehub.yaml.codegen;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.apache.maven.plugin.AbstractMojo;
import org.apache.maven.plugin.MojoExecutionException;
import org.apache.maven.plugins.annotations.LifecyclePhase;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;
import org.apache.maven.project.MavenProject;

@Mojo(name = "generate", defaultPhase = LifecyclePhase.GENERATE_SOURCES)
public class YamlCodegenMojo extends AbstractMojo {

    @Parameter(required = true)
    private File schemaFile;

    @Parameter(required = true)
    private List<OutputConfig> outputs;

    @Parameter(defaultValue = "${project}", readonly = true)
    private MavenProject project;

    @Override
    public void execute() throws MojoExecutionException {
        if (!schemaFile.exists()) {
            throw new MojoExecutionException("Schema file not found: " + schemaFile);
        }

        File outputDir = new File(project.getBuild().getDirectory(),
                "generated-sources/yaml-codegen");
        project.addCompileSourceRoot(outputDir.getAbsolutePath());

        for (OutputConfig output : outputs) {
            try {
                switch (output.getFormat()) {
                    case "record" -> generateRecords(output, outputDir);
                    case "pojo" -> generatePojos(output, outputDir);
                    default -> throw new MojoExecutionException(
                            "Unknown format: " + output.getFormat());
                }
            } catch (Exception e) {
                throw new MojoExecutionException(
                        "Generation failed for format " + output.getFormat(), e);
            }
        }
    }

    private void generateRecords(OutputConfig output, File outputDir)
            throws IOException {
        TypeGraph graph = new SchemaParser().parse(schemaFile);

        MappingConfig mapping = output.getMappingsFile() != null
                ? MappingConfig.load(new File(output.getMappingsFile()))
                : MappingConfig.empty();

        RecordEmitter.EmitConfig emitConfig = new RecordEmitter.EmitConfig(
                output.getTargetPackage(), output.getPrefix());

        List<RecordEmitter.GeneratedFile> files =
                new RecordEmitter().emit(graph, mapping, emitConfig);

        for (RecordEmitter.GeneratedFile file : files) {
            Path dir = outputDir.toPath().resolve(
                    output.getTargetPackage().replace('.', '/'));
            Files.createDirectories(dir);
            Files.writeString(dir.resolve(file.fileName()), file.content());
        }

        getLog().info("Generated " + files.size() + " record files to "
                + output.getTargetPackage());
    }

    private void generatePojos(OutputConfig output, File outputDir) {
        new PojoEmitter().emit(schemaFile, output.getTargetPackage(),
                output.getRuleFactory(), outputDir);
        getLog().info("Generated POJOs to " + output.getTargetPackage());
    }
}
```

- [ ] **Step 6: Write Mojo integration test**

Create `yaml-codegen/src/test/java/io/casehub/yaml/codegen/YamlCodegenMojoTest.java` — test the Mojo's `execute()` method directly (not via Maven invocation). Create a mock `MavenProject` that returns a temp directory for `getBuild().getDirectory()`:

```java
package io.casehub.yaml.codegen;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class YamlCodegenMojoTest {

    @TempDir Path tempDir;

    @Test
    void generateRecordsWritesFiles() throws Exception {
        TypeGraph graph = new SchemaParser()
                .parse(new File("src/test/resources/schema/simple-test.yaml"));
        MappingConfig mapping = MappingConfig.empty();
        RecordEmitter.EmitConfig config =
                new RecordEmitter.EmitConfig("io.test.yaml", "Yaml");

        List<RecordEmitter.GeneratedFile> files =
                new RecordEmitter().emit(graph, mapping, config);

        Path outputDir = tempDir.resolve("io/test/yaml");
        Files.createDirectories(outputDir);
        for (RecordEmitter.GeneratedFile file : files) {
            Files.writeString(outputDir.resolve(file.fileName()), file.content());
        }

        assertThat(outputDir.resolve("YamlPerson.java")).exists();
        assertThat(outputDir.resolve("YamlAddress.java")).exists();

        String person = Files.readString(outputDir.resolve("YamlPerson.java"));
        assertThat(person).contains("package io.test.yaml;");
        assertThat(person).contains("public record YamlPerson(");
    }
}
```

- [ ] **Step 7: Run all tests**

Run: `mvn test -pl yaml-codegen -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: All tests PASS.

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-codegen/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#258): PojoEmitter + YamlCodegenMojo — Maven plugin wiring Refs #258"
```

---

## Batch 4: Engine schema validation test

### Task 5: Validate against engine's CaseDefinition.yaml

**Files:**
- Create: `yaml-codegen/src/test/resources/schema/CaseDefinition.yaml` (copy from engine)
- Create: `yaml-codegen/src/test/resources/schema/engine-record-mappings.yaml`
- Create: `yaml-codegen/src/test/java/io/casehub/yaml/codegen/EngineSchemaValidationTest.java`

**Interfaces:**
- Consumes: `SchemaParser`, `MappingConfig`, `RecordEmitter` (all previous tasks)

- [ ] **Step 1: Copy engine schema to test resources**

```bash
cp /Users/mdproctor/claude/casehub/engine/schema/src/main/resources/schema/CaseDefinition.yaml /Users/mdproctor/claude/casehub/platform/yaml-codegen/src/test/resources/schema/CaseDefinition.yaml
```

- [ ] **Step 2: Create engine record mappings file**

Create `yaml-codegen/src/test/resources/schema/engine-record-mappings.yaml` with the full mapping from the spec's Mapping File Schema section (all 15 annotation overrides from the hand-written records).

- [ ] **Step 3: Write validation test**

Create `yaml-codegen/src/test/java/io/casehub/yaml/codegen/EngineSchemaValidationTest.java`:

```java
package io.casehub.yaml.codegen;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.File;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

class EngineSchemaValidationTest {

    private static List<RecordEmitter.GeneratedFile> generatedFiles;

    @BeforeAll
    static void generateFromEngineSchema() {
        TypeGraph graph = new SchemaParser()
                .parse(new File("src/test/resources/schema/CaseDefinition.yaml"));
        MappingConfig mapping = MappingConfig.load(
                new File("src/test/resources/schema/engine-record-mappings.yaml"));
        RecordEmitter.EmitConfig config = new RecordEmitter.EmitConfig(
                "io.casehub.api.model.converter.yaml", "Yaml");
        generatedFiles = new RecordEmitter().emit(graph, mapping, config);
    }

    @Test
    void generatesExpectedNumberOfTypes() {
        assertThat(generatedFiles.size()).isGreaterThanOrEqualTo(20);
    }

    @Test
    void generatesBindingRecord() {
        RecordEmitter.GeneratedFile binding = findFile("YamlBinding.java");
        assertThat(binding.content()).contains("@JsonDeserialize(using = TriggerDeserializer.class)");
        assertThat(binding.content()).contains("Trigger on");
        assertThat(binding.content()).contains("@JsonAlias(\"replanAfter\")");
        assertThat(binding.content()).contains("List<String> producedKeys");
    }

    @Test
    void generatesWorkerRecord() {
        RecordEmitter.GeneratedFile worker = findFile("YamlWorker.java");
        assertThat(worker.content()).contains("@JsonProperty(\"do\")");
        assertThat(worker.content()).contains("JsonNode doBlock");
    }

    @Test
    void generatesCaseSpecRecord() {
        RecordEmitter.GeneratedFile spec = findFile("YamlCaseDefinitionSpec.java");
        assertThat(spec.content()).contains(
                "@JsonDeserialize(using = CaseCompletionDeserializer.class)");
        assertThat(spec.content()).contains("@JsonAlias(\"cbr\")");
        assertThat(spec.content()).contains("@JsonAlias(\"adaptation\")");
    }

    @Test
    void allRecordsHaveJsonIgnoreProperties() {
        for (RecordEmitter.GeneratedFile file : generatedFiles) {
            assertThat(file.content())
                    .as("File %s should have @JsonIgnoreProperties", file.fileName())
                    .contains("@JsonIgnoreProperties(ignoreUnknown = true)");
        }
    }

    @Test
    void allRecordsHaveNullSafeListDefaults() {
        RecordEmitter.GeneratedFile binding = findFile("YamlBinding.java");
        assertThat(binding.content()).contains("if (producedKeys == null)");
        assertThat(binding.content()).contains("producedKeys = List.of()");
    }

    private RecordEmitter.GeneratedFile findFile(String fileName) {
        return generatedFiles.stream()
                .filter(f -> f.fileName().equals(fileName))
                .findFirst()
                .orElseThrow(() -> new AssertionError(
                        "Generated file not found: " + fileName
                        + ". Available: " + generatedFiles.stream()
                                .map(RecordEmitter.GeneratedFile::fileName)
                                .collect(Collectors.joining(", "))));
    }
}
```

- [ ] **Step 4: Run validation tests**

Run: `mvn test -pl yaml-codegen -f /Users/mdproctor/claude/casehub/platform/pom.xml`
Expected: All validation tests PASS. If failures, iterate on `SchemaParser` and `RecordEmitter` to handle edge cases in the engine schema (inline objects, oneOf, additionalProperties with $ref).

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add yaml-codegen/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#258): engine schema validation — generated records match hand-written baseline Refs #258"
```

## References

- [2026-09-01-yaml-codegen-design.md] — design spec this plan implements
- engine `codegen/CasehubCodegen.java` — existing POJO generator (model for PojoEmitter)
- engine `schema/src/main/resources/schema/CaseDefinition.yaml` — validation target schema
- engine `api/src/main/java/io/casehub/api/model/converter/yaml/*.java` — 46 hand-written records (baseline)
- platform `graphql-generator/pom.xml` — existing generator module pattern
- platform#258 — focal issue
- engine#1018 — parent issue (engine-side migration)
