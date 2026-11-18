# Eliminate Dual-Parse: Jackson-Native Position Tracking — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #879 — Eliminate dual-parse: capture source positions from Jackson YAML deserialization

**Goal:** Replace all direct SnakeYAML API usage with a Jackson Module that captures `JsonLocation` during deserialization, registering positions in `LocationIndex`. Both main playbook and module file paths use a single Jackson parse with position tracking.

**Architecture:** A `LocationTrackingModule` (Jackson `Module`) in `yaml-jackson` registers a `BeanDeserializerModifier` that wraps `MapDeserializer` and `CollectionDeserializer`. Each wrapper captures `parser.currentTokenLocation()` before delegating to the standard deserializer, then registers the returned object + location in a `LocationIndex` passed via `DeserializationContext` attributes. `PlaybookParser` and `FileSystemModuleLoader` are updated to use this module instead of SnakeYAML's compose API.

**Tech Stack:** Jackson 2.x (`jackson-databind`, `jackson-dataformat-yaml`), `BeanDeserializerModifier` API

## Global Constraints

- `yaml-jackson` depends on `yaml-core` + `jackson-databind` + `jackson-dataformat-yaml` only — no new dependencies
- `yaml-core` remains zero-dependency — no changes to `LocationIndex` API
- `LocationIndex.transferFrom()` stays — still used by `PlaybookModuleBridge.expandBranches()` for self-transfer
- Scalar resolution must match SnakeYAML exactly: yes/no/on/off as booleans, integer/long/double, quoted strings preserved
- Position line/column numbers must match existing tests (1-based, same values)

---

## Batch 1: LocationTrackingModule foundation (yaml-jackson)

### Task 1: LocationTrackingModule with map and collection position tracking

**Files:**
- Create: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/LocationTrackingModule.java`
- Create: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/LocationTrackingModifier.java`
- Create: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/LocationTrackingMapDeserializer.java`
- Create: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/LocationTrackingCollectionDeserializer.java`
- Create: `yaml-jackson/src/main/java/io/casehub/yaml/jackson/LocationTrackingHelper.java`
- Test: `yaml-jackson/src/test/java/io/casehub/yaml/jackson/LocationTrackingModuleTest.java`

**Interfaces:**
- Consumes: `io.casehub.yaml.core.error.LocationIndex` (put, locationOf), `io.casehub.yaml.core.error.SourceLocation`
- Produces: `LocationTrackingModule` — Jackson Module with static constants `LOCATION_INDEX_KEY` and `FILE_PATH_KEY`. Registered on an ObjectMapper, it causes all Map and List objects created during deserialization to be recorded in a `LocationIndex` passed via `DeserializationContext.setAttribute()`.

- [ ] **Step 1: Write failing test — map position tracking**

```java
// LocationTrackingModuleTest.java
package io.casehub.yaml.jackson;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.ObjectReader;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import io.casehub.yaml.core.error.LocationIndex;
import io.casehub.yaml.core.error.SourceLocation;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class LocationTrackingModuleTest {

    private final ObjectMapper mapper = new ObjectMapper(new YAMLFactory())
            .registerModule(new LocationTrackingModule());

    @Test
    void tracksRootMapPosition() throws Exception {
        String yaml = """
                      name: hello
                      count: 42
                      """;
        var index = new LocationIndex();
        ObjectReader reader = mapper.readerFor(Object.class)
                .withAttribute(LocationTrackingModule.LOCATION_INDEX_KEY, index)
                .withAttribute(LocationTrackingModule.FILE_PATH_KEY, "test.yaml");
        Object result = reader.readValue(yaml);

        assertThat(result).isInstanceOf(Map.class);
        SourceLocation loc = index.locationOf(result);
        assertThat(loc.file()).isEqualTo("test.yaml");
        assertThat(loc.line()).isEqualTo(1);
        assertThat(loc.column()).isEqualTo(1);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-jackson -Dtest=LocationTrackingModuleTest#tracksRootMapPosition -Dsurefire.failIfNoSpecifiedTests=false`
