# Plugin Generation from @PlatformQuery/@PlatformMutation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #795 — Generate @Plugin playbook step types from @PlatformQuery/@PlatformMutation methods
**Issue group:** #795

**Goal:** Extend `GraphQLResolverProcessor` to generate `@Plugin` playbook step types as a fourth APT output, with a `Records.toMap()` runtime utility and `@GeneratePlugin` annotation for explicit control.

**Architecture:** The APT scans `@McpDomain` types (both interfaces and classes) and generates `@Plugin` record source files. `StepPluginProcessor` then processes those records in a subsequent APT round to emit JSON Schema, Action classes, and registry manifests. A new `Records.toMap()` utility in `yaml-step-runtime` handles record-to-map conversion at runtime.

**Tech Stack:** Java APT (javax.annotation.processing), Jandex (type introspection), PrintWriter (code generation), java.lang.reflect.RecordComponent (runtime flatten)

## Global Constraints

- `mcp-api/` depends only on `platform-api` — no Quarkus, no CDI imports
- `yaml-plugin-api/` must remain zero-dependency and J2CL-safe — `Records.toMap()` goes in `yaml-step-runtime`, NOT `yaml-plugin-api`
- `graphql-generator/` does not depend on `yaml-plugin-api` — annotation references use `DotName.createSimple("io.casehub.yaml.plugin.api.Plugin")`
- `generatePlugins` defaults to `false` — no impact on existing builds until explicitly enabled
- Generated plugin records must compile in the same APT round as `StepPluginProcessor` — requires multi-round awareness fix

---

## Batch 1: Foundation — @GeneratePlugin annotation + Records.toMap()

### Task 1: Create @GeneratePlugin annotation

**Files:**
- Create: `mcp-api/src/main/java/io/casehub/platform/api/mcp/GeneratePlugin.java`
- Test: `mcp-api/src/test/java/io/casehub/platform/api/mcp/GeneratePluginTest.java`

**Interfaces:**
- Consumes: nothing
- Produces: `@GeneratePlugin` annotation with attributes: `name()`, `description()`, `absorb()`, `subject()`, `capability()`, `spi()`, `accessor()`, `spiMethod()`, `optionalParams()`, `exclude()`

- [ ] **Step 1: Write the failing test**

```java
package io.casehub.platform.api.mcp;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class GeneratePluginTest {

    @GeneratePlugin(name = "test-plugin", absorb = true, subject = "input",
                    capability = Runnable.class, optionalParams = {"a", "b"})
    void annotatedMethod() {}

    @Test
    void annotation_retains_values_at_runtime() throws NoSuchMethodException {
        var method = getClass().getDeclaredMethod("annotatedMethod");
        var ann = method.getAnnotation(GeneratePlugin.class);
        assertThat(ann).isNotNull();
        assertThat(ann.name()).isEqualTo("test-plugin");
        assertThat(ann.absorb()).isTrue();
        assertThat(ann.subject()).isEqualTo("input");
        assertThat(ann.capability()).isEqualTo(Runnable.class);
        assertThat(ann.optionalParams()).containsExactly("a", "b");
        assertThat(ann.exclude()).isFalse();
        assertThat(ann.spi()).isEqualTo(void.class);
        assertThat(ann.accessor()).isEmpty();
        assertThat(ann.spiMethod()).isEmpty();
        assertThat(ann.description()).isEmpty();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl mcp-api -Dtest=GeneratePluginTest`
Expected: FAIL with compilation error — `GeneratePlugin` not found

- [ ] **Step 3: Write the annotation**

Create `mcp-api/src/main/java/io/casehub/platform/api/mcp/GeneratePlugin.java`:

```java
package io.casehub.platform.api.mcp;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface GeneratePlugin {
    String name() default "";
    String description() default "";
    boolean absorb() default false;
    String subject() default "";
    Class<?> capability() default void.class;
    Class<?> spi() default void.class;
    String accessor() default "";
    String spiMethod() default "";
    String[] optionalParams() default {};
    boolean exclude() default false;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl mcp-api -Dtest=GeneratePluginTest`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mcp-api/src/main/java/io/casehub/platform/api/mcp/GeneratePlugin.java mcp-api/src/test/java/io/casehub/platform/api/mcp/GeneratePluginTest.java
