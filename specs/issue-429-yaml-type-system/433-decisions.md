# Decisions — #433 Dynamic Step Catalog

## D1: Scope boundary

**Choice:** Everything except IDE JSON Schema generation
**Alternatives:**
- Foundation only (model + SPI + schema gen) — too thin; invoke bindings are the point
- Full as described (including IDE tooling) — Maven plugin for schema gen is polish, not foundation
- Just the model — no catalog, no bindings, no validation
**Rationale:** The step catalog delivers value when playbooks can declare and execute steps. IDE autocomplete is a developer experience layer that doesn't affect runtime correctness. Load-time validation (runtime Java) is in scope; build-time schema generation (Maven plugin) is deferred.
**Trade-offs:** Playbook authors won't get editor autocomplete until the schema generation follow-on lands. Runtime validation still catches errors at load time.
**Sources:** GitHub issue #433 body (IDE Tooling section), existing yaml-plugin-processor SchemaEmitter
**Exploration:** quick
**Status:** captured

## D2: Step definition model relationship to modules

**Choice:** Separate concept — new StepDefinition record in yaml-core that reuses ParameterType/ValueType but is NOT a YamlModule
**Alternatives:**
- Extend YamlModule with outputs and invoke — conflates structural (sections of content) with behavioral (invoke bindings)
- Thin wrapper over YamlModule — composition over inheritance, but creates an awkward delegation for parameters
**Rationale:** Modules are structural: they define sections of YAML content that get merged into a flat namespace. Step definitions are behavioral: they declare executable actions with invoke bindings. These are fundamentally different concerns. Sharing ParameterType (the type enum) is appropriate; sharing the container record is not.
**Trade-offs:** StepParameter will duplicate some structure from YamlModuleParameter (type, required, default, constraints). This is acceptable — the types serve different purposes and may diverge.
**Sources:** yaml-core YamlModule.java, YamlModuleParameter.java, ParameterType.java
**Exploration:** quick
**Status:** captured

## D3: Catalog SPI location

**Choice:** yaml-plugin-api — alongside StepAction and StepResult
**Alternatives:**
- New yaml-step-api module — separate module for catalog contracts; adds a module for a small SPI
- platform-api — step catalog as a platform capability; but step definitions are yaml infrastructure, not platform infrastructure
**Rationale:** The catalog SPI is "given an action name, return something executable." StepAction already defines the execution contract in yaml-plugin-api. The catalog is a registry of StepAction instances with metadata. Placing it alongside the execution contract keeps the dependency graph clean: yaml-plugin-api gains a dependency on yaml-core (for StepDefinition), both are zero-dep pure Java.
**Trade-offs:** yaml-plugin-api gains a compile dependency on yaml-core. Plugin authors who only write @StepPlugin records now have yaml-core on their classpath (transitively). This is harmless — yaml-core is zero-dep pure Java.
**Sources:** yaml-plugin-api StepAction.java, StepResult.java, ServiceRegistry.java
**Exploration:** quick
**Status:** captured

## D4: Invoke handler packaging

**Choice:** Single new yaml-step-runtime module with all invoke handlers
**Alternatives:**
- Per-binding optional modules (yaml-step-mcp, yaml-step-rest, etc.) — 6+ tiny modules for small classes; premature modularity
- Integrate into existing modules (mcp/, agent-router/, etc.) — scatters the feature across modules
**Rationale:** Each invoke handler is ~30-60 lines. Six tiny modules adds build and dependency management overhead with no modularity benefit today. A single module keeps the feature cohesive and discoverable. Can always be split later if any binding grows complex.
**Trade-offs:** All 6 binding implementations are on the classpath together. A deployment that only uses MCP bindings still has REST/Process/Python handler code present. This is acceptable at this scale.
**Sources:** Platform module patterns (agent-* modules, streams-* modules — both consolidated after initially splitting)
**Exploration:** quick
**Status:** captured

## D5: Invoke binding completeness

**Choice:** All 6 invoke bindings fully implemented (MCP, REST, GraphQL, Python, Agent, Process)
**Alternatives:**
- Core 4 + stub 2 — full: MCP, REST, Agent, Process; stub: Python (GraalPy weight), GraphQL (client library)
- MCP + Process only — minimum viable proving the architecture
**Rationale:** The FSI use case needs diverse bindings (risk engines via process, market data via REST, LLM analysis via agent). Python uses subprocess with JSON stdin/stdout (no GraalPy — portable, isolated). GraphQL uses platform's existing SmallRye GraphQL client infrastructure.
**Trade-offs:** More implementation work in the first delivery. Python subprocess is less performant than GraalPy in-JVM but avoids a heavy dependency. GraalPy can be added as an alternative later.
**Sources:** GitHub issue #433 (Invoke Bindings section), platform agent-* modules (AgentProvider SPI), SmallRye GraphQL client in graphql-client/
**Exploration:** quick
**Status:** captured
