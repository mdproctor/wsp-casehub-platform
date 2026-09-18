# Domain Data Generation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #330 — domain data generation
**Issue group:** #312, #313, #314, #315, #317, #318, #319, #320, #321, #322, #323, #325, #326, #327, #328, #329, #330, #332

**Goal:** Add schema-driven random instance generation that respects Jakarta Validation constraints, usable for load testing and integration testing without domain knowledge.

**Architecture:** SchemaDataGenerator in schema-generator takes a JSON Schema (Draft 2020-12 from PlatformSchemaGenerator) and produces random instances that satisfy structural and constraint requirements. RandomCorpusPopulator in simulation-testing provides thin CorpusSeed integration.

**Tech Stack:** Java 21, JUnit 5, AssertJ, Jackson (JsonNode, ObjectMapper), victools jsonschema-generator (for test schemas)

## Global Constraints

- SchemaDataGenerator lives in schema-generator module — no simulation dependencies
- RandomCorpusPopulator lives in simulation-testing module — thin adapter only
- All constraints derived from JSON Schema keywords (not from Java annotations directly)
- Depth guard max 20 for $ref resolution
- Random constructor parameter for reproducible output

---

## Batch 1: Core generator — primitive types and constraints

### Task 1: SchemaDataGenerator with primitive type generation and constraints

**Files:**
- Create: `schema-generator/src/main/java/io/casehub/schema/generator/SchemaDataGenerator.java`
- Create: `schema-generator/src/main/java/io/casehub/schema/generator/SchemaGenerationException.java`
- Test: `schema-generator/src/test/java/io/casehub/schema/generator/SchemaDataGeneratorTest.java`

**Interfaces:**
- Produces: `SchemaDataGenerator(Random)` constructor
- Produces: `List<JsonNode> generate(JsonNode schema, int count)`
- Produces: `<T> List<T> generate(JsonNode schema, int count, Class<T> targetType, ObjectMapper mapper)`
- Produces: `SchemaGenerationException` (unchecked, for depth overflow and unsupported schema)

- [ ] **Step 1: Write failing tests for primitive types**

Create `SchemaDataGeneratorTest.java` in `schema-generator/src/test/java/io/casehub/schema/generator/`:

