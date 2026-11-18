# Validator MCP Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #836 — WS-6b: Validator MCP tool + shaped plugin schemas + authoring metric
**Issue group:** #836

**Goal:** Build the validator MCP tool that serves as the LLM authoring interface, implement per-subject variant schemas for shaped plugins, and establish the authoring metric.

**Architecture:** Enrich the existing `PlaybookApi` with structured validation diagnostics (leveraging the existing `ParseError` sealed hierarchy), a level-filtered + trust-filtered step catalogue, and variant-aware JSON Schema composition. The Walker is modified to accumulate errors via `YamlErrorCollector` instead of throwing. A separate `yaml-metric-core` module provides the authoring metric plugin.

**Tech Stack:** Java 21, yaml-core (zero-dep), yaml-plugin-api (zero-dep), yaml-plugin-processor (APT), yaml-step-runtime (Quarkus), playbook-runner (Quarkus CDI wiring)

## Global Constraints

- `yaml-plugin-api/` must remain zero-dependency — no Quarkus, no JPA, no casehubio imports. Pure Java only.
- `yaml-core/` depends only on `yaml-plugin-api` — remains transitively zero-dep, J2CL-safe.
- All new primitives in yaml-core MUST use `java.util.concurrent` locks or lock-free atomics — never `synchronized`.
- Every commit references issue #836.
- All YAML examples use bare-list form — no `steps:` wrapper key.

---

## Batch 1: Foundation — Level registry + Definition variants + Severity

Core infrastructure in zero-dep modules that everything else depends on.

### Task 1: `YamlError.Severity` and `PlaybookLevel` registry

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/error/YamlError.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/playbook/PlaybookLevel.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/playbook/PlaybookLevelRegistry.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/playbook/MapPlaybookLevelRegistry.java`
- Create: `yaml-core/src/main/java/io/casehub/yaml/core/playbook/LevelFilteredRegistry.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/playbook/MapPlaybookLevelRegistryTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/playbook/LevelFilteredRegistryTest.java`

**Interfaces:**
- Produces: `PlaybookLevel(String name, int ordinal, Set<String> capabilities)`, `PlaybookLevelRegistry.resolve(String)`, `PlaybookLevelRegistry.resolveByOrdinal(int)`, `PlaybookLevelRegistry.all()`, `PlaybookLevelRegistry.resolveOrThrow(String)`, `LevelFilteredRegistry.forLevel(PluginRegistry, PlaybookLevelRegistry, String)`, `YamlError.Severity.ERROR`, `YamlError.Severity.WARNING`, `YamlError.severity()`

- [ ] **Step 1: Write tests for MapPlaybookLevelRegistry**

```java
@Test void resolveByName() {
    var reg = new MapPlaybookLevelRegistry();
    var level = reg.resolve("foundational");
    assertTrue(level.isPresent());
    assertEquals(1, level.get().ordinal());
    assertTrue(level.get().capabilities().contains("steps"));
}

@Test void resolveByOrdinal() {
    var reg = new MapPlaybookLevelRegistry();
    var level = reg.resolveByOrdinal(1);
    assertTrue(level.isPresent());
    assertEquals("foundational", level.get().name());
}

@Test void allLevelsOrderedByOrdinal() {
    var reg = new MapPlaybookLevelRegistry();
    var all = reg.all();
    assertEquals(5, all.size());
    assertEquals("foundational", all.get(0).name());
    assertEquals("expert", all.get(4).name());
}

@Test void higherLevelsIncludeLowerCapabilities() {
    var reg = new MapPlaybookLevelRegistry();
    var basic = reg.resolve("basic-patterns").orElseThrow();
    assertTrue(basic.capabilities().contains("steps")); // from foundational
    assertTrue(basic.capabilities().contains("decorators")); // own
}

