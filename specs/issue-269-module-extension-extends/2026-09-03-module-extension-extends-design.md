# Module Extension (`extends` keyword) — Design Spec

**Issue:** casehubio/platform#269
**Date:** 2026-09-03
**Status:** Draft

## Summary

A module declares `extends: <parent-module-name>` in its header. The child
inherits all of the parent's parameters, outputs, and sections. Child entries
win on key conflict. Single-level extension only (no chains). Resolution
happens before expansion as a pre-processing step.

Three touch points:
1. `YamlModuleHeader` — new `extendsModule` field (nullable)
2. `ModuleExpander` — new `resolveExtensions()` static method
3. `YamlModuleFileBuilder` — `extends` deserialization via `YamlModuleHeader`

yaml-core stays zero-dependency and J2CL-transpilable. No changes to
`YamlModule` (the logical model), `ExpandedModule`, `ModuleBridge<T>`, or
the `expand()` methods.

## YAML Format

```yaml
# Parent module
module:
  name: monitoring
  parameters:
    region:
      type: string
      required: true
    interval:
      type: integer
      defaultValue: "30"
  outputs:
    endpoint:
      type: string
      value: "https://${var.region}.example.com/health"
nodes:
  monitor:
    type: http-poller
    url: "${var.region}.example.com/health"
    interval: "${var.interval}"

# Child module — extends parent
module:
  name: monitoring-with-slack
  extends: monitoring
  parameters:
    slack_channel:
      type: string
      required: true
nodes:
  slack-notifier:
    type: notifier
    dependsOn: [monitor]
    spec:
      channel: "${var.slack_channel}"
```

The child inherits `region` and `interval` parameters, the `endpoint` output,
and the `monitor` node. It adds `slack_channel` and `slack-notifier`.

## Part 1 — `YamlModuleHeader` Changes

### New field

```java
public record YamlModuleHeader(String name,
                               Map<String, YamlModuleParameter> parameters,
                               Map<String, YamlModuleOutput> outputs,
                               String extendsModule) {
    public YamlModuleHeader {
        if (parameters == null) {parameters = Map.of();}
        if (outputs == null) {outputs = Map.of();}
    }
}
```

`extendsModule` is nullable — `null` means no inheritance. The YAML key is
`extends:`; Jackson maps `extends` → `extendsModule` via the
`YamlModuleFileBuilder` in yaml-jackson (see Part 3).

`extends` is a Java reserved word — `extendsModule` is the field name,
consistent with `YamlImport.module()` which also names a target module.

### `toModule()` discards `extends`

`YamlModuleFile.toModule()` is unchanged — it already does not propagate
header-only fields. `extendsModule` has the same lifecycle as `imports`:
consumed during resolution, absent from the logical model.

```java
public YamlModule toModule() {
    return new YamlModule(module.name(), module.parameters(),
                          module.outputs(), sections);
}
```

## Part 2 — `ModuleExpander.resolveExtensions()`

### API

```java
public static Map<String, YamlModule> resolveExtensions(
        List<YamlModuleFile> moduleFiles)
```

Takes all module files (parsed from YAML), resolves extension inheritance,
and returns a map of resolved `YamlModule` instances keyed by name. This
replaces individual `toModule()` calls — callers funnel all files through
`resolveExtensions()` as the standard pipeline step.

### Pipeline

```
parse YAML → List<YamlModuleFile> → resolveExtensions() → Map<String, YamlModule> → expand()
```

### Resolution algorithm

