## D1: module prefix for output references

**Choice:** `module` as a dedicated VariableResolver prefix — `${module.alias.outputName}` references a computed output from an imported module
**Alternatives:**
- Flatten outputs into `var` scope (`${var.connection_url}`) — collapses the input/output distinction, creates naming collisions if a parameter and output share a name
**Rationale:** Outputs are semantically different from parameters. `${var.engine}` is a parameter the consumer provided. `${module.app-db.connection_url}` is a value computed by another module. The prefix makes the distinction visible in YAML and prevents naming collisions.
**Trade-offs:** New prefix to register — consumers must wire a `VariableSource` for `module`. But this is one `withScope("module", ...)` call.
**Sources:** casehubio/platform#256, Terraform `module.name.output_name` syntax
**Exploration:** quick
**Status:** captured
