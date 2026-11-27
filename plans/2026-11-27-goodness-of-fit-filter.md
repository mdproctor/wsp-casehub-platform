# Goodness-of-Fit Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #982 — feat: replace keyword bag-of-words filter with statistical grammar + LLM fallback tiers
**Issue group:** #982

**Goal:** Add an embedding-based rescue tier (tier 2) between keyword affinity (tier 1) and LLM classification (tier 3) in `AdaptiveTemplateRegistry`, with synonym learning that teaches the keyword tier to handle future similar inputs.

**Architecture:** `AdaptiveTemplateRegistry` overrides `matchInNamespace()` to insert embedding similarity rescue per-pattern. When keyword affinity fails, cosine similarity between keyword-level embeddings determines whether the structural matcher runs. Learned synonym pairs are stored on a ConcurrentMap and fed back into keyword affinity. `EmbeddingModel` (LangChain4j) is a nullable constructor parameter — null means tier 2 is inactive.

**Tech Stack:** LangChain4j `EmbeddingModel` / `Embedding`, `Vectors.cosineSimilarity()` from platform-api, OpenNLP tokenizer (via `NlpTokenizer` SPI), JUnit 5 / AssertJ.

## Global Constraints

- `template-registry-api` is a Declaration Primitive — zero external dependencies. Only add `CandidateOutcome` values and the `CandidateTrace` field change there.
- `template-registry` has no LangChain4j dependency. Protected accessors only — no new imports.
- All embedding/LLM code stays in `template-registry-llm`.
- Thread safety via `java.util.concurrent` — never `synchronized` (virtual thread pinning).
- `Vectors.cosineSimilarity(float[], float[])` for all cosine similarity computation.

---

## Batch 1: Foundation — API changes and synonym-aware keyword affinity

### Task 1: Add CandidateOutcome values and CandidateTrace field

**Files:**
- Modify: `template-registry-api/src/main/java/io/casehub/template/registry/CandidateOutcome.java`
- Modify: `template-registry-api/src/main/java/io/casehub/template/registry/CandidateTrace.java`
- Modify: `template-registry/src/main/java/io/casehub/template/registry/nlp/NlpTemplateRegistry.java` (update CandidateTrace constructor calls)
- Modify: `template-registry-llm/src/main/java/io/casehub/template/registry/llm/AdaptiveTemplateRegistry.java` (update CandidateTrace constructor calls)
- Modify: all test files referencing `CandidateTrace` constructor (mechanical — add `-1.0` for `embeddingSimilarity`)
- Test: existing tests must still pass after the record change

**Interfaces:**
- Produces: `CandidateOutcome.EMBEDDING_RESCUED`, `CandidateOutcome.EMBEDDING_FILTERED`, `CandidateTrace.embeddingSimilarity` field

- [ ] **Step 1: Add EMBEDDING_RESCUED and EMBEDDING_FILTERED to CandidateOutcome**

```java
public enum CandidateOutcome {
    MATCHED,
    KEYWORD_FILTERED,
    REGEX_FAILED,
    STRUCTURAL_FAILED,
    CONSTRAINT_FAILED,
    BELOW_THRESHOLD,
    ADAPTIVE_MATCHED,
    EMBEDDING_RESCUED,
    EMBEDDING_FILTERED
}
```

- [ ] **Step 2: Add embeddingSimilarity field to CandidateTrace**

```java
public record CandidateTrace(
    String namespace,
    String templateName,
    int patternIndex,
    double keywordAffinity,
    double embeddingSimilarity,
    CandidateOutcome outcome,
    List<ElementTrace> elements,
    double score
) {
    public CandidateTrace {
        Objects.requireNonNull(namespace, "namespace");
        Objects.requireNonNull(templateName, "templateName");
        Objects.requireNonNull(outcome, "outcome");
        Objects.requireNonNull(elements, "elements");
        elements = List.copyOf(elements);
    }
}
```

- [ ] **Step 3: Fix all existing CandidateTrace constructor calls**

Use `ide_find_references` on `CandidateTrace` to find all constructor calls. Add `-1.0` as the `embeddingSimilarity` argument (5th position, after `keywordAffinity`). Files to update:

