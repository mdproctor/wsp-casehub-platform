# HANDOFF — casehub-platform

**Last worked:** #971 — adaptive semantic variation (landed, follow-up integration tests on main)
**Active item:** #979 — per-namespace threshold and ambiguity (next)

## Session summary

Three-tier adaptive semantic variation for the unified template registry. Template authors write one canonical pattern; the system handles paraphrases through LLM-seeded variations at registration time, NLP structural matching across all patterns, and runtime adaptive LLM fallback that learns new phrasings.

### What was built

**template-registry-api (zero-dep):**
- `replaceOrRegister()` — single-CAS atomic namespace replacement (implements #967)
- `matchStructural()` — structural-only matching for collision detection (bypasses LLM tier)
- `VariationSeeder` SPI — generates paraphrases from template patterns
- `AdaptiveFallbackMatcher` SPI — classifies unmatched input via LLM
- `ClassificationResult` — sealed interface (Matched with confidence, Unmatched)
- `TemplateCandidate` — LLM classification input record
- `CollisionDetector` — stateless utility with test value substitution
- `TemplateNamespace` — language field (default "en", backward-compatible)
- `CandidateOutcome.ADAPTIVE_MATCHED` — trace output for tier 3
- Protected snapshot accessors for subclass CAS operations

**template-registry:**
- `NlpTemplateRegistry.replaceOrRegister()` override with `nlpCompiled` cache sync
- `recompileNlp()` protected helper for subclass NLP cache updates

**template-registry-llm (new module — depends on template-registry + langchain4j-core):**
- `AdaptiveTemplateRegistry` — extends NlpTemplateRegistry with tier 3 adaptive fallback
- `ClassificationCache` — positive/negative TTL cache for LLM results
- `LlmVariationSeeder` — ChatModel-backed variation generator
- `LlmAdaptiveFallback` — ChatModel-backed classifier with field extraction
- `VariationSeedingService` — seed → collision check → register orchestrator

### Key design decisions

- **D3 revised:** `replaceOrRegister` instead of deregister+register — no gap where namespace is absent
- **D4 revised:** LLM implementations in separate module — template-registry keeps pure NLP dependency profile
- **D5:** Single LLM call per miss for classify + extract + suggest variation
- **D7:** Language on namespace, not per-call — each language is its own namespace

### Code review fixes applied

- NearMiss tracking preserved in `AdaptiveTemplateRegistry.match(input)` global search
- String-aware comma splitting in `LlmAdaptiveFallback.extractFields`
- LLM-returned template name validated against namespace before returning Matched

### Follow-up: enriched integration tests (on main)

Rewrote `AdaptiveRegistryIntegrationTest` from 8 thin tests to 25 comprehensive tests in 9 `@Nested` sections. Every test has prose Javadoc explaining the concept, every assertion carries `.as()` with full-sentence failure messages. The centrepiece `FullPipelineScenario` walks through 10 steps proving the full lifecycle: regex → NLP inflection → LLM learning → structural reuse → NLP on learned patterns → caching → negative caching. Each step verifies scores, fields, pattern counts, and LLM call counts to prove which tier handled the input.

## Queue — next session

| # | Issue | Scale | Complexity |
|---|-------|-------|------------|
| 979 | per-namespace score threshold and ambiguity | S | Med |
| 974 | corpus quality testing | — | — |
| 969 | YAML corpus format for template registry | S | Med |
| 970 | match playbook step with type-safe variable flow | — | — |

## Notes for next session

- #979 is closely related — the collision guard and per-namespace thresholds interact. The `CollisionDetector` already uses `matchStructural()` which #979 should respect when adding per-namespace threshold config.
- #969 (YAML corpus) can now store seeded and learned variations — the `TemplateNamespace.language` field maps directly to its proposed `language:` YAML field.
- The `ClassificationCache` config properties (`casehub.template.adaptive.cache.*`) are referenced in the spec but CDI wiring is not in scope for #971 — the CDI `@ApplicationScoped` beans are documented in the spec but require the Quarkus module wiring work.
