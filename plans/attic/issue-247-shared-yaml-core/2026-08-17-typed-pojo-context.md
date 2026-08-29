# Typed POJO Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #238 — feat: JavaBeanCaseFile<T> — typed POJO-backed CaseContext
**Issue group:** #238

**Goal:** Enable case definitions to declare `contextType` in YAML, automatically
wiring `JacksonPojoBridge<T>`, inferring `expressionLang: mvel`, and passing typed
POJOs to workers via the existing `WorkerFunction<T, R>` pipeline.

**Architecture:** Additive wiring on top of existing `ContextBridge<T>` +
`BridgeResolver` + `ExpressionEngineRegistry` infrastructure. YAML `contextType`
→ `resolveByTypeNameStrict()` → `JacksonPojoBridge<T>` → `CaseDefinition.defaultWorkerBridge`.
Expression inference: `contextType` present + no explicit `expressionLang` → `"mvel"`.
MVEL evaluation against bridge-produced POJO via extended `evaluate()` signature.

**Tech Stack:** Java 21, Jackson (JavaTimeModule), MVEL3, Quarkus CDI

## Global Constraints

- Engine is pre-release — breaking changes acceptable
- ADR 0009 — `expressionLang` is per-definition, not per-expression
- `platform-api` must remain zero-dependency — no changes to platform
- All code in `casehub-engine` repo
- Use `ide_*` tools for all Java file operations

---

## Batch 1: Foundation — JacksonPojoBridge fix + contextType parsing

### Task 1: Fix JacksonPojoBridge ObjectMapper — register JavaTimeModule

**Files:**
- Modify: `api/src/main/java/io/casehub/api/context/JacksonPojoBridge.java:24`
- Test: `api/src/test/java/io/casehub/api/context/JacksonPojoBridgeTest.java`

**Interfaces:**
- Consumes: nothing
- Produces: `JacksonPojoBridge<T>` correctly handles `java.time.Instant`, `LocalDate`, `Duration` fields

- [ ] **Step 1: Write failing test — Instant field round-trip**

```java
@Test
void roundTripWithInstantField() {
    record TimedPojo(String name, java.time.Instant createdAt) {}
    var bridge = new JacksonPojoBridge<>(TimedPojo.class);
    var pojo = new TimedPojo("test", java.time.Instant.parse("2026-01-01T00:00:00Z"));
    JsonNode json = bridge.serialise(pojo);
    TimedPojo result = bridge.deserialise(json);
    assertThat(result.createdAt()).isEqualTo(pojo.createdAt());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl api -Dtest=JacksonPojoBridgeTest#roundTripWithInstantField`
Expected: FAIL with `InvalidDefinitionException` (no serializer for Instant)

- [ ] **Step 3: Fix ObjectMapper — add findAndRegisterModules()**

In `JacksonPojoBridge.java`, change the static MAPPER initialisation:

```java
private static final ObjectMapper MAPPER =
    new ObjectMapper()
        .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false)
        .findAndRegisterModules();
```

`findAndRegisterModules()` discovers `jackson-datatype-jsr310` (JavaTimeModule) from
the classpath. This also picks up any other Jackson modules present.

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl api -Dtest=JacksonPojoBridgeTest#roundTripWithInstantField`
Expected: PASS

- [ ] **Step 5: Run full api module tests**

Run: `mvn --batch-mode test -pl api`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add api/src/main/java/io/casehub/api/context/JacksonPojoBridge.java api/src/test/java/io/casehub/api/context/JacksonPojoBridgeTest.java
git commit -m "fix(#238): register JavaTimeModule on JacksonPojoBridge ObjectMapper

Instant, LocalDate, Duration fields threw InvalidDefinitionException.
findAndRegisterModules() discovers jackson-datatype-jsr310 from classpath.

