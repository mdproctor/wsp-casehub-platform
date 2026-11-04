# Decisions — #700 @ Annotations for YAML Playbooks

## D1: Scope

**Choice:** Staged delivery within #700 — Phase 1: pre-parser + tooling annotations (`@description`, `@requires`, `@version`, `@deprecated`). Phase 2: `@Inject` runtime semantics. Phase 3: decorator migration.
**Alternatives:**
- All-in-one — delivers complete vertical slice but bundles three distinct risk profiles (parsing infrastructure, runtime integration, mass migration)
- Pre-parser only — risks building infrastructure without validating against a real consumer
- Pre-parser + tooling annotations only — tests the system without runtime semantics but defers the hard part
**Rationale:** Tooling annotations are a meaningful first consumer — pure metadata extraction validates the pre-parser end-to-end without runtime integration risk. @Inject in Phase 2 proves the system handles resolution and SPI integration. Decorator migration in Phase 3 proceeds on a validated foundation. Each phase informs the next.
**Trade-offs:** Longer delivery timeline per phase, but each increment is shippable and lower-risk.
**Sources:** Issue #700 spec, R1-01 review
**Exploration:** quick
**Status:** revised (R1: staged delivery reduces per-increment risk; tooling annotations are a sufficient first consumer)

## D2: Annotation syntax — `#@` (valid YAML comments)

**Choice:** `#@` prefix — annotations are YAML comments with structured metadata
**Alternatives:**
- Bare `@` with pre-parser stripping — requires text transformation, file isn't valid YAML without pre-parser
- Synthetic YAML keys (`__ann_*`) — pollutes the parsed map
- SnakeYAML comment events — extract `#@` annotations during YAML parsing via `processComments` flag (implementation alternative, not syntax alternative — only available with `#@`)
- Structured `annotations:` section — YAML-native metadata key; no pre-parser needed but separates annotations from what they annotate (acceptable for document-level, problematic for step-level)
**Rationale:** `#@` makes the raw file always valid YAML. The pre-parser's job is **extraction only** — no text transformation or YAML structure modification. With bare `@`, the pre-parser must strip lines before SnakeYAML can parse — it becomes a required text transformation in the critical path. Since yaml-core is zero-dep/J2CL-safe (no SnakeYAML), the pre-parser is necessarily text-based; `#@` keeps extraction and YAML parsing orthogonal. The `#` is a parser concern — the UI renders bare `@` via #717.
**Trade-offs:** Three extra characters per annotation. Standard YAML editors show them as comments (not ideal but not wrong). UI rendering deferred to #717.
**Sources:** Issue #700 discussion, ytt prior art, yaml-core/pom.xml (zero-dep constraint)
**Exploration:** deep-analysis
**Status:** captured

## D3: Decorator migration — dual path with deprecation timeline

**Choice:** Both `timeout: 5s` (key) and `#@timeout(5s)` (annotation) work during the migration window. Annotation takes precedence on conflict. Deprecation warnings for the key form. Decorator-form key removed once D4 classification is validated through implementation — migration tool provided at that point.

**PROMOTABLE_DECORATOR carve-out:** For `retry`, `timeout`, and `mutex` — PROMOTABLE_DECORATORS classified as annotation candidates — migration removes only the **decorator-form** key (e.g., `retry: 3`, `timeout: 5s`, `mutex: lock-name`). The **structural-scoping** key form (e.g., `retry condition: [steps]`, `timeout 30s: [steps]`, `mutex lock: [steps]`) is retained permanently — it has no annotation equivalent because annotations cannot scope a step list. The migration tool must distinguish these two forms by value type: scalar/simple values are decorator-form (migrated), List values or combined-key syntax are structural-scoping (preserved).

