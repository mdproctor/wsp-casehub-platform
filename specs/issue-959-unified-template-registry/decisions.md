# Decisions — Issue #959: Unified Template Registry

## D1: Discrimination structure for candidate selection

**Choice:** Lemmatised keyword discrimination — upgrade existing keyword affinity filtering (TemplateKeywords) to operate on lemmatised tokens using the NLP pipeline. Templates register their lemmatised literal segments as keyword sets. Candidate selection computes lemma-overlap affinity between input and template keywords, pruning before full structural extraction. Positional discrimination (lemma trie) is a future optimisation reserved for when unified registry template counts exceed ~100 templates per registry.
**Alternatives:**
- Lemma trie (original D1) — positional trie where nodes are lemmas at specific template positions. O(template depth) lookup but high implementation complexity. Justified only at scale (hundreds+ templates). No evidence that near-term unified registries reach this threshold
- Inverted lemma index — simpler but less positional discrimination than a trie
- Hybrid (inverted index + positional verification) — best of both but more complexity for marginal gain over lemmatised keyword filtering
- Enhanced TemplateKeywords without lemmatisation — word-overlap affinity already exists in coordination-core; works for exact word matching but misses morphological variants (approve/approved/approves). Lemmatisation closes this gap with minimal new code
**Rationale:** TemplateKeywords.extract() and TemplateKeywords.affinity() in coordination-core already provide a discrimination mechanism: extract content keywords, compute word-overlap affinity, threshold to scope NLP candidates. Upgrading to operate on lemmatised tokens (using the same OpenNLP pipeline the NLP tier depends on) gives morphological discrimination (approve/approved/approves all reduce to "approve") with no new data structures. For realistic near-term template counts (10–50 per protocol, up to ~100 in a unified registry), this discrimination is sufficient — the asymptotic advantage of a positional trie only pays off at hundreds of templates.
**Trade-offs:** Loses positional discrimination — treats the template as a bag of lemmatised words. This is acceptable for near-term scale; positional discrimination can be added as a trie when template counts justify it. Requires the NLP tokenizer for lemmatisation at registration time (lazy — only when the NLP module is on the classpath; falls back to raw keyword matching otherwise).
**Sources:** TemplateKeywords in coordination-core (keyword extraction + affinity scoring), ProtocolEvaluator.scopeCandidates() (affinity threshold at 0.3), issue #922 spec D2 (two-tier matching)
**Exploration:** quick
**Status:** revised — removed Rete analogy (R1-02: alpha network discriminates by Java type, not token identity), acknowledged asymptotic advantage is marginal for near-term template counts (R1-03), added enhanced keyword filtering as the primary approach (R1-04)

## D2: NLP generation model

