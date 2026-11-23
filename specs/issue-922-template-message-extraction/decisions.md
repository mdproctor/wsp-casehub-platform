# Decisions — #922 Template-Based Message Extraction

## D1: Standalone engine, not coupled to yaml-core

**Choice:** Message extraction is a standalone library with no dependency on yaml-core, playbooks, or any CaseHub-specific infrastructure.
**Alternatives:**
- Extend yaml-core TemplateExtractor — couples NLP into a zero-dep J2CL-safe module
- New module under yaml-* namespace — implies YAML coupling that doesn't exist
**Rationale:** The engine knows nothing about YAML or playbooks. It takes prose in, produces structured data out. YAML playbook integration is a consumer concern. This makes the engine reusable for the runtime service direction, LLM-generated processors, and non-playbook consumers.
**Trade-offs:** Consumers must build MessageSchema objects themselves rather than getting YAML-to-schema parsing for free. This is correct — the engine shouldn't prescribe serialization.
**Sources:** Existing TemplateExtractor/TemplateRegistry in yaml-core, ProtocolEvaluator in coordination-core
**Exploration:** deep-analysis
**Status:** captured

## D2: Two-tier matching — regex first, NLP structural fallback

**Choice:** Templates compile to both a regex pattern (for exact/near-exact matching) and an NLP structural pattern (POS-tag + lemma anchoring). The engine tries regex first. If regex fails, NLP structural matching provides a scored fallback. This makes NLP an optional runtime dependency — consumers always get deterministic regex matching; NLP adds robustness against grammatical variation.
**Alternatives:**
- Pure regex string patterns (existing TemplateExtractor approach) — handles exact matches but fails on grammatical variation (tense, number agreement) in literal template segments
- Enhanced regex with lightweight normalization (lowercasing, plural 's' stripping, optional articles) — handles some variation but cannot perform verb lemmatization (approved → approve) or structural matching generically
- Pure NLP structural matching (original D2 candidate) — POS tagger accuracy degrades on short utterances (primary input: 8–15 tokens, ~34% chance of at least one misclassification per sentence), and pays millisecond-scale latency even for exact matches
- LLM-in-the-loop extraction — expensive, non-deterministic, not auditable
**Rationale:** Protocol responses from well-prompted LLMs match templates exactly in the common case — regex handles this in microseconds with zero external dependencies. For the minority case where LLM output deviates (tense, number agreement, article variation), NLP structural matching provides a principled fallback with scored coverage. The two-tier approach resolves the tension between the bounded-variation premise (most LLM output follows templates) and the need for robustness (some output deviates). POS/lemma matching handles verb lemmatization (approve/approved/approves → approve) which simple regex normalization cannot do generically. The regex tier also subsumes the keyword pre-filter from issue #922 — it is strictly more precise and equally fast.
**Trade-offs:** Two matching tiers to implement and maintain. NLP fallback tier has accuracy risk on short utterances (~96% per-token POS accuracy on 10-token sentences means ~34% chance of one misclassification), but this only affects the fallback path — exact matches are handled deterministically by regex. OpenNLP adds ~7–10MB of binary models to the impl module.
**Sources:** Apache OpenNLP docs, GATE/JAPE pattern language, existing TemplateExtractor/TemplateRegistry in yaml-core, Penn Treebank accuracy benchmarks, issue #922 pipeline description
**Exploration:** deep-analysis
**Status:** revised — two-tier approach replaces pure NLP structural matching after review identified bounded-variation contradiction (R1-02) and POS accuracy risk on short sentences (R1-04). Regex tier subsumes keyword pre-filter from #922 (R1-09).

## D3: SPI for NLP tokenization, in a separate API module

**Choice:** NlpTokenizer is an SPI interface producing AnnotatedToken (surface, lemma, POS tag, offsets). OpenNLP is the default implementation. API types live in message-extraction-api; the OpenNLP implementation lives in message-extraction.
**Alternatives:**
- SPI and impl in the same module — forces OpenNLP as a transitive dependency on all consumers
- Hard-code OpenNLP — locks out alternatives (Stanford NLP, spaCy over gRPC, LLM-based tagger)
**Rationale:** Following the established platform pattern (agent-api/agent-claude, platform-api/platform). The SPI in a separate module lets consumers (coordination-core, governance) depend on types without pulling OpenNLP. Consistent with D6's module structure.
**Trade-offs:** Two modules from day one for a single implementation. Acceptable — the platform convention is established and the dependency isolation benefit is immediate.
**Depends on:** D1 (standalone engine)
**Sources:** casehub-platform SPI patterns (AccessControlProvider in platform-api, AgentProvider in agent-api, CaseMemoryStore in platform-api)
**Exploration:** quick
**Status:** revised — aligned with D6 module split (R1-03). Original "SPI and impl in the same module for now" contradicted D6's two-module structure.

## D4: Build-time schemas only for this iteration

