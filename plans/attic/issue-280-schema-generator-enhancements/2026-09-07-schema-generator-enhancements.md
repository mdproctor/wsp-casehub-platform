# Schema Generator Enhancements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #280 — Extract ShorthandModule from neocortex to casehub-platform-schema-generator
**Issue group:** #280, #281, #282

**Goal:** Add ShorthandModule to schema-generator, enhance yaml-codegen with engine's best features, and add drift-detection Maven Enforcer rule.

**Architecture:** Three independent parts in one branch. Part 1 adds a parameterized victools Module for scalar-or-object polymorphism. Part 2 merges engine's codegen capabilities into platform's existing yaml-codegen Maven plugin. Part 3 adds a Maven Enforcer custom rule for codegen drift detection.

**Tech Stack:** victools/jsonschema-generator 4.36.0, Maven Plugin API, Maven Enforcer API 3.5.0, Jackson, JUnit 5, AssertJ

## Global Constraints

- `schema-generator/` has no Quarkus, no CDI — pure Java + victools
- `yaml-codegen/` is `maven-plugin` packaging — depends on jsonschema2pojo-core + Maven Plugin API
- `drift-detection/` is regular JAR packaging — depends on `enforcer-api` provided scope only
- All new public types follow existing package conventions: `io.casehub.schema.generator.module.*`, `io.casehub.yaml.codegen.*`, `io.casehub.platform.drift.*`
- Opt-in inclusion for ShorthandModule — not added to PlatformSchemaGenerator defaults
- Backward compatibility — existing yaml-codegen consumers must not break

---

## Batch 1: ShorthandModule (#280)

### Task 1: ShorthandDefinition interface and ShorthandModule

**Files:**
- Create: `schema-generator/src/main/java/io/casehub/schema/generator/module/ShorthandDefinition.java`
- Create: `schema-generator/src/main/java/io/casehub/schema/generator/module/ShorthandModule.java`
- Create: `schema-generator/src/test/java/io/casehub/schema/generator/module/ShorthandModuleTest.java`

**Interfaces:**
- Consumes: `com.github.victools.jsonschema.generator.Module` (victools SPI), `SchemaGeneratorConfig.createObjectNode()` (JSON node factory)
- Produces: `ShorthandDefinition` (interface: `scalarSchema(SchemaGeneratorConfig)`, `objectSchema(SchemaGeneratorConfig)`, `static of(Function, Function)`), `ShorthandModule` (constructor: `Map<Class<?>, ShorthandDefinition>`, implements `Module`)

- [ ] **Step 1: Write failing tests**

Create `ShorthandModuleTest.java` with local test types and 6 test methods. Use `ide_create_file`.