**Choice:** Template slot-filling for the first iteration — generation re-expands the template by substituting `${var}` placeholders with their extracted values via VariableResolver. No morphological rules, no POS-based verb conjugation. Templates are authored to be grammatically correct as-is; variable values slot into positions where any value produces correct grammar. POS metadata from the parsing pipeline is preserved in the template compilation output for future morphological enhancement.
**Alternatives:**
- Layered resolution with POS-driven morphological generation (original D2) — verb conjugation and determiner agreement from POS structure. Ambitious but premature: English morphological rules are irregular, the effort is substantial, and no concrete consumer requires subject-dependent generation yet
- ICU MessageFormat 2.0 — handles plural forms, gender selection, and ordinal formatting via standard CLDR data. Not a direct substitute: ICU MF2 is selector-based formatting (choose between pre-defined message variants), not morphological generation (transform verb forms based on POS analysis). The two are complementary, not competing. ICU MF2 is a viable path for future multilingual formatting when the need arises but doesn't address the specific problem D2 originally tried to solve (automatic verb conjugation from POS structure)
- Template-declared metadata (`${agent:3rd-singular}`) — heavier authoring, explicit but verbose
- Mandatory metadata (all-or-nothing) — rejects generation without full context
**Rationale:** "Grammatically correct surface form" (issue #959 requirement) is achieved by template slot-filling when templates are authored with grammar in mind — the template IS the grammatically correct form, variables slot into positions where any value is grammatically valid. This avoids the complexity of building custom morphological generation for English (irregular verbs, determiner rules, pronoun agreement) without evidence that subject-dependent generation is a concrete requirement. The POS metadata from NLP parsing is preserved, providing the foundation for morphological rules or ICU MF2 integration if the need is established.
**Trade-offs:** Generation cannot adapt grammatical forms to context (e.g., "She approves" vs "They approve"). This is acceptable for the first iteration — governed communications use prescribed templates where the subject is part of the template, not a variable requiring agreement.
**Sources:** VariableResolver in yaml-core (existing slot-filling), issue #922 spec D2 (two-tier matching, NLP pipeline), ICU MessageFormat 2.0 Tech Preview (CLDR data for 500+ locales)
**Exploration:** quick
**Status:** revised — simplified to template slot-filling (R1-05: custom morphological generation premature, ICU MF2 evaluated as future alternative), deferred POS-driven generation (R1-06: bidirectionality scope now explicit in D6), removed graceful degradation concern (R1-07: slot-filling has no quality variance)

## D3: Template type model in the registry

**Choice:** Single API type with two-tier compilation — consumers register templates as strings without choosing a matching strategy. At registration time, templates always compile to regex patterns (zero-dep, in template-registry-api). NLP structural patterns compile lazily on first NLP fallback attempt, only when the template-registry implementation module (with OpenNLP) is on the classpath. The unified registry provides a shared instance that replaces per-filter isolated ProtocolEvaluator instances — solving the lifecycle problem (each TemplateMatchingFilter creating its own evaluator with duplicate template registries).
**Alternatives:**
- Explicit template types (RegexTemplate vs NlpTemplate) — consumer controls strategy, more complex API, exposes an internal implementation distinction that consumers shouldn't care about
- All templates are NLP internally (original D3) — forces NLP compilation cost on regex-only consumers at registration time, violates the platform's opt-in extension pattern (ARC42STORIES.MD §4: "opt-in capabilities activate by classpath presence")
- Auto-detect with override — middle ground, still exposes the distinction
**Rationale:** The root problem identified in issue #959 is lifecycle: "each TemplateMatchingFilter creates its own isolated ProtocolEvaluator" — multiple evaluators with duplicate template registries. The unified registry solves this by providing a shared instance. The single-type API is a secondary benefit that simplifies the consumer surface. Two-tier compilation preserves the established opt-in pattern: regex is always available (zero-dep API module), NLP activates by classpath presence (impl module with OpenNLP). This mirrors the message-extraction-api / message-extraction split from issue #922.
**Trade-offs:** Consumers cannot force NLP-only matching. The registry always tries regex first. This is architecturally correct — regex is strictly more precise for exact matches, and the two-tier approach is proven in TwoTierMessageMatcher.
**Sources:** ProtocolEvaluator in coordination-core (ConcurrentMap of immutable TemplateRegistry instances), TwoTierMessageMatcher in message-extraction (regex first, NLP fallback), ARC42STORIES.MD §4 (opt-in extension pattern)
**Exploration:** quick
**Status:** revised — fixed root problem identification from type confusion to lifecycle (R1-09), restored opt-in NLP compilation to preserve zero-dep consumers (R1-08)

## D4: Module relationship — template-registry-api supersedes message-extraction-api

**Choice:** template-registry-api absorbs the useful types from message-extraction-api (NlpTokenizer, AnnotatedToken, MessageMatcher, RegexMessageMatcher compilation logic). message-extraction-api is retired. template-registry (impl) absorbs message-extraction's NLP code (StructuralPattern, TwoTierMessageMatcher's matching logic, OpenNlpTokenizer). VariableConstraint is NOT absorbed — yaml-core's `io.casehub.yaml.core.resolver.VariableConstraint` is the canonical definition. The duplicate in message-extraction-api (`io.casehub.extraction.VariableConstraint`) is eliminated; template-registry-api depends on yaml-core for VariableConstraint. yaml-core's TemplateRegistry (Builder → build() → immutable) continues to serve YAML variable resolution (forward direction). The unified registry supersedes TemplateRegistry's matching role — ProtocolEvaluator migrates from `TemplateRegistry.match()` to the unified registry's match API.
**Alternatives:**
- Depend on message-extraction-api — keeps it alive but was designed for a different model (MessageSchema/MessageType vs registry)
- Create a third VariableConstraint in template-registry-api — worsens duplication
- Replace yaml-core TemplateRegistry entirely — breaks TemplateExtractor's YAML variable resolution use case
- Extend yaml-core TemplateRegistry with NLP — couples NLP into a zero-dep Declaration Primitive module
- Coexist independently — maximum independence but ongoing duplication of VariableConstraint, RegexMessageMatcher logic, and the registry concept
**Rationale:** Single source of truth. The two stacks (protocol via TemplateRegistry and extraction via MessageMatcher) are parallel implementations of the same matching concept. Unifying eliminates duplication. VariableConstraint consolidation uses yaml-core as canonical to avoid a third copy — yaml-core is zero-dep and already the original source. yaml-core TemplateRegistry continues for its distinct purpose (YAML variable resolution via TemplateExtractor); the unified registry handles matching/extraction.
**Trade-offs:** Breaking change for consumers of message-extraction-api (migration to template-registry-api types). yaml-core TemplateRegistry and the unified registry coexist — they serve different purposes (variable resolution vs matching/extraction), so this is intentional, not duplication.
**Sources:** VariableConstraint in yaml-core (canonical, sealed interface), VariableConstraint in message-extraction-api (identical duplicate), TemplateRegistry in yaml-core (Builder → build() → match()), ProtocolEvaluator in coordination-core (uses TemplateRegistry for regex matching), issue #922 D8 (migration story)
**Exploration:** quick
**Status:** revised — addressed VariableConstraint consolidation with yaml-core as canonical (R1-10), added explicit yaml-core TemplateRegistry disposition (R1-11), fixed dependency chain: D4 is orthogonal to D3, no longer depends on single template type for module split (R1-12)

