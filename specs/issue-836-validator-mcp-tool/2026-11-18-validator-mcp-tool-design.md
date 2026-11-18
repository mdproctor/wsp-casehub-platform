# Validator MCP tool + shaped plugin schemas + authoring metric — design spec

**Issue:** casehubio/platform#836
**Epic:** #827 — Playbook language direction (platform)
**Direction:** casehubio/parent#540 (LD-2, LD-3)
**Findings:** P31
**Prerequisite:** #830 (trust model — landed)
**Decisions:** [decisions.md](decisions.md)

## Problem

The playbook authoring surface lacks three things an LLM needs to author playbooks well:

1. **Structured validation feedback.** The current `validate()` returns `List<String>` — no location, no category, no suggestions. An LLM can't self-correct from "Step failed" without knowing where and why.

2. **Right-sized vocabulary.** The full step catalogue has hundreds of operations across all capability levels. An LLM writing a level-1 sequential playbook doesn't need to see orchestration primitives. The catalogue must be filtered by level and trust context.

3. **Precise schemas for shaped plugins.** A plugin with multiple operations (e.g., `speaker register: Alice` vs `speaker query: Bob`) currently has one flat schema with all fields optional. The LLM can't tell which fields are required for which operation.

## Design

### 1. Enriched validation pipeline (D1, D4)

Modify the Walker and `PlaybookRunnerCore.validate()` to collect structured diagnostics instead of catching exceptions and returning strings. The existing `ParseError` sealed hierarchy (`UnknownStepError`, `ParameterError`, `ExpressionParseError`, `StructureError`, `DuplicateStepError`) carries `SourceLocation` and `ErrorCategory`, but the Walker currently throws `IllegalArgumentException` with plain string messages at every error site. The Walker must be rewritten to accumulate `ParseError` subtypes via `YamlErrorCollector` instead of throwing immediately — this wires in the structured error hierarchy that was designed for this purpose but never connected.

#### `Severity` on `YamlError` (new, in `yaml-core`)

Add `Severity` to the existing `YamlError` sealed interface as a default method:

```java
public sealed interface YamlError permits ParseError, RuntimeStepError, CoordinationError {
    // ...existing methods...

    enum Severity { ERROR, WARNING }

    default Severity severity() { return Severity.ERROR; }
}
```

All existing subtypes default to ERROR. Walker modifications that produce warnings (e.g., "try without catch or finally") override `severity()` to return WARNING in the appropriate `ParseError` subtype.

No new parallel type (`ValidationDiagnostic`) is needed — `YamlError` already carries `category()`, `summary()`, `location()`, `toDetailMap()`, and now `severity()`. The sealed hierarchy gives callers compile-time access to typed detail fields (`stepName`, `referencedAction`, etc.) that a flattened `Map<String, Object>` discards.

#### New types in `yaml-step-runtime`

```java
public record ValidationSuggestion(
        int diagnosticIndex,
        String suggestion,
        String exampleYaml) {}
```

```java
public record LlmFixResult(
        String correctedYaml,
        String explanation,
        String model) {}
```

#### Enriched `PlaybookValidationResult`

```java
public record PlaybookValidationResult(
        boolean valid,
        List<YamlError> diagnostics,
        PlaybookFrontMatter frontMatter,
        List<ValidationSuggestion> suggestions,
        LlmFixResult llmFix) {}
```

The `valid` field stays for quick checks. `diagnostics` replaces the former `List<String> errors` with the existing `YamlError` sealed hierarchy — callers pattern-match on `ParseError` subtypes for typed access to detail fields. `suggestions` carries layers 1+2 (always present). `llmFix` carries layer 3 (nullable — only when LLM suggestions are enabled and succeed).

#### Three suggestion layers (D5)