```java
package io.casehub.schema.generator;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.junit.jupiter.api.Test;

import java.util.Random;

import static org.assertj.core.api.Assertions.assertThat;

class SchemaDataGeneratorTest {

    private final ObjectMapper mapper = new ObjectMapper();
    private final SchemaDataGenerator generator = new SchemaDataGenerator(new Random(42));

    private ObjectNode schema(String type) {
        ObjectNode node = mapper.createObjectNode();
        node.put("type", type);
        return node;
    }

    @Test
    void generatesStringValues() {
        var results = generator.generate(schema("string"), 5);
        assertThat(results).hasSize(5);
        results.forEach(r -> assertThat(r.isTextual()).isTrue());
    }

    @Test
    void generatesIntegerValues() {
        var results = generator.generate(schema("integer"), 5);
        assertThat(results).hasSize(5);
        results.forEach(r -> assertThat(r.isIntegralNumber()).isTrue());
    }

    @Test
    void generatesNumberValues() {
        var results = generator.generate(schema("number"), 5);
        assertThat(results).hasSize(5);
        results.forEach(r -> assertThat(r.isNumber()).isTrue());
    }

    @Test
    void generatesBooleanValues() {
        var results = generator.generate(schema("boolean"), 5);
        assertThat(results).hasSize(5);
        results.forEach(r -> assertThat(r.isBoolean()).isTrue());
    }

    @Test
    void respectsMinMaxForInteger() {
        var s = schema("integer");
        s.put("minimum", 10);
        s.put("maximum", 20);
        var results = generator.generate(s, 50);
        results.forEach(r -> {
            assertThat(r.asInt()).isBetween(10, 20);
        });
    }

    @Test
    void respectsMinMaxForNumber() {
        var s = schema("number");
        s.put("minimum", 1.5);
        s.put("maximum", 3.5);
        var results = generator.generate(s, 50);
        results.forEach(r -> {
            assertThat(r.asDouble()).isBetween(1.5, 3.5);
        });
    }

    @Test
    void respectsMinLengthMaxLength() {
        var s = schema("string");
        s.put("minLength", 5);
        s.put("maxLength", 10);
        var results = generator.generate(s, 50);
        results.forEach(r -> {
            assertThat(r.asText().length()).isBetween(5, 10);
        });
    }

    @Test
    void selectsFromEnum() {
        var s = schema("string");
        var enumArray = s.putArray("enum");
        enumArray.add("RED");
        enumArray.add("GREEN");
        enumArray.add("BLUE");
        var results = generator.generate(s, 50);
        results.forEach(r -> {
            assertThat(r.asText()).isIn("RED", "GREEN", "BLUE");
        });
    }

    @Test
    void respectsConstValue() {
        var s = schema("string");
        s.put("const", "fixed-value");
        var results = generator.generate(s, 3);
        results.forEach(r -> assertThat(r.asText()).isEqualTo("fixed-value"));
    }

    @Test
    void generatesDateTimeFormat() {
        var s = schema("string");
        s.put("format", "date-time");
        var results = generator.generate(s, 5);
        results.forEach(r -> assertThat(r.asText()).matches("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}.*"));
    }

    @Test
    void generatesUuidFormat() {
        var s = schema("string");
        s.put("format", "uuid");
        var results = generator.generate(s, 5);
        results.forEach(r -> assertThat(r.asText()).matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"));
    }

    @Test
    void seededRandomProducesReproducibleOutput() {
        var gen1 = new SchemaDataGenerator(new Random(99));
        var gen2 = new SchemaDataGenerator(new Random(99));
        var results1 = gen1.generate(schema("integer"), 10);
        var results2 = gen2.generate(schema("integer"), 10);
        assertThat(results1).isEqualTo(results2);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl schema-generator -Dtest=SchemaDataGeneratorTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: Compilation failure — `SchemaDataGenerator` does not exist.

- [ ] **Step 3: Create SchemaGenerationException**

Create `schema-generator/src/main/java/io/casehub/schema/generator/SchemaGenerationException.java`:

```java
package io.casehub.schema.generator;

public class SchemaGenerationException extends RuntimeException {
    public SchemaGenerationException(String message) {
        super(message);
    }
}
```

- [ ] **Step 4: Create SchemaDataGenerator with primitive type support**

Create `schema-generator/src/main/java/io/casehub/schema/generator/SchemaDataGenerator.java`:

The class should:
- Accept `Random` in constructor (default constructor creates `new Random()`)
- `generate(JsonNode schema, int count)` → delegates to a private `generateOne(JsonNode schema, JsonNode rootSchema, int depth)` called `count` times
- `generate(JsonNode schema, int count, Class<T> targetType, ObjectMapper mapper)` → calls the raw generate, then `mapper.treeToValue(node, targetType)` per result
- Private `generateOne` dispatches on `schema.get("type").asText()`:
  - `"string"` → check `const`, `enum`, `format` (date-time, uuid), then respect `minLength`/`maxLength` (default 8-20), generate random alphanumeric
  - `"integer"` → respect `minimum`/`maximum` (default 0-1000), `random.nextInt()`
  - `"number"` → respect `minimum`/`maximum` (default -1000.0/1000.0), `random.nextDouble()`
  - `"boolean"` → `random.nextBoolean()`
  - `"array"` → handled in Task 2
  - `"object"` → handled in Task 2
- Handle `const` keyword: return the constant value directly
- Handle `enum` keyword: random selection from the array

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl schema-generator -Dtest=SchemaDataGeneratorTest`
Expected: All tests PASS.