```java
public static Map<String, YamlModule> resolveExtensions(
        List<YamlModuleFile> moduleFiles) {

    // 1. Index by name
    Map<String, YamlModuleFile> filesByName = new LinkedHashMap<>();
    for (YamlModuleFile file : moduleFiles) {
        String name = file.module().name();
        if (filesByName.containsKey(name)) {
            throw new IllegalArgumentException(
                    "Duplicate module name '" + name + "'.");
        }
        filesByName.put(name, file);
    }

    // 2. Validate and resolve
    Map<String, YamlModule> resolved = new LinkedHashMap<>();
    for (YamlModuleFile file : moduleFiles) {
        String parentName = file.module().extendsModule();

        if (parentName == null) {
            // No extension — convert directly
            resolved.put(file.module().name(), file.toModule());
            continue;
        }

        // Validate
        if (parentName.equals(file.module().name())) {
            throw new IllegalArgumentException(
                    "Module '" + parentName + "' extends itself.");
        }

        YamlModuleFile parentFile = filesByName.get(parentName);
        if (parentFile == null) {
            throw new IllegalArgumentException(
                    "Module '" + file.module().name()
                    + "' extends unknown module '" + parentName + "'.");
        }

        if (parentFile.module().extendsModule() != null) {
            throw new IllegalArgumentException(
                    "Module '" + file.module().name() + "' extends '"
                    + parentName + "', which itself extends '"
                    + parentFile.module().extendsModule()
                    + "'. Extension chains are not supported.");
        }

        // Merge
        YamlModule parentModule = parentFile.toModule();
        YamlModule merged = mergeModules(parentModule, file);
        resolved.put(file.module().name(), merged);
    }

    return Map.copyOf(resolved);
}
```

### Merge semantics

```java
private static YamlModule mergeModules(YamlModule parent,
                                        YamlModuleFile childFile) {
    // Parameters: parent + child overlay (child wins on name match)
    Map<String, YamlModuleParameter> mergedParams = new LinkedHashMap<>(parent.parameters());
    mergedParams.putAll(childFile.module().parameters());

    // Outputs: parent + child overlay (child wins on name match)
    Map<String, YamlModuleOutput> mergedOutputs = new LinkedHashMap<>(parent.outputs());
    mergedOutputs.putAll(childFile.module().outputs());

    // Sections: merge by section name, child entry wins on key match
    Map<String, Map<String, Object>> mergedSections = new LinkedHashMap<>();
    for (Map.Entry<String, Map<String, Object>> entry : parent.sections().entrySet()) {
        mergedSections.put(entry.getKey(), new LinkedHashMap<>(entry.getValue()));
    }
    for (Map.Entry<String, Map<String, Object>> entry : childFile.sections().entrySet()) {
        Map<String, Object> targetSection = mergedSections
                .computeIfAbsent(entry.getKey(), k -> new LinkedHashMap<>());
        targetSection.putAll(entry.getValue());
    }

    return new YamlModule(childFile.module().name(),
                          Map.copyOf(mergedParams),
                          Map.copyOf(mergedOutputs),
                          Map.copyOf(mergedSections));
}
```

**Merge rules:**

| Component | Parent only | Child only | Both (same key) |
|-----------|-------------|------------|------------------|
| Parameter | Inherited | Added | Child replaces entirely |
| Output | Inherited | Added | Child replaces entirely |
| Section name | Inherited | Added | Entry-level merge (below) |
| Section entry | Inherited | Added | Child replaces entirely |

No deep merge of section entry values — yaml-core treats them as opaque
`Object`. Consumers wanting deep merge implement it via
`ModuleBridge<T>.fromSections()`.

### Validation errors

| Error | Condition |
|-------|-----------|
| Duplicate module name | Two files share the same `module.name` |
| Self-extension | `extends` references the module's own name |
| Unknown parent | `extends` references a name not in the file list |
| Extension chain | Parent module also has `extends` (single-level violated) |

All errors throw `IllegalArgumentException` with a descriptive message.

## Part 3 — yaml-jackson Changes

### `YamlModuleFileBuilder` — `extends` capture

The `YamlModuleHeader` record gains the `extendsModule` field. Jackson
deserializes `extends:` from YAML into the `extendsModule` field of the
header record. Since `YamlModuleHeader` is a record, Jackson uses
constructor-based deserialization — the field mapping `extends` →
`extendsModule` needs a `@JsonProperty("extends")` on the constructor
parameter.

However, `YamlModuleHeader` is in yaml-core (zero-dep). The Jackson
annotation must go on a mixin in yaml-jackson:

```java
abstract class YamlModuleHeaderMixin {
    @JsonCreator
    YamlModuleHeaderMixin(
            @JsonProperty("name") String name,
            @JsonProperty("parameters") Map<String, YamlModuleParameter> parameters,
            @JsonProperty("outputs") Map<String, YamlModuleOutput> outputs,
            @JsonProperty("extends") String extendsModule) {}
}
```

Register in `YamlCoreJacksonModule.setupModule()`:
```java
context.setMixInAnnotations(YamlModuleHeader.class, YamlModuleHeaderMixin.class);
```

Without Jackson (pure yaml-core consumers), the caller constructs
`YamlModuleHeader` directly — the field is just `extendsModule`.

## Backward Compatibility

- `YamlModuleHeader` gains a field — existing callers using the 3-arg
  constructor must add `null` for `extendsModule`. Pre-release, acceptable.
- `resolveExtensions()` is additive — new method, no existing methods change.
- `YamlModule` unchanged — no impact on `expand()`, `ModuleBridge<T>`, or
  downstream consumers.
- Modules without `extends` pass through `resolveExtensions()` identically
  to calling `toModule()` directly.

## Test Plan

### ModuleExpander — resolveExtensions tests

| Test | Coverage |
|------|----------|
| `resolve_no_extensions` | Files without extends → same as toModule() |
| `resolve_inherits_parameters` | Child inherits parent's parameters |
| `resolve_inherits_outputs` | Child inherits parent's outputs |
| `resolve_inherits_sections` | Child inherits parent's sections |
| `resolve_child_adds_parameters` | Child adds new params alongside inherited |
| `resolve_child_adds_outputs` | Child adds new outputs alongside inherited |
| `resolve_child_adds_section_entries` | Child adds entries to inherited section |
| `resolve_child_adds_new_section` | Child adds a section parent doesn't have |
| `resolve_child_overrides_parameter` | Child's param replaces parent's entirely |
| `resolve_child_overrides_output` | Child's output replaces parent's entirely |
| `resolve_child_overrides_section_entry` | Child's entry replaces parent's in same section |
| `resolve_unknown_parent_throws` | extends references missing module → error |
| `resolve_self_extension_throws` | extends own name → error |
| `resolve_chain_throws` | Parent also has extends → error |
| `resolve_duplicate_name_throws` | Two files with same module name → error |
| `resolve_mixed_extended_and_plain` | Mix of extended and plain modules in one call |
| `resolve_preserves_child_name` | Resolved module has the child's name, not parent's |

### yaml-jackson — extends deserialization tests

| Test | Coverage |
|------|----------|
| `extends_field_deserialized` | YAML `extends: foo` → `extendsModule()` = "foo" |
| `no_extends_field_null` | YAML without extends → `extendsModule()` = null |
| `extends_with_sections_and_params` | Full module file with extends + content |

### Integration — resolveExtensions + expand

| Test | Coverage |
|------|----------|
| `extended_module_expands_correctly` | Resolve then expand — inherited content appears in expansion |
| `extended_module_with_bridge` | Resolve then typed expand via ModuleBridge<T> |

## References

- `io.casehub.yaml.core.module.YamlModuleFile` — file model (`toModule()` boundary)
- `io.casehub.yaml.core.module.YamlModuleFile.YamlModuleHeader` — header record (extends field target)
- `io.casehub.yaml.core.module.YamlModule` — logical model (unchanged)
- `io.casehub.yaml.core.module.ModuleExpander` — expansion engine (new `resolveExtensions()` method)
- `io.casehub.yaml.core.module.ModuleBridge` — typed bridge (unchanged, works with resolved modules)
- `io.casehub.yaml.jackson.YamlModuleFileBuilder` — Jackson builder (unchanged)
- `io.casehub.yaml.jackson.YamlCoreJacksonModule` — Jackson module (new mixin registration)
- casehubio/platform#269 — this issue
- casehubio/platform#270 — ModuleBridge<T> (foundation this builds on)
- casehubio/platform#252 — yaml-core module system (original design)
- casehubio/casehub-desiredstate#126 — first consumer of ModuleBridge
- `decisions.md` — D1–D5 design decisions
