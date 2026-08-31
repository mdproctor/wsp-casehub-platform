## D1: ExpansionResult returns Map<String, E> instead of List<E>

**Choice:** Replace `List<E> elements` with `LinkedHashMap<String, E> elements` in `ExpansionResult`
**Alternatives:**
- Both fields (`List<E>` + `Map<String, E> elementsById`) — non-breaking but redundant data structures
- Wrapper record (`List<ExpandedElement<E>>`) — explicit but adds a type and forces unwrapping
**Rationale:** The expander already computes the stampedId for every element — it's passed to `adapter.stamp()`. Dropping it from the result was the bug. `LinkedHashMap<String, E>` is the natural return type — ordered, keyed, no wrapper. Callers that just need iteration use `.values()`.
**Trade-offs:** Breaking change — existing callers of `result.elements()` must update from `List` to `Map`. Only one caller exists (the test suite in yaml-core itself), so migration cost is zero within the module.
**Sources:** casehubio/platform#253, ForEachExpander.java (stampedId already computed at line 104), casehubio/casehub-desiredstate#128 (migration identified the regression)
**Exploration:** quick
**Status:** captured

## D3: Generic sections map — no type parameter on YamlModule

**Choice:** `YamlModule(String name, Map<String, YamlModuleParameter> parameters, Map<String, Map<String, Object>> sections)` — content sections are opaque maps keyed by section name
**Alternatives:**
- Type-parameterised `YamlModule<N>` — compile-time safety on content but propagates type parameter through `ModuleExpander<N>`, `YamlModuleFile<N>`, `YamlImport`, every utility. Jackson can't deserialize without concrete `TypeReference` at every parse site — constant boilerplate.
**Rationale:** The module system operates on keys (for alias prefixing) and passes values through opaquely. It never inspects section content — parameter resolution, alias prefixing, and import merging all work on the structural envelope. The type parameter adds friction everywhere for safety that only matters at the consumer boundary. The consumer casts after the fact: `sections.get("nodes")`.
**Trade-offs:** No compile-time type safety on section content within the module system. Runtime ClassCastException if consumer casts wrong. Acceptable because the cast happens exactly once per consumer, at the boundary.
**Sources:** casehubio/platform#252, desiredstate YamlModule.java (tightly coupled to YamlNode/YamlRule/YamlInvariant)
**Exploration:** quick
**Status:** captured

## D2: Deferred prefix diagnostics via DeferredPrefixHandler callback

**Choice:** Add `@FunctionalInterface DeferredPrefixHandler` with `withDeferredPrefixHandler()` on VariableResolver
**Alternatives:**
- Per-prefix error messages (`Map<String, String> deferredPrefixMessages`) — simpler for the common case but can't distinguish contexts; would force desiredstate to create two sets of deferred prefixes (throwing for node specs, silent for rule specs), replicating the same complexity as the dual-API it replaced
**Rationale:** The handler is context-dependent — desiredstate wants to throw in node-spec resolution but leave `${match.X}` as-is in rule/fault spec resolution. A static message per prefix can't distinguish those contexts. The callback receives `(prefix, key, elementContext)` and the consumer decides based on how the resolver was constructed. Default: silent (current behaviour). Consistent with the immutable-child pattern (`withScope()`, `withEachContext()`).
**Trade-offs:** Slightly more complex API surface — one more method on VariableResolver. But the `@FunctionalInterface` makes the simple case trivial.
**Sources:** casehubio/platform#253, casehubio/casehub-desiredstate#128 (identified lost error context), desiredstate VariableResolver (local version threw context-specific messages)
**Exploration:** quick
**Status:** captured
