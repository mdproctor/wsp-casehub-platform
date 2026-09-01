# yaml-core Enhancements + Schema Generator — Design Spec

**Issues:** casehubio/platform#257, casehubio/platform#259, casehubio/platform#248
**Date:** 2026-09-01
**Status:** Draft

## Summary

Three independent enhancements on one branch:

1. **#257** — `allowedValues` enum constraint + `constraintDescription` human-friendly
   message on `YamlModuleParameter` / `ParameterValidator`
2. **#259** — Generic reference rewriting in `ForEachExpander` via `ForEachAdapter`
   default methods
3. **#248** — New `schema-generator/` module: shared JSON Schema generation from Java
   types (victools-based, ported from engine)

All are additive — no breaking changes to existing APIs.

---

## Part 1 — allowedValues + constraintDescription (#257)

### YamlModuleParameter — two new fields

```java
public record YamlModuleParameter(
        ParameterType type, boolean required, String defaultValue,
        Integer minLength, Integer maxLength, String pattern,
        Number minimum, Number maximum,
        List<String> allowedValues,
        String constraintDescription) {

    public YamlModuleParameter {
        if (type == null) { type = ParameterType.STRING; }
        if (allowedValues == null) { allowedValues = List.of(); }
    }
}
```

`allowedValues` restricts the parameter to an enumerated set. Empty list = no
restriction. Checked after type parsing — the values are compared as strings.

`constraintDescription` provides a human-friendly explanation of why the constraint
exists. When present, `ParameterValidator` uses it as the `message` in
`ParameterViolation` and stores the generated technical message in `technicalDetail`.

### ParameterViolation — technicalDetail field

```java
public record ParameterViolation(String parameterName, String constraint,
                                  String message, Object actualValue,
                                  String technicalDetail) {}
```

- When `constraintDescription` is set: `message` = constraintDescription text,
  `technicalDetail` = generated message (e.g., "value 'us-west-3' is not one of [...]")
- When `constraintDescription` is null: `message` = generated message,
  `technicalDetail` = null

Existing callers that only read `message()` are unaffected — the message is always
the most useful text.

### ParameterValidator changes

Add to `validateConstraints()`:

```java
if (!param.allowedValues().isEmpty()) {
    if (!param.allowedValues().contains(rawValue)) {
        String technical = "Parameter '" + name + "': value '" + rawValue
                + "' is not one of " + param.allowedValues() + ".";
        violations.add(createViolation(name, "allowedValues", technical,
                rawValue, param.constraintDescription()));
    }
}
```

All existing violation creation sites updated to pass `constraintDescription`
through a helper:

```java
private static ParameterViolation createViolation(String name, String constraint,
        String technicalMessage, Object actualValue, String constraintDescription) {
    if (constraintDescription != null) {
        return new ParameterViolation(name, constraint, constraintDescription,
                actualValue, technicalMessage);
    }
    return new ParameterViolation(name, constraint, technicalMessage,
            actualValue, null);
}
```

### JSON Schema fragment

Add to `src/main/resources/schema/yaml-module-parameter.schema.json`:
```json
{
  "allowedValues": {
    "type": "array",
    "items": { "type": "string" },
    "description": "Restricts parameter to enumerated values"
  },
  "constraintDescription": {
    "type": "string",
    "description": "Human-friendly constraint explanation"
  }
}
```

---

## Part 2 — ForEachExpander reference rewriting (#259)

### ForEachAdapter — two default methods + Reference record

```java
public interface ForEachAdapter<E> {

    E stamp(E template, String stampedId, VariableResolver scopedResolver);
    Object getForEach(E element);
    String getId(E element);
    String getWhen(E element);

    default List<Reference> getReferences(E element) { return List.of(); }
    default E withReferences(E element, List<Reference> rewritten) { return element; }

    record Reference(String targetId, boolean optional) {}
}
```

Default methods ensure existing adapters are unaffected.

### ForEachExpander — post-expansion rewriting pass

After all elements are stamped (line 131 in current code, before the return),
add a reference rewriting pass:

```java
for (Map.Entry<String, E> entry : allElements.entrySet()) {
    String stampedId = entry.getKey();
    E element = entry.getValue();
    List<ForEachAdapter.Reference> refs = adapter.getReferences(element);
    if (refs.isEmpty()) continue;

    String originalId = originalId(stampedId);
    String sourceGroup = elementToGroup.get(originalId);
    String sourceValue = extractValue(stampedId);

    List<ForEachAdapter.Reference> rewritten = new ArrayList<>();
    for (ForEachAdapter.Reference ref : refs) {
        String targetGroup = elementToGroup.get(ref.targetId());

        if (targetGroup == null) {
            rewritten.add(ref); // static target — unchanged
        } else if (targetGroup.equals(sourceGroup) && sourceValue != null) {
            rewritten.add(new ForEachAdapter.Reference(
                    ref.targetId() + "." + sourceValue, ref.optional()));
        } else if (ref.optional()) {
            // skip optional cross-group ref
        } else {
            throw new IllegalStateException("Element '" + stampedId
                    + "' references forEach element '" + ref.targetId()
                    + "' in a different group.");
        }
    }

    // Check references to excluded elements
    for (ForEachAdapter.Reference ref : rewritten) {
        if (excludedIds.contains(ref.targetId()) && !ref.optional()) {
            throw new IllegalStateException("Element '" + stampedId
                    + "' references excluded element '" + ref.targetId() + "'.");
        }
    }

    allElements.put(stampedId, adapter.withReferences(element, rewritten));
}
```

