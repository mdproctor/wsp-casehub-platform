## D1: ShorthandModule generalization API

**Choice:** ShorthandSpec sealed interface with auto-derived object form
**Alternatives:**
- Raw `Map<Class<?>, Function<SchemaGeneratorConfig, CustomDefinition>>` — maximum flexibility but callers manually construct both forms, losing the auto-derive insight
- Hybrid ShorthandSpec + custom escape hatch — YAGNI, no known use case requires it; trivial to add later
**Rationale:** Callers provide `Map<Class<?>, ShorthandSpec>` describing only the scalar form. Module auto-derives the object form via victools' standard schema generation. Covers all 6 known shorthand types (3 neocortex: Confidence/NodeRef/RecurrenceRule, 3 engine: AdaptationConfig/ExpressionEvaluator/CloudEventTrigger) with three ShorthandSpec variants: `string()`, `stringEnum()`, `number()`.
**Trade-offs:** If a future type needs a non-standard scalar form (not string, string-enum, or number), a new ShorthandSpec variant must be added — but that's a one-line sealed interface change.
**Sources:** neocortex ShorthandModule.java (hardcoded 3 types), engine SchemaPostProcessor (hand-built oneOf methods), PlatformSchemaGenerator.java (module pattern), SealedHierarchyModule (parameterized module precedent)
**Exploration:** quick
**Status:** captured
