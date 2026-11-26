# Adaptive Semantic Variation — Design Spec

**Issue:** #971
**Date:** 2026-11-26
**Parent:** #959 (Unified Template Registry)
**Epic:** #943 (Message Extraction Pipeline)

## Purpose

Template authors write one canonical pattern per intent. The system handles semantic variations through three tiers:

1. **LLM-seeded variations** — at registration time, an LLM generates common semantic paraphrases for each template. These are added as extra patterns to the `TemplateDefinition` before registration — pre-compiled, no runtime cost.
2. **NLP structural matching** — the existing tier handles inflection, plurals, determiners on canonical AND seeded patterns.
3. **Runtime adaptive fallback** — when both regex and NLP return `Unmatched`, a lightweight LLM call classifies the input, extracts fields, and registers the new phrasing as a variation. Next time, the structural matcher handles it without an LLM call.

The `ParaphraseCliff` tests document the current boundary: "I'm in favour of this design" does not match the template "I ${decision} this ${subject}". After this feature, it matches via runtime adaptive fallback — the LLM classifies the input, extracts `{decision: "approve", subject: "design"}`, and caches the classification for future occurrences. Seeded variations handle structural rearrangements that preserve all variable placeholders (e.g. "This ${subject} gets my ${decision}") but cannot bridge true semantic paraphrase where the user substitutes a synonym for an enum-constrained variable value ("in favour of" for `approve`).

## Architecture

```
Template corpus (1 canonical pattern per intent)
     │
     ▼
VariationSeeder (registration time — batch, cheap)
     │
     ▼
CollisionDetector (reject variations that match other templates)
     │
     ▼
Expanded TemplateDefinition (canonical + seeded variations)
     │
     ▼
UnifiedTemplateRegistry.register() (all patterns compiled: regex + NLP)
     │
     ▼
Match attempt: regex → NLP structural
     │
     ▼
Unmatched? → AdaptiveFallbackMatcher (runtime — per-miss, expensive)
     │
     ▼
Match found? → extract fields + register variation (atomic replace)
     │
     ▼
Next occurrence → structural matcher handles it (free)
```

### Module Placement (D4 revised)

```
template-registry-api (zero-dep)
  ├── VariationSeeder         (SPI — @FunctionalInterface)
  ├── AdaptiveFallbackMatcher (SPI — @FunctionalInterface)
  ├── CollisionDetector       (utility — composes registry.match())
  ├── ClassificationResult    (sealed record — match result from adaptive fallback)
  ├── TemplateCandidate       (record — LLM classification input)
  ├── TemplateNamespace       (extended with language field)
  └── UnifiedTemplateRegistry (extended with replaceOrRegister)

template-registry (OpenNLP — unchanged dependency profile)
  └── (no changes — NLP matching only)

template-registry-llm (new — depends on template-registry + langchain4j-core)
  ├── LlmVariationSeeder      (ChatModel-backed VariationSeeder)
  ├── LlmAdaptiveFallback     (ChatModel-backed AdaptiveFallbackMatcher)
  ├── AdaptiveTemplateRegistry (extends NlpTemplateRegistry — adds tier 3)
  └── VariationSeedingService  (seeding orchestrator)
```

LLM implementations inject `ChatModel` from the agent routing layer. The SPIs in template-registry-api have no LLM dependency. template-registry retains its current dependency profile (OpenNLP only).

## New Types

### UnifiedTemplateRegistry — replaceOrRegister (D3 revised)

Add a default method to the existing SPI for atomic namespace replacement. Implements #967.

```java
public interface UnifiedTemplateRegistry {
    // ... existing methods ...

    default void replaceOrRegister(TemplateNamespace namespace) {
        deregister(namespace.name());
        register(namespace);
    }
}
```

The default method provides backward compatibility. `InMemoryTemplateRegistry` overrides with a true single-CAS implementation:

```java
public void replaceOrRegister(TemplateNamespace namespace) {
    Objects.requireNonNull(namespace, "namespace");
    while (true) {
        Snapshot current = snapshot.get();
        Snapshot next = current.withoutNamespace(namespace.name())
                               .withNamespace(namespace);
        if (snapshot.compareAndSet(current, next)) {
            return;
        }
    }
}
```

