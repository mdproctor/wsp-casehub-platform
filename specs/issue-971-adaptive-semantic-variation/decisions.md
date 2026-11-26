## D1: Variation persistence strategy

**Choice:** In-memory only — variations stored in the registry's existing immutable snapshots, lost on restart
**Alternatives:**
- YAML corpus persistence (#969) — durable across restarts, but #969 isn't implemented yet and adds serialization scope
- Pluggable DataStore SPI — future-ready but SPI doesn't exist yet
**Rationale:** Keeps #971 focused on the semantic matching pipeline. The registry already uses immutable snapshots in memory; seeded/learned variations just add more patterns. Persistence is a separate concern.
**Trade-offs:** Variations lost on restart. LLM re-seeds on next startup (batch, cheap). Runtime-learned variations must be re-learned.
**Sources:** Issue #969, InMemoryTemplateRegistry snapshot model
**Exploration:** quick
**Status:** captured

## D2: Seeding integration with registration

**Choice:** Explicit seeder call before register — callers seed variations externally and add them as extra patterns to the TemplateDefinition before calling register()
**Alternatives:**
- Registry-integrated seeding — register() accepts/holds a VariationSeeder reference, triggers seeding internally. Tighter coupling, simpler for callers.
- Post-registration enrichment — register canonical first, then enrichWithVariations() adds seeded patterns. Two-step, allows async.
**Rationale:** Preserves the registry's zero-dep contract. The LLM concern stays at the boundary (caller/wiring layer), not inside the matching engine. The registry doesn't need to know whether patterns came from a human, YAML, or LLM — they're all just patterns.
**Trade-offs:** Callers must orchestrate seeding + collision checking + registration themselves. Slightly more wiring code.
**Depends on:** D1 (in-memory — no persistence layer to coordinate with)
**Sources:** UnifiedTemplateRegistry SPI, InMemoryTemplateRegistry.register(), template-registry-api zero-dep constraint
**Exploration:** quick
**Status:** captured

## D3: Learned variation mutation strategy

**Choice:** ~~Atomic replace via deregister + re-register~~ **REVISED:** Add `replaceOrRegister(TemplateNamespace)` to the `UnifiedTemplateRegistry` SPI — single CAS swap that removes old namespace and adds new one atomically. Issue #967 filed this but never implemented it. We implement it as part of #971.
**Alternatives:**
- Deregister + re-register — creates a window where the namespace is absent; any match() during the gap returns Unmatched. Not acceptable for governed protocol communications.
- New addVariation() method — changes the SPI with a narrow-purpose method. replaceOrRegister is more general and also serves #969's YAML reload use case.
- Separate variation overlay — learned variations in a parallel structure. Adds query complexity without benefit.
**Rationale:** replaceOrRegister provides true atomicity via single CAS swap in the immutable snapshot. No gap where the namespace is absent. Also needed by #969 for reloading YAML corpus files. Small SPI addition (one default method with deregister+register fallback for backward compat).
**Trade-offs:** Adds one method to UnifiedTemplateRegistry SPI. Rebuilds the entire namespace snapshot for each learned variation (acceptable: learning is rare).
**Depends on:** D2 (variations are patterns — no distinction between seeded and learned in the registry)
**Sources:** InMemoryTemplateRegistry.Snapshot, issue #967 (atomic namespace replace — open, not implemented), decision review R1-02
**Exploration:** quick
**Status:** revised

## D4: Module placement for variation SPIs

**Choice:** ~~SPIs in api, LLM impls in template-registry~~ **REVISED:** SPIs in template-registry-api (unchanged), LLM implementations in a new `template-registry-llm` module. template-registry keeps its current dependency profile (OpenNLP only).
**Alternatives:**
- LLM impls in template-registry — adds langchain4j/agent-api dependency to a pure NLP module, changing its architectural character
- Everything in template-registry — same coupling problem plus SPI visibility
**Rationale:** template-registry currently depends on OpenNLP only. Adding ChatModel/langchain4j would be a significant new coupling. The NlpTokenizer analogy breaks: NlpTokenizer has no external SDK dependency, but ChatModel does. A dedicated module preserves template-registry's dependency profile. The platform already has 100+ modules — one more for clean LLM/NLP separation follows established convention.
**Trade-offs:** Additional module. But template-registry-llm is small (LlmVariationSeeder, LlmAdaptiveFallback, AdaptiveTemplateRegistry, VariationSeedingService) and has a clear dependency boundary.
**Sources:** template-registry/pom.xml (no agent-api dependency), decision review R1-03
**Exploration:** quick
**Status:** revised

## D5: Adaptive fallback classification strategy

**Choice:** Single LLM call that classifies and extracts — AdaptiveFallbackMatcher sends input plus all candidate template patterns/variables to the LLM in one structured-output call. Returns either "no match" or {templateName, fields, suggestedVariation}. One call per miss.
**Alternatives:**
- Two-step: classify then extract — first call determines which template matches, second call extracts field values. More precise extraction but doubles latency and cost per miss.
**Rationale:** Modern LLMs handle classification + extraction in a single structured-output call reliably. Per-miss cost sensitivity makes doubling calls expensive. The suggestedVariation field lets the LLM produce a normalised pattern that the system registers for future structural matching.
**Trade-offs:** Single call is slightly less precise for complex extraction, but template variable schemas are simple enough (enum, string, clause) that this is not a practical concern.
**Depends on:** D4 (AdaptiveFallbackMatcher SPI in template-registry-api)
**Sources:** AgentProvider/ChatModel in agent-api, ResponseFormat structured output support
**Exploration:** quick
**Status:** captured

## D6: Collision guard placement

**Choice:** Standalone CollisionDetector utility in template-registry-api — a pure function that takes candidate variations + registry reference, loops over registry.match() for each candidate, rejects any that match a different template. No new SPI.
**Alternatives:**
- Built into VariationSeeder SPI — seeder takes registry reference and self-filters. Couples seeding to collision detection.
- Registry-side validation on register() — registry rejects namespaces with colliding patterns. Changes registry contract, makes registration O(patterns × templates).
**Rationale:** Keeps concerns separate. Collision detection is a policy decision — the caller decides whether a collision is a hard reject or a logged warning. Composes existing registry.match() operations.
**Trade-offs:** Callers must remember to call it. But both call sites (seeding orchestrator and adaptive fallback) are in the same module, so this is easy to enforce.
**Sources:** Issue #979 (cross-namespace ambiguity), issue body collision guard section
**Exploration:** quick
**Status:** captured

## D7: Language parameter strategy

**Choice:** Language on TemplateNamespace, not on individual method calls — add a language field to TemplateNamespace (defaults to "en"). The seeder and adaptive fallback read language from the namespace. match() signatures stay unchanged.
**Alternatives:**
- Language parameter on every method — match(input, language), seed(pattern, variables, language), classify(input, templates, language). Explicit but changes every SPI signature and forces callers to pass language even for English-only use.
**Rationale:** Language is a property of the template corpus, not of each match request. A namespace is authored in one language. The issue's YAML format already shows language: en as a namespace-level field. Avoids breaking SPI changes for a feature not yet used.
**Trade-offs:** Cannot match the same namespace in multiple languages simultaneously — but that's the right constraint: each language should be its own namespace (e.g. protocol:review:de).
**Sources:** Issue #971 i18n hooks section, issue #969 YAML corpus format (language field)
**Exploration:** quick
**Status:** captured