```java
package io.casehub.schema.generator.module;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.github.victools.jsonschema.generator.Option;
import com.github.victools.jsonschema.generator.OptionPreset;
import com.github.victools.jsonschema.generator.SchemaGenerator;
import com.github.victools.jsonschema.generator.SchemaGeneratorConfigBuilder;
import com.github.victools.jsonschema.generator.SchemaVersion;
import java.util.Map;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class ShorthandModuleTest {

    record Price(double amount, String currency) {}
    record Duration(int value, String unit) {}
    record PlainType(String name) {}

    sealed interface Animal permits Dog, Cat {}
    record Dog(String breed) implements Animal {}
    record Cat(boolean indoor) implements Animal {}

    private SchemaGenerator generator(Map<Class<?>, ShorthandDefinition> defs) {
        var builder = new SchemaGeneratorConfigBuilder(
            SchemaVersion.DRAFT_2020_12, OptionPreset.PLAIN_JSON);
        builder.with(Option.DEFINITIONS_FOR_ALL_OBJECTS);
        builder.with(new ShorthandModule(defs));
        return new SchemaGenerator(builder.build());
    }

    @Test
    void shorthandType_generatesOneOf_withScalarAndObjectForms() {
        var gen = generator(Map.of(
            Price.class, ShorthandDefinition.of(
                config -> {
                    ObjectNode s = config.createObjectNode();
                    s.put("type", "number");
                    return s;
                },
                config -> {
                    ObjectNode o = config.createObjectNode();
                    o.put("type", "object");
                    o.putObject("properties").putObject("amount").put("type", "number");
                    return o;
                }
            )
        ));
        var schema = gen.generateSchema(Price.class);

        assertThat(schema.has("oneOf")).isTrue();
        assertThat(schema.get("oneOf").size()).isEqualTo(2);
    }

    @Test
    void scalarForm_matchesCallerProvidedSchema() {
        var gen = generator(Map.of(
            Price.class, ShorthandDefinition.of(
                config -> {
                    ObjectNode s = config.createObjectNode();
                    s.put("type", "number").put("minimum", 0);
                    return s;
                },
                config -> {
                    ObjectNode o = config.createObjectNode();
                    o.put("type", "object");
                    return o;
                }
            )
        ));
        var schema = gen.generateSchema(Price.class);

        for (var option : schema.get("oneOf")) {
            if ("number".equals(option.path("type").asText())) {
                assertThat(option.get("minimum").asInt()).isEqualTo(0);
                return;
            }
        }
        org.junit.jupiter.api.Assertions.fail("No number form found");
    }

    @Test
    void objectForm_matchesCallerProvidedSchema() {
        var gen = generator(Map.of(
            Price.class, ShorthandDefinition.of(
                config -> config.createObjectNode().put("type", "string"),
                config -> {
                    ObjectNode o = config.createObjectNode();
                    o.put("type", "object");
                    ObjectNode props = o.putObject("properties");
                    props.putObject("amount").put("type", "number");
                    props.putObject("currency").put("type", "string");
                    o.putArray("required").add("amount").add("currency");
                    return o;
                }
            )
        ));
        var schema = gen.generateSchema(Price.class);

        for (var option : schema.get("oneOf")) {
            if ("object".equals(option.path("type").asText())) {
                assertThat(option.get("properties").has("amount")).isTrue();
                assertThat(option.get("properties").has("currency")).isTrue();
                assertThat(option.get("required").toString()).contains("amount");
                return;
            }
        }
        org.junit.jupiter.api.Assertions.fail("No object form found");
    }

    @Test
    void nonShorthandType_isNotIntercepted() {
        var gen = generator(Map.of(
            Price.class, ShorthandDefinition.of(
                config -> config.createObjectNode().put("type", "number"),
                config -> config.createObjectNode().put("type", "object")
            )
        ));
        var schema = gen.generateSchema(PlainType.class);

        assertThat(schema.has("oneOf")).isFalse();
    }

    @Test
    void multipleShorthandTypes_inOneModule() {
        var gen = generator(Map.of(
            Price.class, ShorthandDefinition.of(
                config -> config.createObjectNode().put("type", "number"),
                config -> config.createObjectNode().put("type", "object")
            ),
            Duration.class, ShorthandDefinition.of(
                config -> config.createObjectNode().put("type", "string"),
                config -> config.createObjectNode().put("type", "object")
            )
        ));

        var priceSchema = gen.generateSchema(Price.class);
        var durationSchema = gen.generateSchema(Duration.class);

        assertThat(priceSchema.has("oneOf")).isTrue();
        assertThat(durationSchema.has("oneOf")).isTrue();

        boolean priceHasNumber = false;
        for (var opt : priceSchema.get("oneOf")) {
            if ("number".equals(opt.path("type").asText())) priceHasNumber = true;
        }
        assertThat(priceHasNumber).isTrue();

        boolean durationHasString = false;
        for (var opt : durationSchema.get("oneOf")) {
            if ("string".equals(opt.path("type").asText())) durationHasString = true;
        }
        assertThat(durationHasString).isTrue();
    }

    @Test
    void shorthandAndSealedHierarchy_coexist() {
        var builder = new SchemaGeneratorConfigBuilder(
            SchemaVersion.DRAFT_2020_12, OptionPreset.PLAIN_JSON);
        builder.with(Option.DEFINITIONS_FOR_ALL_OBJECTS);
        builder.with(new SealedHierarchyModule());
        builder.with(new ShorthandModule(Map.of(
            Price.class, ShorthandDefinition.of(
                config -> config.createObjectNode().put("type", "number"),
                config -> config.createObjectNode().put("type", "object")
            )
        )));
        var gen = new SchemaGenerator(builder.build());

        var priceSchema = gen.generateSchema(Price.class);
        assertThat(priceSchema.has("oneOf")).isTrue();
        assertThat(priceSchema.get("oneOf").size()).isEqualTo(2);

        var animalSchema = gen.generateSchema(Animal.class);
        assertThat(animalSchema.has("oneOf")).isTrue();
        assertThat(animalSchema.get("oneOf").size()).isEqualTo(2);
        for (var entry : animalSchema.get("oneOf")) {
            assertThat(entry.has("properties")).isTrue();
            assertThat(entry.get("properties").has("type")).isTrue();
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl schema-generator test -Dtest=ShorthandModuleTest --batch-mode`
Expected: Compilation failure — `ShorthandDefinition` and `ShorthandModule` not found.

- [ ] **Step 3: Create ShorthandDefinition interface**

Create `ShorthandDefinition.java` using `ide_create_file`:

```java
package io.casehub.schema.generator.module;

import com.fasterxml.jackson.databind.node.ObjectNode;
import com.github.victools.jsonschema.generator.SchemaGeneratorConfig;
import java.util.function.Function;

public interface ShorthandDefinition {

    ObjectNode scalarSchema(SchemaGeneratorConfig config);

    ObjectNode objectSchema(SchemaGeneratorConfig config);

    static ShorthandDefinition of(
            Function<SchemaGeneratorConfig, ObjectNode> scalar,
            Function<SchemaGeneratorConfig, ObjectNode> object) {
        return new ShorthandDefinition() {
            @Override
            public ObjectNode scalarSchema(SchemaGeneratorConfig config) {
                return scalar.apply(config);
            }

            @Override
            public ObjectNode objectSchema(SchemaGeneratorConfig config) {
                return object.apply(config);
            }
        };
    }
}
```

- [ ] **Step 4: Create ShorthandModule**

Create `ShorthandModule.java` using `ide_create_file`:

