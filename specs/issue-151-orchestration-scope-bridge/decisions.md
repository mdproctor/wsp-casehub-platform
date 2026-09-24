# Decisions — yaml-core Plugin API

## D1: Plugin API as the source of yaml-core's language

**Choice:** yaml-plugin-api generates yaml-core. Plugins are the source of truth for all YAML-addressable constructs. yaml-core becomes a thin generic runtime engine that loads plugins and dispatches.
**Alternatives:**
- Plugin API as an addition on top of hand-coded yaml-core — incremental but leaves two ways to define constructs
- Hand-code everything — current state, no extensibility story for community
**Rationale:** Better architecture for existing code with no downsides. Encourages rapid community evolution. Plugin authors don't need yaml-core internals knowledge.
**Trade-offs:** Migration effort for existing constructs. Acceptable — incremental migration, no big bang.
**Sources:** StepPrimitive/PrimitiveRegistry (current pattern), desiredstate plugin model (prior art)
**Exploration:** quick
**Status:** captured

## D2: Three plugin types

**Choice:** @StepPlugin (leaf → StepResult), @FlowPlugin (contains children → StepResult), @ConditionPlugin (predicate → boolean)
**Alternatives:**
- Two types only (Step + Flow) — forces conditions into StepResult, which is awkward
- Single plugin type with mode flags — loses the clarity of distinct contracts
**Rationale:** Each type has a clear contract and natural return type. Existing constructs map cleanly: rest-call/assert/process-execute → Step, loop/retry/forEach → Flow, and/or/not/xor → Condition.
**Trade-offs:** Three annotation types instead of one. Cost is trivial — each is a distinct concept.
**Sources:** LoopDirective.java, RetryDirective.java, Condition.java (yaml-core), AssertPrimitive.java
**Exploration:** quick
**Status:** captured

## D3: APT for everything — validation, schema, binding, registry

**Choice:** APT generates all artifacts: compile-time plugin class validation, JSON Schema, typed binder (validated tree → record), registry manifest. Jackson limited to YAML text → tree parsing only.
**Alternatives:**
- Jackson for binding — poor error messages leak through
- Hybrid (Jackson binding + APT registry) — still has Jackson error UX problem
- Runtime reflection — no compile-time validation, slower startup
**Rationale:** Full control over error messages at every level. Compile-time: APT catches plugin structure errors. Runtime: schema validation with source-located errors, then generated binder with domain-specific errors. Jackson never touches binding.
**Trade-offs:** More generated code than Jackson-based binding. Acceptable — generated code is mechanical and the error reporting improvement is significant.
**Sources:** PlatformSchemaGenerator (existing schema generation capability), desiredstate annotations/deployment (APT prior art)
**Exploration:** quick
**Status:** captured
**Depends on:** D1 (plugin-as-source architecture)

## D4: Two modules — yaml-plugin-api + yaml-plugin-processor

**Choice:** yaml-plugin-api (zero-dep, annotations + SPI types) + yaml-plugin-processor (APT, depends on schema-generator)
**Alternatives:**
- Single module — forces schema-generator as transitive dep for all plugin authors
- Fold into existing modules — blurs boundaries
**Rationale:** Same pattern as desiredstate annotations/runtime + annotations/deployment. Plugin authors depend only on the thin API module. The processor is a build-time tool.
**Trade-offs:** Two modules instead of one. Standard for annotation processing — the split is well-understood.
**Sources:** desiredstate annotations/ module split, graphql-generator APT pattern
**Exploration:** quick
**Status:** captured
**Depends on:** D1 (plugin-as-source architecture)

## D5: Service injection via @Execute method parameters

**Choice:** Plugin's @Execute method receives service dependencies as typed parameters. Framework resolves from ServiceRegistry. Plugin classes stay framework-neutral.
**Alternatives:**
- CDI @Inject on plugin class — ties plugins to a DI framework
- ServiceLocator parameter — weakly typed, runtime lookup
**Rationale:** Plugin authors write framework-neutral code. APT validates that requested service types are known. The generated binder wires services from whatever DI framework the host uses (CDI, Spring, or plain ServiceRegistry).
**Trade-offs:** Services must be registered in the ServiceRegistry. Not a real cost — platform SPIs already are.
**Sources:** ProcessExecutor SPI pattern (platform-api), AgentRuntime SPI pattern
**Exploration:** quick
**Status:** captured
**Depends on:** D3 (APT generates wiring)

## D6: Flow plugin children as typed record field

**Choice:** Flow plugin record has a `List<PluginInvocation> body` field. Schema generates nested array. APT validates the field exists for @FlowPlugin.
**Alternatives:**
- Callback-based — children passed to execute method only, schema can't describe nesting
- Both declared + executor — redundant
**Rationale:** Children are part of the plugin's schema — YAML authors see them, schema validates them. The execute method receives the typed children list. Type safety composes: each child is also schema-validated.
**Trade-offs:** None identified.
**Sources:** StepDef (current step definition type), CompoundStepDef
**Exploration:** quick
**Status:** captured
**Depends on:** D2 (three plugin types)

## D7: Performance constraint — no runtime reflection

**Choice:** All dispatch through generated code. Plugin lookup via pre-built map. Schema validation optional in production.
**Alternatives:** None considered — this was a stated hard constraint.
**Rationale:** Plugin system must not regress performance vs current hard-coded constructs. Generated binders are as fast as hand-written code. Registry is a HashMap lookup. Schema validation is the only new cost and can be toggled.
**Trade-offs:** None — generated code matches hand-written performance.
**Sources:** Stated constraint from user
**Exploration:** quick
**Status:** captured

## D8: YAML schema stays clean

**Choice:** Generated JSON Schema must produce the same YAML authoring experience as current hand-coded schemas. No complexity increase for YAML authors.
**Alternatives:** None considered — this was a stated hard constraint.
**Rationale:** The plugin system is a better way to architect existing code, not a new abstraction visible to YAML authors. The YAML surface must be identical or better.
**Trade-offs:** Schema generation must be tuned to match existing conventions (ShorthandModule for scalar-or-object patterns, etc.).
**Sources:** Stated constraint from user, ShorthandModule (existing schema capability)
**Exploration:** quick
**Status:** captured