| Layer | Source | Always | Content |
|-------|--------|--------|---------|
| 1 — Structural | `ValidationSuggestionGenerator` | Yes | Levenshtein did-you-mean for unknown steps, missing-required-param hints, type mismatch descriptions |
| 2 — Example-augmented | `Definition` from registry | Yes | Minimal YAML snippet showing correct usage of the suggested step |
| 3 — LLM-generated | `AgentProvider` | No — opt-in via `agent-config.yaml` | Corrected YAML + human-readable explanation of changes |

**Layer 3 execution model:** Layers 1+2 run synchronously as part of the Walker's error collection and suggestion generation. After layers 1+2 complete, if layer 3 is enabled, call `AgentProvider.invokeBlocking(config, Duration.ofSeconds(timeout))` — this collects the `Multi<AgentEvent>` stream and awaits with the configured timeout (default 30s). On timeout or failure, `llmFix` is null and the layers 1+2 result is returned unaffected.

**Layer 3 configuration:**

```yaml
# In agent-config.yaml
casehub:
  playbook:
    validator:
      llm-suggestions:
        enabled: true
        timeout-seconds: 30
```

#### Validation context

The current `validate(Path)` signature has no way to carry the schema context. Add a `ValidationContext` record and an overloaded method:

```java
public record ValidationContext(
        String schema,          // "assisted" or "developer", default "developer"
        String level,           // optional level name for catalogue-aware validation
        boolean llmSuggestions) {} // layer 3 enabled?
```

```java
// New overload — the original delegates with developer defaults
public PlaybookValidationResult validate(Path playbookPath) {
    return validate(playbookPath, new ValidationContext("developer", null, false));
}

public PlaybookValidationResult validate(Path playbookPath, ValidationContext ctx) { ... }
```

The `PlaybookApi.validate(String playbookPath)` MCP interface retains its single-argument signature — the only consumer is the MCP tool, which always validates in `assisted` context. `PlaybookBeans.validate()` constructs `ValidationContext("assisted", null, llmEnabled)` internally and passes a `SchemaFilteredRegistry.forSchema(registry, schemas, "assisted")` to the core method. If CLI/developer validation with schema context is needed later, a second MCP method `validate(String playbookPath, String schema)` can be added.

#### Walker modification — structured error collection

The Walker currently throws `IllegalArgumentException` with plain string messages at every error site (~30 locations in `resolveOne()`). Modify the Walker to accept a `YamlErrorCollector` parameter and accumulate `ParseError` subtypes instead of throwing:

- `throw new IllegalArgumentException("unknown key '" + key + "'")` becomes `collector.add(new ParseError.UnknownStepError(stepName, key, location, null))`
- `throw new IllegalArgumentException("duplicate step name '" + name + "'")` becomes `collector.add(new ParseError.DuplicateStepError(name, location, null))`
- Structural errors (empty step, ambiguous keys, missing companions) become `ParseError.StructureError`
- `LOG.warning("try without catch or finally")` becomes a `ParseError.StructureError` with `Severity.WARNING`

The Walker continues processing after non-fatal errors (unknown keys, duplicate names) to collect multiple diagnostics in a single pass. Fatal errors (maximum nesting depth exceeded, ambiguous structural type + action) still terminate resolution of that step but do not prevent processing subsequent steps.

A new `Walker.resolve()` overload accepts the collector:

```java
public static List<ResolvedStep> resolve(
        List<Map<String, Object>> steps, PluginRegistry registry,
        AnnotationMap annotations, YamlErrorCollector collector) {
    // accumulate errors into collector instead of throwing
}
```

The original throwing overloads remain for backward compatibility with the runtime execution path, where `IllegalArgumentException` is the expected failure mode.

#### `ResolvedStep.ErrorStep` — sentinel for errored steps

When a non-fatal error prevents step resolution (unknown action, ambiguous keys), the Walker collects the diagnostic and returns a sentinel `ErrorStep` to preserve index alignment between the YAML step list and the `List<ResolvedStep>`:

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

This ensures `ValidationSuggestion.diagnosticIndex` correlates with YAML positions. The runtime throwing path never produces `ErrorStep` — it throws instead — so existing callers are unaffected. Callers that traverse `List<ResolvedStep>` (e.g., the compiler, the evaluator) skip `ErrorStep` or handle it explicitly.

