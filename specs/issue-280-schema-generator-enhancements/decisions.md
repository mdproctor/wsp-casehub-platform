## D1: ShorthandModule generalization API

**Choice:** Parameterized ShorthandModule with explicit scalar and object forms
**Alternatives:**
- Raw `Map<Class<?>, Function<SchemaGeneratorConfig, CustomDefinition>>` — maximum flexibility but no structural guarantee that outputs follow the oneOf [scalar, object] pattern; the module becomes a generic dispatcher with no architectural intent
- ShorthandSpec sealed interface with auto-derived object form — REJECTED: auto-derivation from Java types diverges from hand-built schemas (AdaptationConfig `revision` field gap, CloudEventTrigger `$ref` name coordination, Confidence/RecurrenceRule constraint gaps). Only NodeRef auto-derives correctly out of 5 types.
- Per-type victools Modules — follows existing Module composition but repeats oneOf wrapping boilerplate N times; "shorthand types" is one concern, not N (same rationale as SealedHierarchyModule parameterizing multiple sealed hierarchies through one Module)
**Rationale:** Callers provide `Map<Class<?>, ShorthandDefinition>` where ShorthandDefinition supplies both the scalar-form schema and the object-form schema explicitly. Module wraps each pair in `oneOf`. No auto-derivation — callers own the complete schema for both forms. ExpressionEvaluator excluded from scope (stays as its own Module — string-or-map pattern is structurally different from scalar-or-object). Covers 5 known shorthand types (3 neocortex: Confidence/NodeRef/RecurrenceRule, 2 engine: AdaptationConfig/CloudEventTrigger).
**Trade-offs:** Callers must construct both schemas manually, which is more verbose than auto-derivation. This is intentional — the hand-built schemas contain YAML-only properties (AdaptationConfig `revision`), custom ref names (CloudEventTrigger `ExpressionOrOverride`), and validation constraints (Confidence min/max, RecurrenceRule DayOfWeek abbreviations) that auto-derivation cannot reproduce.
**Sources:** neocortex ShorthandModule.java (hardcoded 3 types), engine SchemaPostProcessor buildAdaptation() (revision field gap), ExpressionEvaluatorModule (different pattern), SealedHierarchyModule (parameterized module precedent), CloudEventTrigger.java (filter field refs ExpressionEvaluator), Confidence.java (runtime min/max checks, not Jakarta annotations)
**Exploration:** quick → revised after adversarial review (R1-02, R1-03, R1-04, R1-05)
**Status:** revised — dropped auto-derivation and ShorthandSpec in favor of explicit dual-form parameterization; removed ExpressionEvaluator from scope (5 types, not 6)

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

## D3: Drift detection placement

**Choice:** Maven Enforcer custom rule in `casehub-platform-drift-detection` module
**Alternatives:**
- Full Maven plugin with `maven-plugin` packaging — over-engineered for a read-only inspection; requires Mojo annotations, goal binding, integration test harness, its own release lifecycle
- Second goal in yaml-codegen plugin — couples two independent concerns; blocks/neocortex may use drift detection without yaml-codegen
- Test utility (`DriftAssertions`) — requires each consumer to write a test class; no guaranteed adoption; imperative vs declarative enforcement
**Rationale:** A custom `EnforcerRule` implementation is a single class (~50 lines) in a regular JAR. Consumers declare it via the standard `maven-enforcer-plugin`. The enforcer plugin handles lifecycle, error reporting, and skip/fail configuration. Drift detection only inspects — it never writes files — so plugin packaging is architectural mismatch. Generic by construction: compares `(classes in target package) − (generated sources) − (allow-list) = ∅` with no codegen-pipeline-specific logic. Issue #281's "generic applicability" requirement is satisfied intrinsically.
**Trade-offs:** Consumers must have `maven-enforcer-plugin` declared (most builds already do). Rule configuration is standard enforcer XML.
**Sources:** issue #281 (generic applicability requirement), maven-enforcer-plugin documentation, engine SchemaDriftTest.java (existing test-based schema drift detection — a different concern)
**Exploration:** quick → revised after adversarial review (R1-10)
**Status:** revised — changed from Maven plugin to Maven Enforcer custom rule

## D4: ShorthandModule — neocortex migration scope

**Choice:** Follow-up issue on neocortex — same pattern as SealedHierarchyModule (#279)
**Depends on:** D1 (parameterized ShorthandModule must be published before consumers adopt)
**Alternatives:**
- Cross-repo branch touching both platform and neocortex — couples the release, platform publishes first in build order
**Rationale:** Matches precedent set by #279 D3. Platform publishes first, consumers adopt independently. Migration surface: neocortex's existing `ShorthandModule` is replaced by instantiating the platform's `ShorthandModule` with explicit scalar+object form definitions for Confidence, NodeRef, and RecurrenceRule.
**Trade-offs:** Neocortex temporarily has two copies of the module until migration completes.
**Sources:** issue-279 decisions.md D3, build order (platform publishes before neocortex)
**Exploration:** quick
**Status:** revised — updated migration surface to reflect D1 revision (explicit dual-form definitions, not ShorthandSpec)

## D5: Schema backward compatibility on shorthand migration

**Choice:** Callers must produce schema-equivalent output during migration
**Alternatives:**
- Allow schema drift with version bump — risks invalidating existing YAML files without a migration path
- Auto-migration tooling for YAML files — complexity not justified; hand-built schemas are the source of truth during migration
**Rationale:** When migrating from hand-built schemas (engine SchemaPostProcessor) or hardcoded modules (neocortex ShorthandModule) to the parameterized platform ShorthandModule, callers must provide scalar and object forms that produce schema output equivalent to the existing schemas. This preserves YAML file validity. The engine's SchemaDriftTest provides a verification mechanism — run it after migration to confirm equivalence. With explicit dual-form definitions (D1 revision), backward compatibility is caller-controlled: callers can reproduce exactly the same schema the hand-built code produces today, including YAML-only properties like AdaptationConfig's `revision`.
**Trade-offs:** Callers must carefully replicate existing schema structure. This is mechanical — they translate the same hand-built schemas into ShorthandDefinition construction calls.
**Sources:** engine SchemaDriftTest.java (schema equivalence verification), SchemaPostProcessor buildAdaptation() (hand-built schema with YAML-only properties)
**Exploration:** surfaced during adversarial review (R1-16)
**Status:** captured

## D6: ShorthandModule module placement

**Choice:** ShorthandModule and ShorthandDefinition live in `casehub-platform-schema-generator`
**Alternatives:**
- `casehub-platform-api` — would make the shorthand concern visible at runtime, but no runtime code needs to query "is this type a shorthand?"
**Rationale:** Shorthand type definitions are a build-time schema generation concern. The distinction between shorthand and non-shorthand types matters only during JSON Schema generation. PlatformSchemaGenerator already lives in schema-generator, and ShorthandModule is composed through its varargs Module constructor.
**Trade-offs:** None significant — this is the natural placement.
**Sources:** PlatformSchemaGenerator.java (module composition in schema-generator)
**Exploration:** surfaced during adversarial review (R1-17)
**Status:** captured
