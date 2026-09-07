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

## D2: yaml-codegen consolidation strategy

**Choice:** Merge best-of-both into yaml-codegen's MappingConfig
**Alternatives:**
- Enhance yaml-codegen only with engine's missing features (assumes platform's format is superior — it isn't, both have complementary strengths)
- Start fresh with a clean data model — gold-plating risk, both formats are production-tested
- Support both mapping formats with auto-detection — adds complexity for no lasting benefit
**Rationale:** Side-by-side comparison showed neither format is more powerful. Platform has better schema parsing (TypeGraph with required/description/additionalProperties), dedicated JavaTypeResolver, per-field skip, globalAnnotations, jsonProperty bidirectional lookup. Engine has better code generation flexibility (body injection, defaultValue per field, ExtraField with defaults, recordName), and global configuration (skipPatterns, imports map, deserializers map). Merging preserves all working behavior. No existing consumers break — new features are additive/optional.
**Trade-offs:** Engine's yaml-record-mappings.yaml files need translating to the expanded MappingConfig format. One-time migration cost per consuming repo.
**Sources:** platform yaml-codegen MappingConfig.java (globalAnnotations, per-field skip, jsonProperty bidirectional lookup), engine RecordMapping.java (skipPatterns, imports, deserializers, body, defaultValue, recordName), platform TypeGraph.java (required, description, additionalProperties), engine SchemaType.java (simpler model)
**Exploration:** deep-analysis
**Status:** captured

## D3: Drift detection plugin placement

**Choice:** New module `drift-detection/` as separate Maven plugin
**Alternatives:**
- Second goal in yaml-codegen plugin — couples two independent concerns; blocks/neocortex may use drift detection without yaml-codegen
**Rationale:** Drift detection is orthogonal to code generation. The issue explicitly requires "generic applicability" — usable for any codegen pipeline (yaml-codegen, APT generators, graphql-generator). Separate artifact (`casehub-platform-drift-detection`) with `maven-plugin` packaging. No dependency on yaml-codegen. Scans compiled classes vs a generated-sources directory.
**Trade-offs:** One more module in platform's build. Consumers add a second plugin declaration. Acceptable given the generality requirement.
**Sources:** issue #281 (design section, generic applicability), yaml-codegen YamlCodegenMojo.java (existing plugin pattern)
**Exploration:** quick
**Status:** captured

## D4: ShorthandModule — neocortex migration scope

**Choice:** Follow-up issue on neocortex — same pattern as SealedHierarchyModule (#279)
**Depends on:** D1 (generic ShorthandModule must be published before consumers adopt)
**Alternatives:**
- Cross-repo branch touching both platform and neocortex — couples the release, platform publishes first in build order
**Rationale:** Matches precedent set by #279 D3 (SealedHierarchyModule). Platform publishes first, consumers adopt independently. Cleaner scope — this branch promotes the module, separate issues handle migration.
**Trade-offs:** Neocortex temporarily has two copies of the module until migration completes.
**Sources:** issue-279 decisions.md D3, build order (platform publishes before neocortex)
**Exploration:** quick
**Status:** captured
