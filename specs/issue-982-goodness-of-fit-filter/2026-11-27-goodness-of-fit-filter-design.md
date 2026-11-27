# Design: Statistical Goodness-of-Fit Filter (#982)

## Problem

The keyword affinity pre-filter in `NlpTemplateRegistry` uses bag-of-words lemma overlap (`LemmatisedKeywordFilter.affinity()`). When template vocabulary and input vocabulary are semantically equivalent but lexically different — synonyms, paraphrases — affinity is zero and valid candidates are silently dropped before the structural matcher ever sees them.

Example: Template "Raising ${target} to ${level}" with input "I escalated this to the manager" — keyword overlap is zero because "raise" and "escalate" are different lemmas. The structural matcher never runs. The LLM tier (tier 3) could catch it, but it's expensive and shouldn't be the primary safety net for synonym gaps.

## Architecture Overview

Add an embedding-based rescue tier inside `AdaptiveTemplateRegistry` (in `template-registry-llm`). The full cascade:

```
Input arrives
  → Tier 0: Regex exact match (InMemoryTemplateRegistry)
    → Tier 1: Keyword affinity → Structural matcher (NlpTemplateRegistry)
      → Tier 2: Embedding similarity rescue (NEW — AdaptiveTemplateRegistry)
        → Tier 3: LLM classification (AdaptiveTemplateRegistry — existing)
```

Each tier is cheaper than the next. The system learns from expensive tiers to train cheaper ones — over time, keyword affinity accumulates synonyms and the embedding tier fires less frequently.

### Module Boundary

`template-registry` stays behind the `NlpTokenizer` SPI with `OpenNlpTokenizer` as its current implementation. No LangChain4j dependency. All embedding and LLM code stays in `template-registry-llm`, which already depends on `langchain4j-core`. Classpath-based activation — adding `template-registry-llm` turns on both embedding and LLM tiers. This respects the boundary established in #971 D4.

### NlpTemplateRegistry Protected Accessors

`AdaptiveTemplateRegistry` needs access to the NLP compiled templates, tokenizer, and affinity threshold to run embedding rescue and synonym-aware keyword affinity. `NlpTemplateRegistry` gains three protected accessor methods:

- `protected NlpTokenizer tokenizer()` — needed for input tokenization in embedding rescue and structural matching
- `protected double affinityThreshold()` — needed for synonym-aware keyword affinity check
- `protected ConcurrentMap<String, CompiledNlpTemplate> nlpCompiled()` — needed for keyword sets and structural matchers

These are minimal visibility changes — `protected` accessor methods, no field visibility changes. The fields remain `private final`. This is the same pattern used by `InMemoryTemplateRegistry` which exposes `currentSnapshot()`, `compareAndSetSnapshot()`, and `getNamespaceFromSnapshot()` as protected methods.

### Constructor Change

`AdaptiveTemplateRegistry` gains `EmbeddingModel` (nullable) and `embeddingSimilarityThreshold` (default 0.5) constructor parameters:

```java
public AdaptiveTemplateRegistry(NlpTokenizer tokenizer,
                                AdaptiveFallbackMatcher fallbackMatcher,
                                double confidenceThreshold,
                                ClassificationCache classificationCache,
                                EmbeddingModel embeddingModel,          // nullable
                                double embeddingSimilarityThreshold)    // default 0.5
```

When `embeddingModel` is null, the embedding tier is inactive — `embeddingRescue()` returns `Unmatched` immediately. The synonym learning threshold (0.7) is an internal constant, not a constructor parameter — it's a quality gate that rarely needs tuning.

## Embedding Infrastructure

### Template Embeddings (Registration Time)

When `AdaptiveTemplateRegistry.register()` or `replaceOrRegister()` is called and an `EmbeddingModel` is available, compute embeddings for each template pattern's keyword set:

1. Extract keyword lemmas via `LemmatisedKeywordFilter.extract(pattern, tokenizer)` (existing)
2. Join lemmas into a phrase
3. Embed via `EmbeddingModel.embed()` — one call per pattern
4. Store in a `ConcurrentMap<String, List<float[]>>` keyed by `namespace:templateName`, parallel to `nlpCompiled`

