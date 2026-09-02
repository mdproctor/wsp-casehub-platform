# ModuleBridge<T> Generic + Dynamic Section Capture — Design Spec

**Issue:** casehubio/platform#270
**Date:** 2026-09-03
**Status:** Draft

## Summary

Three changes to the yaml-core module system:

1. **ModuleBridge<T>** — typed bridge interface in yaml-core. Domains own their
   content type; the expansion engine works on raw sections internally. Bridge
   converts at the boundaries.
2. **Dynamic section capture** — Jackson mixin + builder in a new `yaml-jackson/`
   module. Top-level YAML keys (other than `module:` and `imports:`) become
   sections automatically. No `sections:` wrapper.
3. **Case-insensitive ParameterType** — `ACCEPT_CASE_INSENSITIVE_ENUMS` on the
   yaml-jackson module's ObjectMapper configuration.

yaml-core stays zero-dependency and J2CL-transpilable. All Jackson concerns
live in `yaml-jackson/`.

## Part 1 — ModuleBridge<T> (yaml-core)

### Interface

```java
package io.casehub.yaml.core.module;

import java.util.Map;

public interface ModuleBridge<T> {
    T fromSections(Map<String, Map<String, Object>> sections);
    Map<String, Map<String, Object>> toSections(T content);
    default SectionContentRewriter rewriter() { return null; }
    default Map<String, String> deriveOutputs(
            T expandedContent, String alias, Map<String, String> paramScope) {
        return Map.of();
    }
}
```

- `fromSections()` — converts raw expanded sections to the domain type (post-expansion boundary)
- `toSections()` — converts domain type back to raw sections (pre-expansion boundary, or for serialization)
- `rewriter()` — provides a `SectionContentRewriter` for expansion-time operations (e.g., alias-prefixing dependencies during the merge loop). Returns `null` for no rewriting.
- `deriveOutputs()` — computes derived outputs from the typed expanded content. Default returns empty map.

### Relationship to ExpansionOptions

`ModuleBridge<T>` subsumes `SectionDeserializer`. The deserializer's job was
mid-expansion typed conversion; the bridge moves typing to the boundaries.
The expansion engine works on raw `Map<String, Map<String, Object>>` internally
throughout — no mid-expansion deserialization needed.

`SectionContentRewriter` is NOT subsumed — it's a genuinely expansion-time
operation (alias-prefixing during the merge loop). The bridge provides it
directly via `rewriter()`.

Two API levels coexist on `ModuleExpander`:

```java
// Raw consumers — existing API, keeps ExpansionOptions
public static ExpandedModule expand(
        List<YamlImport> imports,
        Map<String, YamlModule> availableModules,
        Map<String, Map<String, Object>> existingSections,
        ExpansionOptions options)

// Typed consumers — new API, uses bridge
public static <T> TypedExpandedModule<T> expand(
        List<YamlImport> imports,
        Map<String, YamlModule> availableModules,
        T existingContent,
        ModuleBridge<T> bridge)
```

### Typed expand() internal flow

1. Convert typed content to raw sections: `bridge.toSections(existingContent)`
2. Build `ExpansionOptions` from bridge: `new ExpansionOptions(null, bridge.rewriter())`
   — deserializer is null (boundary typing replaces mid-expansion typing)
3. Call the existing raw `expand()` with the constructed options
4. Convert raw expanded sections back to typed: `bridge.fromSections(rawResult.sections())`
5. Return `TypedExpandedModule<T>` with typed content + expansion metadata

`deriveOutputs()` is a post-expansion operation — the consumer calls it on the
typed result after expansion, not during the merge loop. The expansion engine
has no knowledge of `T`.

### TypedExpandedModule<T>

```java
package io.casehub.yaml.core.module;

import io.casehub.yaml.core.resolver.VariableSource;
import java.util.Map;

public record TypedExpandedModule<T>(
        T content,
        Map<String, Map<String, String>> moduleScopes,
        Map<String, String> importConditions,
        Map<String, Map<String, String>> moduleOutputs) {

    public VariableSource outputSource() {
        return name -> {
            int dot = name.indexOf('.');
            if (dot < 0) return null;
            String alias = name.substring(0, dot);
            String outputName = name.substring(dot + 1);
            Map<String, String> outputs = moduleOutputs.get(alias);
            return outputs != null ? outputs.get(outputName) : null;
        };
    }
}
```

