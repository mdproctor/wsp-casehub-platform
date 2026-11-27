# Decisions — #982 Statistical Goodness-of-Fit Filter

## D1: Hybrid cascade pre-filter architecture

**Choice:** Three-tier cascade within the template matching pipeline — keyword affinity (free, tier 1) → embedding similarity (medium cost, tier 2) → LLM classification (expensive, tier 3 — already exists). Embedding tier acts as a second-chance rescue for candidates that keyword affinity rejected.
**Alternatives:**
- Replace keyword affinity entirely with embeddings — simpler but loses the free-tier fast path for easy matches
- Embedding-only without cascade — every match pays the embedding cost even when keywords would suffice
**Rationale:** Preserves the existing free keyword affinity path for cases where lexical overlap is sufficient. Only escalates to embedding when the cheap check fails. Matches the existing tiered architecture (regex → NLP → LLM).
**Trade-offs:** Slightly more complex matching logic. Embedding calls add latency for synonym/paraphrase cases that keyword affinity can't handle.
**Sources:** NlpTemplateRegistry.matchInNamespace():119-169, AdaptiveTemplateRegistry.adaptiveFallback():129-176, LemmatisedKeywordFilter.affinity():63-71
**Exploration:** quick
**Status:** captured

## D2: Embedding model source

**Choice:** Use the existing `RoutingEmbeddingModel` via `ModelRegistry` — injected as the `EmbeddingModel` interface (from `langchain4j-core`) into the embedding tier in `template-registry-llm`. Works with any registered backend (Ollama local, OpenAI remote, Gemini). The registry class depends only on the `EmbeddingModel` interface, not on `RoutingEmbeddingModel` or `agent-router-core`.
**Alternatives:**
- Local-only via Ollama — zero API calls but requires Ollama running
- Bundled ONNX model — no external service but adds ~80MB artifact
**Rationale:** Reuses existing platform infrastructure. `template-registry-llm` already depends on `langchain4j-core`, so the `EmbeddingModel` interface is available with no new coupling. `RoutingEmbeddingModel` is wired at the application assembly layer — the registry never references it directly.
**Trade-offs:** Requires at least one embedding-capable backend to be configured. Without one, the tier is silently inactive.
**Sources:** agent-router-core RoutingEmbeddingModel, EmbeddingModelBackend SPI, template-registry-llm/pom.xml (langchain4j-core already present)
**Exploration:** quick
**Status:** captured

## D3: Learned synonym durability

