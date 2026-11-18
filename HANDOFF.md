# HANDOFF — casehub-platform

**Last worked:** #836 (WS-6b: Validator MCP tool) — Batch 2 landed + capture scoping bugfix
**Landed:** `47ff6abb` on main (6 commits published: 3 Batch 1 + 3 Batch 2)
**Queue:** 14 items remaining, #864 is next active

## This session

Implemented Batch 2 of the validator MCP tool (Walker error collection + enriched validation) and fixed a capture variable scoping bug (#294).

**What landed (3 commits this session):**

1. **Walker error collection overload + ErrorStep** — `ErrorStep` added to `ResolvedStep` sealed hierarchy. New `Walker.resolve()` overload accepting `YamlErrorCollector` + playbookFile that collects `ParseError` instances instead of throwing. Unknown keys produce `UnknownStepError`, duplicate names produce `DuplicateStepError`, structural issues produce `StructureError`. All 11 recursive paths (if/then, block, parallel, match, try/catch, etc.) propagate the collector. Original throwing overloads unchanged. `StructuralStepEvaluator.dispatchStep()`, `PlaybookRunnerCore.resolveStepType()`, and `FusionPass` updated for exhaustive switch coverage.

2. **Enriched PlaybookValidationResult + ValidationSuggestionGenerator** — `PlaybookValidationResult` now carries `List<YamlError> diagnostics` (replacing `List<String> errors`), `List<ValidationSuggestion> suggestions`, and nullable `LlmFixResult`. Backward-compatible `errors()` method returns `List<String>` via summary mapping. New types: `ValidationContext(schema, level, llmSuggestions)`, `ValidationSuggestion(diagnosticIndex, suggestion, exampleYaml)`, `LlmFixResult(correctedYaml, explanation, model)`. `ValidationSuggestionGenerator` uses Levenshtein distance to find closest-match actions for unknown steps and generates example YAML from `Definition` inputs. `PlaybookRunnerCore.validate(Path, ValidationContext)` overload with `YamlErrorCollector`-based validation, bare-list enforcement under assisted schema, and automatic suggestion generation. `ValidationContext.level()` and `llmSuggestions()` are accepted but not yet wired (deferred to Batches 3 and 4).

3. **Capture variable scoping fix** — `PlaybookRunnerCore.run()` top-level step loop now wires `capture:` decorator outputs into the `VariableResolver` between steps. Previously, captures worked inside blocks (via `evaluateBlock()`) but failed at the top level — `${name.field}` references threw "Unknown prefix". The built-in `result` scope masked the bug because `capture: result` collided with the built-in prefix. Custom capture names (`capture: order`, `capture: enrichment`) failed silently. Filed #867 for the `result` name collision.

**Code review:** Comprehensive review completed — 0 critical, 3 important (all verified as intentional/per-plan), 3 minor (trailing newlines fixed, FQN imports cleaned up). All 910 yaml-step-runtime tests pass. Full reactor build (5+ min) passes.

**Blog:** "Structured Errors Are the Conversation" — why typed diagnostics and Levenshtein suggestions matter for LLM-assisted playbook authoring.

**Issues filed:** #867 (capture: result name collision with built-in result scope, XS/Low)

## Resuming #864

**Next issue:** #864 — StepSchemaComposer capability-aware structural keywords (S/Low)

This overlaps with #836 Batch 3 Task 5. The StepSchemaComposer currently emits all structural keywords unconditionally. #864 adds a `Set<String> capabilities` parameter to `compose()` so structural keywords (`if/then/else`, `parallel`, `race`, etc.) are conditionally included based on the level's capability set. This is a focused change within `StepSchemaComposer` — the existing two-arg overload delegates with all capabilities for backward compat.

**Key file:** `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepSchemaComposer.java`

**Design context:** The implementation plan for #836 Batches 3-5 is at `/Users/mdproctor/claude/public/casehub/platform/plans/2026-11-18-validator-mcp-tool.md`. Task 5 (catalogue API) depends on the capability-filtered `compose()` from #864. The design spec is at `docs/specs/issue-836-validator-mcp-tool/2026-11-18-validator-mcp-tool-design.md`.

## Queue (14 items)

1. #864 — StepSchemaComposer capability-aware structural keywords (S/Low) ← next
2. #862 — SourceLocation line/column tracking in PlaybookParser (M/Med)
3. #863 — Global steps: key rejection in PlaybookParser (S/Low)
4. #865 — Hierarchical step catalogue — domain-grouped discovery (M/Med)
5. #838 — StepTraceCollector restore advanceStateMachines (S/Low)
6. #839 — SimulationRuntimeActivator static ObjectMapper (XS/Low)
7. #840 — consolidate duplicate capture logic (S/Med)
8. #841 — parallel structural step concurrency bound + fail-fast (M/Med)
9. #842 — background decorator error observability (S/Low)
10. #843 — configurable iteration cap for until loops (S/Low)
11. #765 — CorpusSelectionEventObserver rebuild trigger index (M/Med)
12. #848 — Streaming plugins bypass validation and coercion (M/Med)
13. #849 — Streaming + ContextParam intersection not handled in generator (S/Med)
14. #851 — Restore module-system demonstration (M/Med)
