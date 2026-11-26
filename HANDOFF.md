# HANDOFF — casehub-platform

**Last worked:** #974 — corpus quality testing (design complete, plan pending)
**Branch:** `issue-974-corpus-quality-testing`
**Previous session landed:** #986, #987, #979

## This session

Two issues completed:

### #987 — ManualOption flow (implemented + landed)

User-provided capability resolution in playbooks. When `require-capability` fails with only manual options, the runner now prompts the user for input and continues without re-invocation.

- `UserInputProvider` SPI, `RecoveryAction.PromptUser` command, `${manual.<key>}` variable scope
- CDI + Spring wiring, full test coverage
- Landed via work-end alongside #986

### #974 — Corpus quality testing (designed, not yet planned)

Design spec complete with 5 decisions and a light review pass (15 findings, 7 addressed in spec revision).

**Key decisions:**
1. Variations recorded to simulation corpus (not separate fixtures)
2. Two-mode harness — corpus replay (CI) or LLM generation (developer)
3. Quality tool is a main class in `template-registry-llm`
4. Harness + report types live in `template-registry-api` (no LLM dependency for corpus mode)
5. Ollama on GitHub free tier for one-off integration builds

**Light review addressed:** module placement (harness → template-registry-api), field-level validation, CI quality gate with per-template thresholds, negative fixtures (hand-curated), custom `VariationFixtureLoader` (not `CorpusLoader`), `VariationSeedingService` relationship.

## Next session should

1. Run `work continue` on branch `issue-974-corpus-quality-testing`
2. Write the implementation plan (`writing-plans` skill) — the spec is at `specs/issue-974-corpus-quality-testing/2026-11-26-corpus-quality-testing-design.md`
3. Execute the plan

## References

- Spec: `specs/issue-974-corpus-quality-testing/2026-11-26-corpus-quality-testing-design.md`
- Decisions: `specs/issue-974-corpus-quality-testing/decisions.md`
- Review: `/Users/mdproctor/reviews/casehub-platform/issue-974-corpus-quality-testing-20261126-104645/`
- Key files: `template-registry-api/UnifiedTemplateRegistry.java`, `template-registry-llm/LlmVariationSeeder.java`, `template-registry-api/CollisionDetector.java`, `template-registry-llm/VariationSeedingService.java`