No gap where the namespace is absent — readers see either the old or new snapshot atomically.

### VariationSeeder (SPI)

Functional interface in `template-registry-api`. Takes a template definition and returns semantic paraphrases of each pattern.

```java
@FunctionalInterface
public interface VariationSeeder {

    List<String> seed(TemplateDefinition template, String language);
}
```

The seeder generates variations for all patterns in the definition and returns them as a flat list. It does not modify the definition — the caller decides what to include.

### AdaptiveFallbackMatcher (SPI)

Functional interface in `template-registry-api`. Classifies unmatched input against candidate templates via a single LLM call (D5).

```java
@FunctionalInterface
public interface AdaptiveFallbackMatcher {

    ClassificationResult classify(
        String input,
        List<TemplateCandidate> candidates,
        String language);
}
```

### ClassificationResult

Sealed interface — the result of adaptive classification.

```java
public sealed interface ClassificationResult {

    record Matched(
        String templateName,
        Map<String, String> fields,
        String suggestedVariation,
        double confidence
    ) implements ClassificationResult {
        public Matched {
            Objects.requireNonNull(templateName, "templateName");
            Objects.requireNonNull(fields, "fields");
            Objects.requireNonNull(suggestedVariation, "suggestedVariation");
            if (confidence < 0.0 || confidence > 1.0) {
                throw new IllegalArgumentException(
                    "Confidence must be in [0.0, 1.0]: " + confidence);
            }
            fields = Map.copyOf(fields);
        }
    }

    record Unmatched() implements ClassificationResult {}
}
```

- `templateName` — the template within the namespace that the input matches
- `fields` — extracted variable values
- `suggestedVariation` — a normalised pattern string the LLM produces (e.g. `"This ${subject} gets my ${decision}"`) that can be registered for future structural matching. Must preserve all `${var}` placeholders to be registrable as a variation; patterns that drop variables are not registered but the match is still returned and cached (see §AdaptiveTemplateRegistry — Classification Cache).
- `confidence` — LLM classification confidence in `[0.0, 1.0]`. Variations are only registered when confidence meets the configurable threshold (default 0.8).

### TemplateCandidate

The information the LLM needs to classify against.

```java
public record TemplateCandidate(
    String templateName,
    List<String> patterns,
    Map<String, VariableConstraint> variables
) {
    public TemplateCandidate {
        Objects.requireNonNull(templateName, "templateName");
        Objects.requireNonNull(patterns, "patterns");
        variables = variables != null ? Map.copyOf(variables) : Map.of();
    }

    public static TemplateCandidate from(TemplateDefinition def) {
        return new TemplateCandidate(
            def.name(), def.patterns(), def.variables());
    }
}
```

### CollisionDetector (Utility)

Stateless utility in `template-registry-api` that checks whether candidate variations collide with existing templates (D6).

```java
public final class CollisionDetector {

    public record Collision(
        String variation,
        String collidingNamespace,
        String collidingTemplate
    ) {}

    public static List<Collision> detect(
            List<String> candidateVariations,
            Map<String, VariableConstraint> sourceVariables,
            String sourceNamespace,
            String sourceTemplate,
            UnifiedTemplateRegistry registry) {

        List<Collision> collisions = new ArrayList<>();
        for (String variation : candidateVariations) {
            String testInput = substituteTestValues(variation, sourceVariables);
            TemplateMatch result = registry.match(testInput);
            if (result instanceof TemplateMatch.Matched matched) {
                boolean isSelf = matched.namespace().equals(sourceNamespace)
                    && matched.templateName().equals(sourceTemplate);
                if (!isSelf) {
                    collisions.add(new Collision(
                        variation, matched.namespace(), matched.templateName()));
                }
            }
        }
        return List.copyOf(collisions);
    }

    private static String substituteTestValues(
            String variation,
            Map<String, VariableConstraint> variables) {
        String result = variation;
        for (var entry : variables.entrySet()) {
            String placeholder = "${" + entry.getKey() + "}";
            if (!result.contains(placeholder)) continue;
            String testValue;
            if (entry.getValue() instanceof VariableConstraint.EnumConstraint ec) {
                testValue = ec.values().iterator().next();
            } else {
                testValue = "__collision_test_" + entry.getKey() + "__";
            }
            result = result.replace(placeholder, testValue);
        }
        return result;
    }
}
```