Expected: Compilation error — `LocationTrackingModule` does not exist

- [ ] **Step 3: Implement LocationTrackingModule, LocationTrackingModifier, LocationTrackingMapDeserializer**

```java
// LocationTrackingModule.java
package io.casehub.yaml.jackson;

import com.fasterxml.jackson.databind.module.SimpleModule;

public class LocationTrackingModule extends SimpleModule {

    public static final String LOCATION_INDEX_KEY = "io.casehub.yaml.locationIndex";
    public static final String FILE_PATH_KEY = "io.casehub.yaml.filePath";

    public LocationTrackingModule() {
        super("location-tracking");
    }

    @Override
    public void setupModule(SetupContext context) {
        super.setupModule(context);
        context.addBeanDeserializerModifier(new LocationTrackingModifier());
    }
}
```

```java
// LocationTrackingModifier.java
package io.casehub.yaml.jackson;

import com.fasterxml.jackson.databind.BeanDescription;
import com.fasterxml.jackson.databind.DeserializationConfig;
import com.fasterxml.jackson.databind.JsonDeserializer;
import com.fasterxml.jackson.databind.deser.BeanDeserializerModifier;
import com.fasterxml.jackson.databind.type.CollectionType;
import com.fasterxml.jackson.databind.type.MapType;

class LocationTrackingModifier extends BeanDeserializerModifier {

    @Override
    public JsonDeserializer<?> modifyMapDeserializer(DeserializationConfig config,
                                                     MapType type,
                                                     BeanDescription beanDesc,
                                                     JsonDeserializer<?> deserializer) {
        return new LocationTrackingMapDeserializer(deserializer);
    }

    @Override
    public JsonDeserializer<?> modifyCollectionDeserializer(DeserializationConfig config,
                                                            CollectionType type,
                                                            BeanDescription beanDesc,
                                                            JsonDeserializer<?> deserializer) {
        return new LocationTrackingCollectionDeserializer(deserializer);
    }
}
```

```java
// LocationTrackingMapDeserializer.java
package io.casehub.yaml.jackson;

import com.fasterxml.jackson.core.JsonLocation;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.DeserializationContext;
import com.fasterxml.jackson.databind.JsonDeserializer;
import com.fasterxml.jackson.databind.deser.std.DelegatingDeserializer;
import io.casehub.yaml.core.error.LocationIndex;
import io.casehub.yaml.core.error.SourceLocation;

class LocationTrackingMapDeserializer extends DelegatingDeserializer {

    LocationTrackingMapDeserializer(JsonDeserializer<?> delegate) {
        super(delegate);
    }

    @Override
    protected JsonDeserializer<?> newDelegatingInstance(JsonDeserializer<?> newDelegate) {
        return new LocationTrackingMapDeserializer(newDelegate);
    }

    @Override
    public Object deserialize(JsonParser p, DeserializationContext ctxt) throws java.io.IOException {
        JsonLocation loc = p.currentTokenLocation();
        Object result = super.deserialize(p, ctxt);
        LocationTrackingHelper.recordLocation(ctxt, result, loc);
        return result;
    }
}
```

Also create the shared helper:

```java
// LocationTrackingHelper.java
package io.casehub.yaml.jackson;

import com.fasterxml.jackson.core.JsonLocation;
import com.fasterxml.jackson.databind.DeserializationContext;
import io.casehub.yaml.core.error.LocationIndex;
import io.casehub.yaml.core.error.SourceLocation;

final class LocationTrackingHelper {

    private LocationTrackingHelper() {}

    static void recordLocation(DeserializationContext ctxt, Object target, JsonLocation loc) {
        Object indexObj = ctxt.getAttribute(LocationTrackingModule.LOCATION_INDEX_KEY);
        if (!(indexObj instanceof LocationIndex index)) {
            return;
        }
        String filePath = (String) ctxt.getAttribute(LocationTrackingModule.FILE_PATH_KEY);
        index.put(target, new SourceLocation(filePath, loc.getLineNr(), loc.getColumnNr()));
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl yaml-jackson -Dtest=LocationTrackingModuleTest#tracksRootMapPosition -Dsurefire.failIfNoSpecifiedTests=false`
Expected: PASS