```java
package io.casehub.schema.generator.module;

import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.github.victools.jsonschema.generator.CustomDefinition;
import com.github.victools.jsonschema.generator.Module;
import com.github.victools.jsonschema.generator.SchemaGeneratorConfig;
import com.github.victools.jsonschema.generator.SchemaGeneratorConfigBuilder;
import java.util.Map;

public class ShorthandModule implements Module {

    private final Map<Class<?>, ShorthandDefinition> definitions;

    public ShorthandModule(Map<Class<?>, ShorthandDefinition> definitions) {
        this.definitions = Map.copyOf(definitions);
    }

    @Override
    public void applyToConfigBuilder(SchemaGeneratorConfigBuilder builder) {
        builder.forTypesInGeneral()
            .withCustomDefinitionProvider((type, context) -> {
                ShorthandDefinition def = definitions.get(type.getErasedType());
                if (def == null) {
                    return null;
                }
                return buildOneOf(def, context.getGeneratorConfig());
            });
    }

    private CustomDefinition buildOneOf(ShorthandDefinition def, SchemaGeneratorConfig config) {
        ObjectNode schema = config.createObjectNode();
        ArrayNode oneOf = schema.putArray("oneOf");
        oneOf.add(def.scalarSchema(config));
        oneOf.add(def.objectSchema(config));
        return new CustomDefinition(schema);
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -pl schema-generator test -Dtest=ShorthandModuleTest --batch-mode`
Expected: All 6 tests PASS.

- [ ] **Step 6: Run full schema-generator test suite**

Run: `mvn -pl schema-generator test --batch-mode`
Expected: All tests PASS (existing PlatformSchemaGeneratorTest + SealedHierarchyModuleTest + ShorthandModuleTest).

- [ ] **Step 7: Verify with ide_diagnostics**

Run: `ide_diagnostics` on `schema-generator/` to confirm no compilation errors.

- [ ] **Step 8: Commit**

```bash
git add schema-generator/src/main/java/io/casehub/schema/generator/module/ShorthandDefinition.java schema-generator/src/main/java/io/casehub/schema/generator/module/ShorthandModule.java schema-generator/src/test/java/io/casehub/schema/generator/module/ShorthandModuleTest.java
git commit -m "feat(#280): add ShorthandModule for scalar-or-object polymorphism in JSON Schema

Parameterized victools Module that wraps caller-provided scalar and object
form schemas in oneOf. Callers provide Map<Class<?>, ShorthandDefinition>
where each definition supplies both forms explicitly.

Refs #280"
```

---

## Batch 2: yaml-codegen consolidation (#282) — MappingConfig expansion

### Task 2: Expand MappingConfig with engine features

**Files:**
- Modify: `yaml-codegen/src/main/java/io/casehub/yaml/codegen/MappingConfig.java`
- Modify: `yaml-codegen/src/test/java/io/casehub/yaml/codegen/MappingConfigTest.java`
- Create: `yaml-codegen/src/test/resources/schema/enhanced-mappings.yaml`

**Interfaces:**
- Consumes: existing `MappingConfig.load(File)` (YAML parsing)
- Produces: expanded `MappingConfig(globalAnnotations, skipPatterns, imports, deserializers, types)`, expanded `TypeMapping(recordName, fields, additionalFields, body)`, expanded `FieldMapping(name, type, deserializer, aliases, jsonProperty, skip, defaultValue)`

- [ ] **Step 1: Write failing test for new MappingConfig fields**

Create test YAML file `yaml-codegen/src/test/resources/schema/enhanced-mappings.yaml`:

```yaml
globalAnnotations:
  - "com.fasterxml.jackson.annotation.JsonIgnoreProperties(ignoreUnknown = true)"

skipPatterns:
  - "x-*"
  - "internal"

imports:
  Duration: "java.time.Duration"
  Instant: "java.time.Instant"

deserializers:
  DurationDeserializer: "io.casehub.deser.DurationDeserializer"

types:
  CaseDefinition:
    recordName: CaseDef
    body: |
      public String key() {
        return name() != null ? name() : "unnamed";
      }
    fields:
      name:
        alias: title
        defaultValue: "\"unnamed\""
      duration:
        type: Duration
        deserializer: DurationDeserializer
    additionalFields:
      - name: version
        type: Integer
        defaultValue: "0"
```

Add tests to `MappingConfigTest.java` using `ide_edit_member`:

