# Decisions — platform#402 Error Reporting Model

## D1: Error model location

**Choice:** `io.casehub.yaml.core.error` package in yaml-core
**Alternatives:**
- New yaml-error module — adds a module for pure Java types that fit yaml-core's zero-dep constraint
- yaml-plugin-api — errors are runtime concerns, not plugin contracts
**Rationale:** yaml-core is zero-dep and all consumers already depend on it. Error types are pure Java records and sealed interfaces — no external dependency needed.
**Trade-offs:** Widens yaml-core's surface, but error reporting is a core concern of the orchestration layer.
**Sources:** yaml-core/pom.xml (zero-dep verification), CLAUDE.md module table
**Exploration:** quick
**Status:** captured

## D2: Retrofit vs boundary mapping

**Choice:** Wrap at boundary — existing exceptions stay unchanged, a `YamlErrorMapper` translates them to `YamlError` at the point errors are surfaced
**Alternatives:**
- Retrofit exceptions — extend common base class carrying error model. Tighter coupling.
- Both — base class for new exceptions, boundary mapper for existing. Gradual migration.
**Rationale:** Clean separation. Internal code keeps throwing what it throws. The error model is a presentation concern, not an internal concern. Avoids touching 7 existing exception classes and their callers.
**Trade-offs:** Error context must be threaded to the boundary rather than being attached at the throw site. Acceptable since StepContext already carries resolver and deadline context.
**Sources:** DeadlineExceededException.java, ChannelClosedException.java, StepError.java
**Exploration:** quick
**Status:** captured

## D3: Source location strategy

**Choice:** Attach at parse time — Jackson-aware code (yaml-jackson, desiredstate deployment) attaches `SourceLocation` to parsed structures. yaml-core defines the record but never creates one. Consumers pass it through `StepContext`.
**Alternatives:**
- Step name only — skip line numbers, use step names and file paths. Simpler, covers 90%.
- Deferred — nullable SourceLocation field now, implement Jackson tracking later.
**Rationale:** YAML authors need line numbers to find failures in multi-hundred-line files. The zero-dep constraint is preserved because yaml-core only defines the SourceLocation record — Jackson integration lives in yaml-jackson.
**Trade-offs:** Requires StepContext to carry SourceLocation, adding a field to a widely-used type. Threading burden is real but manageable since StepContext is already threaded through the evaluation pipeline.
**Sources:** StepContext.java, yaml-jackson/pom.xml, YamlDesiredStateProcessor.java (existing Jackson parse site)
**Exploration:** quick
**Status:** captured

## D4: Actionable guidance

**Choice:** Structured context only — error types carry step name, decorator context, root cause, source location. Rendering and guidance are consumer concerns.
**Alternatives:**
- Include guidance — remediation hint templates per error category. Immediately useful but hints go stale.
- Optional guidance SPI — nullable guidance field + pluggable GuidanceProvider. Flexible but adds an SPI.
**Rationale:** A CLI, an MCP tool response, and a web UI need different guidance. The error model should carry facts, not opinions. Guidance belongs in the rendering layer.
**Trade-offs:** YAML authors don't get hints out of the box — consumers must implement their own. Acceptable because the structured context (step name, decorator, root cause) is already more useful than a raw stack trace.
**Sources:** Issue #402 error message format example
**Exploration:** quick
**Status:** captured

---

# Decisions — pages#327 Scenario Templates Parameterized Include

## D5: Parameter syntax

**Choice:** `${params.name}` — reuse existing VariableResolver infrastructure
**Alternatives:**
- `{{param}}` mustache — separate template syntax with clear visual distinction between parse-time and runtime resolution. Requires new parser.
- Both — `${params.name}` for values, `{{#if}}` for structural conditionals. Mixed syntax.
**Rationale:** The entire yaml-core codebase (TS and Java) standardises on `${prefix.name}`. The Java backend already uses `${params.projectName}` for parameterized scenarios. Zero new syntax, zero new parsing code.
**Trade-offs:** No visual distinction between parse-time include params and runtime variable resolution. Acceptable because include expansion happens before Walker — the resolver is scoped to include params only at that phase.
**Sources:** variable-resolver.ts, parameterized-onboard.yaml, callee-create-user.yaml
**Exploration:** quick
**Status:** captured

## D6: Conditional step inclusion