- [ ] **Step 5: Write additional tests — nested maps, no-op without attributes**

Add to `LocationTrackingModuleTest`:

```java
@Test
void tracksNestedMapPositions() throws Exception {
    String yaml = """
                  outer:
                    inner:
                      key: value
                  """;
    var index = new LocationIndex();
    ObjectReader reader = mapper.readerFor(Object.class)
            .withAttribute(LocationTrackingModule.LOCATION_INDEX_KEY, index)
            .withAttribute(LocationTrackingModule.FILE_PATH_KEY, "nested.yaml");
    @SuppressWarnings("unchecked")
    var result = (Map<String, Object>) reader.readValue(yaml);

    assertThat(index.locationOf(result).line()).isEqualTo(1);
    @SuppressWarnings("unchecked")
    var outer = (Map<String, Object>) result.get("outer");
    assertThat(index.locationOf(outer).line()).isEqualTo(2);
    @SuppressWarnings("unchecked")
    var inner = (Map<String, Object>) outer.get("inner");
    assertThat(index.locationOf(inner).line()).isEqualTo(3);
}

@Test
void noOpWhenAttributesAbsent() throws Exception {
    String yaml = """
                  name: hello
                  """;
    // No withAttribute calls — should not throw
    Object result = mapper.readValue(yaml, Object.class);
    assertThat(result).isInstanceOf(Map.class);
}
```

- [ ] **Step 6: Run all tests to verify**

Run: `mvn --batch-mode test -pl yaml-jackson -Dtest=LocationTrackingModuleTest`
Expected: All PASS

- [ ] **Step 7: Write test — list position tracking**

Add to `LocationTrackingModuleTest`:

```java
@Test
void tracksListPositions() throws Exception {
    String yaml = """
                  steps:
                    - log: hello
                    - process:
                        command: run.sh
                  """;
    var index = new LocationIndex();
    ObjectReader reader = mapper.readerFor(Object.class)
            .withAttribute(LocationTrackingModule.LOCATION_INDEX_KEY, index)
            .withAttribute(LocationTrackingModule.FILE_PATH_KEY, "list.yaml");
    @SuppressWarnings("unchecked")
    var result = (Map<String, Object>) reader.readValue(yaml);

    @SuppressWarnings("unchecked")
    var steps = (java.util.List<Map<String, Object>>) result.get("steps");
    SourceLocation listLoc = index.locationOf(steps);
    assertThat(listLoc.file()).isEqualTo("list.yaml");
    assertThat(listLoc.line()).isEqualTo(2);

    // Each step map also tracked
    assertThat(index.locationOf(steps.get(0)).line()).isEqualTo(2);
    assertThat(index.locationOf(steps.get(1)).line()).isEqualTo(3);
}
```

- [ ] **Step 8: Run all tests to verify**

Run: `mvn --batch-mode test -pl yaml-jackson -Dtest=LocationTrackingModuleTest`
Expected: All PASS

- [ ] **Step 9: Write test — typed deserialization captures positions**

Add to `LocationTrackingModuleTest`:

```java
@Test
void tracksPositionsInTypedDeserialization() throws Exception {
    var typedMapper = new ObjectMapper(new YAMLFactory())
            .registerModule(new LocationTrackingModule())
            .registerModule(new YamlCoreJacksonModule())
            .enable(com.fasterxml.jackson.databind.MapperFeature.ACCEPT_CASE_INSENSITIVE_ENUMS);
    String yaml = """
                  module:
                    name: test-mod
                  steps:
                    do-work:
                      - log: hello
                  """;
    var index = new LocationIndex();
    ObjectReader reader = typedMapper.readerFor(io.casehub.yaml.core.module.YamlModuleFile.class)
            .withAttribute(LocationTrackingModule.LOCATION_INDEX_KEY, index)
            .withAttribute(LocationTrackingModule.FILE_PATH_KEY, "module.yaml");
    var moduleFile = (io.casehub.yaml.core.module.YamlModuleFile) reader.readValue(yaml);

    // Sections map should have tracked positions
    assertThat(moduleFile.sections()).containsKey("steps");
    var stepsSection = moduleFile.sections().get("steps");
    assertThat(index.locationOf(stepsSection).line()).isGreaterThan(0);
}
```

