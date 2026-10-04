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

**REVISED:** See §Decisions revised during review in the design spec.
Original text retained below for historical context.

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
**Status:** captured — **revised to two categories (AriaStep, ScenarioStep); chapters/sections are structural containers, not plugins**

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

**REVISED:** See §Decisions revised during review in the design spec.
Original text retained below for historical context.

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
**Status:** captured — **revised: wire protocol uses flat `params`, no `element` field; `target → element` rename dropped**

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

**REVISED:** See §Decisions revised during review in the design spec.
Original text retained below for historical context.

**Choice:** AriaStep, ScenarioStep, and ScenarioStructure all use the yaml-plugin-api plugin format. No special-case parsing — the plugin registry resolves them uniformly.
**Alternatives:**
- Bespoke parsing per category — current Java approach, duplicates infrastructure
**Rationale:** The plugin system (@StepPlugin, @Execute, Result, ServiceRegistry, generated JSON Schema) already handles registration, validation, and dispatch. Using it for all step types means one resolution path, one schema format, one catalog.
**Trade-offs:** ScenarioStructure (chapters/sections) as plugins is unconventional — they're containers, not actions. But they benefit from schema validation and catalog discoverability.
**Depends on:** D19 (taxonomy)
**Sources:** yaml-plugin-api (zero-dep SPI), yaml-plugin-processor (APT generates schema + Action)
**Exploration:** quick
**Status:** captured — **revised: structural containers (chapters/sections) excluded from plugin model**

## D25: Delete both parsers, write one clean one

**REVISED:** See §Decisions revised during review in the design spec.
Original text retained below for historical context.

