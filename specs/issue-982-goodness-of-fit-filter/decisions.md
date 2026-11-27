# Decisions — #982 Statistical Goodness-of-Fit Filter

## D1: Hybrid cascade pre-filter architecture

**Choice:** Three-tier cascade within the template matching pipeline — keyword affinity (free, tier 1) → embedding similarity (medium cost, tier 2) → LLM classification (expensive, tier 3 — already exists). Embedding tier acts as a second-chance rescue for candidates that keyword affinity rejected.
**Alternatives:**
- Replace keyword affinity entirely with embeddings — simpler but loses the free-tier fast path for easy matches
- Embedding-only without cascade — every match pays the embedding cost even when keywords would suffice
**Rationale:** Preserves the existing free keyword affinity path for cases where lexical overlap is sufficient. Only escalates to embedding when the cheap check fails. Matches the existing tiered architecture (regex → NLP → LLM).
**Trade-offs:** Slightly more complex matching logic in `matchInNamespace()`. Embedding calls add latency for synonym/paraphrase cases that keyword affinity can't handle.
**Sources:** NlpTemplateRegistry.matchInNamespace():113-169, AdaptiveTemplateRegistry.adaptiveFallback():129-176, LemmatisedKeywordFilter.affinity():63-71
**Exploration:** quick
**Status:** captured

## D2: Embedding model source

**Choice:** Use the existing `RoutingEmbeddingModel` via `ModelRegistry` — works with any registered backend (Ollama local, OpenAI remote, Gemini).
**Alternatives:**
- Local-only via Ollama — zero API calls but requires Ollama running
- Bundled ONNX model — no external service but adds ~80MB artifact
**Rationale:** Reuses existing platform infrastructure. No new dependency beyond `langchain4j-core`. Works with whatever embedding backend the deployment has configured.
**Trade-offs:** Requires at least one embedding-capable backend to be configured. Without one, the tier is silently inactive.
**Sources:** agent-router-core RoutingEmbeddingModel, EmbeddingModelBackend SPI
**Exploration:** quick
**Status:** captured

## D3: Learned synonym durability

**Choice:** Store learned synonym pairs as metadata on `TemplateNamespace` (`Map<String, Set<String>>` of lemma → synonyms). Lifecycle tied to namespace — replaced when namespace is replaced.
**Alternatives:**
- Separate `SynonymStore` SPI with inmem/JPA implementations — more flexible but adds a persistence module
- YAML seed file — simple and inspectable but no runtime durability between writes
**Rationale:** Namespace is the natural owner of synonym knowledge. No new SPI or persistence module. Synonyms are invalidated when the namespace is replaced, which is correct — new templates may have different vocabulary.
**Trade-offs:** Synonyms are lost when namespace is replaced (intentional — new templates may change vocabulary). No cross-namespace synonym sharing.
**Sources:** TemplateNamespace record, NlpTemplateCompiler.CompiledNlpTemplate
**Exploration:** quick
**Status:** captured

## D4: Module placement

**Choice:** Add embedding tier directly in `NlpTemplateRegistry` in the `template-registry` module. Adds `langchain4j-core` as an optional dependency.
**Alternatives:**
- In `template-registry-llm` alongside `AdaptiveTemplateRegistry` — cleaner dependency boundary but splits cascade across modules
- New `template-registry-embedding` module — maximum isolation but adds another module
**Rationale:** The embedding check is a natural extension of the keyword affinity check — same method, same loop, one more condition. Keeping it in `NlpTemplateRegistry` makes the cascade visible in one place.
**Trade-offs:** Adds `langchain4j-core` to `template-registry` dependencies (previously pure OpenNLP).
**Sources:** template-registry/pom.xml, NlpTemplateRegistry.matchInNamespace()
**Exploration:** quick
**Status:** captured

## D5: Activation model

**Choice:** Auto-activate when an `EmbeddingModel` is available (passed as nullable constructor parameter). Graceful fallback to keyword-only when null.
**Alternatives:**
- Explicit config flag `casehub.template.embedding.enabled` — safer but adds onboarding friction
**Rationale:** Zero-config for the happy path. Deployments without an embedding model configured get the same behavior as today.
**Trade-offs:** No explicit opt-out once an EmbeddingModel is on the classpath. Can be addressed later with a config flag if needed.
**Sources:** NlpTemplateRegistry constructor
**Exploration:** quick
**Status:** captured

## D6: Embedding similarity threshold

**Choice:** Default 0.5 cosine similarity for the embedding second-chance check. Overridable per-namespace (like existing `affinityThreshold`).
**Alternatives:**
- 0.4 — more aggressive rescue, higher false positive rate
- Per-namespace only, no global default — maximum control but more setup burden
**Rationale:** 0.5 catches clear semantic equivalence (synonyms typically 0.6-0.8) while filtering noise (unrelated inputs <0.3). Conservative enough to avoid flooding the structural matcher.
**Trade-offs:** Some edge-case paraphrases in the 0.4-0.5 range will be missed by default. Per-namespace override available for tuning.
**Sources:** LemmatisedKeywordFilter affinity threshold 0.3, NlpTemplateRegistry DEFAULT_AFFINITY_THRESHOLD
**Exploration:** quick
**Status:** captured

## D7: Integration architecture

**Choice:** Inline cascade in `NlpTemplateRegistry.matchInNamespace()`. EmbeddingModel as optional constructor parameter. No new classes for the pre-filter.
**Alternatives:**
- Strategy-based `CandidateFilter` interface — cleaner separation but premature abstraction
- Decorator subclass `EmbeddingNlpTemplateRegistry` — follows existing pattern but deepens inheritance chain to 4 levels
**Rationale:** Two known filter cases don't justify an interface. The inheritance chain is already 3 levels deep with `AdaptiveTemplateRegistry`. Inline cascade is simplest and most readable.
**Trade-offs:** `NlpTemplateRegistry.matchInNamespace()` grows slightly larger. Coupling to `EmbeddingModel` (nullable) in the class.
**Sources:** NlpTemplateRegistry.matchInNamespace():113-169, AdaptiveTemplateRegistry extends NlpTemplateRegistry
**Exploration:** quick
**Status:** captured

## D8: Synonym learning mechanism

**Choice:** Lemma-pair expansion — when embedding rescues a candidate, identify which template keywords had no match in input lemmas, find their nearest embedding neighbor in the input tokens, store as synonym pair on namespace metadata.
**Alternatives:**
- Full input embedding cache — cache vectors and do nearest-neighbor lookup. Faster repeats but doesn't improve keyword affinity tier.
**Rationale:** Teaches the cheap tier to handle future similar inputs. Over time, keyword affinity accumulates synonyms and the embedding tier fires less frequently. Interpretable — synonym pairs can be inspected.
**Trade-offs:** Per-token embedding calls needed to identify the matching lemma pair (one-time cost per rescue). Synonym quality depends on embedding model quality.
**Depends on:** D1 (cascade architecture), D3 (namespace metadata storage)
**Sources:** LemmatisedKeywordFilter.extract(), LemmatisedKeywordFilter.affinity()
**Exploration:** quick
**Status:** captured
