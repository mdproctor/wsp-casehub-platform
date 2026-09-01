# yaml-codegen: Unified Schema-Driven Code Generation

Refs: platform#258 (parent: engine#1018)

## Context

CaseHub repos hand-write Java types that mirror their JSON Schema definitions. The engine repo has 46 YAML record types in `io.casehub.api.model.converter.yaml` and a separate `codegen/` module that generates mutable POJOs via jsonschema2pojo into `io.casehub.model`. Both read the same `CaseDefinition.yaml` schema (1296 lines, 32 type definitions). When the schema changes, the records must be manually updated — drift risk grows as the YAML surface expands.

The engine's existing codegen proves jsonschema2pojo works as a schema parsing library with custom extensions (`CasehubRuleFactory`). The gap is output format: jsonschema2pojo's `JCodeModel` can only emit mutable POJOs, not Java records. No existing tool handles both full JSON Schema 2020-12 support (`$defs`, `oneOf`, `additionalProperties`) and Java record output.

## Solution

A new `yaml-codegen` Maven plugin module in `casehub-platform`, sibling to `yaml-core`. The plugin reads a JSON Schema once via jsonschema2pojo's parsing infrastructure and emits multiple output formats — `record` (Java records for YAML deserialization) and `pojo` (mutable POJOs, replacing engine's `codegen/` module). Future formats (TypeScript for engine#977) add as new backends.

## Module Structure

```
casehub-platform/
  yaml-core/          # existing — zero-dep YAML processing primitives
  yaml-codegen/       # new — schema-driven code generation
    pom.xml           # Maven plugin packaging, depends on jsonschema2pojo-core
    src/main/java/io/casehub/yaml/codegen/
      YamlCodegenMojo.java          # Maven plugin entry point
      SchemaParser.java             # jsonschema2pojo wrapper — schema → TypeGraph
      TypeGraph.java                # Parsed schema model (types, fields, refs)
      MappingConfig.java            # YAML mapping file model
      OutputFormat.java             # SPI: format → source files
      format/
        RecordEmitter.java          # record format backend
        PojoEmitter.java            # pojo format backend (wraps jsonschema2pojo JCodeModel)
```

## Plugin Configuration

```xml
<plugin>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-yaml-codegen-maven-plugin</artifactId>
    <version>${version.io.casehub.platform}</version>
    <executions>
        <execution>
            <phase>generate-sources</phase>
            <goals><goal>generate</goal></goals>
            <configuration>
                <schemaFile>${project.basedir}/src/main/resources/schema/CaseDefinition.yaml</schemaFile>
                <outputs>
                    <output>
                        <format>pojo</format>
                        <targetPackage>io.casehub.model</targetPackage>
                        <ruleFactory>io.casehub.codegen.CasehubRuleFactory</ruleFactory>
                    </output>
                    <output>
                        <format>record</format>
                        <targetPackage>io.casehub.api.model.converter.yaml</targetPackage>
                        <prefix>Yaml</prefix>
                        <mappingsFile>${project.basedir}/src/main/resources/schema/record-mappings.yaml</mappingsFile>
                    </output>
                </outputs>
            </configuration>
        </execution>
    </executions>
    <!-- Consumer-provided RuleFactory must be on plugin classpath -->
    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-engine-codegen</artifactId>
            <version>${version.io.casehub.engine}</version>
        </dependency>
    </dependencies>
</plugin>
```

**Classloader constraint (POJO format):** The `ruleFactory` class is loaded by the Maven plugin classloader. Consumer-provided rule factories must be declared as `<dependencies>` inside the `<plugin>` block — they are NOT resolved from the project's compile classpath.

## Mapping File Schema

The mapping file (`record-mappings.yaml`) declares per-type, per-field overrides for the record output format. It is overrides-only — unmapped fields are inferred from the JSON Schema type (see Default Type Mapping below).

```yaml
# record-mappings.yaml
globalAnnotations:
  - "com.fasterxml.jackson.annotation.JsonIgnoreProperties(ignoreUnknown = true)"

types:
  Binding:
    fields:
      on:
        type: io.casehub.api.model.Trigger
        deserializer: io.casehub.api.model.converter.deser.TriggerDeserializer
      when:
        type: io.casehub.platform.api.expression.ExpressionEvaluator
      inputProjectionOverride:
        type: io.casehub.platform.api.expression.ExpressionEvaluator
      replanHint:
        alias: replanAfter
      humanTask:
        type: io.casehub.api.model.converter.yaml.YamlHumanTaskTarget
      judgment:
        type: io.casehub.api.model.converter.yaml.YamlJudgmentTarget
      subCase:
        type: io.casehub.api.model.converter.yaml.YamlSubCaseTarget
      recoveryOverride:
        type: io.casehub.api.model.converter.yaml.YamlRecoveryOverride

  Worker:
    fields:
      doBlock:
        jsonProperty: "do"
        type: com.fasterxml.jackson.databind.JsonNode

  CaseDefinitionSpec:
    fields:
      completion:
        type: io.casehub.api.model.CaseCompletion
        deserializer: io.casehub.api.model.converter.deser.CaseCompletionDeserializer
      cbrConfig:
        alias: cbr
        type: io.casehub.api.model.cbr.CbrConfig
        deserializer: io.casehub.api.model.converter.deser.CbrConfigDeserializer
      adaptationConfig:
        alias: adaptation
        type: io.casehub.api.model.AdaptationConfig
        deserializer: io.casehub.api.model.converter.deser.AdaptationConfigDeserializer
      reflectionTrigger:
        alias: reflection
      actions:
        alias: goapActions

  Capability:
    fields:
      inputProjection:
        alias: inputSchema
      outputProjection:
        alias: outputSchema

  Goal:
    fields:
      when:
        alias: condition
        type: io.casehub.platform.api.expression.ExpressionEvaluator

  Milestone:
    fields:
      when:
        alias: [condition, completionCriteria]
        type: io.casehub.platform.api.expression.ExpressionEvaluator

  SubCase:
    fields:
      inputMapping:
        type: io.casehub.api.model.SubCaseMapping
        deserializer: io.casehub.api.model.converter.deser.SubCaseMappingDeserializer
      outputMapping:
        type: io.casehub.api.model.SubCaseMapping
        deserializer: io.casehub.api.model.converter.deser.SubCaseMappingDeserializer

  JudgmentTarget:
    fields:
      escalationStrategy:
        alias: escalatorStrategy
```

### Mapping File Fields

| Field | Effect on generated record |
|-------|---------------------------|
| `type` | Override the Java type for this component (fully qualified class name) |
| `deserializer` | Add `@JsonDeserialize(using = X.class)` |
| `alias` | Add `@JsonAlias("X")` or `@JsonAlias({"X", "Y"})` for arrays |
| `jsonProperty` | Add `@JsonProperty("X")` and rename the component |
| `skip` | Omit this field from the generated record |

### Additional Fields (schema-incomplete types)

When the JSON Schema doesn't include all fields that the YAML deserialization layer needs (e.g., engine's `Worker` type has `agent`, `react`, `a2a`, `mcp` fields not in the schema), the mapping file declares them alongside override fields. Any mapping entry whose key doesn't match a schema property name (and isn't a `jsonProperty` of a schema property) is treated as an additional field and appended to the generated record after the schema-derived fields. The `type` field is required for additional fields (no schema type to infer from); it defaults to `JsonNode` if omitted.

