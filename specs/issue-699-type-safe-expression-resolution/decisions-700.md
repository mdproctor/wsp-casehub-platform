# Decisions — #700 @ Annotations for YAML Playbooks

## D1: Scope

**Choice:** Pre-parser + @Inject + decorator migration — all in one issue
**Alternatives:**
- Pre-parser only — risks building infrastructure without validating against a real consumer
- Pre-parser + tooling annotations only — tests the system without runtime semantics but defers the hard part
**Rationale:** @Inject is the flagship annotation that proves the system works end-to-end. Without a meaningful consumer, the pre-parser is speculative infrastructure.
**Trade-offs:** Larger scope (XL/High) but delivers complete vertical slice.
**Sources:** Issue #700 spec
**Exploration:** quick
**Status:** captured

## D2: Annotation syntax — `#@` (valid YAML comments)

**Choice:** `#@` prefix — annotations are YAML comments with structured metadata
**Alternatives:**
- Bare `@` with pre-parser stripping — requires text transformation, file isn't valid YAML without pre-parser
- Synthetic YAML keys (`__ann_*`) — pollutes the parsed map
**Rationale:** `#@` makes the raw file always valid YAML. No pre-parser text transformation needed. SnakeYAML ignores comments natively. The `#` is a parser concern — the UI can render bare `@` later (#717).
**Trade-offs:** Three extra characters per annotation. Standard YAML editors show them as comments (not ideal but not wrong). UI rendering deferred to #717.
**Sources:** Issue #700 discussion, ytt prior art
**Exploration:** deep-analysis
**Status:** captured

## D3: Decorator migration — dual path with deprecation

**Choice:** Both `timeout: 5s` (key) and `#@timeout(5s)` (annotation) work. Annotation takes precedence on conflict. Deprecation warnings for the key form.
**Alternatives:**
- Clean break — simpler but breaks existing playbooks
- Dual path without warnings — no migration pressure
**Rationale:** Zero breaking changes. Gradual migration via deprecation warnings.
**Trade-offs:** Must maintain two code paths until migration complete.
**Sources:** Issue #700 spec
**Exploration:** quick
**Status:** captured

## D4: Decorator audit classification

**Choice:** 8 annotation candidates (policy/metadata): timeout, retry, priority, resource, background, mutex, delay, on-error. 8 stay as keys (structural/data-flow): when, capture, transform, signal, on-success, on-failure, forEach, loop.
**Alternatives:** N/A — classification criteria from issue spec applied consistently
**Rationale:** If removing the element changes WHAT the step does → stays as key. If it changes HOW/WHETHER the step executes → annotation candidate.
**Trade-offs:** None — classification is a design tool, not a trade-off.
**Sources:** Issue #700 playbook element audit table, StepKeywords.java
**Exploration:** quick
**Status:** captured

## D5: @Inject resolution SPI location

**Choice:** `InjectionResolver` functional interface in yaml-core (zero-dep, J2CL-safe)
**Alternatives:**
- yaml-plugin-api — couples injection to the plugin system
- New yaml-inject-api module — adds a module for one interface
**Rationale:** yaml-core is the right home for pre-parser infrastructure. CDI and ServiceRegistry implementations live in their respective modules.
**Trade-offs:** yaml-core gains a new SPI — but it already has VariableSource, ForEachAdapter, etc.
**Sources:** yaml-core module rules (CLAUDE.md), VariableResolver.java architecture
**Exploration:** quick
**Status:** captured

## D6: @Inject binding lines — no stripping

**Choice:** Binding lines (`claude: agent`) stay in the parsed content map as inert keys. No stripping.
**Alternatives:**
- Strip both annotation and binding line — cleaner content map but more complex pre-parser
**Rationale:** Downstream code only reads known keys (steps, params, vars, name). Unknown keys are harmless. Simplifies the pre-parser — it only extracts annotation data, doesn't modify the YAML structure.
**Trade-offs:** Content map has extra keys that nothing reads. Acceptable.
**Sources:** PlaybookParser.java, PlaybookDocument.java
**Exploration:** deep-analysis
**Status:** captured

## D7: Nested step annotations — deferred to #716

**Choice:** V1 supports document-level + top-level step annotations only. Nested step annotations deferred to #716.
**Alternatives:**
- Full nesting support in v1 — more complex pre-parser indent tracking
**Rationale:** Document-level + top-level step covers all decorator migrations and @Inject. Nested support adds complexity without immediate consumers.
**Trade-offs:** Can't annotate steps inside block/try/if structures until #716. Acceptable for v1.
**Sources:** Walker.java nesting depth, issue #716
**Exploration:** quick
**Status:** captured
