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