Collision detection substitutes `${var}` placeholders with valid test values before matching — enum-constrained variables use the first allowed value, string-constrained variables use a unique sentinel. This ensures enum constraint validation doesn't mask real collisions.

This is O(variations × templates) — acceptable at registration time (batch, infrequent). Runtime-learned variations check a single candidate, so the cost is O(templates) per learn event.

### TemplateNamespace — Language Field (D7)

Add an optional `language` field to `TemplateNamespace`, defaulting to `"en"`.

```java
public record TemplateNamespace(
    String name,
    Map<String, TemplateDefinition> templates,
    String language
) {
    public TemplateNamespace(String name,
                             Map<String, TemplateDefinition> templates) {
        this(name, templates, "en");
    }

    public TemplateNamespace {
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(templates, "templates");
        language = language != null ? language : "en";
        // ... existing validation ...
    }
}
```

Backward-compatible: existing two-arg constructor delegates to the three-arg with `"en"`.

## LLM Implementations

### LlmVariationSeeder

Lives in `template-registry-llm`. Injects `ChatModel` from the agent routing layer. Generates paraphrases via a structured-output prompt.

```java
public class LlmVariationSeeder implements VariationSeeder {

    private final ChatModel chatModel;
    private final int maxVariationsPerPattern;

    @Override
    public List<String> seed(TemplateDefinition template, String language) {
        // For each pattern in the template:
        // 1. Build a prompt: "Generate semantic paraphrases of this template
        //    pattern that preserve the ${variable} placeholders exactly.
        //    Language: <language>. Pattern: <pattern>.
        //    Variables: <variable constraints>."
        // 2. Call chatModel with structured output (JSON array of strings)
        // 3. Validate: each variation must contain the same ${var} placeholders
        // 4. Return flat list of all variations across all patterns
    }
}
```

Key prompt constraints:
- Variable placeholders (`${var}`) must be preserved exactly — the variation is a pattern, not a filled sentence
- Variations must be natural language in the specified language
- Enum constraints are communicated to help the LLM understand the template's semantic intent

### LlmAdaptiveFallback

Lives in `template-registry-llm`. Single LLM call per miss (D5).

```java
public class LlmAdaptiveFallback implements AdaptiveFallbackMatcher {

    private final ChatModel chatModel;

    @Override
    public ClassificationResult classify(
            String input,
            List<TemplateCandidate> candidates,
            String language) {
        // 1. Build prompt with all candidate templates + their variables
        // 2. Ask: "Does this input match any of these templates semantically?
        //    If yes, which template, what are the field values, and what
        //    normalised pattern would match this phrasing?"
        // 3. Structured output: {match: boolean, templateName?, fields?, 
        //    suggestedVariation?}
        // 4. Validate field values against variable constraints
        // 5. Return ClassificationResult.Matched or Unmatched
    }
}
```

## AdaptiveTemplateRegistry

Lives in `template-registry-llm`. Extends `NlpTemplateRegistry` to add the third matching tier. The adaptive fallback fires when both regex and NLP fail to produce a confident `Matched` result — this includes both `Unmatched` and `NearMiss` outcomes, since a near-miss indicates the structural matcher found something similar but couldn't confidently extract fields, which is exactly the scenario where LLM classification adds value.

