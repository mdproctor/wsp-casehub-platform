# Generator Fixes + Plugin Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #835 — WS-6a: Generator fixes + plugin validation
**Issue group:** #835

**Goal:** Fix three concrete generator/plugin bugs (P27, P29, P37) that block typed playbooks.

**Architecture:** Point fixes in two modules — `yaml-step-runtime` (PluginScanner type coercion + ValidatingAction wrapping) and `graphql-generator` (GraphQLResolverProcessor @ContextParam injection + collision detection). No new modules or API surfaces.

**Tech Stack:** Java 21, Maven, JUnit 5, AssertJ

## Global Constraints

- `yaml-plugin-api/` must remain zero-dependency
- `yaml-core/` must remain zero-dependency and J2CL-safe
- No quarkus:build goal in any modified module
- All primitives must use j.u.c locks or lock-free atomics — never `synchronized`

---

## Batch 1: Plugin validation + type coercion (yaml-step-runtime)

### Task 1: Fix extractParam type coercion

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/PluginScanner.java:195-213`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/PluginScannerTest.java`

**Interfaces:**
- Consumes: `PluginScanner.extractParam(Map<String, Object>, String, Class<?>)` — private method, internal
- Produces: Same method signature, now handles String→Number, float, enum coercion

- [ ] **Step 1: Write failing tests for type coercion gaps**

Add tests to `PluginScannerTest.java`:

```java
@Test
void extractParam_string_to_int() {
    PluginScanner scanner = new PluginScanner();
    CompositePluginRegistry registry = new CompositePluginRegistry();
    scanner.scanAndRegister(TestPlugin.class, registry);

    var def = registry.resolve("test-plugin").orElseThrow();
    Result result = def.action().execute(
            Map.of("name", "World", "count", "3"),
            new MapServiceRegistry());
    assertThat(result.isSuccess()).isTrue();
    assertThat(result.output()).containsEntry("greeting", "Hello World");
}
```

Create a new test fixture `EnumPlugin.java` in `scannertest/`:

```java
package io.casehub.yaml.step.catalog.scannertest;

import io.casehub.yaml.plugin.api.*;
import java.util.Map;

@Plugin(value = "enum-plugin", description = "Plugin with enum field")
public record EnumPlugin(@Required Priority priority) {

    public enum Priority { LOW, MEDIUM, HIGH }

    @Execute
    public Result run() {
        return Result.of(Map.of("priority", priority.name()));
    }
}
```

Add tests:

```java
@Test
void extractParam_string_to_long() {
    PluginScanner scanner = new PluginScanner();
    CompositePluginRegistry registry = new CompositePluginRegistry();
    scanner.scanAndRegister(TestPlugin.class, registry);

    // TestPlugin has count (int), but let's create a plugin with long
    // For now, test via the existing fixture with String input
    var def = registry.resolve("test-plugin").orElseThrow();
    Result result = def.action().execute(
            Map.of("name", "World", "count", "42"),
            new MapServiceRegistry());
    assertThat(result.isSuccess()).isTrue();
}

@Test
void extractParam_string_to_double() {
    PluginScanner scanner = new PluginScanner();
    CompositePluginRegistry registry = new CompositePluginRegistry();
    scanner.scanAndRegister(io.casehub.yaml.step.catalog.scannertest.FloatPlugin.class, registry);

    var def = registry.resolve("float-plugin").orElseThrow();
    Result result = def.action().execute(
            Map.of("value", "3.14"),
            new MapServiceRegistry());
    assertThat(result.isSuccess()).isTrue();
    assertThat(result.output()).containsEntry("value", 3.14);
}

@Test
void extractParam_float_from_double() {
    PluginScanner scanner = new PluginScanner();
    CompositePluginRegistry registry = new CompositePluginRegistry();
    scanner.scanAndRegister(io.casehub.yaml.step.catalog.scannertest.FloatPlugin.class, registry);

    var def = registry.resolve("float-plugin").orElseThrow();
    Result result = def.action().execute(
            Map.of("value", 3.14),
            new MapServiceRegistry());
    assertThat(result.isSuccess()).isTrue();
}

@Test
void extractParam_enum_from_string() {
    PluginScanner scanner = new PluginScanner();
    CompositePluginRegistry registry = new CompositePluginRegistry();
    scanner.scanAndRegister(EnumPlugin.class, registry);

    var def = registry.resolve("enum-plugin").orElseThrow();
    Result result = def.action().execute(
            Map.of("priority", "HIGH"),
            new MapServiceRegistry());
    assertThat(result.isSuccess()).isTrue();
    assertThat(result.output()).containsEntry("priority", "HIGH");
}
```

