## D1: module prefix for output references

**Choice:** `module` as a dedicated VariableResolver prefix — `${module.alias.outputName}` references a computed output from an imported module
**Alternatives:**
- Flatten outputs into `var` scope (`${var.connection_url}`) — collapses the input/output distinction, creates naming collisions if a parameter and output share a name
**Rationale:** Outputs are semantically different from parameters. `${var.engine}` is a parameter the consumer provided. `${module.app-db.connection_url}` is a value computed by another module. The prefix makes the distinction visible in YAML and prevents naming collisions.
**Trade-offs:** New prefix to register — consumers must wire a `VariableSource` for `module`. But this is one `withScope("module", ...)` call.
**Sources:** casehubio/platform#256, Terraform `module.name.output_name` syntax
**Exploration:** quick
**Status:** captured

## D2: Resolve outputs during expansion — import order enables chaining

**Choice:** `ModuleExpander` resolves output templates during expansion as each import is processed. Resolved outputs from earlier imports are immediately available for later imports' parameter values. Import order = resolution order.
**Alternatives:**
- Resolve after expansion (consumer-side) — simpler for yaml-core but no chaining; B can't use A's outputs as parameter values. Outputs become documentation, not composition.
**Rationale:** Module chaining is the primary use case — database outputs connection_url, cache uses it as a parameter. Without chaining during expansion, outputs add no capability consumers can't already achieve manually. The ordering constraint is natural and matches Terraform's behaviour.
**Trade-offs:** Import order matters — reordering imports can break resolution. Circular references (A→B→A) must be detected during expansion. Both are acceptable constraints that match user expectations from Terraform/CloudFormation.
**Sources:** casehubio/platform#256 §Chaining, Terraform module output resolution order
**Exploration:** quick
**Depends on:** D1 (module prefix — outputs are referenced via ${module.alias.name})
**Status:** captured

## D3: Typed outputs — YamlModuleOutput with ParameterType + value template

**Choice:** `YamlModuleOutput(ParameterType type, String value)` — outputs declare a type and a value template. `YamlModule` gains `Map<String, YamlModuleOutput> outputs`. After template resolution, the resolved value is validated against the declared type using `ParameterType.parse()`. Build-time validation catches type mismatches between output declarations, their template sources, and consumer parameter declarations.
**Alternatives:**
- Untyped outputs (`Map<String, String>` — raw templates, no type declaration) — simpler but no contract; consumers discover type mismatches at runtime deep in their pipeline, not at module expansion time
**Rationale:** Outputs are a module's public interface. A typed interface catches mismatches early — if a module declares `port: integer` as an output but the template resolves to `"abc"`, that's a build-time error, not a runtime ClassCastException in the consumer. Reuses `ParameterType` (STRING/LIST/INTEGER/NUMBER/BOOLEAN) — no new type system needed.
**Trade-offs:** More verbose YAML (`{type: integer, value: "..."}` vs just `"..."`). Acceptable — the verbosity documents the contract.
**Sources:** casehubio/platform#256, ParameterType.java (reused for output type validation)
**Exploration:** quick
**Status:** captured

## D4: moduleOutputs on ExpandedModule + outputSource() convenience

**Choice:** `ExpandedModule` gains `Map<String, Map<String, String>> moduleOutputs` (alias → outputName → resolvedValue). Add `VariableSource outputSource()` that creates a VariableSource resolving `alias.outputName` lookups against the map. Consumer wires: `resolver.withScope("module", expanded.outputSource())`.
**Alternatives:**
- Only VariableSource, no raw map — simpler API but consumers can't inspect outputs programmatically (logging, debugging, passing to callbacks)
**Rationale:** The raw map is useful for debugging and programmatic access. The `outputSource()` convenience saves the consumer from writing the two-level map lookup.
**Trade-offs:** One more field on ExpandedModule. Minimal.
**Sources:** casehubio/platform#256 §Implementation, ExpandedModule.java (existing record)
**Exploration:** quick
**Depends on:** D2 (outputs resolved during expansion), D3 (typed outputs — resolved values are strings post-template-resolution)
**Status:** captured

## D5: Output templates restricted to ${var.*} — no cross-module or cross-scope references

**Choice:** Output value templates may only reference `${var.*}` (the module's own parameters). References to `${module.*}`, `${each.*}`, or any other prefix are a build-time error.
**Alternatives:**
- Allow `${module.*}` in output templates — enables output-to-output chaining within a single module definition, but creates a DAG resolution problem with potential cycles and makes outputs order-dependent within a single module
**Rationale:** Outputs are a pure function of the module's own parameters. This makes each module's outputs resolvable in isolation given its parameter scope — no dependency on other modules' outputs during template resolution. Circular reference detection becomes trivially unnecessary. Matches the issue's explicit constraint: "Output templates must only reference the module's own parameters."
**Trade-offs:** A module can't derive one output from another (`host` can't reference `connection_url`). Acceptable — the module author duplicates the relevant `${var.*}` references in each output template.
**Sources:** casehubio/platform#256 §Validation, R1-08 decision review
**Exploration:** quick
**Status:** captured