```java
@Test
void loadsSkipPatterns() {
    MappingConfig config = MappingConfig.load(
        new File("src/test/resources/schema/enhanced-mappings.yaml"));
    assertThat(config.skipPatterns()).containsExactly("x-*", "internal");
}

@Test
void loadsGlobalImports() {
    MappingConfig config = MappingConfig.load(
        new File("src/test/resources/schema/enhanced-mappings.yaml"));
    assertThat(config.imports()).containsEntry("Duration", "java.time.Duration");
    assertThat(config.imports()).containsEntry("Instant", "java.time.Instant");
}

@Test
void loadsGlobalDeserializers() {
    MappingConfig config = MappingConfig.load(
        new File("src/test/resources/schema/enhanced-mappings.yaml"));
    assertThat(config.deserializers())
        .containsEntry("DurationDeserializer", "io.casehub.deser.DurationDeserializer");
}

@Test
void loadsRecordName() {
    MappingConfig config = MappingConfig.load(
        new File("src/test/resources/schema/enhanced-mappings.yaml"));
    var tm = config.forType("CaseDefinition").orElseThrow();
    assertThat(tm.recordName()).isEqualTo("CaseDef");
}

@Test
void loadsBody() {
    MappingConfig config = MappingConfig.load(
        new File("src/test/resources/schema/enhanced-mappings.yaml"));
    var tm = config.forType("CaseDefinition").orElseThrow();
    assertThat(tm.body()).contains("public String key()");
}

@Test
void loadsFieldDefaultValue() {
    MappingConfig config = MappingConfig.load(
        new File("src/test/resources/schema/enhanced-mappings.yaml"));
    var tm = config.forType("CaseDefinition").orElseThrow();
    var nameField = tm.forField("name").orElseThrow();
    assertThat(nameField.defaultValue()).isEqualTo("\"unnamed\"");
}

@Test
void emptyConfig_hasEmptyNewFields() {
    MappingConfig config = MappingConfig.empty();
    assertThat(config.skipPatterns()).isEmpty();
    assertThat(config.imports()).isEmpty();
    assertThat(config.deserializers()).isEmpty();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-codegen test -Dtest=MappingConfigTest --batch-mode`
Expected: Compilation failure — new fields/methods not found.

- [ ] **Step 3: Expand MappingConfig record**

Use `ide_replace_member` to update `MappingConfig`:

Update the record to:
```java
public record MappingConfig(
    List<String> globalAnnotations,
    List<String> skipPatterns,
    Map<String, String> imports,
    Map<String, String> deserializers,
    Map<String, TypeMapping> types) {
```

Update `empty()`:
```java
public static MappingConfig empty() {
    return new MappingConfig(List.of(), List.of(), Map.of(), Map.of(), Map.of());
}
```

Update `load()` to parse new fields:
```java
List<String> skipPatterns = new ArrayList<>();
JsonNode skipNode = root.path("skipPatterns");
if (skipNode.isArray()) {
    skipNode.forEach(n -> skipPatterns.add(n.asText()));
}

Map<String, String> imports = readStringMap(root.path("imports"));
Map<String, String> deserializers = readStringMap(root.path("deserializers"));
```

Add `readStringMap()` private helper:
```java
private static Map<String, String> readStringMap(JsonNode node) {
    Map<String, String> map = new HashMap<>();
    if (node.isObject()) {
        Iterator<Map.Entry<String, JsonNode>> it = node.fields();
        while (it.hasNext()) {
            Map.Entry<String, JsonNode> entry = it.next();
            map.put(entry.getKey(), entry.getValue().asText());
        }
    }
    return Map.copyOf(map);
}
```

Update constructor call to pass new fields.

Update `TypeMapping`:
```java
public record TypeMapping(
    String recordName,
    Map<String, FieldMapping> fields,
    List<FieldMapping> additionalFields,
    String body) {
```

Update `FieldMapping`:
```java
public record FieldMapping(
    String name,
    String type,
    String deserializer,
    List<String> aliases,
    String jsonProperty,
    boolean skip,
    String defaultValue) {}
```

Update `parseTypeMapping()` to read `recordName` and `body`:
```java
String recordName = node.path("recordName").asText(null);
String body = node.path("body").asText(null);
return new TypeMapping(recordName, Map.copyOf(fields), List.copyOf(additional), body);
```

Update `parseFieldMapping()` to read `defaultValue`:
```java
String defaultValue = node.has("defaultValue") ? node.get("defaultValue").asText() : null;
return new FieldMapping(name, type, deserializer, List.copyOf(aliases), jsonProperty, skip, defaultValue);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn -pl yaml-codegen test -Dtest=MappingConfigTest --batch-mode`
Expected: All tests PASS.

- [ ] **Step 5: Run full yaml-codegen suite to verify backward compat**

Run: `mvn -pl yaml-codegen test --batch-mode`
Expected: All existing tests still PASS.

- [ ] **Step 6: Commit**

```bash
git add yaml-codegen/src/main/java/io/casehub/yaml/codegen/MappingConfig.java yaml-codegen/src/test/java/io/casehub/yaml/codegen/MappingConfigTest.java yaml-codegen/src/test/resources/schema/enhanced-mappings.yaml
git commit -m "feat(#282): expand MappingConfig with engine codegen features

Add skipPatterns, imports, deserializers (global), recordName, body
(per-type), defaultValue (per-field). Backward compatible — all new
fields optional with empty defaults.

Refs #282"
```

### Task 3: RecordEmitter — skipPatterns, recordName, defaultValue, body injection

**Files:**
- Modify: `yaml-codegen/src/main/java/io/casehub/yaml/codegen/RecordEmitter.java`
- Modify: `yaml-codegen/src/main/java/io/casehub/yaml/codegen/JavaTypeResolver.java`
- Modify: `yaml-codegen/src/test/java/io/casehub/yaml/codegen/RecordEmitterTest.java`
- Create: `yaml-codegen/src/test/resources/schema/enhanced-test.yaml`

**Interfaces:**
- Consumes: expanded `MappingConfig` from Task 2
- Produces: `RecordEmitter.emit(TypeGraph, MappingConfig, EmitConfig)` — enhanced to handle skipPatterns, recordName, defaultValue, body

- [ ] **Step 1: Create test schema and write failing tests**

