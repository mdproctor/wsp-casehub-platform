# Schema Generator Enhancements — Design Spec

**Issues:** casehubio/platform#280, #281, #282
**Date:** 2026-09-07
**Status:** Draft

## Summary

Three enhancements to platform's schema tooling:

1. **ShorthandModule** (#280) — generic victools module for scalar-or-object polymorphism in JSON Schema generation. Callers provide both scalar and object form schemas per type; the module wraps each pair in `oneOf`.

2. **yaml-codegen consolidation** (#282) — merge the best features of engine's `codegen/` into platform's existing `yaml-codegen/` Maven plugin, then engine drops its own codegen module.

3. **Drift detection** (#281) — Maven Enforcer custom rule that detects hand-written code in packages that should be generated, failing the build when drift is found.

## Part 1: ShorthandModule (#280)

### Problem

Multiple repos hand-build `oneOf: [scalar, object]` schemas for types that accept either a simple shorthand value or a full object form:

| Repo | Type | Scalar | Object |
|------|------|--------|--------|
| neocortex | `Confidence` | `0.85` (number, 0–1) | `{origin: STATED, value: 0.85}` |
| neocortex | `NodeRef` | `"scheme:id"` (string, pattern) | `{scheme: "...", id: "..."}` |
| neocortex | `RecurrenceRule` | `"FREQ=DAILY"` (string, pattern) | `{freq: DAILY, interval: 1}` |
| engine | `AdaptationConfig` | `"adaptive"` (string enum) | `{trigger: every-step, revision: forward-replan}` |
| engine | `CloudEventTrigger` | `"io.casehub.event.v1"` (string) | `{type: "...", source: "...", filter: ...}` |

Each repo implements this independently — neocortex via a hardcoded `ShorthandModule`, engine via hand-built methods in `SchemaPostProcessor`.

### Approach

Extract a generic, parameterized `ShorthandModule` to `casehub-platform-schema-generator`. Callers provide a `Map<Class<?>, ShorthandDefinition>` where each `ShorthandDefinition` supplies both the scalar-form schema and the object-form schema explicitly.

**Not** auto-derived: the decision review found that auto-derivation from Java types fails for most types — AdaptationConfig has YAML-only properties (`revision`) not on the Java type, CloudEventTrigger uses custom `$ref` names, Confidence/RecurrenceRule have validation constraints not expressed via Jakarta annotations.

**ExpressionEvaluator excluded:** its string-or-map pattern is structurally different from scalar-or-object (maps to multiple object forms via polymorphic dispatch, not a single object form). Stays as its own Module in engine.

### API

```java
package io.casehub.schema.generator.module;

public class ShorthandModule implements Module {

    public ShorthandModule(Map<Class<?>, ShorthandDefinition> definitions) { ... }

    @Override
    public void applyToConfigBuilder(SchemaGeneratorConfigBuilder builder) {
        builder.forTypesInGeneral()
            .withCustomDefinitionProvider((type, context) -> {
                ShorthandDefinition def = definitions.get(type.getErasedType());
                if (def == null) return null;
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

public interface ShorthandDefinition {
    ObjectNode scalarSchema(SchemaGeneratorConfig config);
    ObjectNode objectSchema(SchemaGeneratorConfig config);

    static ShorthandDefinition of(
            Function<SchemaGeneratorConfig, ObjectNode> scalar,
            Function<SchemaGeneratorConfig, ObjectNode> object) {
        return new ShorthandDefinition() {
            @Override public ObjectNode scalarSchema(SchemaGeneratorConfig config) {
                return scalar.apply(config);
            }
            @Override public ObjectNode objectSchema(SchemaGeneratorConfig config) {
                return object.apply(config);
            }
        };
    }
}
```

### Consumer usage

```java
// Neocortex — Confidence: number 0-1 OR full object
var gen = new PlatformSchemaGenerator(
    new ShorthandModule(Map.of(
        Confidence.class, ShorthandDefinition.of(
            config -> {
                ObjectNode s = config.createObjectNode();
                s.put("type", "number").put("minimum", 0).put("maximum", 1);
                return s;
            },
            config -> {
                ObjectNode o = config.createObjectNode();
                o.put("type", "object");
                ObjectNode props = o.putObject("properties");
                props.putObject("origin").put("type", "string");
                props.putObject("value").put("type", "number");
                o.putArray("required").add("origin").add("value");
                return o;
            }
        )
    ))
);
```

### Inclusion strategy

Opt-in via `PlatformSchemaGenerator`'s `Module... customModules` varargs. Not auto-included in the default set. Matches SealedHierarchyModule pattern.

### Module ordering

All three custom definition modules (`EnumInliningModule`, `SealedHierarchyModule`, `ShorthandModule`) register via `builder.forTypesInGeneral().withCustomDefinitionProvider()`. victools evaluates providers in registration order — **first non-null return wins**; remaining providers are not consulted for that type.

Registration order in `PlatformSchemaGenerator`:
1. `EnumInliningModule` (built-in, always first)
2. Custom modules in `Module... customModules` varargs order

**Type set invariant:** Each module returns `null` for types outside its domain — `EnumInliningModule` only intercepts `Enum.class` subtypes, `SealedHierarchyModule` only intercepts sealed types, `ShorthandModule` only intercepts types present in its explicit definition map. These type sets are naturally disjoint (Java enums cannot be sealed; shorthand types are explicitly registered by class). The consumer is responsible for not registering the same type in multiple modules.

**DefinitionType choice:** `ShorthandModule` uses `CustomDefinition.DefinitionType.STANDARD` (the default from `new CustomDefinition(schema)`). This follows standard victools behaviour — shorthand types are placed in `$defs` with `$ref` when referenced multiple times or when `DEFINITIONS_FOR_ALL_OBJECTS` is enabled (which `PlatformSchemaGenerator` enables). `EnumInliningModule` uses `INLINE` because enum schemas are small and should be expanded at each use site. `SealedHierarchyModule` uses `STANDARD` as its `oneOf` schemas contain `$ref` entries to subtypes.

### Test strategy

Local test types in the test package — no dependency on neocortex or engine types.

```java
// Test sealed types
record Price(double amount, String currency) {}
record Duration(int value, String unit) {}
```

Test cases:
1. Shorthand type generates `oneOf` with scalar and object forms
2. Scalar form matches caller-provided schema
3. Object form matches caller-provided schema
4. Non-shorthand types not intercepted
5. Multiple shorthand types in one module
6. Interaction with SealedHierarchyModule — both modules co-registered on the same `PlatformSchemaGenerator` with non-overlapping type sets: a sealed type NOT in the shorthand map, and a shorthand type that is NOT sealed. Verifies each module handles its own types correctly when both are active

### Files changed

| File | Action |
|------|--------|
| `schema-generator/src/main/java/io/casehub/schema/generator/module/ShorthandModule.java` | New |
| `schema-generator/src/main/java/io/casehub/schema/generator/module/ShorthandDefinition.java` | New |
| `schema-generator/src/test/java/io/casehub/schema/generator/module/ShorthandModuleTest.java` | New |

### Migration scope

Follow-up issues (not this branch):
- casehubio/neocortex#290: migrate from local `ShorthandModule` to shared, delete local copy
- casehubio/engine#1067: migrate hand-built `SchemaPostProcessor` methods to shared `ShorthandModule`

**Architectural note on engine migration:** Engine's `SchemaPostProcessor` (1661 lines) operates on already-generated JSON schemas — it's post-processing. It builds shorthand schemas as raw JSON (`buildCloudEventTrigger()`, `buildAdaptation()`, etc.) and patches them into `$defs` of the finished schema. `ShorthandModule` intercepts during schema generation via victools' `Module` interface — a fundamentally different mechanism. The engine migration requires: (1) identifying shorthand-pattern methods in `SchemaPostProcessor`, (2) creating `ShorthandDefinition` registrations, (3) verifying schema equivalence between early interception and late patching, (4) removing migrated methods while keeping non-shorthand post-processing intact. Engine's `SchemaDriftTest` (compares committed schema YAML against generator output) will catch regressions.

Migrating consumers must produce schema-equivalent output. Engine's `SchemaDriftTest` verifies equivalence.

---

## Part 2: yaml-codegen consolidation (#282)

### Problem

Platform has `yaml-codegen/` (Maven plugin, JSON Schema to Java records/POJOs). Engine has `codegen/` (CLI, JSON Schema to Java records). Both do the same thing with complementary strengths — platform has better schema parsing and field-level control, engine has better code generation flexibility.

### Approach

Merge best-of-both into yaml-codegen's `MappingConfig`. No new module — enhance the existing one.

### Gap analysis — features to add

**From engine `RecordMapping` → platform `MappingConfig`:**

| Engine feature | yaml-codegen equivalent | Action |
|---|---|---|
| `TypeMapping.recordName` | Class prefix only | Add `recordName` to `MappingConfig.TypeMapping` |
| `TypeMapping.body` | None | Add `body` field for arbitrary Java code injection |
| `FieldOverride.defaultValue` | None (only null-guards collections) | Add `defaultValue` to `MappingConfig.FieldMapping` |
| `ExtraField(name, type, defaultValue)` | `additionalFields` (no defaults) | Add `defaultValue` to additional fields |
| `RecordMapping.skipPatterns` | Per-field `skip` only | Add global `skipPatterns` list with prefix-star matching (exact match or trailing `*` wildcard) |
| `RecordMapping.imports` | Per-field FQN in `type` | Add global `imports` map (short name to FQN) |
| `RecordMapping.deserializers` | Per-field FQN in `deserializer` | Add global `deserializers` map (name to FQN) |

**Already in yaml-codegen (engine lacks):**
- `TypeGraph` with `required`, `description`, `additionalProperties` per type
- `JavaTypeResolver` as dedicated class
- Per-field `skip` boolean
- `globalAnnotations`
- `jsonProperty` bidirectional lookup
- POJO generation (via jsonschema2pojo)
- Maven Mojo integration

### MappingConfig changes

```java
public record MappingConfig(
    List<String> globalAnnotations,
    List<String> skipPatterns,           // NEW — prefix-star patterns
    Map<String, String> imports,         // NEW — type name → FQN
    Map<String, String> deserializers,   // NEW — deserializer name → FQN
    Map<String, TypeMapping> types) {

    public record TypeMapping(
        String recordName,               // NEW — explicit Java class name
        Map<String, FieldMapping> fields,
        List<FieldMapping> additionalFields,
        String body) {                   // NEW — arbitrary Java body code
    }

    public record FieldMapping(
        String name,
        String type,
        String deserializer,
        List<String> aliases,
        String jsonProperty,
        boolean skip,
        String defaultValue) {           // NEW — default value expression
    }
}
```

### RecordEmitter changes

- Compact constructor: generate null-guard for any field with `defaultValue` (not just collections)
- Body injection: append `TypeMapping.body` inside record body after compact constructor
- Skip patterns: apply global `skipPatterns` before per-field processing. Matching: exact match (`pattern.equals(fieldName)`) or trailing `*` wildcard (`pattern.endsWith("*")` → prefix match via `fieldName.startsWith(prefix)`). Matches engine's `RecordEmitter.shouldSkip()` semantics
- Import resolution: check global `imports` and `deserializers` maps when resolving FQNs
- Record name: use `TypeMapping.recordName` when present, falling back to schema name + prefix

### Test strategy

Extend existing `RecordEmitterTest` with:
1. `body` injection produces valid Java
2. `defaultValue` generates compact constructor null-guard
3. `skipPatterns` prefix-star matching works (exact, prefix-`*`)
4. Global `imports` map resolves short names to FQNs
5. Global `deserializers` map resolves deserializer FQNs
6. `recordName` overrides schema type name
7. Backward compatibility: existing tests still pass with no mapping changes

### Files changed

| File | Action |
|------|--------|
| `yaml-codegen/src/main/java/io/casehub/yaml/codegen/MappingConfig.java` | Modified — add new fields |
| `yaml-codegen/src/main/java/io/casehub/yaml/codegen/RecordEmitter.java` | Modified — body, defaultValue, skipPatterns |
| `yaml-codegen/src/main/java/io/casehub/yaml/codegen/JavaTypeResolver.java` | Modified — global imports resolution |
| `yaml-codegen/src/test/java/io/casehub/yaml/codegen/MappingConfigTest.java` | Modified — new field parsing |
| `yaml-codegen/src/test/java/io/casehub/yaml/codegen/RecordEmitterTest.java` | Modified — new feature tests |

### Migration path

Engine migration (follow-up issue on casehubio/engine):
1. Add `casehub-platform-yaml-codegen` plugin to engine's build
2. Translate `yaml-record-mappings.yaml` to yaml-codegen's expanded `MappingConfig` format
3. Verify generated records are identical (diff or compilation check)
4. Delete engine's `codegen/` module

---

## Part 3: Drift detection (#281)

### Problem

Without build-time enforcement, hand-written records bypass the codegen schema and drift accumulates. Engine has ~15 hand-written YAML records that should be generated. Need a generic mechanism that works with any codegen pipeline.

### Approach

Maven Enforcer custom rule in a new `drift-detection/` module. The enforcer plugin handles lifecycle, error reporting, and skip/fail configuration. Drift detection only inspects — it never writes files — so full Maven plugin packaging is over-engineered.

### API

Targets Maven Enforcer 3.x (stable). The rule implements `EnforcerRule` from `enforcer-api:3.5.0`.

```java
package io.casehub.platform.drift;

public class DriftDetectionRule implements EnforcerRule {

    private String generatedSourcesDir;
    private String sourceRoot;    // default: ${project.basedir}/src/main/java
    private String targetPackage;
    private String allowListFile;

    @Override
    public void execute(EnforcerRuleHelper helper) throws EnforcerRuleException {
        Log log = helper.getLog();
        Set<String> generated = scanGeneratedTypes(generatedSourcesDir);
        Set<String> handWritten = scanHandWrittenTypes(sourceRoot, targetPackage);
        AllowList allowList = loadAllowList(allowListFile);

        for (String entry : allowList.unjustified()) {
            log.warn("Allow-list entry '" + entry + "' has no justification comment");
        }

        Set<String> drift = new TreeSet<>(handWritten);
        drift.removeAll(generated);
        drift.removeAll(allowList.entries());

        if (!drift.isEmpty()) {
            throw new EnforcerRuleException(
                "Codegen drift detected — hand-written types in " + targetPackage
                + " not in generated output or allow-list:\n"
                + drift.stream().map(t -> "  - " + t).collect(joining("\n"))
                + "\n\nTo allow intentionally hand-written types, add them to "
                + allowListFile + " with a justification comment.");
        }
    }

    @Override public boolean isCacheable() { return false; }
    @Override public boolean isResultValid(EnforcerRule cachedRule) { return false; }
    @Override public String getCacheId() { return null; }
}
```

**Scanning mechanism:**
- `scanGeneratedTypes(generatedSourcesDir)`: lists `.java` files recursively under the directory, extracts simple class names from filenames (filtering `package-info.java`).
- `scanHandWrittenTypes(sourceRoot, targetPackage)`: resolves `targetPackage` to a directory path (`sourceRoot/<package as path>/`), lists `.java` files in that directory, extracts simple class names. This directly identifies hand-written source files — generated sources live under `target/generated-sources/`, not under `src/main/java/`.
- `loadAllowList(allowListFile)`: returns an `AllowList` record containing `entries()` (the set of allowed type names) and `unjustified()` (entries that lack a preceding `#` comment line). The parser treats any line starting with `#` as a justification comment for the next non-empty, non-comment line. `helper.getLog().warn(...)` emits warnings for unjustified entries — a nudge, not a failure.

### Configuration (consumer pom.xml)

```xml
<plugin>
    <groupId>org.apache.maven.plugins</groupId>
    <artifactId>maven-enforcer-plugin</artifactId>
    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-drift-detection</artifactId>
            <version>${casehub.version}</version>
        </dependency>
    </dependencies>
    <executions>
        <execution>
            <id>detect-codegen-drift</id>
            <goals><goal>enforce</goal></goals>
            <phase>process-classes</phase>
            <configuration>
                <rules>
                    <driftDetectionRule>
                        <generatedSourcesDir>${project.build.directory}/generated-sources/yaml-codegen</generatedSourcesDir>
                        <sourceRoot>${project.basedir}/src/main/java</sourceRoot>
                        <targetPackage>io.casehub.api.model.converter.yaml</targetPackage>
                        <allowListFile>src/main/resources/hand-written-exceptions.txt</allowListFile>
                    </driftDetectionRule>
                </rules>
            </configuration>
        </execution>
    </executions>
</plugin>
```

### Allow-list format

```
# Each entry requires a justification comment on the preceding line
# Manually optimized — codegen can't express the visitor pattern
WorkItemVisitor
# Legacy type — migration planned in engine#1058
CaseDefinitionLegacy
```

### Module structure

```
drift-detection/
  src/main/java/io/casehub/platform/drift/
    DriftDetectionRule.java          — EnforcerRule implementation
  src/test/java/io/casehub/platform/drift/
    DriftDetectionRuleTest.java      — unit tests with mock directories
  pom.xml                           — regular JAR, depends on enforcer-api:3.5.0 (provided scope)
```

### Test strategy

1. No drift — generated and hand-written sets match → no exception
2. Drift detected — hand-written class not in generated or allow-list → exception with class name
3. Allow-list works — hand-written class in allow-list → no exception
4. Allow-list justification — entries without preceding comment → warning (not failure)
5. Empty generated dir — all hand-written types flagged unless allow-listed
6. Missing allow-list file — treated as empty (no exceptions allowed)

### Files changed

| File | Action |
|------|--------|
| `drift-detection/pom.xml` | New — regular JAR, `enforcer-api:3.5.0` provided-scope dependency |
| `drift-detection/src/main/java/io/casehub/platform/drift/DriftDetectionRule.java` | New |
| `drift-detection/src/test/java/io/casehub/platform/drift/DriftDetectionRuleTest.java` | New |
| `pom.xml` (root) | Modified — add `drift-detection` module |

---

## Downstream issues

This branch does platform-side work only. Consumer migration is separate:

| Issue | Repo | Dependency |
|-------|------|------------|
| casehubio/neocortex#290 | casehubio/neocortex | Migrate ShorthandModule to shared (depends on Part 1) |
| casehubio/engine#1067 | casehubio/engine | Migrate SchemaPostProcessor shorthand methods to shared (depends on Part 1) |
| casehubio/engine#1068 | casehubio/engine | Migrate codegen/ to yaml-codegen plugin (depends on Part 2) |
| casehubio/engine#1069 | casehubio/engine | Add drift-detection enforcer rule (depends on Part 3) |

All downstream: engine epic casehubio/engine#1058.

## References

- `io.casehub.schema.generator.PlatformSchemaGenerator` — module composition entry point
- `io.casehub.schema.generator.module.SealedHierarchyModule` — parameterized module precedent
- `io.casehub.neocortex.schema.ShorthandModule` — source implementation (116 lines)
- `io.casehub.codegen.CasehubRecordCodegen` — engine codegen entry point
- `io.casehub.codegen.record.RecordEmitter` — engine record emitter (325 lines)
- `io.casehub.codegen.record.MappingParser` — engine mapping format
- `io.casehub.yaml.codegen.YamlCodegenMojo` — platform codegen Mojo
- `io.casehub.yaml.codegen.RecordEmitter` — platform record emitter (314 lines)
- `io.casehub.yaml.codegen.MappingConfig` — platform mapping format
- `docs/specs/2026-08-29-shared-schema-generator-design.md` — original schema-generator extraction spec
- `docs/specs/issue-279-sealed-hierarchy-module/2026-09-07-sealed-hierarchy-module-design.md` — SealedHierarchyModule promotion spec
- casehubio/engine#1058 — downstream engine epic