Refs #238"
```

### Task 2: Parse contextType from YAML and wire bridge

**Files:**
- Modify: `api/src/main/java/io/casehub/api/model/converter/CaseDefinitionYamlMapper.java:263-267`
- Modify: `schema/src/main/java/io/casehub/model/CaseDefinition.java` (add `contextType` field)
- Test: `api/src/test/java/io/casehub/api/model/converter/CaseDefinitionYamlMapperTest.java`

**Interfaces:**
- Consumes: `BridgeResolver.resolveByTypeNameStrict(String)` (existing)
- Produces: `CaseDefinition.getDefaultWorkerBridge()` set to `JacksonPojoBridge<T>` when `contextType` declared

- [ ] **Step 1: Add contextType field to schema CaseDefinition**

In `schema/src/main/java/io/casehub/model/CaseDefinition.java`, add:

```java
private String contextType;

public String getContextType() { return contextType; }
public void setContextType(String contextType) { this.contextType = contextType; }
```

Note: check if the schema model is generated (jsonschema2pojo) — if so, add the field
to the JSON schema at `schema/src/main/resources/` instead.

- [ ] **Step 2: Write failing test — contextType parsed and bridge set**

In `CaseDefinitionYamlMapperTest.java`:

```java
@Test
void contextType_setsBridgeToJacksonPojo() throws IOException {
    String yaml = """
        name: typed-case
        version: "1.0"
        contextType: io.casehub.api.model.converter.CaseDefinitionYamlMapperTest.TestContextPojo
        bindings: []
        """;
    CaseDefinition def = loadDefinition(yaml, testRegistry);
    assertThat(def.getDefaultWorkerBridge()).isInstanceOf(JacksonPojoBridge.class);
    assertThat(def.getDefaultWorkerBridge().contextType())
        .isEqualTo(TestContextPojo.class);
}