`ExpandedModule` stays unchanged — `section()`, `typedSection()`, `outputSource()`
remain on the raw variant only. Shared fields (`moduleScopes`, `importConditions`,
`moduleOutputs`, `outputSource()`) are duplicated across both records. Four fields
— not worth an extraction.

## Part 2 — yaml-jackson/ Module (new)

### Module structure

```
yaml-jackson/
  pom.xml
  src/main/java/io/casehub/yaml/jackson/
    YamlCoreJacksonModule.java
    YamlModuleFileMixin.java
    YamlModuleFileBuilder.java
    ParameterTypeMixin.java
  src/test/java/...
```

**Maven coordinates:** `io.casehub:casehub-platform-yaml-jackson`
**Parent:** `casehub-parent` BOM
**Dependencies:** `casehub-platform-yaml-core`, `com.fasterxml.jackson.core:jackson-databind`

### YamlCoreJacksonModule

```java
package io.casehub.yaml.jackson;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.module.SimpleModule;
import io.casehub.yaml.core.module.YamlModuleFile;

public class YamlCoreJacksonModule extends SimpleModule {

    public YamlCoreJacksonModule() {
        super("yaml-core");
    }

    @Override
    public void setupModule(SetupContext context) {
        super.setupModule(context);
        context.setMixInAnnotations(YamlModuleFile.class, YamlModuleFileMixin.class);
    }
}
```

Consumers register via:
```java
objectMapper.registerModule(new YamlCoreJacksonModule());
objectMapper.enable(DeserializationFeature.ACCEPT_CASE_INSENSITIVE_ENUMS);
```

### YamlModuleFileMixin — dynamic section capture

```java
package io.casehub.yaml.jackson;

import com.fasterxml.jackson.databind.annotation.JsonDeserialize;

@JsonDeserialize(builder = YamlModuleFileBuilder.class)
abstract class YamlModuleFileMixin {}
```

### YamlModuleFileBuilder

```java
package io.casehub.yaml.jackson;

import com.fasterxml.jackson.annotation.JsonAnySetter;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.annotation.JsonPOJOBuilder;
import io.casehub.yaml.core.module.YamlImport;
import io.casehub.yaml.core.module.YamlModuleFile;
import io.casehub.yaml.core.module.YamlModuleFile.YamlModuleHeader;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@JsonPOJOBuilder(withPrefix = "")
public class YamlModuleFileBuilder {

    private YamlModuleHeader module;
    private List<YamlImport> imports = new ArrayList<>();
    private final Map<String, Map<String, Object>> sections = new LinkedHashMap<>();

    @JsonProperty("module")
    public YamlModuleFileBuilder module(YamlModuleHeader module) {
        this.module = module;
        return this;
    }

    @JsonProperty("imports")
    public YamlModuleFileBuilder imports(List<YamlImport> imports) {
        this.imports = imports != null ? imports : new ArrayList<>();
        return this;
    }

    @JsonAnySetter
    @SuppressWarnings("unchecked")
    public void addSection(String name, Object value) {
        if (value instanceof Map) {
            sections.put(name, (Map<String, Object>) value);
        }
    }

    public YamlModuleFile build() {
        return new YamlModuleFile(module, Map.copyOf(sections), List.copyOf(imports));
    }
}
```

Known fields (`module`, `imports`) are handled by `@JsonProperty`. All other
top-level keys are captured by `@JsonAnySetter` as sections. No `sections:`
wrapper support — top-level only.

### Case-insensitive ParameterType

`ACCEPT_CASE_INSENSITIVE_ENUMS` is enabled on the ObjectMapper by the consumer
when registering `YamlCoreJacksonModule`. This covers `ParameterType` and any
future yaml-core enums. No per-enum mixin needed — this is the Jackson standard
for pure case differences (Jackson 2.9+, industry consensus).

### YAML format — before and after