This gives a semantic fingerprint of "what this pattern is about" without variable placeholders or optional segments.

### Input Embedding (Match Time)

When a candidate pattern fails keyword affinity and needs the embedding rescue, embed the input's keyword lemmas — not the full input text. Extract content lemmas via `LemmatisedKeywordFilter.extract()` (stop words removed), join into a phrase, embed that phrase. This produces a **symmetric comparison**: both template and input embeddings represent keyword-level semantics stripped of stop words and variables.

Asymmetric comparison (keyword phrase vs full sentence) produces unreliable cosine similarity scores because sentence embedding models are optimized for sentence-to-sentence comparison. Comparing "raise" (bare keyword) against "I escalated this to the manager" (full sentence) gives low scores regardless of semantic relatedness — the surrounding words dilute the signal.

One `EmbeddingModel.embed()` call per match attempt that reaches tier 2 — the input keyword embedding is computed once and reused across all candidate patterns in the namespace.

### Similarity Computation

For each candidate pattern that failed keyword affinity, compute `Vectors.cosineSimilarity()` (from `platform-api`) between the input keyword embedding and that pattern's keyword embedding. If the similarity exceeds the threshold (default 0.5), the pattern passes to the structural matcher.

### Input Embedding Cache

Extend the existing `ClassificationCache` to also cache embedding-tier results (positive and negative) keyed by `(namespace, input)`. When the same input is matched again before synonym learning takes effect, the cache short-circuits the embedding API call. The cache is invalidated on namespace replace, same as LLM classification cache entries.

### Graceful Degradation

If `EmbeddingModel` is null (not on classpath), tier 2 is skipped entirely — the cascade falls through from tier 1 directly to tier 3 (LLM), preserving current behavior. If `EmbeddingModel` throws at match time, the error is logged and the cascade falls through to tier 3.

## Synonym Learning

### When It Fires

After embedding similarity rescues a candidate and the structural matcher confirms a match. The system identifies which template keywords were absent from the input's lemma set — the "missing" keywords that caused keyword affinity to reject the candidate.

### Mechanism

1. Take the missing template keyword lemmas (e.g., "raise") and the input token lemmas (e.g., "escalate", "manager")
2. Batch-embed both sets — 2 API calls total via `EmbeddingModel.embedAll()`
3. For each missing keyword, find the input lemma with highest cosine similarity above a learning threshold (0.7 — stricter than the rescue threshold to avoid noisy pairs)
4. Store the pair (e.g., "raise" → "escalate") in the registry's synonym map

### Storage

`ConcurrentMap<String, ConcurrentMap<String, Set<String>>>` on `AdaptiveTemplateRegistry`, keyed by namespace name → lemma → synonyms. Inner map is `ConcurrentHashMap`, innermost sets are `ConcurrentHashMap.newKeySet()` — both levels are thread-safe for concurrent synonym learning. Same lifecycle as the `nlpCompiled` map — cleared when a namespace is deregistered or replaced via `replaceOrRegister()`.

### Consumption

`LemmatisedKeywordFilter.affinity()` gains an overload accepting the synonym map. When checking whether a template keyword is present in the input, it also checks whether any synonym of that keyword is present. Pure in-memory set lookup — no API calls.

### Interaction with Variation Learning

If embedding rescue succeeds, synonym learning fires. If embedding rescue fails but LLM classification (tier 3) succeeds, variation pattern learning fires (existing behavior). Both do not fire for the same input on the same match attempt — embedding takes precedence as the cheaper path.

## Cascade Integration Point

`AdaptiveTemplateRegistry` overrides `matchInNamespace()` to insert the embedding rescue between keyword affinity failure and LLM fallback. The per-pattern flow becomes:

```
For each pattern in template:
  keyword affinity (with synonyms) ≥ 0.3?  →  yes → structural matcher
                                             →  no  → embedding similarity ≥ 0.5?  →  yes → structural matcher
                                                                                     →  no  → EMBEDDING_FILTERED
```

Rescue operates at the **per-pattern** level, matching the existing architecture where `matchInNamespace()` iterates patterns within templates. A template with patterns ["Raising ${target}", "Promote ${target}"] has each pattern independently checked — pattern 0 may be embedding-rescued while pattern 1 passes keyword affinity.