- `NlpTemplateRegistry.java` — `matchInNamespaceWithTrace()` lines ~194, ~205, ~209
- `InMemoryTemplateRegistry.java` — `matchInNamespaceWithTrace()` lines ~229, ~233
- `AdaptiveTemplateRegistry.java` — `matchWithTrace()` line ~112
- All test files creating `CandidateTrace` instances

- [ ] **Step 4: Run full build to verify no compile errors**

Run: `mvn --batch-mode install -pl template-registry-api,template-registry,template-registry-llm -am`
Expected: BUILD SUCCESS — all existing tests pass with the new field defaulting to -1.0

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(#982): add EMBEDDING_RESCUED/EMBEDDING_FILTERED outcomes and embeddingSimilarity to CandidateTrace Refs #982"
```

### Task 2: Synonym-aware keyword affinity overload

**Files:**
- Modify: `template-registry/src/main/java/io/casehub/template/registry/nlp/LemmatisedKeywordFilter.java`
- Test: `template-registry/src/test/java/io/casehub/template/registry/nlp/LemmatisedKeywordFilterTest.java`

**Interfaces:**
- Consumes: existing `LemmatisedKeywordFilter.affinity(Set<String>, List<AnnotatedToken>)`
- Produces: `LemmatisedKeywordFilter.affinity(Set<String>, List<AnnotatedToken>, Map<String, Set<String>>)` — synonym-expanded keyword matching

- [ ] **Step 1: Write failing tests for synonym-aware affinity**

```java
@Test
void affinityWithSynonyms_expandsMatchSet() {
    var keywords = Set.of("raise", "target");
    var inputTokens = tokenizer.tokenize("I escalated the manager");
    var synonyms = Map.of("raise", Set.of("escalate"));

    double affinity = LemmatisedKeywordFilter.affinity(keywords, inputTokens, synonyms);
    assertThat(affinity).isGreaterThan(0.0);
}

@Test
void affinityWithSynonyms_emptySynonymsBehavesLikeOriginal() {
    var keywords = Set.of("raise", "target");
    var inputTokens = tokenizer.tokenize("I escalated the manager");

    double withoutSynonyms = LemmatisedKeywordFilter.affinity(keywords, inputTokens);
    double withEmptySynonyms = LemmatisedKeywordFilter.affinity(keywords, inputTokens, Map.of());
    assertThat(withEmptySynonyms).isEqualTo(withoutSynonyms);
}

@Test
void affinityWithSynonyms_multipleSynonymsForSameKeyword() {
    var keywords = Set.of("raise");
    var inputTokens = tokenizer.tokenize("I promoted someone");
    var synonyms = Map.of("raise", Set.of("escalate", "promote"));

    double affinity = LemmatisedKeywordFilter.affinity(keywords, inputTokens, synonyms);
    assertThat(affinity).isEqualTo(1.0);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl template-registry -Dtest=LemmatisedKeywordFilterTest`
Expected: FAIL — overload does not exist

- [ ] **Step 3: Implement synonym-aware affinity overload**

```java
public static double affinity(Set<String> keywords, List<AnnotatedToken> inputTokens,
                               Map<String, Set<String>> synonyms) {
    if (keywords.isEmpty()) return 0.0;
    Set<String> inputLemmas = new LinkedHashSet<>();
    for (AnnotatedToken token : inputTokens) {
        inputLemmas.add(token.lemma().toLowerCase());
    }
    long matches = 0;
    for (String keyword : keywords) {
        if (inputLemmas.contains(keyword)) {
            matches++;
        } else {
            Set<String> syns = synonyms.get(keyword);
            if (syns != null) {
                for (String syn : syns) {
                    if (inputLemmas.contains(syn)) {
                        matches++;
                        break;
                    }
                }
            }
        }
    }
    return (double) matches / keywords.size();
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl template-registry -Dtest=LemmatisedKeywordFilterTest`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(#982): add synonym-aware affinity overload to LemmatisedKeywordFilter Refs #982"
```

### Task 3: Protected accessors on NlpTemplateRegistry

**Files:**
- Modify: `template-registry/src/main/java/io/casehub/template/registry/nlp/NlpTemplateRegistry.java`

**Interfaces:**
- Produces: `protected NlpTokenizer tokenizer()`, `protected double affinityThreshold()`, `protected ConcurrentMap<String, CompiledNlpTemplate> nlpCompiled()`

- [ ] **Step 1: Add protected accessor methods**

Add after the constructor in `NlpTemplateRegistry`:

```java
protected NlpTokenizer tokenizer() {
    return tokenizer;
}

protected double affinityThreshold() {
    return affinityThreshold;
}

protected ConcurrentMap<String, NlpTemplateCompiler.CompiledNlpTemplate> nlpCompiled() {
    return nlpCompiled;
}
```

- [ ] **Step 2: Run tests to verify nothing breaks**

Run: `mvn --batch-mode test -pl template-registry`
Expected: PASS — accessor methods are additive only

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(#982): add protected accessors to NlpTemplateRegistry for subclass use Refs #982"
```

## Batch 2: Embedding rescue — the core tier 2 cascade

### Task 4: Embedding rescue in AdaptiveTemplateRegistry

**Files:**
- Modify: `template-registry-llm/src/main/java/io/casehub/template/registry/llm/AdaptiveTemplateRegistry.java`
- Test: `template-registry-llm/src/test/java/io/casehub/template/registry/llm/EmbeddingRescueTest.java` (new)

**Interfaces:**
- Consumes: `NlpTemplateRegistry.tokenizer()`, `NlpTemplateRegistry.affinityThreshold()`, `NlpTemplateRegistry.nlpCompiled()`, `LemmatisedKeywordFilter.affinity(keywords, inputTokens, synonyms)`, `Vectors.cosineSimilarity(float[], float[])`, `EmbeddingModel.embed(TextSegment)`, `LemmatisedKeywordFilter.extract(template, tokenizer)`
- Produces: `AdaptiveTemplateRegistry` with embedding rescue in `matchInNamespace()`, `embeddingRescue()` method

- [ ] **Step 1: Write failing tests for embedding rescue**

Create `EmbeddingRescueTest.java`:

```java
package io.casehub.template.registry.llm;

import dev.langchain4j.data.embedding.Embedding;
import dev.langchain4j.data.segment.TextSegment;
import dev.langchain4j.model.embedding.EmbeddingModel;
import dev.langchain4j.model.output.Response;
import io.casehub.template.registry.TemplateDefinition;
import io.casehub.template.registry.TemplateMatch;
import io.casehub.template.registry.TemplateNamespace;
import io.casehub.template.registry.nlp.OpenNlpTokenizer;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;

class EmbeddingRescueTest {

    private final OpenNlpTokenizer tokenizer = new OpenNlpTokenizer();

    @Test
    void synonymGap_embeddingRescuesMatch() {
        // Template "Raising ${target} to ${level}" — input "I escalated the manager to senior"
        // keyword overlap is zero, but embeddings are similar
        var embeddingModel = stubEmbeddingModel(0.75f);
        var registry = createRegistry(embeddingModel);
        registerEscalationTemplate(registry);

        TemplateMatch result = registry.match("test-ns", "I escalated the manager to senior");
        assertThat(result).isInstanceOf(TemplateMatch.Matched.class);
        var matched = (TemplateMatch.Matched) result;
        assertThat(matched.templateName()).isEqualTo("escalation");
    }

    @Test
    void noEmbeddingModel_fallsThroughToLlm() {
        var registry = createRegistry(null);
        registerEscalationTemplate(registry);

        TemplateMatch result = registry.match("test-ns", "I escalated the manager to senior");
        // Without embedding model, unmatched (LLM stub returns unmatched too)
        assertThat(result).isInstanceOf(TemplateMatch.Unmatched.class);
    }

    @Test
    void belowThreshold_embeddingDoesNotRescue() {
        var embeddingModel = stubEmbeddingModel(0.3f);
        var registry = createRegistry(embeddingModel);
        registerEscalationTemplate(registry);

        TemplateMatch result = registry.match("test-ns", "The weather is nice today");
        assertThat(result).isInstanceOf(TemplateMatch.Unmatched.class);
    }

    @Test
    void keywordAffinityPasses_embeddingNotCalled() {
        var callCount = new AtomicInteger(0);
        EmbeddingModel countingModel = text -> {
            callCount.incrementAndGet();
            return Response.from(Embedding.from(new float[]{1.0f}));
        };
        var registry = createRegistry(countingModel);
        // Template with keyword "cancel" — input "cancel my order" matches keywords
        var templates = new LinkedHashMap<String, TemplateDefinition>();
        templates.put("cancel", new TemplateDefinition("cancel",
            List.of("Cancel ${item}"), Map.of()));
        registry.register(new TemplateNamespace("test-ns", templates, "en"));

        registry.match("test-ns", "Cancel my subscription");
        assertThat(callCount.get()).isEqualTo(0);
    }

    @Test
    void embeddingModelThrows_degradesToTier3() {
        EmbeddingModel failingModel = text -> { throw new RuntimeException("API down"); };
        var registry = createRegistry(failingModel);
        registerEscalationTemplate(registry);

        // Should not throw — degrades gracefully
        TemplateMatch result = registry.match("test-ns", "I escalated the manager");
        assertThat(result).isInstanceOf(TemplateMatch.Unmatched.class);
    }

    private AdaptiveTemplateRegistry createRegistry(EmbeddingModel embeddingModel) {
        return new AdaptiveTemplateRegistry(tokenizer,
            (input, candidates, language) -> new io.casehub.template.registry.ClassificationResult.Unmatched(),
            0.8, new ClassificationCache(Duration.ofMinutes(5), Duration.ofMinutes(1), 100),
            embeddingModel, 0.5);
    }

    private void registerEscalationTemplate(AdaptiveTemplateRegistry registry) {
        var templates = new LinkedHashMap<String, TemplateDefinition>();
        templates.put("escalation", new TemplateDefinition("escalation",
            List.of("Raising ${target} to ${level}"), Map.of()));
        registry.register(new TemplateNamespace("test-ns", templates, "en"));
    }

    private static EmbeddingModel stubEmbeddingModel(float similarity) {
        // Returns vectors that produce the desired cosine similarity
        // For similarity s: a=[1,0], b=[s, sqrt(1-s^2)]
        float bx = similarity;
        float by = (float) Math.sqrt(1.0 - similarity * similarity);
        return text -> Response.from(Embedding.from(
            text.text().contains("raise") || text.text().contains("raising")
                ? new float[]{1.0f, 0.0f}
                : new float[]{bx, by}));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl template-registry-llm -Dtest=EmbeddingRescueTest`
Expected: FAIL — constructor does not accept EmbeddingModel

- [ ] **Step 3: Modify AdaptiveTemplateRegistry constructor**

Add `EmbeddingModel` and `embeddingSimilarityThreshold` fields and constructor parameters. Add `templateEmbeddings` ConcurrentMap and `synonyms` ConcurrentMap fields:

```java
private final EmbeddingModel embeddingModel;
private final double embeddingSimilarityThreshold;
private final ConcurrentMap<String, List<float[]>> templateEmbeddings = new ConcurrentHashMap<>();
private final ConcurrentMap<String, ConcurrentMap<String, Set<String>>> synonyms = new ConcurrentHashMap<>();
```

Update constructor to accept and store the new parameters. Add a convenience constructor that passes `null` and `0.5` for backward compatibility with existing tests.

- [ ] **Step 4: Override matchInNamespace with embedding rescue**

Override `matchInNamespace()` in `AdaptiveTemplateRegistry`. For each pattern that fails synonym-aware keyword affinity, check embedding similarity before filtering:

```java
@Override
protected TemplateMatch matchInNamespace(String namespaceName,
                                          TemplateNamespace ns,
                                          String input,
                                          Snapshot snap) {
    // Tier 0: regex
    TemplateMatch regexResult = /* delegate to InMemoryTemplateRegistry.matchInNamespace via super.super pattern */;
    // ... (full implementation using tokenizer(), affinityThreshold(), nlpCompiled() accessors)
    // For each pattern: synonym-aware affinity → embedding rescue → structural matcher
}
```

The key logic: call `LemmatisedKeywordFilter.affinity(keywords, inputTokens, namespaceSynonyms)` first. If below threshold and `embeddingModel != null`, compute input keyword embedding (once per match attempt), then `Vectors.cosineSimilarity()` against the pattern's stored embedding.

- [ ] **Step 5: Override lifecycle methods**

Override `register()`, `deregister()`, and update `replaceOrRegister()` to manage template embeddings and synonyms:

```java
@Override
public void register(TemplateNamespace namespace) {
    super.register(namespace);
    computeTemplateEmbeddings(namespace);
}

@Override
public void deregister(String namespaceName) {
    templateEmbeddings.keySet().removeIf(k -> k.startsWith(namespaceName + ":"));
    synonyms.remove(namespaceName);
    super.deregister(namespaceName);
}

@Override
public void replaceOrRegister(TemplateNamespace namespace) {
    super.replaceOrRegister(namespace);
    templateEmbeddings.keySet().removeIf(k -> k.startsWith(namespace.name() + ":"));
    computeTemplateEmbeddings(namespace);
    synonyms.remove(namespace.name());
    // classificationCache.invalidateNamespace already called by super
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl template-registry-llm -Dtest=EmbeddingRescueTest`
Expected: PASS

- [ ] **Step 7: Run full module tests to verify no regressions**

Run: `mvn --batch-mode test -pl template-registry-llm`
Expected: PASS — all existing AdaptiveTemplateRegistryTest and AdaptiveRegistryIntegrationTest tests pass (using backward-compatible constructor)

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat(#982): embedding rescue tier in AdaptiveTemplateRegistry — per-pattern cascade with graceful degradation Refs #982"
```

## Batch 3: Synonym learning and diagnostics

### Task 5: Synonym learning after embedding rescue

**Files:**
- Modify: `template-registry-llm/src/main/java/io/casehub/template/registry/llm/AdaptiveTemplateRegistry.java`
- Test: `template-registry-llm/src/test/java/io/casehub/template/registry/llm/SynonymLearningTest.java` (new)

**Interfaces:**
- Consumes: `EmbeddingModel.embedAll()`, `Vectors.cosineSimilarity()`, synonym ConcurrentMap from Task 4
- Produces: `learnSynonyms()` method, synonym consumption in `matchInNamespace()`

- [ ] **Step 1: Write failing tests for synonym learning**

Create `SynonymLearningTest.java`:

```java
@Test
void embeddingRescue_learnsSynonymPair() {
    var embeddingModel = synonymAwareEmbeddingModel();
    var registry = createRegistry(embeddingModel);
    registerEscalationTemplate(registry);

    // First match — embedding rescues
    TemplateMatch first = registry.match("test-ns", "I escalated the manager to senior");
    assertThat(first).isInstanceOf(TemplateMatch.Matched.class);

    // Verify synonym learned — "raise" → "escalate"
    // Second match with different values but same synonym — keyword affinity should pass
    var callCount = new AtomicInteger(0);
    // Replace embedding model with counting model
    // ... (verify embed not called on second match)
}

@Test
void synonymClearedOnNamespaceReplace() {
    var embeddingModel = synonymAwareEmbeddingModel();
    var registry = createRegistry(embeddingModel);
    registerEscalationTemplate(registry);

    // Learn synonym
    registry.match("test-ns", "I escalated the manager to senior");

    // Replace namespace — synonyms should be cleared
    var templates = new LinkedHashMap<String, TemplateDefinition>();
    templates.put("escalation", new TemplateDefinition("escalation",
        List.of("Promoting ${target} to ${level}"), Map.of()));
    registry.replaceOrRegister(new TemplateNamespace("test-ns", templates, "en"));

    // The old synonym "raise"→"escalate" should not be present
    // (new template uses "promote", not "raise")
}

@Test
void synonymQualityGate_lowSimilarityNotStored() {
    // Embedding model returns similarity below 0.7 for synonym pairs
    // but above 0.5 for rescue — synonym should NOT be learned
    var embeddingModel = lowSynonymSimilarityModel();
    var registry = createRegistry(embeddingModel);
    registerEscalationTemplate(registry);

    registry.match("test-ns", "I escalated the manager to senior");
    // Synonym not learned — next match should still use embedding
}

@Test
void concurrentSynonymLearning_noCorruption() throws Exception {
    var embeddingModel = synonymAwareEmbeddingModel();
    var registry = createRegistry(embeddingModel);
    registerEscalationTemplate(registry);

    var threads = new Thread[10];
    var errors = new AtomicInteger(0);
    for (int i = 0; i < threads.length; i++) {
        threads[i] = Thread.ofVirtual().start(() -> {
            try {
                registry.match("test-ns", "I escalated the manager to senior");
            } catch (Exception e) {
                errors.incrementAndGet();
            }
        });
    }
    for (Thread t : threads) t.join();
    assertThat(errors.get()).isEqualTo(0);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl template-registry-llm -Dtest=SynonymLearningTest`
Expected: FAIL — learnSynonyms not implemented

- [ ] **Step 3: Implement synonym learning**

Add `learnSynonyms()` method to `AdaptiveTemplateRegistry`. Called after embedding rescue confirms a structural match:

```java
private void learnSynonyms(String namespaceName, Set<String> templateKeywords,
                            List<AnnotatedToken> inputTokens) {
    if (embeddingModel == null) return;

    Set<String> inputLemmas = new LinkedHashSet<>();
    for (AnnotatedToken t : inputTokens) {
        inputLemmas.add(t.lemma().toLowerCase());
    }

    // Find missing keywords — template keywords not in input lemmas
    List<String> missing = new ArrayList<>();
    for (String kw : templateKeywords) {
        if (!inputLemmas.contains(kw)) missing.add(kw);
    }
    if (missing.isEmpty()) return;

    // Batch embed missing keywords and input lemmas
    List<String> inputLemmaList = new ArrayList<>(inputLemmas);
    try {
        var missingEmbeddings = embeddingModel.embedAll(
            missing.stream().map(TextSegment::from).toList()).content();
        var inputEmbeddings = embeddingModel.embedAll(
            inputLemmaList.stream().map(TextSegment::from).toList()).content();

        var namespaceSynonyms = synonyms.computeIfAbsent(namespaceName,
            k -> new ConcurrentHashMap<>());

        for (int m = 0; m < missing.size(); m++) {
            float[] mVec = missingEmbeddings.get(m).vector();
            double bestSim = 0.0;
            String bestLemma = null;
            for (int i = 0; i < inputLemmaList.size(); i++) {
                double sim = Vectors.cosineSimilarity(mVec, inputEmbeddings.get(i).vector());
                if (sim > bestSim) {
                    bestSim = sim;
                    bestLemma = inputLemmaList.get(i);
                }
            }
            if (bestSim >= SYNONYM_LEARNING_THRESHOLD && bestLemma != null) {
                namespaceSynonyms.computeIfAbsent(missing.get(m),
                    k -> ConcurrentHashMap.newKeySet()).add(bestLemma);
            }
        }
    } catch (Exception e) {
        LOG.log(Level.WARNING, "Synonym learning failed for namespace " + namespaceName, e);
    }
}
```

Add constant: `private static final double SYNONYM_LEARNING_THRESHOLD = 0.7;`

- [ ] **Step 4: Wire synonym learning into matchInNamespace**

After a successful embedding-rescued structural match, call `learnSynonyms()` with the template keywords and input tokens.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl template-registry-llm -Dtest=SynonymLearningTest`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(#982): synonym learning from embedding rescue — batch embed, quality gate, thread-safe storage Refs #982"
```

### Task 6: matchWithTrace embedding diagnostics

**Files:**
- Modify: `template-registry-llm/src/main/java/io/casehub/template/registry/llm/AdaptiveTemplateRegistry.java`
- Test: `template-registry-llm/src/test/java/io/casehub/template/registry/llm/EmbeddingDiagnosticsTest.java` (new)

**Interfaces:**
- Consumes: `CandidateOutcome.EMBEDDING_RESCUED`, `CandidateOutcome.EMBEDDING_FILTERED`, `CandidateTrace.embeddingSimilarity`
- Produces: `matchInNamespaceWithTrace()` override with embedding diagnostics

- [ ] **Step 1: Write failing tests for embedding diagnostics in trace**

```java
@Test
void matchWithTrace_includesEmbeddingRescuedOutcome() {
    var embeddingModel = stubEmbeddingModel(0.75f);
    var registry = createRegistry(embeddingModel);
    registerEscalationTemplate(registry);

    var result = registry.matchWithTrace("test-ns", "I escalated the manager to senior");
    assertThat(result.result()).isInstanceOf(TemplateMatch.Matched.class);

    var rescued = result.trace().candidates().stream()
        .filter(c -> c.outcome() == CandidateOutcome.EMBEDDING_RESCUED)
        .findFirst();
    assertThat(rescued).isPresent();
    assertThat(rescued.get().embeddingSimilarity()).isGreaterThan(0.5);
}

@Test
void matchWithTrace_includesEmbeddingFilteredOutcome() {
    var embeddingModel = stubEmbeddingModel(0.3f);
    var registry = createRegistry(embeddingModel);
    registerEscalationTemplate(registry);

    var result = registry.matchWithTrace("test-ns", "The weather is nice");

    var filtered = result.trace().candidates().stream()
        .filter(c -> c.outcome() == CandidateOutcome.EMBEDDING_FILTERED)
        .findFirst();
    assertThat(filtered).isPresent();
    assertThat(filtered.get().embeddingSimilarity()).isLessThan(0.5);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl template-registry-llm -Dtest=EmbeddingDiagnosticsTest`
Expected: FAIL — trace does not include embedding outcomes

- [ ] **Step 3: Override matchInNamespaceWithTrace**

Override `matchInNamespaceWithTrace()` in `AdaptiveTemplateRegistry` mirroring the `matchInNamespace()` override but populating `CandidateTrace` entries with `embeddingSimilarity` scores and `EMBEDDING_RESCUED` / `EMBEDDING_FILTERED` outcomes.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl template-registry-llm -Dtest=EmbeddingDiagnosticsTest`
Expected: PASS

- [ ] **Step 5: Run full module tests**

Run: `mvn --batch-mode test -pl template-registry-llm`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(#982): embedding diagnostics in matchWithTrace — EMBEDDING_RESCUED/FILTERED with similarity scores Refs #982"
```

## Batch 4: Capability proofs and edge-case tests

### Task 7: Comprehensive capability proof and edge-case test suite

**Files:**
- Test: `template-registry-llm/src/test/java/io/casehub/template/registry/llm/EmbeddingCascadeIntegrationTest.java` (new)

**Interfaces:**
- Consumes: all previous tasks — AdaptiveTemplateRegistry with embedding rescue, synonym learning, diagnostics

- [ ] **Step 1: Write capability proof tests**

Create `EmbeddingCascadeIntegrationTest.java` with nested test classes:

```java
@Nested
class SynonymGapProof { ... }     // "Raising" vs "escalated"
@Nested
class ParaphraseGapProof { ... }  // "Cancel" vs "withdraw"
@Nested
class MultiWordSynonymProof { ... } // "submit"→"file" + "review"→"inspection"
@Nested
class LearningAccelerationProof { ... } // 2nd match uses synonyms, embed not called
@Nested
class CrossTierCoordinationProof { ... } // embed fails → LLM succeeds → variation learned
```

Each proof: register templates, match with synonym/paraphrase input, assert `Matched` with correct fields.

- [ ] **Step 2: Write edge-case and robustness tests**

```java
@Nested
class ThresholdBoundary { ... }      // 0.5 passes, 0.499 does not
@Nested
class AdversarialInput { ... }       // high embedding sim but structural fail
@Nested
class EmptyKeywordSet { ... }        // all-variable template
@Nested
class NamespaceReplaceMidFlight { ... } // synonyms + embeddings cleared
@Nested
class EmbeddingModelFailures { ... }    // empty vec, wrong dims, throws
@Nested
class SynonymQualityGate { ... }     // below 0.7 not stored
@Nested
class MatchStructuralBypass { ... }  // matchStructural skips embedding
```

- [ ] **Step 3: Run all tests**

Run: `mvn --batch-mode test -pl template-registry-llm -Dtest=EmbeddingCascadeIntegrationTest`
Expected: PASS

- [ ] **Step 4: Run full build to verify everything works together**

Run: `mvn --batch-mode install -pl template-registry-api,template-registry,template-registry-llm -am`
Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "test(#982): comprehensive embedding cascade capability proofs and edge-case suite Refs #982"
```

## Batch 5: Embedding result caching

### Task 8: Extend ClassificationCache for embedding-tier results

**Files:**
- Modify: `template-registry-llm/src/main/java/io/casehub/template/registry/llm/ClassificationCache.java`
- Modify: `template-registry-llm/src/main/java/io/casehub/template/registry/llm/AdaptiveTemplateRegistry.java`
- Modify: `template-registry-llm/src/test/java/io/casehub/template/registry/llm/ClassificationCacheTest.java`
- Test: existing `EmbeddingRescueTest` updated

**Interfaces:**
- Consumes: `ClassificationCache.CacheKey`, existing cache infrastructure
- Produces: `ClassificationCache.putEmbeddingPositive()`, `ClassificationCache.putEmbeddingNegative()`, `ClassificationCache.getEmbedding()`

- [ ] **Step 1: Write failing tests for embedding cache**

Add to `ClassificationCacheTest.java`:

```java
@Test
void embeddingPositive_cachedAndReturned() {
    var key = new ClassificationCache.CacheKey("ns", "input text");
    cache.putEmbeddingPositive(key, "template-name", 0, Map.of("field", "value"), 0.75);
    var entry = cache.getEmbedding(key);
    assertThat(entry).isNotNull();
    assertThat(entry.isPositive()).isTrue();
}

@Test
void embeddingNegative_cachedAndReturned() {
    var key = new ClassificationCache.CacheKey("ns", "input text");
    cache.putEmbeddingNegative(key);
    var entry = cache.getEmbedding(key);
    assertThat(entry).isNotNull();
    assertThat(entry.isPositive()).isFalse();
}

@Test
void embeddingCache_invalidatedOnNamespaceReplace() {
    var key = new ClassificationCache.CacheKey("ns", "input text");
    cache.putEmbeddingPositive(key, "template-name", 0, Map.of(), 0.75);
    cache.invalidateNamespace("ns");
    assertThat(cache.getEmbedding(key)).isNull();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl template-registry-llm -Dtest=ClassificationCacheTest`
Expected: FAIL — embedding methods do not exist

- [ ] **Step 3: Add embedding cache methods to ClassificationCache**

Add a separate `ConcurrentHashMap<CacheKey, EmbeddingEntry>` for embedding results. `EmbeddingEntry` stores the match result (template name, pattern index, fields, similarity) or null for negative. TTL and max-entries shared with the classification cache. `invalidateNamespace()` clears both maps.

- [ ] **Step 4: Wire embedding cache into AdaptiveTemplateRegistry**

In `matchInNamespace()`, before computing embeddings, check `classificationCache.getEmbedding(key)`. After computing, store the result.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl template-registry-llm`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(#982): extend ClassificationCache for embedding-tier result caching Refs #982"
```

## References

- [2026-11-27-goodness-of-fit-filter-design.md] — design spec this plan implements
- NlpTemplateRegistry — `template-registry/src/main/java/.../nlp/NlpTemplateRegistry.java`
- AdaptiveTemplateRegistry — `template-registry-llm/src/main/java/.../llm/AdaptiveTemplateRegistry.java`
- LemmatisedKeywordFilter — `template-registry/src/main/java/.../nlp/LemmatisedKeywordFilter.java`
- CandidateTrace — `template-registry-api/src/main/java/.../CandidateTrace.java`
- CandidateOutcome — `template-registry-api/src/main/java/.../CandidateOutcome.java`
- ClassificationCache — `template-registry-llm/src/main/java/.../llm/ClassificationCache.java`
- Vectors.cosineSimilarity — `platform-api/src/main/java/.../util/Vectors.java:56`
- GitHub #982 — focal issue
- GitHub #971 — module boundary decisions (D4)
- GitHub #959 — unified template registry architecture
