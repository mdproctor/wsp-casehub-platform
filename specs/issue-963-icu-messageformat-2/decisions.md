## D1: MF2 integration point — MessageFormatResolver SPI in NlpTemplateRegistry

**Choice:** `MessageFormatResolver` multi-method interface in `template-registry-api` with `compile()` (registration time) and `format()` (generation time). Injected into `NlpTemplateRegistry` via CDI producer — not on `InMemoryTemplateRegistry`. The base class (Declaration Primitive) stays unchanged.
**Alternatives:**
- Nullable constructor on InMemoryTemplateRegistry — rejected: contradicts platform opt-in pattern (#982 D5 explicitly rejected this); pollutes Declaration Primitive with optional capability
- Subclass override (Mf2TemplateRegistry extends NlpTemplateRegistry) — couples MF2 to NLP inheritance hierarchy unnecessarily
- Decorator/wrapper — needs access to TemplateDefinition internals not exposed on the SPI
- GenerationStrategy SPI (parallel to MatchingStrategy) — over-engineered for a single-concern extension; matching needs strategies because different language families use fundamentally different algorithms; generation has only two modes (slot-fill and MF2)
**Rationale:** Follows the established subclass extension pattern (NlpTemplateRegistry adds NLP matching, now also adds MF2 generation). The resolver SPI separates compilation (registration) from formatting (generation), matching the MatchingStrategy precedent. The API module stays zero-dep.
**Trade-offs:** MF2 generation is only available when NlpTemplateRegistry is on the classpath (not with bare InMemoryTemplateRegistry). This is acceptable — MF2 is a production feature, not a testing primitive.
**Sources:** MatchingStrategy SPI (multi-method: buildIndex/selectCandidates/match), #982 D5 (rejected nullable constructor), NlpTemplateRegistry.buildNamespaceState() fail-fast pattern
**Exploration:** quick → revised after decision review (R1-01, R1-02)
**Status:** revised

## D2: MF2 pattern location — field on TemplateDefinition

**Choice:** Nullable `messageFormat` field on `TemplateDefinition` record. Builder gets `.messageFormat(String)`. Defaults to null for backward compatibility.
**Alternatives:**
- Separate MF2 registry — split source of truth, registration/deregistration coordination
- Namespace-level metadata map — indirection, sync risk between templates and messageFormats maps
**Rationale:** The template definition is the natural home for everything about a template. Co-locates matching patterns and generation format. Nullable field is the simplest model.
**Trade-offs:** TemplateDefinition grows a field most templates won't use.
**Sources:** TemplateDefinition record (template-registry-api), TemplateNamespace (already has language field)
**Exploration:** quick
**Status:** captured

## D3: Module structure — single template-registry-mf2

**Choice:** Single `template-registry-mf2` module. Dependencies: `template-registry-api` + `com.ibm.icu:icu4j:79.1`. CDI `@ApplicationScoped` bean for classpath activation.
**Alternatives:**
- Split mf2-api + mf2-impl — no alternative MF2 implementations exist; the SPI is already in template-registry-api
**Rationale:** Mirrors `template-registry-nlp-svo` pattern exactly. SPI in API module, implementation in extension module.
**Trade-offs:** ICU4J is ~14 MB. Consumers that want MF2 pay the size cost.
**Sources:** template-registry-nlp-svo module structure, platform classpath-activation pattern (ARC42STORIES §4)
**Exploration:** quick
**Status:** captured

## D4: Variable type handling — string coercion in adapter

**Choice:** Keep `Map<String, String>` as the public API. MF2 adapter parses string values to typed values per the MF2 pattern's function annotations (`:integer`, `:number`, `:date`). ICU4J's `MessageFormatter` receives the coerced `Map<String, Object>` internally.
**Alternatives:**
- Change to Map<String, Object> — breaking API change, asymmetry with matching (which returns Map<String, String>)
- Overloaded generate() with both signatures — more API surface without clear benefit
**Rationale:** Matching always extracts strings. Generation accepting strings is consistent. MF2's function annotations declare types — the string is transport, coercion is the adapter's job.
**Trade-offs:** Slight runtime cost for string→type parsing (negligible on the generation path). Coercion failure semantics must be clear.
**Sources:** UnifiedTemplateRegistry.generate() signature, TemplateMatch.Matched.fields() returns Map<String, String>, ICU4J MessageFormatter API
**Exploration:** quick
**Status:** captured

## D5: MF2 pattern validation timing — eager at registration

**Choice:** MF2 patterns are parsed and validated at registration time. Invalid patterns cause `register()` to throw `IllegalArgumentException`. Pre-compiled `MessageFormatter` instances are cached for fast generation.
**Alternatives:**
- Lazy validation at generate() time — broken templates discovered in production, inconsistent with regex/NLP validation timing
**Rationale:** Consistent with regex compilation (Snapshot.withNamespace) and NLP index building (NlpTemplateRegistry.buildNamespaceState). Fail-fast at startup.
**Trade-offs:** Registration time increases slightly (negligible MF2 parsing cost).
**Sources:** InMemoryTemplateRegistry.Snapshot.withNamespace() (regex compilation), NlpTemplateRegistry.buildNamespaceState() (NLP index building)
**Exploration:** quick
**Status:** captured

## D6: Schema publication — structured MessageFormatSchema

**Choice:** Extend `TemplateSchema` with a nullable `MessageFormatSchema` record containing the MF2 pattern, selectors (variable name + function), and variant keys. Published alongside structural summaries.
**Alternatives:**
- Raw MF2 pattern string in schema — less structured, LLMs may not parse MF2 syntax reliably
**Rationale:** The schema is for LLM and tooling consumption. Structured data (selectors, variants) is more actionable. Follows the existing StructuralSummary pattern (optional metadata populated when the right module is on the classpath).
**Trade-offs:** Adds types to template-registry-api (MessageFormatSchema, SelectorInfo records).
**Sources:** TemplateSchema.StructuralSummary pattern, @McpDomain("template-schemas") endpoint
**Exploration:** quick
**Status:** captured

## D7: ICU4J API stability — thin adapter with version-pinned dependency

**Choice:** The `MessageFormatResolver` SPI (D1) IS the insulation boundary. ICU4J's `MessageFormatter` is wrapped in a thin adapter. Version pinned in BOM.
**Alternatives:**
- Direct ICU4J types in platform API — ties platform to Draft-status API
**Rationale:** Naturally follows from D1. The SPI boundary insulates consumers from ICU4J evolution.
**Trade-offs:** Thin adapter adds trivial indirection.
**Depends on:** D1 (MessageFormatResolver SPI provides the insulation boundary)
**Sources:** ICU4J 79 MessageFormatter API (Draft status since ICU 78), CLDR 47 MF2 spec (stable)
**Exploration:** quick
**Status:** captured

## D8: Custom MF2 functions — built-ins only, extension deferred

**Choice:** Ship with MF2's built-in functions (`:string`, `:number`, `:integer`, `:date`, `:time`, `:datetime`). Pluralization via `:integer`/`:number` selection, gender via `:string`, ordinals via `:integer select=ordinal`. No custom function SPI in v1.
**Alternatives:**
- Custom function registry from day one (Mf2FunctionProvider CDI SPI) — YAGNI, no concrete use case, complex to design while ICU4J function API is Draft
**Rationale:** All stated use cases (plural, gender, ordinal, number, date) are covered by built-in functions. The thin adapter design makes adding an extension point later non-breaking.
**Trade-offs:** A consumer needing a domain-specific selector (e.g., `:case-status`) cannot add one until the extension point ships.
**Sources:** ICU4J MessageFormatter standard function set, issue #963 scope (plural, gender, ordinal)
**Exploration:** quick
**Status:** captured

## D9: YAML declaration syntax — sibling message-format: key

**Choice:** `message-format:` as a sibling key alongside `patterns:` in YAML template definitions. YAML block scalar (`|`) preserves MF2 multiline syntax. Optional — absent means slot-fill generation.
**Alternatives:**
- Inline MF2 in patterns list (prefix detection) — fragile magic prefix, mixes syntaxes
- Separate mf2-patterns: list — over-engineered, MF2 handles multi-locale via CLDR internally
**Rationale:** Clean separation of matching patterns from generation format. Backward compatible. YAML block scalars handle MF2's multiline syntax naturally.
**Trade-offs:** Template YAML declarations can grow larger when MF2 is used (MF2 patterns are verbose).
**Sources:** Existing YAML template syntax, TemplateNamespace YAML parsing
**Exploration:** quick
**Status:** captured

## D10: MF2 is generation-only — matching unchanged

**Choice:** MF2 affects only the generation path (`generate()`). Matching (regex + NLP structural) is unchanged. MF2 syntax (`.match`/`when` variant selection) is not used for input matching — it selects output forms, not input patterns. Authors are responsible for ensuring matching patterns cover the surface forms MF2 can generate.
**Alternatives:**
- MF2 patterns inform matching (extract variants as matching patterns) — MF2 syntax is designed for output selection, not extraction; variant text contains formatting placeholders that differ from matching variable positions
**Rationale:** MF2's `.match`/`when` structure selects between pre-defined output variants based on variable values and CLDR rules. This is fundamentally different from template matching which extracts variable values from free-form input. The bidirectionality contract from #959 D6 holds at the template level (each template can match and generate) but the mechanisms differ.
**Trade-offs:** Matching patterns and MF2 generation patterns are authored separately — they can drift. An MF2 template might generate a form that the matching patterns don't recognise, or matching patterns might accept input that MF2 can't generate. Authors must maintain coherence manually. Testing (generate → match round-trip) is the validation mechanism.
**Sources:** MF2 specification Part 9 of LDML (variant selection semantics), #959 D6 (bidirectional template contract), decision review R1-09
**Exploration:** quick (surfaced by decision review)
**Status:** captured