```java
public class AdaptiveTemplateRegistry extends NlpTemplateRegistry {

    private final AdaptiveFallbackMatcher fallbackMatcher;
    private final double confidenceThreshold; // default 0.8
    private final ClassificationCache classificationCache;

    @Override
    public TemplateMatch match(String namespaceName, String input) {
        TemplateMatch result = super.match(namespaceName, input);
        if (result instanceof TemplateMatch.Matched) {
            return result;
        }
        // NearMiss or Unmatched → try classification cache, then adaptive fallback
        return adaptiveFallback(namespaceName, input);
    }

    private TemplateMatch adaptiveFallback(String namespaceName, String input) {
        // 0. Check classification cache (positive and negative results)
        var cacheKey = new ClassificationCache.CacheKey(namespaceName, input);
        ClassificationCache.Entry cached = classificationCache.get(cacheKey);
        if (cached != null) {
            return cached.toTemplateMatch(namespaceName);
        }

        TemplateNamespace ns = /* get from snapshot */;
        List<TemplateCandidate> candidates = ns.templates().values()
            .stream().map(TemplateCandidate::from).toList();

        ClassificationResult cr;
        try {
            cr = fallbackMatcher.classify(
                input, candidates, ns.language());
        } catch (Exception e) {
            // LLM unavailable — graceful degradation to Unmatched
            // Log at WARN, do not propagate
            return new TemplateMatch.Unmatched(input);
        }

        if (cr instanceof ClassificationResult.Matched matched) {
            // Cache the positive result regardless of registration
            classificationCache.putPositive(cacheKey, matched);

            // Only register variation if confidence meets threshold
            if (matched.confidence() >= confidenceThreshold) {
                tryRegisterVariation(namespaceName, matched);
            }

            return new TemplateMatch.Matched(
                namespaceName, matched.templateName(), -1,
                matched.fields(), 0.9);
        }

        // Cache the negative result
        classificationCache.putNegative(cacheKey);
        return new TemplateMatch.Unmatched(input);
    }

    private void tryRegisterVariation(String namespaceName,
                                       ClassificationResult.Matched matched) {
        String variation = matched.suggestedVariation();

        // Validate: variation must preserve ALL ${var} placeholders
        TemplateNamespace ns = /* get from snapshot */;
        TemplateDefinition def = ns.templates().get(matched.templateName());
        if (!preservesAllVariables(variation, def.variables())) {
            // Variation drops a variable (e.g. enum value baked into phrasing)
            // — don't register, the classification cache handles future hits
            return;
        }

        // Collision check with test value substitution
        List<CollisionDetector.Collision> collisions =
            CollisionDetector.detect(
                List.of(variation), def.variables(),
                namespaceName, matched.templateName(), this);

        if (collisions.isEmpty()) {
            registerLearnedVariation(
                namespaceName, matched.templateName(), variation);
        }
        // else: log warning, don't persist — match already returned
    }

    private boolean preservesAllVariables(
            String variation, Map<String, VariableConstraint> variables) {
        for (String varName : variables.keySet()) {
            if (!variation.contains("${" + varName + "}")) {
                return false;
            }
        }
        return true;
    }

    private void registerLearnedVariation(
            String namespaceName, String templateName, String variation) {
        // Atomic replace (D3 revised — replaceOrRegister):
        // 1. Read current namespace from snapshot
        // 2. Build new TemplateDefinition with original patterns + variation
        // 3. Build new TemplateNamespace with updated template
        // 4. replaceOrRegister(expandedNamespace) — single CAS, no gap
        //    (replaceOrRegister also invalidates classification cache — see override below)
    }

    @Override
    public void replaceOrRegister(TemplateNamespace namespace) {
        super.replaceOrRegister(namespace);
        classificationCache.invalidateNamespace(namespace.name());
    }
}
```

### NlpTemplateRegistry — replaceOrRegister Override

`NlpTemplateRegistry` must override `replaceOrRegister()` to update both the immutable snapshot AND the `nlpCompiled` cache. Without this override, the CAS in `InMemoryTemplateRegistry.replaceOrRegister()` updates the snapshot directly, bypassing `NlpTemplateRegistry.register()` — the NLP compilation step is skipped, and the tier 2 NLP matcher won't see new patterns.

```java
// In NlpTemplateRegistry:
@Override
public void replaceOrRegister(TemplateNamespace namespace) {
    super.replaceOrRegister(namespace);
    // Remove old NLP compilations for this namespace
    nlpCompiled.keySet().removeIf(k -> k.startsWith(namespace.name() + ":"));
    // Compile NLP patterns for the new namespace
    for (TemplateDefinition def : namespace.templates().values()) {
        String key = namespace.name() + ":" + def.name();
        nlpCompiled.put(key, NlpTemplateCompiler.compile(def, tokenizer));
    }
}
```

### Classification Cache