**Choice:** `when:` decorator on steps inside the template, evaluated during include expansion
**Alternatives:**
- Structural `if/else` blocks — new YAML-level conditionals that include/exclude groups of steps. More powerful but requires new structural parsing.
- Filter function on include — caller specifies which steps to include/exclude by name. Less flexible.
**Rationale:** The `when:` decorator already exists in the step system. The Java backend already uses `when: "${params.enableCI}"` for this exact purpose. Truthiness evaluation is already in yaml-core.
**Trade-offs:** Cannot conditionally include non-step YAML structures (e.g. orchestration blocks). Only steps can be conditional. Sufficient for the stated use case.
**Sources:** decorator-chain.ts (when layer), Truthiness (yaml-core), parameterized-onboard.yaml
**Exploration:** quick
**Status:** captured

## D7: Expansion integration strategy

**Choice:** Pre-expansion phase before Walker.resolve() — expander operates on raw parsed YAML objects
**Alternatives:**
- Walker-integrated — extend Walker to recognize `include` step type, resolve inline. Complicates Walker, mixes I/O into synchronous resolution.
- Loader wrapper — higher-level `parseScenarioWithIncludes()` function. Two entry points to maintain.
**Rationale:** Matches existing yaml-core pattern (ImportExpander, ModuleExpander, ForEachExpander are all pre-processing phases on raw YAML objects). Keeps Walker unchanged. Independently testable. Clean YAML-object → YAML-object transform.
**Trade-offs:** Includes can only appear in the `includes:` block, not inline within the step list. This matches the issue requirements.
**Sources:** import-expander.ts, module-expander.ts, expand.ts (expansion pipeline pattern)
**Exploration:** quick
**Status:** captured

## D8: Expansion site

**Choice:** At point of execution — browser for TS runtime, Java backend for Java runtime
**Alternatives:**
- Server-side only — Java backend resolves includes before sending YAML. Client parser stays unchanged but Java must handle TS-specific step format.
- Client-side only — TS covers all scenarios. Java backend left without include support.
**Rationale:** Both runtimes parse and execute scenarios independently. Each should expand includes in its own parsing pipeline.
**Trade-offs:** Expansion logic must exist in both TS (yaml-core) and Java (scenario module). Consistent interface ensures parity.
**Sources:** scenario-controller.ts (client fetch + parse), HierarchicalParser.java (server parse)
**Exploration:** quick
**Status:** captured

## D9: TS module location

**Choice:** yaml-core — alongside VariableResolver, Walker, and existing expansion infrastructure
**Alternatives:**
- pages-aria scenario/ — scenario-specific layer. Simpler but less reusable.
**Rationale:** yaml-core is the shared primitives package. Any TS consumer that parses scenarios can use the expander. The expander takes an async loader function as a dependency — the caller provides the I/O.
**Trade-offs:** Widens yaml-core surface. Acceptable because include expansion is a core YAML composition concern.
**Sources:** variable-resolver.ts, import-expander.ts (existing yaml-core expansion modules)
**Exploration:** quick
**Status:** captured

## D10: Nesting support

**Choice:** Nested includes with cycle detection
**Alternatives:**
- Single level only — simpler, no cycle detection. Covers basic seed fragments.
- Nested with depth limit — configurable max depth (e.g. 3).
**Rationale:** Consistent with the existing CallGraphValidator pattern on the Java side. Templates that compose other templates enable layered setup (base environment → domain fixtures → scenario-specific state).
**Trade-offs:** Cycle detection adds complexity. Mitigated by tracking include paths in a set and failing fast on revisit.
**Sources:** CallGraphValidator.java, CallGraphValidatorTest.java
**Exploration:** quick
**Status:** captured

## D11: Include scope

**Choice:** Top-level and section-level includes
**Alternatives:**
- Top-level only — simpler but less useful for sectioned tutorials.
**Rationale:** Sectioned scenarios (tutorials) often need different seed data per section. Matches the Java hierarchy (chapters > sections > steps). Top-level includes prepend to all steps; section-level includes prepend to that section's steps.
**Trade-offs:** More expansion points to handle. Manageable since the expansion logic is the same — just invoked at two levels.
**Sources:** types.ts (SectionedScenario, TutorialSection), HierarchicalParser.java (chapters/sections/steps)
**Exploration:** quick
**Status:** captured

## D12: Parameter validation

