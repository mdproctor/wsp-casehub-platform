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

**Choice:** Two modules: `message-extraction-api` (SPI types: NlpTokenizer, AnnotatedToken, MessageSchema, MessageType, MessageMatch, variable constraints) and `message-extraction` (regex matcher, structural matcher, pattern compiler, OpenNLP default NlpTokenizer, bundled OpenNLP models for English).
**Alternatives:**
- Single module with SPI and impl together — simpler, but API consumers forced to depend on OpenNLP transitively
- Three modules (-api, -core, -opennlp) — over-engineered before second impl exists
**Rationale:** Thin API module lets consumers (coordination-core, governance) depend on types without pulling OpenNLP. The impl module bundles the full two-tier engine (regex + NLP) together with OpenNLP models as classpath resources (~7–10MB for English: sentence detector, tokenizer, POS tagger, lemmatizer dictionary). Split -opennlp out when a second tokenizer impl arrives.
**Trade-offs:** Two modules instead of one. The API module is very small (interfaces + records). OpenNLP models bundled in the impl jar — consumers who depend on message-extraction-api only are unaffected.
**Depends on:** D1 (standalone), D3 (SPI)
**Sources:** casehub-platform module patterns (agent-api/agent-claude, platform-api/platform)
**Exploration:** quick
**Status:** revised — added explicit model distribution strategy (R1-10): OpenNLP models bundled as classpath resources in impl jar.

## D7: Output model — sealed match result

**Choice:** The extraction engine returns a sealed interface match result with Matched(templateName, params, score) and Unmatched(input) variants. This follows the existing ProtocolMatchResult pattern in coordination-core.
**Alternatives:**
- Function call model (original D5 framing) — implies a dispatch table mapping template names to handlers; more prescriptive than necessary for a standalone engine
- Event model — decoupled via event bus, but adds indirection without benefit for synchronous extraction
- Raw Map return — loses type safety and match/no-match distinction
**Rationale:** The sealed interface pattern is established in the platform (ProtocolMatchResult.Matched/Unmatched). It doesn't prescribe how consumers handle the result — pattern matching, dispatch table, or event emission are all consumer choices. Adding a score field (from the NLP structural matcher's coverage score) enables best-match selection when multiple templates partially match.
**Trade-offs:** Consumers must pattern-match on the sealed interface. This is intentional — it forces handling of both matched and unmatched cases.
**Depends on:** D1 (standalone engine)
**Sources:** ProtocolMatchResult sealed interface in coordination-core, issue #922 "Score by coverage. Select the best match."
**Exploration:** surfaced by review (R1-06)
**Status:** captured

## D8: Migration story — ProtocolEvaluator becomes a consumer

**Choice:** The message-extraction engine is the successor to TemplateExtractor/TemplateRegistry for response matching. ProtocolEvaluator in coordination-core becomes a consumer of message-extraction, delegating matching to the new engine instead of TemplateRegistry. TemplateExtractor in yaml-core continues to serve YAML variable resolution (forward direction) unchanged.
**Alternatives:**
- Run both systems in parallel — two template matching systems for the same purpose; maintenance and coherence problem
- Message-extraction replaces yaml-core TemplateExtractor entirely — breaks yaml-core's J2CL-safe zero-dep constraint
- ProtocolEvaluator delegates internally to message-extraction — coordination-core gains a new dependency, but this is the correct architectural direction
**Rationale:** TemplateExtractor serves two architecturally distinct purposes: YAML variable resolution (forward: template → rendered string) and protocol response matching (reverse: string → extracted variables). YAML variable resolution stays in yaml-core (zero-dep, J2CL-safe). Response matching moves to message-extraction, which provides the two-tier (regex + NLP) capability. ProtocolEvaluator gains a dependency on message-extraction-api (types) or message-extraction (full engine), replacing its current yaml-core TemplateRegistry dependency for matching.
**Trade-offs:** coordination-core gains a new module dependency. Migration is mechanical — ProtocolEvaluator.evaluate() changes from using TemplateRegistry.match() to using the new engine's match method. Existing ProtocolEvaluatorTest validates the same protocol-level behavior.
**Sources:** ProtocolEvaluator in coordination-core, TemplateExtractor/TemplateRegistry in yaml-core, VariableResolver in yaml-core (uses TemplateExtractor for forward resolution only)
**Exploration:** surfaced by review (R1-08)
**Status:** captured

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