Mandatory in-memory cache for LLM classification results, covering both positive (matched) and negative (unmatched) outcomes. Prevents repeated LLM calls for the same input.

```java
public class ClassificationCache {

    public record CacheKey(String namespace, String input) {}

    // ... Entry, get(), putPositive(), putNegative(), invalidateNamespace()
}
```

The cache key is a typed record — not a string concatenation — because namespace names contain colons (e.g. `"protocol:review"`). A string key like `namespace + ":" + input` would be ambiguous.

| Parameter | Default | Config property | Notes |
|-----------|---------|-----------------|-------|
| Positive TTL | 30 minutes | `casehub.template.adaptive.cache.positive-ttl` | Longer — positive results are valuable to retain |
| Negative TTL | 5 minutes | `casehub.template.adaptive.cache.negative-ttl` | Shorter — input that doesn't match today might match after new registrations |
| Max entries | 1000 | `casehub.template.adaptive.cache.max-entries` | Per-registry, covers both positive and negative entries |
| Eviction | LRU | — | When max entries exceeded, least-recently-used entries evicted first |

Positive cache entries store the full `ClassificationResult.Matched` — on cache hit, the match is returned directly without an LLM call or variation registration attempt. This is the primary mechanism for handling repeated semantic paraphrases that cannot be registered as structural variations (e.g. enum value synonyms like "in favour of" for `approve`).

**Cache invalidation:** `AdaptiveTemplateRegistry.replaceOrRegister()` calls `classificationCache.invalidateNamespace(namespaceName)` after the snapshot update. This clears all cached entries (positive and negative) for the mutated namespace, ensuring the cache doesn't serve stale results for templates that have been added, removed, or changed. `invalidateNamespace()` iterates the `CacheKey` key set and removes entries where `key.namespace().equals(namespaceName)`.

### matchWithTrace Override

`AdaptiveTemplateRegistry` overrides `matchWithTrace(String namespaceName, String input)` to include adaptive tier information in trace output. A new `CandidateOutcome.ADAPTIVE_MATCHED` value distinguishes LLM-classified matches from regex and NLP matches.

```java
// In AdaptiveTemplateRegistry:
@Override
public MatchTraceResult matchWithTrace(String namespaceName, String input) {
    MatchTraceResult structuralResult = super.matchWithTrace(namespaceName, input);
    if (structuralResult.result() instanceof TemplateMatch.Matched) {
        return structuralResult;
    }

    TemplateMatch adaptiveResult = adaptiveFallback(namespaceName, input);
    List<CandidateTrace> candidates = new ArrayList<>(
        structuralResult.trace().candidates());

    if (adaptiveResult instanceof TemplateMatch.Matched matched) {
        candidates.add(new CandidateTrace(
            namespaceName, matched.templateName(), -1, -1.0,
            CandidateOutcome.ADAPTIVE_MATCHED, List.of(), matched.score()));
    }

    return new MatchTraceResult(adaptiveResult,
        new MatchTrace(candidates,
            adaptiveResult instanceof TemplateMatch.Matched m
                ? namespaceName + ":" + m.templateName() : null,
            adaptiveResult instanceof TemplateMatch.Matched m
                ? m.score() : 0.0));
}
```

### Error Handling

- **LLM unavailable:** `adaptiveFallback()` catches all exceptions from `fallbackMatcher.classify()` and degrades gracefully to `Unmatched`. The two structural tiers still work. Log at WARN level.
- **LLM misclassification:** The collision guard (D6) catches cross-namespace errors. Same-namespace misclassification (LLM says input matches template A but it semantically matches template B within the same namespace) is not detectable without ground truth. This is **self-reinforcing**: the registered variation causes future similar inputs to match the wrong template via the structural matcher. Mitigations: (1) the confidence threshold (default 0.8) prevents low-confidence classifications from being registered; (2) re-registering the namespace via `replaceOrRegister()` with canonical-only patterns purges all learned variations; (3) learned variations are in-memory only (D1) and cleared on restart.
- **Cost control:** The classification cache is mandatory — both positive and negative results are cached with configurable TTLs (see §Classification Cache). The `agent-gate` decorator on `ChatModel` provides global token-bucket rate limiting across all LLM consumers.

