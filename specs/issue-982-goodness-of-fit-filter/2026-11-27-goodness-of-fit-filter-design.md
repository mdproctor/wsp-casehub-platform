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

## Embedding Infrastructure

### Template Embeddings (Registration Time)

When `AdaptiveTemplateRegistry.register()` or `replaceOrRegister()` is called and an `EmbeddingModel` is available, compute embeddings for each template pattern's keyword set:

1. Extract keyword lemmas via `LemmatisedKeywordFilter.extract(pattern, tokenizer)` (existing)
2. Join lemmas into a phrase
3. Embed via `EmbeddingModel.embed()` — one call per pattern
4. Store in a `ConcurrentMap<String, List<float[]>>` keyed by `namespace:templateName`, parallel to `nlpCompiled`

This gives a semantic fingerprint of "what this pattern is about" without variable placeholders or optional segments.

### Input Embedding (Match Time)

When a candidate fails keyword affinity and needs the embedding rescue, embed the input text. One `EmbeddingModel.embed()` call per match attempt that reaches tier 2 — not per candidate. The input embedding is reused across all candidates in the namespace.

### Similarity Computation

For each candidate that failed keyword affinity, compute `Vectors.cosineSimilarity()` (from `platform-api`) between the input embedding and each of the candidate's pattern embeddings. Take the maximum. If it exceeds the threshold (default 0.5), the candidate passes to the structural matcher.

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

`ConcurrentMap<String, Map<String, Set<String>>>` on `AdaptiveTemplateRegistry`, keyed by namespace name → lemma → synonyms. Same lifecycle as the `nlpCompiled` map — cleared when a namespace is deregistered or replaced via `replaceOrRegister()`.

### Consumption

`LemmatisedKeywordFilter.affinity()` gains an overload accepting the synonym map. When checking whether a template keyword is present in the input, it also checks whether any synonym of that keyword is present. Pure in-memory set lookup — no API calls.

### Interaction with Variation Learning

If embedding rescue succeeds, synonym learning fires. If embedding rescue fails but LLM classification (tier 3) succeeds, variation pattern learning fires (existing behavior). Both do not fire for the same input on the same match attempt — embedding takes precedence as the cheaper path.

## Cascade Integration Point

The embedding rescue slots into `AdaptiveTemplateRegistry.match(namespaceName, input)`, between structural matching failure and LLM fallback:

```java
TemplateMatch result = super.match(namespaceName, input);  // tiers 0-1
if (result instanceof TemplateMatch.Matched) return result;

result = embeddingRescue(namespaceName, input);             // tier 2 (NEW)
if (result instanceof TemplateMatch.Matched) return result;

return adaptiveFallback(namespaceName, input);              // tier 3 (existing)
```

`matchWithTrace()` follows the same pattern, recording `CandidateOutcome.EMBEDDING_RESCUED` for candidates rescued by the embedding tier. Both the per-namespace `matchWithTrace(namespaceName, input)` and the cross-namespace `matchWithTrace(input)` overrides must include the embedding rescue step.

## Thresholds

| Parameter | Default | Purpose |
|-----------|---------|---------|
| Keyword affinity threshold | 0.3 | Existing — minimum lemma overlap for tier 1 |
| Embedding similarity threshold | 0.5 | Minimum cosine similarity for tier 2 rescue |
| Synonym learning threshold | 0.7 | Minimum cosine similarity to store a synonym pair |

All overridable per-namespace via constructor parameters.

## Diagnostics

New `CandidateOutcome` value: `EMBEDDING_RESCUED` — appears in `matchWithTrace()` output for candidates rescued by the embedding tier. `CandidateTrace` includes both keyword affinity score and embedding similarity score.

Existing outcomes unchanged: `KEYWORD_FILTERED` now means failed both keyword affinity AND embedding similarity. `ADAPTIVE_MATCHED` remains for tier 3 (LLM) rescues.

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

**CI:** `SimulatedEmbeddingModel` replays recorded embeddings. Simulated `AdaptiveFallbackMatcher` replays LLM results. Full integration paths exercised — cascade ordering, synonym learning, tier interaction, fallthrough — all with real data shapes.

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