Create `FloatPlugin.java` fixture:

```java
package io.casehub.yaml.step.catalog.scannertest;

import io.casehub.yaml.plugin.api.*;
import java.util.Map;

@Plugin(value = "float-plugin", description = "Plugin with float/double fields")
public record FloatPlugin(double value) {
    @Execute
    public Result run() {
        return Result.of(Map.of("value", value));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=PluginScannerTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: `extractParam_string_to_int` and enum/float tests FAIL with ClassCastException

- [ ] **Step 3: Fix extractParam with proper coercion**

Replace `extractParam` method in `PluginScanner.java`:

```java
@SuppressWarnings({"unchecked", "rawtypes"})
private static Object extractParam(Map<String, Object> params, String key, Class<?> type) {
    Object value = params.get(key);
    if (value == null) {
        if (type == int.class) return 0;
        if (type == long.class) return 0L;
        if (type == double.class) return 0.0;
        if (type == float.class) return 0.0f;
        if (type == boolean.class) return false;
        return null;
    }
    if (type == int.class || type == Integer.class) {
        if (value instanceof Number n) return n.intValue();
        return Integer.parseInt(value.toString());
    }
    if (type == long.class || type == Long.class) {
        if (value instanceof Number n) return n.longValue();
        return Long.parseLong(value.toString());
    }
    if (type == double.class || type == Double.class) {
        if (value instanceof Number n) return n.doubleValue();
        return Double.parseDouble(value.toString());
    }
    if (type == float.class || type == Float.class) {
        if (value instanceof Number n) return n.floatValue();
        return Float.parseFloat(value.toString());
    }
    if (type == boolean.class || type == Boolean.class) {
        if (value instanceof Boolean b) return b;
        return Boolean.parseBoolean(value.toString());
    }
    if (type.isEnum()) {
        return Enum.valueOf((Class<Enum>) type, value.toString());
    }
    return value;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=PluginScannerTest`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/PluginScanner.java
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/PluginScannerTest.java
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/scannertest/EnumPlugin.java
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/scannertest/FloatPlugin.java
git commit -m "fix(#835): extractParam type coercion — String→Number, float, enum"
```

### Task 2: Wrap @Plugin actions in ValidatingAction

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/PluginScanner.java:50-55`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/PluginScannerTest.java`

**Interfaces:**
- Consumes: `Declaration(name, description, inputs, outputs, invoke)` from yaml-core, `ValidatingAction(declaration, delegate, eventSink)` from yaml-step-runtime
- Produces: `PluginScanner.scanAndRegister()` now returns a Definition with a ValidatingAction-wrapped action

- [ ] **Step 1: Write failing test for missing required field**

Add to `PluginScannerTest.java`:

```java
@Test
void missingRequiredField_returnsFailure() {
    PluginScanner scanner = new PluginScanner();
    CompositePluginRegistry registry = new CompositePluginRegistry();
    scanner.scanAndRegister(TestPlugin.class, registry);

    var def = registry.resolve("test-plugin").orElseThrow();
    // TestPlugin has @Required String name — omit it
    Result result = def.action().execute(
            Map.of("count", 3),
            new MapServiceRegistry());
    assertThat(result.isSuccess()).isFalse();
    assertThat(((Result.Failure) result).message()).contains("name");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=PluginScannerTest#missingRequiredField_returnsFailure`
Expected: FAIL — currently succeeds with `name=null` (silent corruption)

- [ ] **Step 3: Wrap action in ValidatingAction in scanAndRegister**

Modify `PluginScanner.scanAndRegister()` to build a `Declaration` from the inputs and wrap the action:

```java
public void scanAndRegister(Class<?> pluginClass, PluginRegistry registry) {
    // ... existing annotation/name/executeMethod/inputs extraction ...

    Action rawAction = createAction(pluginClass, executeMethod, inputs, streamingInputKey);

    // Build Declaration for validation
    Declaration declaration = new Declaration(name, description, inputs, Map.of(), null);
    Action validatedAction = new ValidatingAction(declaration, rawAction, event -> {});

    // ... streaming type info ...

    registry.register(new Definition(name, description, inputs, Map.of(), portability,
            validatedAction, capability, streamingType, annotation.absorbSiblings()));
}
```

Add imports:
```java
import io.casehub.yaml.core.step.Declaration;
import io.casehub.yaml.step.ValidatingAction;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest=PluginScannerTest`
Expected: ALL PASS — including `missingRequiredField_returnsFailure` now returning failure

- [ ] **Step 5: Run full module tests**

Run: `mvn --batch-mode test -pl yaml-step-runtime`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/PluginScanner.java
git add yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/PluginScannerTest.java
git commit -m "fix(#835): wrap @Plugin actions in ValidatingAction — reject missing @Required"
```

## Batch 2: Generator fixes (graphql-generator)

### Task 3: Fix @ContextParam in plugin delegate calls

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java:1994-2001`
- Test: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/PluginGenerationTest.java`
- Test fixture: Create a test SPI interface with `@ContextParam` for plugin generation verification

**Interfaces:**
- Consumes: `ResolvedParam.isContextParam()`, `ResolvedParam.contextParamKey()`, `contextParamResolution(String)` — all existing
- Produces: Generated plugin source now includes `services.lookup(CurrentPrincipal.class)` for @ContextParam values

- [ ] **Step 1: Understand existing test infrastructure for plugin generation**

Read the full `PluginGenerationTest.java` and the existing `GraphQLResolverProcessorTest.java` test infrastructure to understand how APT compilation tests work in this module. The APT tests use in-memory compilation — find the existing pattern.

Read: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessorTest.java` — look for `classBasedDomainWithContextParam` (line ~882) and the test compilation infrastructure.

- [ ] **Step 2: Write failing test for @ContextParam in plugin generation**

The test should verify that the generated plugin source for an operation with `@ContextParam("tenancyId")` includes a ServiceRegistry lookup rather than skipping the parameter. The exact test pattern depends on what Step 1 reveals about the compilation test infrastructure.

Expected test shape — verify generated source contains:
- `services.lookup(CurrentPrincipal.class)` or equivalent
- The context param is passed to the delegate call (not skipped)

- [ ] **Step 3: Run test to verify it fails**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=PluginGenerationTest`
Expected: FAIL — generated plugin source skips @ContextParam

- [ ] **Step 4: Fix generatePluginSource to inject context params**

In `GraphQLResolverProcessor.java`, modify the delegate call loop (lines 1994-2001):

**Before:**
```java
for (ResolvedParam p : op.params()) {
    if (p.isContextParam()) continue;
    // ...
}
```

**After:** When context params are present, emit a `CurrentPrincipal` lookup before the delegate call, then include context param resolution in the argument list:

```java
// Check if any context params exist
boolean hasContextParams = op.params().stream().anyMatch(ResolvedParam::isContextParam);
if (hasContextParams) {
    out.println("        var __principal = (io.casehub.platform.api.identity.CurrentPrincipal) services.lookup(io.casehub.platform.api.identity.CurrentPrincipal.class);");
}

StringBuilder methodArgs = new StringBuilder();
for (ResolvedParam p : op.params()) {
    if (isStreaming && !meta.subject.isEmpty() && p.name().equals(meta.subject)) continue;
    if (!methodArgs.isEmpty()) methodArgs.append(", ");
    if (p.isContextParam()) {
        methodArgs.append(pluginContextParamResolution(p.contextParamKey()));
    } else {
        methodArgs.append(p.name());
    }
}
```

Add a new helper method:
```java
private static String pluginContextParamResolution(String key) {
    return switch (key) {
        case "tenancyId" -> "__principal.tenancyId()";
        case "actorId" -> "__principal.actorId()";
        default -> "__principal." + key + "()";
    };
}
```

Note: `httpHeaders`, `queryParams`, `requestUrl` are HTTP-only context params that don't apply in the plugin context — they should remain skipped. Add a filter:

```java
private static boolean isHttpOnlyContextParam(String key) {
    return "httpHeaders".equals(key) || "queryParams".equals(key) || "requestUrl".equals(key);
}
```

In the loop:
```java
if (p.isContextParam()) {
    if (isHttpOnlyContextParam(p.contextParamKey())) continue;
    methodArgs.append(pluginContextParamResolution(p.contextParamKey()));
} else {
    methodArgs.append(p.name());
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=PluginGenerationTest`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java
git add graphql-generator/src/test/java/io/casehub/platform/graphql/generator/PluginGenerationTest.java
git commit -m "fix(#835): inject @ContextParam via ServiceRegistry in generated plugins"
```

### Task 4: Step name collision detection

**Files:**
- Modify: `graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java:2026-2031` (derivePluginName) and `:185-186` (iteration loop)
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/CompositePluginRegistry.java:19-24`
- Test: `graphql-generator/src/test/java/io/casehub/platform/graphql/generator/PluginGenerationTest.java`

**Interfaces:**
- Consumes: `derivePluginName(String domain, String methodName)` — existing static method
- Produces: `derivePluginName(String domain, String methodName, Set<String> collisions)` — new overload; `CompositePluginRegistry.register()` — now warns on override

- [ ] **Step 1: Write failing tests for collision detection**

Add to `PluginGenerationTest.java`:

```java
@Test
void derivePluginName_no_collision_uses_short_name() {
    Set<String> collisions = Set.of();
    assertThat(GraphQLResolverProcessor.derivePluginName("connectors/voice", "speak", collisions))
            .isEqualTo("voice-speak");
}

@Test
void derivePluginName_collision_uses_full_domain_path() {
    Set<String> collisions = Set.of("voice-speak");
    assertThat(GraphQLResolverProcessor.derivePluginName("connectors/voice", "speak", collisions))
            .isEqualTo("connectors-voice-speak");
}

@Test
void derivePluginName_deep_nested_collision_uses_full_path() {
    Set<String> collisions = Set.of("lifecycle-claim");
    assertThat(GraphQLResolverProcessor.derivePluginName("work/case/lifecycle", "claim", collisions))
            .isEqualTo("work-case-lifecycle-claim");
}

@Test
void derivePluginName_simple_domain_unaffected_by_collision() {
    Set<String> collisions = Set.of("voice-speak");
    assertThat(GraphQLResolverProcessor.derivePluginName("labels", "children", collisions))
            .isEqualTo("labels-children");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=PluginGenerationTest`
Expected: FAIL — `derivePluginName` doesn't accept a collisions set

- [ ] **Step 3: Add collision-aware derivePluginName overload**

Add a new overload alongside the existing method:

```java
static String derivePluginName(String domain, String methodName, Set<String> collisions) {
    String shortName = derivePluginName(domain, methodName);
    if (collisions.contains(shortName)) {
        return domain.replace('/', '-') + "-" + toKebabCase(methodName);
    }
    return shortName;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl graphql-generator -Dtest=PluginGenerationTest`
Expected: ALL PASS

- [ ] **Step 5: Add two-pass collision detection in the iteration loop**

In `GraphQLResolverProcessor`, before the existing loop at line 185, add a collision pre-scan:

```java
// Pre-scan for plugin name collisions across all domains
Set<String> pluginNameCollisions = new HashSet<>();
if (generatePlugins) {
    Map<String, List<String>> nameTodomains = new HashMap<>();
    for (var entry : allDomains.entrySet()) {
        String domain = entry.getKey();
        for (ResolvedOperation op : entry.getValue().operations) {
            if (op.type() == OperationType.WEBHOOK || op.type() == OperationType.STREAM) continue;
            if (isReactiveReturn(op.returnTypeStr())) continue;
            PluginMeta meta = resolvePluginMeta(op);
            if (meta.exclude || !meta.name.isEmpty()) continue;
            String shortName = derivePluginName(domain, op.methodName());
            nameTodomains.computeIfAbsent(shortName, k -> new ArrayList<>()).add(domain);
        }
    }
    for (var entry : nameTodomains.entrySet()) {
        if (entry.getValue().size() > 1) {
            pluginNameCollisions.add(entry.getKey());
            processingEnv.getMessager().printMessage(Diagnostic.Kind.WARNING,
                    "Plugin name collision '" + entry.getKey() + "' across domains: "
                    + entry.getValue() + " — using full domain paths");
        }
    }
}
```

Then update the call site at line 1839:
```java
String pluginName = meta.name.isEmpty()
        ? derivePluginName(domain, op.methodName(), pluginNameCollisions)
        : meta.name;
```

Pass `pluginNameCollisions` through to `generatePluginSource()` — add it as a parameter.

- [ ] **Step 6: Upgrade CompositePluginRegistry to warn on override**

In `CompositePluginRegistry.register()`, change from INFO to WARNING:

```java
@Override
public void register(Definition definition) {
    Definition existing = definitions.put(definition.name(), definition);
    if (existing != null) {
        LOG.log(Level.WARNING, "Plugin registration collision: ''{0}'' — previous registration overridden", definition.name());
    }
}
```

- [ ] **Step 7: Run all tests in both modules**

Run: `mvn --batch-mode test -pl graphql-generator,yaml-step-runtime`
Expected: ALL PASS

- [ ] **Step 8: Commit**

```bash
git add graphql-generator/src/main/java/io/casehub/platform/graphql/generator/GraphQLResolverProcessor.java
git add graphql-generator/src/test/java/io/casehub/platform/graphql/generator/PluginGenerationTest.java
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/CompositePluginRegistry.java
git commit -m "fix(#835): collision-safe plugin names — short default, full path on collision"
```

## Batch 3: Integration verification

### Task 5: Full build verification

**Files:** None — verification only

**Interfaces:** None

- [ ] **Step 1: Run full project build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile and pass tests

- [ ] **Step 2: Verify no regressions in existing plugin generation**

Check that existing generated plugins in consumer repos (if any exist on the classpath) still resolve by their expected names. The collision detection only changes names when actual collisions exist — existing non-colliding names should be unchanged.

- [ ] **Step 3: Commit any fixups**

If the full build surfaces issues, fix and commit individually.

## References

- [2026-11-17-generator-fixes-plugin-validation-design.md] — design spec
- [GraphQLResolverProcessor.java:1997] — P27 @ContextParam skip
- [GraphQLResolverProcessor.java:2026-2031] — P29 derivePluginName
- [GraphQLResolverProcessor.java:2608] — contextParamResolution() pattern
- [PluginScanner.java:50-55] — P37 raw action registration
- [PluginScanner.java:195-213] — P37 extractParam gaps
- [ValidatingAction.java] — existing validation wrapper
- [CompositePluginRegistry.java:19-24] — silent put on collision
- [Declaration.java] — Declaration record for ValidatingAction
- [PluginScannerTest.java] — existing test patterns
- [PluginGenerationTest.java] — existing APT test patterns
- [GitHub #835] — focal issue
