# HANDOFF — casehub-platform

## Last Session

Design + partial implementation for #963 (ICU MessageFormat 2.0 integration). Full brainstorming cycle with two adversarial reviews (decision review: 12 issues, spec review: 13 issues — key findings addressed). Task 1 of 5 implemented (SPI and schema types). IntelliJ became unresponsive at start of Task 2 — session wrapped cleanly.

What was designed:
- **MessageFormatResolver SPI** in template-registry-api — multi-method interface with `CompiledMessage` opaque handle, `compile()` at registration, `format()` at generation
- **Per-template MF2 dispatch** — `TemplateDefinition` gains nullable `messageFormat` field; `generate()` dispatches based on template, not pipeline stage
- **Fail-fast guards** — `InMemoryTemplateRegistry` throws for MF2 templates (not silent slot-fill), `NlpTemplateRegistry` validates resolver presence at registration
- **New module `template-registry-mf2`** — ICU4J 79.1, classpath-activated, CDI `@ApplicationScoped`

What was implemented (Task 1 only):
- `MessageFormatResolver` interface with `CompiledMessage` marker
- `MessageFormatSchema` and `SelectorInfo` records
- `TemplateSchema` extended with 6-arg constructor (backward-compatible 5-arg delegates)
- 136 tests passing in template-registry-api

## Immediate Next Step

Resume #963 implementation at **Task 2** (TemplateDefinition messageFormat field + InMemoryTemplateRegistry fail-fast guard). Restart IntelliJ first — it was unresponsive at session end. Then continue through Tasks 3-5. Run `work continue`.

Plan: `~/claude/public/casehub/platform/plans/2026-11-27-icu-messageformat-2.md`

## Key Design Decisions (review-tested)

- D1 (revised): Resolver lives in NlpTemplateRegistry, not base class — #982 D5 explicitly rejected nullable constructor on the base class
- D3: MF2 function names are `:string`, `:number`, `:integer`, `:date`, `:time`, `:datetime` — NOT MF1 names (`:plural`, `:select`, `:selectordinal`). No `when` keyword in MF2 syntax.
- D10: MF2 is generation-only — matching unchanged, authors maintain coherence between matching patterns and MF2 generation patterns
- AdaptiveTemplateRegistry constructor chain needs updating (5-arg super call)
- VariationSeedingService and AdaptiveTemplateRegistry.registerLearnedVariation must carry forward messageFormat

## References

- Spec: `docs/specs/issue-963-icu-messageformat-2/2026-11-27-icu-messageformat-2-design.md`
- Decisions: `~/claude/public/casehub/platform/specs/issue-963-icu-messageformat-2/decisions.md`
- Plan: `~/claude/public/casehub/platform/plans/2026-11-27-icu-messageformat-2.md`
- Diary: `docs/blog/2026-11-27-mdp03-slot-filling-meets-cldr.md`
- Decision review: `/Users/mdproctor/reviews/casehub-platform/issue-963-decision-20261127-222535/`
- Spec review: `/Users/mdproctor/reviews/casehub-platform/issue-963-spec-20261127-225408/`