**Choice:** Validate required params and type-check values at expansion time
**Alternatives:**
- Best-effort substitution — just substitute what's provided, let VariableResolver throw on unresolved. Simpler but worse error messages.
**Rationale:** Templates declare params with type/required/default (matching Java ParamDescriptor). Fail-fast with clear error on missing required param is essential for YAML authors who may not see the resulting step errors.
**Trade-offs:** Templates must declare params explicitly. This is the desired behavior — params serve as the template's contract.
**Sources:** ParamDescriptor.java, parameterized-onboard.yaml (params with name/type/required/default)

---

# Decisions — pages#359 Spotlight Targeting for Table Rows

## D13: Table scrollToRow API shape

**Choice:** `scrollToRow(predicate: (row: TypedRow) => boolean): Promise<boolean>` — generic predicate over row data
**Alternatives:**
- By row key only — simpler but can't match on column values
- Multiple named methods (scrollToRowByKey, scrollToRowByIndex) — more surface area
- Options object with discriminated fields — one method but still limited
**Rationale:** A predicate is the most general form. The scenario command layer provides YAML-friendly sugar (key, column+value, index) that compiles down to predicates. The table doesn't need to know about lookup modes.
**Trade-offs:** Callers must construct a predicate rather than passing a key directly. Mitigated by the scenario command sugar and by the fact that programmatic callers already have row data context.
**Sources:** pages-data-table.ts:2111 (_scrollToRowIfNeeded private method), pages-data-table.ts:33 (getRowKey callback)
**Exploration:** quick
**Status:** captured

## D14: Row ARIA labeling

**Choice:** Auto-label rendered rows from getRowKey — when getRowKey is set, each row div gets `aria-label={getRowKey(row)}`
**Alternatives:**
- Dedicated getRowLabel callback — separate from key, allows label != key. Another prop to configure.
- No auto-labeling — leave to consumer. Manual aria-label via getRowClass or slot.
**Rationale:** getRowKey already produces human-meaningful identifiers (customer names, ticket IDs). Adding aria-label from getRowKey means spotlight can target rows by ARIA role+name with zero spotlight changes. Also improves accessibility for screen readers.
**Trade-offs:** Key and label are conflated — if a key is a UUID, the aria-label won't be human-readable. Acceptable because getRowKey is already designed to produce meaningful identifiers, and consumers can override via getRowClass if needed.
**Sources:** pages-data-table.ts:2842-2857 (_renderRow — row div has role="row" but no aria-label)
**Exploration:** quick
**Status:** captured

## D15: Scroll-to auto-wait

**Choice:** scroll-to-row auto-waits for the row to render after scrolling, then resolves
**Alternatives:**
- Explicit wait step — author adds a wait: step between scroll-to and spotlight. More control but boilerplate.
- Composite scroll-and-spotlight action — single action does both. Less flexible.
**Rationale:** Virtual scroll re-renders on scroll events. The scroll-to action should guarantee the row is in the DOM when it resolves — otherwise every scenario would need a boilerplate wait step. Composability is preserved since scroll-to is still a separate action from spotlight.
**Trade-offs:** The auto-wait adds latency (one Lit updateComplete cycle). Negligible for scenario playback.
**Sources:** pages-data-table.ts:2128 (_focusRow already awaits updateComplete)
**Exploration:** quick
**Status:** captured

## D16: Scope — table-specific command

**Choice:** Table-specific scroll-to-row command that targets a table by ARIA role+name, then calls its scrollToRow API
**Alternatives:**
- Generic scroll-into-view for any scrollable container — but virtual scroll elements aren't in the DOM, so generic scrollIntoView fails. Would still need the table's data API.
**Rationale:** Virtual scroll is the only case where elements don't exist in the DOM. A table-specific command can use the data model to find the row index and scroll to it. Can generalize later if needed.
**Trade-offs:** Won't work for non-table virtual scrolling containers. None exist today.
**Sources:** command-executor.ts:8 (resolveTarget), pages-data-table.ts:2202 (_useVirtualScroll)
**Exploration:** quick
**Status:** captured

## D17: Element access pattern

**Choice:** resolveTarget + cast — use existing resolveTarget(AriaTarget) to find the grid element, cast to PagesDataTable, call scrollToRow
**Alternatives:**
- Custom element query by tag name — bypasses ARIA targeting model
**Rationale:** Consistent with all other scenario commands. ARIA targeting is the universal addressing mechanism. A clear error when the target isn't a PagesDataTable is better than silently finding the wrong element.
**Trade-offs:** Depends on the element being a PagesDataTable instance. If someone uses a different grid component, the cast fails. Acceptable since this is explicitly a PagesDataTable feature.
**Sources:** command-executor.ts:8-32 (resolveTarget function)
**Exploration:** quick
**Status:** captured

