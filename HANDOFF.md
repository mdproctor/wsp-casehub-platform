# HANDOFF — casehub-platform

## Last Session

Completed all implementation for #963 (ICU MessageFormat 2.0 integration) and #1013 (CDI producer for NlpTemplateRegistry). Both issues landed on main. Queue is empty except for #1014 (review-filed).

**#963 — Tasks 2-5 implemented and landed:**
- Task 2: `TemplateDefinition` gains nullable `messageFormat` field (4th record component), backward-compatible 3-arg constructor, `Builder.messageFormat()`. `InMemoryTemplateRegistry.generate()` fail-fast guard for MF2 templates.
- Task 3: `NlpTemplateRegistry` 5-arg constructor with optional `MessageFormatResolver`. MF2 patterns compile at registration, dispatch at generation. Fail-fast at registration when MF2 templates appear without resolver. `buildSchema()` populates `messageFormatSchema`.
- Task 4: New `template-registry-mf2` module — `IcuMessageFormatResolver` wrapping ICU4J 79.1. Key discovery: ICU4J 79.1 MF2 syntax requires `.input` declarations followed by `.match` referencing bare variable name (not `.match {$var :function}` from earlier spec drafts).
- Task 5: End-to-end integration tests — plural English, gender selection, schema metadata. French NLP skipped (no OpenNLP French models in test scope).

**#1013 — CDI producer implemented and landed:**
- `TemplateRegistryBeans` produces `NlpTemplateRegistry`, `LanguageFamilyRegistry`, `UnifiedTemplateRegistry` via CDI
- `SvoMatchingStrategy` and `OpenNlpTokenizerFactory` annotated `@ApplicationScoped` (provided scope CDI annotations)
- `IcuMessageFormatResolver` annotated `@ApplicationScoped` for optional CDI discovery
- Score threshold configurable via `casehub.template.score-threshold` (default 0.5)

**Code review findings:**
- Fix applied: `IcuMessageFormatResolver` lacked `@ApplicationScoped` — CDI would never discover it
- Filed #1014: multi-strategy else branch in `TemplateRegistryBeans` overwrites language→family mapping (nondeterministic). Single-strategy path (production) is correct.

## Immediate Next Step

Queue has #1014 (multi-strategy-language-mapping) only. Low priority — theoretical until a second `MatchingStrategy` exists.

## References

- Spec: `docs/specs/issue-963-icu-messageformat-2/2026-11-27-icu-messageformat-2-design.md`
- Diary: `docs/blog/2026-11-27-mdp03-slot-filling-meets-cldr.md`
- Plan: `~/claude/public/casehub/platform/plans/2026-11-27-icu-messageformat-2.md`