**Score for adaptive matches:** 0.9 — lower than regex (1.0) but higher than the NLP threshold. Distinguishes LLM-classified matches in downstream processing.

**Pattern index for adaptive matches:** -1 — indicates the pattern was not from the compiled set.

## Seeding Orchestration

The seeding flow is not inside the registry — it's caller-side (D2). A `VariationSeedingService` orchestrates the pipeline:

```java
public class VariationSeedingService {

    private final VariationSeeder seeder;
    private final UnifiedTemplateRegistry registry;

    public TemplateNamespace seedAndRegister(TemplateNamespace namespace) {
        TemplateNamespace expanded = expandWithVariations(namespace);
        registry.register(expanded);
        return expanded;
    }

    private TemplateNamespace expandWithVariations(TemplateNamespace namespace) {
        Map<String, TemplateDefinition> expandedTemplates = new LinkedHashMap<>();
        for (var entry : namespace.templates().entrySet()) {
            TemplateDefinition def = entry.getValue();
            List<String> variations = seeder.seed(def, namespace.language());

            // Collision check against already-registered templates
            List<CollisionDetector.Collision> collisions =
                CollisionDetector.detect(
                    variations, def.variables(),
                    namespace.name(), def.name(), registry);

            // Filter out colliding variations
            Set<String> collidingVariations = collisions.stream()
                .map(CollisionDetector.Collision::variation)
                .collect(Collectors.toSet());
            List<String> safeVariations = variations.stream()
                .filter(v -> !collidingVariations.contains(v))
                .toList();

            // Log rejected variations
            for (var collision : collisions) {
                // warn: variation X collides with namespace:template
            }

            // Build expanded definition: canonical patterns + safe variations
            List<String> allPatterns = new ArrayList<>(def.patterns());
            allPatterns.addAll(safeVariations);
            expandedTemplates.put(def.name(),
                new TemplateDefinition(def.name(), allPatterns, def.variables()));
        }
        return new TemplateNamespace(
            namespace.name(), expandedTemplates, namespace.language());
    }
}
```

## Three-Tier Match Flow

```
Input prose
  │
  ├─ Tier 1: Regex match via compiled patterns (canonical + seeded)
  │   ├─ Pattern match? → Constraint validation
  │   │   ├─ Pass → TemplateMatch.Matched(score=1.0)
  │   │   └─ Fail → try next template
  │   └─ No regex match → fall through
  │
  ├─ Tier 2: NLP structural match (canonical + seeded patterns)
  │   ├─ Lemmatised keyword filtering (prune candidates)
  │   ├─ Tokenize → POS tag → Lemmatize
  │   ├─ Structural pattern match against candidates
  │   └─ Match? → TemplateMatch.Matched(score=coverage)
  │
  └─ Tier 3: Adaptive fallback (LLM classification — template-registry-llm)
      ├─ Check classification cache (positive/negative)
      │   └─ Cache hit? → return cached result directly
      ├─ Build TemplateCandidate list from namespace
      ├─ Single LLM call: classify + extract + suggest variation
      │   └─ LLM unavailable? → graceful degradation to Unmatched
      ├─ Match? → cache positive result, then try registration:
      │   ├─ Confidence < threshold? → skip registration, return match
      │   ├─ Variation drops variables? → skip registration, return match
      │   ├─ Collision detected? → log warning, skip registration, return match
      │   └─ All checks pass → register variation (replaceOrRegister — single CAS)
      ├─ No match? → cache negative result
      └─ Return TemplateMatch.Matched(score=0.9) or Unmatched
```

Tier 1 and 2 operate on both canonical patterns AND seeded variations — seeded variations are just additional patterns in the `TemplateDefinition`. The registry doesn't distinguish them.

## Thread Safety

- `VariationSeeder` and `AdaptiveFallbackMatcher` are stateless functional interfaces — thread-safe by contract
- `CollisionDetector` is a stateless utility — thread-safe
- `AdaptiveTemplateRegistry` inherits the immutable-snapshot concurrency model from `InMemoryTemplateRegistry`
- Learned variation registration uses `replaceOrRegister()` — single CAS on the snapshot, no gap where the namespace is absent. `NlpTemplateRegistry` overrides `replaceOrRegister()` to update both the snapshot and `nlpCompiled` cache; the two stores are not atomically updated (brief window where snapshot is updated but NLP cache lags). This is consistent with the existing `register()`/`deregister()` behaviour in `NlpTemplateRegistry` — the regex tier (checked first) covers the gap.
- `ClassificationCache` uses `ConcurrentHashMap` — thread-safe, no external locking required
- `LlmVariationSeeder` and `LlmAdaptiveFallback` delegate to `ChatModel` which is thread-safe per platform convention

