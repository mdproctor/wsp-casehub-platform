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