## D5: Integration test suite as acceptance criterion

**Choice:** The integration test suite IS the acceptance criterion. The implementation is not complete until tests demonstrate robustness across the full input spectrum and the full output pipeline.
**Scope — matching/extraction tests:**
- Short sentences (single clause, one variable)
- Long sentences (multi-clause, embedded variables)
- Multi-sentence paragraphs (protocol sentences in conversational prose)
- Variable type permutations (string × enum × optional, all combinations)
- Grammar variation (tense, plurals, contractions, determiners, auxiliaries)
- Score distribution (exact=1.0, NLP proportional, below-threshold rejects)
**Scope — generation tests:**
- Template slot-filling verification: values substituted correctly, output grammatically correct
- Bidirectional roundtrip: extract → generate → verify semantic equivalence
**Scope — structural mapping tests:**
- Extracted matches map to typed structures
- Structures can drive function calls (protocol actions)
- Structures can emit events (CDI/subscription pipeline)
- End-to-end: prose → match → extract → structure → function call / event emission
**Alternatives:** None — this is a hard requirement, not a choice
**Rationale:** The proof of a template matching system is in its behaviour across real input variation. Code correctness without demonstrated robustness is insufficient. The test suite documents the system's capabilities as executable specifications.
**Trade-offs:** Test suite is substantial work — but it's the only reliable way to validate NLP-based matching across grammar variation.
**Sources:** Existing TemplateExtractorTest (22 tests), TwoTierMessageMatcherTest (10 tests) — these set the baseline; the unified registry needs broader coverage
**Exploration:** quick (non-negotiable requirement from stakeholder)
**Status:** revised — generation test scope simplified to match D2's template slot-filling approach (removed metadata layering and graceful degradation tests)

## D6: Bidirectionality — template slot-filling for generation

**Choice:** Templates are bidirectional: parsers (input → extracted fields) and generators (fields → surface form). Generation uses template slot-filling — re-expanding the template with field values via VariableResolver. No morphological generation in the first iteration. The bidirectional promise is fulfilled because template slot-filling is sufficient for governed communications where templates are authored with grammar in mind.
**Alternatives:**
- Parsing only, no generation — consumers handle generation themselves. Rejects the stated requirement in issue #959 ("templates are bidirectional"). Would work for extraction-only consumers but leaves the generation contract unspecified
- POS-driven morphological generation — verb conjugation and determiner agreement from POS structure. Premature: no concrete consumer requires subject-dependent generation
- ICU MessageFormat 2.0 for generation — selector-based formatting for plural/gender/ordinal. Complementary to slot-filling, not a replacement. Valid future enhancement for multilingual support
- Generation delegated to callers — each consumer implements generation differently. Duplicates effort and risks inconsistency
**Rationale:** Issue #959 explicitly states "templates are bidirectional." The simplest fulfilment is template slot-filling — the template IS the grammatically correct surface form, and variable values slot into the designated positions. This covers the governed-communications use case where LLMs must conform to published schemas: the schema tells the LLM the template, the LLM fills in the values, the platform can re-generate the expected surface form from extracted values. Morphological generation is deferred until a concrete consumer requires subject-dependent grammatical adaptation.
**Trade-offs:** Cannot adapt grammatical forms to different subjects or contexts. This is a known limitation accepted for the first iteration.
**Sources:** Issue #959 ("templates are bidirectional"), VariableResolver in yaml-core, issue #922 spec
**Exploration:** surfaced by review (R1-06)
**Status:** captured