**Choice:** Delete both ScenarioParser (Format A) and HierarchicalParser. Write a single scenario envelope parser that reads the envelope (scenario name, speed, actor, meta, simulation) and structure (chapters → sections → `do:` blocks), then delegates step resolution within `do:` blocks to the standard Walker/plugin catalog. Delete ScenarioCommand, ScenarioStep, HierarchicalStep, and all bespoke parsing methods.
**Alternatives:**
- Refactor HierarchicalParser — carries naming baggage, partial deletion is messy
- Refine the bespoke model (original #390 approach) — applies changes to code that shouldn't exist
**Rationale:** Pre-release, no technical debt. Two parsers for the same thing is the problem. One parser that uses the standard step system is the solution. The scenario layer adds envelope + structure, nothing else.
**Trade-offs:** Larger scope than original #390. But cleaner result — no legacy code paths.
**Sources:** HierarchicalParser.java, ScenarioParser.java, engine sequential-onboarding.yaml (do: blocks), parseScenarioFromParsed in parser.ts (TS already delegates to Walker)
**Exploration:** deep-analysis
**Status:** captured — **revised: Java side performs thin structural transformation (not catalog resolution), uses `steps:` (not `do:`)**

## D26: Migrate outlier YAML files to compact format

**Choice:** Migrate existing hierarchical-format YAML files (commands[] syntax) to the compact format (action-name-as-key). Format A's compact YAML was already correct — the hierarchical format introduced the wrong step syntax. Converged format: Format A's compact steps + hierarchical's envelope (chapters, sections, metadata), with decorators for step metadata (label, target, actor).
**Alternatives:**
- Support both syntaxes in the parser — adds complexity, defers cleanup
**Rationale:** The commands[] syntax is the outlier. The compact syntax matches what the engine, ARIA, and plugin systems all use. One format means one parser, one catalog, one resolution path.
**Trade-offs:** Breaking change for any YAML files using commands[] syntax. Acceptable since it's pre-release and the file count is small.
**Sources:** META-INF/scenarios/helpdesk-intake.yaml (commands[] format), helpdesk-demo.yaml (already compact)
**Exploration:** quick
**Status:** captured

---

# Decisions — pages#466 Single-Source YAML Scenarios

## D27: Scope — both showcase and tutorials

**Choice:** Extract showcase YAML into standalone `.scenario.yaml` files AND let tutorials reference them. One generic companion script replaces 15 near-identical showcase scripts.
**Alternatives:**
- Showcase extraction only — tutorials stay unchanged. Misses the single-source goal.
- Shared reference layer only — only addresses overlapping constructs. Leaves non-overlapping showcase scripts as inline JS strings.
**Rationale:** The 15 showcase companion scripts are ~95% identical boilerplate. The only variation is the `EXAMPLES` data (name, tags, description, YAML string). Extracting to files eliminates the duplication AND makes scenarios available for tutorial reference.
**Trade-offs:** Larger scope — touches both showcase and tutorial systems. But both changes are straightforward since the runtime infrastructure (parseScenario, createScheduler) is already shared.
**Sources:** examples/samples/Scenarios/Flow Control.ts (typical companion script), tutorials/form-automation/tutorial.yaml
**Exploration:** quick
**Status:** captured

## D28: File location — shared directory

**Choice:** `scenarios/` directory at repo root, shared by both showcase and tutorials.
**Alternatives:**
- Alongside showcase samples (examples/samples/Scenarios/) — co-located with current consumer but tutorials would reference into examples/
- In each tutorial directory — co-located with tutorial content but showcase would reference into tutorials/
**Rationale:** A neutral shared directory avoids either consumer "owning" the files. Both showcase and tutorials are consumers, not sources. Category structure via subdirectories (e.g. `scenarios/flow-control/`, `scenarios/coordination/`).
**Trade-offs:** New top-level directory. Acceptable for a single-source architecture.
**Sources:** Issue #466 proposal
**Exploration:** quick
**Status:** captured

## D29: Generic companion script

**Choice:** One generic `.ts` companion script that discovers scenarios from a manifest, loads them via `fetch()`, and drives the picker/runner/log UI.
**Alternatives:**
- Web component (`<pages-scenario-showcase>`) — richer but larger scope, new Lit element
- Keep per-page .ts, load external YAML — least change but still 15 scripts with identical boilerplate
**Rationale:** Minimal change to the execution model (still `new Function()` via the gallery app). The boilerplate is identical across all 15 scripts — only the data source changes. A single script parameterised by a manifest reference eliminates all duplication.
**Trade-offs:** The `.page.yaml` still needs the dropdown `<option>` list. Either generate it from the manifest or have the generic script build it dynamically at runtime. Runtime construction is simpler.
**Sources:** examples/samples/Scenarios/Flow Control.ts, Coordination.ts, Composition.ts (identical structure)
**Exploration:** quick
**Status:** captured

## D30: Frontmatter format — reuse existing meta block

**Choice:** Use the existing `meta:` block format (title, description, labels, tags) consistent with `ScriptMeta` on Java side and tutorial `tutorial.yaml` files. Category comes from directory structure or a label.
**Alternatives:**
- Flat frontmatter (name, tags, description, category) — simpler but diverges from existing ScriptMeta format
- Both formats — more flexible but more parsing
**Rationale:** ScriptMeta already exists in `ScenarioEnvelope`, `BundledScriptSource`, and tutorial parsers. Reusing it means no new format to maintain. The Java `ScenarioEnvelopeParser` already reads `meta:` blocks.
**Trade-offs:** Slightly more verbose than flat keys. Consistency with existing format is worth it.
**Sources:** ScenarioEnvelope.java (meta field), ScriptMeta.java, tutorials/form-automation/tutorial.yaml (meta block)
**Exploration:** quick
**Status:** captured

## D31: Tutorial integration — inline steps stay, add scenario references

**Choice:** Existing inline tutorial steps stay. A new reference mechanism lets tutorials pull scenario YAML from shared files for demo sections where the same orchestration construct is being taught.
**Alternatives:**
- All scenario content from shared files — forces restructuring of tutorials that use editor-set-content with inline YAML content (e.g. yaml-composition tutorial)
- Defer tutorial integration — misses the single-source goal
**Rationale:** The yaml-composition tutorial uses `editor-set-content` steps that set YAML text in an editor — these embed YAML content that is *about* YAML composition, not orchestration constructs. Forcing these into external files would break the guided walkthrough flow. The overlap is specifically in orchestration construct demos (sequential, concurrent, signal/await, etc.).
**Trade-offs:** Not all scenario content is single-sourced. Tutorial-specific inline steps remain. The single-source benefit applies to orchestration construct demos that appear in both showcase and tutorials.
**Sources:** tutorials/yaml-composition/tutorial.yaml (editor-set-content with inline YAML), tutorials/form-automation/tutorial.yaml (ARIA steps)
**Exploration:** quick
**Status:** captured

# Decisions — platform#424 Generated Typed Event Dispatch

## D32: Generator purpose — optional performance optimization alongside runtime interpreter

**Choice:** The generated typed dispatch is an optional optimisation path. The runtime-interpreted path (ScenarioCompiler → EventRouter) remains the default. When generated code exists for a scenario, the runtime can use the generated dispatch instead for faster execution and build-time type safety. This establishes the pattern: runtime-interpreted by default, optional generated code for performance — applicable to future areas beyond state machines.
**Alternatives:**
- Generated code replaces runtime interpreter — forces code generation for all state machines, breaks dynamic YAML loading
- Generated code only (no interpreter) — loses the dynamic capability that defines the YAML-first approach
**Rationale:** All YAML is runtime. The Java and TS runtime executors interpret YAML directly. Code generation is an optional optimisation that should never be required. The interpreted path is the canonical behaviour; generated code is a performance shortcut.
**Trade-offs:** Two code paths to maintain. Must ensure generated dispatch produces identical behaviour to interpreted dispatch.
**Sources:** #410 D8 (three-layer architecture), #502 epic (YAML unification goal)
**Exploration:** deep-analysis
**Status:** captured

## D33: Composition — generated dispatch wraps OrcStateMachine directly (parallel to EventRouter)

**Choice:** Option A — the generated dispatch class wraps `OrcStateMachine<StateEnum>` directly and calls `transition()`. It is parallel to EventRouter, not stacked on top of it. The generated `switch` expression replaces what EventRouter does for that scenario — compile-time pattern matching instead of runtime string matching.
**Alternatives:**
- Generated wraps EventRouter (Option B) — unnecessary indirection, the generated switch IS the dispatch
- EventRouter delegates to generated (Option C) — forces EventRouter to know about generated classes
**Rationale:** Both EventRouter and the generated dispatch are event-to-transition mappers. They wrap the same Layer 1 primitive. The generated switch replaces EventRouter's string matching with compile-time pattern matching — wrapping EventRouter would be Layer 3 wrapping Layer 2 wrapping Layer 1 for no benefit.
**Trade-offs:** None meaningful. Both paths call `transition()` on the same OrcStateMachine, so blocking semantics, handlers, and CAS atomicity work identically regardless of which path initiates the transition.
**Depends on:** D32 (optionality — both paths must coexist)
**Sources:** EventRouter.java (fire → transition pattern), #410 D8
**Exploration:** deep-analysis
**Status:** captured

## D34: Input format — extend existing YAML with optional events section

**Choice:** The generator consumes the same YAML format that ScenarioParser reads, extended with an optional `events:` top-level section for typed field definitions. One YAML format, not a separate schema. ScenarioParser already skips unknown top-level keys, so adding `events:` is backward-compatible.
**Alternatives:**
- Separate YAML format for typed state machines — fragments the format, violates the unification goal of epic #502
- JSON Schema for event types — adds a second file and authoring step
**Rationale:** The epic is about YAML unification. One format, two consumption paths (Java runtime, TS runtime), with optional code generation as a performance layer. A separate format works against parity.
**Trade-offs:** The `events:` section is Java/TS-type-system-aware content in an otherwise language-neutral YAML file. Field types must map to both Java and TS primitives.
**Sources:** ScenarioParser.java (existing format), epic #502 (unification goal)
**Exploration:** deep-analysis
**Status:** captured

## D35: Output scope — full package (state enum + sealed events + typed dispatch)

**Choice:** Generate: (1) state enum from YAML state names, (2) sealed event interface + record per event type from `events:` section, (3) typed dispatch class with `fire(Event)` using Java pattern matching. Everything needed for compile-time safe state machine usage.
**Alternatives:**
- Events + dispatch only (states stay as strings) — less type safety, misses the point
- Dispatch wrapper only (events hand-written) — requires manual type authoring, misaligns with "generate from YAML" goal
**Rationale:** The generator should produce a complete, self-contained typed API from the YAML. If consumers have to hand-write any of the types, the generation is partial and the YAML is no longer the single source of truth.
**Trade-offs:** More generated code to maintain. State enum names derived from YAML strings may not follow Java naming conventions — generator must handle case conversion.
**Sources:** #424 issue body (lists all four generated artifacts)
**Exploration:** quick
**Status:** captured

## D36: Generator infrastructure — reusable pattern for future generated optimisations

**Choice:** The generator module and the runtime discovery mechanism should be designed so future areas beyond state machines can follow the same pattern. The module is focused (state machine dispatch) but the interface between "runtime discovers and uses generated code" is generic enough to extend.
**Alternatives:**
- One-off generator with no reuse concern — simpler now but forces reinvention for each future generator
- Generic code generation framework up front — over-engineers for a single known consumer
**Rationale:** The user has identified this as the first of potentially several performance-optimisation generators. The pattern (interpret by default, use generated code when available) should be clean and repeatable. YAGNI on the framework, but the discovery contract should be intentional.
**Trade-offs:** Slightly more design effort on the discovery interface. Balanced by not building a framework — just making the first implementation follow a pattern that a second implementation could replicate.
**Sources:** User direction ("over time we may code generate other areas for performance")
**Exploration:** quick
**Status:** captured

---

# Decisions — casehub-pages#498 Scenario Lifecycle State

## D6: Scope of lifecycle feature

**Choice:** State machine + CDI events only. No application-level versioning, no approval SPI, no persistence, no REST governance endpoints.
**Alternatives:**
- State + versioning + approval — rejected: versioning is git's job, approval workflows belong in Serverless Workflow (casehub-pages#517)
- State + approval SPI — rejected: approval gate adds complexity without a proven use case. If needed, Serverless Workflow or git PRs handle governance better
- Git-backed script storage — explored but deferred: elegant solution for versioned storage, but scope expansion beyond what #498 asks for
**Rationale:** The issue needs a state machine for #499 (event-triggered activation) to check "is this scenario ACTIVE?" Everything beyond that is scope expansion. LLM-generated script governance, git-backed storage, and approval workflows are valid future concerns but separate issues.
**Trade-offs:** No governance mechanism in-app. Acceptable — git PRs or Serverless Workflow (#517) handle governance when needed.
**Sources:** casehub-pages#498, first-principles analysis of Temporal/Airflow/Serverless Workflow lifecycle rationale
**Exploration:** deep-analysis
**Status:** captured

## D7: Lifecycle state location

**Choice:** Add `ScriptLifecycleState` field directly to `ScriptDescriptor` record
**Alternatives:**
- Separate `ManagedScript` wrapper — clean separation but two types for the same concept, API split
- External side map — state and descriptor always needed together, passing separately is error-prone
**Rationale:** Simplest change. State is part of the script's identity from the consumer perspective. TS UI wants to show state in the library view.
**Trade-offs:** Widens ScriptDescriptor, but the field is genuinely part of the type.
**Sources:** ScriptDescriptor.java, ScriptMeta.java
**Exploration:** quick
**Status:** captured

## D8: Lifecycle transition enforcement

**Choice:** OrcStateMachine from yaml-core, same pattern as TemporalSimulationDriver lifecycle
**Alternatives:**
- Custom transition methods with if/else validation — reinvents state machine logic
- Separate ScriptLifecycleService — splits what is conceptually one entity's mutation
**Rationale:** OrcStateMachine already exists, enforces valid transitions, supports onTransition handlers for CDI events. TemporalSimulationDriver is the established precedent.
**Trade-offs:** None significant — this is applying an existing primitive.
**Sources:** OrcStateMachine.java, DefaultOrcStateMachine.java, TemporalSimulationDriver.java
**Exploration:** quick
**Depends on:** D7 (state lives on ScriptDescriptor)
**Status:** captured

## D9: Approval model

**Choice:** No approval model in this issue. Deferred to casehub-pages#517 (Serverless Workflow) or git-based governance (PRs).
**Alternatives:**
- Synchronous ApprovalPolicy SPI — explored but adds in-app governance that duplicates git PRs or Serverless Workflow
- Async approval with PENDING_APPROVAL state — requires persistence and inbox infrastructure
**Rationale:** The scenario system is scripting and automation, not a governance platform. Approval workflows belong in purpose-built tools (git PRs for developer-authored, Serverless Workflow for durable human-task workflows).
**Trade-offs:** No in-app approval gate. Transitions are unconditional.
**Sources:** First-principles analysis: Temporal, Airflow, CNCF Serverless Workflow lifecycle rationale
**Exploration:** deep-analysis
**Depends on:** D6 (minimal scope)
**Status:** captured

## D10: Lifecycle scope by provenance

**Choice:** Uploaded scripts only. Bundled and external scripts are implicitly ACTIVE.
**Alternatives:**
- All provenance types — bundled scripts can be archived (disabled), external scripts can be drafted. More uniform but adds complexity to immutable sources.
**Rationale:** Bundled scripts ship with the app — they're active by definition. External scripts are managed by their source registry. Only uploaded scripts need lifecycle transitions.
**Trade-offs:** Can't disable a bundled script without removing it from the classpath. Acceptable — that's a deployment concern, not a runtime lifecycle concern.
**Sources:** BundledScriptSource.java, ExternalRegistrySource.java
**Exploration:** quick
**Status:** captured
