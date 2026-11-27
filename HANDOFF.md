# HANDOFF — casehub-platform

**Last worked:** #982 — statistical goodness-of-fit filter (design and plan complete, implementation next)
**Branch:** `issue-982-goodness-of-fit-filter`
**This session landed:** nothing (design-only session)

## This session

Completed full design cycle for #982 — embedding-based rescue tier for template matching:

- **Design:** Four-tier cascade (regex → keyword affinity → embedding similarity → LLM classification). Embedding tier uses symmetric keyword-level comparison via `EmbeddingModel` (LangChain4j). Learned synonym pairs feed back into keyword affinity so the system gets faster over time.
- **Decisions:** 11 decisions captured, Standard decision review (3 rounds) revised 4 decisions — corrected module boundary (embedding stays in `template-registry-llm`), storage model (ConcurrentMap on registry, not namespace metadata), activation model (classpath-based), integration point (`AdaptiveTemplateRegistry.matchInNamespace()` override).
- **Spec:** Written and reviewed (Light, 1 round) — 13 findings addressed including symmetric embedding comparison, per-pattern granularity, thread-safe synonym storage, `CandidateTrace` API change.
- **Plan:** 8 tasks across 5 batches — Foundation (API changes, synonym-aware affinity, protected accessors) → Embedding rescue → Synonym learning → Capability proofs → Caching.

## Next session should

1. Run `work continue` — #982 is active on `issue-982-goodness-of-fit-filter`
2. Execute the implementation plan at `plans/2026-11-27-goodness-of-fit-filter.md` using `executing-plans`
3. Start with Batch 1 Task 1 (CandidateOutcome values and CandidateTrace field change)

## Key design decisions to know

- **Module boundary:** All embedding code in `template-registry-llm`, not `template-registry`. Respects #971 D4.
- **Symmetric comparison:** Both template and input embeddings use keyword lemma phrases, not full sentences. Asymmetric comparison produces unreliable cosine similarity.
- **Per-pattern granularity:** Embedding rescue runs per-pattern within templates, matching the existing `matchInNamespace()` architecture.
- **Protected accessors:** `NlpTemplateRegistry` gains `tokenizer()`, `affinityThreshold()`, `nlpCompiled()` — same pattern as `InMemoryTemplateRegistry`'s snapshot accessors.
- **Thread safety:** Synonym map is `ConcurrentMap<String, ConcurrentMap<String, Set<String>>>` with `ConcurrentHashMap.newKeySet()` for innermost sets.

## References

- Design spec: `specs/issue-982-goodness-of-fit-filter/2026-11-27-goodness-of-fit-filter-design.md`
- Decisions: `specs/issue-982-goodness-of-fit-filter/decisions.md`
- Implementation plan: `plans/2026-11-27-goodness-of-fit-filter.md`
- Issue: casehubio/platform#982
