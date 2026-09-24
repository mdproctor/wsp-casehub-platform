# Decisions — yaml-core type system polish

## D1: Unified type vocabulary

**Choice:** Extract `ValueType` enum to `io.casehub.yaml.core.type`, replacing `CsvColumnType`. `ParameterType` delegates scalar ops to `ValueType` and keeps LIST.
**Alternatives:**
- Keep CsvColumnType, add ValueType alongside — three type enums is worse than two
- Merge ParameterType into ValueType with LIST — LIST is a compound type, doesn't belong with scalars
**Rationale:** One scalar type vocabulary used by CSV, variable declarations, and build-time validation. ParameterType stays as the module-parameter-specific type with widening rules.
**Trade-offs:** CsvColumnType deletion is a breaking change for any direct consumer (none found outside yaml-core).
**Sources:** CsvColumnType.java, ParameterType.java, issue #429
**Exploration:** deep-analysis
**Status:** captured

## D2: resolveTyped scalar-only rule

**Choice:** When `resolveTyped()` resolves a root object (via ObjectVariableSource) and there's no field path to drill, return null if the root is a Map or List. Fall through to string resolution.
**Alternatives:**
- Add an `isContainer()` method to ObjectVariableSource — API complexity for a case that has zero production usage
- Modify resolveTyped to try full-name resolution first — adds a second resolution attempt per call, more complex
**Rationale:** Eliminates the dual-purpose alias tension entirely. `${each.region}` (Map root, no field) → null → string fallback → "us-east". `${each.region.tier}` (Map root, drill "tier") → Integer 500. ObjectVariableSource is unused in production so no backward compatibility concern.
**Trade-offs:** A future source that intentionally returns a Map/List as a terminal value would need a different resolution method. Not needed today.
**Sources:** VariableResolver.java:110-135, ForEachExpander.java:255-280, CorpusVariableSource.java (unused)
**Exploration:** deep-analysis
**Status:** captured

## D3: forEach + loop on imports (block-level)

**Choice:** Add `forEach` and `loop` fields to `YamlImport`. Module is the universal block abstraction for both compile-time expansion and runtime iteration.
**Alternatives:**
- Inline block construct on nodes (`block:` wrapper) — adds a new YAML construct; modules already serve as blocks
- forEach inheritance (parent scope propagates) — implicit, fragile, hard to trace
**Rationale:** Fills the 2x2 gap (step vs block × compile-time vs runtime) with no new YAML constructs. Module is already the block abstraction — just wire it to the iteration mechanisms.
**Trade-offs:** Expansion order becomes three-phase (forEach on imports → ModuleExpander → forEach on nodes). Slightly more complex expansion pipeline.
**Sources:** YamlImport.java, ForEachExpander.java, LoopDirective.java, ModuleExpander.java
**Exploration:** quick
**Depends on:** D1 (typed values must flow through block-level expansion too)
**Status:** captured

## D4: Typed variable declarations

**Choice:** `TypedMap` record carrying `Map<String, ValueType>` schema + `Map<String, Object>` typed values. `TypedName.parse()` extracts `name:type` syntax. Variables registered via both VariableSource (string fallback) and ObjectVariableSource (typed resolution).
**Alternatives:**
- TypedVariableSource (new interface combining schema + values) — unnecessary new abstraction when TypedMap + existing interfaces work
- Schema on the resolver itself — makes VariableResolver schema-aware, adds complexity to a core class
**Rationale:** TypedMap is a simple data carrier. The existing VariableSource/ObjectVariableSource pair handles resolution. Schema queryable from TypedMap.schema() for build-time tools.
**Trade-offs:** Schema and resolver are separate — build tools query TypedMap directly rather than asking the resolver.
**Sources:** VariableResolver.java, issue #429
**Exploration:** quick
**Depends on:** D1 (ValueType), D2 (resolveTyped fix)
**Status:** captured

## D5: Final conformance audit

**Choice:** After all changes land, sweep the codebase for violations: type safety gaps, duplicate resolution paths, non-normalised entry points, expansion asymmetries. Findings become follow-up issues.
**Alternatives:**
- Skip audit, trust the implementation — misses emergent gaps
- Audit during implementation — too early, findings change as code lands
**Rationale:** The audit verifies the branch achieved its goals. Running it last means it catches everything, including interactions between changes.
**Trade-offs:** None — it's additive.
**Sources:** User requirement
**Exploration:** quick
**Status:** captured