- [ ] **Step 6: Commit**

```bash
git add schema-generator/src/main/java/io/casehub/schema/generator/SchemaDataGenerator.java schema-generator/src/main/java/io/casehub/schema/generator/SchemaGenerationException.java schema-generator/src/test/java/io/casehub/schema/generator/SchemaDataGeneratorTest.java
git commit -m "feat(#330): add SchemaDataGenerator with primitive types and constraints

Refs #330"
```

---

## Batch 2: Object, array, and $ref support

### Task 2: Object and array generation with $ref resolution

**Files:**
- Modify: `schema-generator/src/main/java/io/casehub/schema/generator/SchemaDataGenerator.java`
- Test: `schema-generator/src/test/java/io/casehub/schema/generator/SchemaDataGeneratorTest.java`

**Interfaces:**
- Consumes: `generateOne(schema, rootSchema, depth)` from Task 1
- Produces: Complete `generateOne` with object, array, and $ref support

- [ ] **Step 1: Write failing tests for object and array generation**

Add to `SchemaDataGeneratorTest.java`:

```java
@Test
void generatesObjectWithRequiredProperties() {
    var s = mapper.createObjectNode();
    s.put("type", "object");
    var props = s.putObject("properties");
    props.putObject("name").put("type", "string");
    props.putObject("age").put("type", "integer");
    var required = s.putArray("required");
    required.add("name");
    required.add("age");

    var results = generator.generate(s, 3);
    assertThat(results).hasSize(3);
    results.forEach(r -> {
        assertThat(r.has("name")).isTrue();
        assertThat(r.get("name").isTextual()).isTrue();
        assertThat(r.has("age")).isTrue();
        assertThat(r.get("age").isIntegralNumber()).isTrue();
    });
}

@Test
void generatesArrayWithItemSchema() {
    var s = mapper.createObjectNode();
    s.put("type", "array");
    s.putObject("items").put("type", "string");
    s.put("minItems", 2);
    s.put("maxItems", 4);

    var results = generator.generate(s, 3);
    assertThat(results).hasSize(3);
    results.forEach(r -> {
        assertThat(r.isArray()).isTrue();
        assertThat(r.size()).isBetween(2, 4);
        r.forEach(item -> assertThat(item.isTextual()).isTrue());
    });
}

@Test
void resolvesRefToDefs() {
    var root = mapper.createObjectNode();
    root.put("type", "object");
    var props = root.putObject("properties");
    props.putObject("color").put("$ref", "#/$defs/Color");
    root.putArray("required").add("color");

    var defs = root.putObject("$defs");
    var colorDef = defs.putObject("Color");
    colorDef.put("type", "string");
    var colorEnum = colorDef.putArray("enum");
    colorEnum.add("RED");
    colorEnum.add("GREEN");
    colorEnum.add("BLUE");

    var results = generator.generate(root, 10);
    results.forEach(r -> {
        assertThat(r.has("color")).isTrue();
        assertThat(r.get("color").asText()).isIn("RED", "GREEN", "BLUE");
    });
}

@Test
void resolvesNestedRefs() {
    var root = mapper.createObjectNode();
    root.put("type", "object");
    var props = root.putObject("properties");
    props.putObject("address").put("$ref", "#/$defs/Address");
    root.putArray("required").add("address");

    var defs = root.putObject("$defs");
    var addressDef = defs.putObject("Address");
    addressDef.put("type", "object");
    var addrProps = addressDef.putObject("properties");
    addrProps.putObject("street").put("type", "string");
    addrProps.putObject("city").put("type", "string");
    addressDef.putArray("required").add("street").add("city");

    var results = generator.generate(root, 3);
    results.forEach(r -> {
        assertThat(r.get("address").has("street")).isTrue();
        assertThat(r.get("address").has("city")).isTrue();
    });
}

@Test
void depthGuardPreventsInfiniteRecursion() {
    var root = mapper.createObjectNode();
    root.put("type", "object");
    var props = root.putObject("properties");
    props.putObject("child").put("$ref", "#/$defs/Node");
    root.putArray("required").add("child");

    var defs = root.putObject("$defs");
    var nodeDef = defs.putObject("Node");
    nodeDef.put("type", "object");
    var nodeProps = nodeDef.putObject("properties");
    nodeProps.putObject("value").put("type", "string");
    nodeProps.putObject("child").put("$ref", "#/$defs/Node");
    nodeDef.putArray("required").add("value");

    var results = generator.generate(root, 1);
    assertThat(results).hasSize(1);
    assertThat(results.get(0).has("child")).isTrue();
}

record SimpleRecord(String name, int count, boolean active) {}

@Test
void typedGenerateDeserializesToTargetClass() {
    var schemaGen = new PlatformSchemaGenerator();
    var schema = schemaGen.generate(SimpleRecord.class);
    var results = generator.generate(schema, 5, SimpleRecord.class, mapper);
    assertThat(results).hasSize(5);
    results.forEach(r -> {
        assertThat(r.name()).isNotNull();
        assertThat(r).isInstanceOf(SimpleRecord.class);
    });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl schema-generator -Dtest=SchemaDataGeneratorTest`