```yaml
# Top-level keys = sections (new format, only supported format)
module:
  name: monitoring
  parameters:
    region:
      type: string          # case-insensitive via ACCEPT_CASE_INSENSITIVE_ENUMS
      required: true
nodes:
  monitor:
    type: http-poller
    url: "https://${var.region}.example.com/health"
rules:
  alert-on-failure:
    when: "monitor.status != 200"
    action: notify
```

## Backward Compatibility

- `ExpandedModule` unchanged — all existing consumers unaffected
- Raw `ModuleExpander.expand()` overloads unchanged
- `ExpansionOptions` with `SectionDeserializer` + `SectionContentRewriter` stays available
- `YamlModuleFile` record API unchanged — only deserialization behavior changes (via mixin)
- No identity bridge — pre-release, two clean APIs (raw and typed), consumers pick one

## Test Plan

### ModuleBridge<T> tests (ModuleBridgeExpandTest)

| Test | Coverage |
|------|----------|
| `typed_expand_converts_at_boundaries` | bridge.toSections() called before expansion, fromSections() after |
| `typed_expand_rewriter_applied` | bridge.rewriter() used during merge loop |
| `typed_expand_null_rewriter` | default null rewriter — no rewriting, no error |
| `typed_expand_derive_outputs` | bridge.deriveOutputs() called with typed content |
| `typed_expand_preserves_module_scopes` | TypedExpandedModule has correct moduleScopes |
| `typed_expand_preserves_import_conditions` | TypedExpandedModule has correct importConditions |
| `typed_expand_preserves_module_outputs` | TypedExpandedModule has correct moduleOutputs |
| `typed_expand_output_source` | TypedExpandedModule.outputSource() resolves correctly |

### TypedExpandedModule tests

| Test | Coverage |
|------|----------|
| `content_accessor` | T content() returns the typed domain object |
| `output_source_resolves` | outputSource() finds alias.outputName |
| `output_source_unknown_returns_null` | unknown alias or output returns null |

### yaml-jackson/ tests (YamlModuleFileBuilderTest)

| Test | Coverage |
|------|----------|
| `top_level_keys_become_sections` | YAML with nodes:/rules: parsed as sections |
| `module_and_imports_not_captured_as_sections` | module: and imports: are known fields |
| `sections_wrapper_treated_as_section` | a key named `sections:` becomes a section entry, not a wrapper |
| `empty_file_parses` | module-only YAML, no sections |
| `nested_map_values_captured` | section entries with nested structure |
| `non_map_values_ignored` | scalar top-level values not captured as sections |

### Case-insensitive ParameterType tests

| Test | Coverage |
|------|----------|
| `lowercase_type_accepted` | `type: string` → ParameterType.STRING |
| `mixed_case_accepted` | `type: String` → ParameterType.STRING |
| `uppercase_still_works` | `type: STRING` → ParameterType.STRING |
| `all_types_case_insensitive` | LIST, INTEGER, NUMBER, BOOLEAN all accept lowercase |

## References

- `io.casehub.yaml.core.module.YamlModule` — current record (unchanged)
- `io.casehub.yaml.core.module.YamlModuleFile` — deserialization model (mixin target)
- `io.casehub.yaml.core.module.ModuleExpander` — expansion engine (new typed overload)
- `io.casehub.yaml.core.module.ExpandedModule` — raw result type (unchanged)
- `io.casehub.yaml.core.module.ExpansionOptions` — raw consumer hook (stays)
- `io.casehub.yaml.core.module.SectionDeserializer` — subsumed by bridge for typed path
- `io.casehub.yaml.core.module.SectionContentRewriter` — provided by bridge.rewriter()
- `io.casehub.yaml.core.module.ParameterType` — enum (case-insensitive via Jackson feature)
- `io.casehub.api.context.ContextBridge` — engine prior art (Jackson-coupled, different pattern)
- `io.casehub.api.context.JacksonPojoBridge` — engine prior art (not mixin-based)
- casehubio/platform#270 — this issue
- casehubio/casehub-desiredstate#126 — first consumer (adopts ModuleBridge)
- platform#269 — module extension (builds on ModuleBridge)
- Jackson `DeserializationFeature.ACCEPT_CASE_INSENSITIVE_ENUMS` — standard for case differences
- `decisions.md` — D1–D7 design decisions