---

# Decisions — pages#390 Scenario Format Refinements

## D18: Format convergence direction

**Choice:** The compact TS step-catalog format is canonical. Java parser converges to read the same format. Scenarios are custom steps (resolved through the standard plugin/catalog system) with presentation structure layered on top.
**Alternatives:**
- Java 3-level format is canonical, TS adapts — forces verbose commands[] wrapper on all YAML authors
- Keep both formats, shared envelope — defers convergence, every refinement applied twice
**Rationale:** The compact format evolved through the YAML parity work (Walker, DecoratorChain, StepWalker). It's what authors write. The Java 3-level format (steps → commands) is redundant infrastructure — the step system already handles action resolution, parameter validation, and dispatch.
**Trade-offs:** Java HierarchicalParser needs rewriting to read compact format. Acceptable since the bespoke parsing duplicates what the plugin system already does.
**Sources:** HierarchicalParser.java (329 lines of bespoke parsing), parser.ts (Walker-based catalog resolution), definitions.ts (step catalog), aria-actions.step.yaml
**Exploration:** deep-analysis (first-principles evaluation)
**Status:** captured

## D19: Step taxonomy

**Choice:** Three categories, all plugins using yaml-plugin-api:
- **AriaStep** — browser DOM actions via ARIA targeting (fill, click, spotlight, scroll-to-row, etc.)
- **ScenarioStep** — presentation actions not requiring ARIA (show-markdown, callouts, slides)
- **ScenarioStructure** — hierarchical containers (chapters, sections) — parsed structure, not dispatched
**Alternatives:**
- Single undifferentiated step type — loses the executor routing signal (ARIA needs browser, etc.)
- Separate systems per category — duplicates the step infrastructure
**Rationale:** All three use the same plugin format (@StepPlugin, @Execute, Result, ServiceRegistry). The category tag (aria, scenario, structure) tells the orchestrator how to route. The plugin registry resolves them uniformly.
**Trade-offs:** ScenarioStructure as a plugin is a stretch — chapters/sections are structural, not executable. But treating them as plugins means they get schema validation and catalog discoverability for free.
**Sources:** yaml-plugin-api (zero-dep plugin SPI), yaml-plugin-processor (APT), command-executor.ts (AriaStep dispatch)
**Exploration:** quick
**Status:** captured

## D20: Speed default change

**Choice:** Clean break — speed omitted = no inter-step delay. Pacing becomes opt-in via explicit `speed: 1.0`.
**Alternatives:**
- Backward compat with flag — keep speed=1.0 default, add opt-in no-delay mode
**Rationale:** Pre-release, no backward compat needed. Steps should execute as fast as possible by default. Pacing is a demo/tutorial concern, not a default.
**Trade-offs:** Existing YAML scenarios that rely on the 1.0 default will run without pacing. Authors add explicit speed: 1.0 where needed.
**Sources:** HierarchicalParser.java:23 (speed default 1.0)
**Exploration:** quick
**Status:** captured

## D21: REST/GraphQL wiring

**Choice:** Adapt existing RestDispatcher/GraphQLDispatcher to work with the compact step format. REST and GraphQL become step definitions in the catalog — standard plugins, not special dispatchers.
**Alternatives:**
- Write fresh dispatch logic — simpler but discards proven code
- Defer — independent concern, but would mean two passes through the files
**Rationale:** The dispatchers have working HTTP/GraphQL logic. The adaptation is wrapping them as plugins that the catalog resolves by action name (rest, graphql).
**Trade-offs:** The adapted dispatchers carry some Format A assumptions that need cleanup.
**Sources:** RestDispatcher.java, GraphQLDispatcher.java, RestInvokeHandler.ts, GraphqlInvokeHandler.ts
**Exploration:** quick
**Status:** captured

## D22: target naming resolution

