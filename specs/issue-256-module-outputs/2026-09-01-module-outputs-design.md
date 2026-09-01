# Module Outputs — Design Spec

**Issue:** casehubio/platform#256
**Date:** 2026-09-01
**Status:** Draft

## Summary

Add module outputs to yaml-core — typed computed values that modules expose for
cross-module composition. Outputs turn modules from content generators into
composable abstractions with defined interfaces (parameters = inputs, outputs =
computed results). Terraform-inspired.

## Model

### YamlModuleOutput

```java
public record YamlModuleOutput(ParameterType type, String value) {}
```

`type` is the declared output type (reuses `ParameterType`). `value` is a
string template resolved using the module's parameter scope.

### YamlModule — new outputs field

```java
public record YamlModule(
        String name,
        Map<String, YamlModuleParameter> parameters,
        Map<String, YamlModuleOutput> outputs,
        Map<String, Map<String, Object>> sections) {

    public YamlModule {
        if (parameters == null) { parameters = Map.of(); }
        if (outputs == null) { outputs = Map.of(); }
        if (sections == null) { sections = Map.of(); }
    }
}
```

### YAML syntax

```yaml
module:
  name: database
  parameters:
    engine:
      type: string
      default: postgres
    port:
      type: integer
      default: 5432
  outputs:
    connection_url:
      type: string
      value: "jdbc:${var.engine}://db-${var.engine}:${var.port}/app"
    host:
      type: string
      value: "db-${var.engine}"
    port:
      type: integer
      value: "${var.port}"
```

### YamlModuleFile — updated

`YamlModuleFile` gains outputs in its header:

```java
public record YamlModuleHeader(
        String name,
        Map<String, YamlModuleParameter> parameters,
        Map<String, YamlModuleOutput> outputs) {

    public YamlModuleHeader {
        if (parameters == null) { parameters = Map.of(); }
        if (outputs == null) { outputs = Map.of(); }
    }
}
```

`toModule()` passes outputs through.

## Resolution

### Output resolution during expansion (D2)

`ModuleExpander.expand()` resolves output templates as each import is processed.
For each import:

1. Resolve parameters (existing — merge provided + defaults)
2. Validate parameters (existing — `ParameterValidator.validateOrThrow()`)
3. **NEW: Resolve output templates** — create a `VariableResolver` with the
   module's parameter scope, resolve each output's `value` template
4. **NEW: Validate resolved outputs** — parse each resolved value against its
   declared `ParameterType`. Type mismatch is a build-time error.
5. **NEW: Store resolved outputs** — add to the accumulating `moduleOutputs` map
6. Prefix section keys and merge (existing)

Resolved outputs from import N are available as `${module.alias.*}` in import
N+1's parameter values. This enables chaining.

### Output template scope restriction (D5)

Output value templates may only contain `${var.*}` references — the module's own
parameters. References to `${module.*}`, `${each.*}`, or any other prefix are
rejected. This makes each module's outputs a pure function of its parameters,
resolvable in isolation.

**Validation:** Before resolving, scan the template for `${` references. Any
prefix other than `var` is a build-time error:

```
Output 'connection_url' in module 'database': template references
'${module.other.x}' — output templates may only use ${var.*} references.
```

### Module prefix on VariableResolver (D1)

`${module.alias.outputName}` resolves via a `VariableSource` registered under
the `module` prefix. The source receives `alias.outputName` (after the first
dot split) and performs a second split to separate alias from output name:

```java
VariableSource moduleSource = name -> {
    int dot = name.indexOf('.');
    if (dot < 0) return null;
    String alias = name.substring(0, dot);
    String outputName = name.substring(dot + 1);
    Map<String, String> outputs = moduleOutputs.get(alias);
    return outputs != null ? outputs.get(outputName) : null;
};
```

This follows the same pattern as `resolveEach` — `${each.row.field}` already
handles two-level dot-separated keys.

### Consumer usage

```yaml
imports:
  - module: database
    as: app-db
    parameters:
      engine: postgres
      port: 5432

  - module: cache
    as: app-cache
    parameters:
      backend_url: "${module.app-db.connection_url}"

nodes:
  app-server:
    type: service
    dependsOn: [app-db.db-instance]
    spec:
      dbUrl: "${module.app-db.connection_url}"
      dbHost: "${module.app-db.host}"
```

## ExpandedModule changes (D4)

```java
public record ExpandedModule(
        Map<String, Map<String, Object>> sections,
        Map<String, Map<String, String>> moduleScopes,
        Map<String, String> importConditions,
        Map<String, Map<String, String>> moduleOutputs) {

    @SuppressWarnings("unchecked")
    public <T> Map<String, T> section(String name) {
        return (Map<String, T>) (Map<String, ?>)
                sections.getOrDefault(name, Map.of());
    }

    public VariableSource outputSource() {
        return name -> {
            int dot = name.indexOf('.');
            if (dot < 0) return null;
            String alias = name.substring(0, dot);
            String outputName = name.substring(dot + 1);
            Map<String, String> outputs = moduleOutputs.get(alias);
            return outputs != null ? outputs.get(outputName) : null;
        };
    }
}
```

Consumer wires: `resolver.withScope("module", expanded.outputSource())`.

## ModuleExpander changes

The `expand()` method gains output resolution in its per-import loop. The
method now needs a `VariableResolver` to resolve output templates:

```java
public static ExpandedModule expand(
        List<YamlImport> imports,
        Map<String, YamlModule> availableModules,
        Map<String, Map<String, Object>> existingSections,
        SectionDeserializer deserializer,
        SectionContentRewriter rewriter) { ... }
```

No new parameter needed — the expander creates a temporary resolver internally
for each import using the module's resolved parameter scope:

```java
// For each import, after parameter resolution:
Map<String, String> paramScope = resolveParameters(module, imp);
VariableResolver outputResolver = new VariableResolver(
        Map.of("var", paramScope::get), Set.of());

Map<String, String> resolvedOutputs = new LinkedHashMap<>();
for (var outputEntry : module.outputs().entrySet()) {
    YamlModuleOutput output = outputEntry.getValue();

    // Validate template scope — only ${var.*} allowed
    validateOutputTemplateScope(output.value(), outputEntry.getKey(), module.name());

    // Resolve template
    String resolved = outputResolver.resolveString(output.value(),
            "output." + module.name() + "." + outputEntry.getKey());

    // Validate resolved value against declared type
    try {
        output.type().parse(resolved);
    } catch (Exception e) {
        throw new IllegalArgumentException(
                "Output '" + outputEntry.getKey() + "' in module '"
                + module.name() + "': resolved value '" + resolved
                + "' is not valid " + output.type(), e);
    }

    resolvedOutputs.put(outputEntry.getKey(), resolved);
}
allOutputs.put(imp.as(), Map.copyOf(resolvedOutputs));
```

For chaining, the output resolver for import N+1 includes earlier outputs:

```java
// Build resolver that includes already-resolved outputs for chaining
VariableSource moduleSource = /* outputSource() logic using allOutputs */;
VariableResolver paramResolver = new VariableResolver(
        Map.of("var", paramScope::get, "module", moduleSource),
        Set.of());
```

Wait — this contradicts D5 (output templates only use `${var.*}`). The chaining
happens in PARAMETER VALUES, not output templates:

```yaml
- module: cache
  parameters:
    backend_url: "${module.app-db.connection_url}"   # parameter value, not output template
```

The parameter value `${module.app-db.connection_url}` is resolved by the
consumer's resolver (which has the `module` source wired). This doesn't require
ModuleExpander to resolve `${module.*}` — the consumer resolves parameter values
before passing them to the import.

**Revised flow for chaining:** ModuleExpander doesn't resolve `${module.*}` in
parameter values. Instead:
1. ModuleExpander resolves each module's outputs (using `${var.*}` only)
2. Returns `moduleOutputs` in `ExpandedModule`
3. Consumer wires `outputSource()` into their resolver
4. Consumer resolves parameter values containing `${module.*}` using their resolver
5. Consumer passes resolved parameter values to the next ModuleExpander call

This keeps ModuleExpander as a structural expander — it resolves output templates
(pure `${var.*}` → resolved strings) but doesn't resolve cross-module references.
The consumer orchestrates chaining.

**But this means the consumer must call `expand()` once per import** (or in
batches where later imports' parameters reference earlier outputs). The current
single-call-all-imports API can't support chaining because parameter values
with `${module.*}` aren't resolved until after expansion.

Two options:

**Option A — Single expand() call, consumer pre-resolves parameters:**
Consumer resolves `${module.*}` in parameter values before calling expand().
This requires the consumer to process imports sequentially, calling
`ParameterValidator` and output resolution for each import manually. Defeats
the purpose of ModuleExpander orchestrating the loop.

**Option B — ModuleExpander resolves chained parameter values internally:**
ModuleExpander processes imports in order. For each import, it resolves
parameter values that contain `${module.*}` using already-resolved outputs.
The expand() API stays as a single call with all imports.

Option B is cleaner — the consumer calls expand() once and gets chaining for
free. ModuleExpander resolves `${module.*}` in parameter values (not in output
templates — D5 holds). The resolver inside ModuleExpander has access to both
`var` (for output templates) and `module` (for parameter value chaining).

## Circular reference detection

Import-order resolution makes circularity structurally impossible:
- Output templates only reference `${var.*}` (D5) — no cross-module refs
- Parameter values in later imports can reference earlier imports' outputs
- Forward references (referencing a not-yet-processed import) are build-time errors
- Transitive circular imports (A→B→C→A) are consumer-side concerns (nested
  import resolution); cycle detection uses `(moduleName, parameterHash)` pairs

No explicit cycle detection needed in ModuleExpander.

## Test Plan

| Test | Coverage |
|------|----------|
| Output template resolves from module parameters | `${var.engine}` → `"postgres"` |
| Output type validation passes | integer output resolves to valid integer |
| Output type validation fails | integer output resolves to non-integer string |
| Output template scope violation | `${module.x}` in output template rejected |
| Output template scope valid | `${var.x}` in output template accepted |
| Chained parameter resolves from earlier output | import B params use `${module.A.out}` |
| Forward reference in parameters rejected | `${module.B.out}` where B comes after current |
| Module with no outputs expands normally | backward compatible |
| outputSource() resolves alias.outputName | two-level dot key lookup |
| outputSource() returns null for missing alias/output | graceful null |
| Multiple imports with outputs all resolve | 3-import chain |
| ExpandedModule.moduleOutputs contains resolved values | programmatic access |

## References

- `io.casehub.yaml.core.module.YamlModule` — add outputs field
- `io.casehub.yaml.core.module.YamlModuleParameter` — existing typed parameter model
- `io.casehub.yaml.core.module.ParameterType` — reused for output type validation
- `io.casehub.yaml.core.module.ModuleExpander` — add output resolution to expansion loop
- `io.casehub.yaml.core.module.ExpandedModule` — add moduleOutputs + outputSource()
- `io.casehub.yaml.core.module.YamlModuleFile` — update header to include outputs
- `io.casehub.yaml.core.resolver.VariableResolver` — used internally for output template resolution
- Terraform module outputs — design precedent
- casehubio/platform#252 — module system
- casehubio/platform#255 — API parity
- casehubio/platform#260 — structural type checking (follow-up)
- `decisions.md` — D1–D5 decisions
