# HANDOFF — casehub-platform

**Last worked:** #836 (WS-6b: Validator MCP tool + shaped plugin schemas + metric) — Batch 1 landed
**Landed:** `9a852444` on main (3 commits: 2 feat + 1 docs promotion)
**Queue:** 11 items remaining, #836 reopened (Batches 2-5 pending)

## This session

Brainstormed, designed, and began implementing the validator MCP tool for LLM-assisted playbook authoring. Completed the full design cycle (spec + 10 decisions + standard review) and landed the foundation batch.

**What landed (3 commits):**

1. **PlaybookLevel registry** — `PlaybookLevel` record, `PlaybookLevelRegistry` interface, `MapPlaybookLevelRegistry` with 5 named levels (foundational → expert). Each level maps to a capability set that filters the step catalogue. `LevelFilteredRegistry` wraps any `PluginRegistry` with level-based filtering (same pattern as `SchemaFilteredRegistry`). `YamlError.Severity` enum (ERROR/WARNING) added to the sealed error hierarchy for the enriched validation pipeline.

2. **Definition.variants + @Variant annotation** — `Definition` record gains a `variants` field (`Map<String, Map<String, Parameter>>`) for per-operation parameter schemas on shaped plugins. `@Variant` annotation in `yaml-plugin-api` for APT-based variant declaration. Builder API: `Definition.of("device").variant("register", ...)`. All existing callers unaffected via 9-arg convenience constructor.

3. **Artifact promotion** — design spec, decisions, and blog entry promoted from workspace to project.

**Design spec:** `docs/specs/issue-836-validator-mcp-tool/2026-11-18-validator-mcp-tool-design.md`
**Implementation plan:** `plans/2026-11-18-validator-mcp-tool.md` (5 batches, 9 tasks)
**Decisions:** 10 captured in `docs/specs/issue-836-validator-mcp-tool/decisions.md`

**Key design decisions:**
- D1: Single-pass validation enrichment — modify Walker to accumulate `ParseError` via `YamlErrorCollector` instead of throwing
- D5: Three suggestion layers — structural (always), example-augmented (always), LLM-generated (optional via agent-config.yaml)
- D9: Named levels over raw integers — `catalogue("foundational", "assisted")` not `catalogue(1, "assisted")`
- D10: `steps:` key rejected by validator — bare YAML list is the only valid form

**Issues filed this session:**
- #862 — SourceLocation line/column tracking in PlaybookParser (M/Med — SnakeYAML Composer API)
- #863 — Global `steps:` key rejection in PlaybookParser (S/Low)
- #864 — StepSchemaComposer capability-aware structural keyword emission (S/Low)
- #865 — Hierarchical step catalogue — domain-grouped discovery (M/Med — filtering + discovery)

**Blog:** "The Vocabulary Your Author Needs" — why level-filtered catalogues produce more correct LLM-authored playbooks

## Resuming #836

**Start from:** Batch 2 in the implementation plan. The plan is at `plans/2026-11-18-validator-mcp-tool.md`.

**Batch 2: Walker structured error collection + enriched validation**
- Task 3: Walker error collection overload + ErrorStep sentinel
- Task 4: Enriched PlaybookValidationResult + ValidationContext + bare-list enforcement + ValidationSuggestionGenerator

This is the most complex batch — the Walker has ~30 `IllegalArgumentException` throw sites that need converting to `ParseError` collection via `YamlErrorCollector`. The spec details the modification pattern and which error types map to which `ParseError` subtypes.

**Batch 3:** Catalogue API + variant schema composition
**Batch 4:** Trust gating (MVEL + env-access) + LLM suggestion layer 3
**Batch 5:** yaml-metric-core module + AuthoringMetricPlugin

**All foundation types are in place** — the next session can proceed directly to Walker modification.

## Next in queue

#836 is the active issue (reopened, Batches 2-5 pending). After #836:
- #839, #840, #841, #842, #843 — small standalone fixes (XS-S/Low)
- #765 — CorpusSelectionEventObserver trigger index rebuild (S/Low)
- #848, #849 — Streaming plugin validation + ContextParam intersection (S-M/Med)
- #851 — Restore module-system demonstration (S/Low)