#### Bare-list enforcement (D10)

The `steps:` wrapper key is rejected — a bare YAML list is the only valid step container. The simplest valid playbook is:

```yaml
- log: hello
- log: world
```

The validator checks for `steps:` as a top-level key in the content map and produces a structural error:

```java
if (content.containsKey("steps")) {
    collector.add(new ParseError.StructureError(
        null,
        "Remove the 'steps:' wrapper — use a bare list instead",
        location, null));
}
```

This applies to the validator (assisted context). The runtime parser (`PlaybookParser`) continues to accept both forms for backward compatibility with existing developer playbooks — the migration is driven by the validator rejecting it, not the parser breaking.

All catalogue example YAML and authoring metric examples use the bare-list form exclusively.

#### Validation implementation

`PlaybookRunnerCore.validate(Path, ValidationContext)` implementation:

1. Parse YAML via `PlaybookParser.parse()` — unchanged
2. Expand imports — unchanged
3. Check for `steps:` key in content — if present, add a structural error to the collector (D10)
4. Extract step list from content (bare list from document 3, or from `steps:` key with the error already recorded)
5. Build a `PluginRegistry` filtered by schema context (`SchemaFilteredRegistry.forSchema()`), then by level if `ctx.level()` is non-null (`LevelFilteredRegistry.forLevel()`)
6. Call `Walker.resolve(steps, filteredRegistry, annotations, collector)` — the collector accumulates `ParseError` subtypes instead of throwing
7. Run `ValidationSuggestionGenerator` over collected diagnostics to produce layer 1+2 suggestions
8. If `ctx.llmSuggestions()`, call `AgentProvider.invokeBlocking(config, Duration.ofSeconds(timeout))` with the diagnostics, original YAML, and catalogue context
9. Return enriched `PlaybookValidationResult` with `collector.errors()` as diagnostics

### 2. Step catalogue API (D2, D6, D9)

New query on `PlaybookApi`:

```java
@PlatformQuery("Step catalogue filtered by level and trust context")
StepCatalogue catalogue(String level, String schema);
```

#### `StepCatalogue` record

```java
public record StepCatalogue(
        String level,
        String schema,
        List<StepEntry> steps,
        ObjectNode jsonSchema) {}
```

#### `StepEntry` record

```java
public record StepEntry(
        String name,
        String description,
        String capability,
        Map<String, ParameterSummary> inputs,
        String exampleYaml) {}
```

```java
public record ParameterSummary(
        ParameterType type,
        boolean required,
        String description) {}
```

#### Filter composition

Trust filtering is applied first, then level filtering. This prevents a high-level query from re-exposing capabilities that the trust context excludes.

```java
var trustFiltered = SchemaFilteredRegistry.forSchema(registry, schemas, schema);
var levelFiltered = LevelFilteredRegistry.forLevel(trustFiltered, levelRegistry, levelName);
var level = levelRegistry.resolveOrThrow(levelName);
var jsonSchema = StepSchemaComposer.compose(levelFiltered, mapper, level.capabilities());
```

#### Named level registry (D9)

Levels are `PlaybookLevel` records registered in a `PlaybookLevelRegistry`, following the same pattern as `PlaybookSchemaRegistry`.

```java
public record PlaybookLevel(String name, int ordinal, Set<String> capabilities) {}

public interface PlaybookLevelRegistry {
    void register(PlaybookLevel level);
    Optional<PlaybookLevel> resolve(String name);
    Optional<PlaybookLevel> resolveByOrdinal(int ordinal);
    List<PlaybookLevel> all();

    default PlaybookLevel resolveOrThrow(String name) {
        return resolve(name).orElseThrow(() ->
                new IllegalArgumentException("Unknown playbook level: '" + name + "'"));
    }
}
```

New class `MapPlaybookLevelRegistry` (in `yaml-core`) with five built-in levels:

| Name | Ordinal | Capabilities |
|------|---------|-------------|
| `foundational` | 1 | `steps`, `variable-resolution`, `control-flow` |
| `basic-patterns` | 2 | + `decorators` |
| `intermediate` | 3 | + `concurrency`, `modules` |
| `advanced` | 4 | + `orchestration`, `correlation`, `state-machine` |
| `expert` | 5 | + all remaining (`mcp-invoke`, `graphql-invoke`, `codegen`) |

`foundational` includes `variable-resolution` and `control-flow` because these are essential for any non-trivial playbook — `${variables}` and `if:` conditions are fundamental syntax, not advanced features. This aligns with `SHARED_CAPABILITIES` in `MapPlaybookSchemaRegistry`, which includes both. Capabilities like `concurrency` and `state-machine` are genuinely complex and belong at higher levels despite being shared across schemas.

Each level includes all capabilities from lower levels. Level ordinal provides backward compatibility with existing `meta.level: 1` metadata in playbook YAML — `resolveByOrdinal(1)` returns `foundational`. The catalogue API accepts both forms: when the `level` parameter is numeric, it calls `resolveByOrdinal`; otherwise `resolve` by name. The `ValidatePlaybookPlugin` directory-mode meta check uses `resolveByOrdinal` to map existing integer metadata to named levels.

#### `LevelFilteredRegistry`

New class in `yaml-core`, same delegation pattern as `SchemaFilteredRegistry`:

```java
public final class LevelFilteredRegistry implements PluginRegistry {

    public static LevelFilteredRegistry forLevel(
            PluginRegistry delegate,
            PlaybookLevelRegistry levels,
            String levelName) {
        PlaybookLevel level = levels.resolveOrThrow(levelName);
        return new LevelFilteredRegistry(delegate, level.capabilities());
    }
}
```

#### `StepSchemaComposer` — level-aware structural keywords

`StepSchemaComposer.compose()` gains a `Set<String> capabilities` parameter. Structural keywords are conditionally included based on capabilities:

| Structural keyword | Capability required |
|-------------------|-------------------|
| `block` | always (sequential grouping) |
| `if`/`then`/`else`, `match`/`cases` | `control-flow` |
| `try`/`catch`/`finally` | always (error handling) |
| `parallel`, `race`, `barrier`, `quorum` | `concurrency` |
| `invoke` | `modules` |
| `select`, `pause`, `resume` | `orchestration` |

Decorator keys (`for-each`, `retry`, `timeout`, `when`, etc.) are included when `decorators` is in the capability set. The `at`, `on-complete`, `resource`, `priority`, `cancel`, `background` shared properties are always included.

```java
public static ObjectNode compose(PluginRegistry registry, ObjectMapper mapper,
                                  Set<String> capabilities) {
    // ...existing action schema generation (already filtered by registry)...
    // structural keywords conditional on capabilities
    if (capabilities.contains("concurrency")) {
        // emit parallel, race, barrier, quorum schemas
    }
    if (capabilities.contains("modules")) {
        // emit invoke schema
    }
    // ...etc
}
```

The filter composition becomes:

```java
var trustFiltered = SchemaFilteredRegistry.forSchema(registry, schemas, schema);
var levelFiltered = LevelFilteredRegistry.forLevel(trustFiltered, levelRegistry, levelName);
var level = levelRegistry.resolveOrThrow(levelName);
var jsonSchema = StepSchemaComposer.compose(levelFiltered, mapper, level.capabilities());
```

### 3. Variant schema generation — P31 (D3)

#### Problem

A shaped plugin with `absorbSiblings = true` and multiple operations (e.g., `speaker register`, `speaker query`) currently produces one flat JSON Schema with all fields optional. The LLM can't distinguish which fields are required per operation.

#### `Definition` extension

Add an optional `variants` field to `Definition`:

```java
public record Definition(
        String name,
        String description,
        Map<String, Parameter> inputs,
        Map<String, Parameter> outputs,
        Portability portability,
        Action action,
        String capability,
        Optional<StreamingTypeInfo> streamingType,
        boolean absorbSiblings,
        Map<String, Map<String, Parameter>> variants) {}  // new — keyed by operation name
```

When `variants` is non-empty, the plugin has per-operation parameter sets. When empty (default), `inputs` applies as-is.

Add `variants` to the canonical constructor with a default of `Map.of()` in the compact constructor. Fix existing callers (7-arg, 8-arg, 9-arg convenience constructors and direct instantiations) mechanically — breaking changes cost nothing on this platform.

Builder extension:

```java
public Builder variant(String operation, Map<String, Parameter> params)
```

#### `@Variant` annotation

New annotation in `yaml-plugin-api` for APT-based variant declaration:

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
public @interface Variant {
    String value();  // operation name
}
```

Usage — inner records within a `@Plugin` record (illustrative example):

```java
@Plugin(value = "device", absorbSiblings = true)
public record DevicePlugin(String operation, ...) {

    @Variant("register")
    public record Register(@Required String name, @Optional String location) {}

    @Variant("query")
    public record Query(@Required String id) {}

    @Execute
    public Result run() { ... }
}
```

**Variant schemas are catalogue-only, not runtime-enforced.** The Walker's combined-key mechanism (`device register: Alice`) maps `register` to the primaryInput key and `Alice` to `_value` — it does not perform per-variant parameter validation. Variant schemas describe the expected parameter sets for each operation in the JSON Schema and catalogue, enabling LLMs to generate correct YAML. Runtime parameter validation is a separate concern handled by the plugin's `@Execute` method.

#### APT processor changes

`StepPluginProcessor` discovers `@Variant` inner records within a `@Plugin` class:

1. Scan enclosed elements for `@Variant` annotations
2. Extract field names and `@Required`/`@Optional` from each variant record
3. Build the `variants` map (operation name → parameter map)
4. Pass to `RegistryEmitter` and `SchemaEmitter`

`SchemaEmitter` gains a variant-aware path: when variants exist, emit per-variant JSON Schema files (`META-INF/yaml-plugins/<name>.<variant>.schema.json`) alongside the base schema.

#### `StepSchemaComposer` changes

When a `Definition` has non-empty `variants`, emit per-variant `oneOf` entries instead of one flat entry:

```json
{
  "oneOf": [
    {
      "properties": {
        "device register": {
          "type": "object",
          "properties": { "name": {"type": "string"}, "location": {"type": "string"} },
          "required": ["name"]
        }
      },
      "required": ["device register"]
    },
    {
      "properties": {
        "device query": {
          "type": "object",
          "properties": { "id": {"type": "string"} },
          "required": ["id"]
        }
      },
      "required": ["device query"]
    }
  ]
}
```

The variant key is `"<plugin-name> <operation>"` matching the Walker's combined-key format (`device register: Alice`).

#### Builder API fallback

Plugins not using APT register variants via the builder:

```java
Definition.of("device")
    .absorbSiblings(true)
    .variant("register", Map.of("name", Parameter.required(STRING)))
    .variant("query", Map.of("id", Parameter.required(STRING)))
    .build();