**Choice:** In the compact YAML format, the `target` conflict dissolves naturally:
- ARIA element fields are flat on the action (role, name, index, within) — no wrapping object
- Executor routing uses `target:` as a decorator (sibling key on the step)
- The rename `target → element` only applies to the wire protocol (JSON serialized from orchestrator to executor) and the TS ScenarioCommand interface
**Alternatives:**
- Rename executor routing to `executor:` instead — clearer but breaks existing YAML that uses `target: browser`
**Rationale:** In the compact format there's only one `target` concept at the YAML level (executor routing). The ARIA element fields aren't wrapped. The wire protocol rename avoids confusion in code without affecting YAML authoring.
**Trade-offs:** The wire protocol rename (target → element) is a breaking change for any code reading the serialized JSON. Acceptable since it's internal protocol.
**Sources:** ScenarioCommand.java (target: AriaTarget), ScenarioOrchestrator.java (serializes to "target" key), scenario-handler.ts:18-25 (ScenarioCommand interface)
**Exploration:** quick
**Status:** captured

## D23: Result aggregation

**Choice:** Last-write-wins merge for multi-command results. Intra-step variable references (${thisStep.field}) prohibited.
**Alternatives:**
- Namespaced by command — preserves all results but complex to reference
- Defer — can be defined when actual multi-command scenarios are authored
**Rationale:** Steps are single-action in the compact format, so multi-command aggregation is rarely needed. When it occurs (via do: grouping), simple merge is sufficient. The step runner infrastructure stays simple.
**Trade-offs:** Can't reference earlier command results within the same step. Acceptable — compose via sequential steps with variable references instead.
**Sources:** Issue #390 proposal
**Exploration:** quick
**Status:** captured

## D24: All step types are plugins

**Choice:** AriaStep, ScenarioStep, and ScenarioStructure all use the yaml-plugin-api plugin format. No special-case parsing — the plugin registry resolves them uniformly.
**Alternatives:**
- Bespoke parsing per category — current Java approach, duplicates infrastructure
**Rationale:** The plugin system (@StepPlugin, @Execute, Result, ServiceRegistry, generated JSON Schema) already handles registration, validation, and dispatch. Using it for all step types means one resolution path, one schema format, one catalog.
**Trade-offs:** ScenarioStructure (chapters/sections) as plugins is unconventional — they're containers, not actions. But they benefit from schema validation and catalog discoverability.
**Depends on:** D19 (taxonomy)
**Sources:** yaml-plugin-api (zero-dep SPI), yaml-plugin-processor (APT generates schema + Action)
**Exploration:** quick
**Status:** captured

## D25: Delete bespoke command model, not refine it

**Choice:** Delete HierarchicalParser's step/command parsing entirely. Replace with a thin scenario envelope parser that reads chapters/sections/metadata and delegates step resolution to the standard Walker/plugin catalog. Delete ScenarioCommand record, parseCommand(), parseAriaTarget(), ScenarioStep sealed interface, ScenarioParser (Format A).
**Alternatives:**
- Refine the bespoke model (original #390 approach) — renames and new fields on a model that shouldn't exist
- Keep both parsers — the commands[] model for Java, compact for TS. Defers convergence.
**Rationale:** Every feature of the commands[] model is already handled by the standard step system. The HierarchicalParser's unique value is the scenario envelope (chapters, sections, top-level metadata). Step parsing should go through the plugin catalog, not a bespoke parser.
**Trade-offs:** Larger scope than original #390. But avoids applying refinements to a model that's being deleted.
**Sources:** HierarchicalParser.java (parseCommand, parseStep — redundant with Walker), engine sequential-onboarding.yaml (do: blocks already use compact syntax), parseScenarioFromParsed in parser.ts (TS already delegates to Walker)
**Exploration:** deep-analysis
**Status:** captured

## D26: Migrate outlier YAML files to compact format

**Choice:** Migrate existing hierarchical-format YAML files (commands[] syntax) to the compact format (action-name-as-key). Format A's compact YAML was already correct — the hierarchical format introduced the wrong step syntax. Converged format: Format A's compact steps + hierarchical's envelope (chapters, sections, metadata), with decorators for step metadata (label, target, actor).
**Alternatives:**
- Support both syntaxes in the parser — adds complexity, defers cleanup
**Rationale:** The commands[] syntax is the outlier. The compact syntax matches what the engine, ARIA, and plugin systems all use. One format means one parser, one catalog, one resolution path.
**Trade-offs:** Breaking change for any YAML files using commands[] syntax. Acceptable since it's pre-release and the file count is small.
**Sources:** META-INF/scenarios/helpdesk-intake.yaml (commands[] format), helpdesk-demo.yaml (already compact)
**Exploration:** quick
**Status:** captured
