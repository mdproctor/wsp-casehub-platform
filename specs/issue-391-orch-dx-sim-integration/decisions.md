# Decisions — #391 DX Refinements + #405 Simulation–Orchestration Integration

## D1: Shorthand forms — per-type parse(Object) factory methods

**Choice:** Follow ForEachDirective pattern — each directive type gets a sealed type with `parse(Object)` factory that handles both scalar (shorthand) and Map (full form).
**Alternatives:**
- Generic ShorthandParser utility in yaml-core — over-abstraction for a handful of types
- yaml-jackson mixin/module (Jackson-level deserialization) — couples parsing to Jackson, breaks zero-dep constraint
**Rationale:** The pattern is proven (ForEachDirective), zero-dep, and self-documenting. ShorthandModule in schema-generator already handles the JSON Schema side.
**Trade-offs:** Each new directive type needs its own parse logic — no shared parser. Acceptable given the small number of directives.
**Sources:** ForEachDirective.parse(), ShorthandModule in schema-generator, yaml-core zero-dep constraint
**Exploration:** quick
**Status:** captured

## D2: Default variable prefix — withDefaultPrefix(String) on VariableResolver

**Choice:** Add `withDefaultPrefix(String)` to VariableResolver. Bare references (`${regime}`) try the default prefix as fallback. Scoped prefixes always win.
**Alternatives:**
- Constructor parameter / builder config — heavier API change for something that's a runtime concern
- Automatic prefix inference from registered scopes — unpredictable when multiple scopes exist
**Rationale:** Immutable copy via withDefaultPrefix() matches existing VariableResolver API style (withScope, withChainedScope, etc.). Resolution order is clear: exact match → default prefix → deferred/exception.
**Trade-offs:** Adds one more concept to VariableResolver. Bare references become ambiguous if the default prefix changes between contexts — callers must be explicit about which prefix is the default.
**Sources:** VariableResolver API (withScope, withChainedScope, withObjectScope patterns), issue #391 proposal
**Exploration:** quick
**Status:** captured

## D3: Compute blocks — yaml-core data model + platform compilation

**Choice:** Add `ComputeBlock` record to yaml-core (engine key + expression text, engine optional). Compilation happens at consumer level via ExpressionEngineRegistry. The `compute:` YAML key and step-decorator semantics are a pages binding concern.
**Alternatives:**
- Full compute infrastructure in yaml-core — violates zero-dep (would need ExpressionEngine dependency)
- Compute blocks entirely in pages — loses reusability for other consumers
**Rationale:** Clean separation: yaml-core owns the data model (what), platform-api owns the compilation (how), pages owns the step binding (where). Each layer stays within its dependency budget.
**Trade-offs:** Consumers must wire ComputeBlock to ExpressionEngineRegistry themselves — no automatic compilation. Acceptable since compilation is inherently a runtime/CDI concern.
**Depends on:** D4 (expression defaults determine which engine is used when ComputeBlock.engine is null)
**Sources:** yaml-core zero-dep constraint, ExpressionEngine/ExpressionEngineRegistry in platform-api
**Exploration:** quick
**Status:** captured

## D4: Expression engine defaults — ExpressionContext enum + registry defaults

**Choice:** Add `ExpressionContext` enum (CONDITION, TRANSFORM, FILTER) to platform-api. Add `registerDefault(context, engineType)` and `resolveDefault(context)` to ExpressionEngineRegistry. Platform defaults: CONDITION → "mvel", TRANSFORM/FILTER → "jq". Overridable.
**Alternatives:**
- Hardcoded defaults in consumers — duplicated, inconsistent across modules
- Configuration-driven (application.properties) — overhead for something that rarely changes; convention is better here
**Rationale:** Conventions reduce ceremony for the 80% case (issue's stated principle). Registry-based registration is consistent with existing ExpressionEngineRegistry patterns and allows override without configuration.
**Trade-offs:** Adds a new concept (ExpressionContext) to platform-api. If future engines arrive (e.g., SpEL), the convention may need revisiting — but registerDefault() handles that.
**Sources:** ExpressionEngineRegistry SPI, MvelExpressionEngine, JQExpressionEngine, issue #391 proposal
**Exploration:** quick
**Status:** captured