Create `yaml-codegen/src/test/resources/schema/enhanced-test.yaml`:

```yaml
$schema: https://json-schema.org/draft/2020-12/schema
$defs:
  Event:
    type: object
    properties:
      name:
        type: string
      x-internal:
        type: string
      x-debug:
        type: boolean
      priority:
        type: integer
      tags:
        type: array
        items:
          type: string
```

Add tests to `RecordEmitterTest.java`:

```java
@Test
void skipPatterns_globMatchOmitsFields() {
    TypeGraph enhancedGraph = new SchemaParser()
        .parse(new File("src/test/resources/schema/enhanced-test.yaml"));
    MappingConfig mapping = MappingConfig.load(
        new File("src/test/resources/schema/enhanced-mappings.yaml"));
    List<RecordEmitter.GeneratedFile> files =
        new RecordEmitter().emit(enhancedGraph, mapping, config);
    RecordEmitter.GeneratedFile event = files.stream()
        .filter(f -> f.fileName().contains("Event"))
        .findFirst().orElseThrow();
    assertThat(event.content()).doesNotContain("x-internal");
    assertThat(event.content()).doesNotContain("x-debug");
    assertThat(event.content()).contains("name");
}

@Test
void recordName_overridesSchemaTypeName() {
    TypeGraph caseGraph = new TypeGraph(List.of(
        new TypeGraph.TypeDef("CaseDefinition", List.of(
            new TypeGraph.FieldDef("name", "string", null, false, false, null, false, null),
            new TypeGraph.FieldDef("duration", "object", null, false, false, null, false, null)
        ), false, null)
    ));
    MappingConfig mapping = MappingConfig.load(
        new File("src/test/resources/schema/enhanced-mappings.yaml"));
    List<RecordEmitter.GeneratedFile> files =
        new RecordEmitter().emit(caseGraph, mapping, new RecordEmitter.EmitConfig("io.test.yaml", ""));
    boolean hasCaseDef = files.stream()
        .anyMatch(f -> f.fileName().equals("CaseDef.java"));
    assertThat(hasCaseDef).as("recordName should override schema type name").isTrue();
}

@Test
void defaultValue_generatesCompactConstructorGuard() {
    TypeGraph caseGraph = new TypeGraph(List.of(
        new TypeGraph.TypeDef("CaseDefinition", List.of(
            new TypeGraph.FieldDef("name", "string", null, false, false, null, false, null),
            new TypeGraph.FieldDef("duration", "object", null, false, false, null, false, null)
        ), false, null)
    ));
    MappingConfig mapping = MappingConfig.load(
        new File("src/test/resources/schema/enhanced-mappings.yaml"));
    List<RecordEmitter.GeneratedFile> files =
        new RecordEmitter().emit(caseGraph, mapping, new RecordEmitter.EmitConfig("io.test.yaml", ""));
    RecordEmitter.GeneratedFile caseDef = files.stream()
        .filter(f -> f.content().contains("CaseDef"))
        .findFirst().orElseThrow();
    assertThat(caseDef.content()).contains("if (name == null)");
    assertThat(caseDef.content()).contains("name = \"unnamed\"");
}

@Test
void body_injectedIntoRecordBody() {
    TypeGraph caseGraph = new TypeGraph(List.of(
        new TypeGraph.TypeDef("CaseDefinition", List.of(
            new TypeGraph.FieldDef("name", "string", null, false, false, null, false, null)
        ), false, null)
    ));
    MappingConfig mapping = MappingConfig.load(
        new File("src/test/resources/schema/enhanced-mappings.yaml"));
    List<RecordEmitter.GeneratedFile> files =
        new RecordEmitter().emit(caseGraph, mapping, new RecordEmitter.EmitConfig("io.test.yaml", ""));
    RecordEmitter.GeneratedFile caseDef = files.stream()
        .filter(f -> f.content().contains("CaseDef"))
        .findFirst().orElseThrow();
    assertThat(caseDef.content()).contains("public String key()");
}

@Test
void globalImports_resolveShortTypeNames() {
    TypeGraph caseGraph = new TypeGraph(List.of(
        new TypeGraph.TypeDef("CaseDefinition", List.of(
            new TypeGraph.FieldDef("name", "string", null, false, false, null, false, null),
            new TypeGraph.FieldDef("duration", "object", null, false, false, null, false, null)
        ), false, null)
    ));
    MappingConfig mapping = MappingConfig.load(
        new File("src/test/resources/schema/enhanced-mappings.yaml"));
    List<RecordEmitter.GeneratedFile> files =
        new RecordEmitter().emit(caseGraph, mapping, new RecordEmitter.EmitConfig("io.test.yaml", ""));
    RecordEmitter.GeneratedFile caseDef = files.stream()
        .filter(f -> f.content().contains("CaseDef"))
        .findFirst().orElseThrow();
    assertThat(caseDef.content()).contains("import java.time.Duration;");
    assertThat(caseDef.content()).contains("Duration duration");
}

@Test
void globalDeserializers_resolveImports() {
    TypeGraph caseGraph = new TypeGraph(List.of(
        new TypeGraph.TypeDef("CaseDefinition", List.of(
            new TypeGraph.FieldDef("name", "string", null, false, false, null, false, null),
            new TypeGraph.FieldDef("duration", "object", null, false, false, null, false, null)
        ), false, null)
    ));
    MappingConfig mapping = MappingConfig.load(
        new File("src/test/resources/schema/enhanced-mappings.yaml"));
    List<RecordEmitter.GeneratedFile> files =
        new RecordEmitter().emit(caseGraph, mapping, new RecordEmitter.EmitConfig("io.test.yaml", ""));
    RecordEmitter.GeneratedFile caseDef = files.stream()
        .filter(f -> f.content().contains("CaseDef"))
        .findFirst().orElseThrow();
    assertThat(caseDef.content()).contains("import io.casehub.deser.DurationDeserializer;");
}

@Test
void existingTests_stillPass() {
    List<RecordEmitter.GeneratedFile> files =
        new RecordEmitter().emit(graph, emptyMapping, config);
    assertThat(files).hasSize(2);
    assertThat(files.stream().map(RecordEmitter.GeneratedFile::fileName))
        .containsExactlyInAnyOrder("YamlPerson.java", "YamlAddress.java");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-codegen test -Dtest=RecordEmitterTest --batch-mode`