## D7: NlpProtocolMatcher SPI disposition — retire and absorb

**Choice:** NlpProtocolMatcher is retired. Its role (NLP fallback matching for protocol evaluation) is absorbed into the unified registry's internal NLP tier. ProtocolEvaluator migrates from its current architecture (TemplateRegistry for regex + optional NlpProtocolMatcher for NLP fallback) to the unified registry's match API (which handles both tiers internally). The NlpProtocolMatcher interface and its NlpMatch record are removed.
**Alternatives:**
- Implement NlpProtocolMatcher by bridging to message-extraction — simplest change (fills the existing SPI slot), but preserves a leaky abstraction. NlpProtocolMatcher.match(Map<String, String>, String) takes raw template strings and re-processes them on every call, duplicating the compilation work the registry already does
- Replace NlpProtocolMatcher with registry lookup — ProtocolEvaluator delegates to the unified registry but keeps NlpProtocolMatcher as a deprecated alias. Unnecessary indirection
- Keep NlpProtocolMatcher as an extension point — no consumer has ever provided an implementation. Zero implementations is evidence the SPI was premature. The unified registry provides the NLP capability directly
**Rationale:** NlpProtocolMatcher was designed as an extension point for NLP matching that ProtocolEvaluator could route through. It has zero implementations — the bridge to TwoTierMessageMatcher was never built (issue #959 explicitly notes this). The unified registry absorbs this role entirely: ProtocolEvaluator registers templates with the registry, and the registry handles both regex and NLP matching internally. Preserving a zero-implementation SPI alongside a registry that does the same thing adds complexity with no benefit.
**Trade-offs:** Removes an extension point. Any hypothetical consumer that wanted to plug in a custom NLP matcher must instead provide a custom NlpTokenizer implementation (via the NlpTokenizer SPI from D3/issue #922 D3), which is more precisely scoped.
**Sources:** NlpProtocolMatcher in coordination-core (interface, zero implementations), ProtocolEvaluator constructor (accepts nullable NlpProtocolMatcher), issue #959 ("NLP SPI exists but has no implementation")
**Exploration:** surfaced by review (R1-13)
**Status:** captured

## D8: Schema publication — registry-published sentence schemas for LLM governance

**Choice:** Each template type registered with the unified registry publishes a sentence schema. The schema includes: template patterns (the literal template strings), variable definitions (name, VariableConstraint), and an optional POS-annotated structural summary (when the NLP module is on the classpath). Schemas are queryable via the registry API: `registry.schema(templateName)` returns the published schema for a registered template type. Schema publication is part of registration — when templates are registered, their schemas are automatically available.
**Alternatives:**
- Schemas defined externally, independent of the registry — allows schema definition without registration. But governance requires that schemas and matching are co-located: the schema tells the LLM what to say, the registry validates what was said. Separating them risks drift
- Schemas as compile-time static artifacts (e.g., generated .json files) — static schemas can't reflect runtime-registered templates or dynamic protocol composition
- No schema publication (original decisions) — leaves one of issue #959's three top-level concerns unaddressed. LLMs have no machine-readable contract for expected sentence structure
**Rationale:** Issue #959's third concern: "Each NLP template publishes a sentence schema that tells LLMs the expected sentence structure. For governed communications, LLMs must conform to the published schema for mechanical detection and actioning." The schema is the contract between LLMs and the protocol engine. Co-locating schema publication with template registration ensures the schema always reflects the registered templates — no drift between what's declared and what's matched.
**Trade-offs:** Schema format must be designed. The schema needs to be consumable by LLM prompt construction (for instructions) and by governance validation (for conformance checking). Schema format design is deferred to the spec — this decision establishes the architectural principle.
**Sources:** Issue #959 (schema publication as top-level concern), ProtocolEvaluator's existing ProtocolDefinition (templates map, partially serves as schema today)
**Exploration:** surfaced by review (R1-14)
**Status:** captured

## D9: Concurrency model — immutable snapshots with atomic swap

**Choice:** The unified registry uses immutable snapshots with atomic swap for concurrency. Following ProtocolEvaluator's existing pattern: the internal index (discrimination structure, compiled templates) is immutable after build. Register/deregister operations build a new snapshot and atomically swap it via `AtomicReference` or `volatile` field. Readers see a consistent snapshot — no locking on the read path.
**Alternatives:**
- Mutable concurrent index (ConcurrentHashMap + read-write lock on trie) — allows fine-grained concurrent updates but adds locking complexity on the read path. Reads are the hot path; locking them is unacceptable
- Full rebuild on every registration (current ProtocolEvaluator approach per-protocol) — ProtocolEvaluator uses ConcurrentHashMap<String, TemplateRegistry> where each protocol has its own immutable registry. The unified registry is broader (all templates in one structure) but the same atomic-swap principle applies
- Copy-on-write collections — Java's CopyOnWriteArrayList pays the copy cost on every write. Acceptable for low-frequency registration, but a custom immutable snapshot gives more control over the discrimination structure
**Rationale:** The existing ProtocolEvaluator already solves this problem: `ConcurrentMap<String, TemplateRegistry>` where register/deregister replaces the entire registry atomically. The unified registry extends this to a single consolidated index. Register/deregister frequency is low (startup-time, protocol activation/deactivation); match frequency is high (every incoming message). Optimising the read path (no locks, no volatile reads beyond the snapshot reference) is the right trade-off.
**Trade-offs:** Full snapshot rebuild on every registration. For registries with hundreds of templates, the rebuild cost is measurable but bounded (template compilation is cached, only the index structure rebuilds). Registration is a startup-time operation, not a hot path.
**Sources:** ProtocolEvaluator in coordination-core (ConcurrentMap<String, TemplateRegistry>, atomic replace), TemplateRegistry.Builder → build() (immutable-after-build pattern)
**Exploration:** surfaced by review (R1-15)
**Status:** captured

## D10: Module hierarchy placement — Declaration Primitive + L4 Extension

**Choice:** template-registry-api is a Declaration Primitive (alongside yaml-core in ARC42STORIES.MD §5). Zero external dependencies. Contains: template registration API, regex compilation, VariableConstraint (re-exported from yaml-core), schema publication types. template-registry (impl) is an L4 Platform Extension. Contains: NLP structural matching (OpenNLP), lazy NLP compilation, OpenNlpTokenizer. This follows the established pattern: yaml-core (zero-dep Declaration Primitive) + coordination-core (uses yaml-core types with extensions).
**Alternatives:**
- L1 platform-api — platform-api should only contain types needed by multiple peer repos with no alternative source. Template matching is specific enough to warrant its own module
- A new layer (template infrastructure) — unnecessary layering. Declaration Primitives already serves this purpose
- Part of yaml-core — couples NLP registration API into yaml-core, which serves YAML variable resolution. Different concerns, different modules
- Part of coordination-core — coordination-core is a consumer of template matching, not the provider. The registry is a shared primitive used by coordination-core, governance, and other consumers
**Rationale:** template-registry-api is architecturally equivalent to yaml-core: a zero-dep Java module providing typed APIs for a specific platform concern. It follows the `@DefaultBean` displacement pattern for the registry implementation. The NLP impl module follows the L4 opt-in extension pattern — adding it to the classpath activates NLP structural matching.
**Trade-offs:** Adds two modules to the platform module taxonomy. This is consistent with the platform's "one concern, one module" principle.
**Sources:** ARC42STORIES.MD §5 (layer taxonomy, Declaration Primitives), yaml-core (zero-dep precedent), platform-api / platform (L1/L2 displacement pattern)
**Exploration:** surfaced by review (R1-16)
**Status:** captured