### `globalAnnotations`

Class-level annotations applied to every generated record. The default includes `@JsonIgnoreProperties(ignoreUnknown = true)`.

## Default Type Mapping

Unmapped fields are inferred from the JSON Schema type. No mapping file entry is needed for standard types.

| JSON Schema | Java type |
|------------|-----------|
| `type: string` | `String` |
| `type: integer` | `Integer` |
| `type: number` | `Double` |
| `type: boolean` | `Boolean` |
| `type: array` + `items: { type: string }` | `List<String>` |
| `type: array` + `items: { $ref: X }` | `List<YamlX>` (prefixed) |
| `type: object` + `properties: {...}` | `YamlX` (prefixed, generated as a record) |
| `type: object` + `additionalProperties: { type: string }` | `Map<String, String>` |
| `type: object` + `additionalProperties: { $ref: X }` | `Map<String, YamlX>` |
| `type: object` + `additionalProperties: true` | `Map<String, Object>` |
| `$ref: "#/$defs/X"` | `YamlX` (prefixed, unless overridden in mapping) |
| `oneOf` / polymorphic | `JsonNode` (unless overridden in mapping) |

The `prefix` config (default `"Yaml"`) is prepended to generated record type names. `$ref` targets and `items.$ref` targets receive the same prefix unless overridden. Types declared in `$defs` that are only referenced by overridden fields (where the mapping specifies an external type) are not generated.

