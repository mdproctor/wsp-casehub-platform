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

## D4: ParameterValidator — dual API: validate() returns, validateOrThrow() throws

**Choice:** `List<ParameterViolation> validate()` (primitive — returns violations, empty list on success) + `void validateOrThrow()` (convenience — calls validate(), throws `ParameterValidationException` if non-empty). Collect-all in both cases.
**Alternatives:**
- Throw-only API (`validate()` throws, no return) — simpler surface but forces catch-and-extract for testing and any non-throwing use case. Testing assertions on a returned list are cleaner than catching exceptions to inspect violations.
- Return `ValidationResult(boolean, List)` — unnecessary wrapper; the list IS the result.
**Rationale:** The composable primitive is `List<ParameterViolation>`. The throwing convenience is built on top. Most callers use `validateOrThrow()` — parameter failures are always fatal at the module boundary. But `validate()` makes testing straightforward and leaves the door open for linting/dry-run without a second method.
**Trade-offs:** Two methods where one would suffice for the common case. Acceptable — the primitive is 3 lines and makes tests cleaner.
**Sources:** casehubio/platform#252, desiredstate GraphInvariantViolationsException (consistent collect-all pattern), R1-02 decision review finding
**Exploration:** quick
**Status:** revised (R1-02 — primitive should be the return value, not the exception)

## D5: Module parameter resolution via VariableSource.chain() — no withModuleScope()

**Choice:** Module parameters are resolved via `VariableSource.chain(moduleParams::get, existingVarSource)` passed to `withScope("var", ...)`. No new `withModuleScope()` method on VariableResolver.
**Alternatives:**
- Add `withModuleScope(Map<String, String>)` as a first-class resolver field — makes priority explicit but splits the resolution model between compositional (VariableSources) and special-case (moduleScope). Module scope IS a VariableSource; `Map<String, String>::get` already satisfies the `@FunctionalInterface`. Chain order IS the priority mechanism — the defining semantic of chaining, not an implicit side effect.
**Rationale:** `VariableSource.chain()` already handles priority — that's its design purpose. Adding `withModuleScope()` creates two resolution paths for `var.*` variables (module scope check AND prefix source dispatch), splitting the resolution model. The consumer wires the chain: `ModuleExpander` returns resolved parameter maps, the consumer creates `VariableSource.chain(moduleParams::get, existingVarSource)` and passes it via `withScope("var", ...)`.
**Trade-offs:** Priority is expressed in chain order rather than a named method. Acceptable — chain order is how VariableSource composition works everywhere.
**Sources:** desiredstate VariableResolver.withModuleScope() (production pattern being retired), VariableSource.chain() (existing composition mechanism), R1-01 decision review finding
**Exploration:** quick
**Status:** revised (R1-01 — module scope IS a VariableSource, chain order IS the priority mechanism)

## D6: ParameterValidator in yaml-core with separate ParameterType enum

**Choice:** `ParameterValidator` lives in yaml-core (not in consumer build-time processors). `ParameterType` enum (STRING, LIST, INTEGER, NUMBER, BOOLEAN) is separate from `CsvColumnType`.
**Alternatives:**
- Validation in consumer build-time processor — desiredstate's current approach, but constraint validation is generic (not domain-specific) and the whole point of extraction is sharing
- Reuse `CsvColumnType` for parameter types — shares three names (STRING, INTEGER, BOOLEAN) but the two type systems parse differently (CSV stores typed values persistently; parameters validate transiently then discard), evolve differently, and serve different lifecycle stages. Unifying creates coupling that costs more to maintain than the five lines it saves.
**Rationale:** Parameter constraints (minLength, maxLength, pattern, minimum, maximum) are generic — no domain knowledge needed. yaml-core owns the module model, so it should own the validation. Separate `ParameterType` keeps concerns clean: CSV types are parse-and-store, parameter types are validate-then-discard.
**Trade-offs:** Two enums with overlapping names. Acceptable — the shared names are coincidence, not identity.
**Sources:** casehubio/platform#252, CsvColumnType.java (existing CSV type system), desiredstate YamlDesiredStateProcessor.validateImports() (current required-only validation)
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