git commit -m "feat: add @GeneratePlugin annotation for plugin generation metadata Refs #795"
```

---

### Task 2: Create Records.toMap() utility

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/util/Records.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/util/RecordsTest.java`

**Interfaces:**
- Consumes: nothing
- Produces: `Records.toMap(Object record)` → `Map<String, Object>` — recursive record flattening

- [ ] **Step 1: Write the failing tests**

```java
package io.casehub.yaml.step.util;

import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class RecordsTest {

    record Simple(String name, int value) {}
    record Nested(String label, Simple inner) {}
    record WithList(String id, List<Simple> items) {}
    record WithOptional(String id, Optional<String> note) {}
    record WithMap(String id, Map<String, Object> data) {}
    record WithNullComponent(String required, String nullable) {}
    record WithSimpleList(String id, List<String> tags) {}

    @Test
    void simple_record() {
        var result = Records.toMap(new Simple("hello", 42));
        assertThat(result).containsEntry("name", "hello").containsEntry("value", 42);
    }

    @Test
    void nested_record_flattens_recursively() {
        var result = Records.toMap(new Nested("outer", new Simple("inner", 7)));
        assertThat(result).containsKey("inner");
        assertThat(result.get("inner")).isInstanceOf(Map.class);
        @SuppressWarnings("unchecked")
        var inner = (Map<String, Object>) result.get("inner");
        assertThat(inner).containsEntry("name", "inner").containsEntry("value", 7);
    }

    @Test
    void list_of_records_flattened() {
        var result = Records.toMap(new WithList("x", List.of(new Simple("a", 1), new Simple("b", 2))));
        assertThat(result.get("items")).isInstanceOf(List.class);
        @SuppressWarnings("unchecked")
        var items = (List<Map<String, Object>>) result.get("items");
        assertThat(items).hasSize(2);
        assertThat(items.get(0)).containsEntry("name", "a");
    }

    @Test
    void list_of_simple_types_passed_through() {
        var result = Records.toMap(new WithSimpleList("x", List.of("tag1", "tag2")));
        assertThat(result.get("tags")).isEqualTo(List.of("tag1", "tag2"));
    }

    @Test
    void optional_present_unwrapped() {
        var result = Records.toMap(new WithOptional("x", Optional.of("note-text")));
        assertThat(result).containsEntry("note", "note-text");
    }

    @Test
    void optional_empty_becomes_null() {
        var result = Records.toMap(new WithOptional("x", Optional.empty()));
        assertThat(result).containsKey("note");
        assertThat(result.get("note")).isNull();
    }

    @Test
    void map_component_passed_through() {
        var data = Map.<String, Object>of("key", "value");
        var result = Records.toMap(new WithMap("x", data));
        assertThat(result.get("data")).isEqualTo(data);
    }

    @Test
    void null_component_value_preserved() {
        var result = Records.toMap(new WithNullComponent("req", null));
        assertThat(result).containsEntry("required", "req");
        assertThat(result).containsKey("nullable");
        assertThat(result.get("nullable")).isNull();
    }

    @Test
    void null_input_throws() {
        assertThatThrownBy(() -> Records.toMap(null))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void non_record_input_throws() {
        assertThatThrownBy(() -> Records.toMap("not a record"))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=RecordsTest`
Expected: FAIL — `Records` class not found

- [ ] **Step 3: Write the implementation**

Create `yaml-step-runtime/src/main/java/io/casehub/yaml/step/util/Records.java`:

```java
package io.casehub.yaml.step.util;

import java.lang.reflect.RecordComponent;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

public final class Records {

    private Records() {}

    public static Map<String, Object> toMap(Object record) {
        if (record == null) {
            throw new IllegalArgumentException("record must not be null");
        }
        if (!record.getClass().isRecord()) {
            throw new IllegalArgumentException(
                    record.getClass().getName() + " is not a record");
        }
        var result = new LinkedHashMap<String, Object>();
        for (RecordComponent component : record.getClass().getRecordComponents()) {
            try {
                Object value = component.getAccessor().invoke(record);
                result.put(component.getName(), convert(value));
            } catch (ReflectiveOperationException e) {
                throw new RuntimeException("Failed to read record component: "
                        + component.getName(), e);
            }
        }
        return result;
    }

    private static Object convert(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Optional<?> opt) {
            return opt.orElse(null);
        }
        if (value.getClass().isRecord()) {
            return toMap(value);
        }
        if (value instanceof List<?> list && !list.isEmpty()
                && list.getFirst().getClass().isRecord()) {
            return list.stream().map(Records::toMap).toList();
        }
        return value;
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=RecordsTest`
Expected: PASS (all 10 tests)

- [ ] **Step 5: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/util/Records.java yaml-step-runtime/src/test/java/io/casehub/yaml/step/util/RecordsTest.java
git commit -m "feat: add Records.toMap() utility for record-to-map flattening Refs #795"
```

---

### Task 3: Make StepPluginProcessor multi-round-aware

**Files:**
- Modify: `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/StepPluginProcessor.java:26-37`
- Test: `yaml-plugin-processor/src/test/java/io/casehub/yaml/plugin/processor/StepPluginProcessorMultiRoundTest.java`

**Interfaces:**
- Consumes: existing `StepPluginProcessor` with `processed` boolean guard
- Produces: multi-round-aware processor that processes newly-appearing `@Plugin` types per round

- [ ] **Step 1: Write the failing test**

Create `yaml-plugin-processor/src/test/java/io/casehub/yaml/plugin/processor/StepPluginProcessorMultiRoundTest.java`:

```java
package io.casehub.yaml.plugin.processor;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class StepPluginProcessorMultiRoundTest {

    @Test
    void processor_does_not_have_processed_boolean_guard() throws Exception {
        var processor = new StepPluginProcessor();
        var fields = processor.getClass().getDeclaredFields();
        for (var field : fields) {
            assertThat(field.getName())
                    .as("StepPluginProcessor should not have a 'processed' boolean — "
                        + "use a Set<String> of processed type names for multi-round support")
                    .isNotEqualTo("processed");
        }
    }

    @Test
    void processor_tracks_processed_types_in_set() throws Exception {
        var processor = new StepPluginProcessor();
        var field = processor.getClass().getDeclaredField("processedTypes");
        assertThat(field).isNotNull();
        assertThat(java.util.Set.class).isAssignableFrom(field.getType());
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-plugin-processor -Dtest=StepPluginProcessorMultiRoundTest`
Expected: FAIL — `processed` field still exists

- [ ] **Step 3: Modify StepPluginProcessor**

In `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/StepPluginProcessor.java`, replace:

```java
private boolean processed;
```

with:

```java
private final java.util.Set<String> processedTypes = new java.util.HashSet<>();
```

And in the `process()` method, replace:

```java
if (processed || roundEnv.processingOver()) return false;
processed = true;

for (Element element : roundEnv.getElementsAnnotatedWith(Plugin.class)) {
```

with:

```java
if (roundEnv.processingOver()) return false;

for (Element element : roundEnv.getElementsAnnotatedWith(Plugin.class)) {
    String qname = ((TypeElement) element).getQualifiedName().toString();
    if (processedTypes.contains(qname)) continue;
    processedTypes.add(qname);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl yaml-plugin-processor -Dtest=StepPluginProcessorMultiRoundTest`
Expected: PASS

- [ ] **Step 5: Run full yaml-plugin-processor tests**

Run: `mvn --batch-mode test -pl yaml-plugin-processor`
Expected: All existing tests PASS (no regression)

- [ ] **Step 6: Commit**

```bash
git add yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/StepPluginProcessor.java yaml-plugin-processor/src/test/java/io/casehub/yaml/plugin/processor/StepPluginProcessorMultiRoundTest.java
git commit -m "fix: make StepPluginProcessor multi-round-aware for APT chain support Refs #795"
```

---

## Batch 2: Generator — Plugin source generation in GraphQLResolverProcessor

### Task 4: Add generatePlugins option and Tier 1 plugin generation (interface delegation)

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java:40-43` (getSupportedOptions), `84-154` (process loop)
- Test: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/PluginGenerationTest.java`

**Interfaces:**
- Consumes: `DomainOperations`, `ResolvedOperation`, `ResolvedParam` from existing processor internals
- Produces: `generatePluginSource(String domain, DomainOperations ops, Set<String> pluginSkipNames)` — emits `@Plugin` record `.java` files for Tier 1 (interface) domains

- [ ] **Step 1: Write the failing test**

Create `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/PluginGenerationTest.java`:

```java
package io.casehub.platform.graphql.generator;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class PluginGenerationTest {

    @Test
    void generatePlugins_is_supported_option() {
        var processor = new GraphQLResolverProcessor();
        assertThat(processor.getSupportedOptions()).contains("generatePlugins", "pluginPackage");
    }

    @Test
    void plugin_name_derivation_interface_domain() {
        assertThat(derivePluginName("acl", "canAccess")).isEqualTo("acl-can-access");
    }

    @Test
    void plugin_name_derivation_connector_domain() {
        assertThat(derivePluginName("connectors/bank", "listTransactions"))
                .isEqualTo("bank-list-transactions");
    }

    @Test
    void plugin_name_derivation_single_word_method() {
        assertThat(derivePluginName("connectors/bank", "balance"))
                .isEqualTo("bank-balance");
    }

    private static String derivePluginName(String domain, String methodName) {
        String domainSuffix = domain.contains("/")
                ? domain.substring(domain.lastIndexOf('/') + 1)
                : domain;
        return domainSuffix + "-" + GraphQLResolverProcessor.toKebabCase(methodName);
    }
}
```

- [ ] **Step 2: Run test to verify current state**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=PluginGenerationTest`
Expected: First test FAILS (generatePlugins not in supported options), name derivation tests PASS

- [ ] **Step 3: Add generatePlugins/pluginPackage to getSupportedOptions()**

In `GraphQLResolverProcessor.java`, update `getSupportedOptions()` to include `"generatePlugins"` and `"pluginPackage"`.

- [ ] **Step 4: Add generatePluginSource() method and wire into process loop**

Add the `generatePluginSource()` method to `GraphQLResolverProcessor`. This is the core of the feature. The method:

1. Resolves the `@Execute` parameter type (interface → the interface itself)
2. Maps method parameters to record fields with `@Required`/`@Optional`
3. Generates the result conversion code based on return type
4. Emits the `@Plugin` record `.java` source file

Add the `generatePlugins` boolean check and call in the process loop (after the existing `generateRest` block):

```java
boolean generatePlugins = "true".equals(processingEnv.getOptions().get("generatePlugins"));
// ...
if (generatePlugins) generatePluginSource(entry.getKey(), entry.getValue(), pluginSkipNames);
```

Add skip detection: `scanHandWrittenPluginNames(IndexView index, RoundEnvironment roundEnv)` — returns `Set<String>` of existing `@Plugin` value() names.

The `generatePluginSource()` method handles Tier 1 (interface domains):
- Determines if the domain source is an interface (Tier 1) or class (Tier 2)
- For Tier 1: generates a record with the interface as `@Execute` parameter
- Applies parameter mapping rules from the spec
- Generates result conversion based on return type table
- Reads `@GeneratePlugin` attributes when present

- [ ] **Step 5: Run tests**

Run: `mvn --batch-mode test -pl graphql-generator`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java graphql-generator/src/test/java/io/casehub/platform/graphql/generator/PluginGenerationTest.java
git commit -m "feat: add Tier 1 plugin generation for @McpDomain interfaces Refs #795"
```

---

### Task 5: Add Tier 2 plugin generation (connector SPI routing)

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java` (extend `generatePluginSource()`)
- Test: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/PluginGenerationTier2Test.java`

**Interfaces:**
- Consumes: `generatePluginSource()` from Task 4, `@GeneratePlugin` from Task 1
- Produces: Tier 2 plugin generation: SPI type inference from `@Inject` fields, capability call chain resolution, routing parameter exclusion

- [ ] **Step 1: Write the failing tests**

Create `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/PluginGenerationTier2Test.java` with test cases for:

- SPI type inference: mock `@McpDomain` class with `@Inject` field whose type has `platform(String)` method → verify generated plugin takes the SPI type as `@Execute` param
- Capability routing: `@GeneratePlugin(capability = X.class)` → verify generated call chain includes capability accessor
- Routing parameter exclusion: `platform` param excluded from record fields
- Explicit SPI override: `@GeneratePlugin(spi = X.class)` takes precedence
- Multiple qualifying `@Inject` fields → compile error
- Accessor method not found on SPI → compile error
- `@GeneratePlugin(exclude = true)` → no plugin generated

Use compile-testing infrastructure similar to the existing `GraphQLResolverProcessorTest` pattern — create test source files in `src/test/resources/` and assert generated output.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=PluginGenerationTier2Test`
Expected: FAIL — Tier 2 logic not implemented

- [ ] **Step 3: Implement Tier 2 logic in generatePluginSource()**

Extend `generatePluginSource()` to handle `@McpDomain` on classes:

1. **SPI type inference:** Find `@Inject` fields, check for `platform(String)` method via Jandex, get return type. Handle `@GeneratePlugin(spi = ...)` override. Emit error on multiple matches.

2. **Capability call chain:** When `@GeneratePlugin(capability = X.class)` is present:
   - Decapitalize class name for accessor (`AccountInformation` → `accountInformation`)
   - Check `@GeneratePlugin(accessor = ...)` override
   - Verify accessor exists on SPI type via Jandex
   - Introspect accessor params → add `@Optional` fields
   - Find method on capability interface (use `spiMethod` override or API method name)

3. **Routing parameter exclusion:** Identify the routing parameter by matching against the `platform(String)` method argument name.

4. **Result and parameter mapping:** Same as Tier 1 but with the additional routing/capability fields.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=PluginGenerationTier2Test`
Expected: PASS

- [ ] **Step 5: Run full graphql-generator tests**

Run: `mvn --batch-mode test -pl graphql-generator`
Expected: All tests PASS (no regression)

- [ ] **Step 6: Commit**

```bash
git add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java graphql-generator/src/test/java/io/casehub/platform/graphql/generator/PluginGenerationTier2Test.java
git commit -m "feat: add Tier 2 plugin generation with SPI routing and capability call chains Refs #795"
```

---

## Batch 3: Integration — Full build verification

### Task 6: Full build verification and CLAUDE.md update

**Files:**
- Test: full `mvn --batch-mode install` across the platform repo
- Modify: `CLAUDE.md` — update module table entry for `graphql-generator`, add `@GeneratePlugin` to mcp-api package structure

**Interfaces:**
- Consumes: all prior tasks
- Produces: verified full build, updated docs

- [ ] **Step 1: Run full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile, all tests pass, `generatePlugins` defaults to `false` so no plugins are generated in any existing module

- [ ] **Step 2: Verify no generated plugins appear without opt-in**

Check that no `@Plugin` records were generated — `generatePlugins` defaults to `false`:

```bash
find . -path "*/target/generated-sources/*" -name "*Plugin.java" | head -20
```

Expected: No matches (or only existing generated files unrelated to this feature)

- [ ] **Step 3: Update CLAUDE.md**

Update the module table entry for `graphql-generator` to mention plugin generation. Add `GeneratePlugin` to the `mcp-api` package structure section under `io.casehub.platform.api.mcp`.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document @GeneratePlugin annotation and plugin generation capability Refs #795"
```

## References

- [2026-11-11-plugin-generation-design.md] — design spec this plan implements
- `graphql-generator/src/main/java/.../GraphQLResolverProcessor.java` — APT extension point
- `yaml-plugin-processor/src/main/java/.../StepPluginProcessor.java` — multi-round fix target
- `yaml-step-runtime/src/main/java/.../` — Records.toMap() location
- `mcp-api/src/main/java/.../` — @GeneratePlugin annotation location
- GitHub #795 — tracking issue