The overridden `matchInNamespace()` calls the synonym-aware `LemmatisedKeywordFilter.affinity()` overload, passing the synonym map. When affinity fails even with synonyms, it falls through to embedding similarity for that specific pattern.

The namespace-level cascade in `match(namespaceName, input)` remains:

```java
TemplateMatch result = super.match(namespaceName, input);  // calls overridden matchInNamespace (tiers 0-2)
if (result instanceof TemplateMatch.Matched) return result;

return adaptiveFallback(namespaceName, input);              // tier 3 (existing LLM)
```

### matchWithTrace

Only the per-namespace `matchWithTrace(namespaceName, input)` override is needed. The cross-namespace `matchWithTrace(input)` delegates to the per-namespace version via iteration, so embedding rescue is included automatically.

### matchStructural

`matchStructural()` bypasses both embedding (tier 2) and LLM (tier 3), consistent with its purpose for collision detection. It calls `super.match(ns, input)` directly, which uses the base `NlpTemplateRegistry.matchInNamespace()` without embedding rescue.

### Lifecycle Overrides

`AdaptiveTemplateRegistry` overrides all three lifecycle methods to manage embedding and synonym state:

- `register()` — compute template embeddings (existing: compiles NLP)
- `deregister()` — clear template embeddings and synonyms for the namespace
- `replaceOrRegister()` — recompute template embeddings, clear synonyms, invalidate classification cache (existing: invalidates cache)

## Thresholds

| Parameter | Default | Purpose |
|-----------|---------|---------|
| Keyword affinity threshold | 0.3 | Existing — minimum lemma overlap for tier 1 |
| Embedding similarity threshold | 0.5 | Minimum cosine similarity for tier 2 rescue |
| Synonym learning threshold | 0.7 | Minimum cosine similarity to store a synonym pair |

All overridable per-namespace via constructor parameters.

## Diagnostics

### New CandidateOutcome Values

- `EMBEDDING_RESCUED` — candidate failed keyword affinity but was rescued by embedding similarity and matched structurally
- `EMBEDDING_FILTERED` — candidate failed keyword affinity AND failed embedding similarity rescue

`KEYWORD_FILTERED` retains its current meaning: failed keyword affinity check (never reached embedding). It is emitted only when no `EmbeddingModel` is available (standalone `NlpTemplateRegistry`). When the embedding tier is active, candidates that fail keyword affinity receive either `EMBEDDING_RESCUED` or `EMBEDDING_FILTERED`, never `KEYWORD_FILTERED`.

`ADAPTIVE_MATCHED` remains for tier 3 (LLM) rescues.

### CandidateTrace API Change

`CandidateTrace` gains an `embeddingSimilarity` field (double, default -1.0 for non-embedding outcomes). This is a source-breaking change to the record in `template-registry-api`. All existing constructor calls must be updated.

```java
public record CandidateTrace(
    String namespace, String templateName, int patternIndex,
    double keywordAffinity, double embeddingSimilarity,   // NEW
    CandidateOutcome outcome,
    List<ElementTrace> elements, double score
) { ... }
```

This is acceptable — `template-registry-api` has no external consumers outside the casehub build. The break is mechanical (add one field to each constructor call).

## Testing Strategy

The test suite serves three purposes: **specification** (each test demonstrates a concrete capability), **proof** (edge cases demonstrate robustness), and **methodology** (local real model runs record ground truth, CI replays via simulation).

### Capability Proofs

- **Synonym gap:** "Raising ${target} to ${level}" with input "I escalated this to the manager" — keyword affinity 0.0, embedding rescues, structural matcher extracts fields
- **Paraphrase gap:** "Cancel ${item}" with input "I'd like to withdraw the order" — zero lexical overlap, embedding catches semantic equivalence
- **Multi-word synonym:** "Submit ${document} for review" with input "File the report for inspection" — both "submit"→"file" and "review"→"inspection" are synonyms
- **Learning acceleration:** First match uses embedding (measured: `EmbeddingModel.embed()` called). Second match with same synonym but different variable values — keyword affinity passes via learned synonyms (measured: `EmbeddingModel.embed()` not called)
- **Cross-tier coordination:** Input that embedding can't rescue but LLM can — embedding fires first, fails, then LLM fires and registers a variation. Next match uses the variation at tier 1

