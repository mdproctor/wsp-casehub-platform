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
