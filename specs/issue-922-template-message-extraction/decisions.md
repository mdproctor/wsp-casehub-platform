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

## D2: NLP structural matching, not string interpolation

**Choice:** Templates compile to NLP structural patterns (POS-tag + lemma matching), not regex string patterns. The displayed template text is a rendered approximation for human understanding — the structural pattern is what actually matches.
**Alternatives:**
- Regex string patterns (existing TemplateExtractor approach) — breaks on grammatical variation (singular/plural, tense, articles)
- LLM-in-the-loop extraction — expensive, non-deterministic, not auditable
**Rationale:** LLMs are instructed to follow template structures, so variation is bounded. POS/lemma matching handles grammatical agreement (approve/approves/approved, item/items, a/an) mechanically. Rule-based extraction outperforms ML here: deterministic, auditable, no training data.
**Trade-offs:** Requires an NLP tokenizer dependency (OpenNLP). Heavier than pure regex. POS tagging can misclassify tokens in short utterances.
**Sources:** Apache OpenNLP docs, GATE/JAPE pattern language, ICU MessageFormat (generation-only, no reverse parsing)
**Exploration:** deep-analysis
**Status:** captured

## D3: SPI for NLP tokenization

**Choice:** NlpTokenizer is an SPI interface producing AnnotatedToken (surface, lemma, POS tag, offsets). OpenNLP is the default implementation. SPI and default impl live in the same module for now.
**Alternatives:**
- Separate -api and -opennlp modules from day one — premature module split before a second impl exists
- Hard-code OpenNLP — locks out alternatives (Stanford NLP, spaCy over gRPC, LLM-based tagger)
**Rationale:** The structural matcher needs tokens with POS tags and lemmas. It shouldn't care where they come from. SPI in the main module, extract when a second implementation materialises.
**Trade-offs:** Single module means OpenNLP is a transitive dependency even if someone only wants the SPI types. Acceptable until a second impl exists.
**Depends on:** D1 (standalone engine)
**Sources:** casehub-platform SPI patterns (AccessControlProvider, CaseMemoryStore, etc.)
**Exploration:** quick
**Status:** captured

## D4: Set sentences at build time, extensible toward runtime

**Choice:** For this iteration, message schemas are defined at build time with fixed patterns. The architecture must support future LLM-generated processors and a runtime service without redesign.
**Alternatives:**
- Full LLM generation pipeline now — scope too large for first iteration
- Runtime-only service — no build-time story, harder to test and debug
**Rationale:** Set sentences are sufficient for the first use case (Qhorus governance). LLMs are instructed to follow the patterns, so rigid structural matching works. The data format (MessageSchema → structural patterns → MessageMatch) is the same whether schemas are built at compile time or generated at runtime.
**Trade-offs:** First iteration won't handle genuinely novel phrasings — only prescribed patterns. This is by design: NLP matches first, LLM fallthrough later.
**Sources:** Issue #922 description
**Exploration:** quick
**Status:** captured

## D5: Java DSL first, playbook integration layered on top

**Choice:** The core API is a Java DSL (builder pattern) that works standalone — no YAML, no playbooks required. YAML declaration and playbook integration are layered on top as a convenience, following the established CaseHub pattern. Any playbook app (starting with Qhorus governance) gets structured prose extraction as a generic capability. The extraction engine produces a function call with typed variables that the consumer actions.
**Alternatives:**
- YAML-first with Java as an afterthought — forces YAML parsing into the core, breaks for Java-only consumers
- Direct Qhorus-specific integration — not reusable across other playbook apps
**Rationale:** Java DSL first is the established CaseHub pattern. Java developers should be able to wire message extraction with pure code. YAML/playbook layering provides declarative convenience without coupling the core to it. The MessageSchema builder is the primary API; YAML parsing is a consumer-side concern.
**Trade-offs:** Two integration surfaces to maintain (Java DSL + YAML declaration). The DSL is the source of truth; YAML maps onto it.
**Depends on:** D1 (standalone engine), D4 (build-time schemas)
**Sources:** Issue #922, CaseHub pattern (e.g., TemplateRegistry.builder(), ProtocolDefinition)
**Exploration:** quick
**Status:** captured

## D6: Module structure

**Choice:** Two modules: `message-extraction-api` (SPI types: NlpTokenizer, AnnotatedToken, MessageSchema, MessageType, MessageMatch, variable constraints) and `message-extraction` (structural matcher, pattern compiler, OpenNLP default NlpTokenizer).
**Alternatives:**
- Single module with SPI and impl together — simpler, but API consumers forced to depend on OpenNLP transitively
- Three modules (-api, -core, -opennlp) — over-engineered before second impl exists
**Rationale:** Thin API module lets consumers (coordination-core, governance) depend on types without pulling OpenNLP. The impl module bundles the matcher + OpenNLP default together. Split -opennlp out when a second tokenizer impl arrives.
**Trade-offs:** Two modules instead of one. The API module is very small (interfaces + records). Worth it for clean dependency management.
**Depends on:** D1 (standalone), D3 (SPI)
**Sources:** casehub-platform module patterns (agent-api/agent-claude, platform-api/platform)
**Exploration:** quick
**Status:** captured
