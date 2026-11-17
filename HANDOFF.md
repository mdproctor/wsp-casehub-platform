# HANDOFF — casehub-platform

**Last closed:** #833 (WS-4: Canonical form — one file shape, reconcile guide)
**Landed:** `3900bebb` on main, published to origin
**Queue:** 13 items remaining

## This session

Canonical form for the playbook corpus — one file shape, one key case, reconciled guide.

**Code:**
- Renamed `forEach` YAML keyword to `for-each` across Walker, StepKeywords, FusionPass, DecoratorChain, ForEachExpander, ImportExpander, PlaybookCompiler, all JSON schemas, and all tests
- Added `@JsonProperty("for-each")` mixin in yaml-jackson for YamlImport deserialization (critical — without it, imports with `for-each:` silently get null forEach field)
- Migrated 71 playbook files from three-document bare-list form to two-document canonical form with explicit `steps:` key
- Renamed 8 agent-interaction-pattern files to `.playbook.yaml`
- Fixed JSON schema to accept runtime value types: log (string shorthand), loop (string/boolean/object), when/if (boolean), barrier/quorum (typed decorator alternatives)

**Docs:**
- Reconciled yaml-language-guide.md: guard keyword `when` (not `if`), type checking claims fixed (P24), 13 undocumented decorators added, bare variable references fixed, canonical file shape documented
- Updated CLAUDE.md module descriptions for for-each rename
- Blog: "One Shape, or the LLM Guesses" with external SVG diagram

**Filed:** casehub-pages#673 (migrate forEach to for-each), #846 (pre-existing test failures: StepTraceCollectorTest + PlaybookDryRunTest), #847 (JSON schema: complete step type validation coverage)

## Breaking change

The `forEach` → `for-each` YAML keyword rename breaks the pages repo. Confirmed with the team — they'll follow git history to get parity (#845).

## Next in queue

Epic #827 Batch 2 continues: #835 (WS-6a: Generator fixes + plugin validation) — different domain (APT generators), fresh session recommended.

Or standalone: #838, #839, #840, #841, #842, #843, #765.
