## D1: Extend existing match step

**Choice:** Extend the existing `match` step with template-matching mode, not a new step type
**Alternatives:**
- New `template-match` step type — cleaner separation but fragments the dispatch concept unnecessarily
- TemplatePattern as MatchPattern variant — keeps single step type but makes template matching a pattern kind rather than a mode. Rejected: template matching involves handler dispatch (multiple named handler blocks), not simple boolean pattern matching. MatchPattern.matches(Object) returns boolean; template matching returns extracted fields + handler routing.
**Rationale:** Both value-matching and template-matching are forms of "dispatch by pattern." One step type to learn, one concept. Mode detected by YAML structure: `cases:` = value mode, `namespace:` + `on:` = template mode. Walker's existing invariant (`match requires cases`) must be updated to accept either `cases` or `namespace` + `on`.
**Trade-offs:** Walker needs conditional companion validation. MatchCompiler and evaluateMatch() each have a mode branch. Both compilation pipelines (PlaybookCompiler/SWF and Walker/StructuralStepEvaluator) must be updated.
**Sources:** existing MatchCompiler.java, ResolvedStep.MatchStep, Walker.java (match/cases invariant), issue #970 syntax
**Exploration:** quick
**Status:** captured

## D2: Schema resolver SPI for compile-time template access

**Choice:** Non-optional functional interface (schema resolver) on the compiler, with NoOp default that returns empty for all namespaces. Return type narrowed to schema info.
**Alternatives:**
- Nullable resolver (original proposal) — creates two operational modes, null can't distinguish "not found" from "not provided"
- Pre-resolved schema metadata through compilation input — wasteful, couples caller to knowing references before parsing
**Rationale:** PlaybookCompiler stays framework-neutral. NoOp default follows platform pattern (NoOpUnifiedTemplateRegistry, NoOpCaseMemoryStore). Interface: `TemplateSchemaResolver` with `resolve(String namespace) → List<TemplateSchema>` — narrower than full TemplateNamespace (compiler only needs variable names, constraints, metadata per template). Non-optional means consistent error path: "namespace not found" whether registry is empty or unconfigured.
**Trade-offs:** Extra interface type. NoOp means template-mode match steps that reference namespaces get "namespace not found" errors at compile time when no resolver is wired — which is the correct behavior (fail-fast).
**Depends on:** D3 (TemplateSchema carries VariableConstraint with metadata)
**Sources:** PlaybookCompiler.java, UnifiedTemplateRegistry.java, NoOp platform pattern
**Exploration:** quick
**Status:** revised (R1-04: nullability → NoOp default, narrowed return type)

## D3: Metadata on VariableConstraint in yaml-core

**Choice:** Add `Map<String, String> metadata()` to the `VariableConstraint` sealed interface with default `Map.of()`. Define `MetadataKeys` constants for known grammar keys (PERSON, NUMBER, PRONOUNS) for safe access.
**Alternatives:**
- Typed `GrammarHints` record — validates at construction, self-documenting. Rejected: closes the door on non-grammar metadata. Future metadata kinds (locale hints, display hints) would require another record or reopening. Constants + Map balances extensibility with safety.
- New wrapper type `TemplateVariable` in template-registry-api — creates parallel type hierarchy for the same concept
**Rationale:** Variable metadata is a general concept, not template-specific. `Map<String, String>` with typed constant keys provides extensibility with discoverability. `MetadataKeys.PERSON`, `MetadataKeys.PRONOUNS` etc. prevent typo-based silent failures for known keys. yaml-core remains zero-dep and J2CL-safe.
**Trade-offs:** Unknown metadata keys are unchecked at construction time (accepted trade-off for extensibility). Known keys are validated via constants at access sites.
**Sources:** VariableConstraint.java (yaml-core), issue #969 YAML corpus format
**Exploration:** quick
**Status:** revised (R1-05: added MetadataKeys constants for known grammar keys)

## D3b: VariableConstraint metadata backward compatibility

