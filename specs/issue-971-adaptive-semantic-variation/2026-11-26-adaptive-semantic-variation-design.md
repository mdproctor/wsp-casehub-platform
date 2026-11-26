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

The `ParaphraseCliff` tests document the current boundary: "I'm in favour of this design" does not match the template "I ${decision} this ${subject}". After this feature, it matches — either via pre-seeded variation or via runtime learning.

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

### Module Placement (D4)

```
template-registry-api (zero-dep)
  ├── VariationSeeder         (SPI — @FunctionalInterface)
  ├── AdaptiveFallbackMatcher (SPI — @FunctionalInterface)
  ├── CollisionDetector       (utility — composes registry.match())
  ├── ClassificationResult    (sealed record — match result from adaptive fallback)
  └── TemplateNamespace       (extended with language field)

template-registry (OpenNLP + CDI)
  ├── LlmVariationSeeder      (ChatModel-backed implementation)
  ├── LlmAdaptiveFallback     (ChatModel-backed implementation)
  └── AdaptiveTemplateRegistry (extends NlpTemplateRegistry — adds tier 3)
```

LLM implementations inject `ChatModel` from the agent routing layer. The SPIs have no LLM dependency.

## New Types

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
        String suggestedVariation
    ) implements ClassificationResult {
        public Matched {
            Objects.requireNonNull(templateName, "templateName");
            Objects.requireNonNull(fields, "fields");
            Objects.requireNonNull(suggestedVariation, "suggestedVariation");
            fields = Map.copyOf(fields);
        }
    }

    record Unmatched() implements ClassificationResult {}
}
```

- `templateName` — the template within the namespace that the input matches
- `fields` — extracted variable values
- `suggestedVariation` — a normalised pattern string the LLM produces (e.g. `"I'm in favour of this ${subject}"`) that can be registered for future structural matching

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
            String sourceNamespace,
            String sourceTemplate,
            UnifiedTemplateRegistry registry) {

        List<Collision> collisions = new ArrayList<>();
        for (String variation : candidateVariations) {
            TemplateMatch result = registry.match(variation);
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
}
```

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

Lives in `template-registry`. Injects `ChatModel` from the agent routing layer. Generates paraphrases via a structured-output prompt.

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

Lives in `template-registry`. Single LLM call per miss (D5).

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

Extends `NlpTemplateRegistry` to add the third matching tier. The adaptive fallback fires only when both regex and NLP return `Unmatched`.

```java
public class AdaptiveTemplateRegistry extends NlpTemplateRegistry {

    private final AdaptiveFallbackMatcher fallbackMatcher;
    private final UnifiedTemplateRegistry self;

    @Override
    public TemplateMatch match(String namespaceName, String input) {
        TemplateMatch result = super.match(namespaceName, input);
        if (!(result instanceof TemplateMatch.Unmatched)) {
            return result;
        }
        return adaptiveFallback(namespaceName, input);
    }

    private TemplateMatch adaptiveFallback(String namespaceName, String input) {
        TemplateNamespace ns = /* get from snapshot */;
        List<TemplateCandidate> candidates = ns.templates().values()
            .stream().map(TemplateCandidate::from).toList();

        ClassificationResult cr = fallbackMatcher.classify(
            input, candidates, ns.language());

        if (cr instanceof ClassificationResult.Matched matched) {
            // 1. Collision check on suggestedVariation
            List<CollisionDetector.Collision> collisions =
                CollisionDetector.detect(
                    List.of(matched.suggestedVariation()),
                    namespaceName, matched.templateName(), this);

            // 2. If no collision, register the variation
            if (collisions.isEmpty()) {
                registerLearnedVariation(
                    namespaceName, matched.templateName(),
                    matched.suggestedVariation());
            }
            // else: log warning, don't persist — still return the match

            // 3. Return the match (even if variation wasn't persisted)
            return new TemplateMatch.Matched(
                namespaceName, matched.templateName(), -1,
                matched.fields(), 0.9);
        }
        return new TemplateMatch.Unmatched(input);
    }

    private void registerLearnedVariation(
            String namespaceName, String templateName, String variation) {
        // Atomic replace (D3):
        // 1. Read current namespace from snapshot
        // 2. Build new TemplateDefinition with original patterns + variation
        // 3. Build new TemplateNamespace with updated template
        // 4. deregister(namespaceName) + register(expandedNamespace)
    }
}
```

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
                    variations, namespace.name(), def.name(), registry);

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
  └─ Tier 3: Adaptive fallback (LLM classification)
      ├─ Build TemplateCandidate list from namespace
      ├─ Single LLM call: classify + extract + suggest variation
      ├─ Match? → collision check on suggested variation
      │   ├─ No collision → register variation (atomic replace)
      │   └─ Collision → log warning, don't persist
      └─ Return TemplateMatch.Matched(score=0.9) or Unmatched
```

Tier 1 and 2 operate on both canonical patterns AND seeded variations — seeded variations are just additional patterns in the `TemplateDefinition`. The registry doesn't distinguish them.

## Thread Safety

- `VariationSeeder` and `AdaptiveFallbackMatcher` are stateless functional interfaces — thread-safe by contract
- `CollisionDetector` is a stateless utility — thread-safe
- `AdaptiveTemplateRegistry` inherits the immutable-snapshot concurrency model from `InMemoryTemplateRegistry`
- Learned variation registration uses atomic `deregister` + `register` with CAS retry
- `LlmVariationSeeder` and `LlmAdaptiveFallback` delegate to `ChatModel` which is thread-safe per platform convention

## Testing Strategy

### Unit Tests

- `CollisionDetectorTest` — collision detection with known colliding/non-colliding variations
- `ClassificationResultTest` — sealed record validation, immutability
- `TemplateCandidateTest` — construction from `TemplateDefinition`
- `TemplateNamespaceTest` — language field, backward-compatible constructor

### Integration Tests

- **Seeded variation matches without LLM:** Register a template with pre-seeded variations. Assert that "I'm in favour of this design" matches via regex or NLP without any LLM call. The `ParaphraseCliff` tests flip from `Unmatched` to `Matched`.
- **Runtime-learned variation matches without LLM on second occurrence:** First call to `match()` for a novel paraphrase triggers adaptive fallback (mock LLM). Assert match returned. Second call for same input matches via regex/NLP without LLM.
- **Collision rejection:** Seed template A. Attempt to seed template B with a variation that matches A. Assert the variation is rejected and logged.
- **Adaptive fallback collision guard:** Adaptive fallback suggests a variation that collides. Assert the match is returned but the variation is NOT registered.

### Mock LLM for Tests

Tests use a stub `VariationSeeder` and `AdaptiveFallbackMatcher` with predetermined responses — no real LLM calls in the test suite.

## Scope

### In scope
- `VariationSeeder` SPI and `LlmVariationSeeder` implementation
- `AdaptiveFallbackMatcher` SPI and `LlmAdaptiveFallback` implementation
- `CollisionDetector` utility
- `ClassificationResult` and `TemplateCandidate` types
- `AdaptiveTemplateRegistry` extending `NlpTemplateRegistry`
- `VariationSeedingService` orchestrator
- `TemplateNamespace` language field (i18n hook)
- Integration tests proving the three tiers work together
- `ParaphraseCliff` tests updated to pass after seeding

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
