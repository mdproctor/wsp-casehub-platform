# HANDOFF — casehub-platform

## Last Session

Implementation session for #965 (multi-language NLP tokenizer models). Executed all 8 tasks across 3 batches. All plan items complete, 393 tests passing across 4 modules (template-registry-api, template-registry-nlp-svo, template-registry, template-registry-llm).

What was built:
- **3 SPIs in template-registry-api:** `MatchingStrategy` (opaque Index, PatternRef, MatchResult), `NlpTokenizerFactory` (BCP 47 language tags), `LanguageFamilyRegistry` (ConcurrentHashMap language→family mapping)
- **New module template-registry-nlp-svo:** SVO-family classes moved from template-registry (StructuralMatcher, DiscriminationTrie, NlpTemplateCompiler, LemmatisedKeywordFilter, OpenNlpTokenizer) + new SvoMatchingStrategy, SvoStopWords (en/fr/es/it/pt), SvoIndex, SvoCompiledTemplate, OpenNlpTokenizerFactory
- **NlpTemplateRegistry refactored:** delegates through MatchingStrategy layer, per-namespace state with opaque Index
- **CompositeNlpTokenizerFactory:** aggregates multiple factory beans
- **Multi-language integration test:** English + French namespace matching verified end-to-end

#965 marked done. #1013 filed for the CDI producer (needs CDI deps not on template-registry's classpath). Review notes: LemmatisedKeywordFilter.affinity stopWords param is unused (not a bug — keywords already filtered), SvoMatchingStrategy.compileTemplate duplicates NlpTemplateCompiler.compile logic (cosmetic).

## Immediate Next Step

Next queue item is #963 (icu-messageformat-2). Topic change — no overlap with NLP tokenizer work. Run `work continue`.

## References

- Spec: `docs/specs/issue-965-multi-lang-nlp-tokenizers/2026-11-27-multi-language-nlp-tokenizers-design.md`
- Plan: `~/claude/casehub/work/plans/2026-11-27-multi-language-nlp-tokenizers.md`
- Diary: `docs/blog/2026-11-27-mdp02-language-families-and-the-matching-strategy-spi.md`
- CDI producer follow-up: casehubio/platform#1013
