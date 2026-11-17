# Decisions — #833 WS-4: Canonical form — one file shape, reconcile guide

## D1: File shape — two-document with explicit steps:

**Choice:** Two-document YAML: front matter (version + schema) + content doc with explicit `steps:` key
**Alternatives:**
- Three-document form (header + metadata + bare step list) — was 83% of files, but step list as bare array required parser normalisation
- Single document with `steps:` key (no header) — used by agent-interaction patterns, loses version/schema metadata
**Rationale:** The parser already wraps bare-list third documents under `steps:` internally (PlaybookParser.java line 66). Making the YAML match what the runtime expects eliminates implicit conversion. Two documents is simpler than three. Metadata (`meta:`, `pools:`) and `steps:` are siblings in the second document.
**Trade-offs:** All existing playbook files need reformatting. Mechanical.
**Sources:** PlaybookParser.java:35-78, PlaybookRunnerCore.java:96, P23
**Exploration:** quick
**Status:** implemented

## D2: Key case — kebab-case, rename forEach to for-each

**Choice:** All YAML keywords use kebab-case; `forEach` renamed to `for-each`
**Alternatives:**
- Keep `forEach` as the only camelCase exception — it's a well-known programming term
- Rename all keys including yaml-core composition keys — too broad, breaks pages
**Rationale:** `on-error`, `on-success`, `on-failure` are already kebab-case. `forEach` was the only camelCase holdout in the step/decorator namespace. YAML convention is kebab-case. The rename covers both the step/decorator keyword (yaml-step-runtime) and the composition keyword (yaml-core ForEachExpander). Java class/method names stay PascalCase/camelCase per Java convention.
**Trade-offs:** Breaking change for pages repo — user confirmed they'll follow git history to get parity. All string literals, JSON schemas, test assertions, and playbook files updated.
**Sources:** Walker.java:21, StepKeywords.java:9, DecoratorChain.java:361, P23
**Exploration:** quick
**Status:** implemented

## D3: Guard keyword — when (decorator) vs if (structural)

**Choice:** `when` for guard decorator, `if/then/else` for structural branching — existing code distinction preserved
**Alternatives:**
- Use `if` for both (what the guide said) — conflates two distinct concepts
- Rename structural `if` to something else — gratuitous, `if/then/else` is universally understood
**Rationale:** These are genuinely different operations. `when: <expr>` conditionally skips a single step (decorator). `if: <expr>` + `then: [steps]` + `else: [steps]` is a structural branching construct. The guide incorrectly used `if` for both. Code already uses `when` for guards.
**Trade-offs:** None — the code already works this way. Only the guide needed fixing.
**Sources:** when-guard.playbook.yaml, if-else.playbook.yaml, Walker.java:220-224, P40
**Exploration:** quick
**Status:** implemented

## D4: Naming convention — .playbook.yaml suffix

**Choice:** All playbook files use `.playbook.yaml` suffix; config manifests stay `.yaml`
**Alternatives:**
- Bare `.yaml` for all — loses the ability to distinguish playbooks from configs in directory listings
**Rationale:** `discoverSimulationYaml()` in PlaybookRunnerCore already handles both `.playbook.yaml` and `.yaml` suffixes. Using `.playbook.yaml` consistently makes it clear which files are executable playbooks vs config manifests (like `agent-config.yaml`). Test descriptor files use `.test.yaml`.
**Sources:** PlaybookRunnerCore.java:196-201, P23
**Exploration:** quick
**Status:** implemented

## D5: Schema reconciliation

**Choice:** Update JSON schema to match runtime step type acceptance
**Alternatives:**
- Leave schema mismatches as known tech debt — they were hidden before the canonical form migration exposed them
**Rationale:** The canonical form migration made bare-list documents visible to the schema validator (previously silently skipped). The underlying mismatches were real: `log` accepts string shorthand, `loop` accepts string/boolean/object, `when`/`if` accept boolean literals, `barrier`/`quorum` decorator forms need typed alternatives. Fixing now avoids a regression backlog.
**Trade-offs:** Minimal — just making the schema truthful about what the runtime accepts.
**Sources:** playbook-document.schema.json, PlaybookSchemaValidationTest failures
**Exploration:** quick
**Status:** implemented
