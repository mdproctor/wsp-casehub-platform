# Decisions — #836 WS-6b: Validator MCP tool + shaped plugin schemas + metric

## D1: Validation pipeline — single-pass enrichment

**Choice:** Modify existing `PlaybookRunnerCore.validate()` to collect `ValidationDiagnostic` records instead of catching exceptions and returning strings. Enrich `PlaybookValidationResult` with structured diagnostics.
**Alternatives:**
- Separate validation engine — reimplements parsing + resolution with richer error collection. Rejected: duplicates the parsing path, risks divergence with `PlaybookRunnerCore`.
**Rationale:** The Walker already throws structured exceptions (`ParseError` subtypes with `SourceLocation`) that contain everything needed. We intercept them as diagnostics instead of flattening to strings. No duplication, no divergence risk.
**Trade-offs:** Couples validation output to the existing parsing path — if parsing changes, validation changes. This is a feature, not a bug.
**Sources:** `PlaybookRunnerCore.java:186-204`, `ParseError.java`, `Walker.java`
**Exploration:** quick
**Status:** captured

## D2: Catalogue API — filtered query

**Choice:** Add `catalogue(int level, String schema)` to `PlaybookApi` returning a `StepCatalogue` record with filtered Definition summaries, JSON Schema, and example YAML snippets. Trust filtering via `SchemaFilteredRegistry`, level filtering via new `LevelFilteredRegistry` wrapper.
**Alternatives:**
- Full catalogue with metadata — return everything annotated with level/trust availability. Rejected: defeats the "small vocabulary" goal stated in the issue.
**Rationale:** The issue explicitly says "a model sees a small vocabulary, not 600 operations." Filtering server-side gives the LLM exactly what it needs at each level. Reuses `SchemaFilteredRegistry` pattern.
**Trade-offs:** Level-to-capability mapping is a new concept that needs to be maintained alongside capability constants. Worth it for the vocabulary reduction.
**Sources:** `SchemaFilteredRegistry.java`, `PlaybookCapabilities.java`, `StepSchemaComposer.java`
**Exploration:** quick
**Status:** captured

## D3: Variant schema generation — StepSchemaComposer enhancement

**Choice:** Extend `Definition` with optional variant metadata. `StepSchemaComposer` emits per-variant `oneOf` entries instead of flat all-optional schema. APT processor generates variant metadata from plugin annotations.
**Alternatives:**
- Separate schema post-processor — standalone tool reads flat schema and splits. Rejected: less integrated, harder to keep in sync.
**Rationale:** Keeps variant schemas in the existing pipeline: register in Definition, compose in StepSchemaComposer, generate via APT. Single source of truth.
**Trade-offs:** Adds complexity to `Definition` and `StepSchemaComposer`. Acceptable because variant schemas are the whole point of P31.
**Sources:** `Definition.java`, `StepSchemaComposer.java`, `StepPluginProcessor.java`
**Exploration:** quick
**Status:** captured

## D4: MCP surface — extend existing PlaybookApi

**Choice:** Add new operations (enriched validate, catalogue) to the existing `@McpDomain("playbooks")` on `PlaybookApi`. Replace `PlaybookValidationResult` in-place with structured diagnostics.
**Alternatives:**
- New 'playbook-authoring' domain — cleaner separation but fragments the playbook surface; LLM needs two domains.
- New method alongside — keep validate() as-is, add validateDetailed(). Rejected: duplicates the validation path.
**Rationale:** Keeps all playbook operations discoverable in one domain. The enriched validate is backward-compatible (adds fields). Catalogue is a new query.
**Trade-offs:** PlaybookApi grows. Acceptable — it's two methods today, adding one more.
**Sources:** `PlaybookApi.java`
**Exploration:** quick
**Status:** captured

## D5: Suggestion layers — progressive enhancement

**Choice:** Three layers of suggestions: (1) structural/deterministic (always), (2) example-augmented YAML snippets (always), (3) LLM-generated suggestions + corrected YAML + explanation (optional, via agent-config.yaml). Layer 3 returns both the corrected YAML and a human-readable explanation of what changed.
**Alternatives:**
- Structural only — fast and testable but misses the opportunity for LLM-augmented authoring.
- LLM-only — adds latency and cost for every validation, even when errors are trivially fixable.
**Rationale:** Progressive enhancement: deterministic baseline for all users, LLM augmentation for those with agent config. The explanation alongside corrected YAML lets users understand fixes before accepting them.
**Trade-offs:** Layer 3 adds AgentProvider dependency and latency when enabled. Gated by config, so no cost when disabled.
**Sources:** Issue #836 comment (WS-3 integration points), `AgentProvider` SPI
**Exploration:** quick
**Status:** captured

## D6: Level filtering — capability-based

**Choice:** Map playbook levels (1-5) to capability sets. Level 1 = steps only. Level 2 = steps + decorators + control-flow. Level 3 = + concurrency + modules. Level 4 = + orchestration + correlation. Level 5 = everything. Catalogue query filters by level using the same `SchemaFilteredRegistry` pattern.
**Alternatives:**
- Tag-based levels — add 'level' field to Definition/Parameter, filter by level <= requested. Rejected: requires annotating every plugin.
- No filtering, just grouping — return full catalogue grouped by level. Rejected: doesn't achieve the 'small vocabulary' goal.
**Rationale:** Reuses existing capability taxonomy. Levels are a view over capabilities, not a new dimension. The mapping is maintained in one place.
**Trade-offs:** Level-to-capability mapping is implicit — a new capability must be assigned to a level. Worth it vs annotating every plugin individually.
**Sources:** `PlaybookCapabilities.java`, `MapPlaybookSchemaRegistry.java`
**Exploration:** quick
**Status:** captured

## D7: Trust gating — include in this issue

**Choice:** Include MVEL expression engine gating and env/systemProperty variable source gating in this issue's scope. These are prerequisites for the validator to work correctly under the `assisted` context.
**Alternatives:**
- Separate issue — keeps this issue focused but leaves a dangling dependency.
**Rationale:** Small, well-defined wiring tasks. The validator tool passes `assisted` context — it must be enforced end-to-end.
**Trade-offs:** Slightly larger issue scope. Acceptable — the tasks are small and well-bounded.
**Sources:** Trust model design spec (`specs/issue-830-trust-model-playbook-authoring/2026-11-17-trust-model-design.md`)
**Exploration:** quick
**Status:** captured

## D8: Authoring metric — yaml-test-core plugin

**Choice:** New 'authoring-metric' step plugin in yaml-test-core. Test playbooks define tasks per level, the plugin invokes an LLM via AgentProvider from ServiceRegistry, captures generated playbook, runs validation/execution, records pass/fail. Results surfaced via JUnit test reports.
**Alternatives:**
- Standalone CLI tool — duplicates test infrastructure, needs its own reporting.
- MCP tool on PlaybookApi — heavier integration, good for LLM self-evaluation but overkill for metrics.
**Rationale:** Integrates with existing test framework. The metric is fundamentally a test: "can a model produce a valid playbook for this level?" JUnit reports give CI-visible results.
**Trade-offs:** Requires AgentProvider to be available in test scope. Tests with LLM dependencies are non-deterministic and potentially slow — should be tagged for separate CI runs.
**Sources:** `YamlTestEngine.java`, `ValidatePlaybookPlugin.java`, `AgentProvider` SPI
**Exploration:** quick
**Status:** captured