Expected: New tests fail (features not implemented yet). Existing tests should still pass.

- [ ] **Step 3: Implement RecordEmitter changes**

Use `ide_edit_member` / `ide_replace_member` to modify `RecordEmitter.java`:

**skipPatterns** — add method and call it before per-field processing in `resolveFields()`:

```java
private boolean shouldSkip(String fieldName, MappingConfig config) {
    for (String pattern : config.skipPatterns()) {
        if (pattern.endsWith("*")) {
            String prefix = pattern.substring(0, pattern.length() - 1);
            if (fieldName.startsWith(prefix)) return true;
        } else if (pattern.equals(fieldName)) {
            return true;
        }
    }
    return false;
}
```

**recordName** — in `emitRecord()`, use `typeMapping.recordName()` when present:

```java
String className;
if (typeMapping != null && typeMapping.recordName() != null) {
    className = typeMapping.recordName();
} else {
    className = config.prefix() + typeDef.name();
}
```

**defaultValue** — expand compact constructor to handle explicit defaults:

```java
List<ResolvedField> nullSafeFields = fields.stream()
    .filter(f -> f.type.typeName().startsWith("List<")
        || f.type.typeName().startsWith("Map<")
        || f.defaultValue != null)
    .toList();
```

In the compact constructor, use field-specific default:
```java
String defaultValue = f.defaultValue != null ? f.defaultValue
    : f.type.typeName().startsWith("List<") ? "List.of()" : "Map.of()";
```

**body** — after compact constructor, append body if present:

```java
if (typeMapping != null && typeMapping.body() != null && !typeMapping.body().isBlank()) {
    sb.append("\n");
    for (String line : typeMapping.body().lines().toList()) {
        sb.append("  ").append(line).append("\n");
    }
}
```

**global imports/deserializers** — update `resolveImports()` in `RecordEmitter` and `resolve()` in `JavaTypeResolver` to check `config.imports()` and `config.deserializers()` maps. Pass `MappingConfig` through to import resolution.

Update `ResolvedField` to carry `defaultValue`:
```java
private record ResolvedField(
    String name,
    JavaTypeResolver.ResolvedType type,
    List<String> annotations,
    Set<String> annotationImports,
    String defaultValue) {}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn -pl yaml-codegen test --batch-mode`
Expected: All tests PASS (new + existing).

- [ ] **Step 5: Verify with ide_diagnostics**

Run: `ide_diagnostics` on `yaml-codegen/` to confirm no compilation errors.

- [ ] **Step 6: Commit**

```bash
git add yaml-codegen/
git commit -m "feat(#282): RecordEmitter — skipPatterns, recordName, defaultValue, body, global imports

Merge engine codegen's best features into yaml-codegen RecordEmitter.
All features backward compatible — empty defaults when not configured.

Refs #282"
```

---

## Batch 3: Drift detection (#281)

### Task 4: DriftDetectionRule Maven Enforcer custom rule

**Files:**
- Create: `drift-detection/pom.xml`
- Create: `drift-detection/src/main/java/io/casehub/platform/drift/DriftDetectionRule.java`
- Create: `drift-detection/src/test/java/io/casehub/platform/drift/DriftDetectionRuleTest.java`
- Modify: `pom.xml` (root) — add `drift-detection` module

**Interfaces:**
- Consumes: `org.apache.maven.enforcer.rule.api.EnforcerRule` (Maven Enforcer SPI)
- Produces: `DriftDetectionRule` — configured via `generatedSourcesDir`, `sourceRoot`, `targetPackage`, `allowListFile`

- [ ] **Step 1: Create drift-detection module pom.xml**

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

    <artifactId>casehub-platform-drift-detection</artifactId>
    <name>CaseHub Platform Drift Detection</name>
    <description>Maven Enforcer custom rule detecting codegen drift — hand-written types in generated packages.</description>

    <properties>
        <version.enforcer-api>3.5.0</version.enforcer-api>
    </properties>

    <dependencies>
        <dependency>
            <groupId>org.apache.maven.enforcer</groupId>
            <artifactId>enforcer-api</artifactId>
            <version>${version.enforcer-api}</version>
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
</project>
```

- [ ] **Step 2: Write failing tests**

Create `DriftDetectionRuleTest.java`:

```java
package io.casehub.platform.drift;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.assertThatNoException;