## Testing Strategy

### Unit Tests

- `CollisionDetectorTest` — collision detection with known colliding/non-colliding variations
- `ClassificationResultTest` — sealed record validation, immutability
- `TemplateCandidateTest` — construction from `TemplateDefinition`
- `TemplateNamespaceTest` — language field, backward-compatible constructor

### Integration Tests

- **Seeded variation matches structural rearrangements:** Register a template with seeded variations that preserve all `${var}` placeholders (e.g. `"This ${subject} gets my ${decision}"`). Assert that structural rearrangements match via regex or NLP without any LLM call.
- **Seeded variations do NOT bridge semantic paraphrase for enum variables:** Register a template with seeded variations. Assert that "I'm in favour of this design" (a synonym paraphrase, not a structural rearrangement) still returns `Unmatched` from tiers 1 and 2. This documents the deliberate boundary.
- **Adaptive fallback bridges ParaphraseCliff:** Configure `AdaptiveTemplateRegistry` with mock LLM. Assert that "I'm in favour of this design" matches via tier 3, with `{decision: "approve", subject: "design"}` extracted. The `ParaphraseCliff` tests flip from `Unmatched` to `Matched`.
- **Classification cache prevents repeated LLM calls:** First call for a semantic paraphrase triggers adaptive fallback (mock LLM). Second call for same input returns cached result without LLM call.
- **Runtime-learned variation matches without LLM on second occurrence:** First call to `match()` for a structural paraphrase (preserves all variables) triggers adaptive fallback (mock LLM) and registers variation. Second call matches via regex/NLP without LLM.
- **NearMiss triggers adaptive fallback:** Configure input that produces a NearMiss from tiers 1+2. Assert the adaptive fallback fires and classifies correctly.
- **Collision rejection:** Seed template A. Attempt to seed template B with a variation that matches A. Assert the variation is rejected and logged.
- **Adaptive fallback collision guard:** Adaptive fallback suggests a variation that collides. Assert the match is returned but the variation is NOT registered.
- **Confidence threshold prevents low-confidence registration:** Adaptive fallback returns a match with confidence below threshold. Assert the match is returned but no variation is registered.

### Mock LLM for Tests

Tests use a stub `VariationSeeder` and `AdaptiveFallbackMatcher` with predetermined responses — no real LLM calls in the test suite.

## CDI Wiring

The registry displacement chain follows the platform's established `@DefaultBean` pattern (ARC42STORIES §4):

```
NoOpUnifiedTemplateRegistry (@DefaultBean in platform-core)
  ↓ displaced by
NlpTemplateRegistry (@ApplicationScoped in template-registry)
  ↓ displaced by
AdaptiveTemplateRegistry (@ApplicationScoped @Alternative @Priority(100) in template-registry-llm)
```

- **No `template-registry-llm` on classpath:** `NlpTemplateRegistry` is active — two-tier matching (regex + NLP)
- **`template-registry-llm` on classpath:** `AdaptiveTemplateRegistry` is active — three-tier matching (regex + NLP + LLM adaptive)
- **Neither on classpath:** `NoOpUnifiedTemplateRegistry` — returns `Unmatched` for everything

All callers inject `UnifiedTemplateRegistry` — never the concrete type. The active implementation is determined by classpath composition.