**Alternatives:**
- Immediate clean break — right design per platform philosophy, but premature before D4 audit is validated
- Dual path without warnings — no migration pressure
- Permanent dual path — maintenance burden that never gets removed
- Migrate structural-scoping forms too — impossible; annotations cannot express step-list scoping
**Rationale:** The dual path exists to hedge against D4 misclassification, not as permanent design. Once decorator classification is validated (D4 complete, Phase 2 @Inject proves the model), a clean break with a mechanical migration tool is the correct final state. The deprecation window is bounded: decorator-form key removed in the release following D4 validation. Structural-scoping forms are a permanent part of the language — they are not annotations and never will be.
**Trade-offs:** Temporary dual-path maintenance. Migration tool must be ready before key-form removal. Migration tool must correctly distinguish decorator-form from structural-scoping usage.
**Sources:** Issue #700 spec, R1-03 review, R2-02 review, Walker.java (PROMOTABLE_DECORATORS lines 19–20, structural handling lines 131–142, 388–395)
**Exploration:** quick
**Status:** revised (R1: added deprecation timeline; R2: added PROMOTABLE_DECORATOR carve-out for structural-scoping forms)

## D4: Decorator audit classification

**Choice:** Complete classification of all 28 `StepKeywords.DECORATOR_KEYS`:

**Annotation candidates — decorator-form only (12 — policy/metadata):** timeout, retry, priority, resource, background, mutex, delay, on-error, trigger, semaphore, at, cancel

Note: `retry`, `timeout`, and `mutex` are PROMOTABLE_DECORATORS with dual forms. Their **decorator-form** (scalar value: `retry: 3`, `timeout: 5s`, `mutex: lock-name`) is an annotation candidate. Their **structural-scoping form** (List value: `retry condition: [steps]`) is retained as a key — see D3 carve-out. The annotation replaces the decorator usage; the structural usage is permanent.

**Stay as keys — primary structural (7):**
- `if` — conditional branching, Walker produces IfElseStep
- `barrier` — synchronization point, Walker produces BarrierStep with await list
- `quorum` — quorum consensus, Walker produces QuorumStep with required/of params
- `when` — primary usage is structural guard (PROMOTABLE_DECORATOR), scopes step lists (`when condition: [steps]`). Also used as simple decorator guard, but structural is the dominant form.
- `forEach` — primary usage is iteration (PROMOTABLE_DECORATOR), scopes step lists
- `loop` — iteration control
- `wait` — structural in select branches (SelectBranchType.WAIT), timing decorator elsewhere; structural usage takes precedence

**Stay as keys — data flow / event emission (5):**
- `capture` — output capture
- `transform` — data transformation
- `from` — data source binding
- `signal` — event emission (adds observable side-effect to step)
- `publish` — event emission (same rationale as signal)

**Stay as keys — lifecycle / transitions (4):**
- `on-success` — success callback / state machine transition (dual step + state-machine semantics)
- `on-failure` — failure transition / state machine transition (dual step + state-machine semantics)
- `on-complete` — completion lifecycle hook (consumed by OnCompleteExpander, pre-Walker expansion)
- `transition` — state machine flow control

**Alternatives:**
- `when` as annotation candidate — `when` changes WHETHER the step runs (fits the HOW/WHETHER criterion). However, `when`'s **primary** usage is structural (iteration guard with step-list scoping). The structural form cannot be expressed as an annotation. Stays as key.
- `retry`/`timeout`/`mutex` as "stays as key" — all three are PROMOTABLE_DECORATORS with structural-scoping capability. However, their **primary** usage is decorator-form (policy metadata). The structural-scoping form is retained as a key (D3 carve-out), but the decorator form migrates to annotation.
- `on-error` vs `on-failure` distinction — Both are error-related. `on-error` is a step-level fallback handler (DecoratorChain.wrapOnError). `on-failure` has additional state-machine-level semantics in StateMachineParser (state transition target). The state-machine structural role keeps `on-failure` as a key.

**Criteria hierarchy:**
1. **Primary criterion:** changes WHAT the step does → key; changes HOW/WHETHER → annotation candidate.
2. **Structural override:** keys with their own ResolvedStep type (IfElseStep, BarrierStep, QuorumStep) or whose **primary** usage is structural step-list scoping (forEach, when, loop) stay as keys regardless of primary criterion.
3. **Dual-form handling:** PROMOTABLE_DECORATORS whose **primary** usage is decorator-form (retry, timeout, mutex) are annotation candidates for the decorator case; the structural-scoping key form is retained permanently (D3 carve-out).
4. **Dual semantics:** keys with step + state-machine semantics (on-success, on-failure) stay as keys.