- [ ] **Step 10: Run test to verify it passes**

Run: `mvn --batch-mode test -pl yaml-jackson -Dtest=LocationTrackingModuleTest#tracksPositionsInTypedDeserialization -Dsurefire.failIfNoSpecifiedTests=false`
Expected: PASS

- [ ] **Step 11: Commit**

```bash
git add yaml-jackson/src/main/java/io/casehub/yaml/jackson/LocationTrackingModule.java \
        yaml-jackson/src/main/java/io/casehub/yaml/jackson/LocationTrackingModifier.java \
        yaml-jackson/src/main/java/io/casehub/yaml/jackson/LocationTrackingMapDeserializer.java \
        yaml-jackson/src/main/java/io/casehub/yaml/jackson/LocationTrackingCollectionDeserializer.java \
        yaml-jackson/src/main/java/io/casehub/yaml/jackson/LocationTrackingHelper.java \
        yaml-jackson/src/test/java/io/casehub/yaml/jackson/LocationTrackingModuleTest.java
git commit -m "feat(#879): add LocationTrackingModule with map and collection position tracking"
```

## Batch 2: Migrate PlaybookParser and FileSystemModuleLoader

### Task 2: Migrate PlaybookParser to Jackson

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/statemachine/PlaybookParser.java`
- Modify: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/statemachine/PlaybookParserTest.java`

**Interfaces:**
- Consumes: `LocationTrackingModule`, `LocationTrackingModule.LOCATION_INDEX_KEY`, `LocationTrackingModule.FILE_PATH_KEY`
- Produces: Same `ParseResult` and `RawParseResult` records with identical behavior — all existing callers remain unchanged

- [ ] **Step 1: Write compatibility test — YAML 1.1 boolean scalars (yes/no/on/off)**

Add to `PlaybookParserTest.LocationTracking`:

```java
@Test
void resolvesYaml11BooleanScalars() {
    String yaml = """
                  a: yes
                  b: no
                  c: on
                  d: off
                  e: "yes"
                  """;
    var result = PlaybookParser.parseWithLocations(yaml, null);
    var content = result.document().content();
    assertThat(content.get("a")).isEqualTo(true);
    assertThat(content.get("b")).isEqualTo(false);
    assertThat(content.get("c")).isEqualTo(true);
    assertThat(content.get("d")).isEqualTo(false);
    assertThat(content.get("e")).isEqualTo("yes");
}

@Test
void resolvesNullVariants() {
    String yaml = """
                  a: null
                  b: ~
                  c:
                  """;
    var result = PlaybookParser.parseWithLocations(yaml, null);
    var content = result.document().content();
    assertThat(content.get("a")).isNull();
    assertThat(content.get("b")).isNull();
    assertThat(content.get("c")).isNull();
}
```

- [ ] **Step 2: Run tests to verify they pass with current SnakeYAML implementation**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest="PlaybookParserTest\$LocationTracking#resolvesYaml11BooleanScalars+resolvesNullVariants" -Dsurefire.failIfNoSpecifiedTests=false`
Expected: PASS — these characterize existing behavior

- [ ] **Step 3: Replace PlaybookParser internals with Jackson**

Replace `parseWithLocations` and `parseRawWithLocations`. Remove `convertNode` and `resolveScalar`. Add a static `ObjectMapper` field.

The new `PlaybookParser` retains all public methods with identical signatures. The internal implementation changes from SnakeYAML to Jackson:

```java
// New fields (top of class, after constants)
private static final ObjectMapper MAPPER = new ObjectMapper(
        new com.fasterxml.jackson.dataformat.yaml.YAMLFactory())
        .registerModule(new io.casehub.yaml.jackson.LocationTrackingModule())
        .enable(com.fasterxml.jackson.databind.MapperFeature.ACCEPT_CASE_INSENSITIVE_ENUMS);

