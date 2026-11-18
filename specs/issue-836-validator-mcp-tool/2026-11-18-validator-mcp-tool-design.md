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

Modify `PlaybookRunnerCore.validate()` to collect structured diagnostics instead of catching exceptions and returning strings. The existing `ParseError` sealed hierarchy (`UnknownStepError`, `ParameterError`, `ExpressionParseError`, `StructureError`, `DuplicateStepError`) already carries `SourceLocation` and `ErrorCategory` — we surface what's already captured internally.

#### New types in `yaml-step-runtime`

```java
public record ValidationDiagnostic(
        Severity severity,
        ErrorCategory category,
        String message,
        SourceLocation location,
        Map<String, Object> detail,
        String yamlPath) {

    public enum Severity { ERROR, WARNING }
}
```

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
        List<ValidationDiagnostic> diagnostics,
        PlaybookFrontMatter frontMatter,
        List<ValidationSuggestion> suggestions,
        LlmFixResult llmFix) {}
```

The `valid` field stays for quick checks. `diagnostics` replaces the former `List<String> errors`. `suggestions` carries layers 1+2 (always present). `llmFix` carries layer 3 (nullable — only when LLM suggestions are enabled and succeed).

#### Three suggestion layers (D5)

| Layer | Source | Always | Content |
|-------|--------|--------|---------|
| 1 — Structural | `ValidationSuggestionGenerator` | Yes | Levenshtein did-you-mean for unknown steps, missing-required-param hints, type mismatch descriptions |
| 2 — Example-augmented | `Definition` from registry | Yes | Minimal YAML snippet showing correct usage of the suggested step |
| 3 — LLM-generated | `AgentProvider` | No — opt-in via `agent-config.yaml` | Corrected YAML + human-readable explanation of changes |

**Layer 3 timeout/fallback:** LLM suggestion is best-effort with a configurable timeout (default 30s). If the LLM times out or fails, `llmFix` is null and layers 1+2 still return. The validation result is never blocked by layer 3.

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

#### Validation implementation

`PlaybookRunnerCore.validate()` changes:

1. Parse YAML via `PlaybookParser.parse()` — unchanged
2. Expand imports — unchanged
3. Wrap `Walker.resolve()` in a try-catch that converts `ParseError` subtypes to `ValidationDiagnostic` records, preserving `SourceLocation`, `ErrorCategory`, and `toDetailMap()`
4. Run `ValidationSuggestionGenerator` over diagnostics to produce layer 1+2 suggestions
5. If layer 3 enabled, invoke `AgentProvider` asynchronously with the diagnostics, original YAML, and catalogue context — with timeout
6. Return enriched `PlaybookValidationResult`

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
var jsonSchema = StepSchemaComposer.compose(levelFiltered, mapper);
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
}
```

New class `MapPlaybookLevelRegistry` (in `yaml-core`) with five built-in levels:

| Name | Ordinal | Capabilities added |
|------|---------|-------------------|
| `foundational` | 1 | `steps` |
| `basic-patterns` | 2 | + `decorators`, `control-flow` |
| `intermediate` | 3 | + `concurrency`, `modules` |
| `advanced` | 4 | + `orchestration`, `correlation` |
| `expert` | 5 | + all remaining (mcp-invoke, graphql-invoke, codegen, state-machine) |

Each level includes all capabilities from lower levels. Level ordinal provides backward compatibility with existing `meta.level: 1` metadata in playbook YAML.

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
        Optional<StreamingType> streamingType,
        boolean absorbSiblings,
        Map<String, Map<String, Parameter>> variants) {}  // new — keyed by operation name
```

When `variants` is non-empty, the plugin has per-operation parameter sets. When empty (default), `inputs` applies as-is (backward compatible).

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

Usage — inner records within a `@Plugin` record:

```java
@Plugin(value = "speaker", absorbSiblings = true)
public record SpeakerPlugin(String operation, ...) {

    @Variant("register")
    public record Register(@Required String name, @Optional String voice) {}

    @Variant("query")
    public record Query(@Required String id) {}

    @Variant("deregister")
    public record Deregister(@Required String id) {}

    @Execute
    public Result run() { ... }
}
```

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
        "speaker register": {
          "type": "object",
          "properties": { "name": {"type": "string"}, "voice": {"type": "string"} },
          "required": ["name"]
        }
      },
      "required": ["speaker register"]
    },
    {
      "properties": {
        "speaker query": {
          "type": "object",
          "properties": { "id": {"type": "string"} },
          "required": ["id"]
        }
      },
      "required": ["speaker query"]
    }
  ]
}
```