**Rationale:** The criteria hierarchy distinguishes between primary and secondary usage patterns. All six PROMOTABLE_DECORATORS share identical structural handling in Walker (lines 131–142, 388–395), but their primary usage differs: `forEach`/`when`/`loop` are primarily iteration/logic constructs that happen to accept scalar values, while `retry`/`timeout`/`mutex` are primarily scalar policies that happen to accept step lists. The primary usage determines the classification; the secondary form is preserved through D3's carve-out.
**Sources:** StepKeywords.java (28 DECORATOR_KEYS), Walker.java (PROMOTABLE_DECORATORS lines 19–20, structural handling lines 131–142, 388–395, combined-key prefixes lines 28–35), DecoratorChain.java (decorator runtime handling), StateMachineParser.java (state-level metadata), OnCompleteExpander.java
**Exploration:** quick
**Status:** revised (R1: completed audit for all 28 keys; R2: refined criteria hierarchy to distinguish primary vs secondary usage for PROMOTABLE_DECORATORS)

## D5: Annotation infrastructure module placement

**Choice:** Two concerns, two homes:
1. `AnnotationExtractor` (pre-parser, `AnnotationMap`, `Annotation` record) — in **yaml-core** as pure text processing. Zero-dep, J2CL-safe.
2. `InjectionResolver` functional interface — in **yaml-core** as SPI. CDI and ServiceRegistry implementations in their respective modules.

**Alternatives:**
- Pre-parser in yaml-step-runtime — has SnakeYAML, but not J2CL-safe; TypeScript parity lost
- Dual implementation (text in yaml-core, SnakeYAML-backed in yaml-step-runtime) — unnecessary; text extraction is sufficient for `#@` syntax
- yaml-plugin-api — couples injection to the plugin system
- New yaml-inject-api module — adds a module for one interface
**Rationale:** yaml-core is zero-dep/J2CL-transpilable (confirmed: yaml-core/pom.xml has no SnakeYAML dependency). The `#@` pre-parser is inherently text processing — scan for lines starting with `#@`, extract annotation data. No YAML parser needed. This naturally fits yaml-core and preserves TypeScript parity via J2CL transpilation.
**Trade-offs:** yaml-core gains annotation infrastructure in addition to variable resolution. Acceptable — both are pre-parse-time text processing concerns.
**Sources:** yaml-core/pom.xml (zero-dep), yaml-core module rules (CLAUDE.md), VariableResolver.java architecture
**Exploration:** quick
**Status:** revised (R1: explicitly addressed pre-parser module home alongside InjectionResolver SPI)

## D6: @Inject binding lines — no stripping