class DriftDetectionRuleTest {

    @TempDir Path tempDir;

    private Path createDir(String name) throws IOException {
        Path dir = tempDir.resolve(name);
        Files.createDirectories(dir);
        return dir;
    }

    private void createJavaFile(Path dir, String className) throws IOException {
        Files.writeString(dir.resolve(className + ".java"), "public class " + className + " {}");
    }

    @Test
    void noDrift_generatedAndHandWrittenMatch() throws Exception {
        Path generated = createDir("generated");
        Path source = createDir("src/io/casehub/model");
        createJavaFile(generated, "Foo");
        createJavaFile(source, "Foo");

        DriftDetectionRule rule = new DriftDetectionRule();
        assertThatNoException().isThrownBy(() ->
            rule.detectDrift(generated.toString(), source.toString(), null));
    }

    @Test
    void driftDetected_handWrittenNotInGenerated() throws Exception {
        Path generated = createDir("generated");
        Path source = createDir("src/io/casehub/model");
        createJavaFile(generated, "Foo");
        createJavaFile(source, "Foo");
        createJavaFile(source, "Bar");

        DriftDetectionRule rule = new DriftDetectionRule();
        assertThatThrownBy(() ->
            rule.detectDrift(generated.toString(), source.toString(), null))
            .hasMessageContaining("Bar");
    }

    @Test
    void allowList_permitsHandWrittenType() throws Exception {
        Path generated = createDir("generated");
        Path source = createDir("src/io/casehub/model");
        createJavaFile(generated, "Foo");
        createJavaFile(source, "Foo");
        createJavaFile(source, "Bar");

        Path allowList = tempDir.resolve("exceptions.txt");
        Files.writeString(allowList, "# Manually written\nBar\n");

        DriftDetectionRule rule = new DriftDetectionRule();
        assertThatNoException().isThrownBy(() ->
            rule.detectDrift(generated.toString(), source.toString(), allowList.toString()));
    }

    @Test
    void emptyGeneratedDir_allHandWrittenFlagged() throws Exception {
        Path generated = createDir("generated");
        Path source = createDir("src/io/casehub/model");
        createJavaFile(source, "Foo");

        DriftDetectionRule rule = new DriftDetectionRule();
        assertThatThrownBy(() ->
            rule.detectDrift(generated.toString(), source.toString(), null))
            .hasMessageContaining("Foo");
    }

    @Test
    void missingAllowListFile_treatedAsEmpty() throws Exception {
        Path generated = createDir("generated");
        Path source = createDir("src/io/casehub/model");
        createJavaFile(generated, "Foo");
        createJavaFile(source, "Foo");
        createJavaFile(source, "Bar");

        DriftDetectionRule rule = new DriftDetectionRule();
        assertThatThrownBy(() ->
            rule.detectDrift(generated.toString(), source.toString(),
                tempDir.resolve("nonexistent.txt").toString()))
            .hasMessageContaining("Bar");
    }

    @Test
    void allowListUnjustified_parsesCorrectly() throws Exception {
        Path allowList = tempDir.resolve("exceptions.txt");
        Files.writeString(allowList, "# Has justification\nJustified\nUnjustified\n");

        DriftDetectionRule.AllowList parsed = DriftDetectionRule.loadAllowList(allowList.toString());
        assertThat(parsed.entries()).containsExactlyInAnyOrder("Justified", "Unjustified");
        assertThat(parsed.unjustified()).containsExactly("Unjustified");
    }