// Replace parseRawWithLocations
public static RawParseResult parseRawWithLocations(String yaml, String filePath) {
    if (yaml == null || yaml.isBlank()) {
        return new RawParseResult(null, new LocationIndex());
    }
    var index = new LocationIndex();
    try {
        com.fasterxml.jackson.databind.ObjectReader reader = MAPPER.readerFor(Object.class)
                .withAttribute(io.casehub.yaml.jackson.LocationTrackingModule.LOCATION_INDEX_KEY, index)
                .withAttribute(io.casehub.yaml.jackson.LocationTrackingModule.FILE_PATH_KEY, filePath);
        Object root = reader.readValue(yaml);
        return new RawParseResult(root, index);
    } catch (java.io.IOException e) {
        throw new IllegalArgumentException("Failed to parse YAML", e);
    }
}

// Replace parseWithLocations
@SuppressWarnings("unchecked")
public static ParseResult parseWithLocations(String yaml, String filePath) {
    if (yaml == null || yaml.isBlank()) {
        throw new IllegalArgumentException("YAML content must not be empty");
    }
    var index = new LocationIndex();
    try {
        com.fasterxml.jackson.databind.ObjectReader reader = MAPPER.readerFor(Object.class)
                .withAttribute(io.casehub.yaml.jackson.LocationTrackingModule.LOCATION_INDEX_KEY, index)
                .withAttribute(io.casehub.yaml.jackson.LocationTrackingModule.FILE_PATH_KEY, filePath);
        var documents = new java.util.ArrayList<Object>();
        com.fasterxml.jackson.databind.MappingIterator<Object> iter = reader.readValues(yaml);
        while (iter.hasNext()) {
            documents.add(iter.next());
        }
        if (documents.isEmpty() || documents.get(0) == null) {
            throw new IllegalArgumentException("YAML content must not be empty");
        }
        PlaybookDocument doc = assembleDocument(documents);
        return new ParseResult(doc, index);
    } catch (java.io.IOException e) {
        throw new IllegalArgumentException("Failed to parse YAML", e);
    }
}

// Remove: convertNode, resolveScalar — no longer needed
```

Remove all `org.yaml.snakeyaml.*` FQN references.

- [ ] **Step 4: Run ALL existing PlaybookParser tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=PlaybookParserTest`
Expected: All PASS — same behavior, different internal implementation

- [ ] **Step 5: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/statemachine/PlaybookParser.java \
        yaml-step-runtime/src/test/java/io/casehub/yaml/step/statemachine/PlaybookParserTest.java
git commit -m "feat(#879): migrate PlaybookParser from SnakeYAML to Jackson LocationTrackingModule"
```

### Task 3: Simplify FileSystemModuleLoader — eliminate dual-parse

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/FileSystemModuleLoader.java`

**Interfaces:**
- Consumes: `LocationTrackingModule`, `LocationTrackingModule.LOCATION_INDEX_KEY`, `LocationTrackingModule.FILE_PATH_KEY`
- Produces: Same `YamlModuleFile` with positions in `LocationIndex` — single-pass, no `transferFrom`

- [ ] **Step 1: Write a test that verifies module file positions via FileSystemModuleLoader**

Check if existing tests in `FileSystemModuleLoaderTest` cover position tracking. If not, add one:

```java
// In the appropriate test class for FileSystemModuleLoader
@Test
void loadModulesTracksPositionsInLocationIndex() throws Exception {
    // Create a temporary module file
    Path moduleDir = tempDir.resolve("modules");
    Files.createDirectories(moduleDir);
    Files.writeString(moduleDir.resolve("test-mod.yaml"), """
            module:
              name: test-mod
            steps:
              do-work:
                - log: hello
            """);
    Path playbookPath = tempDir.resolve("playbook.yaml");
    Files.writeString(playbookPath, "steps: []");

    var locations = new LocationIndex();
    var imports = List.of(new YamlImport("test-mod", null, null, null, null, null));
    var loader = new FileSystemModuleLoader();
    var modules = loader.loadModules(imports, playbookPath, locations);

    assertThat(modules).containsKey("test-mod");
    var stepsSection = modules.get("test-mod").sections().get("steps");
    assertThat(locations.locationOf(stepsSection).line()).isGreaterThan(0);
}
```