**Choice:** Binding lines (`claude: agent`) stay in the parsed content map as inert keys. No stripping.
**Alternatives:**
- Strip both annotation and binding line — cleaner content map but more complex pre-parser
**Rationale:** Downstream code only reads known keys (steps, params, vars, name, states, scenario). Unknown keys are harmless. Simplifies the pre-parser — it only extracts annotation data, doesn't modify the YAML structure.
**Design invariant:** Inert binding lines are safe ONLY at the document level. Walker's `resolveOne` throws `IllegalArgumentException` on unknown keys within the step map (Walker.java — unknown key check after action resolution). If future annotations introduce step-level binding lines, they must be handled differently (stripped or registered as known keys). This constraint is inherent in Walker's design and must be documented.
**Trade-offs:** Content map has extra keys that nothing reads. Acceptable. Future strict-mode validation of top-level keys would need to be annotation-aware.
**Sources:** PlaybookParser.java, PlaybookDocument.java, Walker.java (unknown-key rejection in resolveOne), StateMachineParser.java (reads `states` key only)
**Exploration:** deep-analysis
**Status:** captured (R1: added design invariant documenting Walker's unknown-key rejection constraint)

## D7: Nested step annotations — deferred to #716

**Choice:** V1 supports document-level + top-level step annotations only. Nested step annotations deferred to #716. V1 `AnnotationMap` data model must use hierarchical path-based addressing from day one.
**Alternatives:**
- Full nesting support in v1 — more complex pre-parser indent tracking
- Flat addressing (line number or step index) — simpler V1 but forces #716 rewrite
**Rationale:** Document-level + top-level step covers all decorator migrations and @Inject. Nested support adds complexity without immediate consumers. Forward-compatible data model (path-based keys like `"steps[2].block[0]"`) ensures #716 is additive — extend the pre-parser to populate nested entries without changing the data structure. Walker already tracks depth recursively with path strings (MAX_DEPTH = 32).
**Trade-offs:** Can't annotate steps inside block/try/if structures until #716. V1 populates only top-level entries but the data model supports the full hierarchy.
**Sources:** Walker.java (recursive depth tracking, path strings), issue #716
**Exploration:** quick
**Status:** revised (R1: required forward-compatible hierarchical addressing in V1 data model)

## D8: Annotation argument grammar

**Choice:** Parenthesized argument list with positional values and named `key: value` pairs. V1 values are scalars only (strings, numbers, durations, identifiers). No nested structures.

Grammar:
```
annotation     = "#@" name ["(" arg-list ")"]
name           = identifier ("-" identifier)*
arg-list       = arg ("," arg)*
arg            = named-arg | positional-arg
named-arg      = identifier ":" value
positional-arg = value
value          = quoted-string | number | duration | identifier
quoted-string  = '"' escaped-chars '"'
identifier     = [a-zA-Z_][a-zA-Z0-9_.-]*
duration       = number ("s" | "ms" | "m" | "h")
```

**Alternatives:**
- Full YAML-in-comments (arbitrary nested structures) — complex parser, fragile escaping rules, overkill for V1
- S-expression syntax — unfamiliar to Java/YAML developers
- JSON subset — verbose for simple cases (`@timeout({"value": "5s"})`)
**Rationale:** The grammar matches the examples in the issue spec: `@timeout(5s)`, `@retry(3, backoff: exponential)`, `@Inject(AgentProvider, qualifier: "claude")`, `@roles(admin, case-worker)`. Types referenced in annotations (like `AgentProvider`) are opaque strings to the pre-parser — resolution is the InjectionResolver SPI's job. Quoted strings handle special characters (`@schedule(cron: "0 */6 * * *")`). Nested structures (`@parameterize([{x: 1}])`) deferred to a future grammar extension.
**Trade-offs:** No nested values in V1. If a use case needs nested structures, it must be addressed as a grammar extension.
**Sources:** Issue #700 annotation examples, R1-08 review
**Exploration:** surfaced by review
**Status:** captured

## D9: @Inject and simulation framework coherence

**Choice:** @Inject variable names become the authoritative namespace for simulation bindings. `SimulateBlockParser`'s `ALIASES` map is deprecated but continues to work for playbooks without @Inject declarations.

**Alternatives:**
- Replace SimulateBlockParser entirely — breaks existing playbooks without @Inject
- Keep both resolution paths permanently — same dual-path risk as D3
- @Inject names as additional aliases — confusing namespace with two sources of truth
**Rationale:** @Inject creates a direct mapping: `@Inject(AgentProvider) claude: agent` means the simulate block references `claude` directly, not the alias `agent` → `agent-provider.invoke`. SimulateBlockParser's alias resolution (`ALIASES` map with hard-coded `"agent" → "agent-provider.invoke"`) becomes unnecessary when @Inject declares the binding explicitly. Existing playbooks without @Inject continue to work through the ALIASES fallback until migration (same bounded deprecation as D3).
**Trade-offs:** SimulateBlockParser must check for @Inject declarations before falling back to ALIASES. Migration removes ALIASES when all playbooks use @Inject.
**Sources:** SimulateBlockParser.java (ALIASES map), R1-09 review
**Exploration:** surfaced by review
**Status:** captured

## D10: Annotation ordering and conflict resolution

**Choice:** Duplicate annotations of the same type on the same target are an error. During the D3 dual-path window, annotation takes precedence over key form on conflict.

**Alternatives:**
- Last-wins for duplicates — source of subtle bugs (order-dependent behavior)
- First-wins for duplicates — arbitrary, same problem
- Merge duplicates — complex semantics, undefined for most annotation types
**Rationale:** Duplicate annotations are almost certainly a mistake. Failing fast is the right default — it forces the author to be explicit. The annotation-over-key precedence for D3's dual path is already documented; this decision covers the intra-annotation case.
**Trade-offs:** Strict — no way to override an annotation with another of the same type. If multi-value semantics are needed (e.g., multiple `@roles`), the annotation grammar supports list arguments (`@roles(admin, case-worker)`).
**Sources:** R1-10 review
**Exploration:** surfaced by review
**Status:** captured