Helper methods:

```java
private static String originalId(String stampedId) {
    int dot = stampedId.lastIndexOf('.');
    return dot >= 0 ? stampedId.substring(0, dot) : stampedId;
}

private static String extractValue(String stampedId) {
    int dot = stampedId.lastIndexOf('.');
    return dot >= 0 ? stampedId.substring(dot + 1) : null;
}
```

### Rewriting rules

| Reference target | Target's group | Rewriting |
|-----------------|----------------|-----------|
| Static element | null | Unchanged |
| Same forEach group | same group key | Paired by value: `targetId.value` |
| Different group | different key | Error if not optional, skip if optional |
| Unknown element | not in elements map | Pass through unchanged (cross-boundary ref) |

---

## Part 3 — Shared schema generator (#248)

### Module structure

```
schema-generator/
  pom.xml
  src/main/java/io/casehub/schema/generator/
    PlatformSchemaGenerator.java
    SchemaPostProcessor.java
    module/
      EnumInliningModule.java
      UnevaluatedPropertiesModule.java
  src/test/java/...
```

**Maven coordinates:** `io.casehub:casehub-platform-schema-generator`
**Parent:** `casehub-parent` BOM
**Packaging:** `jar`

### Dependencies

- `com.github.victools:jsonschema-generator` (core)
- `com.github.victools:jsonschema-module-jackson`
- `com.github.victools:jsonschema-module-jakarta-validation`
- `com.fasterxml.jackson.core:jackson-databind`

### API

```java
public class PlatformSchemaGenerator {

    public PlatformSchemaGenerator(Module... customModules) {
        // Base config: DRAFT_2020_12, PLAIN_JSON, DEFINITIONS_FOR_ALL_OBJECTS,
        // FLATTENED_ENUMS_FROM_TOSTRING, JacksonModule, JakartaValidationModule,
        // EnumInliningModule, UnevaluatedPropertiesModule
        // + caller-provided custom modules
    }

    public JsonNode generate(Class<?> rootType) { ... }
    public void generateToJson(Class<?> rootType, Path output) throws IOException { ... }
}
```

### Ported from engine

| Source | Target | Notes |
|--------|--------|-------|
| `CaseHubSchemaGenerator` base setup | `PlatformSchemaGenerator` | Base config only |
| `SchemaPostProcessor` (generic) | `SchemaPostProcessor` | `$schema` insertion, `$def` cleanup |
| `EnumInliningModule` | `module/EnumInliningModule` | Inline enum values |
| `UnevaluatedPropertiesModule` | `module/UnevaluatedPropertiesModule` | JSON Schema 2020-12 |

Domain-specific modules (`WorkerSchemaModule`, `TriggerModule`, etc.) stay in engine.

---

## Test Plan

### #257 tests (ParameterValidatorTest)

| Test | Coverage |
|------|----------|
| `allowedValues_accepts_valid` | Value in allowed list passes |
| `allowedValues_rejects_invalid` | Value not in list → violation with "allowedValues" constraint |
| `allowedValues_error_lists_options` | Error message includes all allowed values |
| `allowedValues_empty_skips_check` | Empty allowedValues = no restriction |
| `constraintDescription_replaces_message` | When set, violation.message() is the description |
| `constraintDescription_preserves_technical` | violation.technicalDetail() has the generated message |
| `constraintDescription_null_no_technicalDetail` | Without constraintDescription, technicalDetail is null |
| `allowedValues_with_constraintDescription` | Both features combined |

### #259 tests (ForEachExpanderTest)

| Test | Coverage |
|------|----------|
| `reference_rewriting_static_unchanged` | Ref to static element passes through |
| `reference_rewriting_same_group_paired` | Ref in same group gets `.value` suffix |
| `reference_rewriting_cross_group_optional_skipped` | Optional cross-group ref removed |
| `reference_rewriting_cross_group_required_throws` | Required cross-group ref throws |
| `reference_rewriting_unknown_passthrough` | Ref to unknown element passes through |
| `reference_to_excluded_required_throws` | Required ref to excluded element throws |
| `reference_to_excluded_optional_skipped` | Optional ref to excluded element skipped |
| `no_references_default_noop` | Adapter without getReferences override works |

### #248 tests (PlatformSchemaGeneratorTest)

| Test | Coverage |
|------|----------|
| `generates_schema_for_simple_record` | Basic record → valid JSON Schema |
| `includes_schema_version_draft_2020_12` | `$schema` is Draft 2020-12 |
| `jackson_annotations_respected` | `@JsonPropertyDescription` appears in output |
| `enum_values_inlined` | Enum type produces inline `enum` array, not `$ref` |
| `custom_module_applied` | Caller-provided module modifies output |
| `generate_to_json_writes_file` | File output works |

## References

- `YamlModuleParameter.java` — current 8-field record (target for #257)
- `ParameterViolation.java` — current 4-field record (target for #257)
- `ParameterValidator.java` — validation logic (target for #257)
- `ForEachAdapter.java` — current 4-method interface (target for #259)
- `ForEachExpander.java` — expansion logic (target for #259)
- `docs/specs/2026-08-29-shared-schema-generator-design.md` — existing design spec for #248
- `decisions.md` — D1 (technicalDetail), D2 (naming convention)
- Issue #257 — allowedValues + constraintDescription
- Issue #259 — forEach reference rewriting
- Issue #248 — shared schema generator
- CloudFormation AllowedValues + ConstraintDescription — prior art for #257