- [ ] **Step 2: Run existing tests first to confirm baseline**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest="*ModuleLoader*"`
Expected: PASS

- [ ] **Step 3: Modify FileSystemModuleLoader to register LocationTrackingModule and simplify parseModuleContent**

In the constructor, add `LocationTrackingModule`:

```java
public FileSystemModuleLoader() {
    this.mapper = new ObjectMapper(new YAMLFactory())
            .enable(MapperFeature.ACCEPT_CASE_INSENSITIVE_ENUMS)
            .registerModule(new YamlCoreJacksonModule())
            .registerModule(new io.casehub.yaml.jackson.LocationTrackingModule());
}
```

Replace `parseModuleContent`:

```java
private YamlModuleFile parseModuleContent(String yaml, String filePath,
                                          LocationIndex locations) throws IOException {
    com.fasterxml.jackson.databind.ObjectReader reader = mapper.readerFor(YamlModuleFile.class);
    if (locations != null) {
        reader = reader
                .withAttribute(io.casehub.yaml.jackson.LocationTrackingModule.LOCATION_INDEX_KEY, locations)
                .withAttribute(io.casehub.yaml.jackson.LocationTrackingModule.FILE_PATH_KEY, filePath);
    }
    return reader.readValue(yaml);
}
```

Remove the import of `PlaybookParser` (no longer needed).

- [ ] **Step 4: Run all yaml-step-runtime tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/FileSystemModuleLoader.java
git commit -m "feat(#879): simplify FileSystemModuleLoader — single-pass position tracking"
```

## Batch 3: Verification and cleanup

### Task 4: Full build verification and SnakeYAML usage audit

**Files:**
- No new files — verification task

**Interfaces:**
- Consumes: All prior tasks
- Produces: Verified clean build with zero direct SnakeYAML usage in yaml-step-runtime main sources

- [ ] **Step 1: Verify no SnakeYAML references remain in yaml-step-runtime main sources**

Use `ide_search_text` to search for `org.yaml.snakeyaml` in `yaml-step-runtime/src/main/**/*.java`. Expected: 0 results.

- [ ] **Step 2: Run full module build**

Run: `mvn --batch-mode install -pl yaml-jackson,yaml-step-runtime -am`
Expected: BUILD SUCCESS

- [ ] **Step 3: Run the full project test suite for affected modules**

Run: `mvn --batch-mode test -pl yaml-jackson,yaml-step-runtime`
Expected: All tests PASS

- [ ] **Step 4: Verify PlaybookRunnerCore validation still works end-to-end**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest="PlaybookRunnerCoreTest"`
Expected: PASS — this exercises the full parse → expand → validate pipeline

- [ ] **Step 5: Commit any test adjustments, if needed**

If any tests needed updates (unlikely — public API unchanged), commit them:

```bash
git add -u
git commit -m "test(#879): adjust tests for Jackson-native position tracking"
```

## References

- [2026-11-18-eliminate-snakeyaml-dual-parse-design.md] — design spec this plan implements
- `yaml-step-runtime/.../PlaybookParser.java` — SnakeYAML usage site (9 FQN references, all in convertNode/resolveScalar/parseWithLocations/parseRawWithLocations)
- `yaml-step-runtime/.../FileSystemModuleLoader.java:102-119` — dual-parse site
- `yaml-step-runtime/.../PlaybookModuleBridge.java:127` — transferFrom self-transfer (not changing)
- `yaml-core/.../LocationIndex.java` — IdentityHashMap position tracking (not changing)
- `yaml-jackson/.../YamlCoreJacksonModule.java` — existing Jackson module pattern
- Jackson `BeanDeserializerModifier` API — deserializer wrapping contract
- Jackson `DelegatingDeserializer` — delegation pattern for wrapping deserializers
- GitHub #879 — focal issue