public static class TestContextPojo {
    public String name;
    public int value;
}
```

- [ ] **Step 3: Write failing test — contextType not on classpath fails fast**

```java
@Test
void contextType_unknownClass_throwsAtParseTime() {
    String yaml = """
        name: typed-case
        version: "1.0"
        contextType: com.nonexistent.NoSuchClass
        bindings: []
        """;
    assertThatThrownBy(() -> loadDefinition(yaml, testRegistry))
        .isInstanceOf(IllegalArgumentException.class)
        .hasMessageContaining("Bridge type class not found");
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl api -Dtest=CaseDefinitionYamlMapperTest#contextType_setsBridgeToJacksonPojo,CaseDefinitionYamlMapperTest#contextType_unknownClass_throwsAtParseTime`
Expected: FAIL

- [ ] **Step 5: Implement contextType parsing in CaseDefinitionYamlMapper**

In the `convert()` method (around line 263), after expressionLang resolution:

```java
if (schema.getContextType() != null) {
    ContextBridge<?> typedBridge =
        BridgeResolver.resolveByTypeNameStrict(schema.getContextType());
    def.setDefaultWorkerBridge(typedBridge);
}
```

Note: `resolveByTypeNameStrict` is an instance method on `BridgeResolver` (CDI bean),
not static. The mapper currently doesn't have a BridgeResolver. Two options:
a. Add a static utility `JacksonPojoBridge.forClassName(String)` that does
   `Class.forName` + construct — avoids CDI dependency in the mapper
b. Thread BridgeResolver through the convert method chain

Option (a) is simpler since the mapper is used in non-CDI contexts:

```java
if (schema.getContextType() != null) {
    try {
        Class<?> contextClass = Class.forName(schema.getContextType());
        def.setDefaultWorkerBridge(new JacksonPojoBridge<>(contextClass));
    } catch (ClassNotFoundException e) {
        throw new IllegalArgumentException(
            "Bridge type class not found: " + schema.getContextType(), e);
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl api -Dtest=CaseDefinitionYamlMapperTest`
Expected: All pass

- [ ] **Step 7: Commit**

```bash
git add api/ schema/
git commit -m "feat(#238): parse contextType from YAML, wire JacksonPojoBridge

CaseDefinitionYamlMapper resolves contextType via Class.forName and sets
JacksonPojoBridge as defaultWorkerBridge. Fail-fast on missing class.

Refs #238"
```

## Batch 2: Expression engine inference + MVEL evaluation

### Task 3: Infer expressionLang from contextType

**Files:**
- Modify: `api/src/main/java/io/casehub/api/model/converter/CaseDefinitionYamlMapper.java:263-266`
- Test: `api/src/test/java/io/casehub/api/model/converter/CaseDefinitionYamlMapperTest.java`

**Interfaces:**
- Consumes: Task 2 (contextType parsed, bridge set)
- Produces: `expressionLang` defaults to `"mvel"` when `contextType` present and no explicit `expressionLang`

- [ ] **Step 1: Write failing test — contextType infers mvel**

```java
@Test
void contextType_infersExpressionLangMvel() throws IOException {
    String yaml = """
        name: typed-case
        version: "1.0"
        contextType: io.casehub.api.model.converter.CaseDefinitionYamlMapperTest.TestContextPojo
        bindings:
          - on: { type: contextChange }
            when: "name != null"
            capability: test-worker
        """;
    var registry = testRegistryWithMvel();
    CaseDefinition def = loadDefinition(yaml, registry);
    // The 'when' expression should be created with "mvel" not "jq"
    assertThat(registry.lastExpressionLang()).isEqualTo("mvel");
}
```

(Requires a recording test registry that tracks `expressionLang` passed to `create()`)

- [ ] **Step 2: Write test — explicit expressionLang overrides inference**

```java
@Test
void contextType_withExplicitJq_usesJq() throws IOException {
    String yaml = """
        name: typed-case
        version: "1.0"
        contextType: io.casehub.api.model.converter.CaseDefinitionYamlMapperTest.TestContextPojo
        expressionLang: jq
        bindings:
          - on: { type: contextChange }
            when: ".name != null"
            capability: test-worker
        """;
    CaseDefinition def = loadDefinition(yaml, testRegistry);
    // explicit expressionLang wins — JQ expressions should work
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl api -Dtest=CaseDefinitionYamlMapperTest#contextType_infersExpressionLangMvel,CaseDefinitionYamlMapperTest#contextType_withExplicitJq_usesJq`
Expected: FAIL

- [ ] **Step 4: Implement inference logic**

In `CaseDefinitionYamlMapper.convert()`, modify the expressionLang resolution (line 263-266):

```java
final String expressionLang;
if (schema.getExpressionLang() != null) {
    expressionLang = schema.getExpressionLang();
} else if (schema.getContextType() != null) {
    expressionLang = "mvel";
} else {
    expressionLang = JQExpressionEvaluator.TYPE;
}
registry.assertLanguageSupported(expressionLang);
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl api`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add api/
git commit -m "feat(#238): infer expressionLang from contextType

contextType present + no explicit expressionLang → mvel.
Explicit expressionLang always wins (migration path: keep jq during transition).

Refs #238"
```

### Task 4: MVEL expression evaluation against bridge-produced POJO

**Files:**
- Modify: `api/src/main/java/io/casehub/api/engine/ExpressionEngine.java` (add bridge-aware evaluate overload)
- Modify: `runtime/src/main/java/io/casehub/engine/internal/engine/DefaultExpressionEngineRegistry.java`
- Create: `runtime/src/main/java/io/casehub/engine/internal/engine/MvelCaseExpressionEngine.java`
- Test: `runtime/src/test/java/io/casehub/engine/internal/engine/MvelCaseExpressionEngineTest.java`

**Interfaces:**
- Consumes: Platform `MvelExpressionEngine` (via CDI), `ContextBridge<T>` (from CaseDefinition)
- Produces: `ExpressionEngineRegistry.evaluate(evaluator, context, bridge)` — evaluates MVEL against bridge-deserialized POJO

- [ ] **Step 1: Write failing test — MVEL evaluates against POJO via bridge**

```java
@Test
void mvelEvaluatesAgainstPojo() {
    record TestPojo(String name, int amount) {}
    var bridge = new JacksonPojoBridge<>(TestPojo.class);
    var context = new CaseContextImpl();
    context.set("name", "test");
    context.set("amount", 42);

    var evaluator = new MvelExpressionEvaluator("amount > 10");
    var engine = new MvelCaseExpressionEngine();

    boolean result = engine.evaluate(evaluator, context, bridge);
    assertThat(result).isTrue();
}

@Test
void mvelEvaluatesAgainstPojo_fieldAccess() {
    record Nested(Inner inner) {}
    record Inner(int value) {}
    var bridge = new JacksonPojoBridge<>(Nested.class);
    var context = new CaseContextImpl();
    context.set("inner", Map.of("value", 99));

    var evaluator = new MvelExpressionEvaluator("inner.value > 50");
    var engine = new MvelCaseExpressionEngine();

    boolean result = engine.evaluate(evaluator, context, bridge);
    assertThat(result).isTrue();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `MvelCaseExpressionEngine` doesn't exist

- [ ] **Step 3: Create MvelCaseExpressionEngine**

```java
package io.casehub.engine.internal.engine;

import io.casehub.api.context.CaseContext;
import io.casehub.api.context.ContextBridge;
import io.casehub.api.engine.ExpressionEngine;
import io.casehub.platform.api.expression.ExpressionEvaluator;
import io.casehub.platform.api.expression.MvelExpressionEvaluator;
import io.casehub.platform.expression.MvelExpressionEngine;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

@ApplicationScoped
public class MvelCaseExpressionEngine implements ExpressionEngine {

    private final MvelExpressionEngine platformMvel;

    @Inject
    public MvelCaseExpressionEngine(MvelExpressionEngine platformMvel) {
        this.platformMvel = platformMvel;
    }

    // Non-CDI constructor for tests
    public MvelCaseExpressionEngine() {
        this.platformMvel = new MvelExpressionEngine();
    }

    @Override
    public String type() { return "mvel"; }

    @Override
    public boolean supportsStringCreation() { return true; }

    @Override
    public ExpressionEvaluator create(String expression) {
        return new MvelExpressionEvaluator(expression);
    }

    @Override
    public boolean evaluate(ExpressionEvaluator evaluator, CaseContext context) {
        // Fallback: evaluate against Map when no bridge available
        var compiled = platformMvel.compile(
            ((MvelExpressionEvaluator) evaluator).expression(),
            Map.class, Boolean.class);
        return Boolean.TRUE.equals(compiled.eval(context.getData()));
    }

    public boolean evaluate(ExpressionEvaluator evaluator,
                           CaseContext context, ContextBridge<?> bridge) {
        Object pojo = bridge.deserialise(context.layer("working").asJsonNode());
        var compiled = platformMvel.compile(
            ((MvelExpressionEvaluator) evaluator).expression(),
            pojo.getClass(), Boolean.class);
        return Boolean.TRUE.equals(compiled.eval(pojo));
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl runtime -Dtest=MvelCaseExpressionEngineTest`
Expected: PASS

- [ ] **Step 5: Wire bridge-aware evaluate into DefaultExpressionEngineRegistry**

Add an overload to `ExpressionEngineRegistry`:

```java
default boolean evaluate(ExpressionEvaluator evaluator,
                        CaseContext context, ContextBridge<?> bridge) {
    return evaluate(evaluator, context);
}
```

Override in `DefaultExpressionEngineRegistry`:

```java
@Override
public boolean evaluate(ExpressionEvaluator evaluator,
                       CaseContext context, ContextBridge<?> bridge) {
    if (evaluator == null) return true;
    ExpressionEngine engine = resolveEngine(evaluator.type());
    if (bridge != null && engine instanceof MvelCaseExpressionEngine mvel) {
        return mvel.evaluate(evaluator, context, bridge);
    }
    return engine.evaluate(evaluator, context);
}
```

- [ ] **Step 6: Update expression evaluation call sites**

The main call sites that evaluate expressions (binding `when`, goal conditions,
milestone conditions) need to pass the bridge when available. These are in:
- `runtime/src/main/java/io/casehub/engine/internal/engine/handler/CaseContextChangedEventHandler.java`
- Goal/milestone evaluators

Each has access to the `CaseDefinition` via the `CaseInstance`. Update calls from:
```java
registry.evaluate(evaluator, context)
```
to:
```java
registry.evaluate(evaluator, context, definition.getDefaultWorkerBridge())
```

The bridge is null when no contextType is declared → falls through to standard evaluate.

- [ ] **Step 7: Run full test suite**

Run: `mvn --batch-mode test`
Expected: All pass

- [ ] **Step 8: Commit**

```bash
git add api/ runtime/ common/
git commit -m "feat(#238): MVEL expression evaluation against bridge-produced POJO

MvelCaseExpressionEngine deserialises CaseContext WORKING layer via bridge,
then evaluates MVEL against the typed POJO. Bridge-aware evaluate() overload
added to ExpressionEngineRegistry. Call sites pass bridge from CaseDefinition.

Refs #238"
```

## Batch 3: Schema + cleanup

### Task 5: Update JSON schema + deprecate MapCaseFile

**Files:**
- Modify: `schema/src/main/resources/casehub-case-definition.json` (add contextType property)
- Modify: `runtime/src/main/java/io/casehub/engine/internal/context/MapCaseFile.java` (deprecate)
- Test: `api/src/test/java/io/casehub/api/model/converter/CaseDefinitionYamlMapperTest.java` (schema validation test)

**Interfaces:**
- Consumes: Tasks 1-4 (all wiring in place)
- Produces: JSON schema updated, MapCaseFile deprecated

- [ ] **Step 1: Add contextType to JSON schema**

In `schema/src/main/resources/casehub-case-definition.json`, add to the `properties` object:

```json
"contextType": {
    "type": "string",
    "description": "Fully-qualified Java class name for typed POJO context. When declared, JacksonPojoBridge<T> is auto-constructed and expressionLang defaults to mvel."
}
```

- [ ] **Step 2: Deprecate MapCaseFile**

Add `@Deprecated(forRemoval = true)` to `MapCaseFile`:

```java
@Deprecated(forRemoval = true)
public class MapCaseFile extends CaseContextImpl {
```

- [ ] **Step 3: Run full test suite**

Run: `mvn --batch-mode test`
Expected: All pass (deprecation is non-breaking)

- [ ] **Step 4: Commit**

```bash
git add schema/ runtime/
git commit -m "chore(#238): add contextType to JSON schema, deprecate MapCaseFile

MapCaseFile was a migration shim from casehub-poc. contextType + JacksonPojoBridge
is the replacement for typed contexts.

Refs #238"
```

## References

- `2026-08-17-typed-pojo-context-design.md` — design spec
- `decisions.md` — D1-D5 design decisions
- `api/src/main/java/io/casehub/api/context/ContextBridge.java` — bridge SPI
- `api/src/main/java/io/casehub/api/context/JacksonPojoBridge.java:24` — ObjectMapper fix
- `api/src/main/java/io/casehub/api/model/converter/CaseDefinitionYamlMapper.java:263` — expressionLang resolution
- `common/src/main/java/io/casehub/engine/common/internal/context/BridgeResolver.java:92` — resolveByTypeNameStrict
- `runtime/src/main/java/io/casehub/engine/internal/engine/DefaultExpressionEngineRegistry.java:81` — evaluate()
- `docs/adr/0009-expression-lang-granularity.md` — per-definition expressionLang ADR
- GE-20260730-41c406 — JacksonPojoBridge ObjectMapper Instant failure
- engine#912 — deferred: CaseContext worker API surface
