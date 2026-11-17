# HANDOFF — casehub-platform

**Last closed:** #834 (WS-5: Rules headers and lint for playbook tests)
**Landed:** `5e17be28` on main, published to origin
**Queue:** 18 items remaining (2 new: #850, #851)

## This session

Tutorial headers and assertion-quality lint for playbook tests. Narrowed scope significantly from the direction doc — dropped R-ID rules (natural language rules with only structural enforcement don't carry their weight).

**What landed (3 commits):**

1. **Gate cleanup** — fixed the 3 playbooks that the catalog-parsing-gate expected to fail (modules, rest, 08-structured-output). Root cause: the Walker rejected unknown sibling keys (`headers`, `body`, `response-format`). Fix: `absorbSiblings(true)` on all stub definitions in `ValidatePlaybookPlugin.buildCatalogRegistry()`. Gate now expects 0 failures. `modules.playbook.yaml` restructured from module-definition form to step-based form (filed #851 for teaching regression).

2. **Header validation** — `ValidatePlaybookPlugin.executeDirectory()` now checks every `.playbook.yaml` for `level`, `layer`, and `teaches` in its `meta:` block. Reports `headerErrors` alongside compilation errors. Test coverage in `ValidatePlaybookPluginTest`. Gate assertion: `result.headerErrors hasSize: 0`.

3. **Tutorial headers** — all 70 playbooks have `level` (1-5 difficulty), `layer` (= directory name), `teaches` (one-line concept), and `builds-on` (prerequisite playbooks). Header validation in the gate enforces these on new playbooks.

**Issues filed:**
- #850 — WS-5b: Category-level behavioral tests (runner enrichment + 10 test files + assertion-quality lint). Deferred batches 3-4 from this issue's plan.
- #851 — Restore module-system demonstration (modules.playbook.yaml lost teaching value in restructure)

**Blog:** "The Test That Teaches Nothing" — why `succeeded: true` isn't a test, and what tutorial metadata enables

**Pre-existing test failures:** 2 simulation tests fail on main (#838 StepTraceCollector, PlaybookDryRun). Not introduced by this branch.

**Design artifacts:**
- Spec: `specs/issue-834-rules-headers-lint-playbook-tests/2026-11-17-rules-headers-lint-design.md`
- Plan: `plans/2026-11-17-rules-headers-lint.md`
- Decisions: `specs/issue-834-rules-headers-lint-playbook-tests/decisions.md` (9 decisions, including dropping R-ID rules)

## Next in queue

Epic #827 continues. Next candidates:
- #850 (WS-5b: Category-level behavioral tests, M/Med) — direct continuation of this session's work, same files and modules
- #836 (WS-6b: Validator MCP tool + shaped schemas + metric, L/High) — design-heavy, unblocked by #830's trust model

Standalone candidates: #838, #839, #840, #841, #842, #843, #765, #848, #849, #851.
