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

`toModule()` passes outputs through:

```java
public YamlModule toModule() {
    return new YamlModule(module.name(), module.parameters(),
            module.outputs(), sections);
}
```

**Prerequisites:** casehubio/platform#255 (API parity — SectionDeserializer,
SectionContentRewriter, sourceFor, withChainedScope) must land first. The
expand() signature below assumes #255's 5-parameter form.

## Resolution

### Output resolution during expansion (D2)

`ModuleExpander.expand()` resolves output templates as each import is processed.
The per-import loop, in order:

1. **Resolve `${module.*}` in parameter values** — scan import parameter values
   for `${module.alias.*}` references. Resolve using already-resolved outputs
   from earlier imports. Forward references (alias not yet processed) are a
   build-time error with actionable message: *"Import 'web-app' references
   ${module.cache.url}, but 'cache' is imported after 'web-app'. Move 'cache'
   before 'web-app'."*
2. **Merge with defaults** — resolved parameter values + module defaults
3. **Validate parameters** — `ParameterValidator.validateOrThrow()` on RESOLVED
   values (not raw `${module.*}` strings). This ordering is critical — validation
   must see the actual values, not unresolved references.
4. **Validate output templates** — scan each output's `value` template for
   `${` references. Only `${var.*}` is allowed (D5). Any other prefix is a
   build-time error. This covers #260 item 2.
5. **Resolve output templates** — create a `VariableResolver` with the module's
   parameter scope, resolve each output's `value` template
6. **Validate resolved outputs** — parse each resolved value against its declared
   `ParameterType`. Type mismatch is a build-time error.
7. **Store resolved outputs** — add to the accumulating `moduleOutputs` map.
   Immediately available for step 1 of subsequent imports.
8. **Prefix section keys and merge** (existing — plus SectionDeserializer/Rewriter)

### Output name validation

Output names are validated alongside import validation (collect-all):
- Must not be null or blank
- Must not contain `.` (dots are the alias/name separator in `${module.alias.name}`)
- Must not contain `${` (would create confusion with variable references)

### Output template scope restriction (D5)

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

No new parameters on `expand()` — the expander creates resolvers internally.
The expand() API stays as a single call with all imports; chaining is handled
inside the per-import loop.

### Definitive per-import loop

```java
Map<String, Map<String, String>> allOutputs = new LinkedHashMap<>();

for (YamlImport imp : imports) {
    YamlModule module = availableModules.get(imp.module());

    // 1. Resolve ${module.*} in parameter values using earlier outputs
    VariableSource moduleSource = buildModuleSource(allOutputs);
    Map<String, String> resolvedParams = resolveModuleRefsInParams(
            imp.parameters(), moduleSource, imp.as(), allOutputs.keySet());

    // 2. Merge with defaults
    Map<String, String> paramScope = mergeWithDefaults(module, resolvedParams);

    // 3. Validate resolved parameter values
    ParameterValidator.validateOrThrow(module.parameters(), paramScope);

    // 4-6. Validate + resolve + validate output templates
    Map<String, String> resolvedOutputs = resolveOutputs(module, paramScope);
    allOutputs.put(imp.as(), resolvedOutputs);

    // 7. Store module scope + import condition (existing)
    moduleScopes.put(imp.as(), paramScope);
    importConditions.put(imp.as(), imp.when());

    // 8. Prefix section keys + deserialize + rewrite (existing)
    expandSections(module, imp, mergedSections, deserializer, rewriter);
}
```

`resolveModuleRefsInParams` scans each parameter value for `${module.*}`
references. For each reference, it verifies the alias exists in
`allOutputs.keySet()` (already processed). If not, it throws a forward-reference
error with actionable guidance. If found, it resolves via the module source.

`resolveOutputs` creates a `VariableResolver` with `Map.of("var", paramScope::get)`
and `Set.of()` (no deferred prefixes). For each output: validates template scope
(var-only), resolves template, validates resolved value against declared type.

### Conditional imports and outputs

Outputs from conditional imports (`when` field set) are always resolved and
available to later imports. The `when` condition is evaluated at runtime by the
consumer — expansion-time output resolution is unconditional. This matches
Terraform's behaviour: conditional resources are always planned, conditions
are evaluated at apply time.

### LIST and BOOLEAN output types

Output type validation confirms the resolved value is well-formed for the
declared type. The stored and referenced value is always the raw string.
LIST consumers re-parse via comma-split; BOOLEAN consumers re-parse via
`Truthiness.isTruthy()`. Both sides use the same parser, so round-tripping
is safe.

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
| Chaining: parameter with `${module.*}` resolves before validation | integer param with `${module.a.port}` passes when port="5432" |
| Forward reference gives actionable error | error names both aliases and suggests reorder |
| Output name with dot rejected | validation error like alias dot check |
| Output name blank rejected | validation error |
| Conditional import outputs still available | `when`-gated import's outputs resolve for later imports |
| Multiple outputs on same module | all resolve from same param scope |

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