```java
// In template-registry-llm:
@ApplicationScoped
@Alternative
@Priority(100)
public class AdaptiveTemplateRegistry extends NlpTemplateRegistry {

    private final AdaptiveFallbackMatcher fallbackMatcher;
    private final double confidenceThreshold;
    private final ClassificationCache classificationCache;

    @Inject
    public AdaptiveTemplateRegistry(
            NlpTokenizer tokenizer,
            AdaptiveFallbackMatcher fallbackMatcher,
            @ConfigProperty(name = "casehub.template.adaptive.confidence-threshold",
                            defaultValue = "0.8")
            double confidenceThreshold,
            ClassificationCache classificationCache) {
        super(tokenizer);
        this.fallbackMatcher = fallbackMatcher;
        this.confidenceThreshold = confidenceThreshold;
        this.classificationCache = classificationCache;
    }
}
```

`ClassificationCache` is an `@ApplicationScoped` bean in `template-registry-llm` with its own `@ConfigProperty` injection for TTLs and max entries (see §Classification Cache for config property names).

The `AdaptiveFallbackMatcher` SPI bean is provided by `LlmAdaptiveFallback` (also in `template-registry-llm`), which injects `ChatModel` from the agent routing layer. `NlpTokenizer` is provided by `OpenNlpTokenizer` in `template-registry`.

Note: `NlpTemplateRegistry`'s `@ApplicationScoped` annotation is part of #959's remaining CDI work. This spec assumes that wiring is in place.

## Scope

### In scope
- `replaceOrRegister()` on `UnifiedTemplateRegistry` SPI (implements #967)
- `NlpTemplateRegistry.replaceOrRegister()` override for `nlpCompiled` cache synchronisation
- `VariationSeeder` SPI and `LlmVariationSeeder` implementation
- `AdaptiveFallbackMatcher` SPI and `LlmAdaptiveFallback` implementation
- `CollisionDetector` utility (with test value substitution for enum-constrained variables)
- `ClassificationResult` and `TemplateCandidate` types (including `confidence` field)
- `AdaptiveTemplateRegistry` extending `NlpTemplateRegistry` (in new `template-registry-llm` module)
- `ClassificationCache` — mandatory in-memory cache for positive and negative LLM results
- `VariationSeedingService` orchestrator (in `template-registry-llm`)
- `TemplateNamespace` language field (i18n hook)
- `CandidateOutcome.ADAPTIVE_MATCHED` — new enum value for trace output
- `AdaptiveTemplateRegistry.matchWithTrace()` override for observability
- CDI wiring: `AdaptiveTemplateRegistry` as `@ApplicationScoped @Alternative @Priority(100)`
- Graceful degradation on LLM unavailability
- Integration tests proving the three tiers work together
- `ParaphraseCliff` tests updated to pass via adaptive fallback (tier 3), not seeded variations

### Out of scope
- Variation persistence across restarts — #969 (YAML corpus)
- Per-namespace score thresholds — #979
- Cross-namespace ambiguity detection at registration — #979
- Multi-language NLP models — #965
- LLM prompt tuning and production prompt engineering — iterative refinement

## References

- `template-registry-api/src/main/java/io/casehub/template/registry/UnifiedTemplateRegistry.java` — registry SPI
- `template-registry-api/src/main/java/io/casehub/template/registry/InMemoryTemplateRegistry.java` — snapshot concurrency model
- `template-registry-api/src/main/java/io/casehub/template/registry/TemplateDefinition.java` — patterns + variables
- `template-registry-api/src/main/java/io/casehub/template/registry/TemplateNamespace.java` — namespace grouping
- `template-registry-api/src/main/java/io/casehub/template/registry/NlpTokenizer.java` — SPI pattern for SPIs in api module
- `template-registry/src/main/java/io/casehub/template/registry/nlp/NlpTemplateRegistry.java` — NLP tier implementation
- `template-registry/src/main/java/io/casehub/template/registry/nlp/StructuralMatcher.java` — structural pattern matching
- `template-registry/src/test/java/io/casehub/template/registry/nlp/TemplateRegistryIntegrationTest.java` — ParaphraseCliff tests
- `agent-router-core/src/main/java/io/casehub/platform/agent/router/RoutingChatModel.java` — ChatModel routing
- Issue #959 spec — `specs/issue-959-unified-template-registry/2026-11-24-unified-template-registry-design.md`
- Issue #969 — YAML corpus format (variation persistence, out of scope)
- Issue #979 — per-namespace threshold and ambiguity detection
- Decisions: `specs/issue-971-adaptive-semantic-variation/decisions.md` (D1–D7)