**Choice:** Message schemas are defined at build time with fixed patterns. Runtime extensibility is a future direction but is not architecturally guaranteed by this iteration.
**Alternatives:**
- Full LLM generation pipeline now — scope too large for first iteration
- Runtime-only service — no build-time story, harder to test and debug
- Aspirational runtime extensibility claim (original D4) — data format may be runtime-compatible but computation model (hot-loading NLP models, pattern compilation latency on hot paths, thread-safe caches, cache invalidation for LLM-generated patterns) is unaddressed
**Rationale:** Set sentences are sufficient for the first use case (Qhorus governance). The data format (MessageSchema → patterns → MessageMatch) is designed to be runtime-compatible, but the computation model for runtime pattern compilation requires separate architectural work when LLM-generated processors become a concrete requirement.
**Trade-offs:** First iteration won't handle genuinely novel phrasings — only prescribed patterns. Runtime extensibility will require a separate design effort.
**Sources:** Issue #922 description
**Exploration:** quick
**Status:** revised — scoped to build-time only (R1-05). Dropped aspirational runtime extensibility claim — it was architecturally hollow without concrete model loading, compilation latency, and cache invalidation design.

## D5: Java DSL first, playbook integration layered on top

**Choice:** The core API is a Java DSL (builder pattern) that works standalone — no YAML, no playbooks required. YAML declaration and playbook integration are layered on top as a convenience, following the established CaseHub pattern. Any playbook app (starting with Qhorus governance) gets structured prose extraction as a generic capability.
**Alternatives:**
- YAML-first with Java as an afterthought — forces YAML parsing into the core, breaks for Java-only consumers
- Direct Qhorus-specific integration — not reusable across other playbook apps
**Rationale:** Java DSL first is the established CaseHub pattern. Java developers should be able to wire message extraction with pure code. YAML/playbook layering provides declarative convenience without coupling the core to it. The MessageSchema builder is the primary API; YAML parsing is a consumer-side concern.
**Trade-offs:** Two integration surfaces to maintain (Java DSL + YAML declaration). The DSL is the source of truth; YAML maps onto it.
**Depends on:** D1 (standalone engine), D4 (build-time schemas)
**Sources:** Issue #922, CaseHub pattern (e.g., TemplateRegistry.builder(), ProtocolDefinition)
**Exploration:** quick
**Status:** revised — removed "function call" output model framing (R1-06). Output model is now an explicit decision (D7).

## D6: Module structure

**Choice:** Two modules: `message-extraction-api` (SPI types + regex matcher: NlpTokenizer, AnnotatedToken, MessageSchema, MessageType, MessageMatch, MessageMatcher interface, RegexMessageMatcher, variable constraints — zero external dependencies) and `message-extraction` (NLP structural matcher, TwoTierMessageMatcher, OpenNLP default NlpTokenizer, bundled OpenNLP models for English).
**Alternatives:**
- Single module with SPI and impl together — API consumers forced to depend on OpenNLP transitively
- Three modules (-api, -core, -opennlp) — over-engineered; the regex matcher in -api eliminates the need for a separate -core
- Regex matcher in impl alongside OpenNLP (previous D6) — forces OpenNLP on consumers who only need exact matching, inflating coordination-core's transitive footprint from ~50KB (yaml-core) to ~7–10MB
**Rationale:** The regex matcher is pure Java with zero external dependencies — architecturally equivalent to TemplateExtractor in yaml-core. Placing it in -api means consumers like coordination-core get regex matching (identical capability to current TemplateExtractor) without pulling OpenNLP. The -impl module adds the NLP fallback tier on top: TwoTierMessageMatcher wraps RegexMessageMatcher (from -api) with NlpMessageMatcher to provide both tiers. This makes D2's two-tier approach genuinely modular: -api gives you the regex tier, -impl adds NLP. Follows the platform-api precedent where zero-dep final classes with operational logic (Path validation/parsing, PathParser static factories) coexist with interfaces and records.
**Trade-offs:** The -api module includes regex matching logic, not just types — but remains zero-dep, consistent with platform-api's constraint. Consumers who want the NLP fallback add message-extraction explicitly.
**Depends on:** D1 (standalone), D3 (SPI)
**Sources:** casehub-platform module patterns (agent-api/agent-claude, platform-api/platform), TemplateExtractor in yaml-core (zero-dep matcher precedent), Path/PathParser in platform-api (operational logic in -api precedent)
**Exploration:** quick
**Status:** revised — regex matcher moved from impl to -api module (R2-02). Previous placement forced ~7–10MB OpenNLP transitive on regex-only consumers like coordination-core. Model distribution strategy (R1-10): OpenNLP models bundled as classpath resources in impl jar.

## D7: Output model — sealed match result with tier-specific scoring