@Test void resolveOrThrowOnUnknown() {
    var reg = new MapPlaybookLevelRegistry();
    assertThrows(IllegalArgumentException.class, () -> reg.resolveOrThrow("nonexistent"));
}
```

- [ ] **Step 2: Write tests for LevelFilteredRegistry**

```java
@Test void filtersByLevelCapabilities() {
    var base = new MapServiceRegistry(); // or CompositePluginRegistry
    base.register(Definition.of("log").execute((p,s) -> Result.of(Map.of())).capability("steps").build());
    base.register(Definition.of("parallel-step").execute((p,s) -> Result.of(Map.of())).capability("concurrency").build());

    var levels = new MapPlaybookLevelRegistry();
    var filtered = LevelFilteredRegistry.forLevel(base, levels, "foundational");

    assertTrue(filtered.resolve("log").isPresent());
    assertFalse(filtered.resolve("parallel-step").isPresent());
    assertTrue(filtered.availableActions().contains("log"));
    assertFalse(filtered.availableActions().contains("parallel-step"));
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn -pl yaml-core test -Dtest=MapPlaybookLevelRegistryTest,LevelFilteredRegistryTest --batch-mode`
Expected: compilation failures (classes don't exist)

- [ ] **Step 4: Implement YamlError.Severity**

Add to `YamlError.java`:
```java
enum Severity { ERROR, WARNING }
default Severity severity() { return Severity.ERROR; }
```

- [ ] **Step 5: Implement PlaybookLevel, PlaybookLevelRegistry, MapPlaybookLevelRegistry**

`PlaybookLevel`: record with `(String name, int ordinal, Set<String> capabilities)`, defensive copy in compact constructor.

`PlaybookLevelRegistry`: interface with `register`, `resolve`, `resolveByOrdinal`, `all`, `resolveOrThrow`.

`MapPlaybookLevelRegistry`: ConcurrentHashMap-backed implementation. Constructor registers 5 built-in levels:
- `foundational` (1): steps, variable-resolution, control-flow
- `basic-patterns` (2): + decorators
- `intermediate` (3): + concurrency, modules
- `advanced` (4): + orchestration, correlation, state-machine
- `expert` (5): + mcp-invoke, graphql-invoke, codegen

Each level includes all capabilities from lower ordinals.

- [ ] **Step 6: Implement LevelFilteredRegistry**

Same delegation pattern as `SchemaFilteredRegistry`. Constructor takes `(PluginRegistry delegate, Set<String> allowedCapabilities)`. Static factory `forLevel(PluginRegistry, PlaybookLevelRegistry, String)`.

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn -pl yaml-core test -Dtest=MapPlaybookLevelRegistryTest,LevelFilteredRegistryTest --batch-mode`
Expected: all PASS

- [ ] **Step 8: Commit**

```
feat(#836): add PlaybookLevel registry, LevelFilteredRegistry, YamlError.Severity
```

### Task 2: `Definition.variants` field + `@Variant` annotation + Builder

**Files:**
- Modify: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Definition.java`
- Create: `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Variant.java`
- Test: `yaml-plugin-api/src/test/java/io/casehub/yaml/plugin/api/DefinitionVariantTest.java`

**Interfaces:**
- Consumes: `Parameter`, `ParameterType` (existing)
- Produces: `Definition.variants()` → `Map<String, Map<String, Parameter>>`, `@Variant(String value)`, `Builder.variant(String, Map<String, Parameter>)`

- [ ] **Step 1: Write tests for Definition variants**

```java
@Test void variantsDefaultToEmpty() {
    var def = Definition.of("test").execute((p,s) -> Result.of(Map.of())).build();
    assertTrue(def.variants().isEmpty());
}

@Test void builderAccumulatesVariants() {
    var def = Definition.of("device")
        .absorbSiblings(true)
        .variant("register", Map.of("name", Parameter.required(ParameterType.STRING)))
        .variant("query", Map.of("id", Parameter.required(ParameterType.STRING)))
        .execute((p,s) -> Result.of(Map.of()))
        .build();
    assertEquals(2, def.variants().size());
    assertTrue(def.variants().get("register").get("name").required());
    assertTrue(def.variants().get("query").get("id").required());
}

@Test void existingConstructorsStillWork() {
    var def = new Definition("test", null, Map.of(), Map.of(),
            Portability.BOTH, (p,s) -> Result.of(Map.of()), null);
    assertTrue(def.variants().isEmpty());
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-plugin-api test -Dtest=DefinitionVariantTest --batch-mode`
Expected: compilation failures

- [ ] **Step 3: Add `variants` field to Definition record**

Add `Map<String, Map<String, Parameter>> variants` as the 10th field. Update compact constructor to default to `Map.of()`. Update existing convenience constructors (7-arg, 8-arg) to pass `Map.of()` for variants. Add `variant()` method to Builder. Update `Builder.build()` to pass the accumulated variants map.

- [ ] **Step 4: Create `@Variant` annotation**

```java
package io.casehub.yaml.plugin.api;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
public @interface Variant {
    String value();
}
```

- [ ] **Step 5: Fix compilation errors across the codebase**

Search for all direct `Definition` constructor calls outside the Builder and update them to include the `variants` parameter (`Map.of()`). Key locations:
- `ValidatePlaybookPlugin.java` (stub definitions)
- `AptPluginSource.java` (manifest-loaded definitions)
- `PluginScanner.java` (annotation-scanned definitions)
- Any test fixtures using direct constructors

Run: `mvn --batch-mode install -DskipTests` to find all compilation errors.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn -pl yaml-plugin-api test -Dtest=DefinitionVariantTest --batch-mode`
Expected: all PASS

- [ ] **Step 7: Run full build to verify no regressions**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 8: Commit**

```
feat(#836): add Definition.variants field, @Variant annotation, Builder.variant()
```

---

## Batch 2: Walker structured error collection + enriched validation

The core validation pipeline — Walker accumulates errors, validation returns structured diagnostics.

### Task 3: Walker error collection overload + ErrorStep

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/ResolvedStep.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/WalkerErrorCollectionTest.java`

**Interfaces:**
- Consumes: `YamlErrorCollector` (existing), `ParseError` subtypes (existing), `PluginRegistry`, `AnnotationMap`
- Produces: `Walker.resolve(List, PluginRegistry, AnnotationMap, YamlErrorCollector, String)`, `ResolvedStep.ErrorStep(String, Map, ParseError)`

- [ ] **Step 1: Write tests for Walker error collection**

```java
@Test void collectsUnknownStepError() {
    var registry = new CompositePluginRegistry();
    registry.register(Definition.of("log").execute((p,s) -> Result.of(Map.of())).build());

    var steps = List.of(Map.<String, Object>of("nonexistent", "value"));
    var collector = new YamlErrorCollector();
    var resolved = Walker.resolve(steps, registry, AnnotationMap.empty(), collector, "test.yaml");

    assertTrue(collector.hasErrors());
    assertEquals(1, collector.errors().size());
    assertInstanceOf(ParseError.UnknownStepError.class, collector.errors().get(0));
    assertEquals(1, resolved.size());
    assertInstanceOf(ResolvedStep.ErrorStep.class, resolved.get(0));
}

@Test void collectsMultipleErrors() {
    var registry = new CompositePluginRegistry();
    var steps = List.of(
        Map.<String, Object>of("unknown1", "v"),
        Map.<String, Object>of("unknown2", "v"));
    var collector = new YamlErrorCollector();
    var resolved = Walker.resolve(steps, registry, AnnotationMap.empty(), collector, "test.yaml");

    assertEquals(2, collector.errors().size());
    assertEquals(2, resolved.size());
}

@Test void validStepsStillResolve() {
    var registry = new CompositePluginRegistry();
    registry.register(Definition.of("log").execute((p,s) -> Result.of(Map.of())).build());

    var steps = List.of(Map.<String, Object>of("log", "hello"));
    var collector = new YamlErrorCollector();
    var resolved = Walker.resolve(steps, registry, AnnotationMap.empty(), collector, "test.yaml");

    assertFalse(collector.hasErrors());
    assertEquals(1, resolved.size());
    assertInstanceOf(ResolvedStep.PluginStep.class, resolved.get(0));
}

@Test void originalOverloadStillThrows() {
    var registry = new CompositePluginRegistry();
    var steps = List.of(Map.<String, Object>of("nonexistent", "value"));
    assertThrows(IllegalArgumentException.class, () -> Walker.resolve(steps, registry));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn -pl yaml-step-runtime test -Dtest=WalkerErrorCollectionTest --batch-mode`
Expected: compilation failures

- [ ] **Step 3: Add `ErrorStep` to `ResolvedStep` sealed interface**

```java
record ErrorStep(
    String name,
    Map<String, Object> originalYaml,
    ParseError error,
    Map<String, Object> decorators,
    List<Annotation> annotations) implements ResolvedStep {

    public ErrorStep(String name, Map<String, Object> originalYaml, ParseError error) {
        this(name, originalYaml, error, Map.of(), List.of());
    }
}
```

- [ ] **Step 4: Add Walker.resolve() overload with YamlErrorCollector**

New overload that accepts `YamlErrorCollector collector` and `String playbookFile`. Duplicate the core `resolveOne()` logic into a `resolveOneCollecting()` variant that:
- Catches `IllegalArgumentException` from unknown keys and converts to `ParseError.UnknownStepError`
- Catches duplicate name errors and converts to `ParseError.DuplicateStepError`
- Converts structural issues to `ParseError.StructureError`
- Returns `ErrorStep` for unresolvable steps instead of throwing
- Uses `SourceLocation(playbookFile, -1, -1)` for all errors

The original throwing overloads delegate to the collecting overload and call `collector.throwIfErrors()` at the end for backward compatibility.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn -pl yaml-step-runtime test -Dtest=WalkerErrorCollectionTest --batch-mode`
Expected: all PASS

- [ ] **Step 6: Run full module tests for regression**

Run: `mvn -pl yaml-step-runtime test --batch-mode`
Expected: all existing tests still PASS

- [ ] **Step 7: Commit**

```
feat(#836): Walker error collection overload with YamlErrorCollector + ErrorStep
```

### Task 4: Enriched PlaybookValidationResult + ValidationContext + bare-list enforcement

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/PlaybookValidationResult.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/ValidationContext.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/ValidationSuggestion.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/LlmFixResult.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/ValidationSuggestionGenerator.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/PlaybookRunnerCore.java`
- Modify: `playbook-runner/src/main/java/io/casehub/yaml/test/quarkus/PlaybookBeans.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/runner/PlaybookValidationEnrichedTest.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/runner/ValidationSuggestionGeneratorTest.java`

**Interfaces:**
- Consumes: `Walker.resolve(..., YamlErrorCollector, String)` (Task 3), `SchemaFilteredRegistry.forSchema()`, `LevelFilteredRegistry.forLevel()` (Task 1), `ParseError` subtypes, `PluginRegistry`
- Produces: `PlaybookValidationResult(boolean, List<YamlError>, PlaybookFrontMatter, List<ValidationSuggestion>, LlmFixResult)`, `ValidationContext(String schema, String level, boolean llmSuggestions)`, `ValidationSuggestion(int diagnosticIndex, String suggestion, String exampleYaml)`, `LlmFixResult(String correctedYaml, String explanation, String model)`, `ValidationSuggestionGenerator.generate(List<YamlError>, PluginRegistry)`

- [ ] **Step 1: Write tests for enriched validation**

```java
@Test void validPlaybookReturnsEmptyDiagnostics() {
    var registry = buildTestRegistry(); // has "log"
    var core = new PlaybookRunnerCore(registry, serviceRegistry, resourceRoot, null);
    Path playbook = writeTempPlaybook("- log: hello\n");
    var result = core.validate(playbook, new ValidationContext("developer", null, false));
    assertTrue(result.valid());
    assertTrue(result.diagnostics().isEmpty());
}

@Test void unknownStepReturnsStructuredDiagnostic() {
    var registry = buildTestRegistry();
    var core = new PlaybookRunnerCore(registry, serviceRegistry, resourceRoot, null);
    Path playbook = writeTempPlaybook("- nonexistent: value\n");
    var result = core.validate(playbook, new ValidationContext("developer", null, false));
    assertFalse(result.valid());
    assertFalse(result.diagnostics().isEmpty());
    assertInstanceOf(ParseError.UnknownStepError.class, result.diagnostics().get(0));
}

@Test void stepsKeyRejectedUnderAssisted() {
    var registry = buildTestRegistry();
    var core = new PlaybookRunnerCore(registry, serviceRegistry, resourceRoot, null);
    Path playbook = writeTempPlaybook("---\nplaybook: \"1.0\"\nschema: assisted\n---\nsteps:\n  - log: hello\n");
    var result = core.validate(playbook, new ValidationContext("assisted", null, false));
    assertFalse(result.valid());
    assertTrue(result.diagnostics().stream().anyMatch(e ->
        e.summary().contains("Remove the 'steps:' wrapper")));
}
```

- [ ] **Step 2: Write tests for ValidationSuggestionGenerator**

```java
@Test void suggestsClosestMatchForUnknownStep() {
    var registry = buildTestRegistry(); // has "log", "assert", "assertThat"
    var error = new ParseError.UnknownStepError("step1", "lg", SourceLocation.UNKNOWN, null);
    var suggestions = ValidationSuggestionGenerator.generate(List.of(error), registry);
    assertEquals(1, suggestions.size());
    assertTrue(suggestions.get(0).suggestion().contains("log"));
}

@Test void includesExampleYaml() {
    var registry = buildTestRegistry();
    var error = new ParseError.UnknownStepError("step1", "lg", SourceLocation.UNKNOWN, null);
    var suggestions = ValidationSuggestionGenerator.generate(List.of(error), registry);
    assertNotNull(suggestions.get(0).exampleYaml());
    assertTrue(suggestions.get(0).exampleYaml().contains("log"));
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn -pl yaml-step-runtime test -Dtest=PlaybookValidationEnrichedTest,ValidationSuggestionGeneratorTest --batch-mode`
Expected: compilation failures

- [ ] **Step 4: Create ValidationContext, ValidationSuggestion, LlmFixResult records**

Simple records as specified in the design spec.

- [ ] **Step 5: Rewrite PlaybookValidationResult**

Replace `List<String> errors` with `List<YamlError> diagnostics`. Add `List<ValidationSuggestion> suggestions` and `LlmFixResult llmFix` (nullable). Provide backward-compatible constructors.

- [ ] **Step 6: Implement ValidationSuggestionGenerator**

Static `generate(List<YamlError>, PluginRegistry)` method:
- For `UnknownStepError`: compute Levenshtein distance against `registry.availableActions()`, suggest closest match. Build example YAML from the matched `Definition`'s inputs (required params with type placeholder values).
- For `ParameterError`: suggest adding/fixing the parameter from the `Definition`'s input map.
- For `StructureError`: no suggestion (structural issues are described by the error message).
- Return `List<ValidationSuggestion>` with `diagnosticIndex` correlating to position in the diagnostics list.

- [ ] **Step 7: Modify PlaybookRunnerCore.validate()**

Add `validate(Path, ValidationContext)` overload. Implementation:
1. Parse, expand imports (unchanged)
2. Derive effective level from `ctx.level()` or `meta.level` in content
3. Check for `steps:` key — add `StructureError` to collector if present under `assisted`
4. Extract step list (bare list from document, or from `steps:` key)
5. Build filtered registry (trust then level)
6. Call `Walker.resolve(steps, filteredRegistry, annotations, collector, path.toString())`
7. Generate suggestions via `ValidationSuggestionGenerator`
8. `llmFix` is null (layer 3 wired in a later batch)
9. Return enriched result

Original `validate(Path)` delegates with developer defaults.

- [ ] **Step 8: Update PlaybookBeans.validate()**

Construct `ValidationContext("assisted", null, false)` and pass `SchemaFilteredRegistry.forSchema(registry, schemas, "assisted")` to the core. Wire `PlaybookSchemaRegistry` and `PlaybookLevelRegistry` as injected dependencies.

- [ ] **Step 9: Fix compilation in existing validate() callers**

Update callers that use the old `PlaybookValidationResult(boolean, List<String>, FrontMatter)` constructor — primarily `ValidatePlaybookPlugin`.

- [ ] **Step 10: Run tests to verify they pass**

Run: `mvn -pl yaml-step-runtime test -Dtest=PlaybookValidationEnrichedTest,ValidationSuggestionGeneratorTest --batch-mode`
Expected: all PASS

- [ ] **Step 11: Run full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 12: Commit**

```
feat(#836): enriched PlaybookValidationResult with structured diagnostics and suggestions
```

---

## Batch 3: Catalogue API + variant schema composition

Step catalogue query and variant-aware JSON Schema.

### Task 5: StepCatalogue API + catalogue() on PlaybookApi

**Files:**
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/StepCatalogue.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/StepEntry.java`
- Create: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/ParameterSummary.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/PlaybookApi.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepSchemaComposer.java`
- Modify: `playbook-runner/src/main/java/io/casehub/yaml/test/quarkus/PlaybookBeans.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/runner/StepCatalogueTest.java`

**Interfaces:**
- Consumes: `SchemaFilteredRegistry.forSchema()`, `LevelFilteredRegistry.forLevel()` (Task 1), `StepSchemaComposer.compose()`, `PluginRegistry.availableActions()`
- Produces: `PlaybookApi.catalogue(String level, String schema)` → `StepCatalogue`, `StepCatalogue(String, String, List<StepEntry>, ObjectNode)`, `StepEntry(String, String, String, Map<String, ParameterSummary>, String)`, `ParameterSummary(ParameterType, boolean, String)`, `StepSchemaComposer.compose(PluginRegistry, ObjectMapper, Set<String>)`

- [ ] **Step 1: Write tests for catalogue API**

```java
@Test void catalogueFiltersbyLevel() {
    var catalogue = service.catalogue("foundational", "developer");
    assertTrue(catalogue.steps().stream().allMatch(s -> 
        Set.of("steps", "variable-resolution", "control-flow").contains(s.capability())));
}

@Test void catalogueFiltersByTrust() {
    var catalogue = service.catalogue("expert", "assisted");
    assertTrue(catalogue.steps().stream().noneMatch(s -> 
        "process-execution".equals(s.capability())));
}

@Test void catalogueIncludesJsonSchema() {
    var catalogue = service.catalogue("foundational", "developer");
    assertNotNull(catalogue.jsonSchema());
    assertTrue(catalogue.jsonSchema().has("oneOf"));
}

@Test void stepEntryIncludesExampleYaml() {
    var catalogue = service.catalogue("foundational", "developer");
    assertFalse(catalogue.steps().isEmpty());
    for (var entry : catalogue.steps()) {
        assertNotNull(entry.exampleYaml(), "Missing example for " + entry.name());
    }
}

@Test void catalogueAcceptsNumericLevel() {
    var catalogue = service.catalogue("1", "developer");
    assertEquals("foundational", catalogue.level());
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Create StepCatalogue, StepEntry, ParameterSummary records**

- [ ] **Step 4: Add `catalogue(String, String)` to PlaybookApi**

```java
@PlatformQuery("Step catalogue filtered by level and trust context")
StepCatalogue catalogue(String level, String schema);
```

- [ ] **Step 5: Modify StepSchemaComposer.compose() to accept capabilities**

Add `Set<String> capabilities` parameter. Conditionally include structural keywords based on capabilities:
- `if/then/else`, `match/cases` → requires `control-flow`
- `parallel`, `race` → requires `concurrency`
- `invoke` → requires `modules`
- `select`, `pause`, `resume` → requires `orchestration`
- `block`, `try/catch/finally` → always included
- Decorator keys → requires `decorators`

Existing two-arg overload remains, delegating with all capabilities.

- [ ] **Step 6: Implement catalogue() in PlaybookBeans**

Build the filtered registry (trust first, then level). Iterate `filteredRegistry.availableActions()`, build `StepEntry` for each with parameter summaries and example YAML. Call `StepSchemaComposer.compose(filteredRegistry, mapper, level.capabilities())`. Return `StepCatalogue`.

Handle numeric level strings: try `Integer.parseInt()`, if successful use `resolveByOrdinal()`.

- [ ] **Step 7: Run tests to verify they pass**

- [ ] **Step 8: Run full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 9: Commit**

```
feat(#836): step catalogue API with level + trust filtering on PlaybookApi
```

### Task 6: Variant-aware StepSchemaComposer + APT processor

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepSchemaComposer.java`
- Modify: `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/StepPluginProcessor.java`
- Modify: `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/SchemaEmitter.java`
- Modify: `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/RegistryEmitter.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/StepSchemaComposerVariantTest.java`
- Test: `yaml-plugin-processor/src/test/java/io/casehub/yaml/plugin/processor/VariantProcessorTest.java`

**Interfaces:**
- Consumes: `Definition.variants()` (Task 2), `@Variant` annotation (Task 2)
- Produces: Per-variant `oneOf` entries in composed JSON Schema, per-variant schema files in `META-INF/yaml-plugins/`

- [ ] **Step 1: Write tests for variant schema composition**

```java
@Test void variantDefinitionEmitsPerOperationOneOf() {
    var registry = new CompositePluginRegistry();
    registry.register(Definition.of("device")
        .absorbSiblings(true)
        .variant("register", Map.of("name", Parameter.required(ParameterType.STRING)))
        .variant("query", Map.of("id", Parameter.required(ParameterType.STRING)))
        .execute((p,s) -> Result.of(Map.of()))
        .build());

    var schema = StepSchemaComposer.compose(registry, new ObjectMapper(), Set.of("steps"));
    var oneOf = schema.get("oneOf");
    
    boolean hasRegister = false, hasQuery = false;
    for (var variant : oneOf) {
        if (variant.has("properties")) {
            if (variant.get("properties").has("device register")) hasRegister = true;
            if (variant.get("properties").has("device query")) hasQuery = true;
        }
    }
    assertTrue(hasRegister, "Missing 'device register' variant");
    assertTrue(hasQuery, "Missing 'device query' variant");
}

@Test void nonVariantDefinitionEmitsFlatSchema() {
    var registry = new CompositePluginRegistry();
    registry.register(Definition.of("log")
        .execute((p,s) -> Result.of(Map.of()))
        .build());

    var schema = StepSchemaComposer.compose(registry, new ObjectMapper(), Set.of("steps"));
    var oneOf = schema.get("oneOf");
    
    boolean hasLog = false;
    for (var variant : oneOf) {
        if (variant.has("properties") && variant.get("properties").has("log")) hasLog = true;
    }
    assertTrue(hasLog);
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement variant-aware StepSchemaComposer**

In the action iteration loop: when `definition.variants()` is non-empty, emit one `oneOf` entry per variant with key `"<plugin-name> <operation>"` and per-variant required fields. When empty, emit the existing flat schema (unchanged).

- [ ] **Step 4: Write APT processor test for @Variant inner records**

Create a test fixture plugin with `@Variant` inner records and verify the processor generates variant metadata in the manifest and per-variant schema files.

- [ ] **Step 5: Implement @Variant scanning in StepPluginProcessor**

In the processing loop for `@Plugin` records, scan enclosed elements for `@Variant` annotations. Extract field names and `@Required`/`@Optional` from each inner record. Build variants map. Pass to `RegistryEmitter` and `SchemaEmitter`.

- [ ] **Step 6: Implement variant-aware SchemaEmitter**

When variants exist, emit per-variant JSON Schema files (`META-INF/yaml-plugins/<name>.<variant>.schema.json`). Update the base schema to reference variants.

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn -pl yaml-step-runtime,yaml-plugin-processor test -Dtest=StepSchemaComposerVariantTest,VariantProcessorTest --batch-mode`
Expected: all PASS

- [ ] **Step 8: Run full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 9: Commit**

```
feat(#836): variant-aware StepSchemaComposer + APT processor for @Variant
```

---

## Batch 4: Trust gating + LLM suggestions layer 3

Runtime enforcement and optional LLM-powered fix suggestions.

### Task 7: MVEL + env-access trust gating

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/PlaybookRunnerCore.java` (run path, not validate path)
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/runner/TrustGatingTest.java`

**Interfaces:**
- Consumes: `PlaybookCapabilities.EXPRESSION_MVEL`, `PlaybookCapabilities.ENV_ACCESS`, `SchemaFilteredRegistry`, `PlaybookSchemaRegistry.effectiveCapabilities()`
- Produces: Runtime enforcement — MVEL engine excluded under `assisted`, env/systemProperty sources excluded under `assisted`

- [ ] **Step 1: Write tests for trust gating**

```java
@Test void mvelExcludedUnderAssisted() {
    var schemaRegistry = new MapPlaybookSchemaRegistry();
    var caps = schemaRegistry.effectiveCapabilities("assisted");
    assertFalse(caps.contains(PlaybookCapabilities.EXPRESSION_MVEL));
}

@Test void envAccessExcludedUnderAssisted() {
    var schemaRegistry = new MapPlaybookSchemaRegistry();
    var caps = schemaRegistry.effectiveCapabilities("assisted");
    assertFalse(caps.contains(PlaybookCapabilities.ENV_ACCESS));
}

@Test void mvelIncludedUnderDeveloper() {
    var schemaRegistry = new MapPlaybookSchemaRegistry();
    var serverCaps = schemaRegistry.effectiveCapabilities("server");
    assertTrue(serverCaps.contains(PlaybookCapabilities.EXPRESSION_MVEL));
}
```

- [ ] **Step 2: Run tests to verify they pass**

These tests verify existing schema registry behavior. They should pass already.

- [ ] **Step 3: Add runtime gating in PlaybookRunnerCore.run()**

In the `run()` method, before building the expression engine registry and variable resolver chain, check the playbook's schema capabilities:
- If `EXPRESSION_MVEL` not in capabilities → skip MVEL engine registration
- If `ENV_ACCESS` not in capabilities → skip `VariableSource.env()` and `systemProperty()` registration

- [ ] **Step 4: Run full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```
feat(#836): runtime trust gating — MVEL + env-access enforcement under assisted
```

### Task 8: LLM suggestion layer 3 (optional)

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/PlaybookRunnerCore.java`
- Modify: `playbook-runner/src/main/java/io/casehub/yaml/test/quarkus/PlaybookBeans.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/runner/LlmSuggestionTest.java`

**Interfaces:**
- Consumes: `AgentProvider.invokeBlocking()` (from agent-api), `ValidationContext.llmSuggestions()`, `LlmFixResult`
- Produces: Populated `LlmFixResult` on `PlaybookValidationResult` when layer 3 is enabled and succeeds

- [ ] **Step 1: Write tests for LLM suggestion integration**

```java
@Test void llmSuggestionsNullWhenDisabled() {
    var core = buildTestRunner();
    Path playbook = writeTempPlaybook("- nonexistent: value\n");
    var result = core.validate(playbook, new ValidationContext("developer", null, false));
    assertNull(result.llmFix());
}

@Test void llmSuggestionsNullWhenNoAgentProvider() {
    var core = buildTestRunnerWithoutAgent();
    Path playbook = writeTempPlaybook("- nonexistent: value\n");
    var result = core.validate(playbook, new ValidationContext("assisted", null, true));
    assertNull(result.llmFix());
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement layer 3 in PlaybookRunnerCore.validate()**

After layers 1+2, if `ctx.llmSuggestions()`:
1. Look up `AgentProvider` from optional dependency (nullable field on `PlaybookRunnerCore`)
2. If absent → `llmFix = null`
3. Build a system prompt with the original YAML, diagnostics summary, and catalogue context
4. Call `agentProvider.invokeBlocking(config, Duration.ofSeconds(30))`
5. Parse the response for corrected YAML and explanation
6. Wrap in `LlmFixResult`
7. On timeout/error → `llmFix = null`

- [ ] **Step 4: Wire AgentProvider into PlaybookBeans**

Add optional `Instance<AgentProvider>` injection. Pass to `PlaybookRunnerCore` constructor. Read `llm-suggestions.enabled` and `timeout-seconds` from config.

- [ ] **Step 5: Run tests to verify they pass**

- [ ] **Step 6: Run full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 7: Commit**

```
feat(#836): optional LLM suggestion layer 3 with AgentProvider + timeout fallback
```

---

## Batch 5: Authoring metric

The measurement plugin in its own module.

### Task 9: yaml-metric-core module + AuthoringMetricPlugin

**Files:**
- Create: `yaml-metric-core/pom.xml`
- Create: `yaml-metric-core/src/main/java/io/casehub/yaml/metric/AuthoringMetricPlugin.java`
- Create: `yaml-metric-core/src/main/java/io/casehub/yaml/metric/AuthoringMetricResult.java`
- Modify: `pom.xml` (add module to reactor)
- Test: `yaml-metric-core/src/test/java/io/casehub/yaml/metric/AuthoringMetricPluginTest.java`

**Interfaces:**
- Consumes: `PlaybookApi.catalogue()` (Task 5), `PlaybookApi.validate()` (Task 4), `AgentProvider.invokeBlocking()`, `AgentProvider.openSession()`, `ServiceRegistry`
- Produces: `AuthoringMetricPlugin` step action registered as `authoring-metric`, `AuthoringMetricResult(boolean, List<YamlError>, String, String, String)`

- [ ] **Step 1: Create module pom.xml**

Dependencies: `yaml-plugin-api`, `yaml-step-runtime`, `agent-api` (compile), `yaml-test-core` (test), `junit-jupiter` (test). No quarkus:build goal.

- [ ] **Step 2: Write tests for AuthoringMetricPlugin**

```java
@Test void failsGracefullyWithoutAgentProvider() {
    var services = new MapServiceRegistry();
    // No AgentProvider registered
    var plugin = new AuthoringMetricPlugin("foundational", "Write a playbook that logs hello", true, "assisted");
    var result = plugin.run().execute(Map.of("level", "foundational", "task", "test"), services);
    assertFalse(result.isSuccess());
    assertTrue(((Result.Failure) result).message().contains("AgentProvider"));
}
```

- [ ] **Step 3: Run tests to verify they fail**

- [ ] **Step 4: Implement AuthoringMetricResult record**

```java
public record AuthoringMetricResult(
    boolean validationPassed,
    List<YamlError> diagnostics,
    String generatedYaml,
    String mode,
    String level) {}
```

- [ ] **Step 5: Implement AuthoringMetricPlugin**

`@Plugin("authoring-metric")` record with `@Execute` method that:
1. Looks up `PlaybookApi` and `AgentProvider` from `ServiceRegistry`
2. Calls `catalogue(level, schema)` for the step vocabulary
3. With-validator mode: opens agent session with validate tool
4. Without-validator mode: single-shot invoke with catalogue context
5. Captures generated YAML, validates via `PlaybookApi.validate()`
6. Returns `AuthoringMetricResult` wrapped in `Result.of()`

- [ ] **Step 6: Register definition via static factory**

```java
public static Definition definition() {
    return Definition.of("authoring-metric")
        .description("Measure LLM playbook authoring quality per level")
        .input("level", ParameterType.STRING, true)
        .input("task", ParameterType.STRING, true)
        .input("with-validator", ParameterType.BOOLEAN, false)
        .input("schema", ParameterType.STRING, false)
        .execute(new AuthoringMetricPlugin())
        .build();
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn -pl yaml-metric-core test --batch-mode`
Expected: all PASS

- [ ] **Step 8: Run full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 9: Commit**

```
feat(#836): yaml-metric-core module with AuthoringMetricPlugin
```

---

## References

- [2026-11-18-validator-mcp-tool-design.md](../specs/issue-836-validator-mcp-tool/2026-11-18-validator-mcp-tool-design.md) — design spec this plan implements
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/Walker.java` — step resolution, error collection target
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/PlaybookRunnerCore.java:186-204` — existing validate()
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/PlaybookValidationResult.java` — enrichment target
- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Definition.java` — variants field addition
- `yaml-core/src/main/java/io/casehub/yaml/core/error/YamlError.java` — Severity addition
- `yaml-core/src/main/java/io/casehub/yaml/core/playbook/SchemaFilteredRegistry.java` — pattern for LevelFilteredRegistry
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepSchemaComposer.java` — variant + level-aware composition
- `playbook-runner/src/main/java/io/casehub/yaml/test/quarkus/PlaybookBeans.java` — CDI wiring for PlaybookApi
- GitHub #836 — focal issue