## Record Generation Rules

For each `$defs` type in the schema that is not suppressed by mappings:

1. **Class declaration**: `public record YamlX(components...) {`
2. **Components**: one per schema property, ordered as declared in the schema
3. **Compact constructor**: null-checks for `List` and `Map` components — assigns `List.of()` or `Map.of()` when null
4. **Annotations**: `@JsonIgnoreProperties(ignoreUnknown = true)` on every record (from `globalAnnotations`). Per-field annotations from the mapping file.
5. **Imports**: computed from component types and annotations — only imports that are actually used
6. **License header**: standard Apache 2.0 header with `Copyright 2026-Present The Case Hub Authors`
7. **Package**: from `targetPackage` config

### Inline Object Types

Schema properties with inline `type: object` + `properties` (not a `$ref`) generate a nested record type or a top-level type depending on depth. The engine schema uses inline objects for `reflection`, `monitoring`, `planningConstraints`, etc. inside `CaseDefinitionSpec`. These generate standalone records (e.g., `YamlMonitoringConfig`, `YamlReflectionTriggerConfig`) because the hand-written types already follow this pattern.

### Handling `unevaluatedProperties`

JSON Schema 2020-12 uses `unevaluatedProperties: false` where Draft-07 used `additionalProperties: false`. jsonschema2pojo does not enforce this keyword. The generator ignores it — `@JsonIgnoreProperties(ignoreUnknown = true)` on every record provides the same lenient behavior.

## POJO Generation Rules

The `pojo` format delegates entirely to jsonschema2pojo's standard pipeline:

1. Parse schema via `SchemaMapper` with consumer-provided `RuleFactory`
2. Generate via `JCodeModel`
3. Write to `targetPackage` in `target/generated-sources/yaml-codegen/`

This is functionally identical to the current `exec-maven-plugin` + `CasehubCodegen` approach, packaged as a plugin goal instead of a standalone `main()` class.

## Generated Source Directory

All outputs write to `target/generated-sources/yaml-codegen/`. The plugin calls `project.addCompileSourceRoot()` to register this directory with Maven.

## Validation

After generation, the consuming repo's existing test suite must pass without modification. For the engine, that means:
- `CaseDefinitionYamlMapperTest` (239 tests) passes with generated records replacing hand-written ones
- `CaseDefinitionDeserializationTest` passes with generated POJOs replacing current generated POJOs
- No compile errors from generated code

## Engine Migration (consumer-side, separate issue)

After the plugin is built and published:
1. Engine adds `casehub-yaml-codegen-maven-plugin` to `schema/pom.xml`
2. Engine deletes `codegen/` module (CasehubCodegen, CasehubRuleFactory move to `schema/` as plugin dependencies)
3. Engine deletes 46 hand-written records in `api/.../converter/yaml/`
4. Engine removes `exec-maven-plugin` from `schema/pom.xml`
5. Run full test suite — 239 mapper tests validate field compatibility

This migration is tracked by engine#1018.

## References

- engine `codegen/CasehubCodegen.java` — existing POJO generator entry point
- engine `codegen/CasehubRuleFactory.java` — custom jsonschema2pojo rules (Worker reuse, typed additionalProperties)
- engine `schema/src/main/resources/schema/CaseDefinition.yaml` — JSON Schema 2020-12 source
- engine `api/src/main/java/io/casehub/api/model/converter/yaml/*.java` — 46 hand-written records (the baseline to match)
- engine `api/src/main/java/io/casehub/api/model/converter/deser/*.java` — polymorphic deserializers (consumer-owned)
- [jsonschema2pojo#1405](https://github.com/joelittlejohn/jsonschema2pojo/issues/1405) — Java records feature request (open since 2022)
- [Cosium/json-schema-to-java-record](https://github.com/Cosium/json-schema-to-java-record) — alternative evaluated, lacks $defs/oneOf support
- engine#977 — TypeScriptWriter (future third output format)
- engine#1015 — yaml-core record adoption (created the hand-written baseline)
