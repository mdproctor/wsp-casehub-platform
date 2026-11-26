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

**Choice:** Atomic replace via deregister + re-register — the adaptive fallback builds a new TemplateNamespace including original patterns plus the learned variation, then atomically swaps via deregister(ns) + register(expandedNs)
**Alternatives:**
- New addVariation() method on the registry SPI — cleaner caller API but changes the SPI contract and needs a new snapshot operation
- Separate variation overlay — learned variations in a parallel structure, match checks main then overlay. No mutation of original namespace but adds query complexity
**Rationale:** Requires zero SPI changes. The existing deregister + register pair already provides atomic namespace replacement (#967). Learned variations are just patterns, same as seeded ones. The immutable-snapshot concurrency model means readers see either old or new state, never torn.
**Trade-offs:** Brief logical gap between deregister and register — but CAS retry handles contention. Rebuilds the entire namespace snapshot for each learned variation (acceptable: learning is rare, O(templates) not O(corpus)).
**Depends on:** D2 (variations are patterns — no distinction between seeded and learned in the registry)
**Sources:** InMemoryTemplateRegistry.Snapshot, issue #967 (atomic namespace replace)
**Exploration:** quick
**Status:** captured

## D4: Module placement for variation SPIs

**Choice:** SPIs in template-registry-api, LLM implementations in template-registry — VariationSeeder and AdaptiveFallbackMatcher are functional interfaces with no LLM dependency. LLM-backed implementations live in template-registry (which has CDI wiring) and inject ChatModel.
**Alternatives:**
- Everything in template-registry — simpler but puts the SPI where only one implementation can see it
- New template-registry-llm module — clean separation but adds a module for two classes
**Rationale:** Follows the established platform pattern: SPI in -api, impl in the runtime module. NlpTokenizer SPI is already in template-registry-api with OpenNlpTokenizer impl in template-registry. Keeps template-registry-api zero-dep.
**Trade-offs:** None significant — this is the standard platform convention.
**Sources:** NlpTokenizer in template-registry-api, OpenNlpTokenizer in template-registry
**Exploration:** quick
**Status:** captured

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
