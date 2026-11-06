# Decisions — #726 Playbook scalar subjects + invoke binding simulation

## D1: Scalar form for single-primary-param steps

**Choice:** Support scalar YAML form for 5 step types: `agent-session-close`, `agent-session-clear`, `graphql-exec`, `rest-request`, `mcp-call`. Scalar value maps to the primary parameter (`session`, `query`, `url`, `tool` respectively).
**Alternatives:**
- Only agent-session-close/clear (original #726 scope) — leaves graphql/rest/mcp inconsistent
- All invoke binding types including multi-param — over-scoped, multi-param steps like agent-session-open need the map form
**Rationale:** All five steps have a single required parameter. Scalar form removes 16+ lines of unnecessary YAML verbosity. Consistency across all single-param invoke binding steps.
**Trade-offs:** Slightly more implementation surface than original issue scope.
**Sources:** Walker.java:266-270 (existing _subject mechanism), AgentSessionStepCompiler.java:23, DeclarationParser.java:219-228, playbook-document.schema.json
**Exploration:** quick
**Status:** captured

## D2: Simulation at Action wrapper level, not handler level

**Choice:** Simulation interception via a transparent `SimulatingAction` wrapper around any `Action`, installed by `YamlDefinitionSource`. Handlers stay unchanged — they always do the real thing. The wrapper checks simulation overlay state at execution time.
**Alternatives:**
- Inject SimulationRuntime into each handler — couples handlers to simulation, requires "recompilation" to switch modes
- Registry-level swap of real vs simulated handlers — still compile-time-ish, requires re-creating the action
**Rationale:** A playbook compiles once and runs real or simulated based on runtime environment. Handlers don't need to know about simulation. Push/pop overlay controls the mode — no playbook or handler changes needed.
**Trade-offs:** The wrapper adds one indirection layer for every invoke binding action, even when simulation is off (the check is cheap — one boolean).
**Sources:** RestInvokeHandler.java, GraphqlInvokeHandler.java, McpInvokeHandler.java, SimulationRuntime overlay pattern, AgentExampleExecutionTest.java:396-409
**Exploration:** quick
**Depends on:** D1 (scalar form defines the corpus key vocabulary)
**Status:** captured

## D3: Full PlaybookCompiler registration for graphql-exec and mcp-call

**Choice:** Register `graphql-exec` and `mcp-call` in PlaybookCompiler with new StepCompiler classes, plus schema entries. Currently they are only stub actions in tests.
**Alternatives:**
- Leave as stubs — playbook catalog files can't be compiled, only parsed via Walker
**Rationale:** User requested full registration. Playbook catalog files should be compilable. Consistent with rest-request and agent-session steps which are already registered.
**Trade-offs:** Two new StepCompiler classes to maintain.
**Sources:** PlaybookCompiler.java:40-57, PlaybookParsingTest.java:35 (stub registration)
**Exploration:** quick
**Depends on:** D1
**Status:** captured

## D4: Corpus keyed by primary parameter

**Choice:** Simulation corpus for invoke binding steps uses `key-lookup` strategy keyed by the step's primary parameter (url, query, tool name). Corpus entries in `simulation.yaml` follow the existing SimulationRuntime pattern.
**Alternatives:**
- Key by full binding (method+url+headers for REST) — more precise but harder to author, overkill for dry-run
- Sequential strategy (ordered responses) — loses addressability
**Rationale:** Primary parameter is the natural discriminator for corpus lookup. Same pattern as existing simulation corpus entries. Pure YAML — no code to change responses.
**Trade-offs:** Can't distinguish GET /api/users from POST /api/users by key alone. Acceptable for dry-run; advanced users can use map form with method to disambiguate.
**Sources:** simulation-config-core KeyLookupStrategy, YamlSimulationConfig corpus schema
**Exploration:** quick
**Depends on:** D2
**Status:** captured