### Edge Cases and Robustness

- **Near-threshold boundary:** Cosine similarity exactly at 0.5 passes, 0.499 does not
- **Adversarial input:** Unrelated input with high embedding similarity — structural matcher rejects despite embedding passing (embedding is pre-filter, not gatekeeper)
- **Empty keyword set:** Template of all variables `${x} ${y}` — keyword set empty, embedding has nothing to compare, falls through cleanly
- **Namespace replace mid-flight:** Learn synonyms, replace namespace, verify synonyms cleared and new embeddings computed
- **Concurrent synonym learning:** Two threads trigger rescue simultaneously, ConcurrentMap ensures no corruption
- **EmbeddingModel failure modes:** Empty vector, wrong dimensions, throws — all degrade gracefully to tier 3
- **Synonym quality gate:** Embedding pairs below 0.7 learning threshold not stored even when 0.5 rescue threshold passes

### Simulation-Backed Integration Testing

**Local development:** Run with real `EmbeddingModel` (e.g., Ollama) and real `AdaptiveFallbackMatcher` (LLM). The simulation framework records inputs and outputs via `@SimulationEligible` decorators. Recorded corpus captures actual embedding vectors and LLM classification results.

**CI:** Simulation framework replays recorded responses. `EmbeddingModel` is a third-party interface (LangChain4j) so `@SimulationEligible` can't annotate it directly — use `META-INF/simulation-eligible.txt` listing to generate a decorator, following the platform's listing-file path for non-annotatable interfaces. `AdaptiveFallbackMatcher` uses hand-written stubs (existing pattern from #971). Full integration paths exercised — cascade ordering, synonym learning, tier interaction, fallthrough — all with real data shapes.

**What CI proves:**
- Integration wiring correct — tiers called in right order
- Cascade fallthrough works with realistic response shapes
- Synonym learning stores and retrieves correctly from recorded pairs
- Error injection via simulation covers model failure edge cases

**Corpus generation via Maven:** A test-scoped integration test (e.g., `EmbeddingCorpusRecorderIT`) runs against a real local model, executes the capability proof scenarios, and writes the recorded responses to `src/test/resources/simulation/`. Run with `mvn verify -Precord-corpus` (a Maven profile that activates the IT and requires a running Ollama). The recorded corpus is committed — CI replays it without needing a model. When the embedding model or scenarios change, re-run the profile to regenerate.

**Corpus convention:** Files in `template-registry-llm/src/test/resources/simulation/`, following `simulation.yaml` convention from `simulation-config-core`.

## Disposition of Issue References

**Connectors STT/TTS (D9):** voice-sherpa's statistical grammar serves speaker identification and phoneme alignment on audio embeddings, not NLP text matching. The shared concept is cosine similarity on vectors, already provided by `Vectors.cosineSimilarity()`. No code reuse beyond this existing utility.

**ProtocolEvaluator.scopeCandidates() (D10):** Retired per #959 D7. Any code that previously used it now goes through the unified template registry, where the embedding tier applies automatically.

## References

- NlpTemplateRegistry.matchInNamespace() — `template-registry/src/main/java/.../nlp/NlpTemplateRegistry.java:113-169`
- AdaptiveTemplateRegistry — `template-registry-llm/src/main/java/.../llm/AdaptiveTemplateRegistry.java`
- LemmatisedKeywordFilter — `template-registry/src/main/java/.../nlp/LemmatisedKeywordFilter.java`
- Vectors.cosineSimilarity() — `platform-api` (#134)
- #971 D4 — module boundary (langchain4j in template-registry-llm, not template-registry)
- #959 D7 — ProtocolEvaluator retirement
- #959 D9 — immutable snapshot concurrency model
- #964 — positional discrimination trie (deferred performance optimisation, orthogonal)
- #973 — NearMiss guided rejection (orthogonal — NearMiss triggers after filtering, better filtering expands NearMiss coverage)
