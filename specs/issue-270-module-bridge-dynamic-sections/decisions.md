## D1: Jackson annotations via mixins in a yaml-jackson/ module

**Choice:** Create a new `yaml-jackson/` module providing Jackson mixins for yaml-core types. yaml-core stays zero-dependency.
**Alternatives:**
- Consumer-side custom deserializers — duplicates logic across consumers, no shared convention
- Jackson annotations directly on yaml-core types — violates zero-dep/J2CL constraint
- JacksonPojoBridge-style impl classes — couples the interface to Jackson (engine's current pattern, may need migration)
**Rationale:** Mixins are the standard Jackson mechanism for annotating types you don't own. A shared module avoids duplication and establishes the convention across casehub.
**Trade-offs:** Adds a new module to the build; consumers must register the module. Trivial cost.
**Sources:** engine `JacksonPojoBridge` (prior art, not ideal), engine `ContextBridge` pattern
**Exploration:** quick
**Status:** captured

## D2: ModuleBridge<T> subsumes SectionDeserializer, coexists with raw API

**Choice:** ModuleBridge<T> provides `fromSections()`, `toSections()`, `rewriter()`, and `deriveOutputs()`. Two API levels on ModuleExpander: raw (ExpansionOptions) and typed (ModuleBridge<T>).
**Alternatives:**
- Bridge wraps ExpansionOptions — unnecessary indirection, SectionDeserializer is redundant with boundary typing
- Bridge replaces ExpansionOptions entirely — breaks raw-map consumers who don't need full typing
**Rationale:** SectionDeserializer does mid-expansion typing; the bridge moves typing to the boundary (before/after expansion). SectionContentRewriter is genuinely expansion-time (alias-prefixing during merge loop), so the bridge provides it directly via `rewriter()`. Raw API stays for consumers who don't need typed content.
**Trade-offs:** Two expansion APIs to maintain. The raw path becomes the less common one going forward.
**Sources:** `ModuleExpander.expand()` current implementation, `ExpansionOptions`, `SectionDeserializer`, `SectionContentRewriter`
**Exploration:** quick
**Status:** captured

```java
interface ModuleBridge<T> {
    T fromSections(Map<String, Map<String, Object>> sections);
    Map<String, Map<String, Object>> toSections(T content);
    default SectionContentRewriter rewriter() { return null; }
    default Map<String, String> deriveOutputs(
            T expandedContent, String alias, Map<String, String> paramScope) {
        return Map.of();
    }
}
```

## D3: Dynamic section capture via Jackson builder in yaml-jackson/

**Choice:** `YamlModuleFile` stays an immutable record in yaml-core. The yaml-jackson/ module provides a `YamlModuleFileBuilder` with `@JsonAnySetter` that accumulates unknown top-level keys as sections, then constructs the record. A mixin wires `@JsonDeserialize(builder = YamlModuleFileBuilder.class)` to the record type.
**Alternatives:**
- Change `YamlModuleFile` from record to class with native builder — adds mutability to yaml-core for a Jackson concern, pollutes the zero-dep API
**Rationale:** The builder is a Jackson deserialization concern, not a yaml-core modelling concern. Records are the right representation for immutable data. The mixin + builder pattern keeps the Jackson layer self-contained.
**Trade-offs:** Builder class adds a file to yaml-jackson/. Consumers who don't use Jackson never see it.
**Sources:** Jackson `@JsonDeserialize(builder = ...)` support for records, `YamlModuleFile` current record
**Exploration:** quick
**Status:** captured

## D4: Separate TypedExpandedModule<T> rather than generifying ExpandedModule

**Choice:** New `TypedExpandedModule<T>` record with `T content()` for the bridge path. `ExpandedModule` stays unchanged for raw consumers. Shared fields (`moduleScopes`, `importConditions`, `moduleOutputs`, `outputSource()`) duplicated across both records.
**Alternatives:**
- Generify `ExpandedModule<T>` — carries dead methods (`section()`, `typedSection()`) on typed variant, forces `ExpandedModule<Map<String, Map<String, Object>>>` at every existing call site, noisy with no value
- Extract shared fields into a base class — four fields, not worth the abstraction
**Rationale:** API clarity (each type has exactly the methods that make sense), zero churn on existing consumers, and avoids the verbosity of `ExpandedModule<Map<String, Map<String, Object>>>` at call sites. "Typed" prefix signals the bridge path vs the raw path, paralleling the two `expand()` overloads.
**Trade-offs:** Field duplication across two records. Four fields — trivial.
**Sources:** `ExpandedModule` current record (section(), typedSection(), outputSource())
**Exploration:** quick
**Status:** captured