The variant key is `"<plugin-name> <operation>"` matching the Walker's combined-key format (`speaker register: Alice`).

#### Builder API fallback

Plugins not using APT register variants via the builder:

```java
Definition.of("speaker")
    .absorbSiblings(true)
    .variant("register", Map.of("name", Parameter.required(STRING)))
    .variant("query", Map.of("id", Parameter.required(STRING)))
    .build();
```

### 4. Trust gating — MVEL + env-access (D7)

Completing the enforcement deferred from #830.

#### MVEL expression engine gating

The `ExpressionEngineRegistry` gains schema-context awareness. When the active schema is `assisted`, MVEL compilation is refused:

```java
// In ExpressionEngineRegistry.compile() or a wrapping decorator:
if ("assisted".equals(activeSchema) && "mvel".equals(type)) {
    throw new ExpressionCompilationException(
        "MVEL expressions are not available in assisted authoring context");
}
```

JQ (pure JSON transform, no side effects) and JEXL (sandboxed) remain available in both contexts.

The active schema is passed through the validation context. The validator sets it to `assisted`; CLI/developer workflows default to `developer`.

#### Variable source gating

When building the `VariableResolver` chain under `assisted` context, `VariableSource.env()` and `systemProperty()` are excluded from the chain:

```java
if (!"assisted".equals(activeSchema)) {
    resolver.addSource(VariableSource.env());
    resolver.addSource(VariableSource.systemProperty());
}
```

This formalises existing production behaviour (these sources aren't registered in production today) as explicit policy.

### 5. Authoring metric (D8)

#### `AuthoringMetricPlugin` in `yaml-test-core`

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
3. Look up `AgentProvider` from `ServiceRegistry`
4. **With-validator mode:** Open an agent session (`AgentProvider.openSession()`) with the validate tool registered. The LLM can iteratively generate, validate, and correct.
5. **Without-validator mode:** Single-shot invoke (`AgentProvider.invoke()`) with catalogue as context. No tool access.
6. Capture the generated YAML
7. Evaluate via `PlaybookApi.validate()` — structured diagnostics
8. Return `AuthoringMetricResult`

#### Result type

```java
public record AuthoringMetricResult(
        boolean validationPassed,
        List<ValidationDiagnostic> diagnostics,
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

tests:
  - name: "sequential logging with validator"
    steps:
      - authoring-metric:
          level: foundational
          task: "Write a playbook that logs 'hello' then logs 'world'"
          with-validator: true
      - assertThat: ${result.validationPassed}
          equals: true

  - name: "sequential logging without validator"
    steps:
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
| `ValidationDiagnostic`, `ValidationSuggestion`, `ValidationSuggestionGenerator` | `yaml-step-runtime` | Alongside `PlaybookValidationResult` |
| `LlmFixResult` | `yaml-step-runtime` | Part of validation result |
| `StepCatalogue`, `StepEntry`, `ParameterSummary` | `yaml-step-runtime` | Returned by `PlaybookApi.catalogue()` |
| `@Variant` annotation | `yaml-plugin-api` | Zero-dep, alongside `@Plugin` |
| Variant APT processing | `yaml-plugin-processor` | Alongside existing `StepPluginProcessor` |
| `Definition.variants` field | `yaml-plugin-api` | On the existing record |
| MVEL gating, env-access gating | `yaml-step-runtime` | Validation context wiring |
| `AuthoringMetricPlugin` | `yaml-test-core` | Test infrastructure |

## References

- `PlaybookRunnerCore.java:186-204` — existing validate() method
- `ParseError.java` — structured error model with SourceLocation
- `SchemaFilteredRegistry.java` — trust filtering pattern reused for levels
- `PlaybookSchemaRegistry.java` — named registry pattern for levels
- `StepSchemaComposer.java` — JSON Schema composition, extended for variants
- `Walker.java:343-351` — absorbSiblings logic
- `Definition.java` — extended with variants field
- `StepPluginProcessor.java` — APT extended for @Variant
- `PlaybookCapabilities.java` — capability constants mapped to levels
- Trust model spec (`specs/issue-830-trust-model-playbook-authoring/2026-11-17-trust-model-design.md`) — deferred MVEL + env-access gating
- Issue #836 comment — WS-3 integration points