**Choice:** ~~Store learned synonym pairs as metadata on `TemplateNamespace`~~ **REVISED:** Store learned synonym pairs as a `ConcurrentMap<String, Map<String, Set<String>>>` on the registry class itself, keyed by namespace name → lemma → synonyms. Lifecycle: cleared when a namespace is deregistered or replaced via `replaceOrRegister()`. LemmatisedKeywordFilter.affinity() receives the synonym map as a parameter and augments keyword matching.
**Alternatives:**
- Metadata on `TemplateNamespace` — infeasible: TemplateNamespace is an immutable record with exactly 4 fields (name, templates, language, version), no metadata field. Adding one breaks the immutability contract and the concurrency model (#959 D9)
- Store on `NlpTemplateCompiler.CompiledNlpTemplate` — closer to the matching pipeline but CompiledNlpTemplate is also immutable (List.copyOf in compact constructor). Would require a parallel data structure anyway
- Separate `SynonymStore` SPI with inmem/JPA implementations — more flexible but adds a persistence module
- YAML seed file — simple and inspectable but no runtime durability between writes
**Rationale:** Synonyms are a property of the matching pipeline (registry), not the template definition (namespace). The registry already maintains per-namespace compiled state (`nlpCompiled` ConcurrentMap in NlpTemplateRegistry). A parallel ConcurrentMap for synonyms follows the same pattern. Cleared on namespace replace — correct, since new templates may have different vocabulary.
**Trade-offs:** Synonyms are lost when namespace is replaced (intentional). No cross-namespace synonym sharing. Registry class gains one more ConcurrentMap field.
**Sources:** NlpTemplateRegistry.nlpCompiled (ConcurrentMap pattern), TemplateNamespace record (4 fields, immutable), #959 D9 (immutable snapshot concurrency model)
**Exploration:** quick
**Status:** revised — changed from TemplateNamespace metadata (infeasible) to ConcurrentMap on registry class (R1-03)

## D4: Module placement

**Choice:** ~~Add embedding tier directly in `NlpTemplateRegistry` in the `template-registry` module~~ **REVISED:** Add embedding tier in `template-registry-llm`, which already has `langchain4j-core` as a dependency and owns `AdaptiveTemplateRegistry`. `template-registry` retains its current dependency profile (OpenNLP only, no langchain4j).
**Alternatives:**
- In `template-registry` with `langchain4j-core` as optional dependency — contradicts #971 D4 (reviewed and revised to explicitly keep langchain4j out of template-registry)
- New `template-registry-embedding` module — maximum isolation but adds another module when `template-registry-llm` already serves this exact purpose
**Rationale:** #971 D4 was revised after review to create `template-registry-llm` specifically to hold langchain4j-dependent code, preserving `template-registry`'s dependency profile. template-registry-api is a Declaration Primitive (#959 D10) with zero external dependencies. template-registry depends only on template-registry-api and OpenNLP. Adding langchain4j-core to template-registry would reverse a reviewed decision. template-registry-llm already has the right dependency profile and the right class (AdaptiveTemplateRegistry) to host the embedding tier.
**Trade-offs:** Cascade spans two modules: keyword affinity/structural in template-registry, embedding/LLM in template-registry-llm. This is the established pattern — NLP matching in template-registry, LLM-dependent enhancements in template-registry-llm.
**Sources:** #971 D4 (reviewed rationale for module split), template-registry/pom.xml (OpenNLP only), template-registry-llm/pom.xml (langchain4j-core present), #959 D10 (Declaration Primitive zero-dep)
**Exploration:** quick
**Status:** revised — changed from template-registry to template-registry-llm to respect #971 D4 boundary (R1-02)

## D5: Activation model

**Choice:** ~~Auto-activate when an `EmbeddingModel` is available (passed as nullable constructor parameter)~~ **REVISED:** Classpath-based activation via `template-registry-llm` module. Adding `template-registry-llm` to the classpath activates the embedding tier (along with LLM classification). Removing the dependency reverts to keyword-only matching.
**Alternatives:**
- Nullable constructor parameter on `NlpTemplateRegistry` — contradicts platform opt-in extension pattern (ARC42STORIES.MD §4: "opt-in capabilities activate by classpath presence"). Also risks silent activation when any `EmbeddingModel` bean appears on the classpath for unrelated purposes (e.g. agent-router)
- Explicit config flag `casehub.template.embedding.enabled` — adds onboarding friction, inconsistent with module-level activation pattern
**Rationale:** Follows the established platform pattern (ARC42STORIES.MD §4): opt-in capabilities activate by classpath presence. `AdaptiveTemplateRegistry` in `template-registry-llm` already follows this pattern for LLM classification. The embedding tier follows the same activation model. Within `template-registry-llm`, the embedding check is active when an `EmbeddingModel` is injected and inactive otherwise — consistent with how `AdaptiveFallbackMatcher` activation works today.
**Trade-offs:** Cannot use embedding without also having LLM classification on the classpath. This is acceptable — embedding and LLM are complementary tiers in the same module.
**Sources:** ARC42STORIES.MD §4 (opt-in extension pattern), AdaptiveTemplateRegistry constructor (existing activation pattern), #971 D4 (module boundary)
**Exploration:** quick
**Status:** revised — changed from nullable constructor parameter to classpath-based activation via template-registry-llm (R1-07)

## D6: Embedding similarity threshold

**Choice:** Default 0.5 cosine similarity for the embedding second-chance check. Overridable per-namespace (like existing `affinityThreshold`).
**Alternatives:**
- 0.4 — more aggressive rescue, higher false positive rate
- Per-namespace only, no global default — maximum control but more setup burden
- Dynamic calibration at startup (run a standard probe set, determine threshold per model) — more accurate but adds startup cost and complexity
**Rationale:** 0.5 catches clear semantic equivalence (synonyms typically 0.6-0.8) while filtering noise (unrelated inputs <0.3). Conservative enough to avoid flooding the structural matcher. The threshold is model-dependent — different embedding models produce different cosine similarity distributions — but 0.5 is conservative enough to work across most models for the "clear synonym" use case. Per-namespace override provides deployment-specific calibration. Cosine similarity computation uses `Vectors.cosineSimilarity()` from `platform-api` (#134).
**Trade-offs:** Some edge-case paraphrases in the 0.4-0.5 range will be missed by default. Per-namespace override available for tuning. Production deployments should validate the threshold empirically against their configured embedding model.
**Sources:** LemmatisedKeywordFilter affinity threshold 0.3, NlpTemplateRegistry DEFAULT_AFFINITY_THRESHOLD, Vectors.cosineSimilarity() in platform-api (#134)
**Exploration:** quick
**Status:** captured

## D7: Integration architecture

**Choice:** ~~Inline cascade in `NlpTemplateRegistry.matchInNamespace()`~~ **REVISED:** Embedding rescue in `AdaptiveTemplateRegistry.match(namespaceName, input)`, between structural matching failure and LLM fallback. No new classes. `EmbeddingModel` as constructor parameter of `AdaptiveTemplateRegistry`. NlpTemplateRegistry is unchanged.
**Alternatives:**
- Inline in `NlpTemplateRegistry.matchInNamespace()` — adds langchain4j coupling to template-registry (contradicts #971 D4), grows an already-complex method (50+ lines), and runs embedding even for `AdaptiveTemplateRegistry` consumers where LLM fallback may catch the same cases
- Strategy-based `CandidateFilter` interface — premature abstraction for two known filter cases
- Decorator subclass `EmbeddingNlpTemplateRegistry` — deepens inheritance chain to 4 levels
**Rationale:** `AdaptiveTemplateRegistry.match(namespaceName, input)` already has the interception point: it calls `super.match()` → structural pipeline, then `adaptiveFallback()` → LLM classification. The embedding check slots naturally between these two. The cascade ordering is explicit: regex → keyword affinity → structural → **embedding rescue** → LLM classification. For standalone `NlpTemplateRegistry` consumers (no LLM tier), embedding is not available — consistent with not depending on langchain4j. For `AdaptiveTemplateRegistry` consumers, embedding reduces LLM invocations by catching synonym/paraphrase cases at lower cost.
**Trade-offs:** Standalone `NlpTemplateRegistry` consumers don't get embedding. This is architecturally correct — if you want language-model capabilities, depend on `template-registry-llm`.
**Sources:** AdaptiveTemplateRegistry.match(String,String):75-81 (interception point), #971 D4 (module boundary)
**Exploration:** quick
**Status:** revised — changed from inline in NlpTemplateRegistry to cascade in AdaptiveTemplateRegistry (R1-02, R1-08)

## D8: Synonym learning mechanism

**Choice:** Lemma-pair expansion — when embedding rescues a candidate, identify which template keywords had no match in input lemmas, find their nearest embedding neighbor in the input tokens, store as synonym pair on the registry's synonym map. Embedding calls are batched: one API call for all unmatched keyword lemmas, one for all input tokens, then pure vector math (cosine similarity via `Vectors.cosineSimilarity()`) for K×T comparisons.
**Alternatives:**
- Full input embedding cache — cache vectors and do nearest-neighbor lookup. Faster repeats but doesn't improve keyword affinity tier.
- Per-token embedding API calls — K × T API calls per rescue event. Prohibitively expensive at typical API latencies. Not the design — batching is mandatory.
**Rationale:** Teaches the cheap tier to handle future similar inputs. Over time, keyword affinity accumulates synonyms and the embedding tier fires less frequently. Interpretable — synonym pairs can be inspected. Batched embedding (2 API calls) makes the per-rescue cost bounded regardless of K and T.
**Trade-offs:** 2 embedding API calls per rescue event (one-time cost). Synonym quality depends on embedding model quality. Coordination with AdaptiveTemplateRegistry's variation learning: embedding rescue takes precedence (cheaper); if embedding rescues a match, synonym learning fires and variation learning does not. If embedding fails but LLM succeeds, variation pattern learning fires. Both paths do not fire for the same input on the same match attempt.
**Depends on:** D1 (cascade architecture), D3 (synonym map on registry class)
**Sources:** LemmatisedKeywordFilter.extract(), LemmatisedKeywordFilter.affinity(), Vectors.cosineSimilarity() in platform-api
**Exploration:** quick
**Status:** captured

## D9: Connectors statistical grammar disposition

**Choice:** Connectors' STT/TTS statistical grammar is not applicable to text template matching. The investigation directive in issue #982 is explicitly addressed and dismissed.
**Alternatives:**
- Reuse voice-sherpa's embedding+cosine pattern — the pattern (extract embedding → cosine distance → threshold matching) is conceptually similar to D1, but operates on fundamentally different input types (audio mel spectrograms → float[] speaker embeddings vs text tokens → text embeddings). No code-level reuse is possible
- Extract a shared statistical matching SPI from voice-sherpa — the shared concept is cosine similarity on vectors, which already exists in `Vectors.cosineSimilarity()` (#134). An additional SPI adds abstraction without value
**Rationale:** voice-sherpa's statistical grammar classes serve speaker identification and phoneme alignment: `CampplusSpeakerEmbeddingExtractor` extracts speaker embeddings from audio mel spectrograms using ONNX Runtime, `CosineDistanceSpeakerRegistry` identifies speakers by cosine distance on voice print vectors, `EspeakPhonemeAligner` aligns phonemes for pronunciation. These operate on float[] audio embeddings, not NLP text. The only shared infrastructure is vector cosine similarity, which `Vectors.cosineSimilarity()` in `platform-api` already provides. D1's cascade uses the same conceptual pattern (embedding → cosine similarity → threshold) but applied to text, with text-specific embedding models (via langchain4j `EmbeddingModel`).
**Trade-offs:** None — the investigation concludes no reusable code exists beyond the existing Vectors utility.
**Sources:** CampplusSpeakerEmbeddingExtractor (casehub-connectors voice-sherpa), CosineDistanceSpeakerRegistry (casehub-connectors voice-sherpa), EspeakPhonemeAligner (casehub-connectors voice-sherpa), Vectors.cosineSimilarity() in platform-api (#134)
**Exploration:** surfaced by review (R1-04)
**Status:** captured

## D10: ProtocolEvaluator call site disposition

**Choice:** `ProtocolEvaluator.scopeCandidates()` is out of scope for #982. Per #959 D7, ProtocolEvaluator is retired — its NLP matching role is absorbed into the unified template registry. The embedding improvement applies automatically to any consumer of the unified registry, including code that previously used ProtocolEvaluator.
**Alternatives:**
- Explicitly modify ProtocolEvaluator.scopeCandidates() — ProtocolEvaluator no longer exists in the codebase (retired per #959 D7). No call site to modify
- Dual implementation in both registries — duplicates effort for a deprecated code path
**Rationale:** #959 D7 explicitly retires ProtocolEvaluator and absorbs its role into the unified registry. Any code that previously called `ProtocolEvaluator.scopeCandidates()` now uses the unified registry's match API, where the embedding tier applies automatically.
**Trade-offs:** None — this is a consequence of the established #959 migration.
**Sources:** #959 D7 (NlpProtocolMatcher SPI disposition — retire and absorb), ProtocolEvaluator (no longer in codebase)
**Exploration:** surfaced by review (R1-06)
**Status:** captured

## D11: Similarity SPI boundary

**Choice:** No new similarity SPI in `template-registry-api`. The embedding tier uses `EmbeddingModel` (langchain4j interface) directly in `template-registry-llm`. Cosine similarity computation uses `Vectors.cosineSimilarity()` from `platform-api`.
**Alternatives:**
- `SemanticFilter` SPI in `template-registry-api` with langchain4j impl in `template-registry-llm` — preserves zero-dep boundary and enables alternative backends. Premature: one known implementation (langchain4j embedding), no concrete alternative backend requirement
- Reuse simulation framework's `SimilarityScorer<I>` from `simulation-api` — different purpose (simulation corpus matching), different type parameter semantics. SimilarityScorer scores query/candidate pairs for simulation NearestMatch strategy; template embedding compares lemma/token embeddings for semantic rescue. Conflating them couples unrelated concerns
**Rationale:** With D4 revised, the embedding tier is in `template-registry-llm`, which already depends on `langchain4j-core`. The `template-registry-api` zero-dep contract is not violated. Adding an SPI in template-registry-api for one implementation is unnecessary indirection. If a second similarity backend emerges, the SPI can be extracted at that point — the refactoring is mechanical (extract interface, move impl). For simulation (#294), the standard approach is to provide a test double for `EmbeddingModel` (langchain4j's existing test infrastructure), not to abstract the entire similarity pipeline.
**Trade-offs:** Direct langchain4j coupling in template-registry-llm. This is the module's stated purpose — it owns all langchain4j-dependent template matching enhancements.
**Sources:** Vectors.cosineSimilarity() in platform-api, SimilarityScorer in simulation-api, template-registry-llm/pom.xml (langchain4j-core)
**Exploration:** surfaced by review (R1-11, implicit decision)
**Status:** captured