```

### 4. Trust gating — MVEL + env-access (D7)

Completing the enforcement deferred from #830.

#### MVEL expression engine gating

MVEL is gated by the existing `EXPRESSION_MVEL` capability, which is excluded from the `assisted` schema's capability set. The `ExpressionEngineRegistry` interface is not modified — it has no schema context and shouldn't.

Expression engine type is a **deployment-time configuration**, not a per-expression inline prefix. `TypeAwareParamResolver.resolveExpression()` calls `engines.resolveDefault(ExpressionContext.PARAMETER)` to select the engine — there is no `${mvel:...}` syntax in the codebase. MVEL gating is therefore a **runtime enforcement concern**, following the same pattern as variable source gating:

```java
// When building the expression engine chain for playbook execution
if (schema.capabilities().contains(PlaybookCapabilities.EXPRESSION_MVEL)) {
    engineRegistry.register(mvelEngine);
}
// JQ and JEXL are always registered
engineRegistry.register(jqEngine);
engineRegistry.register(jexlEngine);
```

If a playbook executes under `assisted` context and the deployment's default engine for `CONDITION` or `PARAMETER` is MVEL, the runtime will fail with "No ExpressionEngine registered for type 'mvel'" — a clear error that surfaces the configuration conflict.

JQ (pure JSON transform, no side effects) and JEXL (sandboxed) remain available in both contexts.

#### Variable source gating

`VariableSource.env()` and `VariableSource.systemProperty()` are not registered in production today (only used in tests). This issue formalises that as explicit runtime policy: when building the `VariableResolver` chain for playbook execution, these sources are only registered when the `ENV_ACCESS` capability is present in the active schema's capability set.

```java
if (schema.capabilities().contains(PlaybookCapabilities.ENV_ACCESS)) {
    resolver.addSource(VariableSource.env());
    resolver.addSource(VariableSource.systemProperty());
}
```

This is a runtime enforcement concern, not a validation-path concern — the validation path does not build a `VariableResolver` chain (variable resolution happens at execution time, not parse time).

### 5. Authoring metric (D8)

#### `AuthoringMetricPlugin` in `yaml-metric-core`

The authoring metric plugin lives in a separate module (`yaml-metric-core`) rather than `yaml-test-core` to avoid adding an `agent-api` dependency to every playbook test consumer. Only test suites that explicitly opt into authoring metrics add `yaml-metric-core` to their classpath.

```java
@Plugin("authoring-metric")
public record AuthoringMetricPlugin(
        @Required String level,
        @Required String task,
        @Optional boolean withValidator,
        @Optional String schema) {}
```

Defaults: `withValidator = true`, `schema = "assisted"`.

#### Two modes (per TN-7)

| Mode | LLM receives | Measures |
|------|-------------|----------|
| `withValidator: true` | Catalogue at requested level (via `PlaybookApi.catalogue()`) + validator as a callable tool + example playbooks from lower levels | Language design + tooling quality combined |
| `withValidator: false` | YAML spec document + example playbooks from lower levels (no tool access, no catalogue) | Language design quality in isolation |

The difference isolates whether the language is learnable from documentation alone (without-validator) versus whether the tooling makes authoring reliable (with-validator).

#### Execution flow — registry-driven

1. Look up `PlaybookApi` from `ServiceRegistry`
2. Call `playbooks.catalogue(level, schema)` to get the `StepCatalogue` — step entries, parameter schemas, example YAML all from the registry
3. Look up `AgentProvider` from `ServiceRegistry` — if unavailable, return a failure result with a clear message (same pattern as `ValidatePlaybookPlugin`'s `TestExecutionContext` lookup: catch `IllegalArgumentException`)
4. **With-validator mode:** Open an agent session (`AgentProvider.openSession()`) with the validate tool registered. The LLM can iteratively generate, validate, and correct.
5. **Without-validator mode:** Single-shot invoke (`AgentProvider.invokeBlocking()`) with catalogue as context. No tool access.
6. Capture the generated YAML
7. Evaluate via `PlaybookApi.validate()` — structured diagnostics
8. Return `AuthoringMetricResult`

#### Result type

```java
public record AuthoringMetricResult(
        boolean validationPassed,
        List<YamlError> diagnostics,
        String generatedYaml,
        String mode,
        String level) {}
```

#### Test playbook structure

```yaml
---
playbook: "1.0"
schema: server
name: authoring-metric-level-1
---
meta:
  level: 1
  layer: metric
  teaches: "LLM authoring capability measurement"