Expected: Failures on object/array/$ref tests.

- [ ] **Step 3: Implement object, array, and $ref support**

Extend `generateOne` in `SchemaDataGenerator`:

- **$ref resolution:** Before type dispatch, check if the schema has a `$ref` field. If so, extract the path (e.g. `#/$defs/Color`), look up the referenced schema from the root schema's `$defs`, and recurse with the resolved schema. Increment depth counter; throw `SchemaGenerationException` at depth 20 for required fields, return null for optional.
- **Object generation:** Iterate `properties`. Generate all `required` fields. For optional fields, include with 50% probability. Recurse for each property's schema.
- **Array generation:** Read `minItems` (default 1), `maxItems` (default 3). Generate random count within bounds. Recurse on `items` schema for each element.

The `rootSchema` parameter threads through all recursive calls to provide the `$defs` context for $ref resolution.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl schema-generator -Dtest=SchemaDataGeneratorTest`
Expected: All tests PASS.

- [ ] **Step 5: Run full schema-generator test suite**

Run: `mvn --batch-mode test -pl schema-generator`
Expected: All tests PASS (existing + new).

- [ ] **Step 6: Commit**

```bash
git add schema-generator/src/main/java/io/casehub/schema/generator/SchemaDataGenerator.java schema-generator/src/test/java/io/casehub/schema/generator/SchemaDataGeneratorTest.java
git commit -m "feat(#330): add object, array, and \$ref support to SchemaDataGenerator

Refs #330"
```

---

## Batch 3: CorpusSeed integration and documentation

### Task 3: RandomCorpusPopulator + documentation

**Files:**
- Create: `simulation-testing/src/main/java/io/casehub/platform/simulation/testing/RandomCorpusPopulator.java`
- Test: `simulation-testing/src/test/java/io/casehub/platform/simulation/testing/RandomCorpusPopulatorTest.java`
- Modify: `docs/guides/simulation-guide.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `SchemaDataGenerator` from Tasks 1-2
- Consumes: `PlatformSchemaGenerator` from schema-generator
- Consumes: `CorpusSeed<I, O>` from simulation-api
- Produces: `RandomCorpusPopulator.populate(seed, inputType, outputType, count, mapper)` — static method

- [ ] **Step 1: Write failing test for RandomCorpusPopulator**

Create `RandomCorpusPopulatorTest.java`:

```java
package io.casehub.platform.simulation.testing;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.casehub.platform.simulation.CorpusSeed;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class RandomCorpusPopulatorTest {

    private final ObjectMapper mapper = new ObjectMapper();

    record Input(String query, int limit) {}
    record Output(String result, boolean found) {}

    @Test
    void populatesSeedWithRandomData() {
        var seed = CorpusSeed.<Input, Output>forMethod("test-spi.query");
        RandomCorpusPopulator.populate(seed, Input.class, Output.class, 10, mapper);

        var records = seed.build();
        assertThat(records).hasSize(10);
        records.forEach(r -> {
            assertThat(r.input()).isInstanceOf(Input.class);
            assertThat(r.output()).isInstanceOf(Output.class);
            assertThat(r.input().query()).isNotNull();
            assertThat(r.output().result()).isNotNull();
        });
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode install -pl schema-generator -DskipTests && mvn --batch-mode test -pl simulation-testing -Dtest=RandomCorpusPopulatorTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: Compilation failure — `RandomCorpusPopulator` does not exist.

- [ ] **Step 3: Create RandomCorpusPopulator**

Create `simulation-testing/src/main/java/io/casehub/platform/simulation/testing/RandomCorpusPopulator.java`:

```java
package io.casehub.platform.simulation.testing;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.casehub.platform.simulation.CorpusSeed;
import io.casehub.schema.generator.PlatformSchemaGenerator;
import io.casehub.schema.generator.SchemaDataGenerator;

public final class RandomCorpusPopulator {

    private RandomCorpusPopulator() {}

    public static <I, O> void populate(CorpusSeed<I, O> seed,
                                        Class<I> inputType,
                                        Class<O> outputType,
                                        int count,
                                        ObjectMapper mapper) {
        var schemaGen = new PlatformSchemaGenerator();
        var dataGen = new SchemaDataGenerator();
        var inputSchema = schemaGen.generate(inputType);
        var outputSchema = schemaGen.generate(outputType);
        var inputs = dataGen.generate(inputSchema, count, inputType, mapper);
        var outputs = dataGen.generate(outputSchema, count, outputType, mapper);
        for (int i = 0; i < count; i++) {
            seed.add(inputs.get(i), outputs.get(i));
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl simulation-testing -Dtest=RandomCorpusPopulatorTest`
Expected: PASS.

- [ ] **Step 5: Run full simulation-testing test suite**

Run: `mvn --batch-mode test -pl simulation-testing`
Expected: All tests PASS.

- [ ] **Step 6: Add schema-driven random generation section to simulation-guide.md**

Add a new subsection under "Corpus population" in `docs/guides/simulation-guide.md`:

**Schema-driven random generation** — explaining how to use `SchemaDataGenerator` directly and `RandomCorpusPopulator` for CorpusSeed integration. Include a DataRealism mapping table showing which generator produces which realism level.

- [ ] **Step 7: Update CLAUDE.md**

Update the `schema-generator` module description to mention `SchemaDataGenerator`. Update the `simulation-testing` module description to mention `RandomCorpusPopulator`.

- [ ] **Step 8: Commit**

```bash
git add simulation-testing/src/main/java/io/casehub/platform/simulation/testing/RandomCorpusPopulator.java simulation-testing/src/test/java/io/casehub/platform/simulation/testing/RandomCorpusPopulatorTest.java docs/guides/simulation-guide.md CLAUDE.md
git commit -m "feat(#330): add RandomCorpusPopulator and schema-driven generation docs

Refs #330"
```

---

## References

- [2026-09-18-domain-data-generation-design.md] — design spec this plan implements
- [PlatformSchemaGenerator.java] — schema generation, JakartaValidationModule, Draft 2020-12
- [PlatformSchemaGeneratorTest.java] — existing test patterns (record types, enum inlining)
- [LlmCorpusPopulator.java] — parallel pattern in simulation-testing
- [CorpusSeed.java] — accumulation API, forMethod() factory
- [DataRealism.java] — 5-level enum
- [SchemaPostProcessor.java] — $schema insertion
- [simulation-testing/pom.xml] — already depends on schema-generator
- [GitHub #330] — domain data generation
