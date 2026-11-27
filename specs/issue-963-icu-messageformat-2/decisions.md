## D1: MF2 integration point — MessageFormatResolver SPI

**Choice:** MessageFormatResolver `@FunctionalInterface` in `template-registry-api`. `InMemoryTemplateRegistry.generate()` accepts an optional resolver at construction. Templates with `messageFormat != null` delegate to the resolver. No resolver + MF2 template → fail-fast at registration.
**Alternatives:**
- Subclass override (Mf2TemplateRegistry extends NlpTemplateRegistry) — couples MF2 to NLP inheritance hierarchy, MF2 is orthogonal to matching
- Decorator/wrapper — needs access to TemplateDefinition internals not exposed on the SPI
**Rationale:** Follows the established classpath-activation pattern (MatchingStrategy, NlpTokenizerFactory). The API module stays zero-dep. Fail-fast at registration prevents runtime surprises.
**Trade-offs:** InMemoryTemplateRegistry constructor gains a nullable parameter.
**Sources:** MatchingStrategy SPI (template-registry-api), NlpTokenizerFactory SPI, NlpTemplateRegistry.buildNamespaceState() fail-fast pattern
**Exploration:** quick
**Status:** captured

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

**Choice:** Ship with ICU4J's standard function registry (`:plural`, `:select`, `:selectordinal`, `:number`, `:integer`, `:date`, `:time`, `:string`). No custom function SPI in v1.
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