---
tests:
  - name: "sequential logging with validator"
    - authoring-metric:
        level: foundational
        task: "Write a playbook that logs 'hello' then logs 'world'"
        with-validator: true
    - assertThat: ${result.validationPassed}
        equals: true

  - name: "sequential logging without validator"
    - authoring-metric:
        level: foundational
        task: "Write a playbook that logs 'hello' then logs 'world'"
        with-validator: false
    - assertThat: ${result.validationPassed}
        equals: true
```

#### CI integration

Tests with `meta.layer: metric` run in a separate CI job:
- Requires an LLM backend (AgentProvider)
- Non-deterministic — results are measurements, not pass/fail gates
- JUnit reports surface per-level pass rates
- Comparison between with/without-validator modes shows tooling value

## Module placement

| Component | Module | Rationale |
|-----------|--------|-----------|
| `PlaybookLevel`, `PlaybookLevelRegistry`, `MapPlaybookLevelRegistry` | `yaml-core` | Alongside `PlaybookSchemaRegistry` — same pattern |
| `LevelFilteredRegistry` | `yaml-core` | Alongside `SchemaFilteredRegistry` — same pattern |
| `YamlError.Severity` | `yaml-core` | On the existing sealed interface |
| `ValidationSuggestion`, `ValidationSuggestionGenerator` | `yaml-step-runtime` | Alongside `PlaybookValidationResult` |
| `LlmFixResult` | `yaml-step-runtime` | Part of validation result |
| `StepCatalogue`, `StepEntry`, `ParameterSummary` | `yaml-step-runtime` | Returned by `PlaybookApi.catalogue()` |
| `@Variant` annotation | `yaml-plugin-api` | Zero-dep, alongside `@Plugin` |
| Variant APT processing | `yaml-plugin-processor` | Alongside existing `StepPluginProcessor` |
| `Definition.variants` field | `yaml-plugin-api` | On the existing record |
| MVEL engine gating, env-access gating | `yaml-step-runtime` | Runtime enforcement under schema context |
| `ResolvedStep.ErrorStep` | `yaml-step-runtime` | Sentinel for errored steps in multi-error collection |
| `AuthoringMetricPlugin` | `yaml-metric-core` | Separate module — avoids `agent-api` dependency on `yaml-test-core` |

## References

- `PlaybookRunnerCore.java:186-204` — existing validate() method
- `Walker.java` — step resolution, currently throws `IllegalArgumentException` (~30 sites), to be modified for `YamlErrorCollector`
- `ParseError.java` — structured error model with SourceLocation (designed for Walker but never wired)
- `YamlError.java` — sealed interface: `ParseError`, `RuntimeStepError`, `CoordinationError`
- `YamlErrorCollector.java` — multi-error collection with `throwIfErrors()` → `YamlValidationException`
- `YamlErrorMapper.java` — runtime error mapping (not validation path, but shows the pattern)
- `SchemaFilteredRegistry.java` — trust filtering pattern reused for levels
- `PlaybookSchemaRegistry.java` / `MapPlaybookSchemaRegistry.java` — named registry pattern and `SHARED_CAPABILITIES`
- `StepSchemaComposer.java` — JSON Schema composition, extended for variants and level-awareness
- `Definition.java` — extended with variants field (uses `Optional<StreamingTypeInfo>`)
- `StepPluginProcessor.java` — APT extended for @Variant
- `PlaybookCapabilities.java` — capability constants mapped to levels
- `TypeAwareParamResolver.java` — expression resolution via `resolveDefault(ExpressionContext.PARAMETER)` (not inline prefix)
- `ExpressionContext.java` — deployment-time engine defaults (CONDITION→mvel, PARAMETER→mvel, TRANSFORM→jq, FILTER→jq)
- `AgentProvider.java` — `invoke()`, `invokeBlocking()`, `openSession()` for layers 3 and authoring metric
- `ValidatePlaybookPlugin.java` — existing pattern for safe `ServiceRegistry` lookup
- Trust model spec (`specs/issue-830-trust-model-playbook-authoring/2026-11-17-trust-model-design.md`) — deferred MVEL + env-access gating
- Issue #836 comment — WS-3 integration points