**Choice:** Add `metadata` field to StringConstraint and EnumConstraint records with compact constructor defaulting null to `Map.of()`. Preserve existing two-arg factory methods; add new `withMetadata(Map)` wither on each variant.
**Alternatives:**
- Wrapper record — rejected in D3
**Rationale:** Existing code constructing via `VariableConstraint.string()` and `enumOf()` continues to work unchanged. New record component means canonical constructor arity changes — existing explicit `new StringConstraint(true)` calls need updating to `new StringConstraint(true, Map.of())` or should use factory methods.
**Trade-offs:** Record component addition changes canonical constructor arity. Serialization: Jackson with `@JsonCreator` or property-based deserialization handles new fields with defaults. The duplicate `VariableConstraint` in message-extraction-api (marked "retired" in #959 spec) is not updated — it's scheduled for removal.
**Sources:** VariableConstraint.java sealed interface, #959 design spec disposition table
**Exploration:** quick
**Status:** revised (R1-06: acknowledged real backward compat trade-offs)

## D4: Unified match with mode detection (Approach A)

**Choice:** Single `match` step with two modes detected by YAML structure
**Alternatives:**
- Approach B: template match as decorator on existing match — forces template matching through value-matching infrastructure that doesn't fit, loses `on:` syntax clarity
- Approach C: separate compilation/execution types under same YAML key — adds type complexity without user benefit, splits concept across two ResolvedStep variants
**Rationale:** Most natural mapping from the issue's YAML syntax. One match concept with clean branch points. Compiler detects mode (is `namespace:` present?), runtime detects mode (is `TemplateMatchSpec` present?). Handler blocks keyed by template name via `on:`. Both pipelines covered: Walker parses into extended ResolvedStep.MatchStep; PlaybookCompiler encodes template match as SetTask with runtime metadata (SWF SwitchTask can't express NLP matching).
**Trade-offs:** MatchCompiler and evaluateMatch() each have a mode branch, but share the dispatch-to-handler concept. Walker companion validation becomes conditional.
**Sources:** issue #970 YAML syntax, MatchCompiler.java, StructuralStepEvaluator.evaluateMatch(), Walker.java
**Exploration:** quick
**Status:** revised (R1-03/R1-08: acknowledged Walker invariant update, explicitly covered both pipelines)

## D5: Metadata accessed via registry lookup, not resolver propagation

**Choice:** Match step exposes `${_tmatch.namespace}` and `${_tmatch.template}` as context variables (prefix `_tmatch` to avoid collision with existing `match` scope). Downstream generation steps query the registry schema for metadata on demand. Compile-time validation ensures `_tmatch` context is available when generation steps reference it.
**Alternatives:**
- Metadata travels with values through resolver via `resolveWithMetadata()` — couples every variable resolution to metadata awareness, unnecessary complexity for static data
- Metadata bundled as `${vote.decision._meta.person}` nested alongside values — adds nesting complexity to the resolver for metadata that is static and schema-level
**Rationale:** Metadata is static (declared once in template definition, never changes per match). The registry already holds it. Downstream steps just need to know which template matched, then look up metadata when needed. No resolver changes required. Compile-time validation catches missing `_tmatch` context (generate step without preceding match in scope).
**Trade-offs:** Generation steps need registry access (same SPI pattern as compiler). One extra in-memory lookup per generation. The match step's registry query at match time discards the schema context — accepted trade-off for resolver simplicity.
**Sources:** UnifiedTemplateRegistry.schema(), TemplateSchema.variables(), VariableConstraint.metadata()
**Exploration:** quick
**Status:** revised (R1-07: renamed prefix to `_tmatch` to avoid collision with existing `match` scope, added compile-time validation of context availability)

## D6: TemplateMatchingFilter supersession

**Choice:** The new match template mode subsumes TemplateMatchingFilter's functionality and is part of the consumer migration path from #959/#961.
**Rationale:** TemplateMatchingFilter already does most of what template match mode needs (input → namespace match → field extraction → constraint validation → near-miss detection). The new match step replaces it at the playbook step level. TemplateMatchingFilter remains available during the transition period (existing playbooks using `templates:` section) but no new features will be added to it.
**Sources:** TemplateMatchingFilter.java, #959 design spec disposition table, #961 (consumer migration)
**Exploration:** quick
**Status:** captured (R1-09: explicitly documented supersession relationship)