    @Test
    void packageInfoFiles_excluded() throws Exception {
        Path generated = createDir("generated");
        Path source = createDir("src/io/casehub/model");
        createJavaFile(generated, "Foo");
        createJavaFile(source, "Foo");
        createJavaFile(source, "package-info");

        DriftDetectionRule rule = new DriftDetectionRule();
        assertThatNoException().isThrownBy(() ->
            rule.detectDrift(generated.toString(), source.toString(), null));
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn -pl drift-detection test --batch-mode`
Expected: Compilation failure — `DriftDetectionRule` not found.

- [ ] **Step 4: Implement DriftDetectionRule**

Create `DriftDetectionRule.java`:

```java
package io.casehub.platform.drift;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;
import java.util.stream.Collectors;
import java.util.stream.Stream;
import org.apache.maven.enforcer.rule.api.EnforcerRule;
import org.apache.maven.enforcer.rule.api.EnforcerRuleException;
import org.apache.maven.enforcer.rule.api.EnforcerRuleHelper;

public class DriftDetectionRule implements EnforcerRule {

    private String generatedSourcesDir;
    private String sourceRoot;
    private String targetPackage;
    private String allowListFile;

    @Override
    public void execute(EnforcerRuleHelper helper) throws EnforcerRuleException {
        String resolvedSourceDir = sourceRoot != null ? sourceRoot : "src/main/java";
        String packagePath = targetPackage != null ? targetPackage.replace('.', '/') : "";
        String fullSourcePath = resolvedSourceDir + "/" + packagePath;

        List<String> warnings = new ArrayList<>();
        try {
            Set<String> drift = detectDrift(generatedSourcesDir, fullSourcePath, allowListFile,
                warnings);
            for (String w : warnings) {
                helper.getLog().warn(w);
            }
            if (!drift.isEmpty()) {
                throw new EnforcerRuleException(formatError(drift, targetPackage, allowListFile));
            }
        } catch (IOException e) {
            throw new EnforcerRuleException("Drift detection failed: " + e.getMessage(), e);
        }
    }

    Set<String> detectDrift(String generatedDir, String sourceDir, String allowListPath)
            throws IOException, EnforcerRuleException {
        return detectDrift(generatedDir, sourceDir, allowListPath, new ArrayList<>());
    }

    Set<String> detectDrift(String generatedDir, String sourceDir, String allowListPath,
            List<String> warnings) throws IOException, EnforcerRuleException {
        Set<String> generated = scanJavaTypes(Path.of(generatedDir));
        Set<String> handWritten = scanJavaTypes(Path.of(sourceDir));
        AllowList allowList = loadAllowList(allowListPath);

        for (String entry : allowList.unjustified()) {
            warnings.add("Allow-list entry '" + entry + "' has no justification comment");
        }

        Set<String> drift = new TreeSet<>(handWritten);
        drift.removeAll(generated);
        drift.removeAll(allowList.entries());

        if (!drift.isEmpty()) {
            throw new EnforcerRuleException(formatError(drift, sourceDir, allowListPath));
        }
        return drift;
    }

    private Set<String> scanJavaTypes(Path dir) throws IOException {
        if (!Files.isDirectory(dir)) {
            return Set.of();
        }
        try (Stream<Path> files = Files.list(dir)) {
            return files
                .filter(p -> p.toString().endsWith(".java"))
                .map(p -> p.getFileName().toString())
                .map(name -> name.substring(0, name.length() - 5))
                .filter(name -> !name.equals("package-info"))
                .collect(Collectors.toCollection(TreeSet::new));
        }
    }

    static AllowList loadAllowList(String path) throws IOException {
        if (path == null) {
            return new AllowList(Set.of(), Set.of());
        }
        Path file = Path.of(path);
        if (!Files.exists(file)) {
            return new AllowList(Set.of(), Set.of());
        }
        Set<String> entries = new TreeSet<>();
        Set<String> unjustified = new TreeSet<>();
        boolean previousWasComment = false;

        for (String line : Files.readAllLines(file)) {
            String trimmed = line.trim();
            if (trimmed.isEmpty()) {
                previousWasComment = false;
                continue;
            }
            if (trimmed.startsWith("#")) {
                previousWasComment = true;
                continue;
            }
            entries.add(trimmed);
            if (!previousWasComment) {
                unjustified.add(trimmed);
            }
            previousWasComment = false;
        }
        return new AllowList(entries, unjustified);
    }

    private String formatError(Set<String> drift, String targetPackage, String allowListFile) {
        return "Codegen drift detected — hand-written types in " + targetPackage
            + " not in generated output or allow-list:\n"
            + drift.stream().map(t -> "  - " + t).collect(Collectors.joining("\n"))
            + "\n\nTo allow intentionally hand-written types, add them to "
            + (allowListFile != null ? allowListFile : "<allow-list-file>")
            + " with a justification comment.";
    }

    record AllowList(Set<String> entries, Set<String> unjustified) {}

    @Override public boolean isCacheable() { return false; }
    @Override public boolean isResultValid(EnforcerRule cachedRule) { return false; }
    @Override public String getCacheId() { return null; }
}
```

- [ ] **Step 5: Add drift-detection module to root pom.xml**

Use `ide_edit_member` or Edit to add `<module>drift-detection</module>` after `<module>schema-generator</module>` in the root `pom.xml`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn -pl drift-detection test --batch-mode`
Expected: All 7 tests PASS.

- [ ] **Step 7: Run full platform build**

Run: `mvn --batch-mode install`
Expected: Full build succeeds including new `drift-detection` module.

- [ ] **Step 8: Commit**

```bash
git add drift-detection/ pom.xml
git commit -m "feat(#281): add drift-detection Maven Enforcer custom rule

DriftDetectionRule scans hand-written .java files in a target package
against generated sources and an allow-list. Build fails when drift
is found. Unjustified allow-list entries emit warnings.

Refs #281"
```

---

## References

- [2026-09-07-schema-generator-enhancements-design.md] — design spec this plan implements
- [schema-generator/src/main/java/io/casehub/schema/generator/module/SealedHierarchyModule.java] — parameterized module pattern reference
- [schema-generator/src/test/java/io/casehub/schema/generator/module/SealedHierarchyModuleTest.java] — test pattern reference
- [yaml-codegen/src/main/java/io/casehub/yaml/codegen/MappingConfig.java] — current mapping config to expand
- [yaml-codegen/src/main/java/io/casehub/yaml/codegen/RecordEmitter.java] — current emitter to enhance
- [engine/codegen/src/main/java/io/casehub/codegen/record/RecordEmitter.java] — engine features to merge
- [GitHub #280] — ShorthandModule extraction
- [GitHub #281] — drift detection plugin
- [GitHub #282] — yaml-codegen consolidation