**Choice:** The extraction engine returns a sealed interface match result with Matched(templateName, params, score) and Unmatched(input) variants. Score semantics are tier-specific: regex tier produces score 1.0 (exact match); NLP tier produces a coverage score in (0, 1.0] based on the ratio of matched structural elements to total template elements. This follows the existing ProtocolMatchResult pattern in coordination-core.
**Alternatives:**
- Function call model (original D5 framing) — implies a dispatch table mapping template names to handlers; more prescriptive than necessary for a standalone engine
- Event model — decoupled via event bus, but adds indirection without benefit for synchronous extraction
- Raw Map return — loses type safety and match/no-match distinction
- Unscored match result — loses the ability to distinguish exact from approximate matches and to threshold on match quality
**Rationale:** The sealed interface pattern is established in the platform (ProtocolMatchResult.Matched/Unmatched). It doesn't prescribe how consumers handle the result. The score field enables consumers to: distinguish regex matches (1.0) from NLP matches (<1.0); reject low-confidence matches via threshold; select the best match when multiple templates partially match. Consumers using only the regex tier (via message-extraction-api) always see score 1.0.
**Trade-offs:** Consumers must pattern-match on the sealed interface. Score interpretation requires understanding tier semantics — mitigated by the clear 1.0 / (0, 1.0] boundary between tiers.
**Depends on:** D1 (standalone engine)
**Sources:** ProtocolMatchResult sealed interface in coordination-core, issue #922 "Score by coverage. Select the best match."
**Exploration:** surfaced by review (R1-06), score semantics specified (R2-03)
**Status:** revised — added explicit score semantics across tiers (R2-03). Regex tier: 1.0. NLP tier: coverage ratio in (0, 1.0].

## D8: Migration story — ProtocolEvaluator becomes a consumer of message-extraction-api

**Choice:** The message-extraction engine is the successor to TemplateExtractor/TemplateRegistry for response matching. ProtocolEvaluator in coordination-core depends on `message-extraction-api` (which includes RegexMessageMatcher — zero external deps), not `message-extraction` (which adds OpenNLP). TemplateExtractor in yaml-core continues to serve YAML variable resolution (forward direction) unchanged.
**Alternatives:**
- Run both systems in parallel — two template matching systems for the same purpose; maintenance and coherence problem
- coordination-core depends on message-extraction (full engine with OpenNLP) — changes coordination-core's transitive footprint from ~50KB (yaml-core, zero-dep) to ~7–10MB (OpenNLP + models), a ~200x increase not justified if regex matching suffices for the protocol use case
- Message-extraction replaces yaml-core TemplateExtractor entirely — breaks yaml-core's J2CL-safe zero-dep constraint
**Rationale:** ProtocolEvaluator's current matching via TemplateRegistry is regex-based. RegexMessageMatcher in message-extraction-api provides identical capability (compiled regex patterns, first-match-wins, variable extraction) with zero footprint increase — message-extraction-api is zero-dep, comparable to yaml-core. If the NLP fallback proves necessary for protocol evaluation, coordination-core can upgrade to depending on message-extraction without API changes (both tiers implement the same MessageMatcher interface). TemplateExtractor in yaml-core continues to serve YAML variable resolution (forward direction) unchanged.
**Trade-offs:** coordination-core gains a dependency on message-extraction-api (zero-dep, comparable footprint to yaml-core). Migration is mechanical: ProtocolEvaluator.evaluate() changes from TemplateRegistry.match() to RegexMessageMatcher.match(). No transitive footprint increase for coordination-core's consumers (playbook-compiler, etc.). If NLP fallback proves necessary later, the dependency can be upgraded to message-extraction — a deliberate opt-in, not a default.
**Sources:** ProtocolEvaluator in coordination-core, TemplateExtractor/TemplateRegistry in yaml-core, D6 module structure (regex matcher in -api), coordination-core pom.xml (current yaml-core dependency)
**Exploration:** surfaced by review (R1-08), dependency target and footprint refined (R2-01, R2-02)
**Status:** revised — dependency target resolved to message-extraction-api (R2-01). Transitive footprint concern eliminated by regex matcher placement in -api (R2-02).

## D9: Language scope — English only

**Choice:** The first iteration supports English only. POS tagger, tokenizer, and lemmatizer models are English-specific. Multi-language support requires additional OpenNLP models per language.
**Alternatives:**
- Multi-language from day one — requires bundling models for each language (5–10MB per language), increasing the dependency footprint substantially
- Language-agnostic structural matching — not feasible; POS tagging and lemmatization are inherently language-specific
**Rationale:** CaseHub governance protocols are currently English-only. The NlpTokenizer SPI (D3) supports future multi-language extension — a consumer provides a language-specific NlpTokenizer implementation with the appropriate models. Bundling models for languages without a concrete consumer is unnecessary complexity. The regex tier (D2) is language-agnostic and always available regardless of language scope.
**Trade-offs:** Non-English deployments cannot use the NLP fallback tier. The regex tier works for any language.
**Depends on:** D2 (two-tier matching), D3 (NlpTokenizer SPI)
**Sources:** OpenNLP model availability per language
**Exploration:** surfaced by review (R1-12)
**Status:** captured
